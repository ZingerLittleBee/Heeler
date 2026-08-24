#!/bin/bash
#
# Merge-gate fixture plus the iOS Simulator test run.
#
# Every sshd instance runs unprivileged: as the invoking user, on a loopback
# high port, out of one disposable directory. No sudo, no system SSH service,
# no machine state to undo. `SetEnv HOME=` gives each session an isolated home
# so nothing here can reach a real herdr socket, and a forced POSIX-sh wrapper
# puts a herdr stub ahead of PATH so the cold-start wake can never start or talk
# to a live server. The weak-network route is unprivileged for the same reason:
# a TCP proxy in front of one sshd, steered per test, rather than `pfctl` or a
# machine-wide Network Link Conditioner.
#
# One exception. macOS cannot verify a password without root, and an
# unprivileged sshd can only authenticate the account it already runs as, whose
# password CI does not know. The two real-password tests therefore need a
# disposable account and one root-owned sshd, provisioned only when passwordless
# sudo is available. Merge CI has it and demands it (HEELER_CI_MANDATORY=1);
# a developer laptop without it still runs twelve of the thirteen mandatory
# behaviours, and the script says loudly which one it left out.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# The gate must leave the worktree byte-identical: this workflow treats a clean
# worktree as a verification precondition, so a stray `__pycache__` beside the
# Python fixtures is a standing false signal. `.gitignore` covers it too; this
# stops it being written in the first place.
export PYTHONDONTWRITEBYTECODE=1

# Fixture ports are a contiguous block that a run claims at startup rather than
# twelve fixed numbers every run shares. Fixed numbers made this script a
# machine-wide mutex: whichever run started second failed its port preflight and
# could only wait for the first to finish.
#
# assign_port_block below is the one place the ports are named; sshd configs,
# the impairment proxy's arguments and the JSON handed to the tests all read the
# variables it sets, so moving the base moves the whole fixture.

# Must equal the number of ports assign_port_block sets; assign_port_block
# asserts that itself rather than trusting this comment.
port_block_size=12
# The historical block. A run that finds the machine idle still lands exactly
# here, so the common case is unchanged.
port_block_base_default=55222
# How many disjoint blocks the machine hands out before it refuses to guess.
port_block_count=8
# Pin a block explicitly, for a caller that would rather not negotiate.
port_block_base_override="${HEELER_CI_PORT_BASE:-}"

# Cross-run coordination lives here: one owned lock per port block, Simulator,
# or account-allocation critical section. A short-lived atomic claim guard
# serializes owner publication, stale reclamation, and token-checked release.
# Ports still decide whether a block is usable; these locks only let a run say
# what it holds, and let the next run tell "someone is working" apart from
# "something crashed".
lock_root=/tmp/heeler-ci-locks
run_lock_dir=""
device_lock_dir=""
account_lock_dir=""
active_claim_guard=""
active_resource_lock=""
lock_owner_token="$$-$(uuidgen)"
lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"

# AF_UNIX paths cap at 104 bytes on macOS and the fixture nests herdr sockets
# several directories deep, so anchor at /tmp: the per-user TMPDIR alone is
# already 69 characters and overflows the limit.
fixture_dir="$(mktemp -d /tmp/heeler-ci.XXXXXX)"
app_derived_data_path="$fixture_dir/AppDerivedData"
package_derived_data_path="$fixture_dir/PackageDerivedData"
diagnostic_run_id="${GITHUB_RUN_ID:-local-$$}"
diagnostic_attempt="${GITHUB_RUN_ATTEMPT:-1}"
diagnostic_root="${RUNNER_TEMP:-/tmp}/heeler-ci-diagnostics-$diagnostic_run_id-$diagnostic_attempt"
xcodebuild_build_timeout_seconds="${HEELER_XCODEBUILD_BUILD_TIMEOUT_SECONDS:-900}"
xcodebuild_test_timeout_seconds="${HEELER_XCODEBUILD_TEST_TIMEOUT_SECONDS:-600}"
fixture_username="$(id -un)"
fixture_home="$fixture_dir/home"
modern_pid=""
legacy_pid=""
restricted_pid=""
stall_pid=""
streamlocal_global_policy_pid=""
streamlocal_key_policy_pid=""
jump_target_pid=""
jump_forwarding_denied_pid=""
pairing_pid=""
pairing_mismatched_pid=""
password_pid=""
fake_herdr_pid=""
weak_network_pid=""
simulator_udid=""
simulator_destination=""

# The privileged password fixture, provisioned only when sudo -n works.
password_username=""
password_secret=""
password_home=""
password_uid=550
password_fixture_available=0
password_user_cleanup_needed=0
password_ssh_sacl_added=0
password_pid_file="$fixture_dir/sshd-password.pid"
password_log="$fixture_dir/sshd-password.log"
password_log_printed=0

# Merge CI must run the complete mandatory matrix; a laptop need not.
mandatory_matrix=0
case "${HEELER_CI_MANDATORY:-${CI:-}}" in
    1 | true | TRUE) mandatory_matrix=1 ;;
esac

unprivileged_sshd_pids=()

run_xcodebuild() {
    local label=$1
    local timeout_seconds=$2
    local safe_label
    local status
    local started_at=$SECONDS
    shift 2

    safe_label=$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '-')
    echo "::group::$label"
    if "$repo_root/scripts/run-with-timeout.py" \
        --timeout-seconds "$timeout_seconds" \
        --label "$label" \
        --diagnostics-dir "$diagnostic_root/$safe_label" \
        --artifact-path "$app_derived_data_path/Logs/Test" \
        --artifact-path "$package_derived_data_path/Logs/Test" \
        --artifact-glob "$fixture_dir/*.log" \
        -- xcodebuild "$@"; then
        status=0
    else
        status=$?
    fi
    echo "::endgroup::"
    echo "==> $label: $((SECONDS - started_at))s (status $status)"
    return "$status"
}

write_lock_owner() {
    local lock=$1

    printf '%s' "$lock_owner_token" > "$lock/token"
    printf '%s' "$$" > "$lock/pid"
    printf '%s' "$lock_owner_start" > "$lock/start"
}

lock_is_stale() {
    local lock=$1
    local owner
    local expected_start
    local actual_start

    owner=$(cat "$lock/pid" 2>/dev/null)
    expected_start=$(cat "$lock/start" 2>/dev/null)
    if [[ -z "$owner" || -z "$expected_start" ]]; then
        return 0
    fi
    actual_start=$(ps -o lstart= -p "$owner" 2>/dev/null \
        | sed 's/^ *//; s/ *$//')
    [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] \
        && return 1
    return 0
}

# Serializes inspection and replacement of one resource lock. The guard is
# never reclaimed automatically: if a gate is killed inside this tiny critical
# section, a later run reports it and asks the operator to remove it. That is
# safer than one run deleting a guard another run has just acquired.
acquire_claim_guard() {
    local lock=$1
    local description=$2
    local guard="$lock.claiming"
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if mkdir "$guard" 2>/dev/null; then
            active_claim_guard="$guard"
            printf '%s' "$lock_owner_token" > "$guard/token"
            return 0
        fi
        sleep 0.05
    done
    printf 'Cannot claim %s: another run is changing its lock.\n' \
        "$description" >&2
    printf 'If no gate is starting, report and remove orphaned guard %s manually.\n' \
        "$guard" >&2
    return 1
}

release_claim_guard() {
    local guard=$1
    local token

    token=$(cat "$guard/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" \
        || "$active_claim_guard" == "$guard" ]]; then
        rm -f -- "$guard/token"
        rmdir "$guard"
    fi
    if [[ "$active_claim_guard" == "$guard" ]]; then
        active_claim_guard=""
    fi
}

claim_resource_lock() {
    local lock=$1
    local description=$2
    local owner
    local claim_status=1

    active_resource_lock="$lock"
    if ! acquire_claim_guard "$lock" "$description"; then
        active_resource_lock=""
        return 1
    fi
    if [[ ! -d "$lock" ]]; then
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    elif lock_is_stale "$lock"; then
        owner=$(cat "$lock/pid" 2>/dev/null)
        printf 'Reclaiming the stale lock on %s (owner pid %s is gone)\n' \
            "$description" "${owner:-unknown}" >&2
        rm -rf -- "$lock"
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    fi
    release_claim_guard "$active_claim_guard"
    active_resource_lock=""
    return "$claim_status"
}

release_resource_lock() {
    local lock=$1
    local description=$2
    local token

    [[ -n "$lock" && -d "$lock" ]] || return 0
    if ! acquire_claim_guard "$lock" "$description"; then
        return 1
    fi
    token=$(cat "$lock/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" ]]; then
        rm -rf -- "$lock"
    fi
    release_claim_guard "$active_claim_guard"
}

cleanup() {
    local status=$?
    local preserve_password_fixture=0
    trap - EXIT INT TERM
    set +e

    clear_simulator_environment
    if [[ -n "$stall_pid" ]]; then
        kill "$stall_pid" >/dev/null 2>&1
        wait "$stall_pid" 2>/dev/null
    fi
    if [[ -n "$fake_herdr_pid" ]]; then
        kill "$fake_herdr_pid" >/dev/null 2>&1
        wait "$fake_herdr_pid" 2>/dev/null
    fi
    if [[ -n "$weak_network_pid" ]]; then
        kill "$weak_network_pid" >/dev/null 2>&1
        wait "$weak_network_pid" 2>/dev/null
    fi
    local pid
    for pid in "${unprivileged_sshd_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" >/dev/null 2>&1
            wait "$pid" 2>/dev/null
        fi
    done
    if [[ -n "$password_pid" ]]; then
        if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
            password_pid=""
        else
            preserve_password_fixture=1
            if [[ "$status" -eq 0 ]]; then
                status=1
            fi
            echo "Failed to stop privileged sshd PID $password_pid." >&2
            echo "Preserving password account $password_username and fixture" \
                "directory $fixture_dir for diagnosis and manual cleanup." >&2
        fi
    fi
    if [[ "$status" -ne 0 && "$password_log_printed" != "1" \
        && -f "$password_log" ]]; then
        cat "$password_log" >&2
    fi
    if [[ "$preserve_password_fixture" != "1" ]]; then
        if [[ "$password_user_cleanup_needed" == "1" ]] \
            && dscl . -read "/Users/$password_username" >/dev/null 2>&1; then
            if [[ "$password_ssh_sacl_added" == "1" ]]; then
                if ! sudo -n /usr/sbin/dseditgroup -o edit \
                    -d "$password_username" -t user com.apple.access_ssh; then
                    preserve_password_fixture=1
                    if [[ "$status" -eq 0 ]]; then
                        status=1
                    fi
                    echo "Failed to remove password account $password_username from SSH access." >&2
                fi
            fi
            if [[ "$preserve_password_fixture" != "1" ]] \
                && ! sudo -n /usr/sbin/sysadminctl \
                    -deleteUser "$password_username" -keepHome; then
                preserve_password_fixture=1
                if [[ "$status" -eq 0 ]]; then
                    status=1
                fi
                echo "Failed to delete password account $password_username." >&2
            fi
        fi
    fi
    if [[ "$preserve_password_fixture" != "1" && -d "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi
    # Released last: while these stand, a concurrent run treats our block and
    # our device as taken. Dropping them after the fixtures are already down,
    # and after the simulator environment has been cleared, is the safe
    # ordering -- the device must not look free while it still holds our
    # HEELER_SSH_E2E_* variables.
    if [[ -n "$active_claim_guard" ]]; then
        if [[ -n "$active_resource_lock" && -d "$active_resource_lock" ]] \
            && [[ "$(cat "$active_resource_lock/token" 2>/dev/null)" \
                == "$lock_owner_token" ]]; then
            rm -rf -- "$active_resource_lock"
        fi
        release_claim_guard "$active_claim_guard"
    fi
    release_resource_lock "$account_lock_dir" "password account allocation" || true
    release_resource_lock "$run_lock_dir" "fixture port block" || true
    release_resource_lock "$device_lock_dir" "simulator" || true

    exit "$status"
}
trap cleanup EXIT INT TERM

# Clears the fixture environment from both the Simulator and this shell. The
# shell half matters: the Simulator test process inherits it, so unsetting only
# the launchd values leaves HEELER_SSH_E2E_REQUIRED visible and the
# fixture-backed suites fail instead of skipping once the fixture is gone.
clear_simulator_environment() {
    local variable
    local pid
    local unsetenv_pids=()
    for variable in \
        HEELER_SSH_E2E_REQUIRED \
        HEELER_SSH_E2E_HOST \
        HEELER_SSH_E2E_PORT \
        HEELER_SSH_E2E_USERNAME \
        HEELER_SSH_E2E_DEVICE_KEY_SEED \
        HEELER_SSH_E2E_WEAK_PORT \
        HEELER_SSH_E2E_WEAK_CONTROL_PORT \
        HEELER_SSH_E2E_LEGACY_PORT \
        HEELER_SSH_E2E_RESTRICTED_PORT \
        HEELER_SSH_E2E_STALL_PORT \
        HEELER_SSH_E2E_STREAMLOCAL_SOCKET \
        HEELER_SSH_E2E_CONFIG \
        HEELER_SSH_JUMP_E2E_CONFIG \
        HEELER_PAIRING_E2E_CONFIG; do
        # launchctl takes one variable per call and each `simctl spawn` costs
        # seconds; run the round trips concurrently and collect them below.
        if [[ -n "$simulator_udid" ]]; then
            xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$variable" \
                >/dev/null 2>&1 &
            unsetenv_pids+=("$!")
        fi
        unset "$variable"
    done
    for pid in "${unsetenv_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null
        fi
    done
}

# The setenv half of the same trade: a dozen serial `simctl spawn` round trips
# put most of a minute on the critical path. Values are read through variable
# indirection, so callers assign first and pass names. Every push is still
# checked -- under `set -e` a failed wait aborts the gate, exactly as the
# serial calls did.
push_simulator_environment() {
    local variable
    local pid
    local setenv_pids=()
    for variable in "$@"; do
        xcrun simctl spawn "$simulator_udid" launchctl setenv \
            "$variable" "${!variable}" &
        setenv_pids+=("$!")
    done
    for pid in "${setenv_pids[@]}"; do
        wait "$pid"
    done
}

stop_privileged_sshd() {
    local launcher_pid=$1
    local pid_file=$2
    local attempt
    local daemon_pid=""
    local launcher_state=""
    local target_pid=""

    if [[ -f "$pid_file" ]]; then
        daemon_pid="$(<"$pid_file")"
    fi
    if [[ "$daemon_pid" =~ ^[0-9]+$ ]]; then
        target_pid=$daemon_pid
    elif [[ "$launcher_pid" =~ ^[0-9]+$ ]]; then
        target_pid=$launcher_pid
    else
        return 0
    fi

    if sudo -n kill "$target_pid" 2>/dev/null; then
        for ((attempt = 0; attempt < 50; attempt += 1)); do
            if ! ps -p "$target_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        if ps -p "$target_pid" >/dev/null 2>&1; then
            return 1
        fi
    elif ps -p "$target_pid" >/dev/null 2>&1; then
        # Do not wait on a process that is still live: cleanup must retain its
        # state and report the failed stop instead of blocking indefinitely.
        return 1
    fi

    # sudo may remain as a distinct launcher after the daemon exits. Bash 3
    # has no bounded wait, so poll until that child is absent or a zombie
    # before reaping it. A live launcher after the deadline is a failed stop,
    # and cleanup must preserve its evidence without waiting on it.
    if [[ "$launcher_pid" =~ ^[0-9]+$ ]]; then
        for ((attempt = 0; attempt < 50; attempt += 1)); do
            launcher_state="$(ps -o state= -p "$launcher_pid" 2>/dev/null || true)"
            if [[ -z "$launcher_state" \
                || "$launcher_state" =~ ^[[:space:]]*Z ]]; then
                wait "$launcher_pid" 2>/dev/null || true
                break
            fi
            sleep 0.1
        done
        if [[ -n "$launcher_state" \
            && ! "$launcher_state" =~ ^[[:space:]]*Z ]]; then
            return 1
        fi
    fi

    ! ps -p "$target_pid" >/dev/null 2>&1
}

start_password_sshd() {
    local attempt

    # Start this short-lived root fixture only when its suite is ready to run.
    # The invoking shell intentionally owns the diagnostic log redirect.
    # shellcheck disable=SC2024
    sudo -n /usr/sbin/sshd -D -e -f "$password_config" \
        > "$password_log" 2>&1 &
    password_pid=$!

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if sudo -n kill -0 "$password_pid" >/dev/null 2>&1 \
            && nc -z 127.0.0.1 "$password_port" >/dev/null 2>&1; then
            return 0
        fi
        if ! sudo -n kill -0 "$password_pid" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
        password_pid=""
    fi
    cat "$password_log" >&2
    password_log_printed=1
    return 1
}

# Prove the disposable account through the same public boundary a Host uses.
# Expect owns a PTY but suppresses its transcript; only the exported secret is
# copied into Tcl, and it is removed from the child environment before ssh.
password_ssh_preflight() {
    local status

    export HEELER_PASSWORD_SSH_PREFLIGHT_PASSWORD="$password_secret"
    if /usr/bin/expect <<'EXPECT'
set timeout 5
log_user 0

set password $env(HEELER_PASSWORD_SSH_PREFLIGHT_PASSWORD)
unset env(HEELER_PASSWORD_SSH_PREFLIGHT_PASSWORD)

spawn /usr/bin/ssh \
    -F /dev/null \
    -T \
    -o PreferredAuthentications=password \
    -o PasswordAuthentication=yes \
    -o KbdInteractiveAuthentication=no \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=5 \
    -o ConnectionAttempts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p $env(HEELER_PASSWORD_SSH_PREFLIGHT_PORT) \
    -l $env(HEELER_PASSWORD_SSH_PREFLIGHT_USERNAME) \
    127.0.0.1 \
    /bin/echo HEELER_PASSWORD_SSH_PREFLIGHT_OK

expect {
    -re {(?i)password:[[:space:]]*$} {
        send -- "$password\r"
    }
    timeout { exit 1 }
    eof { exit 1 }
}

set saw_sentinel 0
expect {
    -exact {HEELER_PASSWORD_SSH_PREFLIGHT_OK} {
        set saw_sentinel 1
        exp_continue
    }
    -re {(?i)password:[[:space:]]*$} { exit 1 }
    timeout { exit 1 }
    eof {}
}

if {!$saw_sentinel} {
    exit 1
}
set child_status [wait]
exit [lindex $child_status 3]
EXPECT
    then
        status=0
    else
        status=$?
    fi
    unset HEELER_PASSWORD_SSH_PREFLIGHT_PASSWORD
    return "$status"
}

# sysadminctl owns creation of the complete local account record. Expect feeds
# its password prompt without putting the secret in argv, a file, the command
# transcript, or the sysadminctl environment.
create_password_user() (
    local status

    export HEELER_SYSADMINCTL_PASSWORD="$password_secret"
    export HEELER_SYSADMINCTL_USERNAME="$password_username"
    export HEELER_SYSADMINCTL_UID="$password_uid"
    export HEELER_SYSADMINCTL_HOME="$password_home"
    if /usr/bin/expect <<'EXPECT'
set timeout 30
log_user 0

set password $env(HEELER_SYSADMINCTL_PASSWORD)
unset env(HEELER_SYSADMINCTL_PASSWORD)

spawn /usr/bin/sudo -n /usr/sbin/sysadminctl \
    -addUser $env(HEELER_SYSADMINCTL_USERNAME) \
    -fullName {Heeler SSH CI} \
    -UID $env(HEELER_SYSADMINCTL_UID) \
    -GID 20 \
    -shell /bin/zsh \
    -home $env(HEELER_SYSADMINCTL_HOME) \
    -password -

set sent_password 0
expect {
    -re {(?i)password[^\r\n]*:[[:space:]]*$} {
        if {$sent_password} {
            close
            catch {wait}
            exit 1
        }
        send -- "$password\r"
        set sent_password 1
        exp_continue
    }
    timeout {
        close
        catch {wait}
        exit 1
    }
    eof {}
}

if {!$sent_password || [catch {wait} child_status]} {
    exit 1
}
if {[llength $child_status] < 4 || [lindex $child_status 2] ne "0"} {
    exit 1
}
if {[llength $child_status] >= 5 \
    && [lindex $child_status 4] eq "CHILDKILLED"} {
    exit 1
}
set child_exit [lindex $child_status 3]
if {![string is integer -strict $child_exit] \
    || $child_exit < 0 || $child_exit > 255} {
    exit 1
}
exit $child_exit
EXPECT
    then
        status=0
    else
        status=$?
    fi
    unset HEELER_SYSADMINCTL_PASSWORD
    unset HEELER_SYSADMINCTL_USERNAME
    unset HEELER_SYSADMINCTL_UID
    unset HEELER_SYSADMINCTL_HOME
    return "$status"
)

# Sets started_sshd_pid rather than printing it: a command substitution would
# run the append to unprivileged_sshd_pids in a subshell and lose it.
started_sshd_pid=""
start_unprivileged_sshd() {
    local config=$1
    local log=$2

    /usr/sbin/sshd -D -e -f "$config" > "$log" 2>&1 &
    started_sshd_pid=$!
    unprivileged_sshd_pids+=("$started_sshd_pid")
}

# The single place fixture ports are named. Every other reference in this
# script, and every port the tests are handed, comes from these twelve
# variables, so moving the base moves the whole fixture.
assign_port_block() {
    local base=$1
    local highest

    modern_port=$((base + 0))
    legacy_port=$((base + 1))
    restricted_port=$((base + 2))
    stall_port=$((base + 3))
    streamlocal_global_policy_port=$((base + 4))
    streamlocal_key_policy_port=$((base + 5))
    jump_target_port=$((base + 6))
    jump_forwarding_denied_port=$((base + 7))
    pairing_port=$((base + 8))
    password_port=$((base + 9))
    # The unprivileged impairment proxy: a degraded route to the modern sshd,
    # plus the control port the weak-network suite steers it through.
    weak_network_port=$((base + 10))
    weak_network_control_port=$((base + 11))

    # Adding a port above without widening port_block_size would overlap the
    # next block, which no test could distinguish from a flaky fixture.
    highest=$weak_network_control_port
    if [[ "$highest" -ne "$((base + port_block_size - 1))" ]]; then
        echo "assign_port_block assigns past port_block_size=$port_block_size" >&2
        exit 1
    fi
}

# The pairing fixture is reached over both loopback families, so a listener on
# either one is a genuine conflict. Checking both for every port costs nothing
# and can only ever reject a block, never wave a busy one through.
port_is_busy() {
    local port=$1

    nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
    nc -z ::1 "$port" >/dev/null 2>&1 && return 0
    return 1
}

# Names who holds a port, so a refusal can say more than "already in use".
# A listener whose parent is init was reparented when its run died: that is an
# orphan from a crashed gate, not a colleague mid-run. It is reported and never
# killed -- guessing wrong about ownership costs someone else their run.
describe_port_holder() {
    local port=$1
    local only_orphans=${2:-0}
    local pid
    local parent
    local command
    local described=1

    for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u); do
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        command=$(ps -o command= -p "$pid" 2>/dev/null)
        if [[ -z "$command" ]]; then
            continue
        fi
        if [[ "$parent" == "1" ]]; then
            described=0
            printf '      port %s: ORPHAN pid %s (reparented to init) %s\n' \
                "$port" "$pid" "$command" >&2
        elif [[ "$only_orphans" != "1" ]]; then
            described=0
            printf '      port %s: pid %s (parent %s) %s\n' \
                "$port" "$pid" "${parent:-unknown}" "$command" >&2
        fi
    done
    return "$described"
}

mkdir -p "$lock_root"

# Blocks are tried in order and the first wholly free one wins, so an idle
# machine is deterministic. Every rejection is recorded rather than fatal:
# if nothing is free the operator gets the whole picture at once instead of
# the first port that happened to be taken.
claim_port_block() {
    local -a bases=()
    local base
    local slot
    local busy
    local port
    local offset
    local lock
    local owner
    local -a rejections=()

    if [[ -n "$port_block_base_override" ]]; then
        bases=("$port_block_base_override")
    else
        for ((slot = 0; slot < port_block_count; slot += 1)); do
            bases+=("$((port_block_base_default + slot * port_block_size))")
        done
    fi

    for base in "${bases[@]}"; do
        lock="$lock_root/block-$base"
        busy=""
        for ((offset = 0; offset < port_block_size; offset += 1)); do
            port=$((base + offset))
            if port_is_busy "$port"; then
                busy+=" $port"
                # A run may move to the next free block, but an orphan from a
                # crashed gate still needs to be visible to the operator. It
                # is reported here and deliberately left untouched.
                describe_port_holder "$port" 1 || true
            fi
        done

        # Recorded as "<base> <kind> <detail...>". The kind is explicit because
        # the two rejections carry different trailing numbers -- ports for one,
        # a pid for the other -- and only ports may be looked up as ports.
        if [[ -n "$busy" ]]; then
            rejections+=("$base ports$busy")
            continue
        fi

        if claim_resource_lock "$lock" "port block $base"; then
            run_lock_dir="$lock"
            assign_port_block "$base"
            return 0
        fi

        owner=$(cat "$lock/pid" 2>/dev/null)
        rejections+=("$base lock ${owner:-unknown}")
    done

    echo "Every fixture port block on this machine is taken." >&2
    echo "The merge gate needs $port_block_size consecutive free ports." >&2
    local -a fields=()
    local rejection
    for rejection in "${rejections[@]}"; do
        read -r -a fields <<<"$rejection"
        if [[ "${fields[1]}" == "ports" ]]; then
            printf '  block %s: ports in use:%s\n' \
                "${fields[0]}" "${rejection#"${fields[0]} ports"}" >&2
            for port in "${fields[@]:2}"; do
                describe_port_holder "$port" || true
            done
        else
            printf '  block %s: claimed by live run pid %s\n' \
                "${fields[0]}" "${fields[2]}" >&2
        fi
    done
    echo >&2
    echo "What to do:" >&2
    echo "  - a block held by a live run: wait for it, or widen" >&2
    echo "    port_block_count in this script." >&2
    echo "  - an ORPHAN above outlived its run. Confirm it is yours, then" >&2
    echo "    kill it by pid. This script never kills what it did not start." >&2
    echo "  - to pin a block yourself: HEELER_CI_PORT_BASE=<base>" >&2
    exit 1
}

claim_port_block
printf 'Claimed fixture port block %s-%s\n' \
    "$modern_port" "$((modern_port + port_block_size - 1))" >&2

sftp_server=""
for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server; do
    if [[ -x "$candidate" ]]; then
        sftp_server="$candidate"
        break
    fi
done
if [[ -z "$sftp_server" ]]; then
    echo "No sftp-server binary was found; the SFTP suites cannot run" >&2
    exit 1
fi

chmod 755 "$fixture_dir"
mkdir -p \
    "$fixture_home/.config/herdr/sessions/fixture" \
    "$fixture_home/.codex/skills/fixture" \
    "$fixture_home/.heeler-ci" \
    "$fixture_dir/bin"
printf '%s\n' \
    '---' \
    'name: fixture' \
    'description: Real SSH fixture skill.' \
    '---' \
    'Fixture body.' \
    > "$fixture_home/.codex/skills/fixture/SKILL.md"
# The dollar expressions below belong to the generated fixture script.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'stty -echo' \
    'printf "TTY-OK\\n"' \
    'printf "ARGS:%s\\n" "$*"' \
    'printf "SOCKET:%s\\n" "$HERDR_SOCKET_PATH"' \
    'stty size' \
    'while IFS= read -r line; do' \
    '    case "$line" in' \
    '        __exit__) exit 0 ;;' \
    '        __fail__) exit 23 ;;' \
    '        __end_race__)' \
    '            printf "END-RACE-READY\\n"' \
    '            sleep 1' \
    '            printf "END-RACE-BEFORE\\n"' \
    '            sleep 10' \
    '            printf "END-RACE-AFTER\\n"' \
    '            continue ;;' \
    '    esac' \
    '    printf "GOT:%s\\n" "$line"' \
    '    stty size' \
    'done' \
    > "$fixture_home/.heeler-ci/fake-attach"
chmod 755 "$fixture_home/.heeler-ci/fake-attach"

# The cold-start wake runs `herdr remote-client-bridge` on the Host. The fixture
# has no herdr server, and a real one must never be reached, so stand in for the
# binary with a stub that succeeds and does nothing. Without it the combined
# cause tests see command-not-found instead of a wake that simply did not help.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_dir/bin/herdr"
chmod 755 "$fixture_dir/bin/herdr"

# The acceptance Host must have no socat. The forced session PATH below is the
# only PATH the product ever sees on this Host, so assert socat is absent from
# it rather than from the machine: a developer with socat in Homebrew still runs
# a genuinely socat-free Host.
fixture_session_path="$fixture_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"
IFS=':' read -r -a fixture_path_entries <<< "$fixture_session_path"
for entry in "${fixture_path_entries[@]}"; do
    if [[ -x "$entry/socat" ]]; then
        echo "socat is reachable at $entry/socat; the Host must not provide it" >&2
        exit 1
    fi
done

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_ed25519"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$fixture_dir/host_rsa"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_jump_target_ed25519"

# A throwaway Device Key per run. The suites receive its seed in the fixture
# configuration, so no key committed to this repository ever authorizes a login.
ssh-keygen -q -t ed25519 -N '' -C heeler-ci-device-key -f "$fixture_dir/device_key"
device_key_seed="$(/usr/bin/python3 \
    scripts/fixtures/openssh-ed25519-seed.py "$fixture_dir/device_key")"
cp "$fixture_dir/device_key.pub" "$fixture_dir/authorized_keys"
printf 'no-port-forwarding %s\n' "$(<"$fixture_dir/device_key.pub")" \
    > "$fixture_dir/authorized_keys-no-forwarding"
cp "$fixture_dir/authorized_keys" "$fixture_dir/authorized_keys-jump-target"

pairing_username="$fixture_username"
pairing_home="$fixture_dir/pairing-home"
pairing_authorized_keys="$pairing_home/.ssh/authorized_keys"
pairing_state_root="$fixture_dir/pairing-state"
mkdir -p "$pairing_home/.ssh" "$pairing_state_root"
cp "$fixture_dir/authorized_keys" "$pairing_authorized_keys"
chmod 700 "$pairing_home/.ssh"
chmod 600 "$pairing_authorized_keys"

modern_config="$fixture_dir/sshd-modern.conf"
legacy_config="$fixture_dir/sshd-legacy.conf"
restricted_config="$fixture_dir/sshd-restricted.conf"
streamlocal_global_policy_config="$fixture_dir/sshd-streamlocal-global-policy.conf"
streamlocal_key_policy_config="$fixture_dir/sshd-streamlocal-key-policy.conf"
jump_target_config="$fixture_dir/sshd-jump-target.conf"
jump_forwarding_denied_config="$fixture_dir/sshd-jump-forwarding-denied.conf"
pairing_config="$fixture_dir/sshd-pairing.conf"
pairing_mismatched_config="$fixture_dir/sshd-pairing-mismatched.conf"
password_config="$fixture_dir/sshd-password.conf"

write_common_config() {
    local port=$1
    local host_key=$2
    local pid_file=$3

    printf '%s\n' \
        "Port $port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $fixture_dir/authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $fixture_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel VERBOSE" \
        "Subsystem sftp $sftp_server" \
        "SetEnv HOME=$fixture_home" \
        "ForceCommand $force_posix_shell"
}

# An unprivileged sshd runs sessions under the invoking account's login shell,
# so the fixture would otherwise mean something different on every machine (the
# old privileged fixture pinned /bin/zsh on its throwaway account). Re-exec every
# session under POSIX sh instead, with the fixture PATH asserted above: sshd
# overwrites a `SetEnv PATH` with its own default, so it has to happen here.
# SSH_ORIGINAL_COMMAND carries the subsystem command too, so SFTP keeps working.
# This must never be set on the Pairing sshd, where it would override the
# authorized_keys forced command.
# The leading `exec` matters: without it the account's login shell forks a child
# for the wrapper, and a session that kills its own parent (the package's native
# resource reclamation test) would kill that child instead of the sshd session.
force_posix_shell="exec /bin/sh -c 'PATH=$fixture_session_path; export PATH;"
force_posix_shell+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
force_posix_shell+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"

write_common_config \
    "$modern_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-modern.pid" > "$modern_config"
write_common_config \
    "$legacy_port" \
    "$fixture_dir/host_rsa" \
    "$fixture_dir/sshd-legacy.pid" > "$legacy_config"
printf '%s\n' "HostKeyAlgorithms ssh-rsa" >> "$legacy_config"
write_common_config \
    "$restricted_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-restricted.pid" > "$restricted_config"
printf '%s\n' "MaxSessions 0" >> "$restricted_config"
write_common_config \
    "$streamlocal_global_policy_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-streamlocal-global-policy.pid" \
    > "$streamlocal_global_policy_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding no" \
    >> "$streamlocal_global_policy_config"
write_common_config \
    "$streamlocal_key_policy_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-streamlocal-key-policy.pid" \
    > "$streamlocal_key_policy_config"
sed -i '' \
    "s|AuthorizedKeysFile $fixture_dir/authorized_keys|AuthorizedKeysFile $fixture_dir/authorized_keys-no-forwarding|" \
    "$streamlocal_key_policy_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding yes" \
    >> "$streamlocal_key_policy_config"
write_common_config \
    "$jump_target_port" \
    "$fixture_dir/host_jump_target_ed25519" \
    "$fixture_dir/sshd-jump-target.pid" > "$jump_target_config"
sed -i '' \
    "s|AuthorizedKeysFile $fixture_dir/authorized_keys|AuthorizedKeysFile $fixture_dir/authorized_keys-jump-target|" \
    "$jump_target_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding yes" \
    >> "$jump_target_config"
write_common_config \
    "$jump_forwarding_denied_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-jump-forwarding-denied.pid" \
    > "$jump_forwarding_denied_config"
printf '%s\n' \
    "AllowTcpForwarding no" \
    "AllowStreamLocalForwarding yes" \
    >> "$jump_forwarding_denied_config"

write_pairing_config() {
    local listen_address=$1
    local host_key=$2
    local pid_file=$3

    printf '%s\n' \
        "Port $pairing_port" \
        "ListenAddress $listen_address" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $pairing_authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $pairing_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel VERBOSE" \
        "Subsystem sftp $sftp_server"
}

write_pairing_config \
    127.0.0.1 \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-pairing.pid" > "$pairing_config"
write_pairing_config \
    ::1 \
    "$fixture_dir/host_jump_target_ed25519" \
    "$fixture_dir/sshd-pairing-mismatched.pid" > "$pairing_mismatched_config"

streamlocal_socket="$fixture_home/.config/herdr/herdr.sock"
streamlocal_stale_socket="$fixture_home/.heeler-ci/stale.sock"
streamlocal_wake_failure_socket="$fixture_home/.heeler-ci/stale-wake-failure.sock"
streamlocal_missing_socket="$fixture_home/.heeler-ci/missing.sock"
streamlocal_count_file="$fixture_home/.heeler-ci/streamlocal-count"
ln -s \
    "$streamlocal_socket" \
    "$fixture_home/.config/herdr/sessions/fixture/herdr.sock"
/usr/bin/python3 scripts/fixtures/fake-herdr-streamlocal.py \
    --socket "$streamlocal_socket" \
    --stale-socket "$streamlocal_stale_socket" \
    --stale-socket "$streamlocal_wake_failure_socket" \
    --count-file "$streamlocal_count_file" \
    > "$fixture_dir/fake-herdr.log" 2>&1 &
fake_herdr_pid=$!

# The weak-network route. `pfctl`/`dummynet` need root and the Network Link
# Conditioner is machine-wide, so degrade one TCP path instead: the suite
# points its Host at this port and steers latency, bandwidth, fragmentation
# and abrupt severance through the control port. Deterministic by construction
# — every knob is a fixed duration or a byte count.
/usr/bin/python3 scripts/fixtures/weak-network-proxy.py \
    --listen-port "$weak_network_port" \
    --control-port "$weak_network_control_port" \
    --target-host 127.0.0.1 \
    --target-port "$modern_port" \
    > "$fixture_dir/weak-network.log" 2>&1 &
weak_network_pid=$!

start_unprivileged_sshd "$modern_config" "$fixture_dir/sshd-modern.log"
modern_pid=$started_sshd_pid
start_unprivileged_sshd "$legacy_config" "$fixture_dir/sshd-legacy.log"
legacy_pid=$started_sshd_pid
start_unprivileged_sshd "$restricted_config" "$fixture_dir/sshd-restricted.log"
restricted_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$streamlocal_global_policy_config" \
    "$fixture_dir/sshd-streamlocal-global-policy.log"
streamlocal_global_policy_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$streamlocal_key_policy_config" \
    "$fixture_dir/sshd-streamlocal-key-policy.log"
streamlocal_key_policy_pid=$started_sshd_pid
start_unprivileged_sshd "$jump_target_config" "$fixture_dir/sshd-jump-target.log"
jump_target_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$jump_forwarding_denied_config" \
    "$fixture_dir/sshd-jump-forwarding-denied.log"
jump_forwarding_denied_pid=$started_sshd_pid
start_unprivileged_sshd "$pairing_config" "$fixture_dir/sshd-pairing.log"
pairing_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$pairing_mismatched_config" "$fixture_dir/sshd-pairing-mismatched.log"
pairing_mismatched_pid=$started_sshd_pid

# Real password authentication is the one behaviour macOS cannot exercise
# unprivileged: only root can verify an account password, and an unprivileged
# sshd can only authenticate the account it already runs as.
if sudo -n true >/dev/null 2>&1; then
    password_username="heelerssh${RANDOM}"
    password_secret="$(uuidgen)-$(uuidgen)"
    password_home="$fixture_dir/password-home"
    account_lock_dir="$lock_root/password-account-allocation"
    if ! claim_resource_lock "$account_lock_dir" "password account allocation"; then
        echo "Another gate is allocating its temporary password account; retry shortly." >&2
        exit 1
    fi
    while dscl . -search /Users UniqueID "$password_uid" | grep -q .; do
        password_uid=$((password_uid + 1))
    done
    mkdir -p "$password_home"
    # EXIT/INT/TERM may arrive after sysadminctl creates only part of the user
    # record, so declare cleanup intent before starting that side effect.
    password_user_cleanup_needed=1
    create_password_user
    release_resource_lock "$account_lock_dir" "password account allocation"
    account_lock_dir=""
    sudo -n dscl . -create "/Users/$password_username" IsHidden 1
    sudo -n chown "$password_uid":20 "$password_home"
    if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
        password_ssh_sacl_added=1
        sudo -n /usr/sbin/dseditgroup -o edit \
            -a "$password_username" -t user com.apple.access_ssh
    fi
    printf '%s\n' \
        "Port $password_port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $fixture_dir/host_ed25519" \
        "PidFile $password_pid_file" \
        "PasswordAuthentication yes" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $fixture_dir/authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $password_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel VERBOSE" \
        "Subsystem sftp $sftp_server" \
        > "$password_config"
    password_fixture_available=1
    # Fail on host account authentication before compilation can hide it.
    export HEELER_PASSWORD_SSH_PREFLIGHT_PORT="$password_port"
    export HEELER_PASSWORD_SSH_PREFLIGHT_USERNAME="$password_username"
    preflight_status=0
    start_password_sshd || exit 1
    password_ssh_preflight || preflight_status=$?
    stop_status=0
    stop_privileged_sshd "$password_pid" "$password_pid_file" \
        || stop_status=$?
    if [[ "$stop_status" == "0" ]]; then
        password_pid=""
    fi
    unset HEELER_PASSWORD_SSH_PREFLIGHT_PORT
    unset HEELER_PASSWORD_SSH_PREFLIGHT_USERNAME
    if [[ "$preflight_status" != "0" || "$stop_status" != "0" ]]; then
        cat "$password_log" >&2
        password_log_printed=1
        exit 1
    fi
elif [[ "$mandatory_matrix" == "1" ]]; then
    echo "Merge CI requires passwordless sudo for the real-password fixture" >&2
    exit 1
else
    echo "==> No passwordless sudo: skipping the real-password sshd fixture." >&2
    echo "==> Twelve of the thirteen mandatory behaviours still run." >&2
fi

/usr/bin/python3 -c '
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen()
connections = []
while True:
    connection, _ = server.accept()
    connections.append(connection)
' "$stall_port" >/dev/null 2>&1 &
stall_pid=$!

fixture_pids=(
    "$modern_pid"
    "$legacy_pid"
    "$restricted_pid"
    "$stall_pid"
    "$streamlocal_global_policy_pid"
    "$streamlocal_key_policy_pid"
    "$jump_target_pid"
    "$jump_forwarding_denied_pid"
    "$pairing_pid"
    "$pairing_mismatched_pid"
    "$fake_herdr_pid"
    "$weak_network_pid"
)
fixture_ports=(
    "$modern_port"
    "$legacy_port"
    "$restricted_port"
    "$stall_port"
    "$streamlocal_global_policy_port"
    "$streamlocal_key_policy_port"
    "$jump_target_port"
    "$jump_forwarding_denied_port"
    "$pairing_port"
    "$weak_network_port"
    "$weak_network_control_port"
)

fixture_is_listening() {
    local port
    for port in "${fixture_ports[@]}"; do
        nc -z 127.0.0.1 "$port" >/dev/null 2>&1 || return 1
    done
    nc -z ::1 "$pairing_port" >/dev/null 2>&1 || return 1
    [[ -S "$streamlocal_socket" ]] || return 1
    [[ -S "$streamlocal_stale_socket" ]] || return 1
    [[ -S "$streamlocal_wake_failure_socket" ]] || return 1
    return 0
}

dump_fixture_logs() {
    local log
    for log in "$fixture_dir"/*.log; do
        [[ -f "$log" ]] || continue
        echo "===== $log" >&2
        cat "$log" >&2
    done
}

for attempt in $(seq 1 50); do
    if fixture_is_listening; then
        break
    fi
    for pid in "${fixture_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            dump_fixture_logs
            exit 1
        fi
    done
    sleep 0.1
done

if ! fixture_is_listening; then
    dump_fixture_logs
    exit 1
fi

# `HEELER_SSH_E2E_REQUIRED=1` is the contract that turns a missing fixture into
# a failure instead of a green skip: see Tests/HeelerTests/Support/RealSSHFixture.
export HEELER_SSH_E2E_REQUIRED=1
export HEELER_SSH_E2E_HOST=127.0.0.1
export HEELER_SSH_E2E_PORT="$modern_port"
export HEELER_SSH_E2E_LEGACY_PORT="$legacy_port"
export HEELER_SSH_E2E_RESTRICTED_PORT="$restricted_port"
export HEELER_SSH_E2E_STALL_PORT="$stall_port"
export HEELER_SSH_E2E_USERNAME="$fixture_username"
export HEELER_SSH_E2E_DEVICE_KEY_SEED="$device_key_seed"
export HEELER_SSH_E2E_STREAMLOCAL_SOCKET="$streamlocal_socket"
export HEELER_SSH_E2E_WEAK_PORT="$weak_network_port"
export HEELER_SSH_E2E_WEAK_CONTROL_PORT="$weak_network_control_port"

password_fixture_json=null
if [[ "$password_fixture_available" == "1" ]]; then
    password_fixture_json=$(printf \
        '{"port":%s,"username":"%s","password":"%s"}' \
        "$password_port" \
        "$password_username" \
        "$password_secret")
fi
fixture_configuration=$(printf \
    '{"host":"127.0.0.1","port":%s,"legacyPort":%s,"restrictedPort":%s,"stallPort":%s,"globalPolicyPort":%s,"keyPolicyPort":%s,"weakNetworkPort":%s,"weakNetworkControlPort":%s,"username":"%s","deviceKeySeed":"%s","passwordFixture":%s,"streamLocalSocketPath":"%s","socketPath":"%s","staleSocketPath":"%s","wakeFailureStaleSocketPath":"%s","missingSocketPath":"%s","countFilePath":"%s","homePath":"%s"}' \
    "$modern_port" \
    "$legacy_port" \
    "$restricted_port" \
    "$stall_port" \
    "$streamlocal_global_policy_port" \
    "$streamlocal_key_policy_port" \
    "$weak_network_port" \
    "$weak_network_control_port" \
    "$fixture_username" \
    "$device_key_seed" \
    "$password_fixture_json" \
    "$streamlocal_socket" \
    "$streamlocal_socket" \
    "$streamlocal_stale_socket" \
    "$streamlocal_wake_failure_socket" \
    "$streamlocal_missing_socket" \
    "$streamlocal_count_file" \
    "$fixture_home")
fixture_configuration_base64=$(printf '%s' "$fixture_configuration" | base64)
jump_fixture_configuration=$(printf \
    '{"host":"127.0.0.1","jumpPort":%s,"forwardingDeniedPort":%s,"targetHost":"127.0.0.1","targetPort":%s,"outerStallPort":%s,"innerStallHost":"127.0.0.1","innerStallPort":%s,"username":"%s","deviceKeySeed":"%s","socketPath":"%s"}' \
    "$modern_port" \
    "$jump_forwarding_denied_port" \
    "$jump_target_port" \
    "$stall_port" \
    "$stall_port" \
    "$fixture_username" \
    "$device_key_seed" \
    "$streamlocal_socket")
jump_fixture_configuration_base64=$(printf '%s' "$jump_fixture_configuration" | base64)
if ! pairing_node_path="$(command -v node)"; then
    echo "Node is required for the mandatory Pairing ceremony suite" >&2
    exit 1
fi
pairing_accept_script="$PWD/plugin/src/pair-accept.js"
if [[ ! -f "$pairing_accept_script" ]]; then
    echo "Pairing accept entrypoint not found at $pairing_accept_script" >&2
    exit 1
fi
pairing_fixture_configuration=$(printf \
    '{"host":"127.0.0.1","port":%s,"mismatchedHostAddress":"::1","username":"%s","deviceKeySeed":"%s","nodePath":"%s","acceptScriptPath":"%s","homePath":"%s","authorizedKeysPath":"%s","localStateRoot":"%s","remoteStateRoot":"%s"}' \
    "$pairing_port" \
    "$pairing_username" \
    "$device_key_seed" \
    "$pairing_node_path" \
    "$pairing_accept_script" \
    "$pairing_home" \
    "$pairing_authorized_keys" \
    "$pairing_state_root" \
    "$pairing_state_root")
pairing_fixture_configuration_base64=$(printf \
    '%s' "$pairing_fixture_configuration" | base64)
# A disjoint port block is necessary for two runs to coexist but not
# sufficient: the fixture reaches the tests through `simctl launchctl setenv`,
# which is per-device state. Two runs sharing one device overwrite each other's
# HEELER_SSH_E2E_* and one of them tests the other's fixture -- silently, unlike
# a port clash. So the device is claimed alongside the block.
#
# Candidates come back last-first, preserving the previous choice of the last
# matching device for a run that finds the machine idle.
simulator_candidates=()
while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && simulator_candidates+=("$candidate")
done < <(xcrun simctl list devices available | awk '
    /iPhone 17 \(/ {
        candidate = ""
        for (field = 1; field <= NF; field += 1) {
            value = $field
            gsub(/[()]/, "", value)
            if (value ~ /^[0-9A-F-]{36}$/) {
                candidate = value
            }
        }
        if (candidate != "") {
            list[++count] = candidate
        }
    }
    END { for (index_ = count; index_ >= 1; index_ -= 1) print list[index_] }
')
if [[ "${#simulator_candidates[@]}" -eq 0 ]]; then
    echo "No available iPhone 17 Simulator was found" >&2
    exit 1
fi

# Reports the live pid holding this device, nothing if it is free.
simulator_held_by() {
    local udid=$1
    local owner

    owner=$(cat "$lock_root/device-$udid/pid" 2>/dev/null)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        printf '%s' "$owner"
        return 0
    fi
    return 1
}

# The device uses the same token-checked resource claim as a port block. A
# separate device claim is necessary because its launchctl environment is
# shared even when the fixture ports are not.
claim_simulator() {
    local udid=$1
    local lock="$lock_root/device-$udid"

    if claim_resource_lock "$lock" "simulator $udid"; then
        device_lock_dir="$lock"
        return 0
    fi
    return 1
}

requested_simulator_udid="${HEELER_CI_SIMULATOR_UDID:-}"
simulator_udid=""
if [[ -n "$requested_simulator_udid" ]]; then
    if claim_simulator "$requested_simulator_udid"; then
        simulator_udid="$requested_simulator_udid"
    else
        printf 'Requested simulator %s is claimed by live run pid %s.\n' \
            "$requested_simulator_udid" \
            "$(simulator_held_by "$requested_simulator_udid" || printf 'unknown')" >&2
        echo "Choose a different HEELER_CI_SIMULATOR_UDID or wait for that run." >&2
        exit 1
    fi
else
    for candidate in "${simulator_candidates[@]}"; do
        if claim_simulator "$candidate"; then
            simulator_udid="$candidate"
            break
        fi
    done
fi
if [[ -z "$simulator_udid" ]]; then
    echo "Every available iPhone 17 Simulator is claimed by a live run." >&2
    for candidate in "${simulator_candidates[@]}"; do
        printf '  %s: held by pid %s\n' \
            "$candidate" "$(simulator_held_by "$candidate")" >&2
    done
    echo >&2
    echo "A run needs a device of its own: the fixture is delivered through" >&2
    echo "per-device launchctl environment, which two runs would overwrite." >&2
    echo "Create another iPhone 17 with 'xcrun simctl create', or pin one" >&2
    echo "explicitly with HEELER_CI_SIMULATOR_UDID=<udid>." >&2
    exit 1
fi
printf 'Claimed simulator %s\n' "$simulator_udid" >&2
simulator_destination="platform=iOS Simulator,id=$simulator_udid"
# Kick the boot off now and wait for it only after build-for-testing below:
# compilation needs the destination to exist, not to be booted, so the minute
# of boot happens under the minutes of build instead of in front of them.
xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true

# Every lane whose executed count and skip budget this script pins exactly. The
# full lane's provenance assertion draws its evidence from these, so a lane that
# is not listed here proves nothing.
pinned_lane_logs=()

# Swift Testing filters exit zero having run nothing, so every mandatory suite
# asserts its executed count. `run_suite` also refuses any skip: with
# HEELER_SSH_E2E_REQUIRED set a fixture-backed suite must fail rather than skip,
# so a skip here means a condition that can still hide missing coverage.
run_suite() {
    local suite=$1
    local expected_tests=$2
    local expected_suites=$3
    local expected_skips=${4:-0}
    local log="$fixture_dir/$suite.log"
    local noun="suite"
    local skips

    if [[ "$expected_suites" != "1" ]]; then
        noun="suites"
    fi
    run_xcodebuild "$suite" "$xcodebuild_test_timeout_seconds" \
        test-without-building \
        -project Heeler.xcodeproj \
        -scheme Heeler \
        -derivedDataPath "$app_derived_data_path" \
        -destination "$simulator_destination" \
        -collect-test-diagnostics never \
        "-only-testing:HeelerTests/$suite" \
        2>&1 | tee "$log"

    skips=$(grep -cE '(Test|Suite) .* skipped' "$log" || true)
    if [[ "$skips" != "$expected_skips" ]]; then
        echo "$suite skipped $skips tests; exactly $expected_skips may skip" >&2
        exit 1
    fi
    if ! grep -q \
        "Test run with $expected_tests tests in $expected_suites $noun passed" \
        "$log"; then
        echo "$suite did not execute all $expected_tests tests" >&2
        exit 1
    fi
    pinned_lane_logs+=("$log")
}

# Every behaviour the merge gate treats as mandatory names the test that proves
# it. A count alone cannot show that Events, resize, or SFTP specifically ran.
assert_behavior() {
    local behavior=$1
    local log_name=$2
    local test_name=$3
    local log="$fixture_dir/$log_name.log"

    if ! grep -qF "Test $test_name passed" "$log"; then
        echo "Mandatory behaviour not proven: $behavior ($test_name)" >&2
        exit 1
    fi
}

# The full lane runs with no fixture configured, so the fixture-backed suites
# skip there by design. That design is also how eleven percent of the lane's
# headline total can execute nothing while the run still reports success, which
# is why the full lane is not asserted on a total: the number a total guard
# would compare is satisfied by exactly the failure it exists to catch.
#
# Provenance is asserted instead. A full-lane skip is permitted only when one of
# the lanes this script pins with an exact executed count and an exact skip
# budget ran that same test to a pass. This is deliberately not an allow-list of
# suite names: a suite cannot be entered into it without also being made to run
# somewhere the gate checks, so a ninth suite joining the skip list fails here,
# by name, rather than reading as a rounding difference.
assert_full_lane_coverage() {
    local log=$1
    local executed_floor=$2
    local covered="$fixture_dir/pinned-lane-passes.txt"
    local skipped="$fixture_dir/full-lane-skips.txt"
    local unproven
    local total
    local skips
    local executed

    # `Test <name> passed after 1.234 seconds.` — the run summary reads
    # `Test run with N tests in M suites passed after ...`, which the same
    # pattern would otherwise reduce to a name, so it is deleted first.
    cat "${pinned_lane_logs[@]}" \
        | sed -n \
            -e '/Test run with /d' \
            -e 's/^.*Test \(.*\) passed after .*$/\1/p' \
        | LC_ALL=C sort -u > "$covered"
    if [[ "$password_fixture_available" != "1" ]]; then
        # The one behaviour a developer laptop may omit, and the only place a
        # full-lane skip is allowed to go unproven. Merge CI cannot reach this
        # branch: an absent privileged fixture already exits above. The two
        # tests are named rather than counted, so the exemption cannot widen
        # into a budget that later skips can hide inside.
        printf '%s\n' \
            '"password authentication and exec round trip through real sshd"' \
            '"incorrect password has a distinct authentication error"' \
            >> "$covered"
        LC_ALL=C sort -u -o "$covered" "$covered"
    fi

    sed -n 's/^.*Test \(.*\) skipped: .*$/\1/p' "$log" \
        | LC_ALL=C sort -u > "$skipped"
    unproven=$(LC_ALL=C comm -23 "$skipped" "$covered")
    if [[ -n "$unproven" ]]; then
        echo "The full lane skipped tests that no pinned lane proved:" >&2
        echo "$unproven" >&2
        echo "Make each one run in a lane run_suite pins, or fix the skip." >&2
        exit 1
    fi

    total=$(sed -n \
        's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
        "$log" | tail -n 1)
    if [[ -z "$total" ]]; then
        echo "The full lane printed no passing run summary" >&2
        exit 1
    fi
    skips=$(grep -c 'Test .* skipped:' "$log" || true)
    executed=$((total - skips))
    # A floor, not an equality: adding tests must not require editing this
    # script, but losing coverage must be a deliberate act. Re-derive it as the
    # run summary's total minus the count of `Test ... skipped:` lines in the
    # same log. The total alone is not usable here — it counts the skips.
    if ((executed < executed_floor)); then
        echo "The full lane executed $executed tests ($total minus $skips" \
            "skipped); at least $executed_floor must run" >&2
        exit 1
    fi
    echo "==> Full lane executed $executed of $total tests," \
        "$skips skipped and all of them proven elsewhere." >&2
}

# The direct-streamlocal suite asserts that a stale socket is still stale.
# HeelerSSHTransportBehaviorE2ETests relinks that socket, so it must run after.
# Swift Testing counts a skipped test in the run total, so only the permitted
# skip count changes when the privileged password fixture is absent.
session_skip_count=0
if [[ "$password_fixture_available" != "1" ]]; then
    session_skip_count=2
fi
echo "==> Fixture provisioning finished at t+${SECONDS}s"
# One compilation for every app lane. Building up front keeps it outside the
# short-lived privileged fixture window, and every suite below plus the full
# lane then runs test-without-building against these products instead of
# paying a package-resolution and incremental-build check per session --
# measured at roughly half a minute per xcodebuild invocation on CI.
run_xcodebuild "Build for testing" "$xcodebuild_build_timeout_seconds" \
    build-for-testing \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -derivedDataPath "$app_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
# The simulator has been booting since before the build started; whatever
# remains of its boot is all this wait costs.
boot_wait_started=$SECONDS
xcrun simctl bootstatus "$simulator_udid" -b
echo "==> Simulator boot wait after the build overlap: $((SECONDS - boot_wait_started))s"
# Read through variable indirection by push_simulator_environment, which
# static analysis cannot follow; unset again by clear_simulator_environment.
# shellcheck disable=SC2034
{
    HEELER_SSH_E2E_CONFIG="$fixture_configuration_base64"
    HEELER_SSH_JUMP_E2E_CONFIG="$jump_fixture_configuration_base64"
    HEELER_PAIRING_E2E_CONFIG="$pairing_fixture_configuration_base64"
}
push_simulator_environment \
    HEELER_SSH_E2E_CONFIG \
    HEELER_SSH_JUMP_E2E_CONFIG \
    HEELER_PAIRING_E2E_CONFIG
if [[ "$password_fixture_available" == "1" ]]; then
    start_password_sshd || exit 1
fi
run_suite HeelerSSHSessionE2ETests 13 1 "$session_skip_count"
if [[ "$password_fixture_available" == "1" ]]; then
    if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
        password_pid=""
    else
        exit 1
    fi
fi
run_suite HeelerSSHPTYE2ETests 3 1
run_suite HeelerSSHDirectStreamLocalE2ETests 9 1
run_suite HeelerSSHJumpHostGateE2ETests 8 1
run_suite HeelerSSHTransportBehaviorE2ETests 56 1
run_suite ImageStagingE2ETests 8 1
run_suite WeakNetworkE2ETests 8 1
run_suite PairingCeremonyE2ETests 11 1

if [[ "$password_fixture_available" == "1" ]]; then
    assert_behavior "real Password" HeelerSSHSessionE2ETests \
        '"password authentication and exec round trip through real sshd"'
fi
assert_behavior "Device Key" HeelerSSHSessionE2ETests \
    '"authorized Device Key authenticates and executes through real sshd"'
assert_behavior "Bootstrap Key" PairingCeremonyE2ETests \
    'fullCeremonyEnrollsTheDeviceKeyAndVerifies()'
assert_behavior "two-hop trust" HeelerSSHJumpHostGateE2ETests \
    '"TOFU records both endpoints once and identifies either mismatch"'
# Trust at both hops is not the product. This is: connect the jump, forward to
# the target, authenticate it, exchange a real ping, and tear the two sessions
# down in order. Folded into the trust assertion it was invisible to rename.
assert_behavior "Jump Host product path" HeelerSSHJumpHostGateE2ETests \
    '"protocol 17 ping traverses independent SSH hops"'
assert_behavior "Events" HeelerSSHTransportBehaviorE2ETests \
    '"direct Host Events preserve framing, concurrency, and slot reuse"'
assert_behavior "PTY" HeelerSSHPTYE2ETests \
    '"PTY exec preserves raw IO, merged output, geometry, and exit status"'
assert_behavior "resize" HeelerSSHTransportBehaviorE2ETests \
    '"direct Host Attach preserves PTY IO, resize, end, and reuse"'
assert_behavior "shell terminal creation" HeelerSSHTransportBehaviorE2ETests \
    '"shell terminal creation sends one exact tab create request"'
assert_behavior "direct Host shell terminal Attach" \
    HeelerSSHTransportBehaviorE2ETests \
    '"direct Host ordinary terminal Attach preserves PTY behavior"'
assert_behavior "Jump Host shell terminal Attach" \
    HeelerSSHTransportBehaviorE2ETests \
    '"Jump Host ordinary terminal Attach preserves PTY behavior"'
assert_behavior "RPC does not stall Attach" HeelerSSHTransportBehaviorE2ETests \
    '"direct Host RPC does not stall Attach"'
assert_behavior "RPC does not stall Attach on a Jump Host" \
    HeelerSSHTransportBehaviorE2ETests \
    '"Jump Host RPC does not stall Attach"'
# These writes can return healthy response envelopes even when a serializer
# silently drops a field. Keep every distinct wire contract named (#165).
assert_behavior "agent rename params" HeelerSSHTransportBehaviorE2ETests \
    '"agent rename sends its custom name and target exactly"'
assert_behavior "agent rename clear omission" HeelerSSHTransportBehaviorE2ETests \
    '"agent rename omits name when clearing a custom name"'
assert_behavior "workspace rename params" HeelerSSHTransportBehaviorE2ETests \
    '"workspace rename sends its label and workspace id exactly"'
assert_behavior "pane read params and result" HeelerSSHTransportBehaviorE2ETests \
    '"pane read sends exact params and round trips the result"'
assert_behavior "worktree remove params" HeelerSSHTransportBehaviorE2ETests \
    '"confirmed worktree removal crosses the real wire dispatch seam"'
assert_behavior "worktree remove stale authorization writes nothing" \
    HeelerSSHTransportBehaviorE2ETests \
    '"stale worktree authorization writes no request bytes"'
assert_behavior "herdr API rejection" HeelerSSHTransportBehaviorE2ETests \
    '"a herdr error envelope surfaces as a typed API rejection"'
assert_behavior "session API rejection mapping" HeelerSSHTransportBehaviorE2ETests \
    '"the session maps a herdr rejection to apiRejected"'
# herdr 0.7.5's `agent_pane_busy` window, which 0.8.0 no longer opens: nothing
# live exercises this any more, so a named assertion is the only thing standing
# between a refactor and silently dropping a documented server behaviour (#128).
assert_behavior "agent_pane_busy retry" HeelerSSHTransportBehaviorE2ETests \
    '"agent start waits out a fresh pane'"'"'s booting shell"'
# Each compensation cleans up different Host state; a count alone cannot tell
# which of them a change removed. New Workspace (#230) also names the
# create-then-start shape and the ambiguous-failure preserve rule, because
# those are the two ways that path can silently drift without changing the
# suite total.
assert_behavior "failed launch closes its pane" HeelerSSHTransportBehaviorE2ETests \
    '"a refused agent start closes the pane it created"'
assert_behavior "failed launch removes its worktree" \
    HeelerSSHTransportBehaviorE2ETests \
    '"a refused worktree agent start removes the worktree it created"'
assert_behavior "new-workspace launch skips tab.create" \
    HeelerSSHTransportBehaviorE2ETests \
    '"a new-workspace agent start creates the workspace then starts in its root pane"'
assert_behavior "failed launch closes its workspace" \
    HeelerSSHTransportBehaviorE2ETests \
    '"a refused new-workspace agent start closes the workspace it created"'
assert_behavior "ambiguous launch preserves its workspace" \
    HeelerSSHTransportBehaviorE2ETests \
    '"an ambiguous new-workspace agent start does not close the workspace"'
assert_behavior "SFTP" ImageStagingE2ETests \
    'directStagingStreamsPrivateFileAndAtomicallyRenamesThePart()'
assert_behavior "forwarding denial" HeelerSSHDirectStreamLocalE2ETests \
    '"global forwarding denial reports the honest combined cause"'
assert_behavior "key-policy forwarding denial" HeelerSSHDirectStreamLocalE2ETests \
    '"authorized_keys forwarding denial reports the honest combined cause"'
assert_behavior "forwarding denial surviving a failed wake" \
    HeelerSSHDirectStreamLocalE2ETests \
    '"a failed wake does not narrow a forwarding denial"'
assert_behavior "cancellation" HeelerSSHDirectStreamLocalE2ETests \
    '"cancellation closes only its channel and preserves connection reuse"'
assert_behavior "teardown" HeelerSSHSessionE2ETests \
    '"clean channel close leaves the connection reusable"'

# The weak-network half of the stress criterion. Each of these runs the named
# behaviour over the impairment proxy — added latency, a bandwidth cap,
# fragmentation, and abrupt severance — rather than over loopback at full speed.
assert_behavior "weak-network concurrent RPCs" WeakNetworkE2ETests \
    '"concurrent RPCs survive latency, a bandwidth cap, and fragmentation"'
assert_behavior "weak-network Events, Attach and SFTP staging" WeakNetworkE2ETests \
    '"Events and Attach stay live while SFTP stages over a degraded link"'
assert_behavior "weak-network cancellation" WeakNetworkE2ETests \
    '"cancelling a rate-starved upload frees only its own channel"'
assert_behavior "weak-network timeout" WeakNetworkE2ETests \
    '"bandwidth starvation times out instead of wedging the connection"'
assert_behavior "weak-network reconnect" WeakNetworkE2ETests \
    '"an abruptly severed link surfaces and a fresh connection recovers"'
assert_behavior "weak-network app lifecycle" WeakNetworkE2ETests \
    '"the events session survives a cut and a background round trip"'
assert_behavior "weak-network descriptor reclamation" WeakNetworkE2ETests \
    '"repeated degraded rounds reclaim every file descriptor"'
# The producer side of the property EventsSession redials on. Every other
# assertion of it in the repo is positive, so this is the only one that would
# notice it sticking true on a dead connection.
assert_behavior "disconnect is reported" WeakNetworkE2ETests \
    '"a severed link makes the transport report itself disconnected"'

push_simulator_environment \
    HEELER_SSH_E2E_REQUIRED \
    HEELER_SSH_E2E_HOST \
    HEELER_SSH_E2E_PORT \
    HEELER_SSH_E2E_USERNAME \
    HEELER_SSH_E2E_DEVICE_KEY_SEED \
    HEELER_SSH_E2E_WEAK_PORT \
    HEELER_SSH_E2E_WEAK_CONTROL_PORT \
    HEELER_SSH_E2E_STREAMLOCAL_SOCKET

package_e2e_log="$fixture_dir/package-e2e.log"
(
    cd Packages/HeelerSSH
    run_xcodebuild "HeelerSSH package E2E" "$xcodebuild_test_timeout_seconds" test \
        -scheme HeelerSSH \
        -derivedDataPath "$package_derived_data_path" \
        -destination "$simulator_destination" \
        -collect-test-diagnostics never
) 2>&1 | tee "$package_e2e_log"
clear_simulator_environment

if grep -q 'Suite "Session driver resource e2e" skipped' "$package_e2e_log" \
    || grep -q 'skipped:' "$package_e2e_log" \
    || ! grep -q 'Test run with 43 tests in 2 suites passed' "$package_e2e_log" \
    || ! grep -q 'Test "remote transport loss reclaims every owned native resource" passed' \
        "$package_e2e_log" \
    || ! grep -q 'Test "an abruptly severed weak link reclaims every owned native resource" passed' \
        "$package_e2e_log" \
    || ! grep -q 'Test "a severed link makes a stream-local connection report itself disconnected" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "a teardown that only runs out of its budget spares the session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "a genuine transport failure during teardown still invalidates the session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "issue 149 exec cleanup expiry invalidates allocated channels" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "openSFTP pre-init failures spare the SSH session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "openSFTP pending init failures invalidate the SSH session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "compensation expiry reclaims SFTP and spares the SSH session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "compensation shutdown failure invalidates the SSH session" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "issue 149 transport failures invalidate each tracked operation" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "direct TCP/IP pump backpressures a fast raw writer without losing bytes" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "outbound backpressure does not livelock a channel open" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "cancelling a transport-send owner drains" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "cancelling a transport-send owner invalidates" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "timing out a transport-send owner at loop-top drains" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "timing out a transport-send owner at loop-top invalidates" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "one-shot RPCs yield so a live PTY can progress" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "cancelling a yielded one-shot distinguishes cleanup outcomes" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "timing out a yielded one-shot distinguishes cleanup outcomes" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "invalidation during a yielding wait does not touch a stale native pointer" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "yielded channel teardown rejects same-id I/O and preserves close" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "repeated invalidation reclaims every file descriptor" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "measurement: Attach throughput with concurrent RPCs" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "SFTP operations and close wait out an in-flight handle use" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "a serialized channel-open wait honors deadline and cancellation" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "an invalidation generation rejects a watch armed before it" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "a transport-send owner error with outbound pending invalidates" passed' \
        "$package_e2e_log" \
    || ! grep -q \
        'Test "a bridge write to a closed peer reports peerClosed" passed' \
        "$package_e2e_log"; then
    echo "The mandatory HeelerSSH package suites did not execute all forty-three tests" >&2
    exit 1
fi
pinned_lane_logs+=("$package_e2e_log")

# The full lane runs with no fixture configured, so every fixture-backed suite
# must skip — hence the clear above. The gate is still in force, though, and
# `HEELER_SSH_E2E_REQUIRED=0` says exactly that: driven by the gate, nothing
# configured. Suites whose only remaining route is a machine-owned resource
# (PairingCeremonyE2ETests would otherwise re-target the developer's own sshd
# and rewrite their real authorized_keys) refuse it and skip; see
# RealSSHFixture.isUnderMergeGate. cleanup() unsets it again on exit.
export HEELER_SSH_E2E_REQUIRED=0
xcrun simctl spawn "$simulator_udid" launchctl setenv HEELER_SSH_E2E_REQUIRED 0

full_lane_log="$fixture_dir/full-lane.log"
run_xcodebuild "Full app test lane" "$xcodebuild_test_timeout_seconds" \
    test-without-building \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -derivedDataPath "$app_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    2>&1 | tee "$full_lane_log"

# 769 is a floor, not the current count: it is what the lane executed the day it
# was written, deliberately left below what the lane reaches now so that adding
# tests never requires editing this script. Adding tests to a fixture-backed
# suite cannot move it at all — the full lane runs with no fixture, so those
# tests skip here and execute in a lane run_suite pins. The floor is not what
# proves the coverage; the skip-versus-pinned-lane comparison above it is.
assert_full_lane_coverage "$full_lane_log" 769

# The three groups that run only here, and so had no assertion of any kind
# before this. Each names the behaviour rather than counting the suite.
assert_behavior "admission reserves the production Events and Attach slots" \
    full-lane 'productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling()'
assert_behavior "admission stays non-blocking" full-lane \
    'sessionSaturationDoesNotBlockForwardingAdmission()'
assert_behavior "admission respects the connection ceiling" full-lane \
    'connectionCeilingBoundsForwardingAndSessionTogether()'
assert_behavior "a cancelled waiter frees its admission capacity" full-lane \
    'cancelledWaiterDoesNotLeakConnectionCapacity()'
assert_behavior "TOFU migrates a legacy record rather than re-prompting" \
    full-lane 'matchingLegacyRecordMigratesAlgorithmMetadata()'
assert_behavior "TOFU refuses a changed key without overwriting it" full-lane \
    'changedKeyFailsWithoutConfirmationOrOverwrite()'
assert_behavior "no obsolete algorithm is negotiable" full-lane \
    '"the session driver negotiates no obsolete algorithm"'
assert_behavior "no private key entry point exists" full-lane \
    '"the SSH package has no private key entry point"'
assert_behavior "signing never exports a key" full-lane \
    '"the transport signs through CryptoKit rather than exporting a key"'
