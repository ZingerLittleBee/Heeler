#!/usr/bin/env python3
"""Record real xcresult execution and verify the complete iOS CI lane union."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit


SCHEMA = 1
SHARED = {
    "HeelerSSHPTYE2ETests", "HeelerSSHJumpHostGateE2ETests",
    "HeelerSSHTransportBehaviorE2ETests", "ChangesFieldHostE2ETests",
    "ImageStagingE2ETests", "PairingCeremonyE2ETests",
}
SESSION = "HeelerSSHSessionE2ETests"
DIRECT = "HeelerSSHDirectStreamLocalE2ETests"
WEAK = "WeakNetworkE2ETests"
FIXTURE_SUITES = SHARED | {SESSION, DIRECT, WEAK}
PACKAGE_SUITES = {
    "SessionDriverE2ETests", "KeyExchangeRetryTests", "DNSServiceAddressResolverTests",
    "SocketConnectorTests", "SSHDiagnosticsTests",
}
LAYOUTS = {
    "sharded": {("app", "session-weak"): {SESSION, WEAK},
                ("app", "transport"): {DIRECT, "SharedFixtureE2ETests"},
                ("app", "ordinary"): {"full-lane"}},
    "serial": {("app", "all"): {SESSION, DIRECT, "SharedFixtureE2ETests", "full-lane"}},
}
RUN_NODES = {"Arguments", "Repetition", "Test Case Run", "Device", "Test Plan Configuration"}
NODE_TYPES = RUN_NODES | {
    "Test Plan", "Unit test bundle", "UI test bundle", "Test Suite", "Test Case",
    "Failure Message", "Source Code Reference", "Attachment", "Expression",
    "Test Value", "Runtime Warning", "Skip Message", "Expected Failure",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def tested_sha() -> str:
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(bool(re.fullmatch(r"[0-9a-f]{40}", sha)), "Invalid tested Git SHA")
    expected = os.environ.get("GITHUB_SHA")
    require(not expected or expected == sha, "GITHUB_SHA does not match the tested checkout")
    return sha


def toolchain() -> dict[str, str]:
    supplied = os.environ.get("HEELER_CI_EVIDENCE_METADATA")
    if supplied:
        value = json.loads(supplied)
    else:
        value = {
            "xcode_version": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
            "sdk_version": subprocess.check_output(
                ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip(),
            "architecture": platform.machine(),
        }
    validate_toolchain(value)
    return value


def validate_toolchain(value: object) -> None:
    require(isinstance(value, dict) and set(value) == {"xcode_version", "sdk_version", "architecture"},
            "Invalid toolchain metadata fields")
    require(all(isinstance(item, str) and 0 < len(item) <= 512 for item in value.values()),
            "Empty or invalid toolchain metadata")


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".evidence-", delete=False) as handle:
        temporary = Path(handle.name)
        try:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def test_cases(report: object) -> list[dict]:
    """Keep method identity and every argument identity, rather than collapsing cases."""
    require(isinstance(report, dict) and isinstance(report.get("testNodes"), list),
            "xcresult tests report has no testNodes")
    tests: list[dict] = []
    seen: set[str] = set()

    def children(node: dict) -> list[dict]:
        value = node.get("children", [])
        require(isinstance(value, list), "Invalid xcresult children")
        for child in value:
            require(isinstance(child, dict) and child.get("nodeType") in NODE_TYPES,
                    "Unsupported xcresult node schema")
        return value

    def function_id(node: dict, bundle: str | None) -> str:
        require(isinstance(bundle, str) and bool(bundle), "Test case has no test bundle")
        identity = node.get("nodeIdentifier")
        if not isinstance(identity, str) or not identity:
            url = node.get("nodeIdentifierURL")
            require(isinstance(url, str) and bool(url), "Test case has no identity")
            parts = unquote(urlsplit(url).path).strip("/").split("/")
            require(bundle in parts, "Test case URL has no matching test bundle")
            identity = "/".join(parts[parts.index(bundle) + 1:])
        if not identity.startswith(bundle + "/"):
            identity = bundle + "/" + identity
        require(len(identity.split("/")) >= 2 and not any(part == "" for part in identity.split("/")),
                "Empty test identity component")
        return identity

    def executions(node: dict, identity: str, method_url: str | None,
                   argument: str | None = None) -> list[dict]:
        if node["nodeType"] == "Arguments":
            url = node.get("nodeIdentifierURL")
            query = ""
            if url is not None:
                require(isinstance(url, str) and bool(url), "Invalid parameterized argument URL")
                parts = urlsplit(url)
                if method_url is not None:
                    parent = urlsplit(method_url)
                    require((parts.scheme, parts.netloc, unquote(parts.path))
                            == (parent.scheme, parent.netloc, unquote(parent.path)),
                            "Parameterized argument URL differs from its parent method URL")
                else:
                    require(unquote(parts.path).endswith("/" + identity),
                            "Parameterized argument URL differs from its parent method identity")
                query = parts.query
            if query:
                # Xcode 27 identifies argument cases in the complete URL query.
                argument = identity + "?" + query
            else:
                # Older readers omit argument URLs or repeat the parent URL.
                # Ownership comes from the containing Test Case; preserve the
                # complete argument name, and reject collisions instead of
                # inventing ordinal IDs when display values are indistinguishable.
                name = node.get("name")
                require(isinstance(name, str) and bool(name),
                        "Parameterized case has no argument name identity")
                argument = identity + "?xcresult-argument-name=" + quote(name, safe="")
        runs = [child for child in children(node) if child["nodeType"] in RUN_NODES]
        if runs:
            result = []
            for child in runs:
                result.extend(executions(child, identity, method_url, argument))
            return result
        result = node.get("result")
        require(result in {"Passed", "Skipped"}, "Unsuccessful or unknown parameter/test result")
        return [{"identity": argument or identity, "result": result}]

    def visit(node: dict, bundle: str | None = None) -> None:
        require(isinstance(node, dict) and node.get("nodeType") in NODE_TYPES,
                "Unsupported xcresult node schema")
        if node["nodeType"] in {"Unit test bundle", "UI test bundle"}:
            bundle = node.get("name")
        if node["nodeType"] == "Test Case":
            identity = function_id(node, bundle)
            require(identity not in seen, f"Duplicate registered test: {identity}")
            seen.add(identity)
            outcome = node.get("result")
            require(outcome in {"Passed", "Skipped"}, f"Unsuccessful test result: {identity}")
            method_url = node.get("nodeIdentifierURL")
            require(method_url is None or isinstance(method_url, str) and bool(method_url),
                    "Invalid parent method URL")
            cases = executions(node, identity, method_url)
            require(len({case["identity"] for case in cases}) == len(cases),
                    f"Duplicate argument/test execution: {identity}")
            if outcome == "Passed":
                require(bool(cases) and all(case["result"] == "Passed" for case in cases),
                        f"Partially executed parameterized test: {identity}")
            else:
                require(all(case["result"] == "Skipped" for case in cases),
                        f"Inconsistent skipped test result: {identity}")
            tests.append({"identity": identity, "result": outcome, "cases": cases})
            return
        for child in children(node):
            visit(child, bundle)

    for node in report["testNodes"]:
        visit(node)
    require(bool(tests), "xcresult registered no tests")
    return sorted(tests, key=lambda item: item["identity"])


def summary_record(summary: object, tests: list[dict]) -> dict:
    require(isinstance(summary, dict), "Invalid xcresult summary")
    value = {"total": summary.get("totalTestCount"), "skipped": summary.get("skippedTests"),
             "failed": summary.get("failedTests"), "result": summary.get("result")}
    require(all(type(value[key]) is int and value[key] >= 0 for key in ("total", "skipped", "failed")),
            "Invalid xcresult counts")
    require(value["result"] == "Passed" and value["failed"] == 0, "xcresult did not pass")
    require(value["total"] == len(tests), "Registered method count does not match xcresult summary")
    require(value["skipped"] == sum(test["result"] == "Skipped" for test in tests),
            "Skipped method count does not match xcresult summary")
    require(value["total"] > value["skipped"], "App/package evidence executed no tests")
    return value


def record(directory: Path, phase: str, lane: str, shard: str, summary: object, report: object,
           selectors: list[str], exclusions: list[str]) -> Path:
    require(bool(re.fullmatch(r"[A-Za-z0-9_-]+", phase)), "Invalid evidence phase")
    require(lane in {"app", "package"} and shard in {"all", "session-weak", "transport", "ordinary"},
            "Invalid evidence lane or shard")
    sha = tested_sha()
    require(not list(directory.glob("worker-*.json")), "Evidence worker is already marked complete")
    # Keep the reports emitted by the native reader before interpreting them.
    # Re-reading an old bundle with another Xcode can produce a different schema.
    diagnostics = directory / "diagnostics"
    atomic_json(diagnostics / f"raw-{phase}-summary.json", summary)
    atomic_json(diagnostics / f"raw-{phase}-tests.json", report)
    metadata = toolchain()
    try:
        reader = subprocess.check_output(["xcrun", "--find", "xcresulttool"],
                                         text=True, stderr=subprocess.DEVNULL).strip() or None
    except (OSError, subprocess.CalledProcessError):
        reader = None
    atomic_json(diagnostics / f"raw-{phase}-reader.json",
                {"tested_sha": sha, "toolchain": metadata, "xcresulttool_path": reader})
    tests = test_cases(report)
    value = {"schema": SCHEMA, "kind": "phase", "tested_sha": sha, "lane": lane,
             "shard": shard, "phase": phase, "toolchain": metadata,
             "selection": {"only_testing": selectors, "skip_testing": exclusions},
             "summary": summary_record(summary, tests), "tests": tests}
    path = directory / f"phase-{phase}.json"
    atomic_json(path, value)
    return path


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text())
    require(isinstance(value, dict) and type(value.get("schema")) is int and value.get("schema") == SCHEMA,
            f"Unsupported evidence schema: {path}")
    fields = {
        "phase": {"schema", "kind", "tested_sha", "lane", "shard", "phase", "toolchain", "selection", "summary", "tests"},
        "worker": {"schema", "kind", "tested_sha", "lane", "shard", "status", "phases"},
    }
    require(isinstance(value.get("kind"), str) and value["kind"] in fields
            and set(value) == fields[value["kind"]], f"Unsupported evidence record fields: {path}")
    require(all(isinstance(value.get(key), str) and bool(value[key]) for key in ("tested_sha", "lane", "shard")),
            f"Invalid worker identity metadata: {path}")
    if value["kind"] == "phase":
        require(isinstance(value.get("phase"), str) and bool(value["phase"]), f"Invalid phase identity: {path}")
    return value


def complete(directory: Path, lane: str, shard: str, expected_sha: str | None = None) -> None:
    sha = tested_sha()
    require(expected_sha is None or expected_sha == sha, "Completion SHA differs from checkout")
    require(not list(directory.glob("worker-*.json")), "Evidence worker is already complete")
    phases = {}
    for path in sorted(directory.glob("phase-*.json")):
        value = read_json(path)
        require(value.get("kind") == "phase", "Unexpected/stale worker completion marker")
        require((value.get("lane"), value.get("shard"), value.get("tested_sha")) == (lane, shard, sha),
                "Worker contains evidence from another lane/shard/SHA")
        require(value["phase"] not in phases, "Duplicate evidence phase")
        phases[value["phase"]] = hashlib.sha256(path.read_bytes()).hexdigest()
    require(bool(phases), "Cannot complete a worker with no phase evidence")
    atomic_json(directory / f"worker-{lane}-{shard}.json",
                {"schema": SCHEMA, "kind": "worker", "tested_sha": sha, "lane": lane,
                 "shard": shard, "status": "passed", "phases": phases})


def suite(identity: str) -> str | None:
    parts = identity.split("/")
    return parts[1] if len(parts) >= 3 else None


def validated_phase(value: dict, sha: str) -> None:
    require(value.get("tested_sha") == sha, "Evidence SHA differs from the candidate")
    validate_toolchain(value.get("toolchain"))
    require(isinstance(value.get("selection"), dict), "Evidence has no selection metadata")
    require(set(value["selection"]) == {"only_testing", "skip_testing"}, "Unsupported selection schema")
    for selected in value["selection"].values():
        require(isinstance(selected, list) and all(isinstance(item, str) and bool(item) for item in selected),
                "Invalid selection metadata")
    tests = value.get("tests")
    require(isinstance(tests, list) and bool(tests), "Phase registered no tests")
    identities = set()
    for test in tests:
        require(isinstance(test, dict) and set(test) == {"identity", "result", "cases"}, "Invalid test evidence")
        identity = test["identity"]
        require(isinstance(identity, str) and bool(identity) and identity not in identities,
                "Duplicate or invalid registered test identity")
        identities.add(identity)
        require(test["result"] in {"Passed", "Skipped"}, "Unsuccessful test evidence")
        cases = test["cases"]
        require(isinstance(cases, list) and bool(cases), "Test has no case execution evidence")
        case_ids = set()
        for case in cases:
            require(isinstance(case, dict) and set(case) == {"identity", "result"}, "Invalid case evidence")
            require(isinstance(case["identity"], str)
                    and (case["identity"] == identity or case["identity"].startswith(identity + "?"))
                    and case["identity"] not in case_ids, "Duplicate or invalid argument identity")
            case_ids.add(case["identity"])
            require(case["result"] == test["result"], "Partially executed parameterized test")
    summary = value.get("summary")
    require(isinstance(summary, dict) and set(summary) == {"total", "skipped", "failed", "result"},
            "Invalid evidence summary")
    summary_record({"totalTestCount": summary["total"], "skippedTests": summary["skipped"],
                    "failedTests": summary["failed"], "result": summary["result"]}, tests)


def load_evidence(directory: Path, sha: str, layout: str, include_package: bool) -> list[dict]:
    expected = dict(LAYOUTS[layout])
    if include_package:
        expected[("package", "all")] = {"package-e2e"}
    phases: dict[tuple, tuple[dict, str]] = {}
    workers = {}
    paths = sorted([*directory.rglob("phase-*.json"), *directory.rglob("worker-*.json")])
    for path in paths:
        value = read_json(path)
        require(value.get("tested_sha") == sha, f"Wrong evidence SHA: {path}")
        worker = (value.get("lane"), value.get("shard"))
        require(worker in expected, f"Unexpected evidence worker: {worker}")
        if value.get("kind") == "phase":
            key = (*worker, value.get("phase"))
            require(key not in phases, f"Duplicate phase evidence: {key}")
            validated_phase(value, sha)
            phases[key] = (value, hashlib.sha256(path.read_bytes()).hexdigest())
        elif value.get("kind") == "worker":
            require(worker not in workers and value.get("status") == "passed", "Duplicate/failed worker marker")
            workers[worker] = value
        else:
            raise ValueError(f"Unsupported evidence kind: {path}")
    missing = sorted("-".join(worker) for worker in set(expected) - set(workers))
    require(not missing, f"Missing worker completion evidence: {', '.join(missing)}. A worker records it only "
            "after its tests pass; if it passed in an earlier attempt whose artifact expired, rerun all jobs")
    for worker, names in expected.items():
        actual = {key[2] for key in phases if key[:2] == worker}
        require(actual == names, f"Missing or unexpected phases for {worker}: {actual}")
        hashes = {name: phases[(*worker, name)][1] for name in names}
        require(workers[worker].get("phases") == hashes, "Worker marker does not bind its complete phase evidence")
    records = [item[0] for item in phases.values()]
    require(len({json.dumps(item["toolchain"], sort_keys=True) for item in records}) == 1,
            "Workers used different Xcode/SDK/architecture")
    return records


def verify_records(records: list[dict], layout: str) -> tuple[set[str], set[str]]:
    functions: set[str] = set()
    cases: set[str] = set()
    fixtures: dict[str, dict] = {}
    full = None
    for value in records:
        tests = value["tests"]
        phase = value["phase"]
        memberships = {suite(test["identity"]) for test in tests}
        if value["lane"] == "package":
            require(len(tests) == 71 and memberships - {None} == PACKAGE_SUITES, "Package suite/count contract changed")
            require(value["summary"]["skipped"] == 0, "Package mandatory tests skipped")
            expected_prefix = "HeelerSSHTests/"
        else:
            expected_prefix = "HeelerTests/"
            if phase == "full-lane":
                require(full is None, "Duplicate full ordinary lane")
                full = value
                require(not any(value["selection"].values()), "Ordinary lane must select the entire target")
                require(value["summary"]["total"] - value["summary"]["skipped"] >= 769,
                        "Full ordinary lane executed fewer than 769 tests")
            else:
                count, suites = {
                    SESSION: (13, {SESSION}), DIRECT: (9, {DIRECT}), WEAK: (10, {WEAK}),
                    "SharedFixtureE2ETests": (116, SHARED | {WEAK}) if layout == "serial" else (106, SHARED),
                }[phase]
                require(len(tests) == count and memberships == suites, f"Fixture suite/count contract changed: {phase}")
                require(value["summary"]["skipped"] == 0, f"Mandatory fixture tests skipped: {phase}")
                require(not value["selection"]["skip_testing"], "Fixture lane excluded tests")
                expected_selectors = {f"HeelerTests/{name}" for name in suites}
                require(set(value["selection"]["only_testing"]) == expected_selectors,
                        f"Fixture lane selection differs from its complete suites: {phase}")
                for test in tests:
                    require(test["identity"] not in fixtures, "Duplicate fixture method across phases")
                    fixtures[test["identity"]] = test
        for test in tests:
            require(test["identity"].startswith(expected_prefix), "Unexpected target in test evidence")
            if test["result"] == "Passed":
                require(test["identity"] not in functions, "Duplicate passing method across lanes")
                functions.add(test["identity"])
                for case in test["cases"]:
                    require(case["identity"] not in cases, "Duplicate passing parameter case across lanes")
                    cases.add(case["identity"])
    require(full is not None, "No full ordinary lane")
    skipped = {test["identity"]: test for test in full["tests"] if test["result"] == "Skipped"}
    require(set(skipped) == set(fixtures), "Full-lane skipped methods differ from fixture passing provenance")
    for identity, test in skipped.items():
        require(suite(identity) in FIXTURE_SUITES, "Nonfixture ordinary method skipped")
        passed_ids = {case["identity"] for case in fixtures[identity]["cases"]}
        # A disabled parameterized function may have no expanded argument nodes;
        # its whole owning fixture suite must have passed. Expanded skipped cases
        # must still map exactly to those passed argument identities.
        skipped_ids = {case["identity"] for case in test["cases"]}
        require(skipped_ids == {identity} or skipped_ids == passed_ids,
                "Skipped parameter cases differ from fixture passing provenance")
    return functions, cases


def verify(directory: Path, sha: str, layout: str, baseline: Path | None, include_package: bool) -> dict:
    require(bool(re.fullmatch(r"[0-9a-f]{40}", sha)), "Invalid candidate SHA")
    records = load_evidence(directory, sha, layout, include_package)
    functions, cases = verify_records(records, layout)
    if baseline is not None:
        previous = load_evidence(baseline, sha, "serial", include_package)
        require(records[0]["toolchain"] == previous[0]["toolchain"], "Baseline toolchain differs from candidate")
        previous_functions, previous_cases = verify_records(previous, "serial")
        require(functions == previous_functions, "Candidate/baseline method union differs")
        require(cases == previous_cases, "Candidate/baseline parameterized-case union differs")
    return {"tested_sha": sha, "passed_methods": len(functions), "passed_cases": len(cases),
            "baseline_compared": baseline is not None}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("record", help="Record a real Mac xcresult after successful native tests")
    export.add_argument("--bundle", type=Path, required=True)
    export.add_argument("--phase", required=True)
    export.add_argument("--lane", choices=["app", "package"], required=True)
    export.add_argument("--shard", choices=["all", "session-weak", "transport", "ordinary"], default="all")
    export.add_argument("--evidence-dir", type=Path, required=True)
    export.add_argument("--only-testing", action="append", default=[])
    export.add_argument("--skip-testing", action="append", default=[])
    finish = commands.add_parser("complete", help="Mark a worker complete after shell guards and cleanup pass")
    finish.add_argument("--evidence-dir", type=Path, required=True)
    finish.add_argument("--lane", choices=["app", "package"], required=True)
    finish.add_argument("--shard", choices=["all", "session-weak", "transport", "ordinary"], default="all")
    finish.add_argument("--sha")
    check = commands.add_parser("verify", help="Verify downloaded serial or sharded worker evidence")
    check.add_argument("--evidence-dir", type=Path, required=True)
    check.add_argument("--sha", required=True)
    check.add_argument("--layout", choices=list(LAYOUTS), default="sharded")
    check.add_argument("--baseline", type=Path)
    check.add_argument("--require-package", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "record":
            reports = [json.loads(subprocess.check_output([
                "xcrun", "xcresulttool", "get", "test-results", report, "--path", str(args.bundle), "--compact",
            ])) for report in ("summary", "tests")]
            record(args.evidence_dir, args.phase, args.lane, args.shard, *reports,
                   args.only_testing, args.skip_testing)
        elif args.command == "complete":
            complete(args.evidence_dir, args.lane, args.shard, args.sha)
        else:
            print(json.dumps(verify(args.evidence_dir, args.sha, args.layout, args.baseline, args.require_package),
                             sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"iOS CI evidence validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
