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

modern_port=55222
legacy_port=55223
restricted_port=55224
stall_port=55225
streamlocal_global_policy_port=55226
streamlocal_key_policy_port=55227
jump_target_port=55228
jump_forwarding_denied_port=55229
pairing_port=55230
password_port=55231
# The unprivileged impairment proxy: a degraded route to the modern sshd, plus
# the control port the weak-network suite steers it through.
weak_network_port=55232
weak_network_control_port=55233

# AF_UNIX paths cap at 104 bytes on macOS and the fixture nests herdr sockets
# several directories deep, so anchor at /tmp: the per-user TMPDIR alone is
# already 69 characters and overflows the limit.
fixture_dir="$(mktemp -d /tmp/heeler-ci.XXXXXX)"
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

# Merge CI must run the complete mandatory matrix; a laptop need not.
mandatory_matrix=0
case "${HEELER_CI_MANDATORY:-${CI:-}}" in
    1 | true | TRUE) mandatory_matrix=1 ;;
esac

unprivileged_sshd_pids=()

cleanup() {
    local status=$?
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
        stop_privileged_sshd "$password_pid" "$fixture_dir/sshd-password.pid"
    fi
    if [[ -n "$password_username" ]] \
        && dscl . -read "/Users/$password_username" >/dev/null 2>&1; then
        sudo -n dscl . -delete "/Users/$password_username"
    fi
    if [[ -d "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi

    exit "$status"
}
trap cleanup EXIT INT TERM

# Clears the fixture environment from both the Simulator and this shell. The
# shell half matters: the Simulator test process inherits it, so unsetting only
# the launchd values leaves HEELER_SSH_E2E_REQUIRED visible and the
# fixture-backed suites fail instead of skipping once the fixture is gone.
clear_simulator_environment() {
    local variable
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
        if [[ -n "$simulator_udid" ]]; then
            xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$variable" >/dev/null 2>&1
        fi
        unset "$variable"
    done
}

stop_privileged_sshd() {
    local launcher_pid=$1
    local pid_file=$2
    local daemon_pid=""

    if [[ -f "$pid_file" ]]; then
        daemon_pid="$(<"$pid_file")"
    fi
    if [[ "$daemon_pid" =~ ^[0-9]+$ ]]; then
        sudo -n kill "$daemon_pid" 2>/dev/null
    elif [[ -n "$launcher_pid" ]]; then
        sudo -n kill "$launcher_pid" 2>/dev/null
    fi
    if [[ -n "$launcher_pid" ]]; then
        wait "$launcher_pid" 2>/dev/null
    fi
}

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

for port in \
    "$modern_port" \
    "$legacy_port" \
    "$restricted_port" \
    "$stall_port" \
    "$streamlocal_global_policy_port" \
    "$streamlocal_key_policy_port" \
    "$jump_target_port" \
    "$jump_forwarding_denied_port" \
    "$pairing_port" \
    "$password_port" \
    "$weak_network_port" \
    "$weak_network_control_port"; do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "TCP port $port is already in use" >&2
        exit 1
    fi
done
if nc -z ::1 "$pairing_port" >/dev/null 2>&1; then
    echo "TCP endpoint [::1]:$pairing_port is already in use" >&2
    exit 1
fi

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
    while dscl . -search /Users UniqueID "$password_uid" | grep -q .; do
        password_uid=$((password_uid + 1))
    done
    mkdir -p "$password_home"
    sudo -n dscl . -create "/Users/$password_username"
    sudo -n dscl . -create "/Users/$password_username" RealName "Heeler SSH CI"
    sudo -n dscl . -create "/Users/$password_username" UserShell /bin/zsh
    sudo -n dscl . -create "/Users/$password_username" UniqueID "$password_uid"
    sudo -n dscl . -create "/Users/$password_username" PrimaryGroupID 20
    sudo -n dscl . -create "/Users/$password_username" NFSHomeDirectory "$password_home"
    sudo -n dscl . -create "/Users/$password_username" IsHidden 1
    sudo -n dscl . -passwd "/Users/$password_username" "$password_secret"
    sudo -n chown "$password_uid":20 "$password_home"
    printf '%s\n' \
        "Port $password_port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $fixture_dir/host_ed25519" \
        "PidFile $fixture_dir/sshd-password.pid" \
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
    sudo -n /usr/sbin/sshd -D -e -f "$password_config" \
        > "$fixture_dir/sshd-password.log" 2>&1 &
    password_pid=$!
    password_fixture_available=1
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
if [[ "$password_fixture_available" == "1" ]]; then
    fixture_pids+=("$password_pid")
fi

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
if [[ "$password_fixture_available" == "1" ]]; then
    fixture_ports+=("$password_port")
fi

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
simulator_udid=$(xcrun simctl list devices available | awk '
    /iPhone 17 \(/ {
        for (field = 1; field <= NF; field += 1) {
            value = $field
            gsub(/[()]/, "", value)
            if (value ~ /^[0-9A-F-]{36}$/) {
                candidate = value
            }
        }
    }
    END { print candidate }
')
if [[ -z "$simulator_udid" ]]; then
    echo "No available iPhone 17 Simulator was found" >&2
    exit 1
fi
simulator_destination="platform=iOS Simulator,id=$simulator_udid"
xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl spawn "$simulator_udid" launchctl setenv \
    HEELER_SSH_E2E_CONFIG \
    "$fixture_configuration_base64"
xcrun simctl spawn "$simulator_udid" launchctl setenv \
    HEELER_SSH_JUMP_E2E_CONFIG \
    "$jump_fixture_configuration_base64"
xcrun simctl spawn "$simulator_udid" launchctl setenv \
    HEELER_PAIRING_E2E_CONFIG \
    "$pairing_fixture_configuration_base64"

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
    xcodebuild test \
        -project Heeler.xcodeproj \
        -scheme Heeler \
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

# The direct-streamlocal suite asserts that a stale socket is still stale.
# HeelerSSHTransportBehaviorE2ETests relinks that socket, so it must run after.
# Swift Testing counts a skipped test in the run total, so only the permitted
# skip count changes when the privileged password fixture is absent.
session_skip_count=0
if [[ "$password_fixture_available" != "1" ]]; then
    session_skip_count=2
fi
run_suite HeelerSSHSessionE2ETests 14 1 "$session_skip_count"
run_suite HeelerSSHPTYE2ETests 3 1
run_suite HeelerSSHDirectStreamLocalE2ETests 11 1
run_suite HeelerSSHJumpHostGateE2ETests 9 1
run_suite HeelerSSHTransportBehaviorE2ETests 30 1
run_suite ImageStagingE2ETests 7 1
run_suite WeakNetworkE2ETests 7 1
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
assert_behavior "RPC" HeelerSSHDirectStreamLocalE2ETests \
    '"Transport ping validates protocol 17 and opens a fresh channel"'
assert_behavior "Events" HeelerSSHTransportBehaviorE2ETests \
    '"direct Host Events preserve framing, concurrency, and slot reuse"'
assert_behavior "PTY" HeelerSSHPTYE2ETests \
    '"PTY exec preserves raw IO, merged output, geometry, and exit status"'
assert_behavior "resize" HeelerSSHTransportBehaviorE2ETests \
    '"direct Host Attach preserves PTY IO, resize, end, and reuse"'
assert_behavior "SFTP" ImageStagingE2ETests \
    'directStagingStreamsPrivateFileAndAtomicallyRenamesThePart()'
assert_behavior "forwarding denial" HeelerSSHDirectStreamLocalE2ETests \
    '"global forwarding denial reports the honest combined cause"'
assert_behavior "key-policy forwarding denial" HeelerSSHDirectStreamLocalE2ETests \
    '"authorized_keys forwarding denial reports the honest combined cause"'
assert_behavior "cancellation" HeelerSSHDirectStreamLocalE2ETests \
    '"cancellation closes only its channel and preserves connection reuse"'
assert_behavior "timeout" HeelerSSHDirectStreamLocalE2ETests \
    '"timeout closes only its channel and preserves connection reuse"'
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

for variable in \
    HEELER_SSH_E2E_REQUIRED \
    HEELER_SSH_E2E_HOST \
    HEELER_SSH_E2E_PORT \
    HEELER_SSH_E2E_USERNAME \
    HEELER_SSH_E2E_DEVICE_KEY_SEED \
    HEELER_SSH_E2E_WEAK_PORT \
    HEELER_SSH_E2E_WEAK_CONTROL_PORT; do
    xcrun simctl spawn "$simulator_udid" launchctl setenv "$variable" "${!variable}"
done

package_e2e_log="$fixture_dir/package-e2e.log"
(
    cd Packages/HeelerSSH
    xcodebuild test \
        -scheme HeelerSSH \
        -destination "$simulator_destination" \
        -collect-test-diagnostics never
) 2>&1 | tee "$package_e2e_log"
clear_simulator_environment

if grep -q 'Suite "Session driver resource e2e" skipped' "$package_e2e_log" \
    || grep -q 'skipped:' "$package_e2e_log" \
    || ! grep -q 'Test run with 16 tests in 2 suites passed' "$package_e2e_log" \
    || ! grep -q 'Test "remote transport loss reclaims every owned native resource" passed' \
        "$package_e2e_log" \
    || ! grep -q 'Test "an abruptly severed weak link reclaims every owned native resource" passed' \
        "$package_e2e_log"; then
    echo "The mandatory HeelerSSH package suites did not execute all sixteen tests" >&2
    exit 1
fi

# The full lane runs with no fixture configured, so every fixture-backed suite
# must skip — hence the clear above. The gate is still in force, though, and
# `HEELER_SSH_E2E_REQUIRED=0` says exactly that: driven by the gate, nothing
# configured. Suites whose only remaining route is a machine-owned resource
# (PairingCeremonyE2ETests would otherwise re-target the developer's own sshd
# and rewrite their real authorized_keys) refuse it and skip; see
# RealSSHFixture.isUnderMergeGate. cleanup() unsets it again on exit.
export HEELER_SSH_E2E_REQUIRED=0
xcrun simctl spawn "$simulator_udid" launchctl setenv HEELER_SSH_E2E_REQUIRED 0

xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
