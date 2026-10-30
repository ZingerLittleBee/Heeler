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
from datetime import datetime
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

    def test_process_start_is_the_second_it_started(self) -> None:
        before = time.time()
        pid = self.start()
        after = time.time()

        def check(shell: list[str]) -> None:
            start = self.read(shell, pids=[pid], start=True, macOS=True)[pid]["start"]
            stamp = datetime.strptime(start, "%a %b %d %H:%M:%S %Y").timestamp()
            self.assertGreaterEqual(stamp, int(before))
            self.assertLessEqual(stamp, after)
        self.for_each_shell(check)

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


if __name__ == "__main__":
    if not shutil.which("swiftc"):
        sys.exit("swiftc is required")
    unittest.main()
