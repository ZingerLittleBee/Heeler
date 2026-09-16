#!/bin/bash
# Exercise the shipped recovery functions with fake CoreSimulator/xcodebuild
# boundaries, real device locks, and the real command watchdog.
# Use the gate's system Bash, including macOS Bash 3.2 empty-array behavior.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/heeler-simulator-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for function in run_xcodebuild run_suite list_simulator_candidates recover_simulator_destination \
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
esac
if [[ "$count" == 1 || "$SCENARIO" == persistent ]]; then
    echo 'xcodebuild: error: Unable to find a device matching the provided destination specifier:' >&2
    exit 70
fi
echo 'Test run with 1 tests in 1 suite passed'
STUB

cat > "$work/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/simctl"
case "$*" in
    'simctl list devices available')
        [[ "$SCENARIO" != list-failure ]] || exit 1
        cat "$CASE_DIR/devices"
        ;;
    'simctl bootstatus '*) [[ "$SCENARIO" != boot-failure ]] ;;
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
    export SCENARIO=$1
    export CASE_DIR="$work/$SCENARIO"
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
    local status=0
    if [[ "$SCENARIO" == suite ]]; then
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
            # Subsequent actions must inherit the recovered destination.
            run_xcodebuild next 10 "$CASE_DIR/next.log" test-without-building \
                -destination "$simulator_destination" >> "$CASE_DIR/output" 2>&1
            tail -n 1 "$CASE_DIR/arguments" | grep -qF "id=$simulator_udid" || fail 'next action used stale UDID'
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
            [[ ! -e "$CASE_DIR/simctl" ]] || fail 'non-destination failure touched simulator'
            ;;
        *)
            [[ "$status" == 70 ]] || fail 'missing destination status lost'
            local expected_calls=1
            [[ "$SCENARIO" != persistent ]] || expected_calls=3
            [[ "$(cat "$CASE_DIR/calls")" == "$expected_calls" ]] || fail 'retry was not bounded'
            grep -qF "recovery exhausted for UDID $ORIGINAL" "$CASE_DIR/output" || fail 'missing UDID diagnostic'
            [[ "$(grep -cF 'simctl list devices available' "$CASE_DIR/simctl")" == 3 ]] || fail 'expected two rediscoveries and final live listing'
            ;;
    esac
    release_resource_lock "$device_lock_dir" simulator
    printf 'PASS %s\n' "$SCENARIO"
    case_completed=1
)

for scenario in same pinned-other-name replacement occupied package suite no-devices persistent \
    test-failure other-70 watchdog-status explicit-pin boot-failure env-failure list-failure; do
    run_case "$scenario"
done
echo 'Passed 15 simulator recovery scenarios.'
