#!/bin/bash
# Exercise the shipped diagnostic controls with fake native boundaries.
# The extracted function bodies use these variables and boundary functions.
# shellcheck disable=SC2034,SC2154,SC2329
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-diagnostic-controls.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Fast builds and manual diagnostics must not publish full-coverage check
# names or artifacts, even as skipped jobs. Releases never wait for full CI
# (ADR 0039).
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
release = workflows.joinpath("release.yml").read_text()
if "ci-full" in release:
    raise SystemExit("release.yml must not call or wait for full verification")
if events(workflow) != {"schedule", "workflow_dispatch"}:
    raise SystemExit("Full native verification must run only daily or manually")
require_line(workflow, "- cron: '17 20 * * *'")
# A manual run must not cancel the scheduled run on the same ref.
require_line(workflow, "group: ci-ios-full-${{ github.ref }}-${{ github.event_name }}")
# Only a cold manual benchmark skips the compiler object cache.
app_tests = job("app-tests")
if "HEELER_CI_DISABLE_COMPILATION_CACHE" in app_tests:
    raise SystemExit("App tests must not disable the compilation cache")
restore = re.search(r"(?m)^      - name: Restore app compilation cache\n(.*?)(?=^      - |\Z)", app_tests, re.DOTALL)
if restore is None:
    raise SystemExit("Missing app compilation cache restore")
require_line(restore.group(1), "if: ${{ github.event_name != 'workflow_dispatch' || inputs.cache_mode == 'warm' }}")
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

# Full verification stays read-only, so only the listener may write.
alert = workflows.joinpath("ci-full-alert.yml").read_text()
full_name = re.search(r"(?m)^name: (.+)$", workflow).group(1)
require_line(alert, f"workflows: [{full_name}]")
require_line(alert, "if: ${{ github.event.workflow_run.event == 'schedule' && github.event.workflow_run.conclusion != 'cancelled' }}")
if re.search(r"(?m)^\s+[\w-]+: write\s*$", workflow):
    raise SystemExit("ci-full.yml must stay read-only")

def trigger_paths(source, name):
    block = re.search(r"(?m)^on:\n(.*?)(?=^[^\s#]|\Z)", source, re.DOTALL).group(1)
    if "paths-ignore:" in block:
        raise SystemExit(f"{name} must use positive paths, not paths-ignore")
    lists = []
    for event in ("pull_request", "push"):
        match = re.search(rf"(?m)^  {event}:\n(.*?)(?=^  \S|\Z)", block, re.DOTALL)
        lists.append(re.findall(r"(?m)^      - (.+)$", match.group(1)) if match else [])
    if lists[0] != lists[1]:
        raise SystemExit(f"{name} must list the same paths for pull_request and push")
    return set(lists[0])

# Each fast workflow starts only for what it compiles or executes: a
# script-only change never builds the app, and exports or the marketing site
# never spend a macOS worker. This runs on Ubuntu for every PR, so a trigger
# edit cannot slip past the workflow it changes.
fast_workflows = {
    "ci.yml": ("app-build", "Build app and tests (not run)", {
        "Sources/**", "Tests/**", "Packages/**", "Heeler.xcodeproj/**", "project.yml",
        "Makefile", "scripts/run-ci-background-build.py",
        "scripts/ci-compilation-cache-prefix.sh", "plugin/test-vectors/**",
        ".github/workflows/ci.yml"}),
    "ci-scripts.yml": ("gate-scripts", "CI and VPS scripts (macOS)", {
        "scripts/**", "Makefile", ".github/workflows/ci-full.yml",
        ".github/workflows/ci-scripts.yml"}),
    "ci-package.yml": ("package-build", "Build HeelerSSH and tests (not run)", {
        "Packages/HeelerSSH/**", ".github/workflows/ci-package.yml"}),
}
sources = {}
for name, (job_id, display, expected) in fast_workflows.items():
    source = sources[name] = workflows.joinpath(name).read_text()
    if events(source) != {"workflow_dispatch", "pull_request", "push"}:
        raise SystemExit(f"{name} must run on PR/push and support manual runs")
    if re.findall(r"(?m)^  ([\w-]+):", source.split("\njobs:\n", 1)[1]) != [job_id]:
        raise SystemExit(f"{name} must have the single job {job_id}")
    require_line(job(job_id, source), "name: " + display)
    paths = trigger_paths(source, name)
    if paths != expected:
        raise SystemExit(f"{name} trigger paths differ: missing {sorted(expected - paths)}, extra {sorted(paths - expected)}")
    if any("name: " + full in source for full in names.values()):
        raise SystemExit("Only full verification may publish full coverage check names")
fast = sources["ci.yml"]
if ("ios-ci-evidence-" in fast or "verify-ci-ios-evidence" in fast or "simctl" in fast
        or re.search(r"\bmake test-ci-(?:app|package|diagnostics)\b", fast)):
    raise SystemExit("The fast build must not execute or claim native tests")
if re.findall(r"(?m)^\s+run: (.+)$", sources["ci-scripts.yml"]) != [
        "scripts/test-vps-ssh-access-scripts.sh", "make test-ci-watchdog",
        "make test-ci-guards", "make test-ci-diagnostic-controls"]:
    raise SystemExit("Script self-tests must not build the app or run native tests")
if re.findall(r"(?m)^\s+run: (.+)$", sources["ci-package.yml"]) != ["make build-ci-package"]:
    raise SystemExit("The HeelerSSH build must only compile the package and its tests")
if any("name: " + full in diagnostics for full in names.values()):
    raise SystemExit("Only full verification may publish full coverage check names")

# Compare whole tokens: the checkout path may contain words such as `test`.
actions = {"build", "build-for-testing", "test", "test-without-building", "analyze", "archive", "clean"}
for target, scheme in [("build-ci-app", "Heeler"), ("build-ci-package", "HeelerSSH")]:
    command = subprocess.check_output(
        ["make", "--no-print-directory", "-n", target],
        cwd=workflows.resolve().parents[1], text=True)
    tokens = shlex.split(command.replace("\\\n", " "))
    if any(Path(token).name in {"xcodegen", "simctl"} for token in tokens) or "xcodebuild" not in tokens:
        raise SystemExit(f"{target} must run xcodebuild on the committed project without a Simulator")
    tokens = tokens[tokens.index("xcodebuild"):]
    if [token for token in tokens if token in actions] != ["build-for-testing"]:
        raise SystemExit(f"{target} must compile {scheme} and its tests without running them")
    if "-scheme" not in tokens or tokens[tokens.index("-scheme") + 1] != scheme:
        raise SystemExit(f"{target} must build the {scheme} scheme")
    if "-destination" not in tokens or tokens[tokens.index("-destination") + 1] != "generic/platform=iOS Simulator":
        raise SystemExit(f"{target} must not need a booted Simulator destination")
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

# Every macOS job builds with the release archive's runner and Xcode, so CI
# never checks a toolchain that nothing ships with, and every Simulator lane
# tests the same pinned iOS runtime (#634).
def settings(body, key):
    return re.findall(rf"(?m)^\s+{re.escape(key)}: (.+)$", body)

archive = job("archive", release)
toolchain = (settings(archive, "runs-on"), settings(archive, "DEVELOPER_DIR"))
if len(toolchain[0]) != 1 or len(toolchain[1]) != 1:
    raise SystemExit("The release archive must name one runner and one DEVELOPER_DIR")
simulator_lanes = {}
for path in sorted(workflows.glob("*.yml")):
    source = path.read_text()
    sections = re.split(r"(?m)^jobs:[ \t]*(?:#.*)?\n", source, maxsplit=1)
    if len(sections) == 1:
        if re.search(r"(?m)^jobs:", source):
            raise SystemExit(f"{path.name} has a jobs key this check cannot read")
        continue
    jobs = sections[1]
    headers = re.findall(r"(?m)^  [^\s#][^\n]*$", jobs)
    parsed = list(re.finditer(r"(?m)^  ([\w-]+):[ \t]*(?:#[^\n]*)?\n(.*?)(?=^  [^\s#]|\Z)", jobs, re.DOTALL))
    if not parsed or len(parsed) != len(headers):
        raise SystemExit(f"{path.name} has jobs this check cannot read")
    for match in parsed:
        name, body = f"{path.name} {match.group(1)}", match.group(2)
        runner = settings(body, "runs-on")
        if len(runner) != 1:
            raise SystemExit(f"{name} must name one runner")
        if runner[0].startswith("ubuntu-"):
            continue
        if (runner, settings(body, "DEVELOPER_DIR")) != toolchain:
            raise SystemExit(f"{name} must use the release archive's runner and Xcode")
        if re.search(r"\bmake test-ci-(?:app|package|diagnostics)\b", body):
            simulator_lanes[name] = settings(body, "HEELER_CI_SIMULATOR_OS")
if set(simulator_lanes) != {"ci-diagnostics.yml diagnose", "ci-full.yml app-tests",
                            "ci-full.yml heelerssh-package-e2e"}:
    raise SystemExit(f"Unexpected Simulator lanes: {sorted(simulator_lanes)}")
runtimes = {tuple(values) for values in simulator_lanes.values()}
if len(runtimes) != 1 or len(next(iter(runtimes))) != 1:
    raise SystemExit("Every Simulator lane must pin the same HEELER_CI_SIMULATOR_OS")
runner_script = (workflows.parent.parent / "scripts/run-ci-ios-tests.sh").read_text()
if not re.search(r"(?m)^ci_simulator_os=\"\$\{HEELER_CI_SIMULATOR_OS:-\}\"$", runner_script):
    raise SystemExit("run-ci-ios-tests.sh must read the pinned runtime from HEELER_CI_SIMULATOR_OS")
print("Passed fast build, full verification, scheduled alert, diagnostic isolation and toolchain contracts.")
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
