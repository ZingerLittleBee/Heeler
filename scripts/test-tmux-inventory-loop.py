#!/usr/bin/env python3
"""Run the tmux inventory loop's script through real shells, against a real tmux.

Compiles Sources/Heeler/Transport/Tmux/TmuxInventoryLoop.swift with a small
driver, feeds the script it builds to a shell on standard input as an exec does,
and hands what the loop prints to the Swift reader.

Nothing here can reach a tmux server of yours. Every server is started by this
file on an `-S` path under its own temporary root, with a `TMUX_TMPDIR` in that
root and no `TMUX` in its environment, and is killed by that same path. Needs
swiftc and tmux, and skips where either is missing. Uses only Python's standard
library.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxInventoryLoop.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxInventory.swift",
    ROOT / "Sources/Heeler/Transport/Tmux/TmuxVersion.swift",
]
NONCE = "0123456789abcdef"

MAIN = """
import Foundation

let arguments = CommandLine.arguments
let nonce = "%s"
switch arguments[1] {
case "script":
    FileHandle.standardOutput.write(
        Data(TmuxInventoryLoop.script(executable: arguments[2], socket: arguments[3], nonce: nonce).utf8))
case "parse":
    var reader = TmuxInventoryLoop.Reader(nonce: nonce)
    var events: [[String: Any]] = []
    for event in reader.read(FileHandle.standardInput.readDataToEndOfFile()) {
        switch event {
        case .alive: events.append(["kind": "alive"])
        case .gone: events.append(["kind": "gone"])
        case .inventory(let inventory):
            events.append([
                "kind": "inventory",
                "pid": inventory.instance?.pid as Any? ?? NSNull(),
                "startTime": inventory.instance?.startTime as Any? ?? NSNull(),
                "panes": inventory.panes.map { pane -> [String: Any] in
                    [
                        "sessionID": pane.sessionID, "sessionName": pane.sessionName,
                        "windowID": pane.windowID, "windowIndex": pane.windowIndex,
                        "windowName": pane.windowName, "paneID": pane.paneID, "paneIndex": pane.paneIndex,
                        "processID": pane.processID, "command": pane.command, "path": pane.path,
                        "width": pane.width, "height": pane.height, "isDead": pane.isDead,
                        "hasPipe": pane.hasPipe, "status": pane.status, "agentSession": pane.agentSession,
                        "pipeMark": pane.pipeMark, "attachMark": pane.attachMark, "worktree": pane.worktree,
                        "arguments": pane.foregroundArguments as Any? ?? NSNull(),
                    ]
                },
            ])
        }
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]))
default:
    exit(64)
}
""" % NONCE


def real_tmux() -> str | None:
    # HEELER_TEST_TMUX names another tmux to run against, such as an old version.
    return os.environ.get("HEELER_TEST_TMUX") or shutil.which("tmux") or next(
        (path for path in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.access(path, os.X_OK)), None)


def shells() -> list[str]:
    found = ["/bin/sh"]
    for name in ("dash", "bash", "ksh"):
        path = shutil.which(name)
        if path:
            found.append(path)
    return found


class Loop:
    """One run of the script, as an exec holds it: its input stays open until `close`."""

    def __init__(self, case: "LoopTestCase", script: bytes, shell: str) -> None:
        self.case = case
        self.output = bytearray()
        self.process = subprocess.Popen(
            [shell, "-s"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=case.env, start_new_session=True)
        self.process.stdin.write(script)
        self.process.stdin.flush()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        while True:
            chunk = self.process.stdout.read1(65536)
            if not chunk:
                return
            self.output.extend(chunk)

    def events(self) -> list[dict]:
        return self.case.parse(bytes(self.output))

    def inventories(self) -> list[dict]:
        return [event for event in self.events() if event["kind"] == "inventory"]

    def snapshots(self) -> list[bytes]:
        """What the loop printed for each snapshot, begin marker to end marker."""
        parts = bytes(self.output).split(f"{NONCE} begin\n".encode())[1:]
        return [part for part in parts if f"\n{NONCE} end\n".encode() in part]

    def argument_lines(self, snapshot: int) -> list[str]:
        """The panes whose arguments a snapshot carried, as the loop printed them."""
        tail = self.snapshots()[snapshot].split(f"\n{NONCE} argv\n".encode())[-1]
        return [line.decode() for line in tail.split(b"\n") if line[:2] in (b"A ", b"a ")]

    def wait_for(self, count: int, timeout: float = 10) -> list[dict]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            found = self.inventories()
            if len(found) >= count:
                return found
            time.sleep(0.1)
        self.case.fail(f"only {len(self.inventories())} of {count} snapshots: {bytes(self.output)!r}")

    def close(self) -> None:
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        # A pause still in flight holds the output open for up to a second.
        self.reader.join(timeout=3)
        for stream in (self.process.stdout, self.process.stderr):
            if stream and not self.reader.is_alive():
                stream.close()


class LoopTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # TmuxInventoryLoopTests covers the script's text and the reader on any machine.
        if shutil.which("swiftc") is None:
            raise unittest.SkipTest("needs swiftc to build the script")
        cls.tmux_path = real_tmux()
        if cls.tmux_path is None:
            raise unittest.SkipTest("needs tmux")
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-tmux-loop-build-"))
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "loop"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        # Short, for the socket path: a Unix socket path holds about 100 bytes.
        self.root = Path(tempfile.mkdtemp(prefix="ht-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.socket = self.root / "s"
        tmp = self.root / "t"
        tmp.mkdir()
        self.assertNotEqual(self.socket.parent, Path(f"/tmp/tmux-{os.getuid()}").resolve())
        # No `TMUX` of the caller's, and a tmux directory of this test's own.
        self.env = {
            "HOME": str(self.root),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/sh",
            "TMUX_TMPDIR": str(tmp),
            "LANG": "C",
        }
        self.loops: list[Loop] = []
        self.addCleanup(self.stop_everything)

    def stop_everything(self) -> None:
        for loop in self.loops:
            loop.close()
        # Only the server on this test's own socket path.
        subprocess.run(
            [self.tmux_path, "-N", "-S", str(self.socket), "kill-server"],
            env=self.env, capture_output=True, stdin=subprocess.DEVNULL)

    def tmux(self, *arguments: str, check: bool = True) -> str:
        result = subprocess.run(
            [self.tmux_path, "-u", "-f", "/dev/null", "-S", str(self.socket), *arguments],
            env=self.env, capture_output=True, stdin=subprocess.DEVNULL)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.decode()

    def start_server(self, command: str = "exec /bin/sleep 600") -> None:
        # Named, so tmux does not rename the window after its program a moment later.
        self.tmux("new-session", "-d", "-s", "main", "-n", "first", "-x", "80", "-y", "24", command)

    def script(self, without_perl: bool = False) -> bytes:
        script = subprocess.run(
            [str(self.binary), "script", self.tmux_path, str(self.socket)], check=True, capture_output=True).stdout
        if without_perl:
            self.assertIn(b"\nP=/usr/bin/perl\n", script)
            script = script.replace(b"\nP=/usr/bin/perl\n", b"\nP=/nonexistent/perl\n")
        return script

    def loop(self, shell: str = "/bin/sh", without_perl: bool = False) -> Loop:
        loop = Loop(self, self.script(without_perl), shell)
        self.loops.append(loop)
        return loop

    def parse(self, output: bytes) -> list[dict]:
        parsed = subprocess.run(
            [str(self.binary), "parse"], input=output, check=True, capture_output=True).stdout
        return json.loads(parsed)

    def instance(self) -> tuple[int, int]:
        pid, start = self.tmux("display-message", "-p", "#{pid} #{start_time}").split()
        return int(pid), int(start)


class ChangeOnlyTests(LoopTestCase):
    def test_it_prints_once_and_then_only_on_change_in_every_shell(self) -> None:
        self.start_server()
        for shell in shells():
            with self.subTest(shell=shell):
                loop = self.loop(shell)
                first = loop.wait_for(1)
                self.assertEqual((first[0]["pid"], first[0]["startTime"]), self.instance())
                # Three asks later it has still said it once.
                time.sleep(3)
                self.assertEqual(len(loop.inventories()), 1)
                before = len(first[0]["panes"])
                self.tmux("new-window", "-d", "-t", "main:", "-n", shell.replace("/", "-"), "exec /bin/sleep 600")
                second = loop.wait_for(2)
                self.assertEqual(len(second[1]["panes"]), before + 1)
                time.sleep(2)
                self.assertEqual(len(loop.inventories()), 2)
                loop.close()

    def test_a_new_window_and_a_rename_each_print_one_snapshot(self) -> None:
        self.start_server()
        loop = self.loop()
        first = loop.wait_for(1)[0]
        self.assertEqual([pane["windowName"] for pane in first["panes"]], ["first"])
        self.tmux("new-window", "-d", "-t", "main:", "-n", "build", "exec /bin/sleep 600")
        second = loop.wait_for(2)[1]
        self.assertEqual([pane["windowName"] for pane in second["panes"]], ["first", "build"])
        self.assertEqual([pane["windowIndex"] for pane in second["panes"]], [0, 1])
        self.tmux("rename-window", "-t", "main:1", "release é")
        self.tmux("rename-session", "-t", "main", "work")
        third = loop.wait_for(3)[-1]
        self.assertEqual([pane["windowName"] for pane in third["panes"]], ["first", "release é"])
        self.assertEqual({pane["sessionName"] for pane in third["panes"]}, {"work"})

    def test_it_says_it_is_alive_while_nothing_changes(self) -> None:
        self.start_server()
        loop = self.loop()
        loop.wait_for(1)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and not any(event["kind"] == "alive" for event in loop.events()):
            time.sleep(0.2)
        kinds = [event["kind"] for event in loop.events()]
        self.assertEqual(kinds[0], "inventory")
        self.assertIn("alive", kinds)
        self.assertEqual(kinds.count("inventory"), 1)

    def test_the_format_holds_nothing_that_changes_on_its_own(self) -> None:
        # A pane that writes and moves its cursor and title every 200 ms.
        self.start_server(
            "exec /bin/sh -c 'while :; do printf \"\\033]2;title %s\\033\\\\\\\\x\\n\" \"$(date +%s)\"; sleep 0.2; done'")
        loop = self.loop()
        loop.wait_for(1)
        time.sleep(4)
        self.assertEqual(len(loop.inventories()), 1)


class RowTests(LoopTestCase):
    def test_rows_carry_ids_names_sizes_and_the_heeler_options(self) -> None:
        self.start_server()
        self.tmux("split-window", "-h", "-d", "-t", "main:0", "exec /bin/sleep 600")
        self.tmux("new-session", "-d", "-s", "other", "-n", "elsewhere", "-x", "100", "-y", "30", "exec /bin/sleep 600")
        self.tmux("set-option", "-p", "-t", "main:0.0", "@heeler-status", "state=working:app=claude-code")
        self.tmux("set-option", "-p", "-t", "main:0.0", "@heeler-session", "abc")
        self.tmux("set-option", "-p", "-t", "main:0.0", "@heeler-pipe", "1")
        self.tmux("set-option", "-t", "other", "@heeler-attach", "1")
        self.tmux("set-option", "-t", "other", "@heeler-worktree", "/tmp/checkout")
        panes = self.loop().wait_for(1)[0]["panes"]
        ids = self.tmux(
            "list-panes", "-a", "-F", "#{session_id} #{window_id} #{pane_id} #{pane_index} #{pane_pid}").split("\n")[:-1]
        self.assertEqual(
            [f"{p['sessionID']} {p['windowID']} {p['paneID']} {p['paneIndex']} {p['processID']}" for p in panes], ids)
        first, second, other = panes
        self.assertEqual((first["sessionName"], first["windowName"], first["windowIndex"]), ("main", "first", 0))
        self.assertEqual((first["status"], first["agentSession"], first["pipeMark"]),
                         ("state=working:app=claude-code", "abc", "1"))
        self.assertEqual((first["attachMark"], first["worktree"]), ("", ""))
        self.assertEqual((second["status"], second["agentSession"], second["pipeMark"]), ("", "", ""))
        self.assertEqual(first["width"] + second["width"] + 1, 80)
        self.assertEqual(
            (other["sessionName"], other["windowName"], other["width"], other["height"]),
            ("other", "elsewhere", 100, 30))
        self.assertEqual((other["attachMark"], other["worktree"]), ("1", "/tmp/checkout"))
        self.assertEqual([pane["isDead"] for pane in panes], [False, False, False])
        self.assertEqual([pane["hasPipe"] for pane in panes], [False, False, False])
        self.assertEqual(first["command"], "sleep")
        self.assertEqual(Path(first["path"]).resolve(), Path(os.getcwd()).resolve())

    def test_text_with_tabs_newlines_and_marker_lines_stays_in_its_field(self) -> None:
        directory = self.root / "a\tb\nc d"
        directory.mkdir()
        self.start_server()
        self.tmux("new-window", "-d", "-t", "main:", "-n", "odd", "-c", str(directory), "exec /bin/sleep 600")
        # What a row, a marker and the end of a snapshot look like, inside one option.
        forged = (f"state=idle\n{NONCE} argv\n{NONCE} end\n{NONCE} begin\n"
                  "1\t2\t$9\t@9\t0\t%9\t0\t1\t80\t24\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\n.\n\n")
        self.tmux("set-option", "-p", "-t", "main:1.0", "@heeler-status", forged)
        loop = self.loop()
        found = loop.wait_for(1)
        time.sleep(2)
        self.assertEqual(len(loop.inventories()), 1)
        panes = found[0]["panes"]
        self.assertEqual([pane["paneID"] for pane in panes], ["%0", "%1"])
        self.assertEqual(Path(panes[1]["path"]), directory)
        self.assertEqual(panes[1]["status"], forged)
        self.assertEqual(panes[1]["arguments"], ["/bin/sleep", "600"])

    def test_a_window_linked_into_two_sessions_is_listed_under_each(self) -> None:
        self.start_server()
        self.tmux("new-session", "-d", "-s", "second", "-n", "own", "-x", "80", "-y", "24", "exec /bin/sleep 600")
        self.tmux("link-window", "-s", "main:0", "-t", "second:5")
        panes = self.loop().wait_for(1)[0]["panes"]
        self.assertEqual(
            [(pane["sessionName"], pane["windowIndex"], pane["paneID"]) for pane in panes],
            [("main", 0, "%0"), ("second", 0, "%1"), ("second", 5, "%0")])
        self.assertEqual(panes[0]["windowID"], panes[2]["windowID"])
        # Its arguments are read once and belong to both rows.
        self.assertEqual(panes[0]["arguments"], ["/bin/sleep", "600"])
        self.assertEqual(panes[2]["arguments"], ["/bin/sleep", "600"])

    def test_a_dead_pane_stays_listed_as_dead(self) -> None:
        self.start_server()
        self.tmux("set-option", "-g", "remain-on-exit", "on")
        self.tmux("new-window", "-d", "-t", "main:", "-n", "over", "exec /usr/bin/true")
        loop = self.loop()
        deadline = time.monotonic() + 10
        panes: list[dict] = []
        while time.monotonic() < deadline:
            found = loop.inventories()
            panes = found[-1]["panes"] if found else []
            if len(panes) == 2 and panes[1]["isDead"]:
                break
            time.sleep(0.1)
        self.assertEqual([pane["isDead"] for pane in panes], [False, True])
        self.assertIsNone(panes[1]["arguments"])


class ArgumentTests(LoopTestCase):
    def test_arguments_come_with_the_first_snapshot_and_then_only_for_a_changed_program(self) -> None:
        self.start_server()
        self.tmux("new-window", "-d", "-t", "main:", "-n", "second", "exec /bin/sh -c 'sleep 601; :' 'two words'")
        loop = self.loop()
        first = loop.wait_for(1)[0]
        self.assertEqual(first["panes"][0]["arguments"], ["/bin/sleep", "600"])
        self.assertEqual(first["panes"][1]["arguments"], ["/bin/sh", "-c", "sleep 601; :", "two words"])
        self.assertEqual([line.split()[1] for line in loop.argument_lines(0)], ["%0", "%1"])

        # A rename changes the snapshot and no program: nothing is read again.
        self.tmux("rename-window", "-t", "main:1", "renamed")
        second = loop.wait_for(2)[1]
        self.assertEqual(loop.argument_lines(1), [])
        self.assertEqual(second["panes"][1]["arguments"], ["/bin/sh", "-c", "sleep 601; :", "two words"])

        # A status that names a program reads its pane again.
        self.tmux("set-option", "-p", "-t", "main:1.0", "@heeler-status", "state=working:app=codex")
        third = loop.wait_for(3)[2]
        self.assertEqual([line.split()[1] for line in loop.argument_lines(2)], ["%1"])
        # Another state of the same program reads nothing.
        self.tmux("set-option", "-p", "-t", "main:1.0", "@heeler-status", "state=idle:app=codex:turn=1")
        loop.wait_for(4)
        self.assertEqual(loop.argument_lines(3), [])
        # Another program in the status does.
        self.tmux("set-option", "-p", "-t", "main:1.0", "@heeler-status", "state=idle:app=claude-code:turn=1")
        loop.wait_for(5)
        self.assertEqual([line.split()[1] for line in loop.argument_lines(4)], ["%1"])
        self.assertEqual(third["panes"][1]["arguments"], ["/bin/sh", "-c", "sleep 601; :", "two words"])

    def test_another_foreground_command_is_read_again(self) -> None:
        self.start_server("exec /bin/sh -c 'sleep 3; exec /bin/cat /dev/zero'")
        loop = self.loop()
        first = loop.wait_for(1)[0]
        self.assertEqual(first["panes"][0]["arguments"][:2], ["/bin/sh", "-c"])
        second = loop.wait_for(2)[1]
        self.assertEqual(second["panes"][0]["command"], "cat")
        self.assertEqual(second["panes"][0]["arguments"], ["/bin/cat", "/dev/zero"])
        self.assertEqual([line.split()[1] for line in loop.argument_lines(1)], ["%0"])

    @unittest.skipUnless(sys.platform == "darwin", "macOS reads arguments through perl")
    def test_without_perl_macos_gives_the_process_words_in_one_line(self) -> None:
        self.start_server()
        loop = self.loop(without_perl=True)
        first = loop.wait_for(1)[0]
        self.assertEqual(first["panes"][0]["arguments"], ["/bin/sleep", "600"])
        self.assertEqual([line.split()[0] for line in loop.argument_lines(0)], ["a"])


class LifetimeTests(LoopTestCase):
    def processes(self) -> list[str]:
        listing = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        return [line for line in listing.splitlines() if str(self.socket) in line and "kill-server" not in line]

    def test_it_never_starts_a_server(self) -> None:
        loop = self.loop()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and loop.process.poll() is None:
            time.sleep(0.1)
        self.assertIsNotNone(loop.process.poll())
        self.assertEqual([event["kind"] for event in loop.events()], ["gone"])
        self.assertFalse(self.socket.exists())
        script = self.script().decode()
        commands = [line for line in script.splitlines() if "list-panes" in line]
        self.assertEqual(len(commands), 1)
        self.assertIn('"$t" -N -u -S "$s" list-panes -a -F "$F"', commands[0])

    def test_it_stops_when_the_server_stops(self) -> None:
        self.start_server()
        loop = self.loop()
        loop.wait_for(1)
        self.tmux("kill-server")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and loop.process.poll() is None:
            time.sleep(0.1)
        self.assertIsNotNone(loop.process.poll())
        self.assertEqual([event["kind"] for event in loop.events()][-1], "gone")

    def test_it_stops_when_its_input_closes(self) -> None:
        self.start_server()
        loop = self.loop()
        loop.wait_for(1)
        loop.process.stdin.close()
        self.assertIsNotNone(loop.process.wait(timeout=5))
        # The ask in flight and its one-second pause end on their own.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and len(self.processes()) > 1:
            time.sleep(0.1)
        self.assertEqual(len(self.processes()), 1, self.processes())

    def test_a_restarted_server_is_another_instance_with_the_same_pane_ids(self) -> None:
        self.start_server()
        first_loop = self.loop()
        first = first_loop.wait_for(1)[0]
        self.tmux("kill-server")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and self.socket.exists():
            time.sleep(0.1)
        # tmux's start time counts seconds.
        time.sleep(1.1)
        self.start_server()
        second = self.loop().wait_for(1)[0]
        self.assertEqual([pane["paneID"] for pane in second["panes"]], [pane["paneID"] for pane in first["panes"]])
        self.assertNotEqual((second["pid"], second["startTime"]), (first["pid"], first["startTime"]))
        self.assertEqual((second["pid"], second["startTime"]), self.instance())


if __name__ == "__main__":
    unittest.main()
