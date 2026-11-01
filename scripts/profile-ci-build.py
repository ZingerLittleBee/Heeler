#!/usr/bin/env python3
"""Capture one compilation-cold CI build without running any tests."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def output(*command: str) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def main() -> int:
    evidence = ROOT / ".ci/compile-profile"
    evidence.mkdir(parents=True, exist_ok=False)
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "--json"))
    device = next(
        device for group in devices["devices"].values() for device in group
        if device["name"] == "iPhone 17" and device["isAvailable"]
    )
    destination = f"platform=iOS Simulator,id={device['udid']}"
    bundle = evidence / "build.xcresult"
    manifest = {
        "candidate_sha": output("git", "rev-parse", "HEAD"),
        "source_sha": os.environ["PROFILE_SOURCE_SHA"],
        "xcode": output("xcodebuild", "-version"),
        "sdk": output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
        "macos": output("sw_vers"),
        "logical_cpus": int(output("sysctl", "-n", "hw.logicalcpu")),
        "memory_bytes": int(output("sysctl", "-n", "hw.memsize")),
        "runner_image": os.environ.get("ImageVersion"),
        "destination": destination,
        "test_execution": False,
        "compilation_cache": False,
        "fresh_derived_data": True,
    }
    (evidence / "environment.json").write_text(json.dumps(manifest, indent=2) + "\n")

    # Keep the committed project, real resources, signing, and ordinary CI flags.
    # A concrete destination matches CI; no app is installed or launched.
    with tempfile.TemporaryDirectory(prefix="heeler-profile.", dir="/tmp") as temporary:
        derived = Path(temporary) / "AppDerivedData"
        command = [
            "xcodebuild", "build-for-testing", "-project", "Heeler.xcodeproj",
            "-scheme", "Heeler", "-derivedDataPath", str(derived),
            "-destination", destination,
            "-clonedSourcePackagesDirPath", str(ROOT / ".ci/source-packages"),
            "-collect-test-diagnostics", "never", "-showBuildTimingSummary",
            "-resultBundlePath", str(bundle),
            "COMPILATION_CACHE_ENABLE_CACHING=NO",
            "GCC_GENERATE_DEBUGGING_SYMBOLS=NO", "COMPILER_INDEX_STORE_ENABLE=NO",
        ]
        (evidence / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        print("Building once; compiler output is saved in build.log.", flush=True)
        try:
            with (evidence / "build.log").open("w") as log:
                result = subprocess.run([
                    "python3", "scripts/run-ci-background-build.py",
                    "--timing-path", str(evidence / "build-timing.json"), "--",
                    "python3", "scripts/run-with-timeout.py",
                    "--timeout-seconds", "1800", "--label", "compile-profile",
                    "--diagnostics-dir", str(evidence / "timeout"),
                    "--artifact-path", str(derived / "Logs/Build"), "--", *command,
                ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
        finally:
            logs = derived / "Logs/Build"
            if logs.exists():
                shutil.copytree(logs, evidence / "build-activity-logs")
        print((evidence / "build-timing.json").read_text(), flush=True)
        print("\n".join((evidence / "build.log").read_text().splitlines()[-70:]), flush=True)

    # Export while Xcode is available, so analysis does not need a Mac later.
    # Keep the native activity logs and bundle even if this export fails.
    root = json.loads(output(
        "xcrun", "xcresulttool", "get", "object", "--legacy",
        "--path", str(bundle), "--format", "json",
    ))
    (evidence / "invocation.json").write_text(json.dumps(root, indent=2) + "\n")
    references = {
        action[key]["logRef"]["id"]["_value"]
        for action in root["actions"]["_values"]
        for key in ("buildResult", "actionResult")
        if "logRef" in action.get(key, {})
    }
    if not references:
        raise RuntimeError("The build result contains no structured activity log")
    for index, reference in enumerate(sorted(references)):
        activity = output(
            "xcrun", "xcresulttool", "get", "object", "--legacy",
            "--path", str(bundle), "--id", reference, "--format", "json",
        )
        (evidence / f"activity-{index}.json").write_text(activity + "\n")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
