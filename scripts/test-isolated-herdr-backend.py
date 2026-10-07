#!/usr/bin/env python3
"""Check the isolated herdr backend's pure parts without starting herdr or sshd."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
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


class RelayTests(unittest.TestCase):
    def test_relay_records_posts_and_answers_410_for_listed_tokens(self) -> None:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix="heeler-iso-test-") as directory:
            root = Path(directory)
            (root / "relay-410.txt").write_text("gone\n")
            relay = subprocess.Popen(
                [sys.executable, str(Path(__file__).with_name("isolated-herdr-backend.py")),
                 "--root", str(root), "relay-serve", "--port", str(port)],
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


if __name__ == "__main__":
    unittest.main()
