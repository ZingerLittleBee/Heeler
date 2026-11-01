#!/usr/bin/env python3
"""Test the lab check's steps and safety rules with a scripted box, without one."""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("herdr_core_lab_check", SCRIPTS / "lab/herdr-core-lab-check.py")
assert spec and spec.loader
lab_check = importlib.util.module_from_spec(spec)
sys.modules["herdr_core_lab_check"] = lab_check
spec.loader.exec_module(lab_check)


def frame_hex(payload: bytes) -> str:
    return (lab_check.HEADER.pack(0, 0, len(payload)) + payload).hex()


VECTORS = {
    "exchanges": [{"name": "server-status", "requestFrame": frame_hex(b'{"id":"1"}'), "replyFrame": frame_hex(b'{"id":"1","result":{}}')}],
    "events": [{"name": "created", "line": '{"method":"event"}\n'}],
}


class ScriptedBox:
    def __init__(self, fail_on=None):
        self.commands = []
        self.local = []
        self.fail_on = fail_on
        self.terminated = False
        self.sessions = set()
        # Sessions someone else starts on the box while the end-to-end methods run.
        self.appearing = set()
        self.test_session = None

    def run(self, command):
        self.commands.append(command)
        if self.fail_on and self.fail_on in command:
            return 1, ""
        if command.startswith('printf "%s\\n"'):
            return 0, "/home/lab\n1000\nlab\n"
        if "--version" in command:
            return 0, "hc 0.1.13\n"
        if "herdr-core 2>/dev/null" in command or command.startswith("ls "):
            return 0, " ".join(sorted(self.sessions))
        if "server start" in command:
            self.sessions.add(re.search(r"HC_SESSION=([\w-]+)", command).group(1))
        if "list-units" in command:
            return 0, "hc-serve-1234.service\nhc-hold-5678.scope\n"
        if "show-user" in command:
            return 0, "Linger=yes\n"
        if command.startswith("cat "):
            return 0, json.dumps(VECTORS)
        return 0, ""

    def run_local(self, command):
        self.local.append(command)
        if command[0] == "ssh-keygen":
            path = Path(command[command.index("-f") + 1])
            path.write_text("private")
            path.with_name("key.pub").write_text("ssh-ed25519 AAAA heeler-lab\n")
        if "setenv" in command:
            config = json.loads(base64.b64decode(command[-1]))
            self.test_session = config["sessionPrefix"] + "abcd"
        if command[:2] == ["make", "test-app"]:
            self.sessions |= self.appearing | {self.test_session}
            if self.fail_on == "make":
                return 65
        return 0

    def spawn(self, command):
        self.local.append(command)

        class Child:
            terminate = lambda _: setattr(self, "terminated", True)

        return Child()


class LabCheckTests(unittest.TestCase):
    def perform(self, box):
        with tempfile.TemporaryDirectory() as directory:
            lab = lab_check.Lab("hc-lab", 47430, "UDID", run=box.run, local=box.run_local, spawn=box.spawn,
                                wait_for_port=lambda port: True, out=Path(directory))
            original = lab_check.load_keys
            lab_check.load_keys = lambda: type("Keys", (), {"seed": staticmethod(lambda path: bytes(32))})
            self.addCleanup(setattr, lab_check, "load_keys", original)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                status = lab.perform()
            return lab, status, output.getvalue()

    def test_a_full_run_passes_and_undoes_everything(self):
        box = ScriptedBox()
        lab, status, output = self.perform(box)
        self.assertEqual(status, 0, output)
        for name in ("an hc-serve unit", "an hc-hold unit", "linger", "the ten end-to-end methods",
                     "captured frames replay unchanged"):
            self.assertIn(f"PASS {name}", output)
        everything = "\n".join(box.commands)
        self.assertIn(f"/run/user/1000/herdr-core/{lab.session}.sock", everything)
        self.assertIn(f"HC_SESSION={lab.session}", everything)
        self.assertTrue(box.terminated, "the port-forward must end")
        self.assertIn(f"sed -i /{lab.marker}/d /home/lab/.ssh/authorized_keys", everything)
        self.assertIn(f"rm -rf /home/lab/.cache/{lab.marker}", everything)
        self.assertIn(["xcrun", "simctl", "spawn", "UDID", "launchctl", "unsetenv", "HEELER_SSH_E2E_CONFIG"], box.local)

    def test_it_never_runs_hc_or_pkill_and_stops_by_absolute_path(self):
        box = ScriptedBox()
        self.perform(box)
        for command in box.commands:
            self.assertNotIn("pkill", command)
            self.assertIsNone(re.search(r"(^|[\s/;&|])hc\s", command), command)
        stops = [command for command in box.commands if "server stop" in command]
        self.assertTrue(stops)
        for command in box.commands:
            if "server start" in command or "server stop" in command:
                self.assertIn("/home/lab/.local/bin/herdr-core server", command)
                self.assertTrue(command.startswith("env -i "), command)
                # Its own, or the session of a method of the suite it ran.
                self.assertRegex(command, r"HC_SESSION=hl?[0-9a-f]{8}")

    def test_it_stops_only_sessions_it_found_new(self):
        box = ScriptedBox()
        box.sessions = {"default", "users-own"}
        self.perform(box)
        everything = "\n".join(box.commands)
        self.assertNotIn("HC_SESSION=default", everything)
        self.assertNotIn("HC_SESSION=users-own", everything)
        self.assertNotIn("herdr-core/default", everything)

    def test_a_session_someone_else_starts_during_the_run_stays_theirs(self):
        box = ScriptedBox()
        # The last two have the shapes this script and the suite use, as another run's would.
        box.appearing = {"default", "users-own", "h1234abcd", "hl1234abcd"}
        lab, _, _ = self.perform(box)
        everything = "\n".join(box.commands)
        for session in sorted(box.appearing):
            self.assertNotIn(f"HC_SESSION={session}", everything)
            self.assertNotIn(f"herdr-core/{session}", everything)
        for session in (lab.session, box.test_session):
            self.assertIn(f"HC_SESSION={session}", everything)
            self.assertIn(f"rm -rf /home/lab/.local/state/herdr-core/{session}", everything)

    def test_failures_still_clean_up_and_fail_the_check(self):
        for fail_on in ("make", "list-units", "--version"):
            with self.subTest(fail_on=fail_on):
                box = ScriptedBox(fail_on=fail_on)
                _, status, output = self.perform(box)
                self.assertEqual(status, 1, output)
                self.assertIn("FAIL", output)
                everything = "\n".join(box.commands)
                if fail_on == "--version":
                    # It failed before it wrote anything.
                    self.assertNotIn("mkdir", everything)
                    self.assertNotIn("authorized_keys", everything)
                else:
                    self.assertIn("rm -rf /home/lab/.cache/heeler-lab-", everything)
                    self.assertTrue(box.terminated)
                    self.assertIn("/d /home/lab/.ssh/authorized_keys", everything)

    def test_the_configuration_has_what_the_suite_decodes(self):
        box = ScriptedBox()
        lab, _, _ = self.perform(box)
        setenv = next(c for c in box.local if "setenv" in c)
        config = json.loads(base64.b64decode(setenv[-1]))
        self.assertEqual(config["coreExecutable"], "/home/lab/.local/bin/herdr-core")
        self.assertEqual(config["port"], 47430)
        self.assertEqual(config["startEnvironment"]["XDG_RUNTIME_DIR"], "/run/user/1000")
        self.assertNotIn("HC_SESSION", config["startEnvironment"])
        self.assertTrue(config["coreFixture"])
        self.assertEqual(config["launchHome"], f"/home/lab/.cache/{lab.marker}/launch-home")
        self.assertRegex(lab.session, r"^hl[0-9a-f]{8}$")
        self.assertRegex(config["sessionPrefix"], r"^h[0-9a-f]{4}$")

    def test_the_launch_methods_startup_files_stay_in_its_own_directory(self):
        box = ScriptedBox()
        lab, _, _ = self.perform(box)
        everything = "\n".join(box.commands)
        home = f"/home/lab/.cache/{lab.marker}/launch-home"
        for relative in (".bashrc", ".zshrc", ".config/fish/config.fish", ".rc-stub/bin/heeler-rc-stub"):
            self.assertIn(f"{home}/{relative}", everything)
        self.assertNotIn("> /home/lab/.bashrc", everything)
        self.assertNotIn("> /home/lab/.zshrc", everything)

    def test_the_make_target_stops_without_a_simulator(self):
        def planned(*variables):
            environment = {name: value for name, value in os.environ.items() if name != "SIMULATOR_UDID"}
            result = subprocess.run(["make", "-n", "verify-core-linux-host", *variables], cwd=SCRIPTS.parent,
                                    env=environment, capture_output=True, text=True, check=True)
            return result.stdout.splitlines()

        steps = planned()
        self.assertTrue(steps[0].startswith('test -n ""'), steps)
        self.assertIn("herdr-core-lab-check.py", steps[-1])
        self.assertIn("--udid 'SOME-UDID'", planned("SIMULATOR_UDID=SOME-UDID")[-1])

    def test_each_run_gets_its_own_session(self):
        self.assertNotEqual(lab_check.unique_session(), lab_check.unique_session())

    def test_replay_refuses_a_frame_that_does_not_round_trip(self):
        self.assertEqual(lab_check.replay(VECTORS), 2)
        truncated = json.loads(json.dumps(VECTORS))
        truncated["exchanges"][0]["replyFrame"] = truncated["exchanges"][0]["replyFrame"][:-2]
        with self.assertRaises(ValueError):
            lab_check.replay(truncated)


if __name__ == "__main__":
    unittest.main()
