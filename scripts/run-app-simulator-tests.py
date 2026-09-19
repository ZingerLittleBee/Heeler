#!/usr/bin/env python3
"""Run xcodebuild with the simulator accessibility tree enabled (refs #339).

Both make test-app and the CI app lane use this entrypoint. These simulator
preferences are test infrastructure, not app APIs; recheck them on SDK upgrades.
Only the two owned keys are restored, including their original absence/type.
"""

from __future__ import annotations

import json
import plistlib
import signal
import subprocess
import sys


DOMAIN = "com.apple.Accessibility"
PREFERENCES = {"AccessibilityEnabled": True, "ApplicationAccessibilityEnabled": 1}


def simctl(*arguments: str) -> bytes:
    return subprocess.check_output(["xcrun", "simctl", *arguments])


def pin_destination(arguments: list[str]) -> str | None:
    """Resolve names once so preparation and xcodebuild use the same device."""
    if arguments.count("-destination") != 1:
        raise ValueError("App tests require exactly one -destination")
    index = arguments.index("-destination") + 1
    destination = dict(part.split("=", 1) for part in arguments[index].split(","))
    if destination.get("platform") != "iOS Simulator":
        return None
    if "id" in destination:
        return destination["id"]

    runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
    requested_os = destination.get("OS", "latest")
    candidates = []
    for runtime in runtimes:
        if not runtime["isAvailable"] or runtime.get("platform") != "iOS":
            continue
        if requested_os != "latest" and runtime["version"] != requested_os:
            continue
        version = tuple(int(part) for part in runtime["version"].split("."))
        for device in devices.get(runtime["identifier"], []):
            if device["name"] == destination.get("name"):
                candidates.append((version, device["udid"]))
    if not candidates:
        raise ValueError(f"No available simulator matches {arguments[index]}")
    # Multiple installed runtime builds can report the same device. Deduplicate
    # before rejecting genuinely ambiguous names on the selected OS version.
    latest = max(version for version, _ in candidates)
    matches = {udid for version, udid in candidates if version == latest}
    if len(matches) != 1:
        raise ValueError("Simulator name is ambiguous; use SIM_DESTINATION with id=<UDID>")
    udid = matches.pop()
    destination.pop("name", None)
    destination.pop("OS", None)
    destination["id"] = udid
    arguments[index] = ",".join(f"{key}={value}" for key, value in destination.items())
    return udid


def write_preference(udid: str, key: str, value: bool | int | None) -> None:
    if value is None:
        simctl("spawn", udid, "defaults", "delete", DOMAIN, key)
    else:
        kind = "-bool" if type(value) is bool else "-int"
        simctl("spawn", udid, "defaults", "write", DOMAIN, key, kind, str(value).lower())


def run(arguments: list[str]) -> int:
    udid = pin_destination(arguments)
    if udid is None:
        return subprocess.call(["xcodebuild", *arguments])

    # -b boots a shut-down device and waits for its services before defaults or
    # the test host can start. CI already overlaps this boot with compilation.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
    preferences = plistlib.loads(simctl("spawn", udid, "defaults", "export", DOMAIN, "-"))
    original = {key: preferences.get(key) for key in PREFERENCES}
    for key, value in original.items():
        if value is not None and type(value) not in (bool, int):
            raise ValueError(f"Cannot safely restore {DOMAIN}/{key}: unexpected preference type")

    changed = []
    child = None
    interrupted = 0

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted
        interrupted = signum
        if child is not None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass
        else:
            raise SystemExit(128 + signum)

    previous_handlers = {
        signum: signal.signal(signum, interrupt) for signum in (signal.SIGINT, signal.SIGTERM)
    }
    status = 1
    try:
        for key, value in PREFERENCES.items():
            # Record before writing so a cancelled/failed write is also restored.
            changed.append(key)
            write_preference(udid, key, value)
        print(f"==> Simulator {udid}: accessibility enabled for app tests", flush=True)
        child = subprocess.Popen(["xcodebuild", *arguments])
        status = child.wait()
        status = 128 + interrupted if interrupted else (128 - status if status < 0 else status)
    finally:
        # Let cleanup finish if the watchdog signals the whole process group.
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        restore_failed = False
        for key in reversed(changed):
            try:
                # A write that failed before creating the key needs no deletion.
                current = plistlib.loads(
                    simctl("spawn", udid, "defaults", "export", DOMAIN, "-")
                )
                if original[key] is not None or key in current:
                    write_preference(udid, key, original[key])
            except (subprocess.CalledProcessError, OSError, ValueError) as error:
                restore_failed = True
                print(f"Could not restore {DOMAIN}/{key}: {error}", file=sys.stderr)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if restore_failed and status == 0:
            status = 1
    return status


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"App simulator test setup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
