#!/usr/bin/env python3
"""Run the Host process reader's script against fake proc trees.

Compiles Sources/Heeler/Transport/HostProcessReader.swift with a small driver,
then feeds the script it builds to each POSIX shell found here (/bin/sh, dash,
bash, ksh, busybox), as an exec does, and hands the output to the Swift parser.
Assertions look at the raw output when they are about what leaves the Host, and
at the parsed values otherwise. Needs swiftc (agent-tools CI uses the Ubuntu
image's, whose /bin/sh is dash); uses only Python's standard library.
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
READER = ROOT / "Sources/Heeler/Transport/HostProcessReader.swift"

MAIN = """
import Foundation

struct Input: Decodable {
    var pids: [String]
    var start: Bool?
    var values: [String]?
    var names: [String]?
    var prefixes: [String]?
    var files: Bool?
    var root: String?
    var macOS: Bool?
}

let arguments = CommandLine.arguments
guard let input = try? JSONDecoder().decode(Input.self, from: Data(arguments[2].utf8)) else {
    exit(64)
}
let request = HostProcessReader.Request(
    pids: input.pids,
    readsStart: input.start ?? false,
    valuesOf: input.values ?? [],
    namesOf: input.names ?? [],
    namesWithPrefix: input.prefixes ?? [],
    readsOpenFiles: input.files ?? false)
let nonce = "0123456789abcdef01234567"

func reading<Value>(_ reading: HostProcessReader.Reading<Value>) -> Any {
    switch reading {
    case .value(let value): return value
    case .unavailable: return "unavailable"
    }
}

switch arguments[1] {
case "script":
    let platform: HostProcessReader.Platform
    if input.macOS == true {
        platform = .macOS
    } else if let root = input.root {
        platform = .linux(procRoot: root)
    } else {
        platform = .hostKernel
    }
    guard let script = try? HostProcessReader.script(request, nonce: nonce, platform: platform)
    else {
        exit(65)
    }
    FileHandle.standardOutput.write(script)
case "parse":
    let output = FileHandle.standardInput.readDataToEndOfFile()
    guard let facts = try? HostProcessReader.parse(stdout: output, nonce: nonce, request: request)
    else {
        exit(66)
    }
    var result: [String: Any] = [:]
    for (pid, fact) in facts {
        var variables: [String: Any] = [:]
        for (name, variable) in fact.variables {
            switch variable {
            case .value(let value): variables[name] = ["value": value]
            case .unset: variables[name] = "unset"
            case .unavailable: variables[name] = "unavailable"
            }
        }
        let names: Any
        switch fact.nonEmptyNames {
        case .value(let found): names = found.sorted()
        case .unavailable: names = "unavailable"
        }
        result[pid] = [
            "start": reading(fact.start),
            "variables": variables,
            "names": names,
            "files": reading(fact.openFiles),
        ]
    }
    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
default:
    exit(64)
}
"""


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


def stat_line(pid: int, command: str, start: int) -> bytes:
    """A real stat line's shape: field 22 is the start time."""
    fields = ["S", "1", str(pid), str(pid), "0", "-1", "4194304"] + ["0"] * 12 + [str(start)]
    fields += ["1000", "2000"]
    return f"{pid} ({command}) {' '.join(fields)}\n".encode()


class ReaderTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-process-reader-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "reader"
        subprocess.run(
            ["swiftc", str(READER), str(cls.build / "main.swift"), "-o", str(cls.binary)],
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

    def process(self, pid: int, command: str = "agent", start: int = 4242) -> Path:
        directory = self.proc / str(pid)
        directory.mkdir()
        (directory / "stat").write_bytes(stat_line(pid, command, start))
        return directory

    def run_script(self, shell: list[str], **request) -> str:
        """The script's raw stdout, under `shell`, with an environment that
        holds none of what a test expects to read."""
        request = {"root": str(self.proc), **request}
        script = subprocess.run(
            [str(self.binary), "script", json.dumps(request)], check=True, capture_output=True
        ).stdout
        result = subprocess.run(
            shell, input=script, capture_output=True, timeout=60,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SECRET_OF_THE_EXEC": "not-this-one"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        return result.stdout.decode("ascii")

    def parse(self, raw: str, **request) -> dict:
        request = {"root": str(self.proc), **request}
        result = subprocess.run(
            [str(self.binary), "parse", json.dumps(request)],
            input=raw.encode(), capture_output=True,
        )
        self.assertEqual(result.returncode, 0, raw)
        return json.loads(result.stdout)

    def read(self, shell: list[str], **request) -> dict:
        return self.parse(self.run_script(shell, **request), **request)

    def for_each_shell(self, check) -> None:
        for shell in shells():
            with self.subTest(shell=" ".join(shell)):
                check(shell)


class StartTimeTests(ReaderTestCase):
    def test_reads_field_22_of_stat(self) -> None:
        self.process(77, start=987654321)

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["77"], start=True)["77"]["start"], "987654321")
        self.for_each_shell(check)

    def test_a_command_name_with_spaces_and_parentheses_cannot_shift_the_field(self) -> None:
        names = ["my agent", "a) b (c", ") S 1 2 3", "((x))", "tab\tname", "new\nline", "*"]
        pids = [str(100 + index) for index in range(len(names))]
        for index, name in enumerate(names):
            self.process(100 + index, command=name, start=5000 + index)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=pids, start=True)
            for index, name in enumerate(names):
                self.assertEqual(facts[pids[index]]["start"], str(5000 + index), name)
        self.for_each_shell(check)

    def test_a_gone_process_reads_as_unavailable(self) -> None:
        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["404"], start=True)["404"]["start"], "unavailable")
        self.for_each_shell(check)

    def test_a_stat_cut_short_reads_as_unavailable(self) -> None:
        directory = self.process(78)
        (directory / "stat").write_bytes(b"78 (agent) S 1 78\n")

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["78"], start=True)["78"]["start"], "unavailable")
        self.for_each_shell(check)


class NamedValueTests(ReaderTestCase):
    ENVIRON = (
        b"PATH=/usr/bin\0"
        b"CLAUDE_CONFIG_DIR=/home/me/my config=dir\0"
        b"BLANK=\0"
        b"LINES=one\ntwo\0"
        b"UNICODE=\xe8\xb7\xaf\xe5\xbe\x84\0"
        b"OTHER=sekrit\nFORGED=by-a-newline\0"
        b"CLAUDE_CONFIG_DIR_MORE=near-miss\0"
        b"TWICE=first\0"
        b"TWICE=second\0"
    )
    ASKED = ["CLAUDE_CONFIG_DIR", "BLANK", "LINES", "UNICODE", "FORGED", "ABSENT", "TWICE"]

    def environ(self, pid: int, data: bytes) -> None:
        (self.process(pid) / "environ").write_bytes(data)

    def test_named_values_are_told_apart_from_unset(self) -> None:
        self.environ(77, self.ENVIRON)

        def check(shell: list[str]) -> None:
            variables = self.read(shell, pids=["77"], values=self.ASKED)["77"]["variables"]
            self.assertEqual(variables, {
                "CLAUDE_CONFIG_DIR": {"value": "/home/me/my config=dir"},
                "BLANK": {"value": ""},
                "LINES": {"value": "one\ntwo"},
                "UNICODE": {"value": "\u8def\u5f84"},
                "FORGED": "unset",
                "ABSENT": "unset",
                "TWICE": {"value": "first"},
            })
        self.for_each_shell(check)

    def test_a_last_entry_without_its_nul_still_counts(self) -> None:
        self.environ(77, b"A=1\0B=2")

        def check(shell: list[str]) -> None:
            variables = self.read(shell, pids=["77"], values=["A", "B"])["77"]["variables"]
            self.assertEqual(variables, {"A": {"value": "1"}, "B": {"value": "2"}})
        self.for_each_shell(check)

    def test_nothing_it_was_not_asked_for_leaves_the_host(self) -> None:
        self.environ(77, self.ENVIRON)
        unasked = [b"PATH", b"/usr/bin", b"OTHER", b"sekrit", b"near-miss", b"SECRET_OF_THE_EXEC"]

        def check(shell: list[str]) -> None:
            raw = self.run_script(shell, pids=["77"], values=["CLAUDE_CONFIG_DIR"]).encode()
            for word in unasked:
                self.assertNotIn(word, raw)
                self.assertNotIn(word.hex().encode(), raw)
        self.for_each_shell(check)

    def test_a_process_whose_entries_cannot_be_read_is_not_unset(self) -> None:
        self.environ(10, b"")
        (self.process(11) / "environ").mkdir()
        self.process(12)  # no environ at all
        pids = ["10", "11", "12", "404"]
        cases = list(pids)
        if os.geteuid() != 0:
            self.environ(13, self.ENVIRON)
            (self.proc / "13/environ").chmod(0)
            cases.append("13")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=cases, values=["CLAUDE_CONFIG_DIR", "ABSENT"])
            for pid in cases:
                self.assertEqual(facts[pid]["variables"], {
                    "CLAUDE_CONFIG_DIR": "unavailable", "ABSENT": "unavailable"}, pid)
        self.for_each_shell(check)


class NamesOnlyTests(ReaderTestCase):
    ENVIRON = (
        b"PATH=/usr/bin\0"
        b"TMUX=/tmp/tmux-sock,1,0\0"
        b"STY=\0"
        b"ZELLIJ=0\0"
        b"HERDR_SOCKET_PATH=/run/herdr.sock\0"
        b"HERDR_BLANK=\0"
        b"HERDR_=only-the-prefix\0"
        b"HERDR_ODD-NAME=dash\0"
        b"NOT_HERDR_X=near-miss\0"
        b"TMUX_PANE=near-miss\0"
        b"OTHER=x\nTMUX_FORGED=y\0"
        b"OTHER2=x\nCODEX_THREAD_ID=forged\0"
    )
    REQUEST = {"names": ["TMUX", "STY", "ZELLIJ", "CODEX_THREAD_ID"], "prefixes": ["HERDR_"]}

    def test_reports_only_names_of_non_empty_listed_variables(self) -> None:
        (self.process(77) / "environ").write_bytes(self.ENVIRON)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["77"], **self.REQUEST)
            self.assertEqual(facts["77"]["names"], [
                "HERDR_", "HERDR_SOCKET_PATH", "TMUX", "ZELLIJ"])
        self.for_each_shell(check)

    def test_never_prints_an_equals_sign_or_a_value(self) -> None:
        (self.process(77) / "environ").write_bytes(self.ENVIRON)
        values = [b"/tmp/tmux-sock", b"/run/herdr.sock", b"only-the-prefix", b"near-miss", b"forged",
                  b"/usr/bin"]

        def check(shell: list[str]) -> None:
            raw = self.run_script(shell, pids=["77"], **self.REQUEST)
            self.assertEqual(raw.count("="), 0, raw)
            lines = [line for line in raw.splitlines() if line and not line.startswith("__HEELER")]
            self.assertEqual(sorted(lines), sorted([
                "N 77 TMUX", "N 77 ZELLIJ", "N 77 HERDR_SOCKET_PATH", "N 77 HERDR_", "E 77 ok"]))
            for value in values:
                self.assertNotIn(value, raw.encode())
                self.assertNotIn(value.hex().encode(), raw.encode())
        self.for_each_shell(check)

    def test_a_process_whose_entries_cannot_be_read_is_not_a_clean_one(self) -> None:
        self.process(12)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["12", "404"], **self.REQUEST)
            self.assertEqual(facts["12"]["names"], "unavailable")
            self.assertEqual(facts["404"]["names"], "unavailable")
        self.for_each_shell(check)

    def test_values_and_names_come_from_one_read(self) -> None:
        (self.process(77) / "environ").write_bytes(self.ENVIRON)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["77"], values=["ZELLIJ", "PATH"], names=["TMUX"])["77"]
            self.assertEqual(facts["names"], ["TMUX"])
            self.assertEqual(facts["variables"], {
                "ZELLIJ": {"value": "0"}, "PATH": {"value": "/usr/bin"}})
        self.for_each_shell(check)


if __name__ == "__main__":
    if not shutil.which("swiftc"):
        sys.exit("swiftc is required")
    unittest.main()
