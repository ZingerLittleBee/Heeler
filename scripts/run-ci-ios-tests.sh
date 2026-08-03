#!/bin/bash

set -euo pipefail

modern_port=55222
legacy_port=55223
restricted_port=55224
stall_port=55225
streamlocal_global_policy_port=55226
streamlocal_key_policy_port=55227
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
fake_herdr_pid=""
simulator_udid=""

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
        HEELER_SSH_E2E_CONFIG; do
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
    "$streamlocal_key_policy_port"; do
    if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
        echo "TCP port $port is already in use" >&2
        exit 1
    fi
done

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
sudo -n chown "$fixture_uid":20 "$fixture_home"

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_ed25519"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$fixture_dir/host_rsa"
printf '%s\n' \
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 heeler-ci-device-key' \
    > "$fixture_dir/authorized_keys"
printf '%s\n' \
    'no-port-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAOhB7/zzhC+HXDdGOdLwJln5NYwm6UNXx3chmQSVTG4 heeler-ci-device-key' \
    > "$fixture_dir/authorized_keys-no-forwarding"

modern_config="$fixture_dir/sshd-modern.conf"
legacy_config="$fixture_dir/sshd-legacy.conf"
restricted_config="$fixture_dir/sshd-restricted.conf"
streamlocal_global_policy_config="$fixture_dir/sshd-streamlocal-global-policy.conf"
streamlocal_key_policy_config="$fixture_dir/sshd-streamlocal-key-policy.conf"

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

streamlocal_socket="$fixture_dir/herdr.sock"
streamlocal_stale_socket="$fixture_dir/stale.sock"
streamlocal_missing_socket="$fixture_dir/missing.sock"
streamlocal_count_file="$fixture_dir/streamlocal-count"
/usr/bin/python3 scripts/fixtures/fake-herdr-streamlocal.py \
    --socket "$streamlocal_socket" \
    --stale-socket "$streamlocal_stale_socket" \
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
        && [[ -S "$streamlocal_socket" ]] \
        && [[ -S "$streamlocal_stale_socket" ]]; then
        break
    fi
    if ! kill -0 "$modern_pid" 2>/dev/null \
        || ! kill -0 "$legacy_pid" 2>/dev/null \
        || ! kill -0 "$restricted_pid" 2>/dev/null \
        || ! kill -0 "$stall_pid" 2>/dev/null \
        || ! kill -0 "$streamlocal_global_policy_pid" 2>/dev/null \
        || ! kill -0 "$streamlocal_key_policy_pid" 2>/dev/null \
        || ! kill -0 "$fake_herdr_pid" 2>/dev/null; then
        cat "$fixture_dir/sshd-modern.log" >&2
        cat "$fixture_dir/sshd-legacy.log" >&2
        cat "$fixture_dir/sshd-restricted.log" >&2
        cat "$fixture_dir/sshd-streamlocal-global-policy.log" >&2
        cat "$fixture_dir/sshd-streamlocal-key-policy.log" >&2
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
    || [[ ! -S "$streamlocal_socket" ]] \
    || [[ ! -S "$streamlocal_stale_socket" ]]; then
    cat "$fixture_dir/sshd-modern.log" >&2
    cat "$fixture_dir/sshd-legacy.log" >&2
    cat "$fixture_dir/sshd-restricted.log" >&2
    cat "$fixture_dir/sshd-streamlocal-global-policy.log" >&2
    cat "$fixture_dir/sshd-streamlocal-key-policy.log" >&2
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
    '{"host":"127.0.0.1","port":%s,"legacyPort":%s,"restrictedPort":%s,"stallPort":%s,"globalPolicyPort":%s,"keyPolicyPort":%s,"username":"%s","password":"%s","streamLocalSocketPath":"%s","socketPath":"%s","staleSocketPath":"%s","missingSocketPath":"%s","countFilePath":"%s"}' \
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
    "$streamlocal_missing_socket" \
    "$streamlocal_count_file")
fixture_configuration_base64=$(printf '%s' "$fixture_configuration" | base64)
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
xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl spawn "$simulator_udid" launchctl setenv \
    HEELER_SSH_E2E_CONFIG \
    "$fixture_configuration_base64"

e2e_log="$fixture_dir/e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHSessionE2ETests \
    2>&1 | tee "$e2e_log"

if grep -q 'skipped:' "$e2e_log" \
    || ! grep -q "Test run with 14 tests in 1 suite passed" "$e2e_log"; then
    echo "The mandatory HeelerSSH real-sshd suite did not execute all fourteen tests" >&2
    exit 1
fi

streamlocal_log="$fixture_dir/streamlocal-e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHDirectStreamLocalE2ETests \
    2>&1 | tee "$streamlocal_log"

if grep -q 'skipped:' "$streamlocal_log" \
    || ! grep -q "Test run with 11 tests in 1 suite passed" "$streamlocal_log"; then
    echo "The mandatory no-socat direct-streamlocal suite did not execute all eleven tests" >&2
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
        -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
        -collect-test-diagnostics never
) 2>&1 | tee "$package_e2e_log"
clear_simulator_environment

if grep -q 'Suite "Session driver resource e2e" skipped' "$package_e2e_log" \
    || ! grep -q 'Test "remote transport loss reclaims every owned native resource" passed' \
        "$package_e2e_log"; then
    echo "The mandatory HeelerSSH native resource reclamation test did not execute" >&2
    exit 1
fi

xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -collect-test-diagnostics never
