#!/bin/bash
# Exercise the shipped diagnostic controls with fake native boundaries.
# The extracted function bodies use these variables and boundary functions.
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-diagnostic-controls.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A skipped required check succeeds on GitHub, so manual diagnostics must not
# publish the full gate's check names or artifacts, even as skipped jobs.
python3 - "$repo_root/.github/workflows/ci.yml" "$repo_root/.github/workflows/ci-diagnostics.yml" <<'PYWORKFLOW'
from pathlib import Path
import re
import sys

workflow, reusable = (Path(path).read_text() for path in sys.argv[1:])

def require_line(body, expected):
    if [line.strip() for line in body.splitlines()].count(expected) != 1:
        raise SystemExit(f"Diagnostic workflow contract missing or duplicated: {expected}")

def job(name, source=workflow):
    match = re.search(rf"(?m)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)",
                      source, re.DOTALL)
    if match is None:
        raise SystemExit(f"Missing CI job: {name}")
    return match.group(1)

require_line(workflow, "workflow_dispatch:")
require_line(workflow, "workflow_call:")
release = Path(sys.argv[1]).with_name("release.yml").read_text()
release_test = job("test", release)
require_line(release_test, "uses: ./.github/workflows/ci.yml")
require_line(release_test, "contents: read")
require_line(release_test, "actions: read")
require_line(workflow, "diagnostic_target:")
require_line(workflow, "options: [none, all, ssh-jump, staging, staging-method, weak, layout]")
require_line(workflow, "default: none")
require_line(workflow, "pull_request:")
diagnostics = job("diagnostics")
require_line(diagnostics, "if: ${{ github.event_name == 'workflow_dispatch' && inputs.diagnostic_target != '' && inputs.diagnostic_target != 'none' }}")
require_line(diagnostics, "uses: ./.github/workflows/ci-diagnostics.yml")
require_line(diagnostics, "target: ${{ inputs.diagnostic_target }}")
require_line(diagnostics, "iterations: ${{ inputs.diagnostic_iterations }}")

diagnostic = "inputs.diagnostic_target != '' && inputs.diagnostic_target != 'none'"
normal = "inputs.diagnostic_target == '' || inputs.diagnostic_target == 'none'"
names = {
    "app-tests": ("Diagnostic mode (app coverage not run)", "format('App tests ({0})', matrix.shard)"),
    "heelerssh-package-e2e": ("Diagnostic mode (package coverage not run)", "'HeelerSSH package E2E (iOS Simulator)'"),
    "build-test": ("Diagnostic mode (full coverage not run)", "'Build & test (iOS Simulator)'"),
}
for name, (diagnostic_name, normal_name) in names.items():
    body = job(name)
    require_line(body, "name: ${{ " + diagnostic + " && '" + diagnostic_name + "' || " + normal_name + " }}")
    condition = f"always() && ({normal})" if name == "build-test" else normal
    require_line(body, "if: ${{ " + condition + " }}")
require_line(job("build-test"), "needs: [app-tests, heelerssh-package-e2e]")

require_line(reusable, "workflow_call:")
require_line(reusable, "workflow_dispatch:")
require_line(reusable, "options: [all, ssh-jump, staging, staging-method, weak, layout]")
require_line(reusable, "default: all")
require_line(reusable, "target: ${{ fromJSON(inputs.target == 'all' && '[\"ssh-jump\",\"staging\",\"weak\"]' || format('[\"{0}\"]', inputs.target)) }}")
require_line(reusable, "HEELER_XCODEBUILD_TEST_TIMEOUT_SECONDS: '1800'")
require_line(reusable, "run: make test-ci-diagnostics")
if "ios-ci-evidence-" in reusable or re.search(r"\bmake test-ci-(?:app|package)\b|verify-ci-ios-evidence\.py complete", reusable):
    raise SystemExit("Diagnostic workflow publishes or runs the complete merge gate")
if not any(line.strip().startswith("name: ios-diagnostic-") for line in reusable.splitlines()):
    raise SystemExit("Diagnostic workflow has no distinct artifact name")
print("Passed workflow dispatch, reusable entrypoint and full-gate isolation contracts.")
PYWORKFLOW

python3 - "$repo_root/Tests/HeelerTests/FileDiffLayoutViewTests.swift" <<'PYLAYOUT'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
expected_methods = {
    "wideDetailReadsAPairAsRemovedThenAddedAndEnablesTheToggle",
    "narrowDetailStaysUnifiedAndDisablesTheToggle",
    "accessibilityTextFallsBackToUnifiedAtTheWideWidth",
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
    "Self.resize(window, to: CGSize(width: 834, height: 1032))",
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
check_configuration staging ordinary AgentSurfaceReplacementTests HEELER_STAGING_RECOVERY_ITERATIONS 9 20
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
