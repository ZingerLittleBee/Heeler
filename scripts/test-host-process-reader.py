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
import time
import unittest
from datetime import datetime, timezone
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
    var arguments: [String]?
    var descendants: String?
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
    readsOpenFiles: input.files ?? false,
    argumentsAmong: input.arguments ?? [],
    descendantsOf: input.descendants)
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
        var entry: [String: Any] = [
            "start": reading(fact.start),
            "variables": variables,
            "names": names,
            "files": reading(fact.openFiles),
        ]
        if !request.argumentsAmong.isEmpty {
            switch fact.arguments {
            case .value(let found): entry["arguments"] = found.sorted()
            case .unavailable: entry["arguments"] = "unavailable"
            }
        }
        if let parent = fact.parent { entry["parent"] = parent }
        if let name = fact.name { entry["name"] = name }
        if pid == input.descendants { entry["descendants"] = reading(fact.descendants) }
        result[pid] = entry
    }
    let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
default:
    exit(64)
}
"""


# Overwrites its argv the way libuv's process title does (Node's process.title):
# the title, then NULs to the end of the argv area, which keeps its length.
REWRITER = r"""
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char *end = argv[argc - 1] + strlen(argv[argc - 1]) + 1;
    size_t area = (size_t)(end - argv[0]);
    if (strcmp(argv[1], "keep") != 0) {
        char *title = malloc(area);
        size_t length = area - 1;
        if (strcmp(argv[1], "fill") == 0) {
            memset(title, 'x', length);
        } else {
            length = strlen(argv[1]);
            memcpy(title, argv[1], length);
        }
        memcpy(argv[0], title, length);
        memset(argv[0] + length, 0, area - length);
    }
    write(1, "ready\n", 6);
    pause();
    return 0;
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


def stat_line(pid: int, command: str, start: int, parent: int = 1) -> bytes:
    """A real stat line's shape: field 4 is the parent, field 22 the start time."""
    fields = ["S", str(parent), str(pid), str(pid), "0", "-1", "4194304"] + ["0"] * 12 + [str(start)]
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

    def process(self, pid: int, command: str = "agent", start: int = 4242, parent: int = 1) -> Path:
        directory = self.proc / str(pid)
        directory.mkdir()
        (directory / "stat").write_bytes(stat_line(pid, command, start, parent))
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


class OpenFileTests(ReaderTestCase):
    def descriptors(self, pid: int, targets: dict[int, bytes]) -> Path:
        directory = self.process(pid) / "fd"
        directory.mkdir()
        for number, target in targets.items():
            os.symlink(target, os.fsencode(directory / str(number)))
        return directory

    def test_reads_the_file_targets_a_process_holds(self) -> None:
        self.descriptors(77, {
            0: b"/dev/null",
            1: b"pipe:[1234]",
            2: b"socket:[99]",
            3: b"anon_inode:[eventpoll]",
            4: b"/home/me/.codex/sessions/rollout-1.jsonl",
            5: b"/home/me/my files/\xe8\xb7\xaf\xe5\xbe\x84.jsonl",
            6: b"/home/me/new\nline.jsonl",
            7: b"/home/me/gone.jsonl (deleted)",
        })

        def check(shell: list[str]) -> None:
            files = self.read(shell, pids=["77"], files=True)["77"]["files"]
            self.assertCountEqual(files, [
                "/dev/null",
                "/home/me/.codex/sessions/rollout-1.jsonl",
                "/home/me/my files/\u8def\u5f84.jsonl",
                "/home/me/new\nline.jsonl",
                "/home/me/gone.jsonl (deleted)",
            ])
        self.for_each_shell(check)

    def test_a_file_name_cannot_forge_another_answer(self) -> None:
        self.descriptors(77, {4: b"/x\nV 77 CLAUDE_CONFIG_DIR 2f\nE 77 ok"})

        def check(shell: list[str]) -> None:
            raw = self.run_script(shell, pids=["77"], files=True)
            self.assertNotIn("CLAUDE_CONFIG_DIR", raw)
            self.assertEqual(len(self.parse(raw, pids=["77"], files=True)["77"]["files"]), 1)
        self.for_each_shell(check)

    def test_no_descriptors_is_an_empty_answer(self) -> None:
        self.descriptors(77, {})

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["77"], files=True)["77"]["files"], [])
        self.for_each_shell(check)

    def test_a_process_whose_descriptors_cannot_be_read_is_unavailable(self) -> None:
        self.process(12)
        cases = ["12", "404"]
        if os.geteuid() != 0:
            self.descriptors(13, {4: b"/secret"}).chmod(0)
            cases.append("13")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=cases, files=True)
            for pid in cases:
                self.assertEqual(facts[pid]["files"], "unavailable", pid)
        self.for_each_shell(check)

    def test_too_many_descriptors_read_as_unavailable_rather_than_part_of_a_list(self) -> None:
        self.descriptors(77, {number: b"/f" for number in range(1025)})
        self.descriptors(78, {number: b"/f" for number in range(1024)})
        facts = self.read(["/bin/sh"], pids=["77", "78"], files=True)
        self.assertEqual(facts["77"]["files"], "unavailable")
        self.assertEqual(len(facts["78"]["files"]), 1024)

    def test_every_read_for_every_pid_comes_from_one_script(self) -> None:
        for pid in (77, 78):
            directory = self.descriptors(pid, {4: f"/open/{pid}".encode()})
            (directory.parent / "environ").write_bytes(f"NAMED={pid}\0TMUX=x\0".encode())

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["77", "78"], start=True, files=True,
                              values=["NAMED"], names=["TMUX"])
            for pid in ("77", "78"):
                self.assertEqual(facts[pid], {
                    "start": "4242",
                    "variables": {"NAMED": {"value": pid}},
                    "names": ["TMUX"],
                    "files": [f"/open/{pid}"],
                })
        self.for_each_shell(check)


class DescendantTests(ReaderTestCase):
    """A launcher, the program under it, and processes that are nothing to it."""

    def tree(self) -> None:
        self.process(10, command="npm exec", start=100)
        self.process(11, command="sh", start=110, parent=10)
        self.process(12, command="claude", start=120, parent=11)
        (self.process(12 + 1, command="node", start=130, parent=10) / "environ").write_bytes(b"A=one\0")
        (self.proc / "12" / "environ").write_bytes(b"A=two\0SECRET=do-not-print\0")
        (self.process(20, command="claude", start=200) / "environ").write_bytes(b"A=other\0")

    def test_reads_every_descendant_the_same_way_as_a_named_process(self) -> None:
        self.tree()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["10"], start=True, values=["A"], descendants="10")
            self.assertEqual(set(facts), {"10", "11", "12", "13"})
            self.assertEqual(set(facts["10"]["descendants"]), {"11", "12", "13"})
            self.assertEqual(facts["10"]["name"], "-")
            self.assertEqual(facts["11"]["parent"], "10")
            self.assertEqual(facts["12"]["parent"], "11")
            self.assertEqual(facts["12"]["name"], "claude")
            self.assertEqual(facts["12"]["start"], "120")
            self.assertEqual(facts["12"]["variables"]["A"], {"value": "two"})
            self.assertEqual(facts["13"]["variables"]["A"], {"value": "one"})
        self.for_each_shell(check)

    def test_nothing_but_the_tree_leaves_the_host(self) -> None:
        self.tree()

        def check(shell: list[str]) -> None:
            raw = self.run_script(shell, pids=["10"], start=True, values=["A"], descendants="10")
            self.assertNotIn(b"do-not-print".hex(), raw)
            self.assertNotIn("do-not-print", raw)
            self.assertNotIn("T 20 ", raw)
            self.assertNotIn(b"other".hex(), raw)
        self.for_each_shell(check)

    def test_a_process_with_no_children_has_no_descendants(self) -> None:
        self.tree()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["12"], start=True, descendants="12")
            self.assertEqual(facts["12"]["descendants"], [])
            self.assertEqual(facts["12"]["parent"], "11")
        self.for_each_shell(check)

    def test_a_command_name_cannot_forge_a_parent_or_a_line(self) -> None:
        self.process(30, command="root")
        self.process(31, command=") S 30 2 3", start=310, parent=1)
        self.process(32, command="a) b (c", start=320, parent=30)
        self.process(33, command="T 99 30 x", start=330, parent=30)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["30"], start=True, descendants="30")
            self.assertEqual(set(facts["30"]["descendants"]), {"32", "33"})
            self.assertEqual(facts["32"]["name"], "-")
            self.assertEqual(facts["33"]["name"], "-")
            self.assertEqual(facts["32"]["start"], "320")
        self.for_each_shell(check)

    def test_entries_of_proc_that_are_no_process_are_skipped(self) -> None:
        self.process(40, command="root")
        (self.proc / "self").mkdir()
        (self.proc / "self" / "stat").write_bytes(stat_line(41, "self", 1, parent=40))
        (self.proc / "42x").mkdir()
        (self.proc / "42x" / "stat").write_bytes(stat_line(42, "odd", 1, parent=40))
        (self.proc / "43").mkdir()

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["40"], descendants="40", start=True)["40"]["descendants"], [])
        self.for_each_shell(check)

    def test_too_many_descendants_read_as_unavailable_rather_than_part_of_a_tree(self) -> None:
        self.process(50, command="root")
        for pid in range(1000, 1065):
            self.process(pid, command="worker", parent=50)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["50"], start=True, descendants="50")
            self.assertEqual(set(facts), {"50"})
            self.assertEqual(facts["50"]["descendants"], "unavailable")
        self.for_each_shell(check)

    def test_a_missing_tree_answer_fails_the_read(self) -> None:
        self.tree()
        raw = self.run_script("/bin/sh".split(), pids=["10"], start=True, descendants="10")
        cut = "\n".join(line for line in raw.split("\n") if not line.startswith("W "))
        result = subprocess.run(
            [str(self.binary), "parse", json.dumps(
                {"pids": ["10"], "start": True, "descendants": "10", "root": str(self.proc)})],
            input=cut.encode(), capture_output=True,
        )
        self.assertEqual(result.returncode, 66)

    def test_the_root_must_be_a_named_process(self) -> None:
        result = subprocess.run(
            [str(self.binary), "script", json.dumps({"pids": ["10"], "descendants": "11", "root": str(self.proc)})],
            capture_output=True,
        )
        self.assertEqual(result.returncode, 65)

    def test_a_kernel_with_no_recorded_method_has_no_tree(self) -> None:
        tools = self.proc / "tools"
        tools.mkdir()
        fake = tools / "uname"
        fake.write_text("#!/bin/sh\necho FreeBSD\n")
        fake.chmod(0o755)
        request = {"pids": ["1"], "start": True, "descendants": "1", "root": None}
        script = subprocess.run(
            [str(self.binary), "script", json.dumps(request)], check=True, capture_output=True
        ).stdout

        def check(shell: list[str]) -> None:
            result = subprocess.run(
                shell, input=script, capture_output=True, timeout=60,
                env={"PATH": f"{tools}:/usr/bin:/bin"},
            )
            self.assertEqual(self.parse(result.stdout.decode(), **request)["1"]["descendants"], "unavailable")
        self.for_each_shell(check)


class ArgumentTests(ReaderTestCase):
    """Codex's shared daemon and the program it serves share a name and a scope,
    and only the arguments tell them apart."""

    ASKED = ["--managed-daemon", "app-server"]

    def cmdline(self, pid: int, data: bytes) -> None:
        (self.process(pid, command="codex") / "cmdline").write_bytes(data)

    def test_reports_only_the_arguments_it_was_asked_about(self) -> None:
        self.cmdline(10, b"/home/dev/.codex/bin/codex\0app-server\0--listen\0unix://\0--managed-daemon\0")
        self.cmdline(11, b"/usr/bin/codex\0--no-daemon\0")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["10", "11"], arguments=self.ASKED)
            self.assertEqual(facts["10"]["arguments"], ["--managed-daemon", "app-server"])
            self.assertEqual(facts["11"]["arguments"], [])
        self.for_each_shell(check)

    def test_a_last_argument_without_its_nul_still_counts(self) -> None:
        self.cmdline(10, b"codex\0--managed-daemon")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["10"], arguments=self.ASKED)
            self.assertEqual(facts["10"]["arguments"], ["--managed-daemon"])
        self.for_each_shell(check)

    def test_an_argument_merely_holding_an_asked_word_does_not_count(self) -> None:
        self.cmdline(10, b"codex\0fix app-server\0--managed-daemon=no\0")

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=["10"], arguments=self.ASKED)["10"]["arguments"], [])
        self.for_each_shell(check)

    def test_nothing_else_in_the_arguments_leaves_the_host(self) -> None:
        self.cmdline(10, b"codex\0--token\0do-not-print\0app-server\0")

        def check(shell: list[str]) -> None:
            raw = self.run_script(shell, pids=["10"], arguments=self.ASKED)
            self.assertNotIn("do-not-print", raw)
            self.assertNotIn(b"do-not-print".hex(), raw)
            self.assertNotIn(b"--token".hex(), raw)
        self.for_each_shell(check)

    def test_arguments_that_cannot_be_read_are_not_an_empty_list(self) -> None:
        self.process(10, command="codex")
        (self.process(11, command="codex") / "cmdline").write_bytes(b"")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["10", "11", "99"], arguments=self.ASKED)
            self.assertEqual(facts["10"]["arguments"], "unavailable")
            self.assertEqual(facts["11"]["arguments"], "unavailable")
            self.assertEqual(facts["99"]["arguments"], "unavailable")
        self.for_each_shell(check)

    def test_each_descendant_is_read_the_same_way(self) -> None:
        self.cmdline(10, b"codex\0")
        (self.process(11, command="codex", parent=10) / "cmdline").write_bytes(b"codex\0app-server\0")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=["10"], arguments=self.ASKED, descendants="10")
            self.assertEqual(facts["11"]["arguments"], ["app-server"])
        self.for_each_shell(check)

    def test_a_word_that_could_become_shell_or_awk_text_is_refused(self) -> None:
        self.process(10, command="codex")
        request = {"pids": ["10"], "root": str(self.proc), "arguments": ['a"b']}
        result = subprocess.run([str(self.binary), "script", json.dumps(request)], capture_output=True)
        self.assertEqual(result.returncode, 65)


class UnknownKernelTests(ReaderTestCase):
    def test_every_read_is_unavailable_on_a_kernel_with_no_recorded_method(self) -> None:
        tools = self.proc / "tools"
        tools.mkdir()
        fake = tools / "uname"
        fake.write_text("#!/bin/sh\necho FreeBSD\n")
        fake.chmod(0o755)
        request = {"pids": ["1"], "start": True, "files": True, "values": ["A"], "names": ["B"], "root": None}
        script = subprocess.run(
            [str(self.binary), "script", json.dumps(request)], check=True, capture_output=True
        ).stdout

        def check(shell: list[str]) -> None:
            result = subprocess.run(
                shell, input=script, capture_output=True, timeout=60,
                env={"PATH": f"{tools}:/usr/bin:/bin"},
            )
            self.assertEqual(self.parse(result.stdout.decode(), **request)["1"], {
                "start": "unavailable",
                "variables": {"A": "unavailable"},
                "names": "unavailable",
                "files": "unavailable",
            })
        self.for_each_shell(check)


@unittest.skipUnless(sys.platform == "darwin", "the macOS reads need a Mac")
class MacOSReadTests(ReaderTestCase):
    """Real reads on this Mac, against processes these tests start themselves
    with an environment built from scratch."""

    ENV = {
        "PATH": "/usr/bin:/bin",
        "NAMED": "with spaces OTHER=x",
        "BLANK": "",
        "LINES": "one\nFORGED=by-a-newline",
        "UNICODE": "\u8def\u5f84",
        "TMUX": "/tmp/tmux-sock,1,0",
        "HERDR_SOCKET_PATH": "/run/herdr.sock",
        "HERDR_BLANK": "",
        "NOT_ASKED": "sekrit",
    }

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        (cls.build / "rewriter.c").write_text(REWRITER)
        cls.rewriter = cls.build / "rewriter"
        subprocess.run(["cc", str(cls.build / "rewriter.c"), "-o", str(cls.rewriter)], check=True)

    def setUp(self) -> None:
        super().setUp()
        self.sleep = self.proc / "sleep-copy"
        # /bin/sleep is a platform binary, whose environment macOS withholds.
        shutil.copy("/bin/sleep", self.sleep)
        subprocess.run(["codesign", "-f", "-s", "-", str(self.sleep)], check=True, capture_output=True)
        self.running: list[subprocess.Popen] = []

    def tearDown(self) -> None:
        for process in self.running:
            process.kill()
            process.wait()
        super().tearDown()

    def start(self, program: Path | str | None = None, **options) -> str:
        process = subprocess.Popen(
            [str(program or self.sleep), "300"], env=self.ENV,
            stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            stdout=options.pop("stdout", subprocess.DEVNULL), **options)
        self.running.append(process)
        time.sleep(0.3)
        return str(process.pid)

    def start_ready(self, *argv: str, executable: str | None = None,
                    env: dict[str, str] | None = None, cwd: Path | None = None) -> str:
        """A process that says it is ready once its argv holds what it will hold."""
        process = subprocess.Popen(
            list(argv), executable=executable, env=self.ENV if env is None else env, cwd=cwd,
            stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdout=subprocess.PIPE)
        self.running.append(process)
        self.addCleanup(process.stdout.close)
        self.assertEqual(process.stdout.readline(), b"ready\n")
        return str(process.pid)

    def rewritten(self, *argv: str, **options) -> str:
        return self.start_ready(str(self.rewriter), *argv, **options)

    def test_the_host_kernel_form_takes_the_macos_branch(self) -> None:
        pid = self.start()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], values=["NAMED"], root=None)
            self.assertEqual(facts[pid]["variables"], {"NAMED": {"value": self.ENV["NAMED"]}})
        self.for_each_shell(check)

    def test_process_start_is_the_second_it_started_in_utc(self) -> None:
        before = time.time()
        pid = self.start()
        after = time.time()

        def check(shell: list[str]) -> None:
            start = self.read(shell, pids=[pid], start=True, macOS=True)[pid]["start"]
            stamp = datetime.strptime(start, "%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc).timestamp()
            self.assertGreaterEqual(stamp, int(before))
            self.assertLessEqual(stamp, after)
        self.for_each_shell(check)

    def test_process_start_does_not_follow_the_execs_zone(self) -> None:
        # Claude Code writes `LC_ALL=C TZ=UTC ps -o lstart=`, and a label outlives
        # the exec that compared it, whose startup files may set a zone.
        pid = self.start()
        request = {"pids": [pid], "start": True, "macOS": True}
        script = subprocess.run(
            [str(self.binary), "script", json.dumps(request)], check=True, capture_output=True
        ).stdout
        starts = []
        for zone in ("Asia/Tokyo", "America/New_York"):
            result = subprocess.run(
                ["/bin/sh"], input=script, capture_output=True, timeout=60,
                env={"PATH": "/usr/bin:/bin", "TZ": zone},
            )
            starts.append(self.parse(result.stdout.decode(), **request)[pid]["start"])
        expected = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", pid], capture_output=True, text=True,
            env={"LC_ALL": "C", "TZ": "UTC"},
        ).stdout.strip()
        self.assertEqual(starts, [expected, expected])

    def test_named_values_are_exact_and_told_apart_from_unset(self) -> None:
        pid = self.start()

        def check(shell: list[str]) -> None:
            asked = ["NAMED", "BLANK", "LINES", "UNICODE", "FORGED", "ABSENT"]
            variables = self.read(shell, pids=[pid], values=asked, macOS=True)[pid]["variables"]
            self.assertEqual(variables, {
                "NAMED": {"value": self.ENV["NAMED"]},
                "BLANK": {"value": ""},
                "LINES": {"value": self.ENV["LINES"]},
                "UNICODE": {"value": self.ENV["UNICODE"]},
                "FORGED": "unset",
                "ABSENT": "unset",
            })
        self.for_each_shell(check)

    def test_the_names_only_form_prints_no_equals_and_no_value(self) -> None:
        pid = self.start()

        def check(shell: list[str]) -> None:
            request = {"pids": [pid], "names": ["TMUX", "STY"], "prefixes": ["HERDR_"], "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertEqual(raw.count("="), 0, raw)
            self.assertEqual(self.parse(raw, **request)[pid]["names"], ["HERDR_SOCKET_PATH", "TMUX"])
            for word in (b"/tmp/tmux-sock", b"sekrit", b"/usr/bin"):
                self.assertNotIn(word, raw.encode())
                self.assertNotIn(word.hex().encode(), raw.encode())
        self.for_each_shell(check)

    def test_a_platform_binary_withholds_its_environment_so_it_reads_unavailable(self) -> None:
        pid = self.start("/bin/sleep")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], values=["NAMED"], names=["TMUX"], macOS=True)
            self.assertEqual(facts[pid]["variables"], {"NAMED": "unavailable"})
            self.assertEqual(facts[pid]["names"], "unavailable")
        self.for_each_shell(check)

    def test_the_shell_a_terminal_runs_withholds_its_environment_too(self) -> None:
        # The fact a check's fallback to the foreground's HC_SCOPE rests on.
        process = subprocess.Popen(
            ["/bin/zsh", "-f", "-c", "/bin/sleep 300; :"], env=self.ENV,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.running.append(process)
        time.sleep(0.3)
        pid = str(process.pid)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], start=True, values=["HC_SCOPE", "NAMED"], macOS=True)
            self.assertEqual(facts[pid]["variables"], {"HC_SCOPE": "unavailable", "NAMED": "unavailable"})
            self.assertNotEqual(facts[pid]["start"], "unavailable")
        self.for_each_shell(check)

    def test_a_title_that_fills_argv_never_reads_a_set_variable_as_unset(self) -> None:
        # Past argc lie entries the argv area no longer holds: PATH, NAMED and
        # BLANK sit where argv strings are expected.
        pid = self.rewritten("fill", "a", "b")

        def check(shell: list[str]) -> None:
            for asked in (["NAMED"], ["BLANK"], ["NAMED", "TMUX"]):
                variables = self.read(shell, pids=[pid], values=asked, macOS=True)[pid]["variables"]
                self.assertEqual(variables, {name: "unavailable" for name in asked})
            for form in ({"names": ["NAMED", "TMUX"]}, {"prefixes": ["NAM"]}):
                request = {"pids": [pid], "macOS": True, **form}
                self.assertEqual(self.read(shell, **request)[pid]["names"], "unavailable")
            variables = self.read(shell, pids=[pid], values=["TMUX", "ABSENT"], macOS=True)[pid]["variables"]
            self.assertEqual(variables, {"TMUX": {"value": self.ENV["TMUX"]}, "ABSENT": "unset"})
        self.for_each_shell(check)

    def test_an_environment_shorter_than_argv_is_not_read_as_empty(self) -> None:
        # Only NULs and dyld's strings follow where the environment should start.
        pid = self.rewritten("fill", "a", "b", "c", "d", env={"ONLY": "made-up"})

        def check(shell: list[str]) -> None:
            variables = self.read(shell, pids=[pid], values=["ONLY"], macOS=True)[pid]["variables"]
            self.assertEqual(variables, {"ONLY": "unavailable"})
            variables = self.read(shell, pids=[pid], values=["ABSENT"], macOS=True)[pid]["variables"]
            self.assertEqual(variables, {"ABSENT": "unset"})
        self.for_each_shell(check)

    def test_an_argument_shaped_like_an_asked_variable_is_never_read_as_one(self) -> None:
        pid = self.rewritten("keep", "NAMED=from-argv", "IN_ARGV=argv-only")

        def check(shell: list[str]) -> None:
            for asked in ("NAMED", "IN_ARGV"):
                request = {"pids": [pid], "values": [asked], "macOS": True}
                raw = self.run_script(shell, **request)
                self.assertNotIn(b"argv".hex(), raw)
                self.assertEqual(self.parse(raw, **request)[pid]["variables"], {asked: "unavailable"})
            request = {"pids": [pid], "names": ["IN_ARGV"], "macOS": True}
            self.assertEqual(self.read(shell, **request)[pid]["names"], "unavailable")
        self.for_each_shell(check)

    def test_an_argument_nobody_asked_about_changes_nothing(self) -> None:
        pid = self.rewritten("keep", "--flag=value", "OTHER=x", "a.js")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], values=["NAMED", "ABSENT"], names=["TMUX"], macOS=True)[pid]
            self.assertEqual(facts["variables"], {"NAMED": {"value": self.ENV["NAMED"]}, "ABSENT": "unset"})
            self.assertEqual(facts["names"], ["TMUX"])
        self.for_each_shell(check)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_node_with_a_title_that_fills_a_short_argv_is_not_read_as_unset(self) -> None:
        # `n` and `x.js` take exactly the bytes `claude` needs, so no NUL is left
        # to show that argv changed.
        (self.proc / "x.js").write_text(
            'process.title="claude";console.log("ready");setInterval(()=>{},60000)')
        env = {"FIRST": "made-up", "SECOND": "made-up-too", "TMUX": "made-up-socket"}
        pid = self.start_ready("n", "x.js", executable=shutil.which("node"), env=env, cwd=self.proc)

        def check(shell: list[str]) -> None:
            variables = self.read(shell, pids=[pid], values=["FIRST"], macOS=True)[pid]["variables"]
            self.assertEqual(variables, {"FIRST": "unavailable"})
            variables = self.read(shell, pids=[pid], values=["TMUX", "ABSENT"], macOS=True)[pid]["variables"]
            self.assertEqual(variables, {"TMUX": {"value": env["TMUX"]}, "ABSENT": "unset"})
        self.for_each_shell(check)

    def test_a_title_shorter_than_argv_leaves_the_environment_readable(self) -> None:
        pid = self.rewritten("claude", "a-long-argument", "another-long-argument")

        def check(shell: list[str]) -> None:
            asked = ["NAMED", "BLANK", "LINES", "UNICODE", "FORGED", "ABSENT"]
            variables = self.read(shell, pids=[pid], values=asked, macOS=True)[pid]["variables"]
            self.assertEqual(variables, {
                "NAMED": {"value": self.ENV["NAMED"]},
                "BLANK": {"value": ""},
                "LINES": {"value": self.ENV["LINES"]},
                "UNICODE": {"value": self.ENV["UNICODE"]},
                "FORGED": "unset",
                "ABSENT": "unset",
            })
            request = {"pids": [pid], "names": ["TMUX", "STY"], "prefixes": ["HERDR_"], "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertEqual(raw.count("="), 0, raw)
            self.assertEqual(self.parse(raw, **request)[pid]["names"], ["HERDR_SOCKET_PATH", "TMUX"])
        self.for_each_shell(check)

    def test_an_environment_with_no_entries_is_read_and_holds_nothing(self) -> None:
        kept = self.rewritten("keep", env={})
        titled = self.rewritten("claude", "a-long-argument", env={})

        def check(shell: list[str]) -> None:
            for pid in (kept, titled):
                facts = self.read(shell, pids=[pid], values=["NAMED"], names=["TMUX"], macOS=True)
                self.assertEqual(facts[pid]["variables"], {"NAMED": "unset"})
                self.assertEqual(facts[pid]["names"], [])
        self.for_each_shell(check)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_node_reads_the_same_with_and_without_a_process_title(self) -> None:
        idle = 'console.log("ready");setInterval(()=>{},60000)'
        plain = self.start_ready(shutil.which("node"), "-e", idle)
        titled = self.start_ready(shutil.which("node"), "-e", f'process.title="claude";{idle}')

        def check(shell: list[str]) -> None:
            for pid in (plain, titled):
                facts = self.read(shell, pids=[pid], values=["NAMED", "ABSENT"],
                                  names=["TMUX"], macOS=True)[pid]
                self.assertEqual(facts["variables"], {
                    "NAMED": {"value": self.ENV["NAMED"]}, "ABSENT": "unset"})
                self.assertEqual(facts["names"], ["TMUX"])
        self.for_each_shell(check)

    def test_open_files_come_back_decoded(self) -> None:
        names = ["plain.jsonl", "with space.jsonl", "\u8def\u5f84.jsonl", "new\nline.jsonl",
                 "back\\slash.jsonl"]
        pids = {}
        for name in names:
            path = self.proc / name
            with path.open("w") as output:
                pids[name] = self.start(stdout=output)

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=list(pids.values()), files=True, macOS=True)
            for name, pid in pids.items():
                self.assertIn(os.path.realpath(self.proc / name), facts[pid]["files"])
                self.assertIn("/dev/null", facts[pid]["files"])
        self.for_each_shell(check)

    def test_a_gone_process_reads_unavailable_for_every_read(self) -> None:
        pid = self.start()
        process = self.running.pop()
        process.kill()
        process.wait()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], start=True, files=True, values=["NAMED"],
                              names=["TMUX"], macOS=True)[pid]
            self.assertEqual(facts, {
                "start": "unavailable",
                "variables": {"NAMED": "unavailable"},
                "names": "unavailable",
                "files": "unavailable",
            })
        self.for_each_shell(check)

    # The tree

    def tree(self, *children: str) -> tuple[str, list[str]]:
        """A shell that holds `children` under it, and their pids once all are up."""
        body = " ".join(f"{child} &" for child in children) + " wait"
        process = subprocess.Popen(
            ["/bin/sh", "-c", body], env=self.ENV,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.running.append(process)
        pids: list[str] = []
        for _ in range(100):
            listed = subprocess.run(
                ["/bin/ps", "-ax", "-o", "pid=,ppid="], capture_output=True, text=True).stdout
            pids = [row.split()[0] for row in listed.splitlines() if row.split()[1] == str(process.pid)]
            if len(pids) == len(children):
                break
            time.sleep(0.05)
        self.assertEqual(len(pids), len(children))
        self.addCleanup(self.stop_all, pids)
        time.sleep(0.2)
        return str(process.pid), pids

    @staticmethod
    def stop_all(pids: list[str]) -> None:
        for pid in pids:
            try:
                os.kill(int(pid), 9)
            except ProcessLookupError:
                pass

    def test_a_walk_answers_with_the_tree_and_each_process_read_the_same_way(self) -> None:
        root, children = self.tree(f"{self.sleep} 300", f"{self.sleep} 301")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[root], start=True, values=["NAMED"], descendants=root, macOS=True)
            self.assertEqual(sorted(facts[root]["descendants"]), sorted(children))
            for child in children:
                self.assertEqual(facts[child]["parent"], root)
                self.assertEqual(facts[child]["name"], "sleep-copy")
                self.assertEqual(facts[child]["variables"], {"NAMED": {"value": self.ENV["NAMED"]}})
                self.assertNotEqual(facts[child]["start"], "unavailable")
        self.for_each_shell(check)

    def test_a_check_of_a_tree_carries_only_the_named_variables(self) -> None:
        # What a check of an Agent asks: the Terminal, the walk and every process
        # under it. Its environment holds HERDR_* and what nothing asked for.
        root, children = self.tree(f"{self.sleep} 300")

        def check(shell: list[str]) -> None:
            request = {
                "pids": [root], "start": True, "values": ["HC_SCOPE", "NAMED"], "names": ["TMUX"],
                "files": True, "arguments": ["--managed-daemon"], "descendants": root, "macOS": True,
            }
            raw = self.run_script(shell, **request)
            facts = self.parse(raw, **request)
            self.assertEqual(facts[children[0]]["variables"], {
                "HC_SCOPE": "unset", "NAMED": {"value": self.ENV["NAMED"]}})
            self.assertEqual(facts[children[0]]["names"], ["TMUX"])
            printed = {line.split(" ")[2] for line in raw.splitlines() if line.startswith("V ")}
            self.assertEqual(printed, {"NAMED"})
            for word in (b"sekrit", b"NOT_ASKED", b"HERDR_", b"/run/herdr.sock", b"/tmp/tmux-sock", b"/usr/bin:/bin"):
                self.assertNotIn(word, raw.encode())
                self.assertNotIn(word.hex().encode(), raw.encode())
        self.for_each_shell(check)

    def test_a_walk_with_no_children_answers_an_empty_tree(self) -> None:
        pid = self.start()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], start=True, descendants=pid, macOS=True)
            self.assertEqual(facts[pid]["descendants"], [])
            self.assertEqual(facts[pid]["name"], "sleep-copy")
        self.for_each_shell(check)

    def test_a_walk_of_a_gone_root_answers_with_nothing_under_it(self) -> None:
        pid = self.start()
        process = self.running.pop()
        process.kill()
        process.wait()

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[pid], start=True, descendants=pid, macOS=True)
            self.assertEqual(facts[pid]["descendants"], [])
            self.assertEqual(facts[pid]["start"], "unavailable")
            self.assertNotIn("name", facts[pid])
        self.for_each_shell(check)

    def test_a_title_is_the_name_a_process_goes_by(self) -> None:
        title = self.rewritten("claude", "a-long-argument", "another-long-argument")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[title], descendants=title, macOS=True)
            self.assertEqual(facts[title]["name"], "claude")
        self.for_each_shell(check)

    @unittest.skipUnless(shutil.which("node"), "needs node")
    def test_node_goes_by_the_title_it_took(self) -> None:
        pid = self.start_ready(
            shutil.which("node"), "-e", 'process.title="pi";console.log("ready");setInterval(()=>{},60000)')

        def check(shell: list[str]) -> None:
            self.assertEqual(self.read(shell, pids=[pid], descendants=pid, macOS=True)[pid]["name"], "pi")
        self.for_each_shell(check)

    def test_a_name_is_the_last_part_of_a_path_and_nothing_else_of_an_argv(self) -> None:
        root, children = self.tree(f"{self.rewriter} keep --token do-not-print")

        def check(shell: list[str]) -> None:
            request = {"pids": [root], "descendants": root, "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertNotIn("do-not-print", raw)
            self.assertNotIn(str(self.build), raw)
            self.assertIn(f"T {children[0]} {root} rewriter\n", raw)
        self.for_each_shell(check)

    def test_a_title_that_could_be_taken_for_anything_else_has_no_name(self) -> None:
        spaced = self.rewritten("a title with spaces", "a-long-argument", "another-long-argument")
        forging = self.rewritten("x\n999 1 claude", "a-long-argument", "another-long-argument")

        def check(shell: list[str]) -> None:
            facts = self.read(shell, pids=[spaced], descendants=spaced, macOS=True)
            self.assertEqual(facts[spaced]["name"], "-")
            request = {"pids": [forging], "descendants": forging, "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertNotIn("999", raw)
            self.assertEqual(self.parse(raw, **request)[forging]["descendants"], [])
        self.for_each_shell(check)

    def test_a_walk_past_its_cap_says_so_and_names_nobody(self) -> None:
        root, _ = self.tree(*[f"{self.sleep} 300"] * 65)

        def check(shell: list[str]) -> None:
            request = {"pids": [root], "descendants": root, "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertIn(f"W {root} -\n", raw)
            self.assertNotIn("T ", raw)
            self.assertEqual(self.parse(raw, **request)[root]["descendants"], "unavailable")
        self.for_each_shell(check)

    def test_a_walk_says_it_did_not_answer_when_the_listing_fails(self) -> None:
        pid = self.start()
        request = {"pids": [pid], "descendants": pid, "macOS": True}
        script = subprocess.run(
            [str(self.binary), "script", json.dumps(request)], check=True, capture_output=True
        ).stdout
        # The listing goes by full path, so a test breaks it in the script itself.
        broken = script.replace(b"/bin/ps -ax", b"/usr/bin/false -ax")
        self.assertNotEqual(broken, script)
        result = subprocess.run(["/bin/sh"], input=broken, capture_output=True, timeout=60)
        self.assertEqual(self.parse(result.stdout.decode(), **request)[pid]["descendants"], "unavailable")

    # Arguments

    ASKED_ARGUMENTS = ["--managed-daemon", "app-server", "pid-update-loop"]

    def test_arguments_report_only_the_asked_words(self) -> None:
        daemon = self.rewritten("keep", "app-server", "--listen", "unix://do-not-print", "--managed-daemon")
        loop = self.rewritten("keep", "app-server", "daemon", "pid-update-loop")
        plain = self.rewritten("keep", "--no-daemon", "--token", "do-not-print")

        def check(shell: list[str]) -> None:
            request = {"pids": [daemon, loop, plain], "arguments": self.ASKED_ARGUMENTS, "macOS": True}
            raw = self.run_script(shell, **request)
            self.assertNotIn("do-not-print", raw)
            self.assertNotIn(b"do-not-print".hex(), raw)
            self.assertNotIn(b"--no-daemon".hex(), raw)
            facts = self.parse(raw, **request)
            self.assertEqual(facts[daemon]["arguments"], ["--managed-daemon", "app-server"])
            self.assertEqual(facts[loop]["arguments"], ["app-server", "pid-update-loop"])
            self.assertEqual(facts[plain]["arguments"], [])
        self.for_each_shell(check)

    def test_an_argument_merely_holding_an_asked_word_does_not_count(self) -> None:
        pid = self.rewritten("keep", "fix app-server", "--managed-daemon=no")

        def check(shell: list[str]) -> None:
            request = {"pids": [pid], "arguments": self.ASKED_ARGUMENTS, "macOS": True}
            self.assertEqual(self.read(shell, **request)[pid]["arguments"], [])
        self.for_each_shell(check)

    def test_an_environment_entry_is_no_argument(self) -> None:
        pid = self.rewritten("keep", "a", env={"app-server": "", "--managed-daemon": "x"})

        def check(shell: list[str]) -> None:
            request = {"pids": [pid], "arguments": self.ASKED_ARGUMENTS, "macOS": True}
            self.assertEqual(self.read(shell, **request)[pid]["arguments"], [])
        self.for_each_shell(check)

    def test_a_platform_binarys_arguments_read_though_its_environment_does_not(self) -> None:
        pid = self.start("/bin/sleep")

        def check(shell: list[str]) -> None:
            request = {"pids": [pid], "arguments": self.ASKED_ARGUMENTS, "values": ["NAMED"], "macOS": True}
            facts = self.read(shell, **request)[pid]
            self.assertEqual(facts["arguments"], [])
            self.assertEqual(facts["variables"], {"NAMED": "unavailable"})
        self.for_each_shell(check)

    def test_arguments_of_a_gone_process_read_unavailable(self) -> None:
        pid = self.start()
        process = self.running.pop()
        process.kill()
        process.wait()

        def check(shell: list[str]) -> None:
            request = {"pids": [pid], "arguments": self.ASKED_ARGUMENTS, "macOS": True}
            self.assertEqual(self.read(shell, **request)[pid]["arguments"], "unavailable")
        self.for_each_shell(check)

    def test_each_descendant_has_its_arguments_read(self) -> None:
        root, children = self.tree(f"{self.rewriter} keep app-server")

        def check(shell: list[str]) -> None:
            request = {"pids": [root], "arguments": self.ASKED_ARGUMENTS, "descendants": root, "macOS": True}
            self.assertEqual(self.read(shell, **request)[children[0]]["arguments"], ["app-server"])
        self.for_each_shell(check)


if __name__ == "__main__":
    if not shutil.which("swiftc"):
        sys.exit("swiftc is required")
    unittest.main()
