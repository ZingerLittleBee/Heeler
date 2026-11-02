#!/bin/bash
# Exercise the shipped diagnostic controls with fake native boundaries.
# The extracted function bodies use these variables and boundary functions.
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-diagnostic-controls.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Fast builds and manual diagnostics must not publish full-coverage check
# names or artifacts, even as skipped jobs. Releases always call full CI.
python3 - "$repo_root/.github/workflows/ci-full.yml" "$repo_root/.github/workflows/ci-diagnostics.yml" <<'PYWORKFLOW'
from pathlib import Path
import re
import shlex
import subprocess
import sys

workflow, diagnostics = (Path(path).read_text() for path in sys.argv[1:])
workflows = Path(sys.argv[1]).parent

def require_line(body, expected):
    if [line.strip() for line in body.splitlines()].count(expected) != 1:
        raise SystemExit(f"Diagnostic workflow contract missing or duplicated: {expected}")

def job(name, source=workflow):
    match = re.search(rf"(?m)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)",
                      source, re.DOTALL)
    if match is None:
        raise SystemExit(f"Missing CI job: {name}")
    return match.group(1)

def events(source):
    block = re.search(r"(?m)^on:\n(.*?)(?=^[^\s#]|\Z)", source, re.DOTALL)
    if block is None:
        raise SystemExit("Missing workflow triggers")
    return set(re.findall(r"(?m)^  ([\w_]+):", block.group(1)))

require_line(workflow, "workflow_dispatch:")
require_line(workflow, "workflow_call:")
release = workflows.joinpath("release.yml").read_text()
release_test = job("test", release)
require_line(release_test, "uses: ./.github/workflows/ci-full.yml")
require_line(release_test, "contents: read")
require_line(release_test, "actions: read")
if events(workflow) != {"schedule", "workflow_dispatch", "workflow_call"}:
    raise SystemExit("Full native verification must run daily, manually or before release")
require_line(workflow, "- cron: '17 20 * * *'")
# A manual run must not cancel the scheduled run on the same ref.
require_line(workflow, "group: ci-ios-full-${{ github.ref }}-${{ github.event_name }}")
# Release tags compile without cross-run compiler objects.
app_tests = job("app-tests")
require_line(app_tests, "HEELER_CI_DISABLE_COMPILATION_CACHE: ${{ startsWith(github.ref, 'refs/tags/') && '1' || '0' }}")
require_line(app_tests, "if: ${{ env.HEELER_CI_DISABLE_COMPILATION_CACHE != '1' && (github.event_name != 'workflow_dispatch' || inputs.cache_mode == 'warm') }}")
names = {
    "app-tests": "App tests (${{ matrix.shard }})",
    "heelerssh-package-e2e": "HeelerSSH package E2E (iOS Simulator)",
    "build-test": "Build & test (iOS Simulator)",
}
for name, display in names.items():
    body = job(name)
    require_line(body, "name: " + display)
    if name != "build-test" and re.search(r"(?m)^    if:", body):
        raise SystemExit(f"Full verification must not skip {name}")
require_line(job("build-test"), "if: ${{ always() }}")
require_line(job("build-test"), "needs: [app-tests, heelerssh-package-e2e]")

# release.yml grants read-only permissions, so only the listener may write.
alert = workflows.joinpath("ci-full-alert.yml").read_text()
full_name = re.search(r"(?m)^name: (.+)$", workflow).group(1)
require_line(alert, f"workflows: [{full_name}]")
require_line(alert, "if: ${{ github.event.workflow_run.event == 'schedule' && github.event.workflow_run.conclusion != 'cancelled' }}")
if re.search(r"(?m)^\s+[\w-]+: write\s*$", workflow):
    raise SystemExit("ci-full.yml must stay read-only for release.yml")

fast = workflows.joinpath("ci.yml").read_text()
if events(fast) != {"workflow_dispatch", "pull_request", "push"}:
    raise SystemExit("The fast build must run on PR/push and support manual runs")
if re.findall(r"(?m)^  ([\w-]+):", fast.split("\njobs:\n", 1)[1]) != ["app-build"]:
    raise SystemExit("The fast build must have one build-only job")
require_line(job("app-build", fast), "name: Build app and tests (not run)")
# Script self-tests build nothing, so a script-only change never starts ci.yml.
scripts = workflows.joinpath("ci-scripts.yml").read_text()
if events(scripts) != {"workflow_dispatch", "pull_request", "push"}:
    raise SystemExit("Script self-tests must run on PR/push and support manual runs")
if re.findall(r"(?m)^  ([\w-]+):", scripts.split("\njobs:\n", 1)[1]) != ["gate-scripts"]:
    raise SystemExit("Script self-tests must have one job")
if re.findall(r"(?m)^\s+run: (.+)$", scripts) != [
        "make test-ci-watchdog", "make test-ci-guards", "make test-ci-diagnostic-controls"]:
    raise SystemExit("Script self-tests must not build the app or run native tests")
if ("ios-ci-evidence-" in fast or "verify-ci-ios-evidence" in fast or "simctl" in fast
        or re.search(r"\bmake test-ci-(?:app|package|diagnostics)\b", fast)):
    raise SystemExit("The fast build must not execute or claim native tests")
for source in [fast, scripts, diagnostics]:
    if any("name: " + display in source for display in names.values()):
        raise SystemExit("Only full verification may publish full coverage check names")
# Compare whole tokens: the checkout path may contain words such as `test`.
command = subprocess.check_output(
    ["make", "--no-print-directory", "-n", "build-ci-app"],
    cwd=workflows.resolve().parents[1], text=True)
tokens = shlex.split(command.replace("\\\n", " "))
actions = {"build", "build-for-testing", "test", "test-without-building", "analyze", "archive", "clean"}
if tokens[:1] != ["xcodebuild"] or [token for token in tokens if token in actions] != ["build-for-testing"]:
    raise SystemExit("The fast build entrypoint must compile the app and tests without running them")
if any(Path(token).name in {"xcodegen", "simctl"} for token in tokens):
    raise SystemExit("The fast build must use the committed project without a Simulator")
if "-destination" not in tokens or tokens[tokens.index("-destination") + 1] != "generic/platform=iOS Simulator":
    raise SystemExit("The fast build must not need a booted Simulator destination")
if "-arch" in tokens:
    raise SystemExit("The generic destination conflicts with -arch; use the ARCHS build setting")

require_line(diagnostics, "workflow_dispatch:")
if events(diagnostics) != {"workflow_dispatch"}:
    raise SystemExit("Repeated diagnostics must remain manual")
require_line(diagnostics, "options: [all, ssh-jump, staging, staging-method, weak, layout]")
require_line(diagnostics, "default: all")
require_line(diagnostics, "target: ${{ fromJSON(inputs.target == 'all' && '[\"ssh-jump\",\"staging\",\"weak\"]' || format('[\"{0}\"]', inputs.target)) }}")
require_line(diagnostics, "HEELER_XCODEBUILD_TEST_TIMEOUT_SECONDS: '1800'")
require_line(diagnostics, "run: make test-ci-diagnostics")
if "ios-ci-evidence-" in diagnostics or re.search(r"\bmake test-ci-(?:app|package)\b|verify-ci-ios-evidence\.py complete", diagnostics):
    raise SystemExit("Diagnostic workflow publishes or runs the complete merge gate")
if not any(line.strip().startswith("name: ios-diagnostic-") for line in diagnostics.splitlines()):
    raise SystemExit("Diagnostic workflow has no distinct artifact name")
print("Passed fast build, full verification, scheduled alert and diagnostic isolation contracts.")
PYWORKFLOW

python3 - "$repo_root/Tests/HeelerTests/FileDiffLayoutViewTests.swift" <<'PYLAYOUT'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
expected_methods = {
    "wideDetailReadsAPairAsRemovedThenAddedAndEnablesTheToggle",
    "narrowDetailStaysUnifiedAndHidesTheToggle",
    "accessibilityTextFallsBackToUnifiedWhereDefaultTextFits",
    "anIPhoneShowsNoToggle",
    "choosingUnifiedPersistsForTheNextPresentation",
    "aLayoutSwitchKeepsTheTopmostLine",
    "pairedRowOffersBothLinesReferenceActions",
    "listChangeNoticeShowsInSideBySide",
}
methods = re.findall(r"@Test\s+func\s+(\w+)\(", source)
if len(methods) != 8 or set(methods) != expected_methods:
    raise SystemExit("Layout diagnosis must retain the original eight test methods")
if re.search(r"\.(?:disabled|enabled)\s*\(", source):
    raise SystemExit("Layout diagnosis must not introduce a skip trait")

def require(body, fragment):
    if fragment not in body:
        raise SystemExit(f"Layout diagnostic contract missing: {fragment}")

trait = source.split("struct FileDiffLayoutViewTests", 1)[0]
for fragment in (
    'environment["HEELER_DIFF_LAYOUT_ITERATIONS"]',
    "(2...100).contains(iterations)",
    "else { return false }",
    '"File diff layout", .serialized',
    ".timeLimit(hasRepeatedDiffLayoutDiagnostic() ? .minutes(30) : .minutes(1))",
):
    require(trait, fragment)
method = source.split("@Test func aLayoutSwitchKeepsTheTopmostLine()", 1)[1].split(
    "private func assertLayoutSwitchKeepsTheTopmostLine", 1)[0]
for fragment in (
    'environment["HEELER_DIFF_LAYOUT_ITERATIONS"] ?? "1"',
    "(1...100).contains(iterations)",
    "for iteration in 1...iterations",
    "try await assertLayoutSwitchKeepsTheTopmostLine(iteration: iteration, iterations: iterations)",
    'print("[diff-layout-test] completed \\(iterations) iterations")',
):
    require(method, fragment)
round_body = source.split("private func assertLayoutSwitchKeepsTheTopmostLine", 1)[1].split(
    "private struct ScrollSetupGeometry", 1)[0]
if round_body.count("eventually(timeout: .seconds(8))") != 2:
    raise SystemExit("Layout diagnosis must retain both eight-second setup deadlines")
for fragment in (
    "try makeSettings(offersSideBySide: true)",
    "defer { cleanup() }",
    "try await host(",
    "defer { window.isHidden = true }",
    "try #require(initialLayoutReady,",
    "guard travel > 400",
    "animated: true)",
    "top >= 40",
    "return stable >= 3",
    "initialScrollSettled,",
    "settings.select(.unified)",
    "settings.select(.sideBySide)",
    "Self.resize(window, to: CGSize(width: 694, height: 1032))",
    "Self.resize(window, to: CGSize(width: 1376, height: 1032))",
):
    require(round_body, fragment)
if round_body.count("try await Self.expectTop(expected, in: controller)") != 2 or round_body.count(
        "Self.topLineID(in: controller.view, viewport: scroll) == expected") != 2:
    raise SystemExit("Layout diagnosis must retain all layout-switch and resize assertions")
print("Passed layout suite membership, repetition and original-deadline source contracts.")
PYLAYOUT

for function in configure_diagnostic_lane run_ci_diagnostic push_simulator_environment clear_simulator_environment; do
    body=$(awk -v fn="$function" '
        $0 == fn "() {" { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$repo_root/scripts/run-ci-ios-tests.sh")
    [[ -n "$body" ]] || { echo "Missing shipped function: $function" >&2; exit 1; }
    eval "$body"
done

# A literal command substitution must be rejected, never evaluated.
# shellcheck disable=SC2016
for target in ssh-jump staging staging-method weak layout; do
    for value in 0 101 -1 '1;false' '$(false)' ' 2' 01; do
        if (ci_lane=app; ci_app_shard=all; ci_diagnostic_target=$target;
            ci_diagnostic_iterations=$value; configure_diagnostic_lane) >/dev/null 2>&1; then
            echo "Invalid $target diagnostic count accepted: $value" >&2
            exit 1
        fi
    done
done
if (ci_lane=package; ci_app_shard=all; ci_diagnostic_target=weak;
    ci_diagnostic_iterations=1; configure_diagnostic_lane) >/dev/null 2>&1; then
    echo "Package worker accepted app diagnosis" >&2
    exit 1
fi
if (ci_lane=app; ci_app_shard=all; ci_diagnostic_target=unknown;
    ci_diagnostic_iterations=1; configure_diagnostic_lane) >/dev/null 2>&1; then
    echo "Unknown diagnostic target accepted" >&2
    exit 1
fi
(ci_lane=app; ci_app_shard=all; ci_diagnostic_target='';
    ci_diagnostic_iterations=''; configure_diagnostic_lane;
    [[ "$ci_app_shard" == all ]])

check_configuration() (
    local target=$1 shard=$2 selector=$3 variable=$4 expected_tests=$5 default_iterations=$6 count
    for count in '' 1 100; do
        ci_lane=app
        ci_app_shard=all
        ci_diagnostic_target=$target
        ci_diagnostic_iterations=$count
        configure_diagnostic_lane
        [[ "$ci_app_shard" == "$shard" && "$HEELER_CI_APP_SHARD" == "$shard" ]]
        [[ "$diagnostic_selector" == "$selector" && "$diagnostic_iteration_variable" == "$variable" ]]
        [[ "$diagnostic_expected_tests" == "$expected_tests" ]]
        [[ "$ci_diagnostic_iterations" == "${count:-$default_iterations}" ]]
        if [[ "$target" == layout ]]; then
            [[ "$diagnostic_completion_marker" == "[diff-layout-test] completed ${count:-$default_iterations} iterations" ]]
        fi
    done
)
check_configuration ssh-jump transport 'HeelerSSHJumpHostGateE2ETests/trustIsIndependentAtBothHops()' HEELER_SSH_JUMP_TOFU_ITERATIONS 1 50
check_configuration staging ordinary AgentSurfaceReplacementTests HEELER_STAGING_RECOVERY_ITERATIONS 10 20
check_configuration staging-method ordinary 'AgentSurfaceReplacementTests/aPossibleSuspensionRebuildsTheTerminalAndPreservesAttachState()' HEELER_STAGING_RECOVERY_ITERATIONS 1 20
check_configuration weak session-weak 'WeakNetworkE2ETests/largeChangesReadsFitTheGitDeadlineOverACellularLink()' HEELER_WEAK_CHANGES_ITERATIONS 1 10
check_configuration layout ordinary FileDiffLayoutViewTests HEELER_DIFF_LAYOUT_ITERATIONS 8 20

run_case() (
    local target=$1 scenario=$2 expected=$3 fixture_mode=$4 status=0 test_noun=tests variable
    ci_lane=app
    ci_app_shard=all
    ci_diagnostic_target=$target
    ci_diagnostic_iterations=2
    configure_diagnostic_lane
    fixture_dir="$work/$target-$scenario-$fixture_mode"
    mkdir -p "$fixture_dir"
    app_derived_data_path="$fixture_dir/derived"
    simulator_destination='platform=iOS Simulator,id=fake'
    simulator_udid=original-device
    simulator_environment_variables=()
    local iteration_variables=(HEELER_SSH_JUMP_TOFU_ITERATIONS HEELER_STAGING_RECOVERY_ITERATIONS HEELER_WEAK_CHANGES_ITERATIONS HEELER_DIFF_LAYOUT_ITERATIONS)
    for variable in "${iteration_variables[@]}"; do
        export "$variable=inherited-value"
    done
    if [[ "$fixture_mode" == configured ]]; then
        simulator_environment_variables=(HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG)
        export HEELER_SSH_E2E_CONFIG=ssh-config HEELER_SSH_JUMP_E2E_CONFIG=jump-config HEELER_PAIRING_E2E_CONFIG=pairing-config
    fi
    xcodebuild_test_timeout_seconds=1
    [[ "$diagnostic_expected_tests" != 1 ]] || test_noun='test'
    xcrun() {
        [[ "$1" == simctl && "$2" == spawn && "$4" == launchctl ]]
        case "$5" in
            setenv) printf '%s %s %s\n' "$3" "$6" "$7" >> "$fixture_dir/environment" ;;
            unsetenv) printf '%s %s\n' "$3" "$6" >> "$fixture_dir/cleared-environment" ;;
            *) return 1 ;;
        esac
    }
    run_xcodebuild() {
        local log=$3
        shift 3
        # Model destination-70 recovery with the runner's saved environment.
        simulator_udid=replacement-device
        push_simulator_environment "${simulator_environment_variables[@]}"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        printf 'Test run with %s %s in 1 suite passed\n' "$diagnostic_expected_tests" "$test_noun" > "$log"
        case "$scenario" in
            native-failure) return 65 ;;
            missing-completion) ;;
            wrong-completion) printf '%s wrong-round\n' "${diagnostic_completion_marker%2*}" >> "$log" ;;
            skipped) printf '%s\nTest "owned" skipped\n' "$diagnostic_completion_marker" >> "$log" ;;
            wrong-count) printf '%s\n%s\n' 'Test run with 0 tests in 1 suite passed' "$diagnostic_completion_marker" > "$log" ;;
            *) printf '%s\n' "$diagnostic_completion_marker" >> "$log" ;;
        esac
    }
    run_ci_diagnostic >/dev/null 2>&1 || status=$?
    [[ "$status" == "$expected" ]] || { echo "Unexpected $target/$scenario status: $status" >&2; exit 1; }
    grep -qxF -- "-only-testing:HeelerTests/$diagnostic_selector" "$fixture_dir/arguments"
    grep -qxF -- '-parallel-testing-enabled' "$fixture_dir/arguments"
    grep -qxF -- 'NO' "$fixture_dir/arguments"
    if grep -q -- '^-skip-testing:' "$fixture_dir/arguments"; then
        echo "Diagnostic added a skip selector: $target/$scenario" >&2
        exit 1
    fi
    for device in original-device replacement-device; do
        grep -qxF "$device $diagnostic_iteration_variable 2" "$fixture_dir/environment"
        if [[ "$fixture_mode" == configured ]]; then
            grep -qxF "$device HEELER_SSH_E2E_CONFIG ssh-config" "$fixture_dir/environment"
            grep -qxF "$device HEELER_SSH_JUMP_E2E_CONFIG jump-config" "$fixture_dir/environment"
            grep -qxF "$device HEELER_PAIRING_E2E_CONFIG pairing-config" "$fixture_dir/environment"
        fi
    done
    # Real runner exit uses this global cleanup after success or failure.
    clear_simulator_environment
    [[ ${#simulator_environment_variables[@]} == 0 ]]
    for variable in "${iteration_variables[@]}" HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG; do
        [[ -z "${!variable+x}" ]]
        grep -qxF "replacement-device $variable" "$fixture_dir/cleared-environment"
    done
)
for target in ssh-jump staging staging-method weak layout; do
    for fixture_mode in empty configured; do
        run_case "$target" passed 0 "$fixture_mode"
        run_case "$target" missing-completion 1 "$fixture_mode"
        run_case "$target" wrong-completion 1 "$fixture_mode"
        run_case "$target" skipped 1 "$fixture_mode"
        run_case "$target" wrong-count 1 "$fixture_mode"
        run_case "$target" native-failure 65 "$fixture_mode"
    done
done
echo 'Passed diagnostic isolation, input rejection and 60 native-boundary/replacement/cleanup scenarios.'
