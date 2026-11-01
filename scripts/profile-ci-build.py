#!/usr/bin/env python3
"""Compare compilation caching without executing tests or changing the gate."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / ".ci/compile-profile"
CACHE = ROOT / ".ci/compilation-cache"
DERIVED = ROOT / ".ci/profile-derived"
APP = Path("Sources/Heeler/Console/GitBranchName.swift")
TEST = Path("Tests/HeelerTests/GitBranchNameTests.swift")
APP_MARKER = "HEELER_CACHE_APP_SOURCE_PROBE_20261101"
TEST_MARKER = "HEELER_CACHE_TEST_SOURCE_PROBE_20261101"
INPUTS = ["Sources", "Tests", "Packages", "Heeler.xcodeproj", "project.yml", "plugin/test-vectors"]


def output(*command: str) -> str:
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def verify_inputs() -> None:
    subprocess.run([
        "git", "diff", "--exit-code", os.environ["PROFILE_SOURCE_SHA"], "--", *INPUTS,
    ], cwd=ROOT, check=True)


@contextmanager
def changed_source(path: Path, old: str, new: str):
    source = ROOT / path
    original = source.read_bytes()
    text = original.decode()
    if text.count(old) != 1:
        raise RuntimeError(f"Expected exactly one probe insertion point in {path}")
    try:
        source.write_text(text.replace(old, new, 1))
        yield
    finally:
        source.write_bytes(original)


def export_activity(directory: Path, bundle: Path) -> None:
    root = json.loads(output(
        "xcrun", "xcresulttool", "get", "object", "--legacy",
        "--path", str(bundle), "--format", "json",
    ))
    write_json(directory / "invocation.json", root)
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
        (directory / f"activity-{index}.json").write_text(activity + "\n")


def check_products(derived: Path, app_changed: bool, test_changed: bool) -> dict:
    # Inspect linked Mach-O products, not source text or intermediate diagnostics.
    products = derived / "Build/Products/Debug-iphonesimulator"
    binaries = [path for path in products.rglob("*") if path.is_file() and path.name in {
        "Heeler", "Heeler.debug.dylib", "HeelerTests",
    }]
    if not any(path.name == "Heeler" for path in binaries) or not any(
        path.name == "HeelerTests" for path in binaries
    ):
        raise RuntimeError("App and test executables must both exist")
    result = {}
    for marker, expected, test_binary in (
        (APP_MARKER, app_changed, False), (TEST_MARKER, test_changed, True),
    ):
        found = [str(path.relative_to(products)) for path in binaries
                 if (path.name == "HeelerTests") == test_binary and marker.encode() in path.read_bytes()]
        if bool(found) != expected:
            raise RuntimeError(f"Compiled source probe {marker}: expected presence={expected}, found={found}")
        result[marker] = {"expected_present": expected, "found_in": found}
    return result


def build(name: str, destination: str, *, caching: bool = True, derived: Path = DERIVED,
          app_changed: bool = False, test_changed: bool = False, error_marker: str = "") -> None:
    directory = EVIDENCE / name
    directory.mkdir()
    # Always discard products and incremental state, even for the same-source run.
    if derived.exists():
        raise RuntimeError(f"DerivedData must be absent before {name}: {derived}")
    bundle = directory / "build.xcresult"
    cache_directory = CACHE if caching else ROOT / ".ci/cache-disabled-control"
    command = [
        "xcodebuild", "build-for-testing", "-project", "Heeler.xcodeproj",
        "-scheme", "Heeler", "-derivedDataPath", str(derived),
        "-destination", destination,
        "-clonedSourcePackagesDirPath", str(ROOT / ".ci/source-packages"),
        "-collect-test-diagnostics", "never", "-showBuildTimingSummary",
        "-resultBundlePath", str(bundle),
        f"COMPILATION_CACHE_ENABLE_CACHING={'YES' if caching else 'NO'}",
        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES",
        f"COMPILATION_CACHE_CAS_PATH={cache_directory}",
        "GCC_GENERATE_DEBUGGING_SYMBOLS=NO", "COMPILER_INDEX_STORE_ENABLE=NO",
    ]
    write_json(directory / "command.json", command)
    write_json(directory / "inputs.json", {
        "app_sha256": hashlib.sha256((ROOT / APP).read_bytes()).hexdigest(),
        "test_sha256": hashlib.sha256((ROOT / TEST).read_bytes()).hexdigest(),
        "patch": output("git", "diff", "--", *INPUTS),
        "fresh_derived_data": True, "derived_data": str(derived),
        "compilation_cache": caching, "expected_error": error_marker,
    })
    print(f"::group::{name}", flush=True)
    try:
        with (directory / "build.log").open("w") as log:
            result = subprocess.run([
                "python3", "scripts/run-ci-background-build.py",
                "--timing-path", str(directory / "build-timing.json"), "--",
                "python3", "scripts/run-with-timeout.py",
                "--timeout-seconds", "1800", "--label", name,
                "--diagnostics-dir", str(directory / "timeout"),
                "--artifact-path", str(derived / "Logs/Build"), "--", *command,
            ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
        text = (directory / "build.log").read_text()
        timing = json.loads((directory / "build-timing.json").read_text())
        print(json.dumps(timing), flush=True)
        print("\n".join(text.splitlines()[-35:]), flush=True)
        remarks = [line for line in text.splitlines() if re.search(
            r"cache (?:hit|miss)|hits / .*cacheable tasks|caching (?:enabled|disabled)", line, re.I)]
        (directory / "cache-remarks.log").write_text("\n".join(remarks) + "\n")
        cache_files = [path for path in cache_directory.rglob("*")
                       if path.is_file() and path.name != "profile-identity.json"]
        summary = {"name": name, **timing, "cache_files": len(cache_files),
                   "cache_bytes": sum(path.stat().st_size for path in cache_files),
                   "cache_summary": [line for line in remarks if "cacheable tasks" in line],
                   "test_execution": False}
        write_json(directory / "summary.json", summary)
        export_activity(directory, bundle)
        if error_marker:
            if result.returncode != 65 or f"error: {error_marker}" not in text:
                raise RuntimeError(f"{name} did not reject the deliberately invalid source")
            summary["invalidation_verified"] = True
        else:
            if result.returncode:
                raise RuntimeError(f"{name} build failed with status {result.returncode}")
            summary["products"] = check_products(derived, app_changed, test_changed)
        if caching and not cache_files:
            raise RuntimeError("Xcode did not populate the requested compilation cache directory")
        write_json(directory / "summary.json", summary)
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as report:
            report.write(f"- {name}: {timing['elapsed_seconds']:.1f}s; "
                         f"{'expected compiler error detected' if error_marker else 'build and product probes passed'}\n")
    finally:
        logs = derived / "Logs/Build"
        if logs.exists():
            shutil.copytree(logs, directory / "build-activity-logs")
        if derived.exists():
            shutil.rmtree(derived)
        if not caching and cache_directory.exists():
            shutil.rmtree(cache_directory)
        print("::endgroup::", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["seed", "restored"], required=True)
    args = parser.parse_args()
    verify_inputs()
    EVIDENCE.mkdir(parents=True, exist_ok=False)
    if args.phase == "seed":
        CACHE.mkdir(exist_ok=False)
    elif not CACHE.is_dir() or not any(CACHE.iterdir()):
        raise RuntimeError("The restored phase requires the exact seed cache")
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "--json"))
    device = next(device for group in devices["devices"].values() for device in group
                  if device["name"] == "iPhone 17" and device["isAvailable"])
    destination = f"platform=iOS Simulator,id={device['udid']}"
    identity = {
        "candidate_sha": output("git", "rev-parse", "HEAD"),
        "source_sha": os.environ["PROFILE_SOURCE_SHA"],
        "xcode": output("xcodebuild", "-version"),
        "swift": output("xcrun", "swiftc", "-version"),
        "sdk": output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"),
        "architecture": output("uname", "-m"),
        "runner_image": os.environ["ImageVersion"],
    }
    write_json(EVIDENCE / "environment.json", {
        **identity, "phase": args.phase, "macos": output("sw_vers"),
        "logical_cpus": int(output("sysctl", "-n", "hw.logicalcpu")),
        "memory_bytes": int(output("sysctl", "-n", "hw.memsize")),
        "destination": destination, "test_execution": False,
        "compilation_cache_path": str(CACHE), "compiler_profiling_flags": [],
    })
    if args.phase == "restored":
        if json.loads((CACHE / "profile-identity.json").read_text()) != identity:
            raise RuntimeError("Restored cache source or toolchain identity differs from the seed")
    try:
        if args.phase == "seed":
            build("01-cache-disabled", destination, caching=False)
            # Reject an accidental nonempty cache before the cold measurement.
            if any(CACHE.iterdir()):
                raise RuntimeError("The cache-disabled control unexpectedly populated the cache")
            build("02-cache-cold", destination)
            build("03-cache-warm", destination)
            write_json(CACHE / "profile-identity.json", identity)
        else:
            build("04-restored-warm", destination)
            # Ordinary CI currently uses a different temporary path per worker.
            with tempfile.TemporaryDirectory(prefix="heeler-profile.", dir="/tmp") as temporary:
                build("05-relocated-warm", destination, derived=Path(temporary) / "AppDerivedData")
            with changed_source(APP, '"Enter a branch name."', f'"{APP_MARKER}"'):
                build("06-app-edit", destination, app_changed=True)
            with changed_source(TEST, '"main", "feature/start-worktree"',
                                f'"{TEST_MARKER}", "feature/start-worktree"'):
                build("07-test-edit", destination, test_changed=True)
            for number, path, label in ((8, APP, "APP"), (9, TEST, "TEST")):
                marker = f"HEELER_CACHE_{label}_INVALIDATION_ERROR"
                first_line = (ROOT / path).read_text().splitlines()[0] + "\n"
                with changed_source(path, first_line, f'#error("{marker}")\n{first_line}'):
                    build(f"{number:02d}-{label.lower()}-invalidation", destination, error_marker=marker)
    finally:
        verify_inputs()


if __name__ == "__main__":
    main()
