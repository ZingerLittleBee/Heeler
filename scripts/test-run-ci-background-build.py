#!/usr/bin/env python3
"""Exercise background build timing and ownership with real watchdog processes."""

from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path


BACKGROUND_BUILD = Path(__file__).with_name("run-ci-background-build.py")
WATCHDOG = Path(__file__).with_name("run-with-timeout.py")

PROCESS_TREE = """
import json, os, signal, subprocess, sys, time
from pathlib import Path

root = Path(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2] == "leaf":
    def terminate(signum, frame):
        (root / "leaf-terminated").write_text(str(signum))
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, terminate)
    (root / "leaf-ready").write_text(str(os.getpid()))
    while True:
        time.sleep(0.05)

leaf = subprocess.Popen([sys.executable, __file__, str(root), "leaf"])
def terminate(signum, frame):
    status = leaf.wait(timeout=3)
    (root / "leaf-reaped.json").write_text(json.dumps({
        "pid": leaf.pid, "exit_status": status, "signal": signum,
    }))
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, terminate)
(root / "pids.json").write_text(json.dumps({
    "command": os.getpid(), "leaf": leaf.pid, "watchdog": os.getppid(),
}))
deadline = time.monotonic() + 3
while not (root / "leaf-ready").exists():
    if time.monotonic() >= deadline:
        raise SystemExit("leaf did not start")
    time.sleep(0.01)
(root / "ready").write_text("ready")
while True:
    time.sleep(0.05)
"""

STUBBORN_PROCESS_TREE = """
import json, os, signal, subprocess, sys, time
from pathlib import Path

root, mode = Path(sys.argv[1]), sys.argv[2]
if mode in ("leaf", "stubborn-leader"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    def terminate(signum, frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
if mode == "leaf":
    (root / "leaf-ready").write_text(str(os.getpid()))
    while True:
        time.sleep(0.05)

leaf = subprocess.Popen([sys.executable, __file__, str(root), "leaf"])
(root / "pids.json").write_text(json.dumps({
    "command": os.getpid(), "leaf": leaf.pid, "watchdog": os.getppid(),
}))
deadline = time.monotonic() + 3
while not (root / "leaf-ready").exists():
    if time.monotonic() >= deadline:
        raise SystemExit("leaf did not start")
    time.sleep(0.01)
# Both handlers are installed before the test may send TERM.
(root / "ready").write_text("ready")
while True:
    time.sleep(0.05)
"""

# Inject the signal between the real Popen returning and the helper publishing
# its child. All command execution and signal forwarding remain real processes.
STARTUP_SIGNAL_HARNESS = """
import importlib.util, os, signal, subprocess, sys, time
from pathlib import Path

target_path, ready_path, signum, *arguments = sys.argv[1:]
spec = importlib.util.spec_from_file_location("owned_command", target_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
if hasattr(module, "CommandCancelled"):
    original_cancellation = module.CommandCancelled
    class EntryWindowCancellation(original_cancellation):
        def __init__(self):
            # Inject a second real signal while constructing the exception,
            # before the watchdog can enter its cancellation except block.
            os.kill(os.getpid(), int(signum))
            super().__init__()
    module.CommandCancelled = EntryWindowCancellation
original_popen = subprocess.Popen
def start_child(*args, **kwargs):
    child = original_popen(*args, **kwargs)
    deadline = time.monotonic() + 4
    while not Path(ready_path).exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("command did not become ready")
        time.sleep(0.01)
    os.kill(os.getpid(), int(signum))
    return child
module.subprocess.Popen = start_child
sys.argv = [target_path, *arguments]
raise SystemExit(module.main())
"""


class BackgroundBuildProcessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="heeler-background-build-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.timing_path = self.root / "timing" / "build.json"
        self.diagnostics_dir = self.root / "diagnostics"
        self.environment = {
            **os.environ,
            "HEELER_TIMEOUT_DISABLE_SAMPLE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.processes: list[subprocess.Popen[str]] = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self) -> None:
        # A failed assertion must not leave the deliberately long-lived fixture
        # behind. Its command is the session leader created by the watchdog.
        pid_path = self.root / "pids.json"
        if pid_path.exists():
            pids = json.loads(pid_path.read_text())
            try:
                os.killpg(pids["command"], signal.SIGKILL)
            except ProcessLookupError:
                pass
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                if pid_path.exists():
                    for pid in json.loads(pid_path.read_text()).values():
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                process.kill()
                process.communicate(timeout=5)

    def launch(
        self, command: list[str], *, timeout: float = 5,
        startup_signal: int | bool = False,
        watchdog_startup_signal: int | None = None,
    ) -> subprocess.Popen[str]:
        watchdog_arguments = [
            "--timeout-seconds", str(timeout),
            "--label", "fixture build", "--diagnostics-dir", str(self.diagnostics_dir),
            "--", *command,
        ]
        watchdog_entry = [sys.executable, str(WATCHDOG)]
        if watchdog_startup_signal is not None:
            harness = self.root / "watchdog-startup-signal.py"
            harness.write_text(STARTUP_SIGNAL_HARNESS, encoding="utf-8")
            watchdog_entry = [
                sys.executable, str(harness), str(WATCHDOG), str(self.root / "ready"),
                str(watchdog_startup_signal),
            ]
        arguments = [
            "--timing-path", str(self.timing_path), "--",
            *watchdog_entry, *watchdog_arguments,
        ]
        if startup_signal:
            harness = self.root / "helper-startup-signal.py"
            harness.write_text(STARTUP_SIGNAL_HARNESS, encoding="utf-8")
            signum = signal.SIGTERM if startup_signal is True else startup_signal
            entry = [
                sys.executable, str(harness), str(BACKGROUND_BUILD),
                str(self.root / "ready"), str(signum),
            ]
        else:
            entry = [sys.executable, str(BACKGROUND_BUILD)]
        process = subprocess.Popen(
            [*entry, *arguments], env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True,
        )
        self.processes.append(process)
        return process

    def finish(self, process: subprocess.Popen[str], expected_status: int) -> None:
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, expected_status, stdout + stderr)

    def assert_timing(self, status: int, earliest_start: float) -> dict:
        timing = json.loads(self.timing_path.read_text())
        self.assertEqual(timing["exit_status"], status)
        self.assertTrue(math.isfinite(timing["started_unix_seconds"]))
        self.assertGreaterEqual(timing["started_unix_seconds"], earliest_start)
        self.assertLessEqual(timing["started_unix_seconds"], time.time())
        self.assertTrue(math.isfinite(timing["elapsed_seconds"]))
        self.assertGreater(timing["elapsed_seconds"], 0)
        self.assertLess(timing["elapsed_seconds"], 10)
        return timing

    def wait_for_path(self, path: Path) -> None:
        deadline = time.monotonic() + 4
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"fixture did not create {path.name}")
            time.sleep(0.01)

    def tree_command(self) -> list[str]:
        fixture = self.root / "process-tree.py"
        fixture.write_text(PROCESS_TREE, encoding="utf-8")
        return [sys.executable, str(fixture), str(self.root)]

    def stubborn_tree_command(self, mode: str) -> list[str]:
        fixture = self.root / "stubborn-process-tree.py"
        fixture.write_text(STUBBORN_PROCESS_TREE, encoding="utf-8")
        return [sys.executable, str(fixture), str(self.root), mode]

    def assert_recorded_processes_gone(self) -> None:
        remaining = json.loads((self.root / "pids.json").read_text())
        # Orphaned leaves may briefly wait for the system parent to reap them
        # after KILL. Require disappearance within a bounded polling window.
        deadline = time.monotonic() + 2
        while remaining:
            for name, pid in list(remaining.items()):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    del remaining[name]
            if remaining:
                self.assertLess(time.monotonic(), deadline, f"processes still exist: {remaining}")
                time.sleep(0.01)

    def assert_descendant_reaped(self) -> None:
        pids = json.loads((self.root / "pids.json").read_text())
        reaped = json.loads((self.root / "leaf-reaped.json").read_text())
        self.assertEqual(reaped, {
            "pid": pids["leaf"], "exit_status": 0, "signal": signal.SIGTERM,
        })
        self.assertEqual((self.root / "leaf-terminated").read_text(), str(signal.SIGTERM))
        # The marker proves wait() reaped the leaf; absence also checks that the
        # watchdog and command have finished by the time the helper returns.
        for name, pid in pids.items():
            with self.subTest(process=name), self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)

    def test_success_records_wall_start_and_elapsed_time(self) -> None:
        started = time.time()
        process = self.launch([sys.executable, "-c", "import time; time.sleep(0.15)"])
        self.finish(process, 0)
        timing = self.assert_timing(0, started)
        self.assertGreaterEqual(timing["elapsed_seconds"], 0.15)

    def test_build_failure_preserves_exit_status_and_watchdog_diagnostics(self) -> None:
        started = time.time()
        process = self.launch([sys.executable, "-c", "raise SystemExit(65)"])
        self.finish(process, 65)
        self.assert_timing(65, started)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "65\n")

    def test_timeout_records_124_and_reaps_the_command_descendant(self) -> None:
        started = time.time()
        process = self.launch(self.tree_command(), timeout=1)
        self.finish(process, 124)
        timing = self.assert_timing(124, started)
        self.assertGreaterEqual(timing["elapsed_seconds"], 1)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "124\n")
        self.assertIn("fixture build exceeded 1 seconds", (self.diagnostics_dir / "timeout.txt").read_text())
        self.assert_descendant_reaped()

    def test_sigterm_records_143_and_reaps_the_command_descendant(self) -> None:
        started = time.time()
        process = self.launch(self.tree_command())
        self.wait_for_path(self.root / "ready")
        process.send_signal(signal.SIGTERM)
        self.finish(process, 143)
        self.assert_timing(143, started)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "143\n")
        self.assert_descendant_reaped()

    def test_signal_before_child_publication_is_forwarded_after_startup(self) -> None:
        started = time.time()
        process = self.launch(self.tree_command(), startup_signal=True)
        self.finish(process, 143)
        self.assert_timing(143, started)
        self.assert_descendant_reaped()

    def test_sigint_before_helper_child_publication_is_forwarded(self) -> None:
        started = time.time()
        process = self.launch(self.tree_command(), startup_signal=signal.SIGINT)
        self.finish(process, 130)
        self.assert_timing(130, started)
        self.assert_descendant_reaped()

    def test_cancellation_before_watchdog_child_publication_keeps_ownership(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                # Keep subcases' PID and readiness files independent.
                self.root = Path(self.temporary.name) / str(signum)
                self.root.mkdir()
                self.timing_path = self.root / "timing" / "build.json"
                self.diagnostics_dir = self.root / "diagnostics"
                started = time.time()
                process = self.launch(self.tree_command(), watchdog_startup_signal=signum)
                self.finish(process, 128 + signum)
                self.assert_timing(128 + signum, started)
                self.assert_descendant_reaped()
                self.assertEqual(
                    (self.diagnostics_dir / "status.txt").read_text(), f"{128 + signum}\n"
                )

    def test_repeated_sigint_does_not_interrupt_stubborn_tree_reaping(self) -> None:
        started = time.time()
        process = self.launch(self.stubborn_tree_command("stubborn-leader"), timeout=900)
        self.wait_for_path(self.root / "ready")
        signaled = time.monotonic()
        process.send_signal(signal.SIGINT)
        time.sleep(0.15)
        process.send_signal(signal.SIGINT)
        status = process.wait(timeout=8)
        self.assertLess(time.monotonic() - signaled, 8)
        self.assertEqual(status, 130)
        self.assert_timing(130, started)
        self.assert_recorded_processes_gone()
        self.finish(process, 130)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "130\n")

    def assert_stubborn_tree_cancellation(self, mode: str) -> None:
        started = time.time()
        process = self.launch(self.stubborn_tree_command(mode), timeout=900)
        self.wait_for_path(self.root / "ready")
        signaled = time.monotonic()
        process.send_signal(signal.SIGTERM)
        status = process.wait(timeout=8)
        self.assertLess(time.monotonic() - signaled, 8)
        self.assertEqual(status, 143)
        self.assert_timing(143, started)
        self.assert_recorded_processes_gone()
        self.finish(process, 143)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "143\n")

    def test_sigterm_escalates_when_leader_and_leaf_ignore_term(self) -> None:
        self.assert_stubborn_tree_cancellation("stubborn-leader")

    def test_sigterm_escalates_after_leader_exits_with_a_stubborn_leaf(self) -> None:
        self.assert_stubborn_tree_cancellation("cooperative-leader")

    def test_timeout_escalates_when_leader_and_leaf_ignore_term(self) -> None:
        started = time.time()
        process = self.launch(self.stubborn_tree_command("stubborn-leader"), timeout=1)
        self.finish(process, 124)
        self.assert_timing(124, started)
        self.assertEqual((self.diagnostics_dir / "status.txt").read_text(), "124\n")
        self.assert_recorded_processes_gone()


class WatchdogPermissionBoundaryTests(unittest.TestCase):
    """Model macOS's intermittent signal permission boundary after leader exit."""

    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("ci_watchdog_permission", WATCHDOG)
        self.watchdog = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.watchdog)
        self.leader = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
        self.leader.wait(timeout=2)

    def test_term_permission_error_accepts_only_a_zombie_group(self) -> None:
        listing = subprocess.CompletedProcess([], 0, stdout=f"{self.leader.pid} Z\n")
        with mock.patch.object(self.watchdog.os, "killpg", side_effect=PermissionError()), \
             mock.patch.object(self.watchdog.subprocess, "run", return_value=listing):
            self.watchdog.terminate_process_group(self.leader, self.leader.pid)
        self.assertEqual(self.leader.returncode, 0)

    def test_term_permission_error_with_a_live_member_is_not_swallowed(self) -> None:
        listing = subprocess.CompletedProcess([], 0, stdout=f"{self.leader.pid} S\n")
        with mock.patch.object(self.watchdog.os, "killpg", side_effect=PermissionError()), \
             mock.patch.object(self.watchdog.subprocess, "run", return_value=listing):
            with self.assertRaises(PermissionError):
                self.watchdog.terminate_process_group(self.leader, self.leader.pid)


if __name__ == "__main__":
    unittest.main()
