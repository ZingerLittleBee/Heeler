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
FLAG_VALUE = "flag-secret-value"
URL_PASSWORD = "url-secret-value"
QUOTED_VALUE = "quoted-secret-value"
EXPORTED_VALUE = "exported-secret-value"
SPLIT_VALUE = "split-secret-value"
USER = "alice"
HOST = "alices-laptop"

RECORD = {
    "address": "t1",
    "name": f"{USER}-review",
    "argv": [
        f"/home/{USER}/.local/bin/claude", f"--token={FLAG_VALUE}", f"API_KEY={SECRET_VALUE}",
        "--api-key", SPLIT_VALUE,
    ],
    "cwd": f"/Users/{USER}/work/project",
    # A shell's title is often the command line it is running.
    "title": f"set --export API_KEY {EXPORTED_VALUE}",
    "labels": {"workspace": f"/home/{USER}/w", "note": f"LABEL_KEY={SECRET_VALUE}"},
    "restart_env": {"API_KEY": SECRET_VALUE},
    "env": {"PATH": f"/home/{USER}/bin", "SECRET": SECRET_VALUE},
    "status": {"state": "idle", "msg": f"SETX API_KEY {EXPORTED_VALUE}", "title": f"see C:\\Users\\{USER}\\notes"},
    "state": "live",
    # A Template's foreground is `sh -c <line>`, so a whole command line lands in argv.
    "foreground": {
        "name": "fish",
        "argv": [
            "fish", "-c",
            f'http_proxy=http://u:{URL_PASSWORD}@proxy LABEL="quoted {QUOTED_VALUE}" claude; '
            f"set --export API_KEY {EXPORTED_VALUE}",
        ],
    },
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
            for forbidden in (
                SECRET_VALUE, FLAG_VALUE, URL_PASSWORD, QUOTED_VALUE, EXPORTED_VALUE, SPLIT_VALUE,
                USER, HOST, "real-core-id", "restart_env", '"env"', "/run/user/501",
            ):
                self.assertNotIn(forbidden, output)
        self.assertIn("LABEL_KEY=<scrubbed>", text)
        self.assertIn("scrubbed-review", text)

    def test_argv_keeps_only_its_program_on_every_record_shape(self) -> None:
        vectors, lines = self.run_capture()
        records = [json.loads(lines[0])["params"]["data"], vectors["exchanges"][1]["result"]["terminals"][0]]
        for record in records:
            self.assertEqual(record["argv"], ["/home/user/.local/bin/claude", *["<scrubbed>"] * 4])
            self.assertEqual(record["foreground"]["argv"], ["fish", "<scrubbed>", "<scrubbed>"])
            self.assertEqual(record["title"], "<scrubbed>")

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


class ScrubberTests(unittest.TestCase):
    def test_scrubbing_covers_each_home_form(self) -> None:
        scrubber = capture.Scrubber([])
        self.assertEqual(scrubber.text("/home/bob/x"), "/home/user/x")
        self.assertEqual(scrubber.text("/Users/bob/x"), "/Users/user/x")
        self.assertEqual(scrubber.text("/root/x"), "/home/user/x")
        self.assertEqual(scrubber.text("/rootless"), "/rootless")
        self.assertEqual(scrubber.text("/run/user/501/herdr-core/default.sock"), "/run/user/1000/herdr-core/default.sock")
        self.assertEqual(scrubber.text(r"C:\Users\bob\x"), r"C:\Users\user\x")

    def test_a_value_after_an_equals_sign_never_survives(self) -> None:
        scrubber = capture.Scrubber([])
        cases = {
            "TOKEN=abc": "TOKEN=<scrubbed>",
            "aws_secret_access_key=zz": "aws_secret_access_key=<scrubbed>",
            "http_proxy=http://u:pw@h": "http_proxy=<scrubbed>",
            "Mixed_Case=secret": "Mixed_Case=<scrubbed>",
            "PATH+=:/opt/secret": "PATH+=<scrubbed>",
            "PATH:=secret": "PATH:=<scrubbed>",
            '"KEY"=secret': '"KEY"=<scrubbed>',
            "--token=abc": "--token=<scrubbed>",
            "p\u00e4sswort=secret": "p\u00e4sswort=<scrubbed>",
        }
        for given, expected in cases.items():
            with self.subTest(given=given):
                self.assertEqual(scrubber.text(given), expected)

    def test_a_string_of_several_words_is_replaced_whole(self) -> None:
        # Each of these could set a variable in some shell, and no list of forms is complete.
        scrubber = capture.Scrubber([])
        for given in (
            "setenv API_KEY zz-secret",
            "set -gx API_KEY zz-secret",
            "set --export API_KEY zz-secret",
            "set --global --export API_KEY zz-secret; claude",
            "SETX API_KEY zz-secret",
            "setx /M API_KEY zz-secret",
            "Set-Item Env:API_KEY zz-secret",
            "New-Item -Path Env:API_KEY -Value zz-secret",
            "export API_KEY=zz-secret",
            '$env:API_KEY = "zz-secret"; claude',
            'KEY="zz-secret" claude',
            "cd /tmp && KEY=zz-secret claude",
            "claude --token zz-secret",
            "two\twords",
            "two\nlines",
            "KEY=first\nsecond",
            "non\u00a0breaking",
        ):
            with self.subTest(given=given):
                self.assertEqual(scrubber.text(given), "<scrubbed>")

    def test_argv_keeps_its_program_alone(self) -> None:
        scrubber = capture.Scrubber([])
        cases = (
            (["fish", "-c", "set --export API_KEY zz-secret; claude"], ["fish", "<scrubbed>", "<scrubbed>"]),
            (["env", "API_KEY", "zz-secret"], ["env", "<scrubbed>", "<scrubbed>"]),
            (["claude", "--token", "zz-secret"], ["claude", "<scrubbed>", "<scrubbed>"]),
            (["/home/bob/bin/claude"], ["/home/user/bin/claude"]),
            (["KEY=zz-secret", "claude"], ["KEY=<scrubbed>", "<scrubbed>"]),
            ([], []),
        )
        for given, expected in cases:
            with self.subTest(given=given):
                self.assertEqual(scrubber.value({"argv": given}), {"argv": expected})
                self.assertEqual(scrubber.value({"foreground": {"argv": given}}), {"foreground": {"argv": expected}})

    def test_a_single_word_stays_readable(self) -> None:
        scrubber = capture.Scrubber([])
        for given in ("claude", "--resume", "working", "/usr/local/bin/claude", "0.1.13", "heeler.workspace"):
            with self.subTest(given=given):
                self.assertEqual(scrubber.text(given), given)

    def test_names_are_replaced_inside_a_single_word(self) -> None:
        self.assertEqual(capture.Scrubber(["alice"]).text("alice@laptop"), "scrubbed@laptop")


class ScenarioMergeTests(unittest.TestCase):
    """The fixture scenario's rewrite of the vector file. Its capture runs against a real core."""

    @classmethod
    def setUpClass(cls) -> None:
        path = ROOT / "scripts" / "fixtures" / "herdr-core-capture-scenario.py"
        scenario_spec = importlib.util.spec_from_file_location("herdr_core_capture_scenario", path)
        assert scenario_spec and scenario_spec.loader
        cls.scenario = importlib.util.module_from_spec(scenario_spec)
        sys.modules["herdr_core_capture_scenario"] = cls.scenario
        scenario_spec.loader.exec_module(cls.scenario)

    def old(self) -> dict:
        return {
            "description": "old", "provisional": True, "coreVersion": "0.1.13", "coreCommit": "abc",
            "hello": {"name": "hello", "source": "source review", "reply": "old"},
            "frames": [{"name": "kept-frame", "source": "x.rs", "bytes": "00"}, {"name": "new-frame", "source": "x.rs", "bytes": "00"}],
            "exchanges": [], "errors": [],
            "events": [{"name": "only-by-hand", "source": "y.rs", "line": "old"}], "eventFrames": [],
        }

    def captured(self) -> dict:
        return {
            "hello": {"name": "hello", "source": "captured", "reply": "new"},
            "frames": [{"name": "new-frame", "source": "captured", "bytes": "01"}],
            "exchanges": [], "errors": [], "events": [{"name": "added", "source": "captured", "line": "l"}], "eventFrames": [],
        }

    def test_captured_cases_replace_those_of_their_name_and_the_rest_are_listed(self) -> None:
        merged = self.scenario.merge(self.old(), self.captured(), "0.1.13")
        self.assertFalse(merged["provisional"])
        self.assertEqual(merged["hello"]["reply"], "new")
        self.assertEqual([case["bytes"] for case in merged["frames"]], ["00", "01"])
        self.assertEqual(merged["notCaptured"], ["kept-frame", "only-by-hand"])
        self.assertEqual([case["name"] for case in merged["events"]], ["only-by-hand", "added"])
        self.assertEqual(merged["coreCommit"], "abc")

    def test_the_scenario_runs_no_hc_and_starts_only_through_the_fixture(self) -> None:
        source = (ROOT / "scripts" / "fixtures" / "herdr-core-capture-scenario.py").read_text()
        self.assertEqual(ast.parse(source).__class__, ast.Module)
        self.assertNotIn("subprocess", source)
        self.assertIn("fixture.start_core(root, SESSION", source)


if __name__ == "__main__":
    unittest.main()
