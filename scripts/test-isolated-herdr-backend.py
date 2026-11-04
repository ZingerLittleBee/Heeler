#!/usr/bin/env python3
"""Check the isolated herdr backend's pure parts without starting herdr or sshd."""

from __future__ import annotations

import base64
import contextlib
import io
import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "isolated_herdr_backend", Path(__file__).with_name("isolated-herdr-backend.py"))
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the isolated herdr backend script")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

CORE_SPEC = importlib.util.spec_from_file_location(
    "core_ssh_fixture", Path(__file__).with_name("fixtures") / "herdr-core-ssh.py")
if CORE_SPEC is None or CORE_SPEC.loader is None:
    raise RuntimeError("Cannot load the herdr-core SSH fixture script")
CORE = importlib.util.module_from_spec(CORE_SPEC)
sys.modules[CORE_SPEC.name] = CORE
CORE_SPEC.loader.exec_module(CORE)

RPC_SPEC = importlib.util.spec_from_file_location(
    "core_rpc_helper", Path(__file__).with_name("fixtures") / "herdr-core-rpc.py")
if RPC_SPEC is None or RPC_SPEC.loader is None:
    raise RuntimeError("Cannot load the herdr-core RPC helper script")
RPC = importlib.util.module_from_spec(RPC_SPEC)
sys.modules[RPC_SPEC.name] = RPC
RPC_SPEC.loader.exec_module(RPC)

# A fixed ed25519 public key; its OpenSSH fingerprint is computed independently below.
HOST_KEY = ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL/TtCrTn19JU6AMQvLzHjYdHuV7TZEKSa7v7BfVdStP "
            "fixture")


class IsolatedEnvironmentTests(unittest.TestCase):
    def test_environment_inherits_nothing_from_the_caller(self) -> None:
        inherited = {"HERDR_SOCKET_PATH": "/Users/me/.config/herdr/herdr.sock",
                     "HERDR_SESSION": "work", "HERDR_ENV": "1", "XDG_CONFIG_HOME": "/elsewhere",
                     "HOME": "/Users/me", "PATH": "/opt/homebrew/bin:/usr/bin"}
        with patch.dict(os.environ, inherited):
            env = MODULE.isolated_env(Path("/tmp/heeler-iso"), "tester")
        self.assertFalse([name for name in env if name.startswith(("HERDR_", "XDG_"))])
        self.assertEqual(env["HOME"], "/tmp/heeler-iso/home")
        self.assertEqual(env["PATH"].split(":")[0], "/tmp/heeler-iso/bin")
        self.assertNotIn("/opt/homebrew/bin", env["PATH"])
        self.assertEqual(env["USER"], "tester")

    def test_force_command_drops_herdr_variables_and_runs_the_original_command(self) -> None:
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            root = Path(directory)
            script = root / "force-command.sh"
            script.write_text(MODULE.force_command_script(root))
            hostile = {"HERDR_SOCKET_PATH": "/live/herdr.sock", "HERDR_SESSION": "work",
                       "XDG_CONFIG_HOME": "/live", "HOME": "/live-home", "PATH": "/usr/bin:/bin",
                       "SSH_ORIGINAL_COMMAND": "env"}
            output = subprocess.run(["/bin/sh", str(script)], env=hostile, capture_output=True,
                                    text=True, check=True).stdout
        values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        self.assertFalse([name for name in values if name.startswith(("HERDR_", "XDG_"))])
        self.assertEqual(values["HOME"], f"{root}/home")
        self.assertTrue(values["PATH"].startswith(f"{root}/bin:"))


class SocketPathGuardTests(unittest.TestCase):
    def test_named_session_client_socket_is_the_longest_path(self) -> None:
        paths = MODULE.socket_paths(Path("/tmp/heeler-iso"), "work")
        self.assertEqual(str(paths["client"]),
                         "/tmp/heeler-iso/home/.config/herdr/sessions/work/herdr-client.sock")
        default = MODULE.socket_paths(Path("/tmp/heeler-iso"), "default")
        self.assertEqual(str(default["api"]), "/tmp/heeler-iso/home/.config/herdr/herdr.sock")

    def test_guard_allows_exactly_the_limit_and_refuses_one_byte_more(self) -> None:
        suffix = len("/home/.config/herdr/sessions/work/herdr-client.sock")
        fits = Path("/" + "r" * (MODULE.MAX_SOCKET_PATH_BYTES - suffix - 1))
        MODULE.check_socket_paths(fits, ["default", "work"])
        too_long = Path(str(fits) + "x")
        with self.assertRaisesRegex(MODULE.BackendError, "104 bytes"):
            MODULE.check_socket_paths(too_long, ["default", "work"])

    def test_default_root_fits_with_a_long_session_name(self) -> None:
        MODULE.check_socket_paths(MODULE.DEFAULT_ROOT, ["default", "w" * 20])

    def test_session_names_follow_herdr_rules(self) -> None:
        self.assertEqual(MODULE.validate_sessions(["default", "work.1_a-b"]),
                         ["default", "work.1_a-b"])
        for bad in ([], [".."], ["a/b"], ["x" * 65], ["work", "work"]):
            with self.subTest(bad=bad), self.assertRaises(MODULE.BackendError):
                MODULE.validate_sessions(bad)

    def test_default_session_maps_to_blank_app_session_and_no_cli_flag(self) -> None:
        self.assertEqual(MODULE.herdr_session_args("default"), [])
        self.assertEqual(MODULE.herdr_session_args("work"), ["--session", "work"])
        self.assertEqual(MODULE.app_session_name("default"), "")


class SshdConfigTests(unittest.TestCase):
    def test_config_mirrors_the_ci_fixture_and_isolates_home(self) -> None:
        root = Path("/tmp/heeler-iso")
        lines = MODULE.sshd_config(root, 47420, "tester", "/usr/libexec/sftp-server").splitlines()
        for expected in ("Port 47420", "ListenAddress 127.0.0.1",
                         "HostKey /tmp/heeler-iso/ssh/host_ed25519",
                         "PidFile /tmp/heeler-iso/ssh/sshd.pid",
                         "AuthorizedKeysFile /tmp/heeler-iso/ssh/authorized_keys",
                         "PasswordAuthentication no", "AllowUsers tester", "StrictModes no",
                         "PerSourcePenalties no", "AllowStreamLocalForwarding yes",
                         "Subsystem sftp /usr/libexec/sftp-server",
                         "SetEnv HOME=/tmp/heeler-iso/home",
                         "ForceCommand exec /bin/sh /tmp/heeler-iso/force-command.sh"):
            self.assertIn(expected, lines)

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/sbin/sshd").exists(),
                         "the backend targets the macOS system sshd")
    def test_config_passes_sshd_syntax_check(self) -> None:
        sshd = "/usr/sbin/sshd"
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            root = Path(directory)
            (root / "ssh").mkdir()
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                            str(root / "ssh" / "host_ed25519")], check=True)
            config = root / "sshd.conf"
            config.write_text(MODULE.sshd_config(root, 47420, MODULE.current_user(),
                                                 "/usr/libexec/sftp-server"))
            result = subprocess.run([sshd, "-t", "-f", str(config)], capture_output=True,
                                    text=True, check=False)
        if "Unsupported option" in result.stderr or "Bad configuration option" in result.stderr:
            self.skipTest(f"older sshd: {result.stderr.strip()}")
        self.assertEqual(result.returncode, 0, result.stderr)


class FingerprintTests(unittest.TestCase):
    def test_known_host_entry_uses_the_app_key_format(self) -> None:
        entry = MODULE.known_host_entry("127.0.0.1", 47420, HOST_KEY)
        blob = base64.b64decode(HOST_KEY.split()[1])
        self.assertEqual(entry, {"v2|15|127.0.0.1:47420|ssh-ed25519":
                                 base64.b64encode(hashlib.sha256(blob).digest()).decode()})
        self.assertTrue(next(iter(entry.values())).endswith("="))

    def test_endpoint_length_counts_utf8_bytes(self) -> None:
        entry = MODULE.known_host_entry("hôte", 22, HOST_KEY)
        self.assertEqual(next(iter(entry)), "v2|8|hôte:22|ssh-ed25519")

    def test_algorithm_comes_from_the_key_blob_not_the_label(self) -> None:
        relabeled = "ssh-rsa " + HOST_KEY.split()[1]
        self.assertTrue(next(iter(MODULE.known_host_entry("h", 1, relabeled))).endswith("|ssh-ed25519"))

    @unittest.skipUnless(shutil.which("ssh-keygen"), "no ssh-keygen")
    def test_display_fingerprint_matches_openssh(self) -> None:
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            key = Path(directory) / "host.pub"
            key.write_text(HOST_KEY + "\n")
            openssh = subprocess.run(["ssh-keygen", "-lf", str(key)], capture_output=True,
                                     text=True, check=True).stdout.split()[1]
        self.assertEqual(MODULE.display_fingerprint(HOST_KEY), openssh)

    def test_rejects_a_non_key(self) -> None:
        with self.assertRaises(MODULE.BackendError):
            MODULE.known_host_entry("h", 1, "not-a-key")


class StateAndHostTests(unittest.TestCase):
    def test_state_round_trips_through_json(self) -> None:
        state = MODULE.State(
            root="/tmp/heeler-iso", user="tester", herdr="/opt/herdr", sessions=["default", "work"],
            servers={"default": MODULE.ProcessRecord(1, "/tmp/heeler-iso/bin/herdr", "a.log"),
                     "work": MODULE.ProcessRecord(2, "/tmp/heeler-iso/bin/herdr", "b.log")},
            ssh_port=47420, sshd=MODULE.ProcessRecord(3, "sshd.conf", "c.log"),
            relay_port=None, relay=None, plugin="/repo/plugin", started_at=12.5)
        self.assertEqual(MODULE.State.from_json(state.to_json()), state)
        self.assertEqual([record.pid for record in state.records()], [1, 2, 3])

    def test_host_entries_match_the_app_codable_shape(self) -> None:
        first = MODULE.host_entries(47420, "tester", ["default", "work"])
        self.assertEqual(first, MODULE.host_entries(47420, "tester", ["default", "work"]))
        self.assertEqual([entry["sessionName"] for entry in first], ["", "work"])
        self.assertEqual(set(first[0]), {"id", "name", "address", "port", "username", "authMethod",
                                         "sessionName", "jumpAddress", "jumpPort", "jumpUsername"})

    def test_prepare_root_refuses_a_foreign_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            (Path(directory) / "precious.txt").write_text("keep")
            with self.assertRaisesRegex(MODULE.BackendError, "not created by this script"):
                MODULE.prepare_root(Path(directory))
            self.assertTrue((Path(directory) / "precious.txt").exists())


class ExecutableTests(unittest.TestCase):
    def test_a_version_manager_shim_is_refused(self) -> None:
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            manager = Path(directory) / "mise"
            manager.write_text("#!/bin/sh\n")
            manager.chmod(0o755)
            shim = Path(directory) / "herdr"
            shim.symlink_to(manager)
            with self.assertRaisesRegex(MODULE.BackendError, "not herdr; use --herdr"):
                MODULE.resolve_executable(str(shim), "herdr")

    def test_a_real_binary_resolves_through_symlinks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            binary = Path(directory) / "node-22"
            binary.write_text("#!/bin/sh\n")
            link = Path(directory) / "node"
            link.symlink_to(binary)
            self.assertEqual(MODULE.resolve_executable(str(link), "node"),
                             os.path.realpath(binary))


class CoreFixtureCleanupTests(unittest.TestCase):
    def stop_fixture(self, root, outcomes, *, core_processes=(), inspection_error=None):
        root = Path(root)
        (root / CORE.backend.MARKER).write_text("fixture")
        for name in ("first", "second"):
            (CORE.state_root(root) / name).mkdir(parents=True)
        state = CORE.backend.State(root=str(root), user="tester", herdr="", sessions=[],
            sshd=CORE.backend.ProcessRecord(123456, str(root / "ssh/sshd.conf"), "sshd.log"))
        CORE.backend.save_state(state)
        with patch.object(sys, "argv", ["herdr-core-ssh.py", "stop", "--root", str(root)]), \
             patch.object(CORE.subprocess, "run", side_effect=outcomes) as commands, \
             patch.object(CORE.backend, "stop_processes", return_value=[]) as stop_owned, \
             patch.object(CORE.backend, "is_ours", return_value=False), \
             patch.object(CORE.backend, "processes_mentioning", return_value=[]), \
             patch.object(CORE, "owned_core_processes", return_value=list(core_processes), side_effect=inspection_error), \
             patch.object(CORE.time, "monotonic", side_effect=[0, 6]), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = CORE.main()
        stop_owned.assert_called_once_with(state)
        self.assertEqual(commands.call_count, 2, "a failed core must not skip other session cleanup")
        return result

    def test_failed_core_stop_preserves_state_but_stops_owned_sshd(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            result = self.stop_fixture(root, [subprocess.CompletedProcess([], 1),
                                             subprocess.CompletedProcess([], 0)])
            self.assertNotEqual(result, 0)
            self.assertTrue((root / "state.json").is_file())
            self.assertTrue((CORE.state_root(root) / "first").is_dir())

    def test_timed_out_core_stop_preserves_state_but_stops_owned_sshd(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            result = self.stop_fixture(root, [subprocess.TimeoutExpired("hc server stop", 20),
                                             subprocess.CompletedProcess([], 0)])
            self.assertNotEqual(result, 0)
            self.assertTrue((root / "state.json").is_file())

    def test_missing_core_launcher_preserves_state_but_stops_owned_sshd(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            result = self.stop_fixture(root, [FileNotFoundError("hc missing"),
                                             subprocess.CompletedProcess([], 0)])
            self.assertNotEqual(result, 0)
            self.assertTrue((root / "state.json").is_file())

    def test_start_cannot_replace_core_state_preserved_after_failed_stop(self):
        with tempfile.TemporaryDirectory(prefix="hc-r-", dir="/tmp") as directory:
            root = Path(directory).resolve()
            (CORE.state_root(root) / "first").mkdir(parents=True)
            state = CORE.state_root(root) / "first/core.lock"
            state.write_text("socket path needed for recovery")
            with patch.object(sys, "argv", ["herdr-core-ssh.py", "start", "--root", str(root),
                                           "--core", sys.executable]), \
                 patch.object(CORE.backend, "prepare_root") as prepare, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as failure:
                    CORE.main()
            self.assertEqual(failure.exception.code, 2)
            prepare.assert_not_called()
            self.assertTrue(state.is_file())

    def test_missing_socket_stop_success_does_not_hide_a_surviving_owned_core(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            binary = CORE.core_executable(root)
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"retained binary")
            result = self.stop_fixture(root, [subprocess.CompletedProcess([], 0, stdout='{"stopped":false}'),
                                             subprocess.CompletedProcess([], 0)], core_processes=[45678])
            self.assertNotEqual(result, 0)
            self.assertEqual(binary.read_bytes(), b"retained binary")
            self.assertTrue((root / "state.json").is_file())

    def test_process_inspection_failure_preserves_the_fixture(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            result = self.stop_fixture(root, [subprocess.CompletedProcess([], 0),
                                             subprocess.CompletedProcess([], 0)],
                                       inspection_error=subprocess.CalledProcessError(1, "ps"))
            self.assertNotEqual(result, 0)
            self.assertTrue(root.exists())

    def test_owned_process_scan_sees_detached_core_and_holder_but_not_mentions(self):
        root = Path("/tmp/core-fixture")
        table = "\n".join([
            "123 /tmp/core-fixture/home/.local/bin/herdr-core serve",
            "124 /tmp/core-fixture/home/.local/bin/herdr-core holder --instance probe",
            "125 /usr/local/bin/herdr-core serve",
            "126 tail -f /tmp/core-fixture/home/.local/bin/herdr-core",
            "127 /tmp/core-fixture/home/.local/bin/herdr-core-other serve",
        ])
        with patch.object(CORE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, table)) as run:
            self.assertEqual(CORE.owned_core_processes(root), [123, 124])
        self.assertTrue(run.call_args.kwargs["check"])
        with patch.object(CORE.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "ps")):
            with self.assertRaises(subprocess.CalledProcessError):
                CORE.owned_core_processes(root)

    def test_owned_argv_identifies_a_real_detached_process(self):
        with tempfile.TemporaryDirectory(prefix="hc-process-") as directory:
            root = Path(directory)
            binary = CORE.core_executable(root)
            binary.parent.mkdir(parents=True)
            # Keep macOS platform signing intact while giving this owned
            # process the same argv[0] as the copied core executable.
            child = subprocess.Popen([str(binary), "30"], executable=shutil.which("sleep"), start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 3
                found = CORE.owned_core_processes(root)
                while child.pid not in found and time.monotonic() < deadline:
                    time.sleep(0.02)
                    found = CORE.owned_core_processes(root)
                self.assertIn(child.pid, found)
            finally:
                child.terminate()
                child.wait(timeout=5)
            self.assertEqual(CORE.owned_core_processes(root), [])

    def started_fixture(self, root, source):
        with patch.object(sys, "argv", ["herdr-core-ssh.py", "start", "--root", str(root),
                                       "--core", str(source)]), \
             patch.object(CORE.backend, "choose_port", return_value=47420), \
             patch.object(CORE.backend, "start_sshd") as sshd, \
             patch.object(CORE.keys, "seed", return_value=bytes(32)), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(CORE.main(), 0)
        return sshd

    def source_core(self, directory):
        source = Path(directory) / "herdr-core"
        source.write_text("#!/bin/sh\nprintf 'hc fixture\\n'\n")
        source.chmod(0o700)
        return source

    def test_core_start_retains_its_executable_and_selects_key_only_sshd(self):
        with tempfile.TemporaryDirectory(prefix="hc-s-", dir="/tmp") as directory, \
             tempfile.TemporaryDirectory(prefix="hc-source-") as source_directory:
            root = Path(directory).resolve()
            source = self.source_core(source_directory)
            sshd = self.started_fixture(root, source)
            self.assertEqual(sshd.call_args.kwargs, {"use_pam": False, "log_level": "DEBUG1"})
            binary = root / "home/.local/bin/herdr-core"
            self.assertFalse(binary.is_symlink())
            self.assertEqual(binary.read_bytes(), source.read_bytes())
            self.assertFalse((root / "bin/herdr-core").exists(), "the core is only at ~/.local/bin")
            source.unlink()  # Outer download cleanup must not break a stop retry.
            self.assertEqual(subprocess.check_output([str(binary), "--version"], text=True), "hc fixture\n")
            legacy = MODULE.sshd_config(root, 47420, "tester", "/sftp")
            core = MODULE.sshd_config(root, 47420, "tester", "/sftp", use_pam=False, log_level="DEBUG1")
            self.assertIn("UsePAM yes\n", legacy)
            self.assertIn("LogLevel VERBOSE\n", legacy)
            self.assertIn("UsePAM no\n", core)
            self.assertIn("LogLevel DEBUG1\n", core)
            self.assertIn("PasswordAuthentication no\n", core)

    def test_every_call_to_hc_or_herdr_is_logged_and_fails(self):
        with tempfile.TemporaryDirectory(prefix="hc-s-", dir="/tmp") as directory, \
             tempfile.TemporaryDirectory(prefix="hc-source-") as source_directory:
            root = Path(directory).resolve()
            self.started_fixture(root, self.source_core(source_directory))
            for wire, log, status in [
                (root / "home/.local/bin/hc", CORE.tripwire_log(root), 97),
                (root / "bin/hc", CORE.tripwire_log(root), 97),
                (root / "home/.local/bin/herdr", CORE.legacy_log(root), 91),
                (root / "bin/herdr", CORE.legacy_log(root), 91),
            ]:
                before = log.read_text() if log.exists() else ""
                called = subprocess.run([str(wire), "server", "start"], capture_output=True, check=False)
                self.assertEqual(called.returncode, status)
                self.assertEqual(log.read_text(), before + "server start\n")

    def test_rc_files_carry_the_path_stub_and_marker(self):
        with tempfile.TemporaryDirectory(prefix="hc-s-", dir="/tmp") as directory, \
             tempfile.TemporaryDirectory(prefix="hc-source-") as source_directory:
            root = Path(directory).resolve()
            self.started_fixture(root, self.source_core(source_directory))
            for name, shell in ((".bashrc", "bash"), (".zshrc", "zsh")):
                if shutil.which(shell) is None:
                    continue
                printed = subprocess.check_output(
                    ["/usr/bin/env", "-i", f"HOME={root / 'home'}", "PATH=/usr/bin:/bin", shutil.which(shell),
                     "-c", f'. "$HOME/{name}"; heeler-rc-stub; printf "%s" "${CORE.RC_MARKER}"'], text=True)
                self.assertEqual(printed, "rc-stub\nrc-sourced")
            fish = shutil.which("fish")
            if fish is not None:
                printed = subprocess.check_output(
                    ["/usr/bin/env", "-i", f"HOME={root / 'home'}", "PATH=/usr/bin:/bin", fish, "-ic",
                     f'heeler-rc-stub; printf "%s" ${CORE.RC_MARKER}'], text=True, stdin=subprocess.DEVNULL)
                self.assertEqual(printed, "rc-stub\nrc-sourced")
            config = (root / "home/.config/fish/config.fish").read_text()
            self.assertIn(".rc-stub/bin", config)
            self.assertIn(CORE.RC_MARKER, config)

    def test_config_names_what_a_test_needs_to_start_and_drive_a_core(self):
        with tempfile.TemporaryDirectory(prefix="hc-s-", dir="/tmp") as directory, \
             tempfile.TemporaryDirectory(prefix="hc-source-") as source_directory:
            root = Path(directory).resolve()
            self.started_fixture(root, self.source_core(source_directory))
            config = json.loads(base64.b64decode((root / "core-test-config").read_text()))
            self.assertEqual(config["coreExecutable"], str(root / "home/.local/bin/herdr-core"))
            self.assertEqual(config["rpcHelper"], str(root / "bin/herdr-core-rpc"))
            self.assertTrue(os.access(config["rpcHelper"], os.X_OK))
            self.assertEqual(config["tripwireLog"], str(root / "hc-called.log"))
            self.assertEqual(config["legacyLog"], str(root / "legacy-called"))
            self.assertEqual(config["startEnvironment"]["HOME"], str(root / "home"))
            self.assertNotIn("HC_SESSION", config["startEnvironment"])

    def test_start_environment_is_explicit_with_default_paths_and_its_own_session(self):
        root = Path("/tmp/hc-x")
        environment = CORE.start_environment(root, "tester", "h1234abcd")
        self.assertEqual(environment["HC_SESSION"], "h1234abcd")
        self.assertEqual(environment["HOME"], "/tmp/hc-x/home")
        self.assertEqual(environment["PATH"], MODULE.isolated_path(root))
        self.assertEqual([name for name in environment if name.startswith("XDG_")], [])
        self.assertNotIn("HC_SOCKET", environment)
        self.assertNotIn(str(root / "home/.local/bin"), environment["PATH"])
        with patch.dict(os.environ, {"XDG_STATE_HOME": "/elsewhere", "HC_SOCKET": "/elsewhere/s"}):
            self.assertEqual(CORE.start_environment(root, "tester", "h1234abcd"), environment)

    def test_start_core_runs_only_the_absolute_program_in_that_environment(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            (root / CORE.backend.MARKER).write_text("fixture")
            CORE.backend.save_state(CORE.backend.State(root=str(root), user="tester", herdr="", sessions=[]))
            with patch.object(CORE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
                CORE.start_core(root, "h1234abcd")
            self.assertEqual(run.call_args.args[0], [str(CORE.core_executable(root)), "server", "start"])
            self.assertEqual(run.call_args.kwargs["env"], CORE.start_environment(root, "tester", "h1234abcd"))

    def test_stop_uses_the_absolute_program_in_each_sessions_environment(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            calls = []

            def record(command, **kwargs):
                calls.append((command, kwargs["env"]))
                return subprocess.CompletedProcess([], 0)

            (root / CORE.backend.MARKER).write_text("fixture")
            for name in ("first", "second"):
                (CORE.state_root(root) / name).mkdir(parents=True)
            state = CORE.backend.State(root=str(root), user="tester", herdr="", sessions=[])
            CORE.backend.save_state(state)
            with patch.object(CORE.subprocess, "run", side_effect=record), \
                 patch.object(CORE.backend, "command_stop", return_value=0), \
                 patch.object(CORE, "owned_core_processes", return_value=[]), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(CORE.stop_fixture(root), 0)
            self.assertEqual([call[0] for call in calls], [[str(CORE.core_executable(root)), "server", "stop"]] * 2)
            self.assertEqual([call[1]["HC_SESSION"] for call in calls], ["first", "second"])
            for _, environment in calls:
                self.assertEqual(environment["HOME"], str(root / "home"))
                self.assertEqual([name for name in environment if name.startswith("XDG_")], [])

    def test_root_budget_fits_the_holders_socket_on_macos(self):
        # 33 + "/home/.local/state/herdr-core/" + 9 + "/" + 9 + ".holder." + 8 + ".sock"
        fits = "/" + "r" * 32
        over = fits + "r"
        self.assertEqual(CORE.longest_socket_path(fits), 103)
        self.assertEqual(CORE.longest_socket_path(over), 104)
        self.assertEqual(len(f"{fits}/home/.local/state/herdr-core/h1234abcd/h1234abcd.holder.0123abcd.sock"), 103)
        with tempfile.TemporaryDirectory(prefix="hc-source-") as source_directory, \
             patch.object(sys, "argv", ["herdr-core-ssh.py", "start", "--root", over,
                                        "--core", str(self.source_core(source_directory))]), \
             contextlib.redirect_stderr(io.StringIO()) as error:
            with self.assertRaises(SystemExit):
                CORE.main()
        self.assertIn("104 bytes of 103", error.getvalue())
        self.assertFalse(Path(over).exists())


    def test_successful_core_and_sshd_stop_removes_the_fixture(self):
        with tempfile.TemporaryDirectory(prefix="hc-clean-") as directory:
            root = Path(directory)
            result = self.stop_fixture(root, [subprocess.CompletedProcess([], 0),
                                             subprocess.CompletedProcess([], 0)])
            self.assertEqual(result, 0)
            self.assertFalse(root.exists())


class RelayTests(unittest.TestCase):
    def test_relay_records_posts_and_answers_410_for_listed_tokens(self) -> None:
        self.check_relay()

    def test_relay_serves_requests_while_reverse_dns_is_stalled(self) -> None:
        self.check_relay(stall_reverse_dns=True)

    def check_relay(self, *, stall_reverse_dns: bool = False) -> None:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            root = Path(directory)
            (root / "relay-410.txt").write_text("gone\n")
            command = [sys.executable]
            if stall_reverse_dns:
                # Stall only the child relay's DNS, not its HTTP client or sockets.
                command += ["-c", """
import runpy
import socket
import sys
import time

def stalled_reverse_lookup(address):
    time.sleep(60)
    raise TimeoutError("reverse DNS stalled")

socket.gethostbyaddr = stalled_reverse_lookup
sys.argv.pop(0)
runpy.run_path(sys.argv[0], run_name="__main__")
"""]
            command += [str(Path(__file__).with_name("isolated-herdr-backend.py")),
                        "--root", str(root), "relay-serve", "--port", str(port)]
            relay = subprocess.Popen(
                command,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.addCleanup(relay.wait)
            self.addCleanup(relay.terminate)
            self.assertTrue(MODULE.wait_until(lambda: MODULE.port_accepts(port), 10))
            statuses = []
            for token in ("live", "gone"):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/push", data=json.dumps({"token": token}).encode(),
                    headers={"Content-Type": "application/json"}, method="POST")
                try:
                    with urllib.request.urlopen(request, timeout=5) as response:
                        statuses.append(response.status)
                except urllib.error.HTTPError as error:
                    statuses.append(error.code)
                    error.close()
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not (root / "relay.jsonl").exists():
                time.sleep(0.05)
            records = [json.loads(line) for line in (root / "relay.jsonl").read_text().splitlines()]
        self.assertEqual(statuses, [200, 410])
        self.assertEqual([(record["status"], record["path"], record["body"]["token"])
                          for record in records],
                         [(200, "/push", "live"), (410, "/push", "gone")])


class CoreRPCHelperTests(unittest.TestCase):
    def serve(self, directory, replies):
        """A one-shot listener at a path a core.lock names."""
        state = Path(directory) / "state"
        (state / "s").mkdir(parents=True)
        path = Path(directory) / "s.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
        listener.listen(1)
        self.addCleanup(listener.close)
        (state / "s/core.lock").write_text(str(path))
        received = []

        def answer():
            connection, _ = listener.accept()
            with connection:
                received.append(connection.makefile().readline())
                connection.sendall(replies)

        thread = threading.Thread(target=answer, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        return state, received

    def call(self, state, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = RPC.main(["--session", "s", "--state-root", str(state), *arguments])
        return status, output.getvalue(), errors.getvalue()

    def test_it_sends_one_plain_request_to_the_locked_socket_and_prints_the_result(self):
        with tempfile.TemporaryDirectory(prefix="hc-r-", dir="/tmp") as directory:
            state, received = self.serve(directory, b'{"jsonrpc":"2.0","id":"rpc","result":{"pid":42}}\n')
            status, output, _ = self.call(state, "server.status")
            self.assertEqual(status, 0)
            self.assertEqual(json.loads(output), {"pid": 42})
            self.assertEqual(json.loads(received[0]),
                {"jsonrpc": "2.0", "id": "rpc", "method": "server.status", "params": {}})

    def test_a_core_error_is_a_failure(self):
        with tempfile.TemporaryDirectory(prefix="hc-r-", dir="/tmp") as directory:
            state, _ = self.serve(directory, b'{"jsonrpc":"2.0","id":"rpc","error":{"code":-1,"message":"no"}}\n')
            status, output, errors = self.call(state, "server.status")
            self.assertEqual(status, 5)
            self.assertEqual(output, "")
            self.assertIn("no", errors)

    def test_nothing_listening_and_no_lock_fail_without_starting_anything(self):
        with tempfile.TemporaryDirectory(prefix="hc-r-", dir="/tmp") as directory:
            state = Path(directory)
            with patch.object(subprocess, "run") as run, patch.object(subprocess, "Popen") as spawn:
                self.assertEqual(self.call(state, "server.status")[0], 3)
                (state / "s").mkdir()
                (state / "s/core.lock").write_text(str(state / "gone.sock"))
                self.assertEqual(self.call(state, "server.status")[0], 4)
            run.assert_not_called()
            spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
