#!/usr/bin/env python3
"""Run the Host Helper's scripts against a fake Host.

Compiles Sources/Heeler/Transport/HostHelperScript.swift with
NodeToolchainProbe.swift and a small driver, then feeds each script to every
POSIX shell found here (/bin/sh, dash, bash, ksh, busybox), as the bounded exec
does. The Host is a temporary HOME with a shell function for `uname` and PATH
stand-ins for `systemctl`, `loginctl`, `launchctl` and `node`; the stand-ins log
how they were called, so a test can see XDG_RUNTIME_DIR arrive. Needs swiftc
(agent-tools CI uses the Ubuntu image's, whose /bin/sh is dash); uses only
Python's standard library.
"""

import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAUNCHCTL_FIXTURES = ROOT / "plugin/test/fixtures/launchctl"
SOURCES = [
    ROOT / "Sources/Heeler/Transport/HostHelperScript.swift",
    ROOT / "Sources/Heeler/Transport/NodeToolchainProbe.swift",
    ROOT / "scripts/fixtures/string-localized-shim.swift",
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
    var timeZone: String?
    var claudeLimits: Bool?
    var session: String?
    var node: String?
    var lister: String?
    var service: String?
    var home: String?
    var recordFiles: [String]?
    var recordFolders: [String]?
    var quietMinutes: Int?
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
case "launchctl": step = .launchctl(input.arguments ?? [])
case "launchdHealth": step = .launchdHealth(service: input.service ?? "")
case "bootOutAndRemove":
    step = .bootOutAndRemove(service: input.service ?? "", propertyList: input.path ?? "")
case "enableLinger": step = .enableLinger(user: input.user ?? "")
case "removeFiles": step = .removeFiles(input.files ?? [])
case "removeEmptyFolders": step = .removeEmptyFolders(input.folders ?? [])
case "removeTree": step = .removeTree(input.path ?? "")
case "tidyInterruptedInstall":
    step = .tidyInterruptedInstall(
        directory: input.directory ?? "",
        record: input.recordFiles.map { HostHelperScript.RecordedPaths(files: $0, folders: input.recordFolders ?? []) },
        quietMinutes: input.quietMinutes)
case "usageQuery":
    step = .usageQuery(
        timeZone: input.timeZone ?? "", claudeLimits: input.claudeLimits ?? false, session: input.session ?? "")
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
        "uid": probe.uid,
        "launchAgentFile": probe.launchAgentFilePresent,
        "launchdPid": probe.health?.launchd?.pid ?? 0,
        "appPresent": probe.appPresent,
        "manifest": probe.manifest.map { String(decoding: $0, as: UTF8.self) } ?? "",
        "record": probe.record.map { String(decoding: $0, as: UTF8.self) } ?? "",
        "hashes": probe.hashes,
        "hashToolMissing": probe.hashToolMissing,
        "serviceNodeGone": probe.serviceNodeGone,
        "leftovers": probe.leftovers,
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
case "property-list":
    let list = try HostHelperLaunchAgent.propertyList(
        nodePath: arguments[3], mainPath: arguments[4], logPath: arguments[5])
    FileHandle.standardOutput.write(list)
default:
    exit(64)
}
"""

# The probe's fixed system locations. Tests move them under the fake root,
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
    "/var/lib/systemd/linger/",
)
# The system's own bin among them, moved only where the probe names it whole,
# not in the /usr/bin/env it runs.
SYSTEM_BIN = re.compile(r"(?<![\w/.-])/usr/bin(?![\w/.-])")

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

# launchd's own wording and exit codes, from plugin/test/fixtures/launchctl/.
LAUNCHCTL = """#!/bin/sh
printf 'launchctl %s\\n' "$*" >> "$FAKE_LOG"
if [ "$1" = print ]; then
    if [ -z "${FAKE_LAUNCHCTL_PRINT:-}" ]; then
        echo 'Bad request.' >&2
        echo 'Could not find service' >&2
        exit 113
    fi
    cat "$FAKE_LAUNCHCTL_PRINT"
    exit 0
fi
if [ -n "${FAKE_LAUNCHCTL_EXIT:-}" ]; then
    exit "$FAKE_LAUNCHCTL_EXIT"
fi
if [ -n "${FAKE_LAUNCHCTL_REFUSES:-}" ]; then
    echo 'Bootstrap failed: 5: Input/output error' >&2
    exit 5
fi
"""

NODE = """#!/bin/sh
case "$2" in
process.versions.node) echo "${FAKE_NODE_VERSION:-22.1.0}" ;;
process.execPath) echo /real/node/bin/node ;;
esac
"""

NONCE = "0123456789abcdef"

def node_stub(exec_path: str, version: str = "22.1.0") -> str:
    """A `node` that says it is the binary at exec_path, as a link or shim to it would."""
    return f"""#!/bin/sh
case "$2" in
process.versions.node) echo {version} ;;
process.execPath) echo '{exec_path}' ;;
esac
"""



def shells() -> list[str]:
    found = ["/bin/sh"]
    for name in ("dash", "bash", "ksh"):
        path = shutil.which(name)
        if path:
            found.append(path)
    busybox = shutil.which("busybox")
    if busybox:
        found.append(f"{busybox} sh")
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
        self.tool("launchctl", LAUNCHCTL)
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

    def node_in(self, directory: Path, exec_path: str, version: str = "22.1.0") -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        node = directory / "node"
        node.write_text(node_stub(exec_path, version))
        node.chmod(0o755)
        return node

    def script(self, **step) -> str:
        return subprocess.run(
            [str(self.binary), "script", json.dumps(step)],
            check=True, capture_output=True, text=True,
        ).stdout

    def run_script(self, shell: str = "/bin/sh", **step) -> subprocess.CompletedProcess:
        # A shell function overrides BusyBox's built-in uname; a PATH shim does not.
        text = 'uname() { printf "%s\\n" "${FAKE_KERNEL:-Linux}"; }\n' + self.script(**step)
        # Only the probe discovers system paths; other steps receive real paths.
        if step["step"] == "probe":
            for prefix in SYSTEM_PREFIXES:
                text = text.replace(prefix, f"{self.root}/abs{prefix}")
            text = SYSTEM_BIN.sub(f"{self.root}/abs/usr/bin", text)
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
        for name in ("id", "od", "tr", "find", "sed", "tail", "mktemp", "rm", "sleep", "cat"):
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
        user = subprocess.run(["id", "-un"], capture_output=True, text=True, check=True).stdout.strip()
        linger = self.root / "abs/var/lib/systemd/linger" / user
        linger.parent.mkdir(parents=True)
        linger.touch()
        self.assertTrue(self.probe()["linger"])
        self.env["FAKE_LINGER"] = "no"
        self.assertFalse(self.probe()["linger"])

    def test_node_missing_and_too_old(self) -> None:
        self.assertEqual(self.probe()["node"], "missing")
        self.tool("node", NODE)
        self.env["FAKE_NODE_VERSION"] = "18.19.0"
        self.assertEqual(self.probe()["node"], "old 18.19.0")

    def test_a_node_another_program_bundles_is_passed_over(self) -> None:
        # mise's shim runs whatever active tool exposes `node`: here cursor-agent's own.
        shims = self.home / ".local/share/mise/shims"
        self.node_in(shims, f"{self.root}/mise/installs/cursor-agent/1/dist-package/node", "26.12.1")
        volta = f"{self.root}/volta/tools/image/node/22.1.0/bin/node"
        self.node_in(self.home / ".volta/bin", volta)
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {volta}")

    def test_only_a_bundled_node_reads_as_missing_not_too_old(self) -> None:
        self.node_in(
            self.home / ".local/share/mise/shims",
            f"{self.root}/mise/installs/cursor-agent/1/dist-package/node", "18.20.0")
        self.node_in(self.bin, f"{self.root}/.vscode-server/bin/0123abcd/node", "18.20.0")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], "missing")

    def test_a_bundled_node_first_on_the_path_gives_way_to_a_later_one(self) -> None:
        # A fish config.fish that activates mise puts cursor-agent's runtime
        # ahead of the system's Node.js on the exec's PATH.
        bundled = self.root / "mise/installs/cursor-agent/latest/dist-package"
        self.node_in(bundled, f"{bundled}/node")
        system = self.root / "system/bin"
        self.node_in(system, "/usr/bin/node")
        self.env["PATH"] = f"{bundled}:{system}:{self.env['PATH']}"
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], "found /usr/bin/node")

    def test_a_bundled_node_first_on_the_login_shells_path_gives_way_to_a_later_one(self) -> None:
        bundled = self.root / "mise/installs/cursor-agent/latest/dist-package"
        self.node_in(bundled, f"{bundled}/node")
        system = self.root / "system/bin"
        self.node_in(system, "/usr/bin/node")
        self.tool("fish", f'#!/bin/sh\necho "PATH=/wrong"\nPATH="{bundled}:{system}:/usr/bin:/bin" exec /usr/bin/env\n')
        self.env["SHELL"] = str(self.bin / "fish")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], "found /usr/bin/node")

    def test_a_distributions_versioned_binary_is_found(self) -> None:
        # Fedora's /usr/bin/node links to node-22; openSUSE's to node22.
        for binary in ("/usr/bin/node-22", "/usr/bin/node22", "/usr/bin/nodejs22"):
            self.node_in(self.bin, binary)
            for shell in shells():
                with self.subTest(binary=binary, shell=shell):
                    self.assertEqual(self.probe(shell)["node"], f"found {binary}")
        for binary in ("/opt/tool/libexec/node-22", "/usr/bin/node-gyp", "/usr/bin/node22/lib/node"):
            self.node_in(self.bin, binary)
            with self.subTest(binary=binary):
                self.assertEqual(self.probe()["node"], "missing")

    def test_a_managers_default_link_is_named_as_found(self) -> None:
        alias = self.home / ".local/share/fnm/aliases/default/bin"
        self.node_in(alias, f"{self.root}/fnm/node-versions/v22.1.0/installation/bin/node")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {alias}/node")

    def test_homebrews_bin_is_named_rather_than_its_cellar(self) -> None:
        brew = self.root / "abs/opt/homebrew/bin"
        self.node_in(brew, f"{self.root}/abs/opt/homebrew/Cellar/node/24.1.0/bin/node", "24.1.0")
        self.assertEqual(self.probe()["node"], f"found {brew}/node")

    def test_the_systems_bin_is_named_rather_than_the_binary_it_leads_to(self) -> None:
        # Fedora's /usr/bin/node is the alternatives link dnf keeps on its current Node.js.
        usr_bin = self.root / "abs/usr/bin"
        self.node_in(usr_bin, "/usr/bin/node-22")
        self.assertEqual(self.probe()["node"], f"found {usr_bin}/node")
        self.env["PATH"] = f"{usr_bin}:{self.env['PATH']}"
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {usr_bin}/node")

    def test_homebrews_bin_on_the_path_is_named_rather_than_its_cellar(self) -> None:
        # A fish config.fish that runs `brew shellenv` puts it on the exec's PATH.
        brew = self.root / "abs/opt/homebrew/bin"
        self.node_in(brew, f"{self.root}/abs/opt/homebrew/Cellar/node/24.1.0/bin/node", "24.1.0")
        self.env["PATH"] = f"{brew}:{self.env['PATH']}"
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {brew}/node")

    def test_another_directory_on_the_path_is_named_by_the_binary_it_runs(self) -> None:
        # fnm's per-shell link, which goes when that shell does.
        shell_link = self.root / "fnm_multishells/123_456/bin"
        binary = f"{self.root}/fnm/node-versions/v22.1.0/installation/bin/node"
        self.node_in(shell_link, binary)
        self.env["PATH"] = f"{shell_link}:{self.env['PATH']}"
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {binary}")

    def test_a_shim_is_named_by_the_binary_it_runs(self) -> None:
        binary = f"{self.root}/mise/installs/node/24.13.1/bin/node"
        self.node_in(self.home / ".local/share/mise/shims", binary, "24.13.1")
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["node"], f"found {binary}")

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


class ServiceNodeTests(HelperScriptCase):
    """Whether the Node.js the service names can still run, which a live process never shows."""

    LABEL = "dev.bybee.heeler.host-helper"

    def node_path(self, name: str = "node", exists: bool = True) -> Path:
        node = self.root / "keg 24%" / "bin" / name
        if exists:
            node.parent.mkdir(parents=True, exist_ok=True)
            node.write_text("#!/bin/sh\n")
            node.chmod(0o755)
        return node

    def write_unit(self, node: Path | str) -> None:
        unit = subprocess.run(
            [str(self.binary), "unit", '{"step":"locate"}', str(node), f"{self.helper_dir}/app/main.js"],
            capture_output=True, text=True, check=True,
        ).stdout
        path = self.home / ".config/systemd/user/heeler-host-helper.service"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(unit)

    def use_print_naming(self, node: Path) -> None:
        text = (LAUNCHCTL_FIXTURES / "running.txt").read_text()
        printed = self.root / "print.txt"
        printed.write_text(text.replace("\tprogram = /opt/homebrew/bin/node", f"\tprogram = {node}"))
        self.env["FAKE_LAUNCHCTL_PRINT"] = str(printed)
        self.env["FAKE_KERNEL"] = "Darwin"

    def test_a_unit_whose_node_has_gone_says_so_under_every_shell(self) -> None:
        self.write_unit(self.node_path(exists=False))
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertTrue(self.probe(shell)["serviceNodeGone"])

    def test_a_unit_whose_node_runs_says_nothing(self) -> None:
        self.write_unit(self.node_path())
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertFalse(self.probe(shell)["serviceNodeGone"])

    def test_a_node_that_is_not_executable_counts_as_gone(self) -> None:
        node = self.node_path()
        node.chmod(0o644)
        self.write_unit(node)
        self.assertTrue(self.probe()["serviceNodeGone"])

    def test_a_host_with_no_unit_says_nothing(self) -> None:
        self.assertFalse(self.probe()["serviceNodeGone"])

    def test_a_path_the_check_cannot_read_back_says_nothing(self) -> None:
        self.write_unit(self.root / "a\\b" / "node")
        self.assertFalse(self.probe()["serviceNodeGone"])

    def test_a_launchagent_whose_node_has_gone_says_so_under_every_shell(self) -> None:
        self.use_print_naming(self.node_path(exists=False))
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertTrue(self.probe(shell)["serviceNodeGone"])

    def test_a_launchagent_whose_node_runs_says_nothing(self) -> None:
        self.use_print_naming(self.node_path())
        self.assertFalse(self.probe()["serviceNodeGone"])

    def test_an_agent_launchd_does_not_hold_says_nothing(self) -> None:
        self.env["FAKE_KERNEL"] = "Darwin"
        self.assertFalse(self.probe()["serviceNodeGone"])


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

    def test_make_folders_that_fails_partway_says_which_it_created_and_ends_its_frame(self) -> None:
        (self.home / "taken").write_text("a file")
        made = self.home / "made"
        folders = [str(made), str(self.home / "taken"), str(self.home / "never")]
        result = self.run_script(step="makeFolders", folders=folders, privateFolder=folders[0])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            [line for line in result.stdout.splitlines() if line.startswith("created")],
            [f"created {made}"],
        )
        self.assertTrue(result.stdout.rstrip().endswith(" end"), result.stdout)
        self.assertFalse((self.home / "never").exists())

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


class MacOSTests(HelperScriptCase):
    """A Darwin Host: launchd instead of systemd, Application Support for the directory."""

    LABEL = "dev.bybee.heeler.host-helper"

    def setUp(self) -> None:
        super().setUp()
        self.env["FAKE_KERNEL"] = "Darwin"
        self.support = self.home / "Library/Application Support"
        self.helper_dir = self.support / "heeler/host-helper"
        self.agent = self.home / f"Library/LaunchAgents/{self.LABEL}.plist"

    def use_fixture(self, name: str) -> None:
        self.env["FAKE_LAUNCHCTL_PRINT"] = str(LAUNCHCTL_FIXTURES / name)

    def test_the_directory_is_under_application_support_whatever_xdg_says(self) -> None:
        self.env["XDG_DATA_HOME"] = f"{self.root}/data"
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.probe(shell)["data"], str(self.support))

    def test_asks_launchd_in_the_users_domain_and_touches_no_systemd(self) -> None:
        self.use_fixture("running.txt")
        probe = self.probe()
        self.assertEqual(probe["uid"], str(os.getuid()))
        self.assertEqual(
            self.log.read_text().splitlines(), [f"launchctl print user/{os.getuid()}/{self.LABEL}"])

    def test_reads_a_running_agent_under_every_shell(self) -> None:
        self.use_fixture("running.txt")
        for shell in shells():
            with self.subTest(shell=shell):
                probe = self.probe(shell)
                self.assertEqual(probe["health"], ["loaded", "running", "", "0"])
                self.assertEqual(probe["launchdPid"], 1116)

    def test_leaves_the_services_environment_on_the_host(self) -> None:
        self.use_fixture("running.txt")
        for shell in shells():
            with self.subTest(shell=shell):
                stdout = self.run_script(shell, step="probe").stdout
                self.assertIn("launchd \tstate = running", stdout)
                self.assertIn("launchd \tenvironment = {", stdout)
                self.assertNotIn("OSLogRateLimit", stdout)
                self.assertNotIn("PATH =>", stdout)

    def test_a_second_health_read_leaves_the_environment_on_the_host_too(self) -> None:
        self.use_fixture("running.txt")
        service = f"user/501/{self.LABEL}"
        for shell in shells():
            with self.subTest(shell=shell):
                result = self.run_script(shell, step="launchdHealth", service=service)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("\tstate = running\n", result.stdout)
                self.assertIn("\tpid = 1116\n", result.stdout)
                self.assertIn("\tenvironment = {\n", result.stdout)
                self.assertNotIn("OSLogRateLimit", result.stdout)
                self.assertNotIn("PATH =>", result.stdout)
                self.assertIn(f"{NONCE} end", result.stdout)

    def test_a_second_health_read_keeps_launchctls_answer(self) -> None:
        service = f"user/501/{self.LABEL}"
        for shell in shells():
            with self.subTest(shell=shell):
                result = self.run_script(shell, step="launchdHealth", service=service)
                self.assertEqual(result.returncode, 113, result.stderr)
                self.assertIn("Could not find service", result.stderr)
                self.assertIn(f"{NONCE} end", result.stdout)
        self.assertIn(f"launchctl print {service}", self.log.read_text())

    def test_an_agent_launchd_does_not_hold_reads_as_not_loaded(self) -> None:
        probe = self.probe()
        self.assertEqual(probe["health"], ["not-found", "inactive", "", "0"])
        self.assertFalse(probe["launchAgentFile"])

    def test_says_when_the_property_list_is_there(self) -> None:
        self.agent.parent.mkdir(parents=True)
        self.agent.write_text("<plist/>")
        self.assertTrue(self.probe()["launchAgentFile"])

    def test_changes_nothing_on_the_host(self) -> None:
        self.use_fixture("running.txt")
        self.probe()
        self.assertEqual(list(self.home.iterdir()), [])

    def test_reads_the_manifest_and_hashes_through_a_path_with_a_space(self) -> None:
        hashes = self.install_tree({"main.js": "one\n", "shared/a b.js": "two\n", "manifest.json": "{\"v\":1}\n"})
        hashes.pop("manifest.json")
        (self.helper_dir / "installed.json").write_text("{}\n")
        probe = self.probe()
        self.assertTrue(probe["appPresent"])
        self.assertEqual(probe["hashes"], hashes)
        self.assertEqual(probe["record"], "{}\n")

    def test_launchctl_gets_its_words_whole_and_reports_refusal(self) -> None:
        plist = f"{self.home}/Library/LaunchAgents/{self.LABEL}.plist"
        result = self.run_script(step="launchctl", arguments=["bootstrap", "user/501", plist])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"launchctl bootstrap user/501 {plist}", self.log.read_text())
        self.env["FAKE_LAUNCHCTL_REFUSES"] = "1"
        refused = self.run_script(step="launchctl", arguments=["bootstrap", "user/501", plist])
        self.assertEqual(refused.returncode, 5)
        self.assertIn("Bootstrap failed: 5", refused.stderr)
        self.assertIn(f"{NONCE} end", refused.stdout)

    def test_a_bootout_that_stopped_or_found_nothing_takes_the_property_list_with_it(self) -> None:
        for answer in ("", "3", "113"):
            with self.subTest(answer=answer):
                self.env["FAKE_LAUNCHCTL_EXIT"] = answer
                self.agent.parent.mkdir(parents=True, exist_ok=True)
                self.agent.write_text("<plist/>")
                result = self.run_script(
                    step="bootOutAndRemove", service=f"user/501/{self.LABEL}", path=str(self.agent))
                self.assertEqual(result.returncode, int(answer or 0), result.stderr)
                self.assertIn(f"{NONCE} end", result.stdout)
                self.assertFalse(self.agent.exists())

    def test_a_refused_bootout_keeps_the_property_list_and_says_so(self) -> None:
        self.agent.parent.mkdir(parents=True)
        self.agent.write_text("<plist/>")
        self.env["FAKE_LAUNCHCTL_EXIT"] = "1"
        result = self.run_script(
            step="bootOutAndRemove", service=f"user/501/{self.LABEL}", path=str(self.agent))
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{NONCE} end", result.stdout)
        self.assertTrue(self.agent.exists())
        self.assertIn(f"launchctl bootout user/501/{self.LABEL}", self.log.read_text())

    def test_the_property_list_is_what_the_recorded_domain_accepts(self) -> None:
        node, main, log = "/opt/no de/<bin>/node", "/Users/a&b/app/main.js", "/Users/a&b/helper.log"
        data = subprocess.run(
            [str(self.binary), "property-list", '{"step":"locate"}', node, main, log],
            capture_output=True, check=True,
        ).stdout
        self.assertEqual(plistlib.loads(data), {
            "Label": self.LABEL,
            "ProgramArguments": [node, main],
            "KeepAlive": True,
            "RunAtLoad": True,
            "LimitLoadToSessionType": "Background",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        })


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


class TidyStepTests(HelperScriptCase):
    """What a dropped SSH forward left mid-upload on hc-lab (2026-11-03): a staging
    folder holding a half-written file, the record, and empty extension folders."""

    def setUp(self) -> None:
        super().setUp()
        self.config = self.home / ".config"
        self.config.mkdir()
        self.extensions = [self.home / ".pi/agent/extensions", self.home / ".omp/agent/extensions"]
        for folder in self.extensions:
            folder.mkdir(parents=True)
        (self.config / "systemd/user/default.target.wants").mkdir(parents=True)
        staging = self.helper_dir / "staging-8D99F76C/core"
        staging.mkdir(parents=True)
        (staging / "follower.js.tmp-4c1d").write_text("half")
        self.unit = self.config / "systemd/user/heeler-host-helper.service"
        self.files = [
            str(self.unit), str(self.config / "systemd/user/default.target.wants/heeler-host-helper.service"),
            *(str(folder / "heeler-session.js") for folder in self.extensions),
        ]
        created = [
            self.config / "systemd", self.config / "systemd/user", self.config / "systemd/user/default.target.wants",
            self.home / ".local", self.home / ".local/share", self.home / ".local/share/heeler",
            self.home / ".pi", self.home / ".pi/agent", *self.extensions,
            self.home / ".omp", self.home / ".omp/agent",
        ]
        (self.helper_dir / "installed.json").write_text(json.dumps({"version": 1, "files": self.files, "folders": []}))
        self.folders = sorted(
            (str(path) for path in [*created, self.helper_dir]),
            key=lambda path: (-path.count("/"), path))

    def age(self) -> None:
        old = os.path.getmtime(self.home) - 3600
        for root, folders, files in os.walk(self.home):
            for name in folders + files:
                os.utime(os.path.join(root, name), (old, old), follow_symlinks=False)

    def tidy(self, shell: str = "/bin/sh", record: bool = True) -> subprocess.CompletedProcess:
        step = {"step": "tidyInterruptedInstall", "directory": str(self.helper_dir), "quietMinutes": 5}
        if record:
            step |= {"recordFiles": self.files, "recordFolders": self.folders}
        result = self.run_script(shell, **step)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_clears_everything_a_first_install_left_under_every_shell(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                self.setUp()
                self.age()
                result = self.tidy(shell)
                self.assertIn("record-removed", result.stdout)
                self.assertEqual(sorted(path.name for path in self.home.iterdir()), [".config"])
                self.assertEqual(list(self.config.iterdir()), [])

    def test_the_probe_says_leftovers_are_there_and_then_gone(self) -> None:
        self.assertTrue(self.probe()["leftovers"])
        self.age()
        self.tidy()
        self.assertFalse(self.probe()["leftovers"])

    def test_leaves_everything_while_an_install_may_still_be_writing(self) -> None:
        self.age()
        (self.helper_dir / "staging-8D99F76C/core/follower.js.tmp-4c1d").write_text("still coming")
        result = self.tidy()
        self.assertIn("busy", result.stdout)
        # The app reads `busy` only inside the frame.
        self.assertIn(f"{NONCE} end", result.stdout)
        self.assertTrue((self.helper_dir / "staging-8D99F76C/core/follower.js.tmp-4c1d").exists())
        self.assertTrue((self.helper_dir / "installed.json").exists())

    def test_a_fresh_temporary_beside_a_recorded_file_counts_as_writing(self) -> None:
        self.age()
        (self.extensions[0] / "heeler-session.js.tmp-77").write_text("still coming")
        self.assertIn("busy", self.tidy().stdout)
        self.assertTrue((self.helper_dir / "installed.json").exists())

    def test_a_recorded_file_on_the_host_keeps_the_record(self) -> None:
        (self.extensions[0] / "heeler-session.js").write_text("export default 1;\n")
        (self.extensions[1] / "heeler-session.js.tmp-77").write_text("half")
        self.age()
        result = self.tidy()
        self.assertNotIn("record-removed", result.stdout)
        self.assertEqual(sorted(path.name for path in self.helper_dir.iterdir()), ["installed.json"])
        self.assertEqual(list(self.extensions[1].iterdir()), [])
        self.assertTrue(self.extensions[1].exists())

    def test_a_dangling_link_the_record_names_keeps_it_too(self) -> None:
        os.symlink(self.unit, self.files[1])
        self.age()
        self.assertNotIn("record-removed", self.tidy().stdout)
        self.assertTrue((self.helper_dir / "installed.json").exists())

    def test_anything_else_in_the_directory_keeps_the_record(self) -> None:
        (self.helper_dir / "notifications.json").write_text("{}")
        self.age()
        self.tidy()
        self.assertEqual(
            sorted(path.name for path in self.helper_dir.iterdir()), ["installed.json", "notifications.json"])

    def test_a_helper_in_place_keeps_its_record_and_loses_its_staging(self) -> None:
        self.install_tree({"main.js": "one\n"})
        (self.helper_dir / "app.old-1").mkdir()
        self.age()
        self.tidy()
        self.assertEqual(sorted(path.name for path in self.helper_dir.iterdir()), ["app", "installed.json"])

    def test_without_a_record_only_the_leftovers_go(self) -> None:
        (self.helper_dir / "installed.json.tmp-9").write_text("half")
        self.age()
        self.tidy(record=False)
        self.assertEqual(sorted(path.name for path in self.helper_dir.iterdir()), ["installed.json"])

    def test_a_host_without_the_directory_changes_nothing(self) -> None:
        shutil.rmtree(self.home / ".local")
        result = self.tidy()
        self.assertNotIn("record-removed", result.stdout)
        self.assertIn(f"{NONCE} end", result.stdout)
        self.assertTrue(self.extensions[0].exists())


class UsageQueryTests(HelperScriptCase):
    MISSING = '{"version":1,"runtime":"missing"}'
    BEGIN = f"__HEELER_USAGE_BEGIN_{NONCE}\n"
    END = f"\n__HEELER_USAGE_END_{NONCE}:"

    def query(self, shell: str = "/bin/sh", session: str = "work", limits: bool = False) -> tuple[str, str]:
        result = self.run_script(
            shell, step="usageQuery", timeZone="Asia/Kolkata", claudeLimits=limits, session=session)
        self.assertEqual(result.returncode, 0, result.stderr)
        start = result.stdout.find(self.BEGIN)
        self.assertGreaterEqual(start, 0, result.stdout)
        body_start = start + len(self.BEGIN)
        end = result.stdout.find(self.END, body_start)
        if end < 0:
            return result.stdout[body_start:], "unfinished"
        status = result.stdout[end + len(self.END):].split("\n", 1)[0]
        return result.stdout[body_start:end].strip(), status

    def installed(self, query: str | None = "x\n") -> None:
        app = self.helper_dir / "app"
        app.mkdir(parents=True)
        (app / "main.js").write_text("")
        if query is not None:
            (app / "usage-query.js").write_text(query)

    def record(self, node_body: str, session: str = "work") -> Path:
        node = self.bin / "recorded-node"
        node.write_text(node_body)
        node.chmod(0o755)
        folder = self.helper_dir / "sessions" / session
        folder.mkdir(parents=True)
        (folder / "runtime-node").write_text(f"{node}\n")
        return node

    def test_a_host_without_the_helper_says_so_and_makes_nothing(self) -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.query(shell), ("helper-absent", "0"))
                self.assertFalse(self.helper_dir.exists())

    def test_a_helper_from_before_usage_says_so(self) -> None:
        self.installed(query=None)
        self.assertEqual(self.query(), ("helper-outdated", "0"))
        self.assertFalse((self.helper_dir / "sessions").exists())

    def test_no_record_reads_as_missing_and_makes_the_sessions_private_folder(self) -> None:
        self.installed()
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.query(shell, session="my 'work'"), (self.MISSING, "0"))
                folder = self.helper_dir / "sessions" / "my 'work'"
                self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(folder.parent.stat().st_mode), 0o700)

    def test_runs_the_helpers_query_with_the_recorded_node(self) -> None:
        self.installed()
        self.record(f"""#!/bin/sh
printf '%s\\n' "$@" >> "{self.log}"
printf '{{"version":1,"runtime":"recorded"}}\\n'
""")
        for shell in shells():
            with self.subTest(shell=shell):
                self.log.write_text("")
                self.assertEqual(self.query(shell), ('{"version":1,"runtime":"recorded"}', "0"))
                self.assertEqual(
                    self.log.read_text().splitlines(),
                    [str(self.helper_dir / "app/usage-query.js"), "--tz", "Asia/Kolkata", "--session", "work"],
                )

    def test_asks_for_claude_codes_limits_only_when_told(self) -> None:
        self.installed()
        self.record(f"""#!/bin/sh
printf '%s\\n' "$*" >> "{self.log}"
printf '{{}}\\n'
""")
        self.query(limits=False)
        self.query(limits=True)
        calls = self.log.read_text().splitlines()
        self.assertNotIn("--claude-limits", calls[0])
        self.assertTrue(calls[1].endswith("--claude-limits"))

    def test_follows_xdg_data_home_and_ignores_a_relative_one(self) -> None:
        data = self.root / "data"
        self.env["XDG_DATA_HOME"] = str(data)
        app = data / "heeler/host-helper/app"
        app.mkdir(parents=True)
        (app / "main.js").write_text("")
        (app / "usage-query.js").write_text("")
        self.assertEqual(self.query(), (self.MISSING, "0"))
        self.assertTrue((data / "heeler/host-helper/sessions/work").is_dir())

        self.env["XDG_DATA_HOME"] = "relative"
        self.assertEqual(self.query(), ("helper-absent", "0"))

    def test_a_query_that_fails_reports_its_status(self) -> None:
        self.installed()
        self.record("#!/bin/sh\nexit 1\n")
        self.assertEqual(self.query(), ("", "1"))

    def test_a_node_that_cannot_run_reads_as_missing(self) -> None:
        self.installed()
        node = self.record("#!/bin/sh\nexit 127\n")
        self.assertEqual(self.query(), (self.MISSING, "0"))
        node.unlink()
        self.assertEqual(self.query(), (self.MISSING, "0"))

    def unit_names(self, node: Path) -> None:
        unit = self.home / ".config/systemd/user/heeler-host-helper.service"
        unit.parent.mkdir(parents=True, exist_ok=True)
        unit.write_text(f'[Service]\nExecStart="{node}" "{self.helper_dir}/app/main.js"\n')

    def test_a_record_and_a_service_on_a_node_that_has_gone_ask_for_repair(self) -> None:
        self.installed()
        node = self.record("#!/bin/sh\n")
        node.unlink()
        self.unit_names(node)
        for shell in shells():
            with self.subTest(shell=shell):
                self.assertEqual(self.query(shell), ("helper-node-gone", "0"))

    def test_a_mac_whose_record_and_agent_name_a_node_that_has_gone_asks_for_repair(self) -> None:
        self.env["FAKE_KERNEL"] = "Darwin"
        self.helper_dir = self.home / "Library/Application Support/heeler/host-helper"
        self.installed()
        node = self.record("#!/bin/sh\n")
        node.unlink()
        printed = self.root / "print.txt"
        printed.write_text(
            (LAUNCHCTL_FIXTURES / "running.txt").read_text().replace(
                "\tprogram = /opt/homebrew/bin/node", f"\tprogram = {node}"))
        self.env["FAKE_LAUNCHCTL_PRINT"] = str(printed)
        self.assertEqual(self.query(), ("helper-node-gone", "0"))

    def service_node(self, body: str) -> Path:
        node = self.root / "service node" / "node"
        node.parent.mkdir(parents=True, exist_ok=True)
        node.write_text(body)
        node.chmod(0o755)
        return node

    def test_a_recorded_node_that_has_gone_runs_the_query_with_the_services_node(self) -> None:
        # The service names a manager's link, the record the binary it led to then.
        self.installed()
        self.record("#!/bin/sh\n").unlink()
        self.unit_names(self.service_node(f"""#!/bin/sh
printf '%s\\n' "$@" >> "{self.log}"
printf '{{"version":1,"runtime":"service"}}\\n'
"""))
        for shell in shells():
            with self.subTest(shell=shell):
                self.log.write_text("")
                self.assertEqual(self.query(shell), ('{"version":1,"runtime":"service"}', "0"))
                self.assertEqual(
                    self.log.read_text().splitlines(),
                    [str(self.helper_dir / "app/usage-query.js"), "--tz", "Asia/Kolkata", "--session", "work"],
                )

    def test_a_mac_whose_record_has_gone_runs_the_query_with_the_agents_node(self) -> None:
        self.env["FAKE_KERNEL"] = "Darwin"
        self.helper_dir = self.home / "Library/Application Support/heeler/host-helper"
        self.installed()
        self.record("#!/bin/sh\n").unlink()
        node = self.service_node("#!/bin/sh\nprintf '{\"version\":1,\"runtime\":\"agent\"}\\n'\n")
        printed = self.root / "print.txt"
        printed.write_text(
            (LAUNCHCTL_FIXTURES / "running.txt").read_text().replace(
                "\tprogram = /opt/homebrew/bin/node", f"\tprogram = {node}"))
        self.env["FAKE_LAUNCHCTL_PRINT"] = str(printed)
        self.assertEqual(self.query(), ('{"version":1,"runtime":"agent"}', "0"))

    def test_the_services_node_reports_a_failed_query_like_the_records(self) -> None:
        self.installed()
        self.record("#!/bin/sh\n").unlink()
        self.unit_names(self.service_node("#!/bin/sh\nexit 1\n"))
        self.assertEqual(self.query(), ("", "1"))

    def test_a_service_whose_node_cannot_run_the_query_waits_for_its_next_record(self) -> None:
        self.installed()
        self.record("#!/bin/sh\n").unlink()
        self.unit_names(self.service_node("#!/bin/sh\nexit 127\n"))
        self.assertEqual(self.query(), (self.MISSING, "0"))

    def test_the_services_node_runs_only_when_it_is_another_one_that_runs(self) -> None:
        self.installed()
        # The record's own Node.js, which the query already tried.
        same = self.record("#!/bin/sh\nprintf ran >> \"$FAKE_LOG\"\nexit 127\n")
        self.unit_names(same)
        self.assertEqual(self.query(), (self.MISSING, "0"))
        self.assertEqual(self.log.read_text(), "ran")
        # One the unit names that cannot be read back, or that is not executable.
        self.unit_names(self.root / "a\\b" / "node")
        self.assertEqual(self.query(), (self.MISSING, "0"))
        unrunnable = self.service_node("#!/bin/sh\nprintf '{}\\n'\n")
        unrunnable.chmod(0o644)
        self.unit_names(unrunnable)
        self.assertEqual(self.query(), ("helper-node-gone", "0"))

    def test_a_relative_node_is_never_run(self) -> None:
        self.installed()
        folder = self.helper_dir / "sessions/work"
        folder.mkdir(parents=True)
        (folder / "runtime-node").write_text("relative-node\n")
        self.assertEqual(self.query(), (self.MISSING, "0"))

    def test_an_answer_past_the_cap_never_reads_as_finished(self) -> None:
        self.installed()
        self.record("#!/bin/sh\nhead -c 1100000 /dev/zero | tr '\\0' x\n")
        _, status = self.query()
        self.assertEqual(status, "unfinished")

    def test_finds_the_helper_under_application_support_on_a_mac(self) -> None:
        self.env["FAKE_KERNEL"] = "Darwin"
        self.env["XDG_DATA_HOME"] = f"{self.root}/data"
        self.helper_dir = self.home / "Library/Application Support/heeler/host-helper"
        self.assertEqual(self.query(), ("helper-absent", "0"))
        self.installed()
        self.assertEqual(self.query(), (self.MISSING, "0"))
        self.assertTrue((self.helper_dir / "sessions/work").is_dir())

    def test_the_real_helper_answers_from_a_bare_copy(self) -> None:
        node = shutil.which("node")
        if node is None:
            self.skipTest("node not found")
        shutil.copytree(ROOT / "plugin/helper", self.helper_dir / "app")
        folder = self.helper_dir / "sessions/work"
        folder.mkdir(parents=True)
        (folder / "runtime-node").write_text(f"{node}\n")
        self.assertEqual(self.query(), (self.MISSING, "0"))


if __name__ == "__main__":
    if shutil.which("swiftc") is None:
        print("skipping: swiftc not found", file=sys.stderr)
        sys.exit(0)
    unittest.main()
