#!/usr/bin/env python3
"""Run the core environment check's script against fake proc trees.

Compiles HostProcessReader.swift and HerdrCoreEnvironmentCheck.swift with a small
driver, feeds the check's script to each POSIX shell found here, as an exec does,
and hands the output to the Swift parser. Assertions look at the raw output when
they are about what leaves the Host. Needs swiftc; standard library only.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HostProcessReader.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreEnvironmentCheck.swift",
]
NONCE = "0123456789abcdef01234567"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = Int(arguments[2]) else { exit(64) }
switch arguments[1] {
case "script":
    let platform: HostProcessReader.Platform =
        arguments.count > 3 ? .linux(procRoot: arguments[3]) : .hostKernel
    guard let script = try? HerdrCoreEnvironmentCheck.script(
        pid: pid, nonce: "%s", platform: platform)
    else { exit(65) }
    FileHandle.standardOutput.write(script)
case "parse":
    let names = HerdrCoreEnvironmentCheck.leakedNames(
        stdout: FileHandle.standardInput.readDataToEndOfFile(), nonce: "%s", pid: pid)
    let json = try JSONSerialization.data(withJSONObject: names.sorted())
    FileHandle.standardOutput.write(json)
default:
    exit(64)
}
""" % (NONCE, NONCE)

# Every exact name ADR 0034 lists, each with a value a test can look for.
LISTED = {
    "CLAUDE_CODE_CHILD_SESSION": "value-child-session",
    "CLAUDE_CODE_SKIP_PROMPT_HISTORY": "value-skip-history",
    "CLAUDECODE": "value-claudecode",
    "TMUX": "/tmp/value-tmux,1,0",
    "STY": "value-sty",
    "ZELLIJ": "value-zellij",
    "CURSOR_TRACE_ID": "value-cursor",
    "VSCODE_GIT_ASKPASS_MAIN": "/value/askpass.js",
    "CODEX_THREAD_ID": "value-codex-thread",
    "OMPCODE": "value-omp",
    "PI_PROGRAM_STATUS": "value-pi-status",
}
BY_PREFIX = {"HERDR_ENV": "value-herdr-env", "HERDR_SOCKET_PATH": "/value/herdr.sock"}
OUTSIDE = {
    "PATH": "/usr/bin",
    "HERDR": "value-no-underscore",
    "HERDRX_Y": "value-near-prefix",
    "NOT_HERDR_X": "value-prefix-inside",
    "TMUX_PANE": "value-longer-name",
    "CLAUDE_CODE_SESSION_ID": "value-unlisted",
}


def environ(entries: dict[str, str]) -> bytes:
    return b"".join(f"{name}={value}".encode() + b"\0" for name, value in entries.items())


def shells() -> list[list[str]]:
    found = [["/bin/sh"]]
    for name in ("dash", "bash", "ksh"):
        path = shutil.which(name)
        if path:
            found.append([path])
    busybox = shutil.which("busybox")
    if busybox:
        found.append([busybox, "sh"])
    return found


class CheckTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-environment-check-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "check"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.proc = Path(tempfile.mkdtemp(prefix="heeler-proc-"))

    def tearDown(self) -> None:
        for directory, _, _ in os.walk(self.proc):
            os.chmod(directory, 0o755)
        shutil.rmtree(self.proc, ignore_errors=True)

    def core(self, entries: bytes | None, pid: int = 77) -> None:
        directory = self.proc / str(pid)
        directory.mkdir()
        if entries is not None:
            (directory / "environ").write_bytes(entries)

    def raw(self, shell: list[str], pid: int = 77, root: str | None = None) -> bytes:
        """The script's stdout, under an environment holding nothing a test looks for."""
        arguments = [str(self.binary), "script", str(pid), root or str(self.proc)]
        script = subprocess.run(arguments, check=True, capture_output=True).stdout
        result = subprocess.run(
            shell, input=script, capture_output=True, timeout=60,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SECRET_OF_THE_EXEC": "not-this-one"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        return result.stdout

    def parse(self, raw: bytes, pid: int = 77) -> list[str]:
        result = subprocess.run(
            [str(self.binary), "parse", str(pid)], input=raw, capture_output=True, check=True
        )
        return json.loads(result.stdout)

    def names(self, shell: list[str], pid: int = 77) -> list[str]:
        return self.parse(self.raw(shell, pid), pid)

    def for_each_shell(self, check) -> None:
        for shell in shells():
            with self.subTest(shell=" ".join(shell)):
                check(shell)


class FakeProcTests(CheckTestCase):
    def test_names_every_listed_variable_and_each_herdr_one(self) -> None:
        self.core(environ({**LISTED, **BY_PREFIX, **OUTSIDE}))

        def check(shell: list[str]) -> None:
            self.assertEqual(self.names(shell), [
                "CLAUDECODE",
                "CLAUDE_CODE_CHILD_SESSION",
                "CLAUDE_CODE_SKIP_PROMPT_HISTORY",
                "CODEX_THREAD_ID",
                "CURSOR_TRACE_ID",
                "HERDR_ENV",
                "HERDR_SOCKET_PATH",
                "OMPCODE",
                "PI_PROGRAM_STATUS",
                "STY",
                "TMUX",
                "VSCODE_GIT_ASKPASS_MAIN",
                "ZELLIJ",
            ])
        self.for_each_shell(check)

    def test_prints_names_only_with_no_equals_and_no_value(self) -> None:
        everything = {**LISTED, **BY_PREFIX, **OUTSIDE}
        self.core(environ(everything))

        def check(shell: list[str]) -> None:
            raw = self.raw(shell)
            self.assertEqual(raw.count(b"="), 0, raw)
            for value in everything.values():
                self.assertNotIn(value.encode(), raw)
                self.assertNotIn(value.encode().hex().encode(), raw)
            self.assertNotIn(b"not-this-one", raw)
            lines = [line for line in raw.decode().splitlines() if line]
            self.assertEqual(lines[-2], "E 77 ok")
            for line in lines[1:-2]:
                self.assertRegex(line, r"^N 77 [A-Z_]+$")
        self.for_each_shell(check)

    def test_ignores_blank_values_and_variables_outside_the_list(self) -> None:
        blank = {name: "" for name in LISTED}
        self.core(environ({**blank, "HERDR_BLANK": "", **OUTSIDE}))

        def check(shell: list[str]) -> None:
            self.assertEqual(self.names(shell), [])
        self.for_each_shell(check)

    def test_a_newline_in_a_value_cannot_forge_a_listed_name(self) -> None:
        self.core(b"OTHER=x\nTMUX=forged\0OTHER2=y\nHERDR_FORGED=z\0")

        def check(shell: list[str]) -> None:
            self.assertEqual(self.names(shell), [])
        self.for_each_shell(check)

    def test_an_unreadable_environment_names_nothing(self) -> None:
        self.core(None, pid=11)  # no environ at all
        self.core(b"", pid=12)  # a zombie's, or a kernel thread's
        cases = [11, 12, 404]
        if os.geteuid() != 0:
            self.core(environ(LISTED), pid=13)
            (self.proc / "13/environ").chmod(0)
            cases.append(13)

        def check(shell: list[str]) -> None:
            for pid in cases:
                raw = self.raw(shell, pid)
                self.assertIn(f"E {pid} -".encode(), raw, pid)
                self.assertEqual(self.parse(raw, pid), [], pid)
        self.for_each_shell(check)

    def test_output_that_is_cut_short_or_someone_elses_names_nothing(self) -> None:
        self.core(environ(LISTED))
        raw = self.raw(["/bin/sh"])
        self.assertEqual(self.parse(raw.split(b"__HEELER_PROC_END_")[0]), [])
        self.assertEqual(self.parse(raw.replace(NONCE.encode(), b"another-nonce")), [])
        self.assertEqual(self.parse(b""), [])
        self.assertEqual(self.parse(b"TMUX=/tmp/banner\n"), [])


class RealProcessTests(CheckTestCase):
    """The form production sends, against a process this test starts itself."""

    def start(self, program: str, env: dict[str, str]) -> str:
        process = subprocess.Popen(
            [program, "300"], env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        time.sleep(0.3)
        return str(process.pid)

    def read_host_kernel(self, pid: str) -> tuple[bytes, list[str]]:
        script = subprocess.run(
            [str(self.binary), "script", pid], check=True, capture_output=True
        ).stdout
        raw = subprocess.run(
            ["/bin/sh"], input=script, capture_output=True, timeout=60,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        ).stdout
        return raw, self.parse(raw, int(pid))

    def program(self) -> str:
        # macOS withholds a platform binary's environment.
        if sys.platform != "darwin":
            return "/bin/sleep"
        copy = self.proc / "sleep-copy"
        shutil.copy("/bin/sleep", copy)
        subprocess.run(["codesign", "-f", "-s", "-", str(copy)], check=True, capture_output=True)
        return str(copy)

    def test_a_leaked_process_on_this_kernel_is_named_without_its_values(self) -> None:
        pid = self.start(self.program(), {
            "PATH": "/usr/bin:/bin", "TMUX": "/tmp/value-tmux,1,0", "STY": "",
            "CLAUDE_CODE_CHILD_SESSION": "1", "HERDR_PANE_ID": "value-pane", "UNLISTED": "value-other",
        })
        raw, names = self.read_host_kernel(pid)
        self.assertEqual(names, ["CLAUDE_CODE_CHILD_SESSION", "HERDR_PANE_ID", "TMUX"])
        self.assertEqual(raw.count(b"="), 0, raw)
        for value in (b"value-tmux", b"value-pane", b"value-other"):
            self.assertNotIn(value, raw)
            self.assertNotIn(value.hex().encode(), raw)

    def test_a_clean_process_on_this_kernel_names_nothing(self) -> None:
        pid = self.start(self.program(), {"PATH": "/usr/bin:/bin", "LANG": "C"})
        raw, names = self.read_host_kernel(pid)
        self.assertIn(f"E {pid} ok".encode(), raw)
        self.assertEqual(names, [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS withholds only there")
    def test_a_withheld_environment_on_macos_names_nothing(self) -> None:
        pid = self.start("/bin/sleep", {"PATH": "/usr/bin:/bin", "TMUX": "/tmp/value-tmux,1,0"})
        raw, names = self.read_host_kernel(pid)
        self.assertIn(f"E {pid} -".encode(), raw)
        self.assertEqual(names, [])


if __name__ == "__main__":
    if not shutil.which("swiftc"):
        sys.exit("swiftc is required")
    unittest.main()
