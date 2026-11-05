#!/usr/bin/env python3
"""Run the herdr-core locator's script against a fake home.

Compiles Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift with a small
driver, then feeds the script it builds to each POSIX shell found here, on
standard input as an exec does, with a constructed environment, and hands the
output to the Swift parser. A fake `hc` and fake `herdr-core` programs record
every call, so these tests never touch a real core. Needs swiftc; uses only
Python's standard library.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreSessionName.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreWindowsLocator.swift",
    ROOT / "scripts/fixtures/herdr-core-tool-stubs.swift",
]
NONCE = "0123456789abcdef"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let nonce = "%s"
switch arguments[1] {
case "script":
    guard let script = try? HerdrCoreLocator.script(session: arguments[2], nonce: nonce) else {
        exit(65)
    }
    FileHandle.standardOutput.write(script)
case "parse":
    let output = FileHandle.standardInput.readDataToEndOfFile()
    guard let location = try? HerdrCoreLocator.parse(stdout: output, nonce: nonce) else {
        exit(66)
    }
    let result: [String: Any?] = [
        "executable": location.executablePath,
        "version": location.version,
        "socket": location.socketPath,
        "source": location.socketSource == .lock ? "lock" : "default",
        "socketFile": location.socketFilePresent,
        "limit": location.socketPathLimit,
        "fits": location.fitsSocketPathLimit,
        "stale": location.isStaleLock,
        "shell": location.loginShell,
    ]
    let json = try JSONSerialization.data(
        withJSONObject: result.mapValues { $0 ?? NSNull() }, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
default:
    exit(64)
}
""" % NONCE


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


class LocatorTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # HerdrCoreLocatorTests covers the script's text and parsing on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the locator")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-core-locator-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "locator"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        # A short path: a socket file below it must bind on macOS.
        self.root = Path(tempfile.mkdtemp(prefix="hl-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / "h"
        self.home.mkdir()
        self.path_dir = self.root / "p"
        self.path_dir.mkdir()
        self.calls = self.root / "calls"
        self.calls.touch()
        self.program(self.path_dir / "hc", "hc 0.1.13")

    def program(self, path: Path, version: str, *, status: int = 0) -> Path:
        """A fake that records every call, then prints a version only when asked."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s %s\\n' {path.name} \"$*\" >> {self.calls}\n"
            f"if [ \"$1\" = --version ]; then printf '%s\\n' '{version}'; exit {status}; fi\n"
            "exit 99\n")
        path.chmod(0o755)
        return path

    def installed(self, version: str = "hc 0.1.13") -> Path:
        return self.program(self.home / ".local/bin/herdr-core", version)

    def lock(self, session: str, contents: str, state: Path | None = None) -> None:
        directory = (state or self.home / ".local/state") / "herdr-core" / session
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "core.lock").write_text(contents)

    def bound_socket(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        bound = socket.socket(socket.AF_UNIX)
        bound.bind(str(path))
        self.addCleanup(bound.close)

    def run_script(self, shell: list[str], session: str = "work", **environment: str) -> bytes:
        script = subprocess.run(
            [str(self.binary), "script", session], check=True, capture_output=True).stdout
        env = {"HOME": str(self.home), "PATH": f"{self.path_dir}:/usr/bin:/bin", **environment}
        result = subprocess.run(shell, input=script, env=env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def locate(self, shell: list[str], session: str = "work", **environment: str) -> dict:
        output = self.run_script(shell, session, **environment)
        parsed = subprocess.run(
            [str(self.binary), "parse"], input=output, check=True, capture_output=True).stdout
        return json.loads(parsed)

    def called(self) -> str:
        return self.calls.read_text()

    def default_socket(self, session: str = "work") -> Path:
        """Where the core would bind here with no runtime variable."""
        run_user = Path(f"/run/user/{os.getuid()}")
        if run_user.is_dir():
            return run_user / "herdr-core" / f"{session}.sock"
        return self.home / ".local/state/herdr-core" / session / f"{session}.sock"


class InstallTests(LocatorTestCase):
    def test_no_program_reads_as_not_installed(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertIsNone(self.locate(shell)["executable"])

    def test_the_installers_path_is_found_when_path_lacks_it(self) -> None:
        program = self.installed()
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["executable"], str(program))
                self.assertEqual(location["version"], "0.1.13")

    def test_the_execs_path_comes_first(self) -> None:
        self.installed()
        on_path = self.program(self.path_dir / "herdr-core", "herdr-core 0.2.0")
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["executable"], str(on_path))
                self.assertEqual(location["version"], "0.2.0")

    def test_a_program_that_is_not_the_core_does_not_hide_the_installed_one(self) -> None:
        program = self.installed()
        self.program(self.path_dir / "herdr-core", "Health Check 2.0")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.locate(shell)["executable"], str(program))

    def test_a_version_that_does_not_identify_the_core_reads_as_not_installed(self) -> None:
        self.program(self.home / ".local/bin/herdr-core", "Health Check 2.0")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertIsNone(self.locate(shell)["executable"])

    def test_a_failing_version_probe_reads_as_not_installed(self) -> None:
        self.program(self.home / ".local/bin/herdr-core", "hc 0.1.13", status=3)
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertIsNone(self.locate(shell)["executable"])

    def test_only_the_version_is_asked_and_hc_is_never_run(self) -> None:
        self.installed()
        self.locate(["/bin/sh"])
        self.assertEqual(self.called(), "herdr-core --version\n")

    def test_the_output_says_nothing_of_the_exec_environment(self) -> None:
        self.installed()
        output = self.run_script(["/bin/sh"], SECRET_NAME="secret-value")
        self.assertNotIn(b"secret-value", output)
        self.assertNotIn(b"SECRET_NAME", output)
        self.assertNotIn(str(self.path_dir).encode(), output)


class SocketTests(LocatorTestCase):
    def test_an_unused_session_reads_its_default_path_and_creates_nothing(self) -> None:
        self.installed()
        before = sorted(str(path) for path in self.home.rglob("*"))
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["socket"], str(self.default_socket()))
                self.assertEqual(location["source"], "default")
                self.assertFalse(location["socketFile"])
        self.assertEqual(sorted(str(path) for path in self.home.rglob("*")), before)

    def test_the_session_names_its_paths(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(
                    self.locate(shell, session="a'b c")["socket"], str(self.default_socket("a'b c")))
                self.assertEqual(
                    self.locate(shell, session="  ")["socket"], str(self.default_socket("default")))

    def test_a_runtime_directory_decides_the_default_path(self) -> None:
        runtime = self.root / "r"
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell, XDG_RUNTIME_DIR=str(runtime))
                self.assertEqual(location["socket"], f"{runtime}/herdr-core/work.sock")

    def test_the_state_directory_follows_its_variable(self) -> None:
        state = self.root / "s"
        self.lock("work", "/tmp/from-state.sock", state=state)
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell, XDG_STATE_HOME=str(state))
                self.assertEqual(location["socket"], "/tmp/from-state.sock")
                self.assertEqual(location["source"], "lock")

    def test_a_lock_names_the_socket(self) -> None:
        socket_path = self.root / "elsewhere.sock"
        self.bound_socket(socket_path)
        self.lock("work", str(socket_path))
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["socket"], str(socket_path))
                self.assertEqual(location["source"], "lock")
                self.assertTrue(location["socketFile"])
                self.assertFalse(location["stale"])

    def test_a_lock_whose_socket_is_gone_is_stale(self) -> None:
        self.lock("work", str(self.root / "gone.sock"))
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["source"], "lock")
                self.assertFalse(location["socketFile"])
                self.assertTrue(location["stale"])

    def test_an_empty_lock_falls_back_to_the_default_path(self) -> None:
        self.lock("work", "")
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["source"], "default")
                self.assertEqual(location["socket"], str(self.default_socket()))

    def test_a_socket_file_left_at_the_default_path_is_reported(self) -> None:
        runtime = self.root / "r"
        self.bound_socket(runtime / "herdr-core/work.sock")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertTrue(self.locate(shell, XDG_RUNTIME_DIR=str(runtime))["socketFile"])

    def test_a_regular_file_is_not_a_socket(self) -> None:
        runtime = self.root / "r"
        (runtime / "herdr-core").mkdir(parents=True)
        (runtime / "herdr-core/work.sock").write_text("")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertFalse(self.locate(shell, XDG_RUNTIME_DIR=str(runtime))["socketFile"])

    def test_an_over_long_path_is_reported_against_this_kernels_limit(self) -> None:
        long_path = "/tmp/" + "a" * 200 + ".sock"
        self.lock("work", long_path)
        limit = 107 if sys.platform.startswith("linux") else 103
        for shell in shells():
            with self.subTest(shell=shell):
                location = self.locate(shell)
                self.assertEqual(location["socket"], long_path)
                self.assertEqual(location["limit"], limit)
                self.assertFalse(location["fits"])

    def test_a_lock_with_a_newline_fails_the_read(self) -> None:
        self.lock("work", "/tmp/a\nsocket-file 1")
        output = self.run_script(["/bin/sh"])
        parsed = subprocess.run([str(self.binary), "parse"], input=output, capture_output=True)
        self.assertEqual(parsed.returncode, 66)

    def test_a_lock_cannot_print_locator_fields(self) -> None:
        # No core is installed, so nothing else would name an executable.
        self.lock("work", "x\nexecutable /tmp/y\nversion 1")
        for shell in shells():
            with self.subTest(shell=shell):
                output = self.run_script(shell)
                self.assertNotIn(b"executable /tmp/y", output)
                parsed = subprocess.run(
                    [str(self.binary), "parse"], input=output, capture_output=True)
                self.assertEqual(parsed.returncode, 66)


class StartupOutputTests(LocatorTestCase):
    """The exec's command line is parsed by the user's shell, which reads its
    startup files first, so whatever they print comes before the script's output."""

    BANNERS = {
        "a line": b"Welcome to box\n",
        "no newline": b"Welcome to box",
        "not UTF-8": b"\xff\xfe caf\xe9\n",
        "not UTF-8 and no newline": b"caf\xe9",
    }

    def startup_shells(self) -> list[tuple[list[str], str]]:
        found = []
        bash = shutil.which("bash")
        if bash:
            found.append(([bash, "--login", "-c", "/bin/sh -s"], ".bash_profile"))
        zsh = shutil.which("zsh")
        if zsh:
            found.append(([zsh, "-c", "/bin/sh -s"], ".zshenv"))
        if not found:
            self.skipTest("needs bash or zsh")
        return found

    def test_a_startup_file_that_prints_leaves_the_read_intact(self) -> None:
        program = self.installed()
        socket_path = self.root / "elsewhere.sock"
        self.bound_socket(socket_path)
        self.lock("work", str(socket_path))
        for shell, startup_file in self.startup_shells():
            for name, banner in self.BANNERS.items():
                with self.subTest(shell=shell[0], banner=name):
                    (self.home / startup_file).write_bytes(
                        b"printf '%b' '" + b"".join(b"\\0%03o" % byte for byte in banner) + b"'\n")
                    output = self.run_script(shell)
                    self.assertTrue(output.startswith(banner), output)
                    location = self.locate(shell)
                    self.assertEqual(location["executable"], str(program))
                    self.assertEqual(location["socket"], str(socket_path))
                    self.assertEqual(location["source"], "lock")
                    self.assertTrue(location["socketFile"])

    def test_a_startup_file_that_prints_leaves_not_installed_readable(self) -> None:
        for shell, startup_file in self.startup_shells():
            with self.subTest(shell=shell[0]):
                (self.home / startup_file).write_text("echo Welcome to box\n")
                self.assertIsNone(self.locate(shell)["executable"])


class ShellTests(LocatorTestCase):
    def test_the_login_shell_comes_from_the_account_database(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                reported = self.locate(shell, SHELL="/not/the/account/shell")["shell"]
                self.assertTrue(reported is None or reported.startswith("/"), reported)
                self.assertNotEqual(reported, "/not/the/account/shell")


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main()
