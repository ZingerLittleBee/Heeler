#!/usr/bin/env python3
"""Capture scrubbed herdr-core frame vectors and an event log from a core socket.

Connects only to the socket path it is given, speaks the framed protocol itself,
and starts nothing: it runs no `hc` and no herdr-core subcommand, because every
one of those can start a core with this process's environment (ADR 0031). Start
the core yourself first, on a lab machine.

    herdr-core-capture.py --socket <path> --vectors <out.json> --events <out.ndjson> \
        [--seconds 20]

The vectors have the shape of plugin/test-vectors/herdr-core-frames-v1.json.
Everything written is rebuilt from scrubbed JSON: the core's name and id, user
paths, the user and host names, and environment assignments never reach a file.
An assignment takes the rest of its string with it, because a command line in
argv can quote its value in ways that only a shell can parse. A secret passed as
a separate argument (`--token abc`) is not an assignment and is not recognized,
so read the output before committing it. The script never attaches to a Terminal,
whose screen bytes cannot be scrubbed.
"""

from __future__ import annotations

import argparse
import getpass
import json
import re
import select
import socket as socketlib
import struct
import sys
import time
from pathlib import Path
from typing import Any

HEADER = struct.Struct("<IBI")
DATA, CREDIT, CLOSE = 0, 1, 2
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_HELLO_LINE = 1024 * 1024
# Keys whose whole value is an environment, wherever they appear.
ENVIRONMENT_KEYS = {"env", "environment", "restart_env"}
SCRUBBED_CORE = {"id": "scrubbed-core-id", "name": "lab-core"}
# POSIX, PowerShell and flag assignments, in any case, through the end of the string.
ASSIGNMENT = re.compile(r"\b(\w+)[ \t]*(\+?=).*", re.DOTALL)
# csh, fish and Windows forms, which set a variable with no equals sign.
ENVIRONMENT_COMMAND = re.compile(r"\b((?:setenv|setx|set(?:[ \t]+-\w+)+)[ \t]+\w+[ \t]+).*", re.DOTALL)
# The name after a home root, and the directory the core keeps per-user sockets in.
USER_PATHS = (
    (re.compile(r"/home/[^/\s\"']+"), "/home/user"),
    (re.compile(r"/Users/[^/\s\"']+"), "/Users/user"),
    (re.compile(r"/root(?=[/\s\"']|$)"), "/home/user"),
    (re.compile(r"/run/user/\d+"), "/run/user/1000"),
    (re.compile(r"(?i)[a-z]:\\users\\[^\\\s\"']+"), r"C:\\Users\\user"),
)


class CaptureError(Exception):
    pass


class Scrubber:
    """Removes what identifies a person or a machine from decoded JSON."""

    def __init__(self, names: list[str]) -> None:
        self.names = [re.compile(rf"\b{re.escape(name)}\b") for name in names if len(name) > 1]

    def text(self, value: str) -> str:
        for pattern, replacement in USER_PATHS:
            value = pattern.sub(replacement, value)
        value = ASSIGNMENT.sub(lambda match: f"{match.group(1)}{match.group(2)}<scrubbed>", value)
        value = ENVIRONMENT_COMMAND.sub(lambda match: f"{match.group(1)}<scrubbed>", value)
        for name in self.names:
            value = name.sub("scrubbed", value)
        return value

    def value(self, value: Any, key: str | None = None) -> Any:
        if key == "core" and isinstance(value, dict):
            return dict(SCRUBBED_CORE)
        if isinstance(value, dict):
            return {
                self.text(name): self.value(item, name)
                for name, item in value.items()
                if name not in ENVIRONMENT_KEYS
            }
        if isinstance(value, list):
            return [self.value(item, key) for item in value]
        if isinstance(value, str):
            return self.text(value)
        return value


def frame(channel: int, kind: int, payload: bytes = b"") -> bytes:
    return HEADER.pack(channel, kind, len(payload)) + payload


def compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


class Connection:
    def __init__(self, path: str, timeout: float) -> None:
        self.sock = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
        self.sock.settimeout(timeout)
        try:
            self.sock.connect(path)
        except OSError:
            self.sock.close()
            raise
        self.buffer = b""

    def close(self) -> None:
        self.sock.close()

    def send(self, data: bytes) -> None:
        self.sock.sendall(data)

    def _fill(self) -> None:
        chunk = self.sock.recv(64 * 1024)
        if not chunk:
            raise CaptureError("the core closed the connection")
        self.buffer += chunk

    def read_line(self) -> bytes:
        while b"\n" not in self.buffer:
            if len(self.buffer) > MAX_HELLO_LINE:
                raise CaptureError("the hello reply is too long")
            self._fill()
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def read_frame(self) -> tuple[int, int, bytes]:
        while len(self.buffer) < HEADER.size:
            self._fill()
        channel, kind, length = HEADER.unpack_from(self.buffer)
        if length > MAX_PAYLOAD:
            raise CaptureError(f"a frame of {length} bytes exceeds the limit")
        while len(self.buffer) < HEADER.size + length:
            self._fill()
        payload = self.buffer[HEADER.size:HEADER.size + length]
        self.buffer = self.buffer[HEADER.size + length:]
        return channel, kind, payload

    def has_input(self, timeout: float) -> bool:
        return bool(self.buffer) or bool(select.select([self.sock], [], [], timeout)[0])


def request(identifier: str, method: str, params: dict[str, Any]) -> bytes:
    return compact({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params}).encode()


def call(connection: Connection, identifier: str, method: str, params: dict[str, Any], early: list[tuple[int, bytes]]):
    """One channel-0 exchange. Stream frames that come first are kept for later."""
    connection.send(frame(0, DATA, request(identifier, method, params)))
    while True:
        channel, kind, payload = connection.read_frame()
        if channel != 0:
            if kind == DATA:
                early.append((channel, payload))
            continue
        reply = json.loads(payload)
        if reply.get("id") == identifier:
            return reply


def source_of(version: str, how: str) -> str:
    return f"captured from herdr-core {version} by scripts/lab/herdr-core-capture.py: {how}"


def capture(path: str, seconds: float, scrubber: Scrubber) -> tuple[dict[str, Any], list[str]]:
    connection = Connection(path, timeout=max(seconds, 10.0))
    try:
        hello = {"jsonrpc": "2.0", "id": "hello", "method": "hello", "params": {"generation": 1, "framed": True}}
        connection.send((compact(hello) + "\n").encode())
        hello_reply = json.loads(connection.read_line())
        if "result" not in hello_reply:
            raise CaptureError(f"hello was refused: {scrubber.value(hello_reply.get('error'))}")
        version = str(hello_reply["result"].get("version", "unknown"))

        early: list[tuple[int, bytes]] = []
        exchanges = []
        status_reply = call(connection, "1", "server.status", {}, early)
        exchanges.append(exchange_case("server-status", version, "server.status", status_reply, scrubber))
        subscribe_reply = call(connection, "2", "events.subscribe", {}, early)
        exchanges.append(exchange_case("events-subscribe", version, "events.subscribe", subscribe_reply, scrubber))
        events_channel = subscribe_reply.get("result", {}).get("channel")
        if not isinstance(events_channel, int):
            raise CaptureError("events.subscribe named no channel")

        stream = bytearray()
        for channel, payload in early:
            if channel == events_channel:
                stream += payload
                connection.send(frame(channel, CREDIT, struct.pack("<I", len(payload))))
        deadline = time.monotonic() + seconds
        while (left := deadline - time.monotonic()) > 0:
            if not connection.has_input(left):
                break
            channel, kind, payload = connection.read_frame()
            if channel == events_channel and kind == DATA:
                stream += payload
                connection.send(frame(channel, CREDIT, struct.pack("<I", len(payload))))
            elif channel == events_channel and kind == CLOSE:
                break
        connection.send(frame(events_channel, CLOSE))
    finally:
        connection.close()

    lines = [scrubbed_line(line, scrubber) for line in bytes(stream).split(b"\n") if line.strip()]
    vectors = {
        "description": "Captured herdr-core framed protocol vectors. Scrubbed: no environments, user paths, or core identity.",
        "provisional": False,
        "coreVersion": version,
        "hello": {
            "name": "hello",
            "source": source_of(version, "the plain hello reply"),
            "reply": compact(scrubber.value(hello_reply)),
        },
        "exchanges": exchanges,
        "events": [
            {
                "name": f"{event_name(line)}-{index}",
                "source": source_of(version, "the events channel"),
                "line": line + "\n",
            }
            for index, line in enumerate(lines)
        ],
    }
    return vectors, lines


def exchange_case(name: str, version: str, method: str, reply: dict[str, Any], scrubber: Scrubber) -> dict[str, Any]:
    clean = scrubber.value(reply)
    return {
        "name": name,
        "source": source_of(version, f"a {method} exchange on channel 0"),
        "method": method,
        "params": {},
        "result": clean.get("result"),
        "requestFrame": frame(0, DATA, request(str(reply.get("id")), method, {})).hex(),
        "replyFrame": frame(0, DATA, compact(clean).encode()).hex(),
    }


def scrubbed_line(line: bytes, scrubber: Scrubber) -> str:
    return compact(scrubber.value(json.loads(line)))


def event_name(line: str) -> str:
    message = json.loads(line)
    params = message.get("params", {})
    return str(params.get("type") or message.get("method") or "notification")


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Capture scrubbed vectors from a herdr-core socket.")
    parser.add_argument("--socket", required=True, help="the core socket to connect to, and the only one")
    parser.add_argument("--vectors", required=True, type=Path, help="where to write the vector JSON")
    parser.add_argument("--events", required=True, type=Path, help="where to write the scrubbed event log")
    parser.add_argument("--seconds", type=float, default=20.0, help="how long to record events")
    return parser.parse_args(arguments)


def main(arguments: list[str]) -> int:
    options = parse_arguments(arguments)
    scrubber = Scrubber([getpass.getuser(), socketlib.gethostname().split(".")[0]])
    try:
        vectors, lines = capture(options.socket, options.seconds, scrubber)
    except (CaptureError, OSError, ValueError) as error:
        print(f"capture failed: {error}", file=sys.stderr)
        return 1
    options.vectors.write_text(json.dumps(vectors, indent=2, ensure_ascii=False) + "\n")
    options.events.write_text("".join(line + "\n" for line in lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
