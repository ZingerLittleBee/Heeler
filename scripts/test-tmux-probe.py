#!/usr/bin/env python3
"""Run the tmux probe's script through real shells, and against a real tmux.

Compiles Sources/Heeler/Transport/Tmux/TmuxProbe.swift with a small driver, feeds
the script it builds to /bin/sh on standard input as an exec does, and hands the
output to the Swift parser.

Nothing here can reach a tmux server of yours. Every run gets a `TMUX_TMPDIR`
inside its own temporary root, in the exec's environment and in the login
shell's startup files alike, so the directory the script reads is never
`/tmp/tmux-<uid>`. The servers the real-tmux tests start listen on `-S` paths
under that root and are killed by those same paths. Needs swiftc; the real-tmux
tests are skipped where no tmux is installed. Uses only Python's standard library.
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxProbe.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxVersion.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxSocketName.swift",
    ROOT / "scripts/fixtures/string-localized-shim.swift",
]
NONCE = "0123456789abcdef"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let nonce = "%s"
switch arguments[1] {
case "script":
    let request: TmuxProbe.Request
    switch arguments[2] {
    case "sockets": request = .sockets
    case "resolve": request = .resolve(socketName: arguments[3])
    case "stored": request = .stored(executable: arguments[3], socket: arguments[4])
    default: exit(64)
    }
    FileHandle.standardOutput.write(Data(TmuxProbe.script(request, nonce: nonce).utf8))
case "parse":
    let output = FileHandle.standardInput.readDataToEndOfFile()
    guard let report = try? TmuxProbe.parse(stdout: output, nonce: nonce) else { exit(66) }
    let installation: String
    switch report.installation {
    case .notInstalled: installation = "notInstalled"
    case .updateRequired(let version): installation = "updateRequired " + version
    case .usable(_, let version): installation = "usable " + version
    }
    let result: [String: Any?] = [
        "kernel": report.kernel,
        "executable": report.executable,
        "version": report.versionLine,
        "directory": report.directory,
        "sockets": report.sockets,
        "pid": report.server?.pid,
        "startTime": report.server?.startTime,
        "installation": installation,
    ]
    let json = try JSONSerialization.data(
        withJSONObject: result.mapValues { $0 ?? NSNull() }, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
default:
    exit(64)
}
""" % NONCE

# The startup file each shell reads as an interactive login shell.
LOGIN_FILES = {
    "sh": ".profile",
    "dash": ".profile",
    "ksh": ".profile",
    "bash": ".bash_profile",
    "zsh": ".zshrc",
    "fish": ".config/fish/config.fish",
}


def login_shells() -> list[str]:
    found = ["/bin/sh"]
    for name in ("dash", "bash", "ksh", "zsh", "fish"):
        path = shutil.which(name)
        if path:
            found.append(path)
    return found


def real_tmux() -> str | None:
    return shutil.which("tmux") or next(
        (path for path in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.access(path, os.X_OK)), None)


class ProbeTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # TmuxProbeTests covers the script's text and parsing on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the script")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-tmux-probe-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "probe"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        # Short, for the socket paths below: a Unix socket path holds about 100 bytes.
        self.root = Path(tempfile.mkdtemp(prefix="ht-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / "h"
        self.home.mkdir()
        self.calls = self.root / "calls"
        self.calls.touch()
        # What the exec's environment says, and what the login shell's files say.
        self.exec_tmp = self.root / "x"
        self.login_tmp = self.root / "l"
        self.exec_bin = self.root / "xb"
        self.login_bin = self.root / "lb"
        for directory in (self.exec_tmp, self.login_tmp, self.exec_bin, self.login_bin):
            directory.mkdir()
        self.uid = os.getuid()
        user_directories = {Path(f"/tmp/tmux-{self.uid}").resolve(), Path(f"/tmp/tmux-{self.uid}")}
        for directory in (self.exec_directory, self.login_directory):
            self.assertNotIn(directory, user_directories)
            self.assertTrue(directory.is_relative_to(self.root))

    @property
    def exec_directory(self) -> Path:
        return self.exec_tmp / f"tmux-{self.uid}"

    @property
    def login_directory(self) -> Path:
        return self.login_tmp / f"tmux-{self.uid}"

    def fake_tmux(self, directory: Path, version: str = "tmux 3.7b", name: str = "tmux") -> Path:
        """Records every call. A server answers on a socket that has an `.up` file beside it."""
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> {self.calls}\n"
            f"if [ \"$1\" = -V ]; then printf '%s\\n' '{version}'; exit 0; fi\n"
            "if [ \"$1\" = -N ] && [ \"$2\" = -S ] && [ \"$4\" = display-message ]; then\n"
            "    case $3 in */frozen) sleep 60 ;; esac\n"
            "    [ -f \"$3.up\" ] || { echo \"no server running on $3\" >&2; exit 1; }\n"
            "    cat \"$3.up\"\n"
            "    exit 0\n"
            "fi\n"
            "exit 97\n")
        path.chmod(0o755)
        return path

    def socket_file(self, directory: Path, name: str, answers: str | None = None) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
        path = directory / name
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        listener.close()
        if answers is not None:
            (directory / f"{name}.up").write_text(answers + "\n")
        return path

    def write_login_files(self, lines_for) -> None:
        for shell, file in LOGIN_FILES.items():
            path = self.home / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(lines_for("fish" if shell == "fish" else "sh") + "\n")

    def login_files_resolve(self) -> None:
        """Startup files that put the login tmux on PATH and name the login tmux directory."""
        def lines(dialect: str) -> str:
            if dialect == "fish":
                return (f"set -gx PATH {self.login_bin} $PATH\n"
                        f"set -gx TMUX_TMPDIR {self.login_tmp}\necho banner from fish")
            return (f"PATH={self.login_bin}:$PATH; export PATH\n"
                    f"TMUX_TMPDIR={self.login_tmp}; export TMUX_TMPDIR\necho banner from a startup file")
        self.write_login_files(lines)

    def script(self, *request: str) -> bytes:
        return subprocess.run(
            [str(self.binary), "script", *request], check=True, capture_output=True).stdout

    def run_script(self, script: bytes, shell: str = "/bin/sh", extra_env: dict | None = None) -> bytes:
        env = {
            "HOME": str(self.home),
            "SHELL": shell,
            "PATH": f"{self.exec_bin}:/usr/bin:/bin",
            # Never the user's own tmux directory, whatever a startup file does.
            "TMUX_TMPDIR": str(self.exec_tmp),
            **(extra_env or {}),
        }
        result = subprocess.run(["/bin/sh"], input=script, env=env, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def parse(self, output: bytes) -> dict:
        parsed = subprocess.run(
            [str(self.binary), "parse"], input=output, check=True, capture_output=True).stdout
        return json.loads(parsed)

    def probe(self, *request: str, shell: str = "/bin/sh", extra_env: dict | None = None) -> dict:
        return self.parse(self.run_script(self.script(*request), shell, extra_env))

    def called(self) -> list[str]:
        return self.calls.read_text().splitlines()


class StoredPathTests(ProbeTestCase):
    def test_a_running_server_answers_with_its_instance(self) -> None:
        tmux = self.fake_tmux(self.root / "elsewhere")
        sock = self.socket_file(self.root / "s", "default", answers="4242 1700000000")
        found = self.probe("stored", str(tmux), str(sock))
        self.assertEqual(found["installation"], "usable 3.7b")
        self.assertEqual(found["executable"], str(tmux))
        self.assertEqual((found["pid"], found["startTime"]), (4242, 1700000000))
        self.assertIsNone(found["directory"])
        self.assertEqual(found["kernel"], os.uname().sysname)

    def test_every_server_command_carries_the_socket_path_and_never_starts_a_server(self) -> None:
        tmux = self.fake_tmux(self.root / "elsewhere")
        sock = self.socket_file(self.root / "s", "default", answers="1 2")
        self.probe("stored", str(tmux), str(sock))
        self.assertEqual(
            self.called(), ["-V", f"-N -S {sock} display-message -p #{{pid}} #{{start_time}}"])

    def test_a_socket_no_server_answers_on_has_no_instance(self) -> None:
        tmux = self.fake_tmux(self.root / "elsewhere")
        stale = self.socket_file(self.root / "s", "default")
        for path in (stale, self.root / "s" / "absent"):
            found = self.probe("stored", str(tmux), str(path))
            self.assertEqual(found["installation"], "usable 3.7b")
            self.assertIsNone(found["pid"])

    def test_an_executable_that_moved_reads_as_not_installed(self) -> None:
        # One on the exec's PATH is not looked for: stored paths ask only what they name.
        self.fake_tmux(self.exec_bin)
        sock = self.socket_file(self.root / "s", "default", answers="1 2")
        found = self.probe("stored", str(self.root / "gone" / "tmux"), str(sock))
        self.assertEqual(found["installation"], "notInstalled")
        self.assertIsNone(found["pid"])
        self.assertEqual(self.called(), [])

    def test_an_old_tmux_names_its_version(self) -> None:
        tmux = self.fake_tmux(self.root / "elsewhere", version="tmux 3.2a")
        sock = self.socket_file(self.root / "s", "default")
        self.assertEqual(self.probe("stored", str(tmux), str(sock))["installation"], "updateRequired 3.2a")

    def test_a_program_that_is_not_tmux_reads_as_not_installed(self) -> None:
        tmux = self.fake_tmux(self.root / "elsewhere", version="usage: something else")
        sock = self.socket_file(self.root / "s", "default")
        self.assertEqual(self.probe("stored", str(tmux), str(sock))["installation"], "notInstalled")

    def test_paths_with_spaces_and_quotes_stay_one_word(self) -> None:
        directory = self.root / "it's here"
        tmux = self.fake_tmux(directory)
        sock = self.socket_file(self.root / "a b", "default", answers="7 8")
        found = self.probe("stored", str(tmux), str(sock))
        self.assertEqual(found["executable"], str(tmux))
        self.assertEqual(found["pid"], 7)


class LoginShellTests(ProbeTestCase):
    def test_the_login_shell_finds_tmux_and_the_directory_the_exec_does_not_have(self) -> None:
        tmux = self.fake_tmux(self.login_bin)
        self.login_files_resolve()
        self.socket_file(self.login_directory, "work", answers="11 22")
        for shell in login_shells():
            with self.subTest(shell=shell):
                found = self.probe("resolve", "work", shell=shell)
                self.assertEqual(found["executable"], str(tmux))
                self.assertEqual(found["directory"], str(self.login_directory))
                self.assertEqual((found["pid"], found["startTime"]), (11, 22))

    def test_only_sockets_a_server_answers_on_are_listed(self) -> None:
        self.fake_tmux(self.login_bin)
        self.login_files_resolve()
        self.socket_file(self.login_directory, "default", answers="1 2")
        self.socket_file(self.login_directory, "work", answers="3 4")
        self.socket_file(self.login_directory, "stale")
        (self.login_directory / "not-a-socket").write_text("")
        # The exec's own directory is another place, and nothing in it is read.
        self.socket_file(self.exec_directory, "elsewhere", answers="5 6")
        for shell in login_shells():
            with self.subTest(shell=shell):
                found = self.probe("sockets", shell=shell)
                self.assertEqual(found["sockets"], ["default", "work"])
                self.assertEqual(found["installation"], "usable 3.7b")
                self.assertIsNone(found["pid"])
        self.assertFalse([call for call in self.called() if "elsewhere" in call])
        self.assertFalse([call for call in self.called() if "not-a-socket" in call])

    def test_a_frozen_server_does_not_hide_the_others(self) -> None:
        self.fake_tmux(self.login_bin)
        self.login_files_resolve()
        self.socket_file(self.login_directory, "default", answers="1 2")
        self.socket_file(self.login_directory, "frozen", answers="3 4")
        self.socket_file(self.login_directory, "work", answers="5 6")
        started = time.monotonic()
        found = self.probe("sockets")
        self.assertEqual(found["sockets"], ["default", "work"])
        self.assertLess(time.monotonic() - started, 30)

    def test_no_tmux_directory_yet_still_names_where_a_socket_would_be(self) -> None:
        self.fake_tmux(self.login_bin)
        self.login_files_resolve()
        found = self.probe("resolve", "default")
        self.assertEqual(found["directory"], str(self.login_directory))
        self.assertIsNone(found["pid"])
        self.assertEqual(self.probe("sockets")["sockets"], [])
        self.assertFalse(self.login_directory.exists())

    def sealed_env(self) -> dict:
        """An exec with no login shell and a PATH of this test's own, which no real tmux is on."""
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        for name in ("uname", "id", "sed", "sleep"):
            if not (tools / name).exists():
                (tools / name).symlink_to(shutil.which(name, path="/usr/bin:/bin"))
        refusing = self.root / "refusing-shell"
        refusing.write_text("#!/bin/sh\nexit 1\n")
        refusing.chmod(0o755)
        return {"PATH": str(tools), "SHELL": str(refusing)}

    def test_a_tmux_directory_that_does_not_exist_falls_back_as_tmux_does(self) -> None:
        # tmux ignores a TMUX_TMPDIR it cannot resolve and uses /tmp. No tmux can
        # be found in this run, so it only names that directory and asks nothing.
        found = self.probe(
            "resolve", "default", extra_env={**self.sealed_env(), "TMUX_TMPDIR": str(self.root / "missing")})
        self.assertIsNone(found["executable"])
        self.assertEqual(found["directory"], str(Path("/tmp").resolve() / f"tmux-{self.uid}"))
        self.assertEqual(self.called(), [])

    def test_no_tmux_anywhere_reads_as_not_installed(self) -> None:
        for request in (("sockets",), ("resolve", "default")):
            found = self.probe(*request, extra_env=self.sealed_env())
            self.assertEqual(found["installation"], "notInstalled")
            self.assertEqual(found["sockets"], [])
            self.assertEqual(found["directory"], str(self.exec_directory))
        self.assertEqual(self.called(), [])

    def test_a_shell_that_cannot_run_the_line_leaves_the_exec_to_answer(self) -> None:
        tmux = self.fake_tmux(self.exec_bin)
        self.socket_file(self.exec_directory, "default", answers="9 9")
        refusing = self.root / "refusing-shell"
        refusing.write_text("#!/bin/sh\necho partial output\nexit 1\n")
        refusing.chmod(0o755)
        for shell in (str(refusing), str(self.root / "no-such-shell")):
            with self.subTest(shell=shell):
                found = self.probe("resolve", "default", shell=shell)
                self.assertEqual(found["executable"], str(tmux))
                self.assertEqual(found["pid"], 9)

    def test_a_startup_file_that_ends_the_shell_early_leaves_the_exec_to_answer(self) -> None:
        tmux = self.fake_tmux(self.exec_bin)
        self.write_login_files(lambda dialect: "exit 3")
        for shell in login_shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe("resolve", "default", shell=shell)["executable"], str(tmux))

    def test_startup_output_is_ignored(self) -> None:
        self.fake_tmux(self.login_bin)
        def lines(dialect: str) -> str:
            marker = f"{NONCE} tmux begin"
            path = (f"set -gx PATH {self.login_bin} $PATH" if dialect == "fish"
                    else f"PATH={self.login_bin}:$PATH; export PATH")
            return f"{path}\necho '{marker}'\necho 'executable /nowhere/tmux'\nprintf 'no newline'"
        self.write_login_files(lines)
        for shell in login_shells():
            with self.subTest(shell=shell):
                self.assertEqual(
                    self.probe("resolve", "default", shell=shell)["executable"], str(self.login_bin / "tmux"))

    def test_output_cut_short_does_not_parse(self) -> None:
        self.fake_tmux(self.exec_bin)
        whole = self.run_script(self.script("resolve", "default"))
        cut = whole.split(f"{NONCE} tmux end".encode())[0]
        parsed = subprocess.run([str(self.binary), "parse"], input=cut, capture_output=True)
        self.assertEqual(parsed.returncode, 66)


@unittest.skipUnless(real_tmux(), "needs tmux")
class RealTmuxTests(ProbeTestCase):
    """A real tmux, on sockets under this test's own root."""

    def setUp(self) -> None:
        super().setUp()
        self.tmux = real_tmux()
        self.login_directory.mkdir(mode=0o700)
        # A configuration that creates a session on start: the probe must not start one.
        (self.home / ".tmux.conf").write_text("new-session -d -s made-by-the-configuration\n")
        link = self.login_bin / "tmux"
        link.symlink_to(self.tmux)
        self.login_files_resolve()

    def server_env(self) -> dict:
        return {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "TMUX_TMPDIR": str(self.login_tmp)}

    def start_server(self, name: str) -> Path:
        path = self.login_directory / name
        self.assertTrue(path.is_relative_to(self.root))
        subprocess.run(
            [self.tmux, "-S", str(path), "-f", "/dev/null", "new-session", "-d", "-s", "probe"],
            check=True, env=self.server_env(), capture_output=True, timeout=20)
        self.addCleanup(self.kill_server, path)
        return path

    def kill_server(self, path: Path) -> None:
        subprocess.run(
            [self.tmux, "-N", "-S", str(path), "kill-server"],
            env=self.server_env(), capture_output=True, timeout=20)

    def server_fact(self, path: Path, fact: str) -> str:
        return subprocess.run(
            [self.tmux, "-N", "-S", str(path), "display-message", "-p", f"#{{{fact}}}"],
            check=True, env=self.server_env(), capture_output=True, text=True, timeout=20).stdout.strip()

    def test_a_running_server_is_found_where_tmux_itself_puts_it(self) -> None:
        path = self.start_server("default")
        found = self.probe("resolve", "default")
        self.assertEqual(found["executable"], str(self.login_bin / "tmux"))
        self.assertTrue(found["version"].startswith("tmux "))
        self.assertEqual(f"{found['directory']}/default", self.server_fact(path, "socket_path"))
        self.assertEqual(str(found["pid"]), self.server_fact(path, "pid"))
        self.assertEqual(str(found["startTime"]), self.server_fact(path, "start_time"))

        stored = self.probe("stored", self.tmux, f"{found['directory']}/default")
        self.assertEqual(stored["pid"], found["pid"])

    def test_a_killed_servers_socket_is_not_offered(self) -> None:
        self.start_server("default")
        killed = self.start_server("killed")
        os.kill(int(self.server_fact(killed, "pid")), signal.SIGKILL)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if subprocess.run(
                [self.tmux, "-N", "-S", str(killed), "display-message", "-p", "x"],
                env=self.server_env(), capture_output=True, timeout=20).returncode != 0:
                break
            time.sleep(0.1)
        self.assertTrue(killed.is_socket())

        self.assertEqual(self.probe("sockets")["sockets"], ["default"])

    def test_asking_a_socket_with_no_server_starts_none(self) -> None:
        for request in (("resolve", "default"), ("sockets",),
                        ("stored", self.tmux, str(self.login_directory / "default"))):
            found = self.probe(*request)
            self.assertIsNone(found["pid"])
            self.assertEqual(found["sockets"], [])
        self.assertEqual(list(self.login_directory.iterdir()), [])
        self.assertFalse(self.exec_directory.exists())


if __name__ == "__main__":
    sys.exit(unittest.main())
