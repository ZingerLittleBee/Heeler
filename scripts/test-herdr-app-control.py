#!/usr/bin/env python3
"""Run the desktop-app control's scripts through /bin/sh against the fixture's stub.

Compiles Sources/Heeler/Transport/HerdrCore/HerdrAppControl.swift with a small
driver, runs the status and rename scripts as an exec does, and reads them back
with the app's own parser. The stub is the one
scripts/fixtures/herdr-core-ssh.py gives a fixture. Needs swiftc; uses only
Python's standard library. Nothing here starts a core or a desktop app.
"""

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrAppControl.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreLocator.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreSessionName.swift",
    ROOT / "Sources/Heeler/Transport/HerdrCore/HerdrCoreWindowsLocator.swift",
    ROOT / "scripts/fixtures/herdr-core-tool-stubs.swift",
]
NONCE = "0123456789abcdef"

MAIN = """
import Foundation

struct GitExecResult {
    let stdout: Data
    let stderr: Data
    let exitStatus: Int32
}

let arguments = CommandLine.arguments
let nonce = "%s"
func stdinResult() -> GitExecResult {
    GitExecResult(
        stdout: FileHandle.standardInput.readDataToEndOfFile(), stderr: Data(), exitStatus: 0)
}
switch arguments[1] {
case "status":
    FileHandle.standardOutput.write(HerdrAppControl.statusScript(nonce: nonce))
case "rename":
    FileHandle.standardOutput.write(
        try HerdrAppControl.renameScript(spaceID: arguments[2], name: arguments[3], nonce: nonce))
case "is-running":
    print(HerdrAppControl.isRunning(stdinResult(), nonce: nonce))
case "outcome":
    print(HerdrAppControl.doOutcome(stdinResult(), nonce: nonce))
default:
    exit(64)
}
""" % NONCE

HOSTILE = [
    "plain", "two words", "it's", '"quoted"', "$HOME", "`id`", "*", "a;b", "2026", "true",
    "{not json", "back\\slash", "line\nbreak", "名字",
]


def load_fixture():
    path = ROOT / "scripts/fixtures/herdr-core-ssh.py"
    spec = importlib.util.spec_from_file_location("herdr_core_ssh_fixture", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class HerdrAppControlTests(unittest.TestCase):
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
        cls.fixture = load_fixture()

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def install_stub(self, directory: Path, name: str = "herdr-app") -> None:
        directory.mkdir(parents=True, exist_ok=True)
        self.fixture.write_herdr_app_stub(
            directory / name, self.fixture.herdr_app_log(self.root),
            self.fixture.herdr_app_down(self.root))

    def drive(self, *arguments: str, stdin: bytes | None = None) -> bytes:
        return subprocess.run(
            [str(self.driver), *arguments], input=stdin, check=True, capture_output=True,
            timeout=30).stdout

    def run_script(self, script: bytes, path: str | None = None) -> bytes:
        result = subprocess.run(
            ["/bin/sh", "-s"], input=b"echo welcome from the rc\n" + script,
            env={"HOME": str(self.home), "PATH": path or f"{self.bin}:/usr/bin:/bin"},
            capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def is_running(self, path: str | None = None) -> bool:
        output = self.run_script(self.drive("status"), path)
        return self.drive("is-running", stdin=output).strip() == b"true"

    def logged(self) -> list[str]:
        log = self.fixture.herdr_app_log(self.root)
        return log.read_text().splitlines() if log.exists() else []

    def rename(self, space: str, name: str) -> str:
        output = self.run_script(self.drive("rename", space, name))
        return self.drive("outcome", stdin=output).decode().strip()

    def test_status_reads_running_only_when_the_app_answers(self):
        self.assertFalse(self.is_running(), "no client on the Host")
        self.install_stub(self.bin)
        self.assertTrue(self.is_running())
        self.fixture.herdr_app_down(self.root).touch()
        self.assertFalse(self.is_running(), "a client with no window")
        self.assertEqual(self.logged(), [], "status sends no command")

    def test_status_finds_the_installers_places_off_the_exec_path(self):
        places = [
            (self.home / ".local/bin", "herdr-app"),
            (self.home / ".local/share/herdr-app", "herdr-app"),
            (self.home / "Applications/Herdr.app/Contents/MacOS", "Herdr"),
        ]
        for directory, name in places:
            with self.subTest(place=str(directory)):
                self.install_stub(directory, name)
                self.assertTrue(self.is_running("/usr/bin:/bin"))
                (directory / name).unlink()

    def test_a_directory_on_the_way_is_not_the_client(self):
        (self.home / ".local/bin/herdr-app").mkdir(parents=True)
        self.assertFalse(self.is_running("/usr/bin:/bin"))

    def test_each_name_reaches_the_client_whole_as_one_json_object(self):
        self.install_stub(self.bin)
        for index, name in enumerate(HOSTILE):
            with self.subTest(name=name):
                self.assertEqual(self.rename("sp1", name), "done")
                line = self.logged()[index]
                prefix = "do space.rename "
                self.assertTrue(line.startswith(prefix), line)
                self.assertEqual(json.loads(line[len(prefix):]), {"id": "sp1", "name": name})

    def test_a_refusal_keeps_the_apps_words(self):
        self.install_stub(self.bin)
        self.fixture.herdr_app_down(self.root).touch()
        self.assertIn("refused", self.rename("sp1", "name"))
        self.assertEqual(self.logged(), [])

    def test_no_client_is_a_refusal_not_an_unknown(self):
        self.assertIn("refused", self.rename("sp1", "name"))

    def test_the_stub_answers_nothing_else(self):
        self.install_stub(self.bin)
        result = subprocess.run(
            [str(self.bin / "herdr-app"), "space.rename"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.logged(), [])


if __name__ == "__main__":
    unittest.main()
