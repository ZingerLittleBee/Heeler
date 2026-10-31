#!/usr/bin/env python3
"""Run the Host Helper's scripts against a fake Host.

Compiles Sources/Heeler/Transport/HostHelperScript.swift with
NodeToolchainProbe.swift and a small driver, then feeds each script to every
POSIX shell found here (/bin/sh, dash, bash, ksh, busybox), as the bounded exec
does. The Host is a temporary HOME with stand-ins for `systemctl`, `loginctl`
and `node` on PATH; the stand-ins log how they were called, so a test can see
XDG_RUNTIME_DIR arrive. Needs swiftc (agent-tools CI uses the Ubuntu image's,
whose /bin/sh is dash); uses only Python's standard library.
"""

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HostHelperScript.swift",
    ROOT / "Sources/Heeler/Transport/NodeToolchainProbe.swift",
]

STUB = """
enum HerdrHostPath {
    static let pathExport = "export PATH=\\"$PATH\\""
    static func isBareHerdrCommand(_ command: String) -> Bool { command.hasPrefix("herdr ") }
}
"""

MAIN = """
import Foundation

struct Input: Decodable {
    var step: String
    var folders: [String]?
    var privateFolder: String?
    var directory: String?
    var staging: String?
    var path: String?
    var app: String?
    var arguments: [String]?
    var user: String?
    var files: [String]?
    var node: String?
    var lister: String?
    var home: String?
}

let arguments = CommandLine.arguments
guard let input = try? JSONDecoder().decode(Input.self, from: Data(arguments[2].utf8)) else { exit(64) }
let nonce = "0123456789abcdef"
let step: HostHelperScript.Step
switch input.step {
case "probe": step = .probe
case "locate": step = .locate
case "listExtensionFolders":
    step = .listExtensionFolders(node: input.node ?? "", lister: input.lister ?? "", home: input.home ?? "")
case "makeFolders": step = .makeFolders(input.folders ?? [], privateFolder: input.privateFolder ?? "")
case "prepareStaging":
    step = .prepareStaging(
        directory: input.directory ?? "", staging: input.staging ?? "", folders: input.folders ?? [])
case "hashTree": step = .hashTree(root: input.path ?? "")
case "promote": step = .promote(staging: input.staging ?? "", app: input.app ?? "")
case "systemctl": step = .systemctl(input.arguments ?? [])
case "enableLinger": step = .enableLinger(user: input.user ?? "")
case "removeFiles": step = .removeFiles(input.files ?? [])
case "removeEmptyFolders": step = .removeEmptyFolders(input.folders ?? [])
case "removeTree": step = .removeTree(input.path ?? "")
default: exit(64)
}
let script = HostHelperScript(step, nonce: nonce)
switch arguments[1] {
case "script":
    print(script.text, terminator: "")
case "parse-probe":
    let probe = try HostHelperProbe(stdout: FileHandle.standardInput.readDataToEndOfFile(), nonce: nonce)
    let summary: [String: Any] = [
        "kernel": probe.kernel,
        "user": probe.user,
        "home": probe.locations.home,
        "data": probe.locations.dataHome,
        "config": probe.locations.configHome,
        "node": {
            switch probe.node {
            case .found(let path): return "found \\(path)"
            case .tooOld(let version): return "old \\(version)"
            case .missing: return "missing"
            }
        }() as String,
        "linger": probe.lingerOn,
        "hasSystemd": probe.hasSystemd,
        "health": probe.health.map { [$0.loadState, $0.activeState, $0.result, String($0.restarts)] } ?? [],
        "appPresent": probe.appPresent,
        "manifest": probe.manifest.map { String(decoding: $0, as: UTF8.self) } ?? "",
        "record": probe.record.map { String(decoding: $0, as: UTF8.self) } ?? "",
        "hashes": probe.hashes,
        "hashToolMissing": probe.hashToolMissing,
    ]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "parse-extension-folders":
    let folders = try HostHelperProbe.parseExtensionFolders(
        stdout: FileHandle.standardInput.readDataToEndOfFile(), nonce: nonce)
    let summary = folders.map { [$0.path, $0.installed ? "installed" : "absent"] }
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "unit":
    print(HostHelperUnit.text(nodePath: arguments[3], mainPath: arguments[4]), terminator: "")
default:
    exit(64)
}
"""

# The node probe's fixed system locations. Tests move them under the fake root,
# so what this machine has installed cannot answer for a layout.
SYSTEM_PREFIXES = (
    "/opt/homebrew/",
    "/usr/local/",
    "/home/linuxbrew/",
    "/etc/profiles/",
    "/run/current-system/",
    "/nix/var/",
    "/snap/bin",
    "/opt/local/bin",
)

SYSTEMCTL = """#!/bin/sh
printf 'XDG_RUNTIME_DIR=%s args=%s\\n' "$XDG_RUNTIME_DIR" "$*" >> "$FAKE_LOG"
[ "${FAKE_SYSTEMCTL_FAILS:-}" = 1 ] && { echo 'Failed to connect to bus' >&2; exit 1; }
if [ "$2" = show ]; then
    printf 'LoadState=loaded\\nActiveState=failed\\nResult=start-limit-hit\\nNRestarts=5\\n'
fi
"""

LOGINCTL = """#!/bin/sh
printf 'loginctl %s\\n' "$*" >> "$FAKE_LOG"
if [ "$1" = show-user ]; then
    [ "${FAKE_LINGER:-}" = missing ] && exit 1
    echo "Linger=${FAKE_LINGER:-no}"
fi
if [ "$2" = enable-linger ] && [ "${FAKE_LINGER_REFUSES:-}" = 1 ]; then
    echo 'Could not enable linger: Interactive authentication required.' >&2
    exit 1
fi
"""

NODE = """#!/bin/sh
case "$2" in
process.versions.node) echo "${FAKE_NODE_VERSION:-22.1.0}" ;;
process.execPath) echo /real/node/bin/node ;;
esac
"""

NONCE = "0123456789abcdef"


def shells() -> list[str]:
    found = ["/bin/sh"]
    for name in ("dash", "bash", "ksh"):
        path = shutil.which(name)
        if path:
            found.append(path)
    if shutil.which("busybox"):
        found.append("busybox sh")
    return found


class HelperScriptCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-helper-build-"))
        (cls.build / "stub.swift").write_text(STUB)
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "helper"
        subprocess.run(
            ["swiftc", *map(str, SOURCES), str(cls.build / "stub.swift"),
             str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="hh-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = self.root / "my home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.log"
        self.log.write_text("")
        self.tool("systemctl", SYSTEMCTL)
        self.tool("loginctl", LOGINCTL)
        self.env = {
            "HOME": str(self.home),
            "USER": "me",
            "SHELL": "/bin/sh",
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FAKE_LOG": str(self.log),
        }
        self.helper_dir = self.home / ".local/share/heeler/host-helper"

    def tool(self, name: str, body: str) -> None:
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def script(self, **step) -> str:
        return subprocess.run(
            [str(self.binary), "script", json.dumps(step)],
            check=True, capture_output=True, text=True,
        ).stdout

    def run_script(self, shell: str = "/bin/sh", **step) -> subprocess.CompletedProcess:
        text = self.script(**step)
        for prefix in SYSTEM_PREFIXES:
            text = text.replace(prefix, f"{self.root}/abs{prefix}")
        return subprocess.run(
            shell.split(), input=text, env=self.env, capture_output=True, text=True, timeout=60,
        )

    def probe(self, shell: str = "/bin/sh") -> dict:
        result = self.run_script(shell, step="probe")
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = subprocess.run(
            [str(self.binary), "parse-probe", json.dumps({"step": "probe"})],
            input="a line from .bashrc\n" + result.stdout,
            capture_output=True, text=True, check=True,
        )
        return json.loads(parsed.stdout)

    def install_tree(self, files: dict[str, str]) -> dict[str, str]:
        hashes = {}
        app = self.helper_dir / "app"
        for name, body in files.items():
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body)
            hashes[name] = hashlib.sha256(body.encode()).hexdigest()
        return hashes


class ProbeTests(HelperScriptCase):
    def test_reads_a_host_with_nothing_installed_under_every_shell(self) -> None:
        self.tool("node", NODE)
        for shell in shells():
            with self.subTest(shell=shell):
                probe = self.probe(shell)
                self.assertEqual(probe["user"], subprocess.run(
                    ["id", "-un"], capture_output=True, text=True, check=True).stdout.strip())
                self.assertEqual(probe["home"], str(self.home))
                self.assertEqual(probe["data"], f"{self.home}/.local/share")
                self.assertEqual(probe["config"], f"{self.home}/.config")
                self.assertEqual(probe["node"], "found /real/node/bin/node")
                self.assertFalse(probe["appPresent"])
                self.assertEqual(probe["hashes"], {})

    def test_changes_nothing_on_the_host(self) -> None:
        self.probe()
        self.assertEqual(list(self.home.iterdir()), [])

    def test_follows_the_xdg_directories_and_ignores_relative_ones(self) -> None:
        self.env["XDG_DATA_HOME"] = f"{self.root}/data"
        self.env["XDG_CONFIG_HOME"] = "relative/config"
        probe = self.probe()
        self.assertEqual(probe["data"], f"{self.root}/data")
        self.assertEqual(probe["config"], f"{self.home}/.config")

    def test_every_systemctl_call_carries_the_runtime_directory(self) -> None:
        self.probe()
        calls = [line for line in self.log.read_text().splitlines() if "args=" in line]
        self.assertEqual(len(calls), 1)
        self.assertIn(f"XDG_RUNTIME_DIR=/run/user/{os.getuid()} args=--user show heeler-host-helper.service", calls[0])
        self.env["XDG_RUNTIME_DIR"] = "/run/custom"
        self.log.write_text("")
        self.probe()
        self.assertIn("XDG_RUNTIME_DIR=/run/custom ", self.log.read_text())

    def test_reads_the_units_state_result_and_restart_count(self) -> None:
        self.assertEqual(self.probe()["health"], ["loaded", "failed", "start-limit-hit", "5"])

    def test_a_user_manager_nobody_can_reach_reads_as_unreachable(self) -> None:
        self.env["FAKE_SYSTEMCTL_FAILS"] = "1"
        probe = self.probe()
        self.assertEqual(probe["health"], [])
        self.assertTrue(probe["hasSystemd"])

    def test_a_host_without_systemd_says_so(self) -> None:
        (self.bin / "systemctl").unlink()
        self.env["PATH"] = str(self.bin) + ":" + str(self.root / "tools")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("uname", "id", "od", "tr", "find", "sed", "tail", "mktemp", "rm", "sleep", "cat"):
            found = shutil.which(name)
            if found:
                (tools / name).symlink_to(found)
        self.assertFalse(self.probe()["hasSystemd"])

    def test_linger_from_loginctl_and_from_loginds_file(self) -> None:
        self.env["FAKE_LINGER"] = "yes"
        self.assertTrue(self.probe()["linger"])
        self.env["FAKE_LINGER"] = "no"
        self.assertFalse(self.probe()["linger"])
        self.env["FAKE_LINGER"] = "missing"
        self.assertFalse(self.probe()["linger"])

    def test_node_missing_and_too_old(self) -> None:
        self.assertEqual(self.probe()["node"], "missing")
        self.tool("node", NODE)
        self.env["FAKE_NODE_VERSION"] = "18.19.0"
        self.assertEqual(self.probe()["node"], "old 18.19.0")

    def test_reads_the_installed_manifest_record_and_hashes(self) -> None:
        hashes = self.install_tree({"main.js": "one\n", "shared/a b.js": "two\n", "manifest.json": "{\"v\":1}\n"})
        hashes.pop("manifest.json")
        (self.helper_dir / "installed.json").write_text('{"files":["é"]}')
        for shell in shells():
            with self.subTest(shell=shell):
                probe = self.probe(shell)
                self.assertTrue(probe["appPresent"])
                self.assertEqual(probe["manifest"], '{"v":1}\n')
                self.assertEqual(probe["record"], '{"files":["é"]}')
                self.assertEqual(probe["hashes"], hashes)


class InstallStepTests(HelperScriptCase):
    def test_make_folders_says_which_it_created_and_makes_them_private(self) -> None:
        (self.home / ".config").mkdir()
        folders = [str(self.home / ".config"), str(self.home / ".config/a"), str(self.home / ".config/a/b")]
        result = self.run_script(step="makeFolders", folders=folders, privateFolder=folders[-1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [line for line in result.stdout.splitlines() if line.startswith("created")],
            [f"created {folders[1]}", f"created {folders[2]}"],
        )
        self.assertEqual(stat.S_IMODE(Path(folders[2]).stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(Path(folders[1]).stat().st_mode), 0o700)

    def test_make_folders_tightens_an_existing_private_folder(self) -> None:
        folder = self.home / "open"
        folder.mkdir(mode=0o755)
        self.run_script(step="makeFolders", folders=[str(folder)], privateFolder=str(folder))
        self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)

    def test_prepare_staging_clears_what_an_interrupted_install_left(self) -> None:
        self.helper_dir.mkdir(parents=True)
        (self.helper_dir / "staging-old").mkdir()
        (self.helper_dir / "app.old-1").mkdir()
        (self.helper_dir / "notifications.json").write_text("{}")
        staging = self.helper_dir / "staging-new"
        result = self.run_script(
            step="prepareStaging", directory=str(self.helper_dir), staging=str(staging),
            folders=[str(staging / "shared/delivery")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(path.name for path in self.helper_dir.iterdir()), ["notifications.json", "staging-new"])
        self.assertEqual(stat.S_IMODE((staging / "shared/delivery").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(staging.stat().st_mode), 0o700)

    def test_hash_tree_lists_files_but_the_manifest(self) -> None:
        hashes = self.install_tree({"main.js": "one\n", "manifest.json": "{}\n"})
        result = self.run_script(step="hashTree", path=str(self.helper_dir / "app"))
        self.assertIn(f"hash {hashes['main.js']} main.js", result.stdout)
        self.assertNotIn("manifest.json", result.stdout)

    def test_promote_replaces_the_app_and_keeps_its_neighbours(self) -> None:
        self.install_tree({"main.js": "old\n"})
        (self.helper_dir / "notifications.json").write_text("{}")
        staging = self.helper_dir / "staging-1"
        staging.mkdir()
        (staging / "main.js").write_text("new\n")
        result = self.run_script(step="promote", staging=str(staging), app=str(self.helper_dir / "app"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.helper_dir / "app/main.js").read_text(), "new\n")
        self.assertEqual(sorted(path.name for path in self.helper_dir.iterdir()), ["app", "notifications.json"])

    def test_promote_without_a_staging_directory_fails_and_restores(self) -> None:
        self.install_tree({"main.js": "old\n"})
        result = self.run_script(
            step="promote", staging=str(self.helper_dir / "staging-gone"), app=str(self.helper_dir / "app"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.helper_dir / "app/main.js").read_text(), "old\n")

    def test_systemctl_carries_the_runtime_directory_and_reports_failure(self) -> None:
        result = self.run_script(step="systemctl", arguments=["enable", "heeler-host-helper.service"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"XDG_RUNTIME_DIR=/run/user/{os.getuid()} args=--user enable heeler-host-helper.service",
            self.log.read_text())
        self.env["FAKE_SYSTEMCTL_FAILS"] = "1"
        result = self.run_script(step="systemctl", arguments=["daemon-reload"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Failed to connect to bus", result.stderr)
        self.assertIn(f"{NONCE} end", result.stdout)

    def test_a_linger_refusal_comes_back_without_asking(self) -> None:
        self.env["FAKE_LINGER_REFUSES"] = "1"
        result = self.run_script(step="enableLinger", user="me")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Interactive authentication required", result.stderr)
        self.assertIn("loginctl --no-ask-password enable-linger me", self.log.read_text())

    def test_the_unit_runs_under_systemd_quoting(self) -> None:
        text = subprocess.run(
            [str(self.binary), "unit", '{"step":"locate"}', "/opt/no de/bin/node", "/home/100%/app/main.js"],
            capture_output=True, text=True, check=True,
        ).stdout
        self.assertIn('ExecStart="/opt/no de/bin/node" "/home/100%%/app/main.js"\n', text)
        self.assertIn("Restart=always\n", text)
        self.assertIn("WantedBy=default.target\n", text)


class ExtensionFolderStepTests(HelperScriptCase):
    """The real script text through a real Node.js, which only this step runs."""

    LISTER = ROOT / "plugin/helper/extensions/extension-folders.js"

    def list_folders(self, shell: str = "/bin/sh") -> list:
        node = shutil.which("node")
        self.assertIsNotNone(node, "this test needs Node.js")
        result = self.run_script(
            shell, step="listExtensionFolders", node=node,
            lister=self.LISTER.read_text(), home=str(self.home),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = subprocess.run(
            [str(self.binary), "parse-extension-folders", json.dumps({"step": "probe"})],
            input="a line from .bashrc\n" + result.stdout,
            capture_output=True, text=True, check=True,
        )
        return json.loads(parsed.stdout)

    def test_finds_every_profile_under_every_shell_in_a_home_with_a_space(self) -> None:
        (self.home / ".omp/profiles/work").mkdir(parents=True)
        (self.home / ".omp/profiles/it's").mkdir()
        (self.home / ".omp/profiles/side").mkdir()
        installed = self.home / ".pi/agent/extensions"
        installed.mkdir(parents=True)
        (installed / "heeler-session.js").write_text("")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.list_folders(shell), [
                    [f"{self.home}/.pi/agent/extensions", "installed"],
                    [f"{self.home}/.omp/agent/extensions", "absent"],
                    [f"{self.home}/.omp/profiles/side/agent/extensions", "absent"],
                    [f"{self.home}/.omp/profiles/work/agent/extensions", "absent"],
                ])

    def test_changes_nothing_on_the_host(self) -> None:
        self.list_folders()
        self.assertEqual(list(self.home.iterdir()), [])


class RemovalStepTests(HelperScriptCase):
    def test_removes_only_the_files_named(self) -> None:
        keep = self.home / "keep"
        gone = self.home / "go ne"
        keep.write_text("")
        gone.write_text("")
        result = self.run_script(step="removeFiles", files=[str(gone), str(self.home / "absent")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(gone.exists())
        self.assertTrue(keep.exists())

    def test_removes_only_folders_that_are_empty(self) -> None:
        full = self.home / "full"
        full.mkdir()
        (full / "file").write_text("")
        outer = self.home / "outer"
        inner = outer / "inner"
        inner.mkdir(parents=True)
        result = self.run_script(
            step="removeEmptyFolders", folders=[str(full), str(inner), str(outer), str(self.home / "absent")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((full / "file").exists())
        self.assertFalse(outer.exists())

    def test_remove_tree_takes_the_helper_directory(self) -> None:
        self.install_tree({"main.js": "one\n"})
        (self.helper_dir / "notifications.json").write_text("{}")
        result = self.run_script(step="removeTree", path=str(self.helper_dir))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.helper_dir.exists())
        self.assertTrue(self.helper_dir.parent.exists())


if __name__ == "__main__":
    if shutil.which("swiftc") is None:
        print("skipping: swiftc not found", file=sys.stderr)
        sys.exit(0)
    unittest.main()
