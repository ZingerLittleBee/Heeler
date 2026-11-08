#!/usr/bin/env python3
"""Run the herdr-core Start command through real shells against a fake core.

Compiles Sources/Heeler/Transport/HerdrCore/HerdrCoreStart.swift with a small
driver, then feeds the script it builds to /bin/sh on standard input, as a
bounded exec does, with SHELL naming each login shell found here. Startup files
in a temporary HOME print noise and aim HC_SESSION at another session; a fake
`herdr-core` records what it was given. These tests never start a real core.
Needs swiftc; uses only Python's standard library.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreStart.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreSessionName.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreWindowsLocator.swift",
    ROOT / "scripts/fixtures/herdr-core-tool-stubs.swift",
    ROOT / "scripts/fixtures/string-localized-shim.swift",
]
VECTORS = ROOT / "plugin/test-vectors/herdr-core-session-names-v1.json"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
switch arguments[1] {
case "script":
    guard let script = try? HerdrCoreStart.script(executablePath: arguments[2], session: arguments[3]) else {
        exit(65)
    }
    FileHandle.standardOutput.write(script)
case "judge":
    let outcome = HerdrCoreStart.outcome(
        stdout: FileManager.default.contents(atPath: arguments[2]) ?? Data(),
        stderr: FileManager.default.contents(atPath: arguments[3]) ?? Data(),
        exitStatus: Int32(arguments[4]) ?? -1,
        elapsed: .milliseconds(Int64(arguments[5]) ?? 0))
    print(outcome)
default:
    exit(64)
}
"""

FAKE_CORE = """#!/bin/sh
{
  printf 'session=%s\\n' "$HC_SESSION"
  printf 'argc=%s\\n' "$#"
  for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
} >> "$(dirname "$0")/calls"
if [ -f "$(dirname "$0")/refuse" ]; then
  printf '{"error":{"kind":"io","message":"bind failed","hint":""}}\\n' >&2
  exit 3
fi
printf '{"pid":1,"uptime_ms":%s}\\n' "${FAKE_UPTIME_MS:-5}"
"""

POSIX_RC = "export HC_SESSION=stray\necho rc-noise\necho rc-warning >&2\n"
STARTUP_FILES = {
    ".bash_profile": POSIX_RC,
    ".profile": POSIX_RC,
    ".zshrc": POSIX_RC,
    ".config/fish/config.fish": "set -gx HC_SESSION stray\necho rc-noise\necho rc-warning >&2\n",
}

# Names hc accepts that a shell would read as something else if a layer were
# left unquoted, beside the shared vector's accepted cases.
EXTRA_SESSIONS = [
    "a!b", "!!", "-x", "~", "~root", "%s", "`id`", "$HOME", "${HOME}", "a  b", "a'b'c", "'", "''",
    "a;b", "a&b", "(a)", "{a}", "[a]", "#a", "a#b", "=a", "a=b",
]


def login_shells() -> list[str]:
    return [path for path in (shutil.which(name) for name in ("bash", "zsh", "fish")) if path]


class StartCommandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # HerdrCoreStartTests covers the command's text and the parse on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the Start command")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-core-start-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "start"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="heeler-core-start-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / "home"
        for name, body in STARTUP_FILES.items():
            path = self.home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
        # A path that needs its own quoting, as a home directory with a space does.
        self.core_dir = self.root / "my core's bin"
        self.core_dir.mkdir()
        self.core = self.core_dir / "herdr-core"
        self.core.write_text(FAKE_CORE)
        self.core.chmod(0o755)
        self.calls = self.core_dir / "calls"

    def start(self, shell: str, session: str, *, uptime_ms: int = 5) -> subprocess.CompletedProcess:
        script = subprocess.run(
            [str(self.binary), "script", str(self.core), session], check=True, capture_output=True
        ).stdout
        self.calls.unlink(missing_ok=True)
        return subprocess.run(
            ["/bin/sh", "-s"],
            # The body sits in a subshell with no stdin, as in a bounded exec.
            input=b"(\n" + script + b"\n) </dev/null\n",
            capture_output=True,
            timeout=60,
            # An interactive shell must not take this terminal's foreground.
            start_new_session=True,
            cwd=self.root,
            env={
                "HOME": str(self.home),
                "PATH": "/usr/bin:/bin",
                "SHELL": shell,
                "TERM": "dumb",
                "FAKE_UPTIME_MS": str(uptime_ms),
            },
        )

    def recorded(self) -> list[str]:
        return self.calls.read_text().splitlines()

    def judge(self, result: subprocess.CompletedProcess, elapsed_ms: int) -> str:
        stdout = self.root / "stdout"
        stderr = self.root / "stderr"
        stdout.write_bytes(result.stdout)
        stderr.write_bytes(result.stderr)
        return subprocess.run(
            [
                str(self.binary), "judge", str(stdout), str(stderr),
                str(result.returncode), str(elapsed_ms),
            ],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def test_the_core_gets_the_hosts_session_whatever_the_startup_files_set(self) -> None:
        for shell in login_shells():
            with self.subTest(shell=shell):
                result = self.start(shell, "work")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"rc-noise", result.stdout)
                self.assertEqual(
                    self.recorded(), ["session=work", "argc=2", "arg=server", "arg=start"])

    def test_every_session_name_hc_accepts_survives_both_quoting_layers(self) -> None:
        vectors = json.loads(VECTORS.read_text())["cases"]
        cases = [(case["raw"], case["normalized"]) for case in vectors if case["normalized"] is not None]
        cases += [(name, name) for name in EXTRA_SESSIONS]
        for shell in login_shells():
            for raw, normalized in cases:
                with self.subTest(shell=shell, session=raw):
                    result = self.start(shell, raw)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.recorded()[0], f"session={normalized}")

    def test_a_refused_session_name_builds_no_command(self) -> None:
        for name in (".", "a/b", "a\nb", 'a"b'):
            with self.subTest(session=name):
                build = subprocess.run(
                    [str(self.binary), "script", str(self.core), name], capture_output=True)
                self.assertEqual(build.returncode, 65)

    def test_real_shell_output_reads_as_started_or_already_running(self) -> None:
        for shell in login_shells():
            with self.subTest(shell=shell):
                result = self.start(shell, "work", uptime_ms=800)
                self.assertEqual(self.judge(result, 1000), "started")
                self.assertEqual(self.judge(result, 500), "alreadyRunning")

    def test_a_refused_start_reads_as_failed_with_the_core_s_message(self) -> None:
        (self.core_dir / "refuse").touch()
        for shell in login_shells():
            with self.subTest(shell=shell):
                result = self.start(shell, "work")
                self.assertEqual(result.returncode, 3)
                self.assertEqual(self.judge(result, 1000), 'failed(detail: Optional("bind failed"))')

    def test_a_missing_core_reads_as_failed_with_the_shell_s_message(self) -> None:
        self.core.unlink()
        for shell in login_shells():
            with self.subTest(shell=shell):
                result = self.start(shell, "work")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("failed(detail: Optional(", self.judge(result, 1000))


if __name__ == "__main__":
    unittest.main(verbosity=1 if sys.stdout.isatty() else 2)
