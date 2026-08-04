#!/bin/bash

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
fixture_username="heelerssh${RANDOM}"
fixture_password="$(uuidgen)-$(uuidgen)"
fixture_uid=550
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/heeler-ssh-ci.XXXXXX")"
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
fake_herdr_pid=""
simulator_udid=""
simulator_destination=""

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
    stop_sshd "$modern_pid" "$fixture_dir/sshd-modern.pid"
    stop_sshd "$legacy_pid" "$fixture_dir/sshd-legacy.pid"
    stop_sshd "$restricted_pid" "$fixture_dir/sshd-restricted.pid"
    stop_sshd \
        "$streamlocal_global_policy_pid" \
        "$fixture_dir/sshd-streamlocal-global-policy.pid"
    stop_sshd \
        "$streamlocal_key_policy_pid" \
        "$fixture_dir/sshd-streamlocal-key-policy.pid"
    stop_sshd "$jump_target_pid" "$fixture_dir/sshd-jump-target.pid"
    stop_sshd \
        "$jump_forwarding_denied_pid" \
        "$fixture_dir/sshd-jump-forwarding-denied.pid"
    stop_sshd "$pairing_pid" "$fixture_dir/sshd-pairing.pid"
    stop_sshd \
        "$pairing_mismatched_pid" \
        "$fixture_dir/sshd-pairing-mismatched.pid"
    if dscl . -read "/Users/$fixture_username" >/dev/null 2>&1; then
        sudo -n dscl . -delete "/Users/$fixture_username"
    fi
    if [[ -d "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi

    exit "$status"
}
trap cleanup EXIT INT TERM

clear_simulator_environment() {
    if [[ -z "$simulator_udid" ]]; then
        return
    fi
    for variable in \
        HEELER_SSH_E2E_REQUIRED \
        HEELER_SSH_E2E_HOST \
        HEELER_SSH_E2E_PORT \
        HEELER_SSH_E2E_USERNAME \
        HEELER_SSH_E2E_PASSWORD \
        HEELER_SSH_E2E_LEGACY_PORT \
        HEELER_SSH_E2E_RESTRICTED_PORT \
        HEELER_SSH_E2E_STALL_PORT \
        HEELER_SSH_E2E_STREAMLOCAL_SOCKET \
        HEELER_SSH_E2E_CONFIG \
        HEELER_SSH_JUMP_E2E_CONFIG \
        HEELER_PAIRING_E2E_CONFIG; do
        xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$variable" >/dev/null 2>&1
    done
}

stop_sshd() {
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

for port in \
    "$modern_port" \
    "$legacy_port" \
    "$restricted_port" \
    "$stall_port" \
    "$streamlocal_global_policy_port" \
    "$streamlocal_key_policy_port" \
    "$jump_target_port" \
    "$jump_forwarding_denied_port" \
    "$pairing_port"; do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "TCP port $port is already in use" >&2
        exit 1
    fi
done
if nc -z ::1 "$pairing_port" >/dev/null 2>&1; then
    echo "TCP endpoint [::1]:$pairing_port is already in use" >&2
    exit 1
fi

while dscl . -search /Users UniqueID "$fixture_uid" | grep -q .; do
    fixture_uid=$((fixture_uid + 1))
done

fixture_home="$fixture_dir/home"
mkdir -p "$fixture_home"
chmod 755 "$fixture_dir"
sudo -n dscl . -create "/Users/$fixture_username"
sudo -n dscl . -create "/Users/$fixture_username" RealName "Heeler SSH CI"
sudo -n dscl . -create "/Users/$fixture_username" UserShell /bin/zsh
sudo -n dscl . -create "/Users/$fixture_username" UniqueID "$fixture_uid"
sudo -n dscl . -create "/Users/$fixture_username" PrimaryGroupID 20
sudo -n dscl . -create "/Users/$fixture_username" NFSHomeDirectory "$fixture_home"
sudo -n dscl . -create "/Users/$fixture_username" IsHidden 1
sudo -n dscl . -passwd "/Users/$fixture_username" "$fixture_password"
mkdir -p \
    "$fixture_home/.config/herdr/sessions/fixture" \
    "$fixture_home/.codex/skills/fixture" \
    "$fixture_home/.heeler-ci"
chmod 777 "$fixture_home/.heeler-ci"
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
sudo -n chown "$fixture_uid":20 "$fixture_home"

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_ed25519"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$fixture_dir/host_rsa"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_jump_target_ed25519"
printf '%s\n' \
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 heeler-ci-device-key' \
    > "$fixture_dir/authorized_keys"
printf '%s\n' \
    'no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 heeler-ci-device-key' \
    > "$fixture_dir/authorized_keys-no-forwarding"
cp "$fixture_dir/authorized_keys" "$fixture_dir/authorized_keys-jump-target"

pairing_username="$(id -un)"
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

write_common_config() {
    local port=$1
    local host_key=$2
    local pid_file=$3

    printf '%s\n' \
        "Port $port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication yes" \
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
        "LogLevel VERBOSE"
}

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
        "LogLevel VERBOSE"
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

sudo -n /usr/sbin/sshd -D -e -f "$modern_config" \
    > "$fixture_dir/sshd-modern.log" 2>&1 &
modern_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$legacy_config" \
    > "$fixture_dir/sshd-legacy.log" 2>&1 &
legacy_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$restricted_config" \
    > "$fixture_dir/sshd-restricted.log" 2>&1 &
restricted_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$streamlocal_global_policy_config" \
    > "$fixture_dir/sshd-streamlocal-global-policy.log" 2>&1 &
streamlocal_global_policy_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$streamlocal_key_policy_config" \
    > "$fixture_dir/sshd-streamlocal-key-policy.log" 2>&1 &
streamlocal_key_policy_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$jump_target_config" \
    > "$fixture_dir/sshd-jump-target.log" 2>&1 &
jump_target_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$jump_forwarding_denied_config" \
    > "$fixture_dir/sshd-jump-forwarding-denied.log" 2>&1 &
jump_forwarding_denied_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$pairing_config" \
    > "$fixture_dir/sshd-pairing.log" 2>&1 &
pairing_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$pairing_mismatched_config" \
    > "$fixture_dir/sshd-pairing-mismatched.log" 2>&1 &
pairing_mismatched_pid=$!
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

for attempt in $(seq 1 50); do
    if nc -z 127.0.0.1 "$modern_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$legacy_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$restricted_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$stall_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$streamlocal_global_policy_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$streamlocal_key_policy_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$jump_target_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$jump_forwarding_denied_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$pairing_port" >/dev/null 2>&1 \
        && nc -z ::1 "$pairing_port" >/dev/null 2>&1 \
        && [[ -S "$streamlocal_socket" ]] \
        && [[ -S "$streamlocal_stale_socket" ]] \
        && [[ -S "$streamlocal_wake_failure_socket" ]]; then
        break
    fi
    if ! kill -0 "$modern_pid" 2>/dev/null \
        || ! kill -0 "$legacy_pid" 2>/dev/null \
        || ! kill -0 "$restricted_pid" 2>/dev/null \
        || ! kill -0 "$stall_pid" 2>/dev/null \
        || ! kill -0 "$streamlocal_global_policy_pid" 2>/dev/null \
        || ! kill -0 "$streamlocal_key_policy_pid" 2>/dev/null \
        || ! kill -0 "$jump_target_pid" 2>/dev/null \
        || ! kill -0 "$jump_forwarding_denied_pid" 2>/dev/null \
        || ! kill -0 "$pairing_pid" 2>/dev/null \
        || ! kill -0 "$pairing_mismatched_pid" 2>/dev/null \
        || ! kill -0 "$fake_herdr_pid" 2>/dev/null; then
        cat "$fixture_dir/sshd-modern.log" >&2
        cat "$fixture_dir/sshd-legacy.log" >&2
        cat "$fixture_dir/sshd-restricted.log" >&2
        cat "$fixture_dir/sshd-streamlocal-global-policy.log" >&2
        cat "$fixture_dir/sshd-streamlocal-key-policy.log" >&2
        cat "$fixture_dir/sshd-jump-target.log" >&2
        cat "$fixture_dir/sshd-jump-forwarding-denied.log" >&2
        cat "$fixture_dir/sshd-pairing.log" >&2
        cat "$fixture_dir/sshd-pairing-mismatched.log" >&2
        cat "$fixture_dir/fake-herdr.log" >&2
        exit 1
    fi
    sleep 0.1
done

if ! nc -z 127.0.0.1 "$modern_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$legacy_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$restricted_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$stall_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$streamlocal_global_policy_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$streamlocal_key_policy_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$jump_target_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$jump_forwarding_denied_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$pairing_port" >/dev/null 2>&1 \
    || ! nc -z ::1 "$pairing_port" >/dev/null 2>&1 \
    || [[ ! -S "$streamlocal_socket" ]] \
    || [[ ! -S "$streamlocal_stale_socket" ]] \
    || [[ ! -S "$streamlocal_wake_failure_socket" ]]; then
    cat "$fixture_dir/sshd-modern.log" >&2
    cat "$fixture_dir/sshd-legacy.log" >&2
    cat "$fixture_dir/sshd-restricted.log" >&2
    cat "$fixture_dir/sshd-streamlocal-global-policy.log" >&2
    cat "$fixture_dir/sshd-streamlocal-key-policy.log" >&2
    cat "$fixture_dir/sshd-jump-target.log" >&2
    cat "$fixture_dir/sshd-jump-forwarding-denied.log" >&2
    cat "$fixture_dir/sshd-pairing.log" >&2
    cat "$fixture_dir/sshd-pairing-mismatched.log" >&2
    cat "$fixture_dir/fake-herdr.log" >&2
    exit 1
fi

export HEELER_SSH_E2E_REQUIRED=1
export HEELER_SSH_E2E_HOST=127.0.0.1
export HEELER_SSH_E2E_PORT="$modern_port"
export HEELER_SSH_E2E_LEGACY_PORT="$legacy_port"
export HEELER_SSH_E2E_RESTRICTED_PORT="$restricted_port"
export HEELER_SSH_E2E_STALL_PORT="$stall_port"
export HEELER_SSH_E2E_USERNAME="$fixture_username"
export HEELER_SSH_E2E_PASSWORD="$fixture_password"
export HEELER_SSH_E2E_STREAMLOCAL_SOCKET="$streamlocal_socket"

fixture_configuration=$(printf \
    '{"host":"127.0.0.1","port":%s,"legacyPort":%s,"restrictedPort":%s,"stallPort":%s,"globalPolicyPort":%s,"keyPolicyPort":%s,"username":"%s","password":"%s","streamLocalSocketPath":"%s","socketPath":"%s","staleSocketPath":"%s","wakeFailureStaleSocketPath":"%s","missingSocketPath":"%s","countFilePath":"%s","homePath":"%s"}' \
    "$modern_port" \
    "$legacy_port" \
    "$restricted_port" \
    "$stall_port" \
    "$streamlocal_global_policy_port" \
    "$streamlocal_key_policy_port" \
    "$fixture_username" \
    "$fixture_password" \
    "$streamlocal_socket" \
    "$streamlocal_socket" \
    "$streamlocal_stale_socket" \
    "$streamlocal_wake_failure_socket" \
    "$streamlocal_missing_socket" \
    "$streamlocal_count_file" \
    "$fixture_home")
fixture_configuration_base64=$(printf '%s' "$fixture_configuration" | base64)
jump_fixture_configuration=$(printf \
    '{"host":"127.0.0.1","jumpPort":%s,"forwardingDeniedPort":%s,"targetHost":"127.0.0.1","targetPort":%s,"outerStallPort":%s,"innerStallHost":"127.0.0.1","innerStallPort":%s,"username":"%s","socketPath":"%s"}' \
    "$modern_port" \
    "$jump_forwarding_denied_port" \
    "$jump_target_port" \
    "$stall_port" \
    "$stall_port" \
    "$fixture_username" \
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
    '{"host":"127.0.0.1","port":%s,"mismatchedHostAddress":"::1","username":"%s","nodePath":"%s","acceptScriptPath":"%s","homePath":"%s","authorizedKeysPath":"%s","localStateRoot":"%s","remoteStateRoot":"%s"}' \
    "$pairing_port" \
    "$pairing_username" \
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

e2e_log="$fixture_dir/e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHSessionE2ETests \
    2>&1 | tee "$e2e_log"

if grep -q 'skipped:' "$e2e_log" \
    || ! grep -q "Test run with 14 tests in 1 suite passed" "$e2e_log"; then
    echo "The mandatory HeelerSSH real-sshd suite did not execute all fourteen tests" >&2
    exit 1
fi

pty_log="$fixture_dir/pty-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHPTYE2ETests \
    2>&1 | tee "$pty_log"

if grep -q 'skipped:' "$pty_log" \
    || ! grep -q "Test run with 3 tests in 1 suite passed" "$pty_log"; then
    echo "The mandatory HeelerSSH PTY suite did not execute all three tests" >&2
    exit 1
fi

streamlocal_log="$fixture_dir/streamlocal-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHDirectStreamLocalE2ETests \
    2>&1 | tee "$streamlocal_log"

if grep -q 'skipped:' "$streamlocal_log" \
    || ! grep -q "Test run with 11 tests in 1 suite passed" "$streamlocal_log"; then
    echo "The mandatory direct-streamlocal suite did not execute all eleven tests" >&2
    exit 1
fi

jump_log="$fixture_dir/jump-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHJumpHostGateE2ETests \
    2>&1 | tee "$jump_log"

if grep -q 'skipped:' "$jump_log" \
    || ! grep -q "Test run with 9 tests in 1 suite passed" "$jump_log"; then
    echo "The mandatory HeelerSSH Jump Host gate suite did not execute" >&2
    exit 1
fi

transport_behavior_log="$fixture_dir/transport-behavior-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHTransportBehaviorE2ETests \
    2>&1 | tee "$transport_behavior_log"

if grep -q 'skipped:' "$transport_behavior_log" \
    || ! grep -q "Test run with 28 tests in 1 suite passed" "$transport_behavior_log"; then
    echo "The mandatory HeelerSSH Transport suite did not execute all twenty-eight tests" >&2
    exit 1
fi

image_staging_log="$fixture_dir/image-staging-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/ImageStagingE2ETests \
    2>&1 | tee "$image_staging_log"

if grep -q 'skipped:' "$image_staging_log" \
    || ! grep -q "Test run with 7 tests in 1 suite passed" "$image_staging_log"; then
    echo "The mandatory HeelerSSH image-staging suite did not execute all seven tests" >&2
    exit 1
fi

pairing_log="$fixture_dir/pairing-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/PairingCeremonyE2ETests \
    2>&1 | tee "$pairing_log"

if grep -q 'skipped:' "$pairing_log" \
    || ! grep -q "Test run with 11 tests in 1 suite passed" "$pairing_log"; then
    echo "The mandatory Pairing ceremony suite did not execute all eleven tests" >&2
    exit 1
fi

for variable in \
    HEELER_SSH_E2E_REQUIRED \
    HEELER_SSH_E2E_HOST \
    HEELER_SSH_E2E_PORT \
    HEELER_SSH_E2E_USERNAME \
    HEELER_SSH_E2E_PASSWORD; do
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
    || ! grep -q 'Test run with 14 tests in 2 suites passed' "$package_e2e_log" \
    || ! grep -q 'Test "remote transport loss reclaims every owned native resource" passed' \
        "$package_e2e_log"; then
    echo "The mandatory HeelerSSH package suites did not execute all fourteen tests" >&2
    exit 1
fi

xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
