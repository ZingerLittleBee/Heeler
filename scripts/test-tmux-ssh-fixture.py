#!/usr/bin/env python3
"""Check the tmux SSH fixture without starting sshd.

Nothing here can reach a tmux server of yours. Every root is a temporary
directory of this test's own, the servers the real-tmux tests start listen on
`-S` paths under it (or under another temporary directory, for the server the
fixture must leave alone), and each is ended by that same path. The real-tmux
tests are skipped where no tmux is installed. Uses only Python's standard library.
"""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "tmux_ssh_fixture", Path(__file__).with_name("fixtures") / "tmux-ssh.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the tmux SSH fixture script")
FIXTURE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = FIXTURE
SPEC.loader.exec_module(FIXTURE)

UID = os.getuid()
USER_DIRECTORIES = {Path(f"/tmp/tmux-{UID}"), Path(f"/private/tmp/tmux-{UID}"), Path(f"/tmp/tmux-{UID}").resolve()}
# The startup file each shell reads as an interactive login shell.
LOGIN_SHELLS = ("sh", "dash", "bash", "ksh", "zsh", "fish")


def real_tmux() -> str | None:
    return shutil.which("tmux") or next(
        (path for path in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.access(path, os.X_OK)), None)


def login_shells() -> list[str]:
    found = ["/bin/sh"]
    for name in LOGIN_SHELLS[1:]:
        path = shutil.which(name)
        if path:
            found.append(path)
    return found


class FixtureTestCase(unittest.TestCase):
    def setUp(self) -> None:
        # Short, for the socket paths below: a Unix socket path holds about 100 bytes.
        self.root = Path(tempfile.mkdtemp(prefix="ht-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        for tmpdir in (FIXTURE.login_tmpdir(self.root), FIXTURE.exec_tmpdir(self.root)):
            directory = FIXTURE.socket_directory(tmpdir)
            self.assertNotIn(directory, USER_DIRECTORIES)
            self.assertTrue(directory.is_relative_to(self.root))

    def fake_tmux(self) -> Path:
        source = self.root.parent / f"{self.root.name}-source"
        source.mkdir()
        self.addCleanup(shutil.rmtree, source, ignore_errors=True)
        tmux = source / "tmux"
        tmux.write_text("#!/bin/sh\n[ \"$1\" = -V ] && echo 'tmux 3.7b'\nexit 0\n")
        tmux.chmod(0o755)
        return tmux

    def good_facts(self, through_login_shell: bool) -> dict:
        root = self.root
        if through_login_shell:
            return {"home": str(root / "home"), "tmpdir": str(FIXTURE.login_tmpdir(root)),
                    "tmux": str(FIXTURE.tmux_executable(root))}
        return {"home": str(root / "home"), "tmpdir": str(FIXTURE.exec_tmpdir(root)), "tmux": ""}

    def start(
        self,
        tmux: Path | str,
        facts=None,
        root: Path | None = None,
        system_tmux: str | None = None,
    ) -> tuple[int, str]:
        facts = facts or (lambda _root, _state, through_login_shell: self.good_facts(through_login_shell))
        errors = io.StringIO()
        with patch.object(FIXTURE.backend, "choose_port", return_value=47420), \
             patch.object(FIXTURE.backend, "start_sshd") as sshd, \
             patch.object(FIXTURE.backend, "stop_processes", return_value=[]) as stopped, \
             patch.object(FIXTURE, "session_facts", side_effect=facts), \
             patch.object(FIXTURE, "system_tmux", return_value=system_tmux), \
             patch.object(FIXTURE.keys, "seed", return_value=bytes(32)), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
            status = FIXTURE.main(["start", "--root", str(root or self.root), "--tmux", str(tmux)])
        self.sshd, self.stopped = sshd, stopped
        return status, errors.getvalue()

    def stop(self) -> tuple[int, str]:
        errors = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(errors):
            status = FIXTURE.main(["stop", "--root", str(self.root)])
        return status, errors.getvalue()


class SocketDirectoryTests(FixtureTestCase):
    def test_the_users_own_tmux_directory_is_refused(self) -> None:
        for directory in USER_DIRECTORIES:
            self.assertIn("user's own", FIXTURE.socket_directory_refusal(str(directory), self.root))
            self.assertIn("user's own", FIXTURE.socket_directory_refusal(str(directory / "nested"), self.root))
        # A root that holds it does not make it the fixture's.
        self.assertIn("user's own", FIXTURE.socket_directory_refusal(f"/tmp/tmux-{UID}", Path("/tmp")))

    def test_a_directory_outside_the_root_is_refused(self) -> None:
        for directory in ("/tmp/elsewhere/tmux-1", str(self.root) + "-other/t/tmux-1", "relative/tmux-1", ""):
            self.assertIsNotNone(FIXTURE.socket_directory_refusal(directory, self.root), directory)

    def test_the_fixtures_own_directories_are_taken(self) -> None:
        for tmpdir in (FIXTURE.login_tmpdir(self.root), FIXTURE.exec_tmpdir(self.root)):
            self.assertIsNone(FIXTURE.socket_directory_refusal(str(FIXTURE.socket_directory(tmpdir)), self.root))
        # Through the /tmp link too, where the root was given that way.
        linked = Path("/tmp") / self.root.name / "t" / f"tmux-{UID}"
        self.assertIsNone(FIXTURE.socket_directory_refusal(str(linked), self.root))

    def test_what_a_session_resolves_decides_whether_the_fixture_runs(self) -> None:
        login, bare = self.good_facts(True), self.good_facts(False)
        self.assertIsNone(FIXTURE.resolution_refusal(self.root, login, bare))
        refused = [
            # A login shell that read no startup file leaves tmux its default.
            (dict(login, tmpdir=""), bare),
            (dict(login, tmpdir="/tmp"), bare),
            (dict(login, tmpdir="/private/tmp"), bare),
            (dict(login, tmpdir=str(FIXTURE.exec_tmpdir(self.root))), bare),
            (dict(login, tmux="/opt/homebrew/bin/tmux"), bare),
            (dict(login, tmux=""), bare),
            (dict(login, home=str(Path.home())), bare),
            (login, dict(bare, tmpdir="")),
            (login, dict(bare, tmpdir="/tmp")),
            (login, dict(bare, tmux="/usr/bin/tmux")),
            (login, dict(bare, home=str(Path.home()))),
        ]
        for login_facts, bare_facts in refused:
            self.assertIsNotNone(FIXTURE.resolution_refusal(self.root, login_facts, bare_facts),
                                 (login_facts, bare_facts))

    def test_the_check_reads_its_own_lines_and_nothing_a_startup_file_prints(self) -> None:
        output = ("banner\nheeler-tmux-fixture-check tmux /nowhere\n\n"
                  f"{FIXTURE.CHECK_MARKER} tmpdir /a b\n{FIXTURE.CHECK_MARKER} tmux \n{FIXTURE.CHECK_MARKER} home /h\n")
        self.assertEqual(FIXTURE.parse_check(output), {"tmpdir": "/a b", "tmux": "", "home": "/h"})


class SessionEnvironmentTests(FixtureTestCase):
    def setUp(self) -> None:
        super().setUp()
        status, errors = self.start(self.fake_tmux())
        self.assertEqual(status, 0, errors)
        self.caller = self.root.parent / f"{self.root.name}-caller"
        self.caller.mkdir()
        self.addCleanup(shutil.rmtree, self.caller, ignore_errors=True)
        caller_tmux = self.caller / "tmux"
        caller_tmux.write_text("#!/bin/sh\necho 'tmux caller'\n")
        caller_tmux.chmod(0o755)

    def session(self, command: str, shell: str = "/bin/sh") -> dict:
        """What sshd's ForceCommand gives a command, with the account's login shell."""
        result = subprocess.run(
            ["/bin/sh", str(self.root / "force-command.sh")],
            env={"SSH_ORIGINAL_COMMAND": command, "SHELL": shell, "HOME": "/nonexistent",
                 "PATH": f"{self.caller}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                 "TMUX": "/tmp/tmux-0/default,1,0", "TMUX_TMPDIR": "/tmp"},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return FIXTURE.parse_check(result.stdout)

    def test_the_exec_has_no_tmux_and_a_tmux_directory_of_its_own(self) -> None:
        facts = self.session(FIXTURE.check_script(False))
        self.assertEqual(facts, dict(self.good_facts(False), tmux=FIXTURE.system_tmux() or ""))
        self.assertEqual(
            self.session("printf 'heeler-tmux-fixture-check path %s\\n' \"$PATH\"")["path"],
            FIXTURE.backend.isolated_path(self.root),
        )
        self.assertEqual(self.session("printf 'heeler-tmux-fixture-check tmux %s\\n' \"$TMUX\"")["tmux"], "")

    def test_every_login_shell_finds_tmux_and_the_fixtures_tmux_directory(self) -> None:
        for shell in login_shells():
            with self.subTest(shell=shell):
                facts = self.session(FIXTURE.check_script(True), shell)
                self.assertEqual(facts, self.good_facts(True))
                self.assertIsNone(FIXTURE.resolution_refusal(self.root, facts, self.good_facts(False)))

    def test_the_login_shells_path_is_the_fixtures_alone(self) -> None:
        expected = [str(FIXTURE.first_directory(self.root)), str(FIXTURE.tmux_directory(self.root)),
                    str(self.root / "bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        self.assertEqual(FIXTURE.login_path(self.root), expected)
        command = ("__c='printf \"\\nheeler-tmux-fixture-check path %s\\n\" \"$PATH\"'; export __c; "
                   "\"$SHELL\" -lic 'exec /bin/sh -c \"$__c\"' </dev/null 2>/dev/null")
        for shell in login_shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.session(command, shell)["path"], ":".join(expected))

    def test_a_stand_in_before_tmux_on_the_path_is_the_one_found(self) -> None:
        stand_in = FIXTURE.first_directory(self.root) / "tmux"
        stand_in.write_text("#!/bin/sh\necho 'tmux 3.2a'\n")
        stand_in.chmod(0o755)
        for shell in login_shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.session(FIXTURE.check_script(True), shell)["tmux"], str(stand_in))


class StartTests(FixtureTestCase):
    def test_start_builds_a_home_and_tmux_directories_of_its_own(self) -> None:
        tmux = self.fake_tmux()
        status, errors = self.start(tmux)
        self.assertEqual(status, 0, errors)
        self.assertEqual(self.sshd.call_args.kwargs, {"use_pam": False, "log_level": "DEBUG1"})
        root = self.root
        self.assertEqual(os.readlink(FIXTURE.tmux_executable(root)), str(tmux.resolve()))
        self.assertEqual(list(FIXTURE.first_directory(root).iterdir()), [])
        self.assertFalse((root / "bin" / "tmux").exists())
        for tmpdir in (FIXTURE.login_tmpdir(root), FIXTURE.exec_tmpdir(root)):
            directory = FIXTURE.socket_directory(tmpdir)
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(list(directory.iterdir()), [])
        for file in (".profile", ".bash_profile", ".zshrc", ".config/fish/config.fish"):
            self.assertIn(str(FIXTURE.login_tmpdir(root)), (root / "home" / file).read_text())
        self.assertIn(f"TMUX_TMPDIR={FIXTURE.exec_tmpdir(root)}", (root / "force-command.sh").read_text())

        path = root / "tmux-test-config"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        config = json.loads(base64.b64decode(path.read_text()))
        self.assertEqual(config, {
            "tmuxFixture": True, "host": "127.0.0.1", "port": 47420,
            "username": FIXTURE.backend.current_user(), "homePath": str(root / "home"),
            "tmuxExecutable": str(FIXTURE.tmux_executable(root)), "tmuxVersion": "3.7b",
            "firstDirectory": str(FIXTURE.first_directory(root)),
            "socketDirectory": str(root / "t" / f"tmux-{UID}"),
            "execSocketDirectory": str(root / "x" / f"tmux-{UID}"),
            "deviceKeySeed": base64.b64encode(bytes(32)).decode(),
        })
        self.assertNotIn("coreFixture", config)

    def test_start_refuses_a_session_that_resolves_outside_the_root(self) -> None:
        def facts(_root, _state, through_login_shell):
            found = self.good_facts(through_login_shell)
            # As when the login shell read none of the fixture's startup files.
            return dict(found, tmpdir="", tmux="/opt/homebrew/bin/tmux") if through_login_shell else found
        status, errors = self.start(self.fake_tmux(), facts)
        self.assertEqual(status, 2)
        self.assertIn("refusing to run", errors)
        self.stopped.assert_called_once()
        self.assertFalse((self.root / "tmux-test-config").exists())

    def test_start_refuses_a_root_it_cannot_keep_private_or_short(self) -> None:
        tmux = self.fake_tmux()
        with patch.object(FIXTURE.backend, "prepare_root") as prepare:
            for root in (Path(f"/tmp/tmux-{UID}"), Path(f"/tmp/tmux-{UID}/fixture"), Path("/tmp"),
                         Path("/tmp/ht with space"), self.root / ("long" * 12)):
                with self.subTest(root=root):
                    status, _ = self.start(tmux, root=root)
                    self.assertEqual(status, 2)
            prepare.assert_not_called()

    def test_start_refuses_a_tmux_it_cannot_keep_off_the_execs_path(self) -> None:
        tmux = self.fake_tmux()
        with patch.object(FIXTURE.shutil, "which", return_value="/usr/bin/tmux") as which:
            self.assertEqual(FIXTURE.system_tmux(), "/usr/bin/tmux")
        which.assert_called_once_with("tmux", path=":".join(FIXTURE.backend.SYSTEM_PATH))
        with patch.object(FIXTURE.backend, "prepare_root") as prepare:
            status, errors = self.start(tmux, system_tmux="/usr/bin/tmux")
        self.assertEqual(status, 2)
        self.assertIn("/usr/bin/tmux", errors)
        prepare.assert_not_called()

    def test_start_refuses_a_missing_tmux_and_a_root_already_in_use(self) -> None:
        self.assertEqual(self.start(self.root / "no-such-tmux")[0], 2)
        self.assertEqual(self.start(self.fake_tmux())[0], 0)
        kept = self.root / "tmux-test-config"
        before = kept.read_text()
        status, errors = self.start(FIXTURE.tmux_executable(self.root).resolve())
        self.assertEqual(status, 2)
        self.assertIn("run stop", errors)
        self.assertEqual(kept.read_text(), before)


class StopTests(FixtureTestCase):
    def test_stop_refuses_a_directory_that_is_not_a_tmux_fixture(self) -> None:
        (self.root / FIXTURE.backend.MARKER).write_text("another fixture")
        FIXTURE.backend.save_state(
            FIXTURE.backend.State(root=str(self.root), user="tester", herdr="", sessions=[]))
        status, errors = self.stop()
        self.assertEqual(status, 2)
        self.assertIn("not a tmux fixture", errors)
        self.assertTrue(self.root.exists())

    def test_stop_asks_only_the_fixtures_sockets_and_keeps_a_root_whose_server_still_answers(self) -> None:
        self.assertEqual(self.start(self.fake_tmux())[0], 0)
        sockets = []
        for tmpdir, name in ((FIXTURE.login_tmpdir(self.root), "default"), (FIXTURE.exec_tmpdir(self.root), "work")):
            path = FIXTURE.socket_directory(tmpdir) / name
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(path))
            listener.close()
            sockets.append(path)
        (FIXTURE.socket_directory(FIXTURE.login_tmpdir(self.root)) / "not-a-socket").write_text("")
        calls = self.root.parent / f"{self.root.name}-source" / "calls"
        # A tmux whose server never goes away.
        Path(os.readlink(FIXTURE.tmux_executable(self.root))).write_text(
            f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {calls}\nexit 0\n")
        with patch.object(FIXTURE.backend, "wait_until", side_effect=lambda predicate, *_: predicate()):
            status, errors = self.stop()
        self.assertNotEqual(status, 0)
        self.assertIn("still answers", errors)
        self.assertTrue((self.root / "tmux-test-config").exists())
        commands = calls.read_text().splitlines()
        self.assertTrue(commands)
        for command in commands:
            words = command.split()
            self.assertEqual(words[:2], ["-N", "-S"], command)
            self.assertIn(Path(words[2]), sockets, command)
        self.assertEqual({command.split()[3] for command in commands}, {"kill-server", "display-message"})


@unittest.skipUnless(real_tmux(), "needs tmux")
class RealTmuxStopTests(FixtureTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.tmux = real_tmux()
        status, errors = self.start(self.tmux)
        self.assertEqual(status, 0, errors)
        # A server that is not the fixture's, on a socket of this test's own.
        self.other = Path(tempfile.mkdtemp(prefix="ho-", dir="/tmp")).resolve()
        self.addCleanup(shutil.rmtree, self.other, ignore_errors=True)
        self.assertNotIn(self.other, USER_DIRECTORIES)

    def environment(self) -> dict:
        return dict(FIXTURE.backend.isolated_env(self.root, FIXTURE.backend.current_user()),
                    TMUX_TMPDIR=str(FIXTURE.exec_tmpdir(self.root)))

    def start_server(self, path: Path, executable: str) -> None:
        self.assertTrue(path.is_relative_to(self.root) or path.is_relative_to(self.other))
        subprocess.run(
            [executable, "-S", str(path), "-f", "/dev/null", "new-session", "-d", "-s", "main", "/bin/cat"],
            check=True, env=self.environment(), stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
        self.addCleanup(self.kill_server, path)

    def kill_server(self, path: Path) -> None:
        subprocess.run([self.tmux, "-N", "-S", str(path), "kill-server"], env=self.environment(),
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=20)

    def answers(self, path: Path) -> bool:
        return subprocess.run(
            [self.tmux, "-N", "-S", str(path), "display-message", "-p", "x"], env=self.environment(),
            stdin=subprocess.DEVNULL, capture_output=True, timeout=20).returncode == 0

    def test_stop_ends_the_fixtures_servers_by_their_sockets_and_no_other(self) -> None:
        fixture_tmux = str(FIXTURE.tmux_executable(self.root))
        own = [FIXTURE.socket_directory(FIXTURE.login_tmpdir(self.root)) / "default",
               FIXTURE.socket_directory(FIXTURE.login_tmpdir(self.root)) / "work"]
        for path in own:
            self.start_server(path, fixture_tmux)
        # A killed server's socket file is in the way of nothing.
        stale = FIXTURE.socket_directory(FIXTURE.exec_tmpdir(self.root)) / "stale"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(stale))
        listener.close()
        other = self.other / "s"
        self.start_server(other, self.tmux)
        self.assertTrue(all(self.answers(path) for path in own + [other]))

        status, errors = self.stop()
        self.assertEqual(status, 0, errors)
        self.assertFalse(self.root.exists())
        self.assertTrue(self.answers(other))
        self.assertEqual(FIXTURE.backend.processes_mentioning(str(self.root) + "/"), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
