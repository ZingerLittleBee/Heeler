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

def job(name):
    match = re.search(rf"(?m)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:|\Z)",
                      workflow, re.DOTALL)
    if match is None:
        raise SystemExit(f"Missing CI job: {name}")
    return match.group(1)

require_line(workflow, "workflow_dispatch:")
require_line(workflow, "diagnostic_target:")
require_line(workflow, "options: [none, all, ssh-jump, staging, staging-method, weak]")
require_line(workflow, "default: none")
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
require_line(reusable, "run: make test-ci-diagnostics")
if "ios-ci-evidence-" in reusable or re.search(r"\bmake test-ci-(?:app|package)\b|verify-ci-ios-evidence\.py complete", reusable):
    raise SystemExit("Diagnostic workflow publishes or runs the complete merge gate")
if not any(line.strip().startswith("name: ios-diagnostic-") for line in reusable.splitlines()):
    raise SystemExit("Diagnostic workflow has no distinct artifact name")
print("Passed workflow dispatch, reusable entrypoint and full-gate isolation contracts.")
PYWORKFLOW

for function in configure_diagnostic_lane run_ci_diagnostic push_simulator_environment; do
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
for value in 0 101 -1 '1;false' '$(false)' ' 2' 01; do
    if (ci_lane=app; ci_app_shard=all; ci_diagnostic_target=weak;
        ci_diagnostic_iterations=$value; configure_diagnostic_lane) >/dev/null 2>&1; then
        echo "Invalid diagnostic count accepted: $value" >&2
        exit 1
    fi
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

run_case() (
    local target=$1 scenario=$2 expected=$3 fixture_mode=$4 status=0 test_noun=tests
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
    if [[ "$fixture_mode" == configured ]]; then
        simulator_environment_variables=(HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG)
        export HEELER_SSH_E2E_CONFIG=ssh-config HEELER_SSH_JUMP_E2E_CONFIG=jump-config HEELER_PAIRING_E2E_CONFIG=pairing-config
    fi
    xcodebuild_test_timeout_seconds=1
    [[ "$diagnostic_expected_tests" != 1 ]] || test_noun='test'
    xcrun() {
        [[ "$1" == simctl && "$2" == spawn && "$4" == launchctl && "$5" == setenv ]]
        printf '%s %s %s\n' "$3" "$6" "$7" >> "$fixture_dir/environment"
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
            skipped) printf '%s\nTest "owned" skipped\n' "$diagnostic_completion_marker" >> "$log" ;;
            wrong-count) printf '%s\n%s\n' 'Test run with 0 tests in 1 suite passed' "$diagnostic_completion_marker" > "$log" ;;
            *) printf '%s\n' "$diagnostic_completion_marker" >> "$log" ;;
        esac
    }
    run_ci_diagnostic >/dev/null 2>&1 || status=$?
    [[ "$status" == "$expected" ]] || { echo "Unexpected $target/$scenario status: $status" >&2; exit 1; }
    grep -qxF -- "-only-testing:HeelerTests/$diagnostic_selector" "$fixture_dir/arguments"
    for device in original-device replacement-device; do
        grep -qxF "$device $diagnostic_iteration_variable 2" "$fixture_dir/environment"
        if [[ "$fixture_mode" == configured ]]; then
            grep -qxF "$device HEELER_SSH_E2E_CONFIG ssh-config" "$fixture_dir/environment"
            grep -qxF "$device HEELER_SSH_JUMP_E2E_CONFIG jump-config" "$fixture_dir/environment"
            grep -qxF "$device HEELER_PAIRING_E2E_CONFIG pairing-config" "$fixture_dir/environment"
        fi
    done
)
for target in ssh-jump staging staging-method weak; do
    for fixture_mode in empty configured; do
        run_case "$target" passed 0 "$fixture_mode"
        run_case "$target" missing-completion 1 "$fixture_mode"
        run_case "$target" skipped 1 "$fixture_mode"
        run_case "$target" wrong-count 1 "$fixture_mode"
        run_case "$target" native-failure 65 "$fixture_mode"
    done
done
echo 'Passed diagnostic isolation, input rejection and 40 native-boundary/replacement scenarios.'
