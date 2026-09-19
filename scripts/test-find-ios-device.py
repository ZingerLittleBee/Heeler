#!/usr/bin/env python3
"""Exercise Make's device selection without requiring connected Apple devices."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def device(kind: str, reality: str, udid: str, *, legacy: bool = False) -> dict:
    hardware = {"deviceType": kind, "reality": reality, "udid": udid}
    return {"hardwareProperties": hardware} if legacy else {"properties": {"hardware": hardware}}


class DeviceDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="heeler-device-test-")
        self.addCleanup(self.directory.cleanup)
        directory = Path(self.directory.name)
        self.fixture = directory / "devices.json"
        xcrun = directory / "xcrun"
        xcrun.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "if os.environ.get('FAIL_DISCOVERY'):\n"
            "    sys.exit('device discovery failed')\n"
            "destination = sys.argv[sys.argv.index('--json-output') + 1]\n"
            "pathlib.Path(destination).write_text(pathlib.Path(os.environ['DEVICE_FIXTURE']).read_text())\n"
        )
        xcrun.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(directory) + os.pathsep + os.environ["PATH"],
            "DEVICE_FIXTURE": str(self.fixture),
        }
        for key in ("DEVICE", "DEVICE_IPAD", "MAKEFLAGS", "MFLAGS", "MAKELEVEL"):
            self.environment.pop(key, None)

    def run_make(self, devices: list[dict], *arguments: str) -> subprocess.CompletedProcess:
        self.fixture.write_text(json.dumps({"result": {"devices": devices}}))
        return subprocess.run(
            ["make", "--no-print-directory", *arguments],
            cwd=ROOT, env=self.environment, text=True, capture_output=True, check=False,
        )

    def test_install_selects_physical_phone_udid_not_simulator_or_ipad(self) -> None:
        udid = "00000001-0000000000000001"
        result = self.run_make([
            device("iPhone", "simulated", "11111111-1111-1111-1111-111111111111"),
            device("iPad", "physical", "00000002-0000000000000002"),
            device("iPhone", "physical", udid),
        ], "-n", "install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("platform=iOS,id=" + udid, result.stdout)
        self.assertIn("device install app --device " + udid, result.stdout)
        self.assertIn("--terminate-existing --device " + udid, result.stdout)

    def test_ipad_install_supports_legacy_json(self) -> None:
        udid = "00000002-0000000000000002"
        result = self.run_make([
            device("iPhone", "physical", "00000001-0000000000000001", legacy=True),
            device("iPad", "simulated", "22222222-2222-2222-2222-222222222222", legacy=True),
            device("iPad", "physical", udid, legacy=True),
        ], "-n", "install-ipad")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("device install app --device " + udid, result.stdout)

    def test_simulator_only_fails_preflight(self) -> None:
        result = self.run_make([
            device("iPhone", "simulated", "11111111-1111-1111-1111-111111111111"),
        ], "check-device")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No physical iPhone found", result.stdout)

    def test_explicit_overrides_bypass_discovery(self) -> None:
        self.environment["FAIL_DISCOVERY"] = "1"
        result = self.run_make([], "check-device", "check-device-ipad",
                               "DEVICE=explicit-phone", "DEVICE_IPAD=explicit-ipad")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("device discovery failed", result.stderr)

    def test_discovery_failure_remains_visible(self) -> None:
        self.environment["FAIL_DISCOVERY"] = "1"
        result = self.run_make([], "check-device")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("device discovery failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
