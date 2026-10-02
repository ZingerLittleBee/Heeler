#!/usr/bin/env python3
"""Run xcodebuild with the simulator accessibility tree enabled (refs #339).

Both make test-app and the CI app lane use this entrypoint. These simulator
preferences are test infrastructure, not app APIs; recheck them on SDK upgrades.
Only the two owned keys are restored, including their original absence/type.
Testing actions accept exported TEST_FLAGS/TEST_SELECTOR and verify execution
and selector identities from xcresulttool's test-results summary/tests reports.
"""

from __future__ import annotations

import json
import importlib.util
import os
import plistlib
import shlex
import signal
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlsplit


DOMAIN = "com.apple.Accessibility"
PREFERENCES = {"AccessibilityEnabled": True, "ApplicationAccessibilityEnabled": 1}
EXECUTED_RESULTS = {"Passed", "Failed", "Expected Failure"}
TEST_ACTIONS = {"test", "test-without-building"}


@dataclass(frozen=True)
class TestRunSummary:
    total: int
    skipped: int
    failed: int
    result: str

    @property
    def executed(self) -> int:
        return self.total - self.skipped

    @classmethod
    def parse(cls, value: object) -> TestRunSummary:
        if not isinstance(value, dict):
            raise ValueError("xcresult summary is not an object")
        counts = []
        for key in ("totalTestCount", "skippedTests", "failedTests"):
            count = value.get(key)
            if type(count) is not int or count < 0:
                raise ValueError(f"xcresult summary has an invalid {key}")
            counts.append(count)
        total, skipped, failed = counts
        if skipped + failed > total or not isinstance(value.get("result"), str):
            raise ValueError("xcresult summary has inconsistent test counts or result")
        return cls(total, skipped, failed, value["result"])


def option_value(arguments: list[str], option: str) -> str | None:
    if arguments.count(option) > 1:
        raise ValueError(f"App tests require at most one {option}")
    if option not in arguments:
        return None
    index = arguments.index(option) + 1
    if index == len(arguments) or arguments[index].startswith("-"):
        raise ValueError(f"{option} requires a value")
    return arguments[index]


def requested_selectors(arguments: list[str]) -> list[str]:
    selectors = []
    for index, argument in enumerate(arguments):
        if argument.startswith("-only-testing:"):
            value = argument.removeprefix("-only-testing:")
        elif argument == "-only-testing":
            if index + 1 == len(arguments) or arguments[index + 1].startswith("-"):
                raise ValueError("-only-testing requires a selector or @response-file")
            value = arguments[index + 1]
        else:
            continue
        if value.startswith("@"):
            # Xcode's response files are newline-delimited identifiers, with
            # blank lines ignored. Read them without shell expansion or edits.
            selectors.extend(line.strip() for line in Path(value[1:]).read_text().splitlines() if line.strip())
        else:
            selectors.append(value)
    if any(not selector or selector != selector.strip() for selector in selectors):
        raise ValueError("An only-testing selector must be nonempty with no outer whitespace")
    return selectors


def prepare_test_arguments(arguments: list[str]) -> tuple[Path | None, list[str]]:
    if not TEST_ACTIONS.intersection(arguments):
        return None, []
    # Make exports these values. Tokenize flags once, without another shell or
    # shell expansions; a method's parentheses remain ordinary argv characters.
    arguments.extend(shlex.split(os.environ.get("TEST_FLAGS", "")))
    selector = os.environ.get("TEST_SELECTOR", "")
    if selector:
        arguments.append(f"-only-testing:{selector}")
    selectors = requested_selectors(arguments)

    supplied = option_value(arguments, "-resultBundlePath")
    if supplied is not None:
        return Path(supplied), selectors
    derived = option_value(arguments, "-derivedDataPath")
    directory = Path(derived) / "Logs" / "Test" if derived else Path(tempfile.gettempdir())
    directory.mkdir(parents=True, exist_ok=True)
    bundle = directory / f"Heeler-{uuid.uuid4().hex}.xcresult"
    arguments.extend(["-resultBundlePath", str(bundle)])
    return bundle, selectors


def xcresult_report(bundle: Path, report: str) -> object:
    return json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", "test-results", report,
        "--path", str(bundle), "--compact",
    ]))


def executed_test_identifiers(report: object) -> set[str]:
    if not isinstance(report, dict) or not isinstance(report.get("testNodes"), list):
        raise ValueError("xcresult tests report has no testNodes")
    identifiers: set[str] = set()
    run_types = {"Arguments", "Repetition", "Test Case Run", "Device", "Test Plan Configuration"}

    def has_execution(node: dict) -> bool:
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("xcresult tests report contains invalid children")
        runs = [child for child in children
                if isinstance(child, dict) and isinstance(child.get("nodeType"), str)
                and child["nodeType"] in run_types]
        if runs:
            return any(has_execution(child) for child in runs)
        result = node.get("result")
        return isinstance(result, str) and result in EXECUTED_RESULTS

    def visit(node: object, bundle_name: str | None) -> None:
        if not isinstance(node, dict) or not isinstance(node.get("nodeType"), str):
            raise ValueError("xcresult tests report contains an invalid node")
        if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}:
            bundle_name = node.get("name")
        if node.get("nodeType") == "Test Case" and has_execution(node):
            identifier = node.get("nodeIdentifier")
            if isinstance(bundle_name, str) and isinstance(identifier, str):
                if not identifier.startswith(bundle_name + "/"):
                    identifier = bundle_name + "/" + identifier
                identifiers.add(identifier)
            elif isinstance(bundle_name, str) and isinstance(node.get("nodeIdentifierURL"), str):
                # URL queries describe parameter values, not the selected method.
                parts = unquote(urlsplit(node["nodeIdentifierURL"]).path).strip("/").split("/")
                if bundle_name in parts:
                    identifiers.add("/".join(parts[parts.index(bundle_name):]))
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("xcresult tests report contains invalid children")
        for child in children:
            visit(child, bundle_name)

    for node in report["testNodes"]:
        visit(node, None)
    return identifiers


def selector_matches(selector: str, identifier: str) -> bool:
    # Suite/target selectors match descendants; XCTest may omit empty method
    # parentheses while Swift Testing reports them. Parameter labels stay exact.
    return (identifier == selector or identifier.startswith(selector + "/")
            or identifier.removesuffix("()") == selector.removesuffix("()"))


def verify_test_result(bundle: Path, selectors: list[str], arguments: list[str] | None = None) -> None:
    summary_report = xcresult_report(bundle, "summary")
    summary = TestRunSummary.parse(summary_report)
    if summary.executed <= 0:
        raise ValueError(f"App test run executed no tests ({summary.total} registered, {summary.skipped} skipped)")
    if summary.failed or summary.result not in {"Passed", "Expected Failure"}:
        raise ValueError(f"App test result reports {summary.result} with {summary.failed} failed tests")
    tests_report = xcresult_report(bundle, "tests")
    identifiers = executed_test_identifiers(tests_report)
    if not identifiers:
        raise ValueError("App test result contains no executed test identifiers")
    for selector in selectors:
        if not any(selector_matches(selector, identifier) for identifier in identifiers):
            raise ValueError(f"Requested selector executed no matching tests: {selector}")
    print(f"==> App tests executed {summary.executed} of {summary.total} tests "
          f"({summary.skipped} skipped); {len(selectors)} selectors verified", flush=True)
    evidence_directory = os.environ.get("HEELER_CI_EVIDENCE_DIR")
    if evidence_directory:
        # Export only after the existing result and selector checks succeed.
        # The shell/workflow marks completion after its own guards and cleanup.
        evidence_path = Path(__file__).with_name("verify-ci-ios-evidence.py")
        spec = importlib.util.spec_from_file_location("heeler_ci_evidence", evidence_path)
        if spec is None or spec.loader is None:
            raise ValueError("Cannot load the CI evidence recorder")
        evidence = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(evidence)
        flags = arguments or []
        exclusions = []
        for index, flag in enumerate(flags):
            if flag.startswith("-skip-testing:"):
                exclusions.append(flag.removeprefix("-skip-testing:"))
            elif flag == "-skip-testing":
                if index + 1 == len(flags) or flags[index + 1].startswith("-"):
                    raise ValueError("-skip-testing requires a selector")
                exclusions.append(flags[index + 1])
        evidence.record(Path(evidence_directory), os.environ.get("HEELER_CI_TEST_PHASE", ""),
                        "app", os.environ.get("HEELER_CI_APP_SHARD", "all"),
                        summary_report, tests_report, selectors, exclusions)


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
    result_bundle, selectors = prepare_test_arguments(arguments)
    udid = pin_destination(arguments)
    if udid is None:
        status = subprocess.call(["xcodebuild", *arguments])
        status = 128 - status if status < 0 else status
        if status == 0 and result_bundle is not None:
            verify_test_result(result_bundle, selectors, arguments)
        return status

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
    if result_bundle is not None:
        print(f"==> App test result bundle: {result_bundle}", flush=True)
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
    if status == 0 and result_bundle is not None:
        verify_test_result(result_bundle, selectors, arguments)
    return status


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"App simulator test validation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
