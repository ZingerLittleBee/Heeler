#!/usr/bin/env python3
"""Run the plugin install's Node.js probe against fake Host layouts.

Compiles Sources/Heeler/Transport/NodeToolchainProbe.swift with a stub
HerdrHostPath, then runs the wrapped `herdr` command it produces under each
POSIX shell found here (/bin/sh, dash, bash, ksh, busybox). Every layout is
a fake HOME holding stand-in `node` and `npm` scripts where one install
method keeps them, and a stand-in `herdr` that reports which `npm` its child
build would start. Needs swiftc (agent-tools CI uses the Ubuntu image's,
whose /bin/sh is dash); uses only Python's standard library.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "Sources/Heeler/Transport/NodeToolchainProbe.swift"

STUB = """
enum HerdrHostPath {
    static let pathExport = "export PATH=\\"$PATH\\""
    static func isBareHerdrCommand(_ command: String) -> Bool { command.hasPrefix("herdr ") }
}
"""

MAIN = """
print(NodeToolchainProbe.wrappingBareHerdr(CommandLine.arguments[1]), terminator: "")
"""

# The probe's fixed system locations. Tests move them under the fake root, so
# what this machine has installed (the CI image ships Node.js in
# /usr/local/bin) cannot answer for a layout.
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

HERDR = """#!/bin/sh
echo "herdr=$0"
echo "npm=$(command -v npm)"
echo "node=$(node -p process.versions.node)"
for argument in "$@"; do echo "arg=$argument"; done
"""


def shells() -> list[str]:
    found = ["/bin/sh"]
    for name in ("dash", "bash", "ksh"):
        path = shutil.which(name)
        if path:
            found.append(path)
    if shutil.which("busybox"):
        found.append("busybox sh")
    return found


class ProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = Path(tempfile.mkdtemp(prefix="heeler-probe-build-"))
        (cls.build / "stub.swift").write_text(STUB)
        (cls.build / "main.swift").write_text(MAIN)
        cls.binary = cls.build / "probe"
        subprocess.run(
            ["swiftc", str(PROBE), str(cls.build / "stub.swift"),
             str(cls.build / "main.swift"), "-o", str(cls.binary)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.build, ignore_errors=True)

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="heeler-probe-"))
        self.home = self.root / "home"
        self.home.mkdir()
        self.system = self.root / "system"
        self.system.mkdir()
        self.tool(self.system / "herdr", HERDR)
        self.env = {
            "HOME": str(self.home),
            "USER": "probe",
            "SHELL": "/bin/sh",
            "PATH": f"{self.system}:/usr/bin:/bin",
        }

    def tearDown(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def tool(self, path: Path, body: str) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        path.chmod(0o755)
        return path

    def node(self, directory: Path, version: str = "22.1.0", npm_runs: bool = True) -> Path:
        """Stand-ins that answer the probe's two questions. A shim with no
        version selected fails `npm --version`, as mise's does."""
        self.tool(directory / "node", f'#!/bin/sh\n[ "$1" = -p ] && echo {version}\n')
        self.tool(directory / "npm", "#!/bin/sh\n" + ("echo 10.0.0\n" if npm_runs else "exit 1\n"))
        return directory

    def run_install(self, command: str = "herdr plugin install 'a b' --yes", shell: str = "/bin/sh"):
        wrapped = subprocess.run(
            [str(self.binary), command], check=True, capture_output=True, text=True
        ).stdout
        self.assertTrue(wrapped.startswith("/bin/sh -c "))
        for prefix in SYSTEM_PREFIXES:
            self.assertIn(prefix, wrapped)
            wrapped = wrapped.replace(prefix, f"{self.root}/abs{prefix}")
        if shell != "/bin/sh":
            wrapped = shell + wrapped[len("/bin/sh"):]
        return subprocess.run(
            ["/bin/sh", "-c", "LC_ALL=C " + wrapped],
            env=self.env, capture_output=True, text=True, timeout=60,
        )

    def assert_found(self, directory: Path, version: str = "22.1.0") -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                result = self.run_install(shell=shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"npm={directory}/npm\n", result.stdout)
                self.assertIn(f"node={version}\n", result.stdout)

    def assert_missing(self, marker: str = "__HEELER_NODE_NOT_FOUND__") -> None:
        for shell in shells():
            with self.subTest(shell=shell):
                result = self.run_install(shell=shell)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn(marker, result.stderr)
                self.assertNotIn("herdr=", result.stdout)

    def test_nothing_installed_stops_before_herdr(self) -> None:
        self.assert_missing()

    def test_each_install_method_is_found_on_its_own(self) -> None:
        layouts = {
            "mise": ".local/share/mise/shims",
            "volta": ".volta/bin",
            "fnm xdg": ".local/share/fnm/aliases/default/bin",
            "fnm macos": "Library/Application Support/fnm/aliases/default/bin",
            "fnm legacy": ".fnm/aliases/default/bin",
            "nvm without alias": ".nvm/versions/node/v22.1.0/bin",
            "asdf": ".asdf/shims",
            "nodenv": ".nodenv/shims",
            "nvs": ".nvs/default/bin",
            "nodebrew": ".nodebrew/current/bin",
            "n": "n/bin",
            "proto": ".proto/shims",
            "pnpm macos": "Library/pnpm",
            "pnpm linux": ".local/share/pnpm",
        }
        for name, relative in layouts.items():
            with self.subTest(layout=name):
                directory = self.node(self.home / relative)
                self.assert_found(directory)
                shutil.rmtree(self.home)
                self.home.mkdir()

    def test_homebrew_keeps_versioned_formulae_off_the_path(self) -> None:
        self.assert_found(self.node(self.root / "abs/opt/homebrew/opt/node@22/bin"))

    def test_environment_overrides_move_the_managers(self) -> None:
        directory = self.node(self.root / "custom-volta/bin")
        self.env["VOLTA_HOME"] = str(self.root / "custom-volta")
        self.assert_found(directory)

    def test_nvm_resolves_its_default_alias(self) -> None:
        self.node(self.home / ".nvm/versions/node/v20.0.0/bin", "20.0.0")
        chosen = self.node(self.home / ".nvm/versions/node/v24.2.0/bin", "24.2.0")
        self.tool(self.home / ".nvm/nvm.sh",
                  f'nvm() {{ [ "$1 $2" = "which default" ] && echo "$NVM_DIR/versions/node/v24.2.0/bin/node"; }}\n'
                  'echo nvm noise\n')
        self.assert_found(chosen, "24.2.0")

    def test_asdf_shims_can_find_asdf(self) -> None:
        chosen = self.node(self.home / ".asdf/shims")
        self.tool(chosen / "npm", '#!/bin/sh\ncommand -v asdf >/dev/null && echo 10.0.0\n')
        self.tool(self.home / ".asdf/bin/asdf", "#!/bin/sh\n")
        self.assert_found(chosen)

    def test_a_shim_without_a_version_is_passed_over(self) -> None:
        self.node(self.home / ".local/share/mise/shims", npm_runs=False)
        chosen = self.node(self.home / ".volta/bin")
        self.assert_found(chosen)

    def test_an_old_default_gives_way_to_a_new_enough_one(self) -> None:
        self.node(self.home / ".nvm/versions/node/v18.19.0/bin", "18.19.0")
        chosen = self.node(self.home / ".nvm/versions/node/v22.1.0/bin")
        self.assert_found(chosen)

    def test_only_old_versions_are_reported(self) -> None:
        self.node(self.home / ".volta/bin", "18.19.0")
        self.node(self.system, "16.20.2")
        self.assert_missing("__HEELER_NODE_TOO_OLD__=18.19.0\n")

    def test_a_version_manager_comes_before_the_path(self) -> None:
        self.node(self.system, "20.5.0")
        chosen = self.node(self.home / ".volta/bin")
        self.assert_found(chosen)

    def test_the_path_is_used_when_nothing_else_is_there(self) -> None:
        self.assert_found(self.node(self.system, "20.5.0"), "20.5.0")

    def login_shell(self, name: str, path: str) -> None:
        """A login shell whose rc files set `path` and print noise."""
        self.env["SHELL"] = str(self.tool(
            self.root / f"shells/{name}",
            f'#!/bin/sh\necho "PATH=/wrong"\nPATH="{path}" exec /usr/bin/env\n'))

    def test_the_login_shell_is_asked_last(self) -> None:
        chosen = self.node(self.root / "rc-only/bin")
        self.login_shell("zsh", f"{chosen}:/usr/bin:/bin")
        self.assert_found(chosen)
        # Ending the watchdog leaves no job notice in herdr's stderr.
        self.assertEqual(self.run_install().stderr, "")

    def test_shims_from_the_login_shell_keep_its_path(self) -> None:
        shims = self.node(self.root / "asdf-data/shims")
        self.tool(shims / "npm", '#!/bin/sh\ncommand -v asdf >/dev/null && echo 10.0.0\n')
        tools = self.root / "tools"
        self.tool(tools / "asdf", "#!/bin/sh\n")
        self.login_shell("bash", f"{shims}:{tools}:/usr/bin:/bin")
        self.assert_found(shims)

    def test_a_login_shell_that_waits_is_cut_short(self) -> None:
        # The trailing `:` keeps the shell from exec-ing into the sleep.
        self.env["SHELL"] = str(self.tool(self.root / "shells/bash", "#!/bin/sh\nsleep 61\n:\n"))
        started = time.monotonic()
        result = self.run_install()
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual(result.returncode, 3)
        self.assertIn("__HEELER_NODE_NOT_FOUND__", result.stderr)
        # Neither what the setup waited on nor the watchdog's sleep stays.
        time.sleep(0.5)
        processes = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
        left = [line for line in map(str.strip, processes.splitlines())
                if line in ("sleep 61", "sleep 10")]
        self.assertEqual(left, [])

    def test_an_npm_upgraded_into_its_own_prefix_uses_the_systems_node(self) -> None:
        upgraded = self.root / "npm-prefix/bin"
        self.tool(upgraded / "npm", "#!/bin/sh\necho 10.9.2\n")
        self.node(self.root / "usr-bin")
        self.env["PATH"] = f"{self.system}:{upgraded}:{self.root / 'usr-bin'}:/usr/bin:/bin"
        self.assert_found(upgraded)

    def test_node_without_npm_says_npm_is_missing(self) -> None:
        self.tool(self.system / "node", '#!/bin/sh\n[ "$1" = -p ] && echo 20.19.2\n')
        self.assert_missing("__HEELER_NPM_NOT_FOUND__=20.19.2\n")

    def test_an_old_node_without_npm_is_too_old(self) -> None:
        self.tool(self.system / "node", '#!/bin/sh\n[ "$1" = -p ] && echo 18.20.4\n')
        self.assert_missing("__HEELER_NODE_TOO_OLD__=18.20.4\n")

    def test_other_login_shells_are_not_run(self) -> None:
        marker = self.root / "ran"
        self.env["SHELL"] = str(self.tool(self.root / "shells/nu", f"#!/bin/sh\ntouch {marker}\n"))
        self.assert_missing()
        self.assertFalse(marker.exists())

    def test_herdr_is_the_one_on_the_path_before_node_was_added(self) -> None:
        chosen = self.node(self.home / ".volta/bin")
        self.tool(chosen / "herdr", "#!/bin/sh\necho wrong herdr\n")
        result = self.run_install()
        self.assertIn(f"herdr={self.system}/herdr\n", result.stdout)
        self.assertNotIn("wrong herdr", result.stdout)

    def test_herdrs_words_arrive_intact(self) -> None:
        self.node(self.system)
        result = self.run_install("herdr --session work plugin install 'it'\\''s here' --yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("arg=--session\narg=work\narg=plugin\narg=install\narg=it's here\narg=--yes\n",
                      result.stdout)

    def test_a_missing_herdr_still_exits_127(self) -> None:
        (self.system / "herdr").unlink()
        self.node(self.system)
        self.assertEqual(self.run_install().returncode, 127)


if __name__ == "__main__":
    if not shutil.which("swiftc"):
        sys.exit("swiftc is required")
    unittest.main()
