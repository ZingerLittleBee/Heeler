#!/usr/bin/env python3
"""Print the first physical iPhone or iPad UDID reported by devicectl."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device_type", choices=("iPhone", "iPad"))
    arguments = parser.parse_args()

    # A file also works with Xcode versions that cannot emit JSON to stdout.
    with tempfile.TemporaryDirectory(prefix="heeler-devices-") as directory:
        output = Path(directory) / "devices.json"
        result = subprocess.run(
            ["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", str(output)],
            stdout=sys.stderr,
            check=False,
        )
        if result.returncode:
            return result.returncode
        devices = json.loads(output.read_text())["result"]["devices"]

    for device in devices:
        hardware = device.get("properties", {}).get("hardware")
        if hardware is None:
            hardware = device.get("hardwareProperties", {})
        if (
            hardware.get("deviceType") == arguments.device_type
            and hardware.get("reality") == "physical"
            and hardware.get("udid")
        ):
            print(hardware["udid"])
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
