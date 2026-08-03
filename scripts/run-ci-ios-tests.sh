#!/bin/bash

set -euo pipefail

modern_port=55222
legacy_port=55223
fixture_username="heelerssh${RANDOM}"
fixture_password="$(uuidgen)-$(uuidgen)"
fixture_uid=550
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/heeler-ssh-ci.XXXXXX")"
modern_pid=""
legacy_pid=""

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e

    stop_sshd "$modern_pid" "$fixture_dir/sshd-modern.pid"
    stop_sshd "$legacy_pid" "$fixture_dir/sshd-legacy.pid"
    if dscl . -read "/Users/$fixture_username" >/dev/null 2>&1; then
        sudo -n dscl . -delete "/Users/$fixture_username"
    fi
    if [[ -d "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi

    exit "$status"
}
trap cleanup EXIT INT TERM

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

for port in "$modern_port" "$legacy_port"; do
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

modern_config="$fixture_dir/sshd-modern.conf"
legacy_config="$fixture_dir/sshd-legacy.conf"

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
        "PubkeyAuthentication no" \
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

sudo -n /usr/sbin/sshd -D -e -f "$modern_config" \
    > "$fixture_dir/sshd-modern.log" 2>&1 &
modern_pid=$!
sudo -n /usr/sbin/sshd -D -e -f "$legacy_config" \
    > "$fixture_dir/sshd-legacy.log" 2>&1 &
legacy_pid=$!

for attempt in $(seq 1 50); do
    if nc -z 127.0.0.1 "$modern_port" >/dev/null 2>&1 \
        && nc -z 127.0.0.1 "$legacy_port" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$modern_pid" 2>/dev/null || ! kill -0 "$legacy_pid" 2>/dev/null; then
        cat "$fixture_dir/sshd-modern.log" >&2
        cat "$fixture_dir/sshd-legacy.log" >&2
        exit 1
    fi
    sleep 0.1
done

if ! nc -z 127.0.0.1 "$modern_port" >/dev/null 2>&1 \
    || ! nc -z 127.0.0.1 "$legacy_port" >/dev/null 2>&1; then
    cat "$fixture_dir/sshd-modern.log" >&2
    cat "$fixture_dir/sshd-legacy.log" >&2
    exit 1
fi

export HEELER_SSH_E2E_REQUIRED=1
export HEELER_SSH_E2E_HOST=127.0.0.1
export HEELER_SSH_E2E_PORT="$modern_port"
export HEELER_SSH_E2E_LEGACY_PORT="$legacy_port"
export HEELER_SSH_E2E_USERNAME="$fixture_username"
export HEELER_SSH_E2E_PASSWORD="$fixture_password"

e2e_log="$fixture_dir/e2e.log"
xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -collect-test-diagnostics never \
    -only-testing:HeelerTests/HeelerSSHSessionE2ETests \
    2>&1 | tee "$e2e_log"

if grep -q 'Suite "HeelerSSH session e2e" skipped' "$e2e_log" \
    || ! grep -q "Test run with 7 tests in 1 suite passed" "$e2e_log"; then
    echo "The mandatory HeelerSSH real-sshd suite did not execute all seven tests" >&2
    exit 1
fi

xcodebuild test \
    -project Heeler.xcodeproj \
    -scheme Heeler \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -collect-test-diagnostics never
