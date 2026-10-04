#!/usr/bin/env python3
"""Exercise app test selection/result guards at the process and simulator boundaries."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("run-app-simulator-tests.py")
spec = importlib.util.spec_from_file_location("app_simulator_tests", SCRIPT)
assert spec is not None and spec.loader is not None
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)


def test_report(*cases: tuple[str, str]) -> dict:
    return {"testNodes": [{"nodeType": "Unit test bundle", "name": "HeelerTests", "children": [
        {"nodeType": "Test Case", "nodeIdentifier": identifier, "result": result}
        for identifier, result in cases
    ]}]}


FAKE_HOST = '''
import json, os, plistlib, sys, time
from pathlib import Path
root = Path(os.environ["FAKE_HOST_ROOT"])
args = sys.argv[1:]
program = Path(sys.argv[0]).name
with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([program, *args]) + "\\n")
config = json.loads((root / "config.json").read_text())
if program == "xcodebuild":
    if config.get("wait_for_signal"):
        (root / "started").write_text("started")
        time.sleep(20)
    status = config.get("status", 0)
    if status == 0 and "-resultBundlePath" in args:
        bundle = Path(args[args.index("-resultBundlePath") + 1])
        if bundle.exists():
            print("Result bundle already exists", file=sys.stderr)
            sys.exit(73)
        bundle.mkdir(parents=True)
    sys.exit(status)
if args[:4] == ["xcresulttool", "get", "test-results", "summary"]:
    print(json.dumps(config["summary"]))
elif args[:4] == ["xcresulttool", "get", "test-results", "tests"]:
    print(json.dumps(config["tests"]))
elif args == ["--find", "xcresulttool"]:
    print("/Applications/FakeXcode.app/usr/bin/xcresulttool")
elif args[:2] == ["simctl", "spawn"] and args[3] == "defaults":
    prefs_path = root / "preferences.plist"
    prefs = plistlib.loads(prefs_path.read_bytes())
    action = args[4]
    if action == "export":
        sys.stdout.buffer.write(plistlib.dumps(prefs))
    elif action == "write":
        if config.get("fail_restore") and args[-1] == "false":
            sys.exit(1)
        prefs[args[6]] = (args[8] == "true") if args[7] == "-bool" else int(args[8])
        prefs_path.write_bytes(plistlib.dumps(prefs))
    elif action == "delete":
        prefs.pop(args[6], None)
        prefs_path.write_bytes(plistlib.dumps(prefs))
elif args[:2] != ["simctl", "bootstatus"]:
    print("Unexpected fake host command: " + repr(args), file=sys.stderr)
    sys.exit(2)
'''


class ResultParsingTests(unittest.TestCase):
    def test_counts_are_nonnegative_integers_with_a_consistent_skip_budget(self):
        valid = {"totalTestCount": 3, "skippedTests": 1, "failedTests": 0, "result": "Passed"}
        self.assertEqual(runner.TestRunSummary.parse(valid).executed, 2)
        for key, value in [("totalTestCount", True), ("totalTestCount", "3"),
                           ("skippedTests", -1), ("skippedTests", 4), ("failedTests", 3),
                           ("expectedFailures", -1), ("expectedFailures", "1")]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                runner.TestRunSummary.parse({**valid, key: value})

    def test_parameterized_url_uses_method_identity_not_argument_values(self):
        report = test_report()
        report["testNodes"][0]["children"] = [{
            "nodeType": "Test Case", "result": "Passed",
            "nodeIdentifierURL": "test://com.apple.xcode/Heeler/HeelerTests/Suite/check%28value%3A%29?args=abc",
            "children": [{"nodeType": "Arguments", "result": "Passed", "name": "one value"}],
        }]
        identifiers = runner.executed_test_identifiers(report)
        self.assertEqual(identifiers, {"HeelerTests/Suite/check(value:)"})
        self.assertTrue(runner.selector_matches("HeelerTests/Suite", next(iter(identifiers))))
        self.assertTrue(runner.selector_matches("HeelerTests/Suite/check(value:)", next(iter(identifiers))))
        self.assertFalse(runner.selector_matches("HeelerTests/Suite/check(other:)", next(iter(identifiers))))

    def test_skipped_parameter_runs_do_not_count_as_method_execution(self):
        report = test_report(("Suite/check(value:)", "Passed"))
        report["testNodes"][0]["children"][0]["children"] = [
            {"nodeType": "Arguments", "result": "Skipped", "name": "unused value"}]
        self.assertEqual(runner.executed_test_identifiers(report), set())

    def test_method_matching_does_not_accept_a_different_method_prefix(self):
        self.assertTrue(runner.selector_matches("HeelerTests/Suite/test", "HeelerTests/Suite/test()"))
        self.assertFalse(runner.selector_matches("HeelerTests/Suite/test()", "HeelerTests/Suite/testOther()"))
        self.assertFalse(runner.selector_matches("HeelerTests/Suite", "OtherTests/Suite/test()"))

    def test_malformed_test_reports_fail_with_a_validation_error(self):
        for report in [None, {"testNodes": None}, {"testNodes": [None]},
                       {"testNodes": [{"nodeType": "Test Case", "children": None, "result": "Passed"}]}]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                runner.executed_test_identifiers(report)


class ProcessBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="heeler-app-test-runner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("xcrun", "xcodebuild"):
            executable = self.bin / name
            executable.write_text(f"#!{sys.executable}\n" + FAKE_HOST)
            executable.chmod(0o755)
        self.original_preferences = {"AccessibilityEnabled": False, "ApplicationAccessibilityEnabled": 7,
                                     "UnrelatedPreference": "retain me"}
        (self.root / "preferences.plist").write_bytes(plistlib.dumps(self.original_preferences))
        self.config = {"summary": {"totalTestCount": 1, "skippedTests": 0, "failedTests": 0, "result": "Passed"},
                       "tests": test_report(("Suite/test()", "Passed"))}
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FAKE_HOST_ROOT": str(self.root), "TEST_FLAGS": "", "TEST_SELECTOR": "",
                    "PYTHONDONTWRITEBYTECODE": "1"}
        for key in ("HEELER_CI_EVIDENCE_DIR", "HEELER_CI_TEST_PHASE", "HEELER_CI_APP_SHARD",
                    "HEELER_CI_EVIDENCE_METADATA"):
            self.env.pop(key, None)
        self.base_arguments = ["-destination", "platform=iOS Simulator,id=owned-device",
                               "-derivedDataPath", str(self.root / "derived")]

    def save_config(self):
        (self.root / "config.json").write_text(json.dumps(self.config))

    def run_wrapper(self, *extra: str, action: str = "test"):
        self.save_config()
        return subprocess.run([sys.executable, str(SCRIPT), *self.base_arguments, *extra, action],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]

    def xcode_arguments(self) -> list[str]:
        return next(call[1:] for call in self.calls() if call[0] == "xcodebuild")

    def assert_preferences_restored(self):
        self.assertEqual(plistlib.loads((self.root / "preferences.plist").read_bytes()), self.original_preferences)

    def test_make_exports_parentheses_as_opaque_selector_and_tokenized_legacy_flags(self):
        self.save_config()
        makefile = self.root / "Makefile"
        makefile.write_text("export TEST_FLAGS TEST_SELECTOR\nall:\n\t" + sys.executable + " " + str(SCRIPT)
                            + " -destination 'platform=iOS Simulator,id=owned-device' -derivedDataPath '"
                            + str(self.root / "derived") + "' test\n")
        result = subprocess.run(["make", "-f", str(makefile), "TEST_SELECTOR=HeelerTests/Suite/test()",
                                 "TEST_FLAGS=-only-testing:HeelerTests/Suite/test() -parallel-testing-enabled NO"],
                                cwd=self.root, env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = self.xcode_arguments()
        self.assertEqual(arguments.count("-only-testing:HeelerTests/Suite/test()"), 2)
        self.assertIn("-parallel-testing-enabled", arguments)
        self.assert_preferences_restored()

    def test_existing_internally_quoted_test_flags_remain_compatible(self):
        self.env["TEST_FLAGS"] = "'-only-testing:HeelerTests/Suite/test()'"
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-only-testing:HeelerTests/Suite/test()", self.xcode_arguments())

    def test_invalid_flag_quoting_fails_before_changing_simulator_preferences(self):
        self.env["TEST_FLAGS"] = "unbalanced'"
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.root / "calls.jsonl").exists())
        self.assert_preferences_restored()

    def test_cli_suite_and_method_selectors_match_executed_cases(self):
        result = self.run_wrapper("-only-testing:HeelerTests/Suite", "-only-testing:HeelerTests/Suite/test()")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 selectors verified", result.stdout)

    def test_separated_cli_selectors_and_response_files_also_require_matching_execution(self):
        response_file = self.root / "selected-tests.txt"
        response_file.write_text("\nHeelerTests/Suite\n\nHeelerTests/Suite/test()\n")
        result = self.run_wrapper("-only-testing", "@" + str(response_file))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 selectors verified", result.stdout)
        self.assertEqual(response_file.read_text(), "\nHeelerTests/Suite\n\nHeelerTests/Suite/test()\n")
        result = self.run_wrapper("-only-testing", "HeelerTests/Suite/missing()")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Requested selector executed no matching tests", result.stderr)
        response_file.write_text("HeelerTests/Suite/missing()\n")
        result = self.run_wrapper("-only-testing", "@" + str(response_file))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Requested selector executed no matching tests", result.stderr)

    def test_each_requested_selector_must_execute_despite_another_matching_selector(self):
        result = self.run_wrapper("-only-testing:HeelerTests/Suite", "-only-testing:HeelerTests/Suite/missing()")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Requested selector executed no matching tests: HeelerTests/Suite/missing()", result.stderr)
        self.assert_preferences_restored()

    def test_skipped_requested_suite_is_not_credited_by_an_unrelated_pass(self):
        self.config["summary"].update(totalTestCount=2, skippedTests=1)
        self.config["tests"] = test_report(("Requested/test()", "Skipped"), ("Other/test()", "Passed"))
        result = self.run_wrapper("-only-testing:HeelerTests/Requested")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Requested selector executed no matching tests", result.stderr)

    def test_zero_and_skipped_only_runs_fail_even_with_a_successful_child(self):
        for total, skipped in [(0, 0), (2, 2)]:
            with self.subTest(total=total, skipped=skipped):
                self.config["summary"].update(totalTestCount=total, skippedTests=skipped)
                result = self.run_wrapper()
                self.assertEqual(result.returncode, 1)
                self.assertIn("executed no tests", result.stderr)
                self.assert_preferences_restored()

    def test_failed_child_keeps_its_status_without_reading_a_result(self):
        self.config["status"] = 65
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 65)
        self.assertFalse(any(call[1:2] == ["xcresulttool"] for call in self.calls()))
        self.assert_preferences_restored()

    def test_result_report_cannot_hide_a_failure_behind_child_exit_zero(self):
        self.config["summary"].update(failedTests=1, result="Failed")
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("reports Failed", result.stderr)

    def test_expected_failures_fail_like_the_ci_evidence_recorder(self):
        for summary in ({"expectedFailures": 1}, {"expectedFailures": 1, "result": "Expected Failure"}):
            with self.subTest(summary=summary):
                self.config["summary"].update(summary)
                result = self.run_wrapper()
                self.assertEqual(result.returncode, 1)
                self.assertIn("reports 1 expected failures", result.stderr)
                self.assert_preferences_restored()

    def test_build_for_testing_does_not_consume_selection_or_require_results(self):
        self.env.update(TEST_FLAGS="unbalanced'", TEST_SELECTOR="HeelerTests/Missing")
        result = self.run_wrapper(action="build-for-testing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("-resultBundlePath", self.xcode_arguments())
        self.assertFalse(any(call[1:2] == ["xcresulttool"] for call in self.calls()))

    def test_test_without_building_also_validates_selectors(self):
        result = self.run_wrapper("-only-testing:HeelerTests/Missing", action="test-without-building")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Requested selector", result.stderr)

    def enable_evidence(self):
        self.env.update(HEELER_CI_EVIDENCE_DIR=str(self.root / "evidence"),
                        HEELER_CI_TEST_PHASE="full-lane", HEELER_CI_APP_SHARD="ordinary",
                        HEELER_CI_EVIDENCE_METADATA=json.dumps({"xcode_version": "Xcode 26.6",
                                                              "sdk_version": "26.5", "architecture": "arm64"}))
        self.env.pop("GITHUB_SHA", None)

    def test_success_exports_execution_evidence_without_marking_shell_guards_complete(self):
        self.enable_evidence()
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        phase = json.loads((self.root / "evidence/phase-full-lane.json").read_text())
        self.assertEqual(phase["tests"][0]["identity"], "HeelerTests/Suite/test()")
        self.assertEqual(phase["summary"]["total"], 1)
        self.assertEqual(phase["selection"], {"only_testing": [], "skip_testing": []})
        self.assertFalse(list((self.root / "evidence").glob("worker-*.json")))
        self.assert_preferences_restored()

    def test_failed_child_exports_no_success_evidence(self):
        self.enable_evidence()
        self.config["status"] = 65
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse((self.root / "evidence").exists())

    def test_partial_parameter_execution_cannot_export_a_green_phase(self):
        self.enable_evidence()
        node = self.config["tests"]["testNodes"][0]["children"][0]
        url = "test://com.apple.xcode/Heeler/HeelerTests/Suite/test()"
        node["children"] = [
            {"nodeType": "Arguments", "nodeIdentifierURL": url + "?args=first", "result": "Passed"},
            {"nodeType": "Arguments", "nodeIdentifierURL": url + "?args=second", "result": "Skipped"}]
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Partially executed parameterized test", result.stderr)
        self.assertFalse(list((self.root / "evidence").glob("phase-*.json")))
        self.assertFalse(list((self.root / "evidence").glob("worker-*.json")))
        self.assertEqual(json.loads((self.root / "evidence/diagnostics/raw-full-lane-tests.json").read_text()),
                         self.config["tests"])
        self.assert_preferences_restored()

    def test_export_sha_mismatch_fails_after_restoring_preferences(self):
        self.enable_evidence()
        self.env["GITHUB_SHA"] = "0" * 40
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("GITHUB_SHA does not match", result.stderr)
        self.assertFalse((self.root / "evidence").exists())
        self.assert_preferences_restored()

    def test_supplied_result_bundle_is_used_and_existing_results_are_never_removed(self):
        bundle = self.root / "chosen.xcresult"
        result = self.run_wrapper("-resultBundlePath", str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        marker = bundle / "retain.txt"
        marker.write_text("original result")
        result = self.run_wrapper("-resultBundlePath", str(bundle))
        self.assertEqual(result.returncode, 73)
        self.assertEqual(marker.read_text(), "original result")

    def test_generated_result_paths_are_unique_under_derived_data(self):
        self.assertEqual(self.run_wrapper().returncode, 0)
        self.assertEqual(self.run_wrapper().returncode, 0)
        bundles = list((self.root / "derived" / "Logs" / "Test").glob("*.xcresult"))
        self.assertEqual(len(bundles), 2)

    def test_absent_preferences_are_restored_to_absence(self):
        self.original_preferences = {"UnrelatedPreference": "retain me"}
        (self.root / "preferences.plist").write_bytes(plistlib.dumps(self.original_preferences))
        self.assertEqual(self.run_wrapper().returncode, 0)
        self.assert_preferences_restored()

    def test_restore_failure_keeps_the_run_failed(self):
        self.config["fail_restore"] = True
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not restore", result.stderr)
        self.assertFalse(any(call[1:2] == ["xcresulttool"] for call in self.calls()))

    def test_cancellation_forwards_to_child_and_restores_preferences(self):
        self.config["wait_for_signal"] = True
        self.save_config()
        child = subprocess.Popen([sys.executable, str(SCRIPT), *self.base_arguments, "test"],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        deadline = time.monotonic() + 5
        while not (self.root / "started").exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.root / "started").exists(), "fake xcodebuild did not start")
        child.send_signal(signal.SIGTERM)
        child.communicate(timeout=5)
        self.assertEqual(child.returncode, 143)
        self.assert_preferences_restored()


if __name__ == "__main__":
    unittest.main()
