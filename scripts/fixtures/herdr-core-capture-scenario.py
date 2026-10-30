#!/usr/bin/env python3
"""Capture the shared frame vectors from a disposable fixture core.

Drives a fixture core through inert Terminals this script starts, so every event
and frame in plugin/test-vectors/herdr-core-frames-v1.json has a real capture
behind it, and rebuilds them with the capture script's scrubber:

    python3 scripts/fixtures/herdr-core-ssh.py start --root /tmp/hc-capture --core <path>
    python3 scripts/fixtures/herdr-core-capture-scenario.py --root /tmp/hc-capture \\
        --vectors plugin/test-vectors/herdr-core-frames-v1.json
    python3 scripts/fixtures/herdr-core-ssh.py stop --root /tmp/hc-capture

Unlike the capture script, which only listens on a lab core, this attaches to
Terminals: only its own, whose programs print nothing but what it tells them to.
It refuses a root the fixture did not create, and starts the core itself. A case
in the file that this run did not capture refuses the whole file, so nothing keeps
an old source by accident: to retire a case, delete it first. Read the output
before committing it.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import importlib.util
import json
import os
from pathlib import Path
import re
import socket as socketlib
import struct
import sys
import time

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


capture = load("herdr_core_capture", HERE.parent / "lab/herdr-core-capture.py")
fixture = load("herdr_core_ssh_fixture", HERE / "herdr-core-ssh.py")

DATA, CREDIT, CLOSE, RESIZE, FOCUS, FACTS = 0, 1, 2, 3, 4, 5
SESSION = "capture"
WINDOW = 256 * 1024
# A heartbeat every 15 seconds would make this wait; nothing here depends on its rate.
EXTRA_ENVIRONMENT = {"HC_HEARTBEAT_MS": "1000"}
TEMPLATE_NAME = "reviewer"
# Its body is empty, so a run sends no first message and waits for no agent.
TEMPLATE = """---
description: An inert program
command: {command}
submit: enter
stop: esc
paste_gap_ms: 120
---
"""
LARGEST = 65535
INERT_PROGRAM = r"""#!/usr/bin/env python3
import os, signal, sys, time, tty
tty.setraw(0)
sys.stdout.write("ready\\r\\n")
sys.stdout.flush()
pending = bytearray()
while True:
    byte = os.read(0, 1)
    if not byte:
        break
    if byte not in (b"\r", b"\n"):
        pending.extend(byte)
        continue
    word, _, value = pending.decode().partition(":")
    pending.clear()
    if word == "print":
        sys.stdout.write(value + "\r\n")
    elif word == "title":
        sys.stdout.write("\033]2;" + value + "\007")
    elif word == "osc":
        sys.stdout.write("\033]7501;" + value + "\007")
    elif word == "exit":
        sys.stdout.flush()
        os._exit(int(value))
    elif word == "orphan-foreground":
        # The foreground group's leader goes and a member keeps the group alive,
        # so the core finds a group with no leader to read. This program is then
        # in the background: reading the tty would stop it, so it waits to be killed.
        ready_read, ready_write = os.pipe()
        leader = os.fork()
        if leader == 0:
            os.close(ready_write)
            os.setpgid(0, 0)
            os.read(ready_read, 1)
            if os.fork() == 0:
                time.sleep(60)
            os._exit(0)
        os.setpgid(leader, leader)
        os.tcsetpgrp(0, leader)
        os.close(ready_write)
        os.waitpid(leader, 0)
        signal.pause()
    sys.stdout.flush()
"""


class ScenarioError(Exception):
    pass


class Driver:
    """One framed connection: calls on channel 0, a line stream on the events
    channel, and whatever else arrives kept in order."""

    def __init__(self, path, clean):
        self.connection = capture.Connection(path, timeout=20.0)
        self.clean = clean
        self.next_id = 100
        self.events_channel = None
        self.holding_credit = False
        self.stream = bytearray()
        self.lines = []
        self.event_frames = []
        self.event_bytes = 0
        self.frames = []

    def send(self, channel, kind, payload=b""):
        self.connection.send(capture.frame(channel, kind, payload))

    def pump(self):
        channel, kind, payload = self.connection.read_frame()
        self.frames.append((channel, kind, payload))
        if channel == self.events_channel and kind == DATA:
            self.event_frames.append(payload)
            self.event_bytes += len(payload)
            self.stream += payload
            *complete, rest = bytes(self.stream).split(b"\n")
            self.stream = bytearray(rest)
            self.lines += [json.loads(line) for line in complete if line.strip()]
            if not self.holding_credit:
                self.send(channel, CREDIT, struct.pack("<I", len(payload)))
        return channel, kind, payload

    def call(self, method, params=None, identifier=None):
        identifier = identifier or str(self.next_id)
        self.next_id += 1
        params = params if params is not None else {}
        self.send(0, DATA, capture.request(identifier, method, params))
        while True:
            channel, _, payload = self.pump()
            if channel == 0:
                reply = json.loads(payload)
                if reply.get("id") == identifier:
                    return reply, payload

    def result(self, method, params=None):
        reply, _ = self.call(method, params)
        if "result" not in reply:
            raise ScenarioError(f"{method} failed: {reply.get('error')}")
        return reply["result"]

    def wait(self, predicate, seconds=15.0):
        """Reads frames until the predicate holds; nothing is slept away."""
        deadline = time.monotonic() + seconds
        while True:
            found = predicate()
            if found:
                return found
            if time.monotonic() >= deadline:
                raise ScenarioError(f"timed out waiting for {getattr(predicate, 'what', 'a frame')}")
            if self.connection.has_input(0.05):
                self.pump()

    def event(self, kind, terminal=None, seconds=15.0, matching=lambda data: True, after=0):
        """The first such event, its `data` matching, past the first `after` lines."""
        def find():
            for line in self.lines[after:]:
                params = line.get("params", {})
                if params.get("type") == kind and (terminal is None or params.get("terminal") == terminal) \
                        and matching(params.get("data") or {}):
                    return line
            return None

        find.what = f"a {kind} event on {terminal}"
        return self.wait(find, seconds)

    def stream_frame(self, channel, matching, seconds=15.0):
        def find():
            for frame in self.frames:
                if frame[0] == channel and matching(frame):
                    return frame
            return None

        find.what = f"a frame on channel {channel}"
        return self.wait(find, seconds)


def selected(name, how, line):
    """A selection the run saw. Nothing here is optional: a miss is a failed run."""
    if line is None:
        raise ScenarioError(f"the run never saw a {name} event")
    return name, how, line


def plain_line(path, method, params, identifier="1"):
    """A reply on a connection that never switched to frames."""
    connection = capture.Connection(path, timeout=10.0)
    try:
        connection.send((capture.compact(json.loads(capture.request(identifier, method, params))) + "\n").encode())
        return connection.read_line()
    finally:
        connection.close()


def run_scenario(root, version_source):
    state = fixture.backend.load_state(root)
    started = fixture.start_core(root, SESSION, extra=EXTRA_ENVIRONMENT)
    if started.returncode:
        raise ScenarioError(f"the fixture core did not start: {started.stderr.decode(errors='replace')}")
    socket_path = (fixture.state_root(root) / SESSION / "core.lock").read_text()
    program = root / "bin/heeler-inert"
    program.write_text(INERT_PROGRAM)
    program.chmod(0o700)
    home = str(root / "home")
    templates = root / "home/.config/herdr-core/templates"
    templates.mkdir(parents=True, exist_ok=True)
    (templates / f"{TEMPLATE_NAME}.md").write_text(TEMPLATE.format(command=program))

    prefixes = [(f"{root}/bin", "/usr/local/bin"), (f"{root}/home", "/home/user")]

    def scrub_text(raw: bytes) -> bytes:
        text = raw.decode()
        for prefix, replacement in prefixes:
            text = text.replace(prefix, replacement)
        # The interpreter's real path, wherever it is installed, says nothing useful.
        return re.sub(r'"/[^"]*/Python"', '"/usr/local/bin/python3"', text).encode()

    scrubber = capture.Scrubber([getpass.getuser(), socketlib.gethostname().split(".")[0]])

    def clean_line(raw: bytes) -> str:
        return capture.compact(scrubber.value(json.loads(scrub_text(raw))))

    def clean_json(value) -> str:
        return clean_line(capture.compact(value).encode())

    def source(how):
        return f"captured from herdr-core {version_source} by scripts/fixtures/herdr-core-capture-scenario.py: {how}"

    def frame_case(name, how, channel, kind, payload):
        return {"name": name, "source": source(how), "bytes": capture.frame(channel, kind, payload).hex()}

    cases = {"frames": [], "exchanges": [], "errors": [], "events": [], "eventFrames": []}
    driver = Driver(socket_path, clean_line)
    hello = {"jsonrpc": "2.0", "id": "hello", "method": "hello", "params": {"generation": 1, "framed": True}}
    driver.connection.send((capture.compact(hello) + "\n").encode())
    hello_raw = driver.connection.read_line()
    cases["hello"] = {"name": "hello", "source": source("the plain hello reply"), "reply": clean_line(hello_raw)}

    def exchange(name, how, method, params, reply_bytes, identifier):
        clean_reply = clean_line(reply_bytes)
        cases["exchanges"].append({
            "name": name, "source": source(how), "method": method, "params": params,
            "result": json.loads(clean_reply).get("result"),
            "requestFrame": capture.frame(0, DATA, capture.request(identifier, method, params)).hex(),
            "replyFrame": capture.frame(0, DATA, clean_reply.encode()).hex(),
        })

    # One live and one finished Terminal, for the subscribe snapshot.
    first = driver.result("terminal.run", {"argv": [str(program)], "cwd": home, "name": "live"})
    live = first["terminal"]["address"] if "terminal" in first else first["address"]
    done = driver.result("terminal.run", {"argv": ["/bin/sh", "-c", "exit 0"], "cwd": home})
    done_address = done["terminal"]["address"] if "terminal" in done else done["address"]

    def finished():
        return driver.result("terminal.get", {"terminal": done_address}).get("state") == "finished"

    finished.what = "the short Terminal to finish"
    driver.wait(finished)
    _, raw = driver.call("server.status", {}, identifier="1")
    exchange("server-status", "a server.status exchange with one live and one finished Terminal",
             "server.status", {}, raw, "1")

    reply, raw = driver.call("events.subscribe", {}, identifier="2")
    if "result" not in reply:
        raise ScenarioError(f"events.subscribe failed: {reply}")
    exchange("events-subscribe", "a subscribe with one live and one finished Terminal", "events.subscribe", {}, raw, "2")
    driver.events_channel = reply["result"]["channel"]

    # An attached Terminal with a name, labels and keep.
    run = driver.result("terminal.run", {
        "argv": [str(program)], "cwd": home, "name": "review", "keep": True,
        "labels": {"heeler.workspace": "w1"},
    })
    target = run["terminal"]["address"] if "terminal" in run else run["address"]
    pid = driver.event("created", target)["params"]["data"].get("pid")
    if not isinstance(pid, int):
        raise ScenarioError("a created event named no pid")

    attach_params = {"terminal": target, "cols": 80, "rows": 24, "observe": False}
    reply, raw = driver.call("terminal.attach", attach_params, identifier="3")
    if "result" not in reply:
        raise ScenarioError(f"terminal.attach failed: {reply}")
    exchange("terminal-attach", "an attach to an inert Terminal", "terminal.attach", attach_params, raw, "3")
    channel = reply["result"]["channel"]

    def type_line(text):
        driver.send(channel, DATA, text.encode() + b"\r")

    # Typed before the program is raw, a line would be echoed and then flushed.
    driver.stream_frame(channel, lambda f: f[1] == DATA and b"ready" in f[2])

    # Frames the core sends on an attach channel.
    mark = len(driver.frames)
    type_line("print:hello")
    _, _, printed = driver.stream_frame(
        channel, lambda f: f[1] == DATA and b"hello" in f[2] and f in driver.frames[mark:])
    cases["frames"].append(frame_case("data-attach-raw-bytes", "an attach channel's bytes from an inert program",
                                      channel, DATA, printed))

    # Frames a client sends: each one sent to the core, which acted on it.
    driver.send(channel, CREDIT, struct.pack("<I", WINDOW))
    cases["frames"].append(frame_case("credit-256-kib", "sent to the core, which kept the channel open",
                                      channel, CREDIT, struct.pack("<I", WINDOW)))
    resize = struct.pack("<HH", 100, 30)
    driver.send(channel, RESIZE, resize)
    driver.event("size", target, matching=lambda data: data.get("cols") == 100)
    resize = struct.pack("<HH", 80, 24)
    driver.send(channel, RESIZE, resize)
    driver.event("size", target, matching=lambda data: data.get("cols") == 80)
    cases["frames"].append(frame_case("resize-80x24", "sent to the core, which reported the new size",
                                      channel, RESIZE, resize))
    for name, value in (("focus-lost", b"\x00"), ("focus-gained", b"\x01")):
        driver.send(channel, FOCUS, value)
        driver.result("server.status", {})
        cases["frames"].append(frame_case(name, "sent to the core, which kept the channel open", channel, FOCUS, value))

    facts = capture.compact({"fg": "#ffffff", "bg": "#000000", "cursor": "#ff0000", "cell": [10, 20]}).encode()
    driver.send(channel, FACTS, facts)
    driver.result("server.status", {})
    cases["frames"].append(frame_case("facts", "sent to the core, which kept the channel open", channel, FACTS, facts))

    # Facts a program reports.
    type_line("title:Working")
    driver.event("title", target)
    type_line("osc:state=working:app=claude-code:progress=10")
    driver.event("status", target, matching=lambda data: (data.get("status") or {}).get("state") == "working")
    type_line("osc:state=done:app=claude-code")
    driver.event("turn", target, matching=lambda data: data.get("state") == "done")
    mark = len(driver.lines)
    type_line("osc:state=working:app=claude-code")
    driver.event("status", target, matching=lambda data: (data.get("status") or {}).get("state") == "working",
                 after=mark)
    mark = len(driver.lines)
    type_line("osc:state=clear")
    driver.event("status", target, matching=lambda data: data.get("status") is None, after=mark)
    driver.event("turn", target, matching=lambda data: data.get("state") is None, after=mark)

    # Facts a client changes.
    driver.result("terminal.label", {"terminal": target, "labels": {"heeler.workspace": "w2"}})
    driver.event("labels", target)
    driver.result("terminal.keep", {"terminal": target, "keep": False})
    driver.event("keep", target, matching=lambda data: data.get("keep") is False)
    driver.result("terminal.keep", {"terminal": target, "keep": True})
    driver.event("keep", target, matching=lambda data: data.get("keep") is True)
    reply, raw = driver.call("doc.set", {"name": "herdr-app-layout", "value": {"v": 1}, "version": 0})
    cases["frames"].append(frame_case("data-channel-0-reply", "a doc.set reply", 0, DATA, clean_line(raw).encode()))
    driver.event("doc")

    # The client ends one attachment, and a program's exit ends another.
    driver.send(channel, CLOSE)
    driver.stream_frame(channel, lambda f: f[1] == CLOSE)
    cases["frames"].append(frame_case("close-from-client", "sent to the core, which answered with its own CLOSE",
                                      channel, CLOSE, b""))
    gone = driver.result("terminal.run", {"argv": [str(program)], "cwd": home})
    gone_address = gone["terminal"]["address"] if "terminal" in gone else gone["address"]
    reply, _ = driver.call("terminal.attach", {"terminal": gone_address, "cols": 80, "rows": 24, "observe": False})
    gone_channel = reply["result"]["channel"]
    driver.stream_frame(gone_channel, lambda f: f[1] == DATA and b"ready" in f[2])
    driver.send(gone_channel, DATA, b"exit:0\r")
    _, _, ended = driver.stream_frame(gone_channel, lambda f: f[1] == CLOSE)
    cases["frames"].append(frame_case("close-program-ended", "the core's CLOSE when an attached program exited",
                                      gone_channel, CLOSE, ended))
    driver.event("finished", gone_address)
    driver.result("terminal.rm", {"terminal": gone_address})
    driver.event("removed", gone_address)

    # A kept Terminal loses its program and gets a shell.
    os.kill(pid, 9)
    driver.event("lost", target)
    driver.event("restarted", target)
    driver.wait(lambda: next((line for line in driver.lines if line.get("method") == "heartbeat"), None))

    # The largest size the frame can name, on a Terminal of its own: its screen takes
    # seconds to shrink back.
    big = driver.result("terminal.run", {"argv": [str(program)], "cwd": home})
    big_address = big["terminal"]["address"] if "terminal" in big else big["address"]
    reply, _ = driver.call("terminal.attach", {"terminal": big_address, "cols": 80, "rows": 24, "observe": False})
    big_channel = reply["result"]["channel"]
    driver.stream_frame(big_channel, lambda f: f[1] == DATA and b"ready" in f[2])
    largest = struct.pack("<HH", LARGEST, LARGEST)
    driver.send(big_channel, RESIZE, largest)
    driver.event("size", big_address, seconds=60, matching=lambda data: data.get("cols") == LARGEST)
    cases["frames"].append(frame_case("resize-largest", "sent to the core, which reported the new size",
                                      big_channel, RESIZE, largest))
    driver.send(big_channel, CLOSE)
    driver.stream_frame(big_channel, lambda f: f[1] == CLOSE, seconds=60)
    driver.result("terminal.kill", {"terminal": big_address})
    driver.event("finished", big_address, seconds=30)
    driver.result("terminal.rm", {"terminal": big_address})

    # A foreground group whose leader is gone: the watcher reports none.
    orphan = driver.result("terminal.run", {"argv": [str(program)], "cwd": home})
    orphan_address = orphan["terminal"]["address"] if "terminal" in orphan else orphan["address"]
    # The field starts empty, so a cleared one only shows after a first report.
    driver.event("foreground", orphan_address, matching=lambda data: "pid" in data)
    reply, _ = driver.call("terminal.attach", {"terminal": orphan_address, "cols": 80, "rows": 24, "observe": False})
    orphan_channel = reply["result"]["channel"]
    driver.stream_frame(orphan_channel, lambda f: f[1] == DATA and b"ready" in f[2])
    driver.send(orphan_channel, DATA, b"orphan-foreground:\r")
    driver.event("foreground", orphan_address, matching=lambda data: data == {})
    driver.result("terminal.kill", {"terminal": orphan_address})
    driver.event("finished", orphan_address, seconds=30)

    # A family for the `missed` snapshot. A wait on all children holds while one is
    # busy, and while it holds a killed `rm` child stays in the record; a report from
    # the child started from a template fills in every field a live record has.
    parent = driver.result("terminal.run", {"argv": [str(program)], "cwd": home, "name": "parent"})
    parent_address = parent["terminal"]["address"] if "terminal" in parent else parent["address"]
    killed = driver.result("terminal.run", {
        "argv": [str(program)], "cwd": home, "name": "killed-child", "parent": parent_address, "rm": True,
    })
    killed_address = killed["terminal"]["address"] if "terminal" in killed else killed["address"]
    driver.result("terminal.run", {"argv": [str(program)], "cwd": home, "name": "busy-child", "parent": parent_address})
    full = driver.result("terminal.run", {
        "argv": [TEMPLATE_NAME], "cwd": home, "name": "full-record", "parent": parent_address,
        "labels": {"heeler.workspace": "w1"}, "keep": True,
    })
    full_address = full["terminal"]["address"] if "terminal" in full else full["address"]
    reply, _ = driver.call("terminal.attach", {"terminal": full_address, "cols": 80, "rows": 24, "observe": False})
    full_channel = reply["result"]["channel"]
    driver.stream_frame(full_channel, lambda f: f[1] == DATA and b"ready" in f[2])
    driver.send(full_channel, DATA, b"title:Reviewing\r")
    driver.event("title", full_address)
    driver.send(full_channel, DATA, b"osc:state=working:app=claude-code\r")
    driver.event("status", full_address, matching=lambda data: (data.get("status") or {}).get("state") == "working")
    driver.send(full_channel, DATA, b"osc:state=working:id=child:app=claude-code\r")
    driver.event("status", full_address, matching=lambda data: "child" in data.get("records", {}))
    report = ("osc:state=blocked:kind=permission:progress=40:app=claude-code"
              f":title={base64.b64encode(b'Reviewing').decode()}:msg={base64.b64encode(b'Allow').decode()}\r")
    driver.send(full_channel, DATA, report.encode())
    driver.event("status", full_address, matching=lambda data: (data.get("status") or {}).get("state") == "blocked")
    driver.event("foreground", full_address, matching=lambda data: "pid" in data)
    driver.send(full_channel, CLOSE)
    driver.stream_frame(full_channel, lambda f: f[1] == CLOSE)
    # Sent and never read back: it ends with this connection. Its reply matches no call.
    driver.send(0, DATA, capture.request("family-wait", "terminal.wait",
                                         {"children": "all", "caller": parent_address, "timeout": 600}))
    driver.result("server.status", {})
    driver.result("terminal.kill", {"terminal": killed_address})
    driver.event("finished", killed_address, seconds=30)
    kept = driver.call("terminal.get", {"terminal": killed_address})[0].get("result") or {}
    if not kept.get("rm") or kept.get("reason") != "killed":
        raise ScenarioError(f"the wait did not hold the killed child: {kept}")

    # Errors, each in the shape its caller meets it.
    cases["errors"].append({"name": "unknown-method", "source": source("a plain request for a method no core has"),
                            "kind": "unknown_method",
                            "line": clean_line(plain_line(socket_path, "no.such.method", {}))})
    cases["errors"].append({"name": "needs-framed", "source": source("an attach on a plain connection"),
                            "kind": "needs_framed",
                            "line": clean_line(plain_line(socket_path, "terminal.attach",
                                                          {"terminal": live, "cols": 80, "rows": 24}))})
    cases["errors"].append({"name": "unsupported-generation", "source": source("a hello for a generation no core has"),
                            "kind": "unsupported_generation",
                            "line": clean_line(plain_line(socket_path, "hello", {"generation": 99}))})
    reply, raw = driver.call("terminal.attach",
                             {"terminal": live, "cols": 80, "rows": 24, "caller": live}, identifier="1")
    cases["errors"].append({"name": "domain-error", "source": source("an attach from the Terminal itself"),
                            "kind": "refused", "line": clean_line(raw)})

    # Credit: one line cut at its edge, then two lines in one frame, then a backlog
    # past what the core keeps, which it replaces with `missed`.
    driver.holding_credit = True
    held_from = driver.event_bytes
    index = 0

    def flood(value=None):
        nonlocal index
        driver.result("terminal.label", {"terminal": live, "labels": {"f": value or f"{index:06d}"}})
        index += 1

    def drain():
        while driver.connection.has_input(0.2):
            driver.pump()

    while driver.event_bytes - held_from < WINDOW - 2048:
        flood()
        if index > 20000:
            raise ScenarioError("the events window never ran out")
    for _ in range(100):
        flood()
    drain()
    # Lines are this long unless a heartbeat falls among them, so a guess that misses
    # leaves the stream at another cut, and the next one lands.
    whole = [len(frame) for frame in driver.event_frames[-50:] if frame.count(b"\n") == 1 and frame.endswith(b"\n")]
    length = max(set(whole), key=whole.count)

    def release(count):
        seen = len(driver.event_frames)
        driver.send(driver.events_channel, CREDIT, struct.pack("<I", count))
        driver.wait(lambda: len(driver.event_frames) > seen)
        return driver.event_frames[-1]

    across = together = None
    for _ in range(40):
        if across and together:
            break
        start, partial = driver.event_frames[-1], len(driver.stream)
        if partial:
            frame = release(length - partial)
            if not driver.stream and frame.count(b"\n") == 1 and partial == len(start):
                across = (start, frame)
        elif across:
            frame = release(2 * length)
            if not driver.stream and frame.count(b"\n") == 2:
                together = frame
        else:
            release(length // 2)
    if across:
        cases["eventFrames"].append({
            "name": "one-line-across-two-frames", "source": source("an event line cut at the credit edge"),
            "bytes": b"".join(capture.frame(driver.events_channel, DATA, part) for part in across).hex(),
            "lines": 1,
        })
    if together:
        cases["eventFrames"].append({
            "name": "two-lines-in-one-frame", "source": source("two event lines the credit released together"),
            "bytes": capture.frame(driver.events_channel, DATA, together).hex(),
            "lines": 2,
        })
    # Past the 4 MiB the core keeps. Long labels get there quickly, and the padding
    # says nothing, so what the snapshot keeps of it is scrubbed.
    padding = "x" * (16 * 1024)
    for _ in range(320):
        flood(padding)
    driver.holding_credit = False
    driver.send(driver.events_channel, CREDIT, struct.pack("<I", 16 * 1024 * 1024))
    driver.wait(lambda: next((line for line in driver.lines if line.get("method") == "missed"), None))
    missed = next(line for line in driver.lines if line.get("method") == "missed")
    for record in missed["params"]["terminals"]:
        if record["labels"].get("f") == padding:
            record["labels"]["f"] = capture.SCRUBBED

    def line_case(name, how, line):
        cases["events"].append({"name": name, "source": source(how), "line": clean_json(line) + "\n"})

    def first(kind, matching=lambda line: True, terminal=target):
        for line in driver.lines:
            params = line.get("params", {})
            if params.get("type") == kind and (terminal is None or params.get("terminal") == terminal) \
                    and matching(params.get("data")):
                return line
        return None

    selections = [
        ("created", "a Terminal started with a name, labels and keep", first("created")),
        ("created-from-template", "a Terminal started from a template, with a parent",
         first("created", terminal=full_address)),
        ("size", "a RESIZE frame", first("size", lambda data: data.get("cols") == 100)),
        ("title", "an inert program's OSC 2", first("title")),
        ("foreground", "the core's foreground watcher", first("foreground", lambda data: data is not None)),
        ("foreground-cleared", "a foreground process group whose leader exited",
         first("foreground", lambda data: data is None, terminal=orphan_address)),
        ("status", "an inert program's OSC 7501",
         first("status", lambda data: (data.get("status") or {}).get("progress") == 10)),
        ("status-cleared", "an inert program's OSC 7501 state=clear",
         first("status", lambda data: data.get("status") is None)),
        ("turn", "a working program reporting done", first("turn", lambda data: data.get("state") == "done")),
        ("turn-cleared", "a working program clearing its status",
         first("turn", lambda data: data.get("state") is None)),
        ("labels", "terminal.label", first("labels")),
        ("keep", "terminal.keep", first("keep", lambda data: data.get("keep") is False)),
        ("doc", "doc.set", first("doc", terminal=None)),
        ("lost", "a kept program killed by SIGKILL", first("lost")),
        ("restarted", "a kept program's replacement shell", first("restarted")),
        ("finished", "an attached program's exit", first("finished", terminal=gone_address)),
        ("removed", "terminal.rm", first("removed", terminal=gone_address)),
        ("heartbeat", "the events channel's heartbeat, every second by HC_HEARTBEAT_MS",
         next((line for line in driver.lines if line.get("method") == "heartbeat"), None)),
        ("missed", "a backlog past the core's limit with credit withheld, with a killed rm child a parent's wait "
                   "holds and a templated child with every field a live record has", missed),
    ]
    for name, how, line in selections:
        line_case(*selected(name, how, line))
    driver.result("server.status", {})
    driver.connection.close()
    return cases


def merge(old, cases, version):
    """The new file: captured cases replace those of the same name, new ones follow.
    Every case has to come from this run; any other refuses the whole file."""
    captured_names = {"hello"}
    merged = dict(old)
    merged["hello"] = cases["hello"]
    missing = []
    for section in ("frames", "exchanges", "errors", "events", "eventFrames"):
        by_name = {case["name"]: case for case in cases[section]}
        captured_names |= set(by_name)
        missing += [case["name"] for case in old[section] if case["name"] not in by_name]
        kept = [by_name.pop(case["name"]) for case in old[section] if case["name"] in by_name]
        merged[section] = kept + list(by_name.values())
    if missing:
        raise ScenarioError(f"this run did not capture {', '.join(missing)}; re-run, or delete a retired case first")
    merged["provisional"] = False
    merged["coreVersion"] = version
    merged["description"] = (
        "Shared herdr-core framed protocol vectors: frames, the hello line, channel-0 exchanges and event lines. "
        "Swift reads them now and the Host Helper reads them later. Captured from a fixture core and scrubbed by "
        "scripts/fixtures/herdr-core-capture-scenario.py; every case names its capture. Hex strings hold exact "
        "bytes; a frame is channel (u32 LE), kind (u8) and length (u32 LE) before its payload."
    )
    return merged


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, type=Path, help="a root the fixture's start created")
    parser.add_argument("--vectors", required=True, type=Path, help="the vector file to rewrite")
    args = parser.parse_args()
    root = args.root.resolve()
    old = json.loads(args.vectors.read_text())
    cases = run_scenario(root, old["coreVersion"])
    args.vectors.write_text(json.dumps(merge(old, cases, old["coreVersion"]), indent=2, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
