#!/bin/bash
# Exercise the shipped recovery functions with fake CoreSimulator/xcodebuild
# boundaries, real device locks, and the real command watchdog.
# Use the gate's system Bash, including macOS Bash 3.2 empty-array behavior.
# Cases intentionally isolate exported boundary variables in subshells. The
# dynamically extracted shipped functions consume the globals and stubs below.
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
set -euo pipefail

# Mock boundaries must not opt into a native worker's evidence or build
# settings. Keep intentionally exercised evidence in this harness's temp tree.
for inherited_setting in "${!HEELER_CI_@}" "${!HEELER_XCODEBUILD_@}"; do
    [[ -z "$inherited_setting" ]] || unset "$inherited_setting"
done
unset inherited_setting

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-simulator-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for function in prepare_evidence_directory record_phase start_background_build cancel_background_build run_app_fixture_suites assert_behavior run_xcodebuild run_suite list_simulator_candidates recover_simulator_destination \
    claim_simulator claim_resource_lock release_resource_lock write_lock_owner \
    lock_is_stale acquire_claim_guard release_claim_guard \
    clear_simulator_environment push_simulator_environment; do
    body=$(awk -v fn="$function" '
        $0 == fn "() {" { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$repo_root/scripts/run-ci-ios-tests.sh")
    [[ -n "$body" ]] || { echo "Missing shipped function: $function" >&2; exit 1; }
    eval "$body"
done

mkdir -p "$work/bin"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -eu
count=$(cat "$CASE_DIR/calls" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$CASE_DIR/calls"
printf '%s\n' "$PWD $*" >> "$CASE_DIR/arguments"
case "$SCENARIO" in
    test-failure) echo 'Test failed'; exit 65 ;;
    other-70) echo 'Unrelated destination configuration error'; exit 70 ;;
    watchdog-status) exit 124 ;;
    background-stall)
        exec python3 - "$CASE_DIR" <<'PYCHILD'
import os, signal, sys, time
from pathlib import Path
root = Path(sys.argv[1])
def terminate(_signum, _frame):
    (root / "cancel-order").write_text("fixture-present" if (root / "fixture").exists() else "fixture-removed")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, terminate)
(root / "build-child.pid").write_text(str(os.getpid()))
while True:
    time.sleep(0.05)
PYCHILD
        ;;
esac
if [[ "$count" == 1 || "$SCENARIO" == persistent ]]; then
    echo 'xcodebuild: error: Unable to find a device matching the provided destination specifier:' >&2
    exit 70
fi
while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == -resultBundlePath ]]; then
        [[ "$#" -gt 1 ]] || exit 2
        mkdir -p "$2"
        shift
    fi
    shift
done
echo 'Test run with 1 tests in 1 suite passed'
STUB

cat > "$work/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/simctl"
case "$*" in
    'xcresulttool get test-results summary --path '*' --compact')
        [[ -d "$6" ]] || exit 1
        printf '%s\n' '{"totalTestCount":1,"skippedTests":0,"failedTests":0,"result":"Passed"}'
        ;;
    'xcresulttool get test-results tests --path '*' --compact')
        [[ -d "$6" ]] || exit 1
        printf '%s\n' '{"testNodes":[{"nodeType":"Unit test bundle","name":"HeelerTests","children":[{"nodeType":"Test Suite","name":"ExampleSuite","children":[{"nodeType":"Test Case","name":"example()","nodeIdentifier":"ExampleSuite/example()","result":"Passed"}]}]}]}'
        ;;
    'simctl list devices available')
        [[ "$SCENARIO" != list-failure ]] || exit 1
        cat "$CASE_DIR/devices"
        ;;
    # The device boots for the first attempt (the app-lane runner boots it
    # too); after the loss it never comes back.
    'simctl bootstatus '*) [[ "$SCENARIO" != boot-failure || ! -e "$CASE_DIR/calls" ]] ;;
    # run-app-simulator-tests.py reads the accessibility preferences before
    # each app-lane attempt; an empty domain is a valid answer.
    'simctl spawn '*' defaults export com.apple.Accessibility -')
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n'
        ;;
    *'launchctl setenv HEELER_SSH_E2E_REQUIRED '*) [[ "$SCENARIO" != env-failure ]] ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$work/bin/xcodebuild" "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
export HEELER_TIMEOUT_DISABLE_SAMPLE=1
export ORIGINAL=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
export REPLACEMENT=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
export OCCUPIED=CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC

fail() { echo "FAIL $SCENARIO: $*" >&2; exit 1; }
# Avoid delays in the test; simulator recovery still runs the shipped loop.
sleep() { :; }

run_case() (
    local case_name=$1
    local overlap_case=0
    export SCENARIO=$case_name
    case "$case_name" in overlap-*) overlap_case=1; SCENARIO=${case_name#overlap-} ;; esac
    export CASE_DIR="$work/$case_name"
    mkdir -p "$CASE_DIR/locks" "$CASE_DIR/fixture"
    # A nounset exit can run the trap before a command's redirects unwind.
    # Keep diagnostics off that command's capture file.
    exec 3>&2
    local case_completed=0
    local case_status=0
    trap 'case_status=$?; if [[ "$case_status" != 0 || "$case_completed" != 1 ]]; then
        echo "FAIL $SCENARIO: assertions did not complete (exit $case_status)" >&3
        cat "$CASE_DIR/output" >&3 2>/dev/null || true
        exit 1
    fi' EXIT
    # These variables are consumed by extracted functions, not by eval here.
    # shellcheck disable=SC2034
    {
        ci_lane=app
        ci_app_shard=all
        overlap_build=1
        background_build_pid=""
        evidence_dir=""
        xcodebuild_build_timeout_seconds=10
        source_packages_dir="$CASE_DIR/packages"
        fixture_dir="$CASE_DIR/fixture"
        diagnostic_root="$CASE_DIR/diagnostics"
        app_derived_data_path="$CASE_DIR/app"
        package_derived_data_path="$CASE_DIR/package"
        lock_root="$CASE_DIR/locks"
        lock_owner_token=ours
        lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"
        active_resource_lock=""
        active_claim_guard=""
        device_lock_dir=""
        requested_simulator_udid=""
        simulator_environment_variables=()
        ci_simulator_name='iPhone 17'
        xcodebuild_test_timeout_seconds=10
        pinned_lane_logs=()
    }
    simulator_udid=$ORIGINAL
    simulator_destination="platform=iOS Simulator,id=$ORIGINAL"
    claim_simulator "$ORIGINAL"
    printf '    iPhone 17 (%s) (Shutdown)\n' "$ORIGINAL" > "$CASE_DIR/devices"
    case "$SCENARIO" in
        replacement | occupied | explicit-pin | package | suite)
            printf '    iPhone 17 (%s) (Shutdown)\n' "$REPLACEMENT" > "$CASE_DIR/devices"
            # A similarly named model is never an eligible replacement.
            printf '    iPhone 17 Pro (%s) (Shutdown)\n' "$OCCUPIED" >> "$CASE_DIR/devices"
            ;;
        no-devices) echo '== Devices ==' > "$CASE_DIR/devices" ;;
    esac
    if [[ "$SCENARIO" == occupied ]]; then
        mkdir "$lock_root/device-$OCCUPIED"
        write_lock_owner "$lock_root/device-$OCCUPIED"
        echo other > "$lock_root/device-$OCCUPIED/token"
        printf '    iPhone 17 (%s) (Shutdown)\n' "$OCCUPIED" >> "$CASE_DIR/devices"
    fi
    # shellcheck disable=SC2034
    [[ "$SCENARIO" != explicit-pin ]] || requested_simulator_udid=$ORIGINAL
    if [[ "$SCENARIO" == pinned-other-name ]]; then
        # shellcheck disable=SC2034
        requested_simulator_udid=$ORIGINAL
        printf '    iPad Pro 13-inch (M5) (%s) (Shutdown)\n' "$ORIGINAL" > "$CASE_DIR/devices"
    fi
    # shellcheck disable=SC2034
    [[ "$SCENARIO" != package ]] || ci_lane=package
    if [[ "$SCENARIO" == replacement || "$SCENARIO" == env-failure || "$SCENARIO" == package ]]; then
        export HEELER_SSH_E2E_REQUIRED=1 HEELER_SSH_E2E_HOST=127.0.0.1
        # Equivalent to a previously successful environment push. The failure
        # case fails only while reapplying it during destination recovery.
        # shellcheck disable=SC2034
        simulator_environment_variables=(HEELER_SSH_E2E_REQUIRED HEELER_SSH_E2E_HOST)
    fi
    if [[ "$case_name" == overlap-replacement ]]; then
        export HEELER_CI_DISABLE_DEBUG_SYMBOLS=1
    fi
    local status=0
    if [[ "$overlap_case" == 1 ]]; then
        start_background_build first
        [[ -n "$background_build_pid" ]] || fail 'build was not started during preparation'
        run_xcodebuild first 10 "$CASE_DIR/lane.log" build-for-testing \
            -scheme Heeler -derivedDataPath "$app_derived_data_path" \
            -destination "$simulator_destination" > "$CASE_DIR/output" 2>&1 || status=$?
        [[ -z "$background_build_pid" ]] || fail 'joined build PID still owned'
        [[ -s "$fixture_dir/background-build-timing.json" ]] || fail 'build elapsed metadata missing'
    elif [[ "$SCENARIO" == suite ]]; then
        run_suite first 1 1 0 ExampleSuite > "$CASE_DIR/output" 2>&1 || status=$?
        cp "$fixture_dir/first.log" "$CASE_DIR/lane.log"
        [[ "${#pinned_lane_logs[@]}" == 1 ]] || fail 'suite log was not registered'
    else
        run_xcodebuild first 10 "$CASE_DIR/lane.log" test-without-building \
            -destination "$simulator_destination" > "$CASE_DIR/output" 2>&1 || status=$?
    fi
    case "$SCENARIO" in
        same | pinned-other-name | replacement | occupied | package | suite)
            [[ "$status" == 0 && "$(cat "$CASE_DIR/calls")" == 2 ]] || fail 'expected one retry and success'
            grep -qF 'Test run with 1 test' "$CASE_DIR/lane.log" || fail 'missing passing log'
            if grep -qF 'Unable to find' "$CASE_DIR/lane.log"; then fail 'failed attempt contaminated gate log'; fi
            [[ -s "$fixture_dir/first-attempt-1.log" ]] || fail 'first failure log lost'
            if [[ "$SCENARIO" != same && "$SCENARIO" != pinned-other-name ]]; then
                [[ "$simulator_udid" == "$REPLACEMENT" ]] || fail 'replacement did not reach calling shell'
                [[ "$device_lock_dir" == "$lock_root/device-$REPLACEMENT" ]] || fail 'cleanup lock is stale'
                [[ ! -d "$lock_root/device-$ORIGINAL" ]] || fail 'old lock leaked'
            fi
            if [[ "$overlap_case" == 1 ]]; then
                local build_arguments
                local attempt
                for attempt in 1 2; do
                    build_arguments=$(sed -n "${attempt}p" "$CASE_DIR/arguments")
                    [[ " $build_arguments " == *' build-for-testing '* ]] || fail 'expected background build and foreground retry'
                    if [[ "$case_name" == overlap-replacement ]]; then
                        [[ " $build_arguments " == *' GCC_GENERATE_DEBUGGING_SYMBOLS=NO '* ]] || fail "build attempt $attempt lost opt-in debug symbol setting"
                    else
                        [[ "$build_arguments" != *GCC_GENERATE_DEBUGGING_SYMBOLS=* ]] || fail "build attempt $attempt disabled debug symbols without opt-in"
                    fi
                done
            fi
            # Subsequent actions must inherit the recovered destination.
            run_xcodebuild next 10 "$CASE_DIR/next.log" test-without-building \
                -destination "$simulator_destination" >> "$CASE_DIR/output" 2>&1
            tail -n 1 "$CASE_DIR/arguments" | grep -qF "id=$simulator_udid" || fail 'next action used stale UDID'
            if [[ "$overlap_case" == 1 ]]; then
                build_arguments=$(tail -n 1 "$CASE_DIR/arguments")
                [[ " $build_arguments " == *' test-without-building '* ]] || fail 'subsequent action rebuilt tests'
                [[ "$build_arguments" != *GCC_GENERATE_DEBUGGING_SYMBOLS=* ]] || fail 'test action inherited build-only debug symbol setting'
            fi
            if [[ "$SCENARIO" == replacement || "$SCENARIO" == package ]]; then
                grep -qF "simctl spawn $REPLACEMENT launchctl setenv HEELER_SSH_E2E_REQUIRED 1" "$CASE_DIR/simctl" || fail 'fixture environment was not restored'
            fi
            if [[ "$SCENARIO" == occupied ]]; then
                [[ "$(cat "$lock_root/device-$OCCUPIED/token")" == other ]] || fail 'another owner was disturbed'
            fi
            if [[ "$SCENARIO" == package ]]; then
                grep -qF "$repo_root/Packages/HeelerSSH test-without-building" "$CASE_DIR/arguments" || fail 'wrong package working directory'
            fi
            ;;
        test-failure | other-70 | watchdog-status)
            local expected=65
            [[ "$SCENARIO" != other-70 ]] || expected=70
            [[ "$SCENARIO" != watchdog-status ]] || expected=124
            [[ "$status" == "$expected" && "$(cat "$CASE_DIR/calls")" == 1 ]] || fail 'non-destination failure retried or changed'
            # The app-lane runner's accessibility preparation is expected;
            # rediscovery is not.
            ! grep -qF 'simctl list devices available' "$CASE_DIR/simctl" 2>/dev/null \
                || fail 'non-destination failure rediscovered simulators'
            ;;
        *)
            [[ "$status" == 70 ]] || fail 'missing destination status lost'
            local expected_calls=1
            [[ "$SCENARIO" != persistent ]] || expected_calls=4
            [[ "$(cat "$CASE_DIR/calls")" == "$expected_calls" ]] || fail 'retry was not bounded'
            grep -qF "recovery exhausted for UDID $ORIGINAL" "$CASE_DIR/output" || fail 'missing UDID diagnostic'
            [[ "$(grep -cF 'simctl list devices available' "$CASE_DIR/simctl")" == 4 ]] || fail 'expected three rediscoveries and final live listing'
            if [[ "$SCENARIO" != list-failure ]]; then
                grep -qF 'Simulators visible while recovering' "$CASE_DIR/output" || fail 'rediscovery did not record the live listing'
            fi
            ;;
    esac
    release_resource_lock "$device_lock_dir" simulator
    printf 'PASS %s\n' "$case_name"
    case_completed=1
)

# A single recovery plus subsequent action exercises the actual shipped app
# wrapper under inherited worker settings without repeating all scenarios.
case "${1:-}" in
    --inherited-env-probe)
        run_case same
        echo 'Passed inherited CI environment recovery probe.'
        exit 0
        ;;
    "") ;;
    *) echo "Unknown recovery test option: $1" >&2; exit 2 ;;
esac

for scenario in same pinned-other-name replacement occupied package suite no-devices persistent \
    test-failure other-70 watchdog-status explicit-pin boot-failure env-failure list-failure \
    overlap-replacement overlap-persistent overlap-test-failure overlap-other-70 \
    overlap-watchdog-status overlap-package; do
    run_case "$scenario"
done
echo 'Passed 21 simulator recovery scenarios.'

# Exercise the shipped shard dispatcher with fake test/process boundaries.
# This proves invocation order and ownership, including failure before Weak.
run_shard_case() (
    local shard=$1
    ci_app_shard=$shard
    fixture_dir="$work/shard-$shard"
    mkdir -p "$fixture_dir"
    password_fixture_available=1
    password_pid=42
    password_pid_file="$fixture_dir/password.pid"
    session_skip_count=0
    run_suite() { printf 'suite %s\n' "$*" >> "$fixture_dir/events"; }
    start_password_sshd() { echo start-password >> "$fixture_dir/events"; }
    stop_privileged_sshd() { echo stop-password >> "$fixture_dir/events"; }
    run_app_fixture_suites
    case "$shard" in
        session-weak)
            cat > "$fixture_dir/expected" <<'EXPECTED'
start-password
suite HeelerSSHSessionE2ETests 13 1 0 HeelerSSHSessionE2ETests
stop-password
suite WeakNetworkE2ETests 10 1 0 WeakNetworkE2ETests
EXPECTED
            [[ -z "$password_pid" ]] || fail 'password sshd ownership survived Session'
            ;;
        transport)
            cat > "$fixture_dir/expected" <<'EXPECTED'
suite HeelerSSHDirectStreamLocalE2ETests 9 1 0 HeelerSSHDirectStreamLocalE2ETests
suite SharedFixtureE2ETests 106 6 0 HeelerSSHPTYE2ETests HeelerSSHJumpHostGateE2ETests HeelerSSHTransportBehaviorE2ETests ChangesFieldHostE2ETests ImageStagingE2ETests PairingCeremonyE2ETests
EXPECTED
            [[ ! -e "$fixture_dir/WeakNetworkE2ETests.log" ]] || fail 'transport included Weak'
            ;;
        all)
            cat > "$fixture_dir/expected" <<'EXPECTED'
start-password
suite HeelerSSHSessionE2ETests 13 1 0 HeelerSSHSessionE2ETests
stop-password
suite HeelerSSHDirectStreamLocalE2ETests 9 1 0 HeelerSSHDirectStreamLocalE2ETests
suite SharedFixtureE2ETests 116 7 0 HeelerSSHPTYE2ETests HeelerSSHJumpHostGateE2ETests HeelerSSHTransportBehaviorE2ETests ChangesFieldHostE2ETests ImageStagingE2ETests WeakNetworkE2ETests PairingCeremonyE2ETests
EXPECTED
            ;;
        ordinary)
            [[ ! -e "$fixture_dir/events" ]] || fail 'ordinary started fixture test/process'
            printf 'PASS shard-%s\n' "$shard"
            exit 0
            ;;
    esac
    diff -u "$fixture_dir/expected" "$fixture_dir/events" || fail 'shard order, selectors, counts, or process ownership drifted'
    printf 'PASS shard-%s\n' "$shard"
)
for shard in all session-weak transport ordinary; do run_shard_case "$shard"; done

(
    ci_app_shard=session-weak
    fixture_dir="$work/session-failure"
    mkdir -p "$fixture_dir"
    password_fixture_available=1
    password_pid=42
    password_pid_file="$fixture_dir/password.pid"
    session_skip_count=0
    start_password_sshd() { :; }
    stop_privileged_sshd() { echo stop >> "$fixture_dir/events"; }
    run_suite() { echo "$1" >> "$fixture_dir/events"; return 65; }
    status=0
    run_app_fixture_suites || status=$?
    [[ "$status" == 65 ]] || fail 'Session failure status was changed'
    [[ "$(cat "$fixture_dir/events")" == HeelerSSHSessionE2ETests ]] || fail 'Weak ran after failed Session'
    [[ "$password_pid" == 42 ]] || fail 'failed Session lost password process cleanup ownership'
    echo 'PASS shard-session-failure'
)

for shard in all session-weak transport ordinary; do
    (
        ci_app_shard=$shard
        fixture_dir="$work/behavior-$shard"
        mkdir -p "$fixture_dir"
        case "$shard" in
            all | ordinary) owned=full-lane ;;
            session-weak) owned=WeakNetworkE2ETests ;;
            transport) owned=HeelerSSHTransportBehaviorE2ETests ;;
        esac
        if (assert_behavior example "$owned" example) > "$fixture_dir/failure" 2>&1; then
            fail 'missing owned behavior passed'
        fi
        grep -qF 'Mandatory behaviour not proven' "$fixture_dir/failure" || fail 'wrong owned failure'
        printf 'Test example passed\n' > "$fixture_dir/$owned.log"
        assert_behavior example "$owned" example
        if [[ "$shard" != all ]]; then
            unowned=HeelerSSHSessionE2ETests
            [[ "$shard" != session-weak ]] || unowned=full-lane
            assert_behavior delegated "$unowned" absent
        fi
        printf 'PASS shard-behavior-%s\n' "$shard"
    )
done
echo 'Passed 9 shard dispatch and named behavior scenarios.'

# Preparation failure and parent cancellation must reap the real owned build
# before deleting its products and fixture. CoreSimulator is mocked here.
for function in cleanup preserve_failure_diagnostics dump_fixture_logs; do
    body=$(awk -v fn="$function" '
        $0 == fn "() {" { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$repo_root/scripts/run-ci-ios-tests.sh")
    [[ -n "$body" ]] || fail "missing cleanup function $function"
    eval "$body"
done
for reason in preparation-failure parent-cancellation; do
    (
        export SCENARIO=background-stall
        export CASE_DIR="$work/$reason"
        mkdir -p "$CASE_DIR/fixture"
        fixture_dir="$CASE_DIR/fixture"
        ci_lane=app
        ci_app_shard=all
        overlap_build=1
        source_packages_dir="$CASE_DIR/packages"
        app_derived_data_path="$fixture_dir/AppDerivedData"
        package_derived_data_path="$fixture_dir/PackageDerivedData"
        xcodebuild_build_timeout_seconds=10
        diagnostic_root=""
        evidence_dir=""
        background_build_pid=""
        simulator_destination="platform=iOS Simulator,id=$ORIGINAL"
        simulator_udid=""
        simulator_environment_variables=()
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_log="$fixture_dir/password.log"
        password_log_printed=0
        password_user_cleanup_needed=0
        active_claim_guard=""
        active_resource_lock=""
        account_lock_dir=""
        run_lock_dir=""
        device_lock_dir=""
        start_background_build first
        for _ in $(seq 1 100); do
            [[ -s "$CASE_DIR/build-child.pid" ]] && break
            /bin/sleep 0.02
        done
        [[ -s "$CASE_DIR/build-child.pid" ]] || fail 'build did not start'
        # Keep these traps identical to the shipped parent entrypoint.
        trap cleanup EXIT
        trap 'exit 143' TERM
        if [[ "$reason" == parent-cancellation ]]; then
            python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
        else
            exit 1
        fi
    ) > "$work/$reason.log" 2>&1 &
    case_pid=$!
    status=0
    wait "$case_pid" || status=$?
    expected=1
    [[ "$reason" != parent-cancellation ]] || expected=143
    [[ "$status" == "$expected" ]] || { cat "$work/$reason.log" >&2; fail "$reason changed parent exit status $status"; }
    [[ "$(cat "$work/$reason/cancel-order")" == fixture-present ]] || fail 'fixture deleted before build reaped'
    [[ ! -d "$work/$reason/fixture" ]] || fail 'fixture not cleaned after build cancellation'
    ! kill -0 "$(cat "$work/$reason/build-child.pid")" 2>/dev/null || fail 'owned build child survived cleanup'
    printf 'PASS overlap-%s\n' "$reason"
done
echo 'Passed 2 owned build cleanup scenarios.'

for scenario in new settings stale-phase stale-worker stale-metrics unexpected symlink; do
    (
        directory="$work/evidence-$scenario"
        case "$scenario" in
            new) ;;
            *) mkdir -p "$directory" ;;
        esac
        case "$scenario" in
            settings) echo 'layout=sharded' > "$directory/run-settings.txt" ;;
            stale-phase) echo '{}' > "$directory/phase-full-lane.json" ;;
            stale-worker) echo '{}' > "$directory/worker-app-ordinary.json" ;;
            stale-metrics) mkdir "$directory/metrics" ;;
            unexpected) touch "$directory/unexpected" ;;
            symlink) ln -s "$work" "$directory/run-settings.txt" ;;
        esac
        status=0
        prepare_evidence_directory "$directory" > "$work/evidence-$scenario.log" 2>&1 || status=$?
        case "$scenario" in
            new | settings) [[ "$status" == 0 ]] || fail 'fresh evidence rejected' ;;
            *)
                [[ "$status" != 0 ]] || fail 'stale or unexpected evidence accepted'
                grep -qF 'CI evidence directory must be fresh' "$work/evidence-$scenario.log" || fail 'wrong evidence startup failure'
                ;;
        esac
        printf 'PASS evidence-startup-%s\n' "$scenario"
    )
done
echo 'Passed 7 fresh evidence directory scenarios.'
