#!/usr/bin/env python3
"""Exercise Droid's status hook against two private tmux servers."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import uuid4


HOOK = Path(__file__).resolve().parents[1] / "integrations/droid/heeler-droid.py"
spec = importlib.util.spec_from_file_location("droid_hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


@unittest.skipUnless(shutil.which("tmux"), "tmux is unavailable")
class DroidHookTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.tmux = shutil.which("tmux")
        self.sockets = []
        for name in ("a", "b"):
            folder = self.home / name
            folder.mkdir()
            socket = folder / "same"
            self.tmux_run(socket, "new-session", "-d", "-s", "fixture", "exec /bin/sleep 300")
            self.addCleanup(self.tmux_run, socket, "kill-server")
            self.sockets.append(socket)
            saved = self.home / ("Library/Application Support" if sys.platform == "darwin" else ".local/share")
            saved = saved / "heeler/host-helper/tmux/same"
            saved.mkdir(parents=True, exist_ok=True)
            executable = folder / "configured tmux"
            executable.symlink_to(self.tmux)
            key = hashlib.sha256(os.fsencode(socket)).hexdigest()
            (saved / f"droid-{key}.json").write_text(json.dumps({"socket": str(socket), "executable": str(executable)}))
        environment = patch.dict(os.environ, {"HOME": str(self.home), "PATH": "", "XDG_DATA_HOME": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def tmux_run(self, socket, *args):
        return subprocess.check_output([self.tmux, "-S", str(socket), *args], text=True).strip()

    def select(self, socket):
        server, tty = self.tmux_run(socket, "display-message", "-p", "-t", "%0", "#{pid} #{pane_tty}").split()
        os.environ.update(TMUX=f"{socket},{server},0", TMUX_PANE="%0")
        return tty

    def status(self, socket):
        return self.tmux_run(socket, "display-message", "-p", "-t", "%0", "#{@heeler-status}")

    def test_configured_executable_socket_instance_and_terminal(self):
        a, b = self.sockets
        tty = self.select(a)
        for state in ["working", "blocked", "done", "done", "working", "blocked", "error"]:
            self.assertTrue(hook.tmux_status({}, tty, state, False))
        self.assertEqual(self.status(a), "state=error:app=droid:turn=2:blocked=2")
        self.assertEqual(self.status(b), "")
        self.select(b)
        self.assertIsNone(hook.tmux_status({}, tty, "working", False))
        self.assertEqual(self.status(b), "")
        os.environ["TMUX"] = f"{b},1,0"
        self.assertIsNone(hook.tmux_status({}, self.tmux_run(b, "display-message", "-p", "#{pane_tty}"), "working", False))
        self.assertEqual(self.status(b), "")

    def test_stop_before_provider_failure_finishes_the_blocked_turn_once(self):
        socket = self.sockets[0]
        tty = self.select(socket)
        pid, session = os.getpid(), str(uuid4())
        transcript = self.home / ".factory/sessions/fixture" / (session + ".jsonl")
        transcript.parent.mkdir(parents=True)
        transcript.write_text(json.dumps({"type": "session_start", "id": session}) + "\n")
        record = {"pid": pid, "start": "birth", "session": session, "file": str(transcript)}
        stored = hook.session_file(pid)
        stored.parent.mkdir(parents=True)
        hook.write_session(stored, dict(record, turn="token"))
        hook.tmux_status(record, tty, "working", False)
        hook.tmux_status(record, tty, "blocked", False)
        with patch.object(hook, "foreground_droid", return_value=(pid, "birth", tty)):
            hook.main({"hook_event_name": "Stop", "session_id": session, "transcript_path": str(transcript)})
        self.assertIn("state=blocked", self.status(socket))
        offset = transcript.stat().st_size
        with transcript.open("a") as file:
            file.write(json.dumps({"type": "agent_turn_outcome", "reason": "model_provider_unreachable"}) + "\n")
        with patch.object(hook, "process_start", return_value="birth"), patch.object(hook, "ps", return_value=f"{pid} {pid} {tty[5:]}"):
            hook.watch_turn(pid, "token", offset)
            hook.watch_turn(pid, "token", offset)
        self.assertEqual(self.status(socket), "state=error:app=droid:turn=1:blocked=1")


class DroidForegroundTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Darwin process API")
    def test_darwin_reads_only_the_queried_parents_immediate_children(self):
        spec = importlib.util.spec_from_file_location("droid_foreground", HOOK.with_name("foreground-session.py"))
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        # The child confirms both grandchildren exist, then owns their cleanup.
        script = """
import subprocess, sys
children = [subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                             stdin=subprocess.PIPE) for _ in range(2)]
try:
    print(" ".join(str(child.pid) for child in children), flush=True)
    sys.stdin.buffer.read()
finally:
    for child in children:
        child.communicate()
"""
        with subprocess.Popen([sys.executable, "-c", script], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True) as parent:
            try:
                descendants = parent.stdout.readline().split()
                self.assertEqual(len(descendants), 2)
                self.assertEqual(set(probe.darwin_children(str(parent.pid))), set(descendants))
                own = probe.darwin_children(str(os.getpid()))
                self.assertIn(str(parent.pid), own)
                self.assertTrue(set(descendants).isdisjoint(own))
            finally:
                parent.communicate()

    def test_only_one_direct_rpc_child_in_the_same_foreground_can_own_the_session(self):
        spec = importlib.util.spec_from_file_location("droid_foreground", HOOK.with_name("foreground-session.py"))
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            def process(pid, parent, group, foreground, tty, name, argv):
                folder = tree / str(pid)
                folder.mkdir()
                (folder / "stat").write_text(f"{pid} ({name}) S {parent} {group} 1 {tty} {foreground} 0")
                (folder / "cmdline").write_bytes(b"\0".join(argv) + b"\0")
            rpc = [b"/test/droid", b"exec", b"--input-format", b"stream-jsonrpc", b"--output-format", b"stream-jsonrpc"]
            process(10, 1, 10, 10, 5, "droid", [b"droid"])
            process(20, 10, 10, 10, 5, "droid", rpc)
            process(21, 10, 21, 10, 5, "droid", rpc)
            process(22, 10, 10, 10, 6, "droid", rpc)
            process(23, 10, 10, 10, 5, "droid", rpc + [b"other"])
            process(24, 10, 10, 10, 5, "unrelated ) job", rpc)
            process(25, 10, 10, 10, 5, "droid", rpc)
            main = tree / "10/task/10/children"
            worker = tree / "10/task/11/children"
            for path in (main, worker):
                path.parent.mkdir(parents=True)
            main.write_text("21 22 23 24")
            worker.write_text("20")
            def path(*parts):
                return tree.joinpath(*parts[1:]) if parts[0] == "/proc" else Path(*parts)
            with patch.object(probe.sys, "platform", "linux"), patch.object(probe.pathlib, "Path", path):
                self.assertEqual(probe.controller("10"), "20")
                main.write_text("21 22 23 24 25")
                self.assertIsNone(probe.controller("10"))
                main.write_text("21 22 23 24")
                worker.write_text("")
                self.assertEqual(probe.controller("10"), "10")
                (tree / "10/stat").write_text("10 (droid) S 1 10 1 5 42 0")
                self.assertIsNone(probe.controller("10"))


if __name__ == "__main__":
    unittest.main()
