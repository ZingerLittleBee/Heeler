#!/usr/bin/env python3
"""Exercise complete CI evidence with real file/CLI boundaries and hostile results."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("verify-ci-ios-evidence.py")
spec = importlib.util.spec_from_file_location("ci_evidence", SCRIPT)
assert spec and spec.loader
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
SHA = "a" * 40
METADATA = {"xcode_version": "Xcode 26.6\nBuild version 17F113", "sdk_version": "26.5", "architecture": "arm64"}


def xcode26_parameter_report() -> dict:
    """Keep the Xcode 27 reader's view of native Xcode 26.6 run 37056503090."""
    identity = "DNSServiceAddressResolverTests/numericAddressesPreserveFamilyAndPort(_:)"
    url = "test://com.apple.xcode/HeelerSSH/HeelerSSHTests/" + identity
    return {"testNodes": [{"name": "HeelerSSH", "nodeType": "Test Plan", "result": "Passed", "children": [
        {"name": "HeelerSSHTests", "nodeType": "Unit test bundle", "result": "Passed", "children": [
            {"name": "DNS resolution lifecycle", "nodeType": "Test Suite", "result": "Passed", "children": [
                {"name": "numericAddressesPreserveFamilyAndPort(_:)", "nodeType": "Test Case",
                 "nodeIdentifier": identity, "nodeIdentifierURL": url, "result": "Passed",
                 "duration": "0.00015s", "durationInSeconds": 0.00015342235565185547,
                 "children": [
                     {"name": '"::1"', "nodeType": "Arguments", "nodeIdentifierURL": url, "result": "Passed",
                      "duration": "0.00021s", "durationInSeconds": 0.0002129077911376953},
                     {"name": '"127.0.0.1"', "nodeType": "Arguments", "nodeIdentifierURL": url, "result": "Passed",
                      "duration": "0.000094s", "durationInSeconds": 9.393692016601562e-05}]}]}]}]}]}


def xcode26_data_collision_report() -> dict:
    """Keep the native Xcode 26.6 collision from run 37059893453's raw report."""
    identity = "AttachUserMessageIndexTests/controlSequencesDoNotLandInTheIndexedText(_:)"
    url = "test://com.apple.xcode/Heeler/HeelerTests/" + identity
    return {"testNodes": [{"nodeType": "Unit test bundle", "name": "HeelerTests", "children": [
        {"name": "controlSequencesDoNotLandInTheIndexedText(_:)", "nodeType": "Test Case",
         "nodeIdentifier": identity, "nodeIdentifierURL": url, "result": "Passed", "children": [
             {"name": "3 bytes", "nodeType": "Arguments", "result": "Passed", "children": [
                 {"name": "Repetition 1", "nodeIdentifier": "0", "nodeType": "Repetition", "result": "Passed"},
                 {"name": "Repetition 2", "nodeIdentifier": "0", "nodeType": "Repetition", "result": "Passed"}]},
             {"name": "6 bytes", "nodeType": "Arguments", "result": "Passed"}]}]}]}


def byte_array_parameter_report() -> dict:
    """Model complete array display values; native byte-array rendering is checked by CI."""
    report = xcode26_data_collision_report()
    report["testNodes"][0]["children"][0]["children"] = [
        {"name": name, "nodeType": "Arguments", "result": "Passed"}
        for name in ("[27, 91, 68]", "[27, 91, 49, 59, 50, 67]", "[27, 79, 65]")]
    return report


def method(suite: str, number: int, result: str = "Passed", target: str = "HeelerTests") -> dict:
    identity = f"{target}/{suite}/test{number}()"
    return {"identity": identity, "result": result, "cases": [{"identity": identity, "result": result}]}


def phase(name: str, shard: str, tests: list[dict], suites: set[str], lane: str = "app") -> dict:
    return {"schema": 1, "kind": "phase", "tested_sha": SHA, "lane": lane, "shard": shard,
            "phase": name, "toolchain": METADATA,
            "selection": {"only_testing": sorted("HeelerTests/" + suite for suite in suites), "skip_testing": []},
            "summary": {"total": len(tests), "skipped": sum(test["result"] == "Skipped" for test in tests),
                        "failed": 0, "result": "Passed"}, "tests": tests}


def records(layout: str = "sharded", package: bool = False) -> list[dict]:
    session = [method(evidence.SESSION, index) for index in range(13)]
    direct = [method(evidence.DIRECT, index) for index in range(9)]
    weak = [method(evidence.WEAK, index) for index in range(10)]
    shared = [method(suite, 0) for suite in sorted(evidence.SHARED)]
    shared += [method("HeelerSSHTransportBehaviorE2ETests", index) for index in range(1, 101)]
    skipped = copy.deepcopy(session + direct + shared + weak)
    for test in skipped:
        test["result"] = "Skipped"
        test["cases"][0]["result"] = "Skipped"
    ordinary = [method("Logic", index) for index in range(769)]
    ordinary[0]["cases"] = [{"identity": ordinary[0]["identity"] + "?args=" + arg, "result": "Passed"}
                             for arg in ("first", "second")]
    if layout == "serial":
        result = [phase(evidence.SESSION, "all", session, {evidence.SESSION}),
                  phase(evidence.DIRECT, "all", direct, {evidence.DIRECT}),
                  phase("SharedFixtureE2ETests", "all", shared + weak, evidence.SHARED | {evidence.WEAK}),
                  phase("full-lane", "all", ordinary + skipped, set())]
    else:
        result = [phase(evidence.SESSION, "session-weak", session, {evidence.SESSION}),
                  phase(evidence.WEAK, "session-weak", weak, {evidence.WEAK}),
                  phase(evidence.DIRECT, "transport", direct, {evidence.DIRECT}),
                  phase("SharedFixtureE2ETests", "transport", shared, evidence.SHARED),
                  phase("full-lane", "ordinary", ordinary + skipped, set())]
    if package:
        tests = [method(suite, 0, target="HeelerSSHTests") for suite in sorted(evidence.PACKAGE_SUITES)]
        tests += [method("SessionDriverE2ETests", index, target="HeelerSSHTests") for index in range(1, 67)]
        result.append(phase("package-e2e", "all", tests, set(), "package"))
    return result


def write_records(directory: Path, values: list[dict]) -> None:
    workers: dict[tuple[str, str], dict] = {}
    for value in values:
        worker = (value["lane"], value["shard"])
        destination = directory / "-".join(worker)
        path = destination / f"phase-{value['phase']}.json"
        evidence.atomic_json(path, value)
        workers.setdefault(worker, {})[value["phase"]] = hashlib.sha256(path.read_bytes()).hexdigest()
    for (lane, shard), phases in workers.items():
        evidence.atomic_json(directory / f"{lane}-{shard}" / f"worker-{lane}-{shard}.json",
                             {"schema": 1, "kind": "worker", "tested_sha": SHA,
                              "lane": lane, "shard": shard, "status": "passed", "phases": phases})


class AggregateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="heeler-ci-evidence-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.candidate = self.root / "candidate"
        self.baseline = self.root / "baseline"
        self.values = records()

    def check(self, baseline: bool = False, package: bool = False) -> dict:
        write_records(self.candidate, self.values)
        return evidence.verify(self.candidate, SHA, "sharded", self.baseline if baseline else None, package)

    def test_complete_sharded_union_matches_serial_including_parameter_cases(self):
        write_records(self.baseline, records("serial"))
        result = self.check(baseline=True)
        self.assertEqual(result["passed_methods"], 907)
        self.assertEqual(result["passed_cases"], 908)
        self.assertTrue(result["baseline_compared"])

    def test_one_missing_parameter_case_fails_despite_identical_method_and_summary_counts(self):
        write_records(self.baseline, records("serial"))
        self.values[-1]["tests"][0]["cases"].pop()
        with self.assertRaisesRegex(ValueError, "parameterized-case union differs"):
            self.check(baseline=True)

    def test_xcode26_package_argument_union_detects_a_missing_case(self):
        self.values = records(package=True)
        previous = records("serial", package=True)
        parameterized = evidence.test_cases(xcode26_parameter_report())[0]
        self.values[-1]["tests"][0] = copy.deepcopy(parameterized)
        previous[-1]["tests"][0] = copy.deepcopy(parameterized)
        write_records(self.baseline, previous)
        self.assertEqual(self.check(baseline=True, package=True)["passed_cases"], 980)
        self.values[-1]["tests"][0]["cases"].pop()
        with self.assertRaisesRegex(ValueError, "parameterized-case union differs"):
            self.check(baseline=True, package=True)

    def test_byte_array_argument_union_detects_a_missing_case(self):
        previous = records("serial")
        parameterized = evidence.test_cases(byte_array_parameter_report())[0]
        self.values[-1]["tests"][0] = copy.deepcopy(parameterized)
        previous[-1]["tests"][0] = copy.deepcopy(parameterized)
        write_records(self.baseline, previous)
        self.assertEqual(self.check(baseline=True)["passed_cases"], 909)
        self.values[-1]["tests"][0]["cases"].pop()
        with self.assertRaisesRegex(ValueError, "parameterized-case union differs"):
            self.check(baseline=True)

    def test_skipped_argument_is_rejected_even_when_its_method_and_summary_pass(self):
        self.values[-1]["tests"][0]["cases"][1]["result"] = "Skipped"
        with self.assertRaisesRegex(ValueError, "Partially executed parameterized test"):
            self.check()

    def test_skip_provenance_requires_the_exact_method_not_just_an_allowed_suite(self):
        skipped = self.values[-1]["tests"][769]
        skipped["identity"] += "missing"
        skipped["cases"][0]["identity"] = skipped["identity"]
        with self.assertRaisesRegex(ValueError, "skipped methods differ"):
            self.check()

    def test_wrong_fixture_membership_cannot_be_hidden_by_the_same_total(self):
        self.values[0]["tests"][0] = method("Other", 0)
        with self.assertRaisesRegex(ValueError, "suite/count contract changed"):
            self.check()

    def test_full_ordinary_lane_may_not_filter_the_target(self):
        for key in ("only_testing", "skip_testing"):
            with self.subTest(key=key):
                self.values[-1]["selection"][key] = ["HeelerTests/Logic"]
                with self.assertRaisesRegex(ValueError, "entire target"):
                    self.check()
                self.values[-1]["selection"][key] = []

    def test_missing_phase_and_missing_worker_markers_fail(self):
        self.values.pop(1)
        with self.assertRaisesRegex(ValueError, "Missing or unexpected phases"):
            self.check()
        self.values = records()
        write_records(self.candidate, self.values)
        (self.candidate / "app-ordinary/worker-app-ordinary.json").unlink()
        with self.assertRaisesRegex(ValueError, "Missing worker completion evidence: app-ordinary\\. .*rerun all jobs"):
            evidence.verify(self.candidate, SHA, "sharded", None, False)

    def test_wrong_sha_and_unknown_schema_fail(self):
        for key, value, message in (("tested_sha", "b" * 40, "Wrong evidence SHA"),
                                    ("schema", 2, "Unsupported evidence schema"),
                                    ("schema", True, "Unsupported evidence schema")):
            with self.subTest(key=key, value=value):
                self.values = records()
                self.values[0][key] = value
                with self.assertRaisesRegex(ValueError, message):
                    self.check()

    def test_duplicate_functions_or_argument_cases_fail(self):
        for level in ("functions", "cases"):
            with self.subTest(level=level):
                self.values = records()
                if level == "functions":
                    self.values[0]["tests"][1] = copy.deepcopy(self.values[0]["tests"][0])
                else:
                    cases = self.values[-1]["tests"][0]["cases"]
                    cases.append(copy.deepcopy(cases[0]))
                with self.assertRaisesRegex(ValueError, "Duplicate"):
                    self.check()

    def test_all_skipped_and_nonzero_failure_cannot_be_completed(self):
        for scenario in ("all-skipped", "failed"):
            with self.subTest(scenario=scenario):
                self.values = records()
                value = self.values[0]
                if scenario == "failed":
                    value["summary"].update(failed=1, result="Failed")
                else:
                    value["summary"]["skipped"] = len(value["tests"])
                    for test in value["tests"]:
                        test["result"] = test["cases"][0]["result"] = "Skipped"
                with self.assertRaises(ValueError):
                    self.check()

    def test_completion_hash_binds_phase_and_ignores_non_evidence_timing_json(self):
        write_records(self.candidate, self.values)
        (self.candidate / "timing.json").write_text('{"elapsed":12}')
        evidence.verify(self.candidate, SHA, "sharded", None, False)
        path = self.candidate / "app-ordinary/phase-full-lane.json"
        path.write_text(path.read_text() + "\n")
        with self.assertRaisesRegex(ValueError, "does not bind"):
            evidence.verify(self.candidate, SHA, "sharded", None, False)

    def test_new_ordinary_methods_are_included_automatically_without_a_fixed_total(self):
        self.values[-1]["tests"].append(method("NewSuite", 0))
        self.values[-1]["summary"]["total"] += 1
        self.assertEqual(self.check()["passed_methods"], 908)

    def test_package_is_required_when_requested_and_retains_its_contract(self):
        with self.assertRaisesRegex(ValueError, "Missing worker"):
            self.check(package=True)
        self.values = records(package=True)
        self.assertEqual(self.check(package=True)["passed_methods"], 978)

    def test_package_cannot_drop_back_to_the_old_seventy_method_count(self):
        self.values = records(package=True)
        self.values[-1]["tests"].pop()
        self.values[-1]["summary"]["total"] -= 1
        with self.assertRaisesRegex(ValueError, "Package suite/count contract changed"):
            self.check(package=True)

    def test_cli_rejects_missing_evidence_with_nonzero_exit(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "verify", "--evidence-dir", str(self.candidate),
                                 "--sha", SHA], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing worker", result.stderr)


class ResultTreeTests(unittest.TestCase):
    def report(self, result: str = "Passed") -> dict:
        identity = "Suite/check(value:)"
        url = "test://com.apple.xcode/Heeler/HeelerTests/" + identity
        return {"testNodes": [{"nodeType": "Unit test bundle", "name": "HeelerTests", "children": [
            {"nodeType": "Test Case", "nodeIdentifier": identity, "nodeIdentifierURL": url,
             "result": "Passed", "children": [
                 {"nodeType": "Arguments", "nodeIdentifierURL": url + "?args=first", "result": "Passed"},
                 {"nodeType": "Arguments", "nodeIdentifierURL": url + "?args=second", "result": result}]}]}]}

    def test_argument_query_identity_is_preserved(self):
        tests = evidence.test_cases(self.report())
        self.assertEqual([case["identity"] for case in tests[0]["cases"]],
                         ["HeelerTests/Suite/check(value:)?args=first", "HeelerTests/Suite/check(value:)?args=second"])

    def test_xcode26_argument_names_are_lossless_and_independent_of_timing(self):
        report = xcode26_parameter_report()
        tests = evidence.test_cases(report)
        identity = "HeelerSSHTests/DNSServiceAddressResolverTests/numericAddressesPreserveFamilyAndPort(_:)"
        self.assertEqual([case["identity"] for case in tests[0]["cases"]],
                         [identity + "?xcresult-argument-name=%22%3A%3A1%22",
                          identity + "?xcresult-argument-name=%22127.0.0.1%22"])
        node = report["testNodes"][0]["children"][0]["children"][0]["children"][0]
        for child in node["children"]:
            child.update(duration="12s", durationInSeconds=12.0)
        self.assertEqual(tests, evidence.test_cases(report))

    def test_native_xcode26_grouped_data_repetitions_remain_ambiguous(self):
        with self.assertRaisesRegex(ValueError, "Duplicate argument/test execution"):
            evidence.test_cases(xcode26_data_collision_report())

    def test_three_byte_arrays_keep_their_complete_distinct_case_identity(self):
        test = evidence.test_cases(byte_array_parameter_report())[0]
        prefix = "HeelerTests/AttachUserMessageIndexTests/controlSequencesDoNotLandInTheIndexedText(_:)"
        self.assertEqual([case["identity"] for case in test["cases"]], [
            prefix + "?xcresult-argument-name=%5B27%2C%2091%2C%2068%5D",
            prefix + "?xcresult-argument-name=%5B27%2C%2091%2C%2049%2C%2059%2C%2050%2C%2067%5D",
            prefix + "?xcresult-argument-name=%5B27%2C%2079%2C%2065%5D"])

    def test_argument_names_bind_structurally_when_argument_urls_are_absent(self):
        report = xcode26_parameter_report()
        expected = evidence.test_cases(report)
        node = report["testNodes"][0]["children"][0]["children"][0]["children"][0]
        for child in node["children"]:
            child.pop("nodeIdentifierURL")
        self.assertEqual(expected, evidence.test_cases(report))
        node.pop("nodeIdentifierURL")
        self.assertEqual(expected, evidence.test_cases(report))
        node["children"][0].pop("name")
        with self.assertRaisesRegex(ValueError, "no argument name identity"):
            evidence.test_cases(report)

    def test_argument_urls_bind_to_the_actual_parent_url_not_its_display_identity(self):
        report = xcode26_parameter_report()
        node = report["testNodes"][0]["children"][0]["children"][0]["children"][0]
        node["nodeIdentifier"] = "DNSServiceAddressResolverTests/displayAlias(_:)"
        parsed = evidence.test_cases(report)
        self.assertTrue(parsed[0]["cases"][0]["identity"].startswith(
            "HeelerSSHTests/DNSServiceAddressResolverTests/displayAlias(_:)?"))
        node["children"][0]["nodeIdentifierURL"] += "different"
        with self.assertRaisesRegex(ValueError, "differs from its parent method URL"):
            evidence.test_cases(report)

    def test_xcode26_argument_skips_missing_names_and_duplicate_names_fail(self):
        for scenario in ("skip", "missing-name", "empty-name", "duplicate-name", "wrong-method"):
            with self.subTest(scenario=scenario):
                report = xcode26_parameter_report()
                cases = report["testNodes"][0]["children"][0]["children"][0]["children"][0]["children"]
                if scenario == "skip": cases[0]["result"] = "Skipped"
                if scenario == "missing-name": cases[0].pop("name")
                if scenario == "empty-name": cases[0]["name"] = ""
                if scenario == "duplicate-name": cases[1]["name"] = cases[0]["name"]
                if scenario == "wrong-method": cases[0]["nodeIdentifierURL"] += "different"
                with self.assertRaises(ValueError): evidence.test_cases(report)

    def test_partial_arguments_unknown_nodes_and_missing_argument_identity_fail(self):
        for kind in ("Skipped", "Failed", "unknown-node", "missing-url", "duplicate"):
            with self.subTest(kind=kind):
                report = self.report(kind if kind in {"Skipped", "Failed"} else "Passed")
                cases = report["testNodes"][0]["children"][0]["children"]
                if kind == "unknown-node": cases[0]["nodeType"] = "Future Node"
                if kind == "missing-url": cases[0].pop("nodeIdentifierURL")
                if kind == "duplicate": cases[1] = copy.deepcopy(cases[0])
                with self.assertRaises(ValueError): evidence.test_cases(report)

    def test_worker_completion_happens_separately_and_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(evidence, "tested_sha", return_value=SHA), patch.object(evidence, "toolchain", return_value=METADATA):
                path = evidence.record(directory, "full-lane", "app", "ordinary",
                                       {"totalTestCount": 1, "skippedTests": 0, "failedTests": 0, "result": "Passed"},
                                       self.report(), [], [])
                self.assertEqual(path.name, "phase-full-lane.json")
                self.assertFalse(list(directory.glob("worker-*.json")))
                evidence.complete(directory, "app", "ordinary", SHA)
                with self.assertRaisesRegex(ValueError, "already complete"):
                    evidence.complete(directory, "app", "ordinary", SHA)

    def test_invalid_parameter_report_is_preserved_without_success_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = self.report("Skipped")
            summary = {"totalTestCount": 1, "skippedTests": 0, "failedTests": 0, "result": "Passed"}
            with patch.object(evidence, "tested_sha", return_value=SHA), \
                    patch.object(evidence, "toolchain", return_value=METADATA), \
                    patch.object(subprocess, "check_output", return_value="/Fake/xcresulttool\n"):
                with self.assertRaisesRegex(ValueError, "Partially executed parameterized test"):
                    evidence.record(directory, "full-lane", "app", "ordinary", summary, report, [], [])
            self.assertEqual(json.loads((directory / "diagnostics/raw-full-lane-tests.json").read_text()), report)
            self.assertEqual(json.loads((directory / "diagnostics/raw-full-lane-summary.json").read_text()), summary)
            self.assertEqual(json.loads((directory / "diagnostics/raw-full-lane-reader.json").read_text()),
                             {"tested_sha": SHA, "toolchain": METADATA, "xcresulttool_path": "/Fake/xcresulttool"})
            self.assertFalse(list(directory.glob("phase-*.json")))
            self.assertFalse(list(directory.glob("worker-*.json")))

    def test_git_sha_must_match_ci_checkout(self):
        with patch.object(subprocess, "check_output", return_value=SHA + "\n"), patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
            with self.assertRaisesRegex(ValueError, "does not match"):
                evidence.tested_sha()


if __name__ == "__main__":
    unittest.main()
