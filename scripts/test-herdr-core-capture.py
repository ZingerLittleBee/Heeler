#!/usr/bin/env python3
"""Test the herdr-core capture script against a fake core on a Unix socket."""

from __future__ import annotations

import ast
import importlib.util
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "lab" / "herdr-core-capture.py"

spec = importlib.util.spec_from_file_location("herdr_core_capture", SCRIPT)
assert spec and spec.loader
capture = importlib.util.module_from_spec(spec)
sys.modules["herdr_core_capture"] = capture
spec.loader.exec_module(capture)

HEADER = struct.Struct("<IBI")
SECRET_VALUE = "hunter2-secret-value"
USER = "alice"
HOST = "alices-laptop"

RECORD = {
    "address": "t1",
    "argv": [f"/home/{USER}/.local/bin/claude", f"--token=abc", f"API_KEY={SECRET_VALUE}"],
    "cwd": f"/Users/{USER}/work/project",
    "title": f"{USER}@{HOST}: ~/work",
    "labels": {"workspace": f"/home/{USER}/w"},
    "restart_env": {"API_KEY": SECRET_VALUE},
    "env": {"PATH": f"/home/{USER}/bin", "SECRET": SECRET_VALUE},
    "status": {"state": "idle", "msg": f"see C:\\Users\\{USER}\\notes"},
    "state": "live",
}


def line(method, params):
    return (json.dumps({"jsonrpc": "2.0", "method": method, "params": params}) + "\n").encode()


class FakeCore(threading.Thread):
    """Answers hello, status and subscribe, then sends events cut across frames."""

    def __init__(self, path: str) -> None:
        super().__init__(daemon=True)
        self.path = path
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(4)
        self.connections = 0
        self.received: list[tuple[int, int, bytes]] = []
        self.sent: list[tuple[int, int, bytes]] = []
        self.hello: dict | None = None

    def run(self) -> None:
        try:
            connection, _ = self.listener.accept()
        except OSError:
            return  # The test closed the listener without connecting.
        self.connections += 1
        with connection:
            reader = connection.makefile("rb")
            self.hello = json.loads(reader.readline())
            connection.sendall(self.reply("hello", {
                "generation": 1, "version": "0.1.13", "framed": True,
                "core": {"id": "real-core-id", "name": HOST},
                "features": ["framed", "attach", "events", "status"], "methods": [],
            }) + b"\n")
            while True:
                header = reader.read(HEADER.size)
                if len(header) < HEADER.size:
                    return
                channel, kind, length = HEADER.unpack(header)
                payload = reader.read(length)
                self.received.append((channel, kind, payload))
                if channel != 0 or kind != 0:
                    if kind == 2:
                        return
                    continue
                request = json.loads(payload)
                if request["method"] == "server.status":
                    self.send(connection, 0, self.reply(request["id"], {
                        "core": {"id": "real-core-id", "name": HOST}, "version": "0.1.13",
                        "pid": 123, "uptime_ms": 456, "holders": [], "live": 1, "finished": 0,
                    }))
                elif request["method"] == "events.subscribe":
                    stream = (
                        line("event", {"seq": 2, "type": "created", "terminal": "t1", "data": RECORD})
                        + line("heartbeat", {"seq": 2})
                    )
                    # The first bytes beat the reply, and a line is cut across frames.
                    self.send(connection, 1, stream[:10])
                    self.send(connection, 0, self.reply(request["id"], {"seq": 1, "terminals": [RECORD], "channel": 1}))
                    self.send(connection, 1, stream[10:])
                    self.send(connection, 1, b"", kind=2)

    @staticmethod
    def reply(identifier, result) -> bytes:
        return json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}).encode()

    def send(self, connection, channel, payload, kind=0) -> None:
        self.sent.append((channel, kind, payload))
        connection.sendall(HEADER.pack(channel, kind, len(payload)) + payload)


class CaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.socket_path = str(self.base / "core.sock")
        self.core = FakeCore(self.socket_path)
        self.addCleanup(self.core.listener.close)
        self.core.start()

    def run_capture(self):
        vectors, lines = capture.capture(self.socket_path, 2.0, capture.Scrubber([USER, HOST]))
        return vectors, lines

    def test_it_speaks_the_framed_protocol_with_no_core_field(self) -> None:
        vectors, _ = self.run_capture()
        self.assertEqual(self.core.connections, 1)
        self.assertEqual(self.core.hello["params"], {"generation": 1, "framed": True})
        self.assertEqual([case["name"] for case in vectors["exchanges"]], ["server-status", "events-subscribe"])
        self.assertEqual(vectors["coreVersion"], "0.1.13")

    def test_output_holds_no_environment_user_paths_or_identity(self) -> None:
        vectors, lines = self.run_capture()
        text = json.dumps(vectors) + "\n".join(lines)
        decoded = "".join(
            bytes.fromhex(case[key]).decode(errors="replace")
            for case in vectors["exchanges"]
            for key in ("requestFrame", "replyFrame")
        )
        for output in (text, decoded):
            for forbidden in (SECRET_VALUE, USER, HOST, "real-core-id", "restart_env", '"env"', "/run/user/501"):
                self.assertNotIn(forbidden, output)
        self.assertIn("API_KEY=<scrubbed>", text)
        self.assertIn("/home/user/.local/bin/claude", text)

    def test_events_reassemble_across_frames_and_credit_comes_back(self) -> None:
        vectors, lines = self.run_capture()
        self.assertEqual([json.loads(item).get("method") for item in lines], ["event", "heartbeat"])
        self.assertEqual(len(vectors["events"]), 2)
        self.assertTrue(all("source" in case for case in vectors["events"]))
        self.core.join(timeout=5)
        credits = [struct.unpack("<I", payload)[0] for channel, kind, payload in self.core.received if channel == 1 and kind == 1]
        # Everything the core sent on the events channel earns its credit back.
        sent = sum(len(payload) for channel, kind, payload in self.core.sent if channel == 1 and kind == 0)
        self.assertEqual(sum(credits), sent)
        self.assertIn((1, 2, b""), self.core.received)

    def test_main_writes_both_files(self) -> None:
        vectors_path = self.base / "vectors.json"
        events_path = self.base / "events.ndjson"
        status = capture.main([
            "--socket", self.socket_path, "--vectors", str(vectors_path),
            "--events", str(events_path), "--seconds", "2",
        ])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(vectors_path.read_text())["provisional"], False)
        self.assertEqual(len(events_path.read_text().splitlines()), 2)

    def test_a_missing_socket_fails_without_starting_anything(self) -> None:
        status = capture.main([
            "--socket", str(self.base / "absent.sock"), "--vectors", str(self.base / "v.json"),
            "--events", str(self.base / "e.ndjson"),
        ])
        self.assertEqual(status, 1)
        self.assertFalse((self.base / "v.json").exists())
        self.assertFalse((self.base / "absent.sock").exists())


class SourceTests(unittest.TestCase):
    """The script must not be able to start a core or leak its own environment."""

    def setUp(self) -> None:
        self.tree = ast.parse(SCRIPT.read_text())

    def test_it_imports_nothing_that_starts_a_process(self) -> None:
        imported = set()
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add((node.module or "").split(".")[0])
        for forbidden in ("subprocess", "os", "pty", "multiprocessing", "shlex", "shutil"):
            self.assertNotIn(forbidden, imported)
        names = {node.attr for node in ast.walk(self.tree) if isinstance(node, ast.Attribute)}
        self.assertFalse(names & {"system", "popen", "spawn", "exec", "environ", "getenv"})

    def test_it_never_names_a_core_program_as_a_string_to_run(self) -> None:
        strings = [node.value for node in ast.walk(self.tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)]
        self.assertFalse([value for value in strings if value in ("hc", "herdr-core")])

    def test_the_only_address_it_connects_to_comes_from_its_argument(self) -> None:
        connects = [
            node for node in ast.walk(self.tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "connect"
        ]
        self.assertEqual(len(connects), 1)
        self.assertEqual(ast.unparse(connects[0].args[0]), "path")

    def test_scrubbing_covers_each_home_form(self) -> None:
        scrubber = capture.Scrubber([])
        self.assertEqual(scrubber.text("/home/bob/x"), "/home/user/x")
        self.assertEqual(scrubber.text("/Users/bob/x y"), "/Users/user/x y")
        self.assertEqual(scrubber.text("/root/x"), "/home/user/x")
        self.assertEqual(scrubber.text("/rootless"), "/rootless")
        self.assertEqual(scrubber.text("/run/user/501/herdr-core/default.sock"), "/run/user/1000/herdr-core/default.sock")
        self.assertEqual(scrubber.text(r"C:\Users\bob\x"), r"C:\Users\user\x")
        self.assertEqual(scrubber.text("TOKEN=abc def"), "TOKEN=<scrubbed> def")


if __name__ == "__main__":
    unittest.main()
