#!/usr/bin/env python3
"""Run Server Kind detection's script against a fake home.

Compiles Sources/Heeler/Hosts/ServerKindDetectionScript.swift and the locator it
wraps with a small driver, then feeds the script it builds to each POSIX shell
found here, on standard input as an exec does, and hands the output to the Swift
parser. Fake `herdr`, `hc`, `herdr-core` and `tmux` programs record every call,
and every run gets a `TMUX_TMPDIR` inside its own temporary root, so these tests
never touch a real server. Needs swiftc; uses only Python's standard library.
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
    ROOT / "Sources/Heeler/Hosts/ServerKindDetectionScript.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreSessionName.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreWindowsLocator.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxProbe.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxVersion.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxSocketName.swift",
    ROOT / "scripts/fixtures/herdr-core-tool-stubs.swift",
    ROOT / "scripts/fixtures/string-localized-shim.swift",
]
NONCE = "0123456789abcdef"
# The shape of ServerKindDetection's read, with one directory the exec's PATH lacks.
HERDR_READ = 'export PATH="$HOME/.cargo/bin:$PATH"; exec herdr session list --json'
SESSIONS = '{\n  "sessions": [\n    {"name": "default", "default": true, "running": false}\n  ]\n}'

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let nonce = "%s"
switch arguments[1] {
case "script":
    FileHandle.standardOutput.write(
        ServerKindDetectionScript.script(session: arguments[2], nonce: nonce, herdrRead: arguments[3]))
case "parse":
    let output = FileHandle.standardInput.readDataToEndOfFile()
    guard let parsed = try? ServerKindDetectionScript.parse(stdout: output, session: arguments[2], nonce: nonce)
    else { exit(66) }
    let result: [String: Any?] = [
        "status": Int(parsed.herdrStatus),
        "output": String(decoding: parsed.herdrOutput, as: UTF8.self),
        "located": parsed.location != nil,
        "executable": parsed.location?.executablePath,
        "version": parsed.location?.version,
        "socket": parsed.location?.socketPath,
        "tmuxRead": parsed.tmux != nil,
        "tmuxExecutable": parsed.tmux?.executable,
        "tmuxVersion": parsed.tmux?.versionLine,
        "tmuxDirectory": parsed.tmux?.directory,
        "tmuxSockets": parsed.tmux?.sockets,
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
    return found


class DetectionTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # ServerKindDetectionTests covers the script's text and parsing on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the script")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-kind-detection-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "detection"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="hk-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.home = self.root / "h"
        self.home.mkdir()
        self.path_dir = self.root / "p"
        self.path_dir.mkdir()
        self.calls = self.root / "calls"
        self.calls.touch()
        self.program(self.path_dir / "hc", "printf 'hc 0.1.13\\n'")
        # The tmux probe's login shell reads this home's files, and never the
        # directory the user's own tmux servers listen in.
        self.tmux_tmp = self.root / "t"
        self.tmux_tmp.mkdir()
        self.tmux_directory = self.tmux_tmp / f"tmux-{os.getuid()}"
        self.assertNotEqual(self.tmux_directory, Path(f"/tmp/tmux-{os.getuid()}").resolve())

    def program(self, path: Path, body: str) -> Path:
        """A fake that records every call, then runs `body`."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\nprintf '%s %s\\n' {path.name} \"$*\" >> {self.calls}\n{body}\n")
        path.chmod(0o755)
        return path

    def herdr(self, directory: Path, *, status: int = 0, output: str = SESSIONS) -> Path:
        return self.program(directory / "herdr", f"cat <<'JSON'\n{output}\nJSON\nexit {status}")

    def core(self, directory: Path) -> Path:
        return self.program(
            directory / "herdr-core",
            'if [ "$1" = --version ]; then printf \'hc 0.1.13\\n\'; exit 0; fi\nexit 99')

    def tmux(self, directory: Path, version: str = "tmux 3.7b") -> Path:
        """A fake tmux whose server answers on a socket that has an `.up` file beside it."""
        return self.program(
            directory / "tmux",
            f"if [ \"$1\" = -V ]; then printf '%s\\n' '{version}'; exit 0; fi\n"
            'if [ "$1" = -N ] && [ "$2" = -S ] && [ "$4" = display-message ] && [ -f "$3.up" ]; then\n'
            "    printf '1 2\\n'\n    exit 0\nfi\nexit 1")

    def tmux_socket(self, name: str, answers: bool) -> None:
        self.tmux_directory.mkdir(mode=0o700, exist_ok=True)
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(self.tmux_directory / name))
        listener.close()
        if answers:
            (self.tmux_directory / f"{name}.up").touch()

    def env(self) -> dict:
        return {
            "HOME": str(self.home), "PATH": f"{self.path_dir}:/usr/bin:/bin", "SHELL": "/bin/sh",
            "TMUX_TMPDIR": str(self.tmux_tmp),
        }

    def detect(self, shell: list[str], session: str = "work", banner: bytes = b"") -> dict:
        script = subprocess.run(
            [str(self.binary), "script", session, HERDR_READ], check=True, capture_output=True
        ).stdout
        env = self.env()
        result = subprocess.run(shell, input=script, env=env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = subprocess.run(
            [str(self.binary), "parse", session], input=banner + result.stdout,
            check=True, capture_output=True,
        ).stdout
        return json.loads(parsed)

    def called(self) -> list[str]:
        return self.calls.read_text().splitlines()


class FindingTests(DetectionTestCase):
    def test_nothing_there_reads_as_neither(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["status"], 127)
                self.assertEqual(found["output"].strip(), "")
                self.assertTrue(found["located"])
                self.assertIsNone(found["executable"])
                self.assertTrue(found["tmuxRead"])
        self.assertEqual(self.called(), [])

    def test_all_three_answer_in_one_run(self) -> None:
        self.herdr(self.path_dir)
        core = self.core(self.home / ".local/bin")
        tmux = self.tmux(self.path_dir)
        self.tmux_socket("default", answers=True)
        self.tmux_socket("work", answers=True)
        self.tmux_socket("stale", answers=False)
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["status"], 0)
                self.assertEqual(found["executable"], str(core))
                self.assertEqual(found["tmuxExecutable"], str(tmux))
                self.assertEqual(found["tmuxVersion"], "tmux 3.7b")
                self.assertEqual(found["tmuxDirectory"], str(self.tmux_directory))
                self.assertEqual(found["tmuxSockets"], ["default", "work"])

    def test_the_tmux_probe_asks_through_the_login_shell(self) -> None:
        tmux = self.tmux(self.home / "off-the-exec-path")
        (self.home / ".profile").write_text(f"PATH={tmux.parent}:$PATH; export PATH\necho banner\n")
        self.tmux_socket("default", answers=True)
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["tmuxExecutable"], str(tmux))
                self.assertEqual(found["tmuxSockets"], ["default"])
                # The login shell's PATH stays out of the other two reads.
                self.assertEqual(found["status"], 127)
                self.assertIsNone(found["executable"])

    def test_tmux_is_only_asked_for_its_version_and_whether_a_server_answers(self) -> None:
        self.tmux(self.path_dir)
        self.tmux_socket("default", answers=True)
        self.detect(["/bin/sh"])
        self.assertEqual(self.called(), [
            "tmux -V",
            f"tmux -N -S {self.tmux_directory}/default display-message -p #{{pid}} #{{start_time}}",
        ])

    def test_both_answer_in_one_run(self) -> None:
        self.herdr(self.path_dir)
        program = self.core(self.home / ".local/bin")
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["status"], 0)
                self.assertEqual(json.loads(found["output"])["sessions"][0]["name"], "default")
                self.assertEqual(found["executable"], str(program))
                self.assertEqual(found["version"], "0.1.13")

    def test_the_only_calls_are_the_session_list_and_the_version(self) -> None:
        self.herdr(self.path_dir)
        self.core(self.home / ".local/bin")
        self.detect(["/bin/sh"])
        self.assertEqual(self.called(), ["herdr session list --json", "herdr-core --version"])

    def test_the_herdr_read_finds_herdr_through_its_own_path(self) -> None:
        self.herdr(self.home / ".cargo/bin")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.detect(shell)["status"], 0)

    def test_the_herdr_reads_path_does_not_reach_the_locator(self) -> None:
        self.core(self.home / ".cargo/bin")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertIsNone(self.detect(shell)["executable"])

    def test_a_failing_herdr_keeps_its_status_and_the_locator_still_runs(self) -> None:
        self.herdr(self.path_dir, status=3, output="not json")
        program = self.core(self.home / ".local/bin")
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["status"], 3)
                self.assertEqual(found["output"].strip(), "not json")
                self.assertEqual(found["executable"], str(program))

    def test_a_herdr_output_without_a_final_newline_stays_framed(self) -> None:
        self.program(self.path_dir / "herdr", "printf '{}'")
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell)
                self.assertEqual(found["status"], 0)
                self.assertEqual(found["output"].strip(), "{}")

    def test_the_typed_sessions_lock_is_read(self) -> None:
        self.core(self.home / ".local/bin")
        lock = self.home / ".local/state/herdr-core/work team/core.lock"
        lock.parent.mkdir(parents=True)
        lock.write_text("/tmp/work.sock")
        other = self.home / ".local/state/herdr-core/default/core.lock"
        other.parent.mkdir(parents=True)
        other.write_text("/tmp/default.sock")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.detect(shell, session="work team")["socket"], "/tmp/work.sock")

    def test_a_refused_session_runs_only_the_herdr_read(self) -> None:
        self.herdr(self.path_dir)
        self.core(self.home / ".local/bin")
        for shell in shells():
            with self.subTest(shell=shell):
                found = self.detect(shell, session="a/b")
                self.assertEqual(found["status"], 0)
                self.assertFalse(found["located"])
        self.assertFalse([call for call in self.called() if call.startswith("herdr-core")])

    def test_startup_output_is_ignored(self) -> None:
        self.herdr(self.path_dir)
        found = self.detect(["/bin/sh"], banner=b"Welcome\n\xff\xfe no newline")
        self.assertEqual(found["status"], 0)
        self.assertTrue(found["located"])

    def test_output_cut_short_does_not_parse(self) -> None:
        script = subprocess.run(
            [str(self.binary), "script", "work", HERDR_READ], check=True, capture_output=True
        ).stdout
        whole = subprocess.run(["/bin/sh"], input=script, env=self.env(), capture_output=True).stdout
        end = f"{NONCE} end".encode()
        status = f"{NONCE} herdr-tui status".encode()
        for cut in (whole.split(end)[0], whole.split(status)[0]):
            parsed = subprocess.run([str(self.binary), "parse", "work"], input=cut, capture_output=True)
            self.assertEqual(parsed.returncode, 66)


if __name__ == "__main__":
    sys.exit(unittest.main())
