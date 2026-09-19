#!/usr/bin/env python3
"""Check the real New Agent sheet's first directory browser presentation using idb.

Install the candidate with `make sim-id`, then open a fresh New Agent form,
select a Host, and keep the Workspace dropdown visible without opening it.
Run `make test-directory-browser-ui SIMULATOR_UDID=<uuid>`.

The precondition matters: reopening an already-used form can hide a stale
SwiftUI sheet capture. This probe does not launch an Agent or change Host data.
It leaves the browser open and saves its accessibility tree and screenshot.
Requires idb and Xcode command-line tools; uses only Python's standard library.
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True, help="Exact booted simulator UUID")
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    def ui(*arguments: str) -> str:
        return subprocess.check_output(
            ["idb", "ui", *arguments, "--udid", args.udid],
            text=True,
            timeout=15,
        )

    def snapshot() -> list[dict]:
        return json.loads(ui("describe-all"))

    devices = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "--json"], text=True, timeout=15
    ))
    if not any(
        device["udid"] == args.udid and device["state"] == "Booted"
        for runtime in devices["devices"].values()
        for device in runtime
    ):
        raise RuntimeError("The specified simulator must already be booted")

    elements = snapshot()
    if not any(item.get("AXUniqueId") == "New Agent" for item in elements):
        raise RuntimeError("Open a fresh New Agent form before running the probe")

    # Let Agent discovery finish before opening Browse. Otherwise its unrelated
    # view update can refresh the stale capture and mask the first-open defect.
    deadline = time.monotonic() + 15
    while any(item.get("AXLabel") == "Detecting installed Agents…" for item in elements):
        if time.monotonic() >= deadline:
            raise RuntimeError("Wait for Agent discovery to finish before testing New Workspace")
        time.sleep(0.2)
        elements = snapshot()

    pickers = [item for item in elements if item.get("AXUniqueId") == "start-workspace-picker"]
    if len(pickers) != 1 or not pickers[0].get("enabled"):
        raise RuntimeError("Exactly one enabled Workspace dropdown must be visible")
    frame = pickers[0]["frame"]
    ui("tap", str(round(frame["x"] + frame["width"] / 2)),
       str(round(frame["y"] + frame["height"] / 2)))

    deadline = time.monotonic() + 5
    matches = []
    while time.monotonic() < deadline:
        elements = snapshot()
        matches = [item for item in elements
                   if item.get("AXUniqueId") == "new-workspace"
                   or (item.get("AXLabel") == "New Workspace" and item.get("type") == "Button")]
        if matches:
            break
        time.sleep(0.2)
    (args.output_dir / "workspace-menu.json").write_text(json.dumps(elements, indent=2) + "\n")
    if len(matches) != 1 or not matches[0].get("enabled"):
        raise RuntimeError("Exactly one enabled New Workspace control must be visible")
    frame = matches[0]["frame"]
    ui("tap", str(round(frame["x"] + frame["width"] / 2)),
       str(round(frame["y"] + frame["height"] / 2)))

    deadline = time.monotonic() + 5
    visible = False
    while time.monotonic() < deadline:
        elements = snapshot()
        visible = any(
            item.get("AXUniqueId") == "Browse Directories"
            or item.get("AXLabel") == "Browse Directories"
            for item in elements
        )
        if visible:
            break
        time.sleep(0.2)

    (args.output_dir / "browser.json").write_text(json.dumps(elements, indent=2) + "\n")
    subprocess.run(
        ["xcrun", "simctl", "io", args.udid, "screenshot",
         str(args.output_dir / "browser.png")],
        check=True,
        timeout=15,
    )
    if not visible:
        print("FAIL: first Browse presentation has no browser content", file=sys.stderr)
        return 1
    print("PASS: first Browse presentation renders the directory browser")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
