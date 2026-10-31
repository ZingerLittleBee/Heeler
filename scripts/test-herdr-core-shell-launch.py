#!/usr/bin/env python3
"""Run a herdr-core launch and installed-agent discovery through real shells.

Compiles Sources/Heeler/Transport/HerdrCore/HerdrCoreShellLaunch.swift with a
small driver. Each interactive shell found here (bash, zsh, fish) then runs the
argv Heeler would give the core, and the discovery script as an exec does, under
a fake home whose startup file alone puts the stub programs on PATH. Needs
swiftc; uses only Python's standard library. Nothing here starts a core.
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
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreShellLaunch.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreSessionName.swift",
]
NONCE = "0123456789abcdef"
MARKER = "rc-sourced"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let nonce = "%s"
func write(_ value: Any) throws {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value))
}
switch arguments[1] {
case "argv":
    try write(HerdrCoreShellLaunch.argv(shell: arguments[2], program: Array(arguments[3...])))
case "script":
    FileHandle.standardOutput.write(
        HerdrCoreShellLaunch.discoveryScript(
            shell: arguments[2], executables: Array(arguments[4...]), versionOf: arguments[3],
            nonce: nonce))
case "parse":
    let output = FileHandle.standardInput.readDataToEndOfFile()
    guard let found = try? HerdrCoreShellLaunch.parseDiscovery(stdout: output, nonce: nonce) else {
        exit(66)
    }
    let version: Any = found.version ?? NSNull()
    try write(["executables": found.executables.sorted(), "version": version])
default:
    exit(64)
}
""" % NONCE

STUB = """#!/bin/sh
printf '%s\\n' "marker=$HEELER_RC_MARKER"
for argument in "$@"; do printf 'arg=%s\\n' "$argument"; done
"""

VERSION_STUB = """#!/bin/sh
echo 'opencode v2.2.2'
"""

HOSTILE = ["two words", "it's", '"quoted"', "$HOME", "`id`", "*", "a;b", "", "--flag=$x"]


def shells() -> list[str]:
    found = []
    for name in ("bash", "zsh", "fish"):
        path = shutil.which(name)
        if path:
            found.append(path)
    return found


class ShellLaunchTests(unittest.TestCase):
    driver: Path
    build: tempfile.TemporaryDirectory

    @classmethod
    def setUpClass(cls):
        if not shutil.which("swiftc"):
            raise unittest.SkipTest("needs swiftc")
        cls.build = tempfile.TemporaryDirectory()
        main = Path(cls.build.name) / "main.swift"
        main.write_text(MAIN)
        cls.driver = Path(cls.build.name) / "driver"
        result = subprocess.run(
            ["swiftc", "-o", str(cls.driver), str(main), *map(str, SOURCES)],
            capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.home_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.home_directory.cleanup)
        self.home = Path(self.home_directory.name).resolve()
        stubs = self.home / "rc-bin"
        stubs.mkdir()
        for name, body in (("heeler-stub", STUB), ("claude", STUB), ("opencode", VERSION_STUB)):
            path = stubs / name
            path.write_text(body)
            path.chmod(0o700)
        posix = f'echo welcome from the rc\nexport PATH="$HOME/rc-bin:$PATH"\nexport HEELER_RC_MARKER={MARKER}\n'
        (self.home / ".bashrc").write_text(posix)
        (self.home / ".zshrc").write_text(posix)
        fish = self.home / ".config/fish"
        fish.mkdir(parents=True)
        (fish / "config.fish").write_text(
            f'echo welcome from the rc\nset -gx PATH $HOME/rc-bin $PATH\nset -gx HEELER_RC_MARKER {MARKER}\n')

    def environment(self) -> dict[str, str]:
        return {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "LC_ALL": "C", "TERM": "dumb"}

    def drive(self, *arguments: str, stdin: bytes | None = None) -> bytes:
        return subprocess.run(
            [str(self.driver), *arguments], input=stdin, check=True, capture_output=True,
            timeout=30).stdout

    def test_each_argument_reaches_the_program_whole_with_the_rc_environment(self):
        for shell in shells():
            with self.subTest(shell=shell):
                argv = json.loads(self.drive("argv", shell, "heeler-stub", *HOSTILE))
                self.assertEqual(argv[0], shell)
                self.assertEqual(argv[1], "-ic")
                result = subprocess.run(
                    argv, env=self.environment(), stdin=subprocess.DEVNULL, capture_output=True,
                    text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.splitlines()
                self.assertIn(f"marker={MARKER}", lines)
                arguments = [line[4:] for line in lines if line.startswith("arg=")]
                self.assertEqual(arguments, HOSTILE)

    def test_discovery_finds_what_the_rc_puts_on_path_and_reads_the_version(self):
        for shell in shells():
            with self.subTest(shell=shell):
                script = self.drive("script", shell, "opencode", "claude", "opencode", "codex")
                result = subprocess.run(
                    ["/bin/sh", "-s"], input=script, env=self.environment(), capture_output=True,
                    timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"welcome from the rc", result.stdout)
                found = json.loads(self.drive("parse", stdin=result.stdout))
                self.assertEqual(found["executables"], ["claude", "opencode"])
                self.assertEqual(found["version"], "opencode v2.2.2")

    def test_discovery_with_no_such_program_reads_no_version(self):
        for shell in shells():
            with self.subTest(shell=shell):
                script = self.drive("script", shell, "opencode-absent", "opencode-absent")
                result = subprocess.run(
                    ["/bin/sh", "-s"], input=script, env=self.environment(), capture_output=True,
                    timeout=30)
                found = json.loads(self.drive("parse", stdin=result.stdout))
                self.assertEqual(found["executables"], [])
                self.assertIsNone(found["version"])

    def test_a_zsh_with_no_startup_files_still_answers_discovery(self):
        zsh = shutil.which("zsh")
        if not zsh:
            self.skipTest("needs zsh")
        (self.home / ".zshrc").unlink()
        script = self.drive("script", zsh, "opencode", "claude")
        result = subprocess.run(
            ["/bin/sh", "-s"], input=script, env=self.environment(), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        found = json.loads(self.drive("parse", stdin=result.stdout))
        self.assertEqual(found["executables"], [])

    def test_an_output_cut_short_is_refused(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.drive("parse", stdin=b"welcome\n__HEELER_AGENTS_BEGIN_" + NONCE.encode() + b"\nagent claude\n")
        self.assertEqual(caught.exception.returncode, 66)

    def test_a_shell_path_with_a_space_or_quote_stays_one_word(self):
        directory = self.home / "odd dir's"
        directory.mkdir()
        shell = directory / "bash"
        target = shutil.which("bash")
        if not target:
            self.skipTest("needs bash")
        shell.symlink_to(target)
        script = self.drive("script", str(shell), "opencode", "claude")
        result = subprocess.run(
            ["/bin/sh", "-s"], input=script, env=self.environment(), capture_output=True, timeout=30)
        found = json.loads(self.drive("parse", stdin=result.stdout))
        self.assertEqual(found["executables"], ["claude"])


if __name__ == "__main__":
    print(f"shells: {shells()}", file=sys.stderr)
    unittest.main()
