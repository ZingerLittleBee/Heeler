#!/usr/bin/env python3
"""Run the bounded Host script's wrapper through real shells.

Every bounded exec (Changes, Worktrees, GitHub, Chat reads and the rest)
wraps its script in `HeelerSSHTransport.boundedScript`, whose watchdog ends
the exec's process group at its bound. The function lives in the transport
actor's file, so this copies it from there verbatim into a stub enum,
compiles it with a small driver, and feeds the bytes it builds to /bin/sh
and dash (where installed) on standard input, as an exec does, each in a
session of its own as sshd starts one.

A lost connection or closed channel reaches the exec only as SIGPIPE at its
next write. Here the reader of the exec's output pipe goes away before the
bound, and the script's child, which outlives the bound, must be gone once
the bound passes. Needs swiftc; uses only Python's standard library.
"""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSPORT = ROOT / "Sources/Heeler/Transport/HeelerSSHTransport.swift"
START = "    static func boundedScript("
END = "    }"
MARKER = "__HEELER_TEST_TIMEOUT_F00D__"
# POSIX sleep takes whole seconds, as the app's bound does.
BOUND = 2

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let script = FileHandle.standardInput.readDataToEndOfFile()
FileHandle.standardOutput.write(HeelerSSHTransport.boundedScript(
    script, remoteSeconds: Int64(arguments[1])!, timeoutMarker: arguments[2]))
"""


def bounded_script_source() -> str:
    """The function's text, from its signature to its closing brace."""
    lines = TRANSPORT.read_text().splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.startswith(START)), None)
    if start is None:
        raise AssertionError(f"no `{START.strip()}` in {TRANSPORT}")
    end = next((i for i in range(start, len(lines)) if lines[i].rstrip("\n") == END), None)
    if end is None:
        raise AssertionError(f"boundedScript has no closing `{END}` in {TRANSPORT}")
    return "".join(lines[start:end + 1])


def running(pid: int) -> bool:
    """Alive and not a zombie waiting for its reaper."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    state = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin"},
    ).stdout.strip()
    return bool(state) and not state.startswith("Z")


def kill_group(pgid: int | None) -> None:
    if pgid is None:
        return
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


class BoundedHostScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # BoundedHostScriptTests pins the bytes on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the script")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-bounded-build-"))
        (cls.build / "stub.swift").write_text(
            "import Foundation\n\nenum HeelerSSHTransport {\n" + bounded_script_source() + "}\n")
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "bounded"
        subprocess.run(
            ["swiftc", str(cls.build / "stub.swift"), str(cls.build / "main.swift"),
             "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="heeler-bounded-"))
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "LC_ALL": "C"}

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def wrapped(self, body: str, bound: int = BOUND) -> bytes:
        return subprocess.run(
            [str(self.binary), str(bound), MARKER], input=body.encode(),
            check=True, capture_output=True,
        ).stdout

    def each_shell(self, check) -> None:
        """Runs `check` with each shell's path, as a subtest; a missing dash
        is skipped."""
        for name in ("/bin/sh", "dash"):
            with self.subTest(shell=name):
                path = name if os.path.isabs(name) else shutil.which(name)
                if path is None:
                    self.skipTest(f"{name} is not installed")
                check(path)

    def long_child_body(self, tag: str) -> str:
        """A script whose child, recorded by pid, outlives the bound, and which
        writes only once the child has ended."""
        return (
            f"/bin/sh -c 'echo $$ >{self.root}/{tag}.child; exec sleep 30'\n"
            "echo finished\n"
        )

    def wait_for_pid(self, path: Path, timeout: float = 5) -> int:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = path.read_text().strip() if path.exists() else ""
            if text:
                return int(text)
            time.sleep(0.02)
        self.fail(f"the script never started its child ({path.name})")

    def test_the_bound_ends_the_child_after_the_reader_went_away(self) -> None:
        def check(shell: str) -> None:
            tag = Path(shell).name
            script = self.wrapped(self.long_child_body(tag))
            reader, writer = os.pipe()
            started = time.monotonic()
            process = subprocess.Popen(
                [shell, "-s"], stdin=subprocess.PIPE, stdout=writer, stderr=writer,
                env=self.env, start_new_session=True,
            )
            os.close(writer)
            child = None
            try:
                process.stdin.write(script)
                process.stdin.close()
                child = self.wait_for_pid(self.root / f"{tag}.child")
                # The exec's only reader goes, as a dropped connection's does.
                os.close(reader)
                reader = None
                deadline = started + BOUND + 1.5
                while running(child) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertFalse(
                    running(child),
                    f"{shell}: the child outlived the {BOUND}-second bound by "
                    f"{time.monotonic() - started - BOUND:.1f} s after its reader closed")
                self.assertEqual(process.wait(timeout=5), -signal.SIGKILL)
            finally:
                if reader is not None:
                    os.close(reader)
                kill_group(process.pid)
                if child is not None and running(child):
                    os.kill(child, signal.SIGKILL)
                process.wait()

        self.each_shell(check)

    def test_the_bound_reports_its_marker_to_a_present_reader(self) -> None:
        def check(shell: str) -> None:
            tag = Path(shell).name
            started = time.monotonic()
            process = subprocess.Popen(
                [shell, "-s"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=self.env, start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(
                    self.wrapped(self.long_child_body(tag)), timeout=BOUND + 5)
                elapsed = time.monotonic() - started
            finally:
                kill_group(process.pid)
            child = self.wait_for_pid(self.root / f"{tag}.child", timeout=1)
            self.assertEqual(process.returncode, -signal.SIGKILL)
            self.assertEqual(stderr, f"\n{MARKER}\n".encode())
            self.assertEqual(stdout, b"")
            self.assertGreaterEqual(elapsed, BOUND - 0.5)
            self.assertLess(elapsed, BOUND + 2)
            self.assertFalse(running(child))

        self.each_shell(check)

    def test_a_script_that_finishes_leaves_at_once_with_its_status(self) -> None:
        # A long bound: the watchdog's timer must not hold the output open.
        bound = 20

        def check(shell: str) -> None:
            started = time.monotonic()
            process = subprocess.Popen(
                [shell, "-s"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=self.env, start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(
                    self.wrapped("printf body\n(exit 7)\n", bound=bound), timeout=10)
                elapsed = time.monotonic() - started
            finally:
                # The timer's own sleep is left to run out; end it here.
                kill_group(process.pid)
            self.assertEqual(process.returncode, 7)
            self.assertEqual(stdout, b"body")
            self.assertEqual(stderr, b"")
            self.assertLess(elapsed, 3)

        self.each_shell(check)


if __name__ == "__main__":
    unittest.main(verbosity=2)
