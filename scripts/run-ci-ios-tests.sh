#!/bin/bash
# Unprivileged loopback SSH fixtures and iOS Simulator test runner for CI and local parity.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
fixture_python="$(command -v python3)"

ci_lane="${HEELER_CI_LANE:-app}"
case "$ci_lane" in
    app | package) ;;
    *) echo "HEELER_CI_LANE must be app or package, got: $ci_lane" >&2; exit 2 ;;
esac

ci_app_shard="${HEELER_CI_APP_SHARD:-all}"
case "$ci_app_shard" in
    all | session-weak | transport | ordinary) ;;
    *) echo "Invalid HEELER_CI_APP_SHARD: $ci_app_shard" >&2; exit 2 ;;
esac

app_products_archive="${HEELER_CI_APP_PRODUCTS_ARCHIVE:-}"
package_products_archive="${HEELER_CI_PACKAGE_PRODUCTS_ARCHIVE:-}"

fixture_dir="$(mktemp -d /tmp/heeler-ci.XXXXXX)"
app_derived_data_path="${HEELER_CI_APP_DERIVED_DATA_PATH:-$fixture_dir/AppDerivedData}"
owned_app_build_directory=""
if [[ "$ci_lane" == app && -n "${HEELER_CI_APP_DERIVED_DATA_PATH:-}" ]]; then
    mkdir -p "$(dirname "$app_derived_data_path")"
    mkdir "$app_derived_data_path"
    owned_app_build_directory="$app_derived_data_path"
fi
package_derived_data_path="$fixture_dir/PackageDerivedData"
source_packages_dir="${HEELER_CI_SOURCE_PACKAGES_DIR:-$repo_root/.ci/source-packages}"
core_archive_cache_dir="${HEELER_CI_CORE_ARCHIVE_DIR:-$repo_root/.ci/herdr-core-archive}"
diagnostic_root="${RUNNER_TEMP:-/tmp}/heeler-ci-diagnostics-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-1}"
fixture_username="$(id -un)"
fixture_home="$fixture_dir/home"

simulator_udid=""
simulator_destination=""
simulator_environment_variables=()
unprivileged_sshd_pids=()
stall_pid=""
fake_herdr_pid=""
weak_network_pid=""
core_fixture_dir=""
tmux_fixture_dir=""
tmux_fixture_executable=""
app_base_xctestrun=""
package_base_xctestrun=""

clear_simulator_environment() {
    [[ -n "$simulator_udid" && "${#simulator_environment_variables[@]}" -gt 0 ]] || return 0
    local variable pid
    local -a pids=()
    for variable in "${simulator_environment_variables[@]}"; do
        xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$variable" >/dev/null 2>&1 &
        pids+=("$!")
        unset "$variable"
    done
    simulator_environment_variables=()
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}

push_simulator_environment() {
    simulator_environment_variables=("$@")
    local variable pid status=0
    local -a pids=()
    for variable in "$@"; do
        xcrun simctl spawn "$simulator_udid" launchctl setenv "$variable" "${!variable}" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || status=1
    done
    return "$status"
}

stop_core_fixture() {
    [[ -n "$core_fixture_dir" ]] || return 0
    [[ ! -f "$core_fixture_dir/logs/sshd.log" ]] || cp "$core_fixture_dir/logs/sshd.log" "$fixture_dir/herdr-core-sshd.log" 2>/dev/null || true
    "$fixture_python" "$repo_root/scripts/fixtures/herdr-core-ssh.py" stop --root "$core_fixture_dir" || true
    core_fixture_dir=""
}

stop_tmux_fixture() {
    [[ -n "$tmux_fixture_dir" ]] || return 0
    [[ ! -f "$tmux_fixture_dir/logs/sshd.log" ]] || cp "$tmux_fixture_dir/logs/sshd.log" "$fixture_dir/tmux-sshd.log" 2>/dev/null || true
    "$fixture_python" "$repo_root/scripts/fixtures/tmux-ssh.py" stop --root "$tmux_fixture_dir" || true
    tmux_fixture_dir=""
}

preserve_failure_diagnostics() {
    local status=$1
    [[ "$status" -ne 0 ]] || return 0
    local dest="$diagnostic_root/fixture"
    mkdir -p "$dest/logs"
    printf '%s\n' "$status" > "$dest/exit-status.txt"
    local log
    for log in "$fixture_dir"/*.log; do
        [[ -f "$log" ]] || continue
        cp "$log" "$dest/logs/" 2>/dev/null || true
    done
    for dir in "$app_derived_data_path/Logs/Test" "$package_derived_data_path/Logs/Test"; do
        if [[ -d "$dir" ]]; then
            local name
            name="$(basename "$(dirname "$(dirname "$dir")")")-Logs-Test"
            mkdir -p "$dest/$name"
            cp -R "$dir/." "$dest/$name/" 2>/dev/null || true
        fi
    done
    for log in "$fixture_dir"/sshd-*.log "$fixture_dir"/weak-network.log "$fixture_dir"/fake-herdr.log \
        "$fixture_dir"/herdr-core-sshd.log "$fixture_dir"/tmux-sshd.log "$fixture_dir"/stall-server.log; do
        [[ -s "$log" ]] || continue
        echo "===== $log (last 60 lines)" >&2
        tail -n 60 "$log" >&2
    done
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    clear_simulator_environment
    stop_core_fixture
    stop_tmux_fixture
    local pid
    for pid in "$stall_pid" "$fake_herdr_pid" "$weak_network_pid" "${unprivileged_sshd_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" >/dev/null 2>&1
            wait "$pid" 2>/dev/null
        fi
    done
    preserve_failure_diagnostics "$status"
    rm -rf -- "$fixture_dir"
    if [[ -n "$owned_app_build_directory" ]]; then
        rm -rf -- "$owned_app_build_directory"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

select_simulator() {
    "$fixture_python" - "${HEELER_CI_SIMULATOR_UDID:-}" "${HEELER_CI_SIMULATOR_NAME:-iPhone 17}" "${HEELER_CI_SIMULATOR_OS:-}" <<'PYSIM'
import json, subprocess, sys

pinned, name, requested_os = sys.argv[1], sys.argv[2], sys.argv[3]
if pinned:
    print(pinned)
    raise SystemExit(0)

runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
candidates = []
for runtime in runtimes:
    if not runtime.get("isAvailable") or runtime.get("platform") != "iOS":
        continue
    if requested_os and runtime.get("version") != requested_os:
        continue
    version = tuple(int(part) for part in runtime["version"].split("."))
    for device in devices.get(runtime["identifier"], []):
        if device.get("name") == name:
            candidates.append((version, device["udid"]))
if not candidates:
    raise SystemExit(f"No available simulator matches name={name!r} os={requested_os!r}")
latest = max(v for v, _ in candidates)
matching = [udid for v, udid in candidates if v == latest]
print(matching[-1])
PYSIM
}

find_app_xctestrun() {
    local candidate
    app_base_xctestrun=""
    for candidate in "$app_derived_data_path"/Build/Products/Heeler_*.xctestrun; do
        [[ "$candidate" == *Heeler-ci-active.xctestrun ]] && continue
        if [[ -f "$candidate" ]]; then
            app_base_xctestrun="$candidate"
            return 0
        fi
    done
    return 1
}

find_package_xctestrun() {
    local candidate
    package_base_xctestrun=""
    for candidate in "$package_derived_data_path"/Build/Products/HeelerSSH_*.xctestrun; do
        if [[ -f "$candidate" ]]; then
            package_base_xctestrun="$candidate"
            return 0
        fi
    done
    return 1
}

prepare_active_xctestrun() {
    local output="$app_derived_data_path/Build/Products/Heeler-ci-active.xctestrun"
    "$fixture_python" - "$app_base_xctestrun" "$output" "${HEELER_SSH_E2E_REQUIRED:-}" <<'PYXCTESTRUN'
import os, plistlib, sys
from pathlib import Path

source, dest, required = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
data = plistlib.loads(source.read_bytes())
for key, value in data.items():
    if key == "__xctestrun_metadata__" or not isinstance(value, dict):
        continue
    env = dict(value.get("EnvironmentVariables") or {})
    env["HEELER_SSH_E2E_REQUIRED"] = required
    value["EnvironmentVariables"] = env
    test_env = dict(value.get("TestingEnvironmentVariables") or {})
    dyld = test_env.get("DYLD_INSERT_LIBRARIES")
    if isinstance(dyld, str) and dyld:
        kept = [
            entry for entry in dyld.split(":")
            if not entry.startswith("/var/run/com.apple.security.cryptexd/") or os.path.exists(entry)
        ]
        test_env["DYLD_INSERT_LIBRARIES"] = ":".join(kept)
        value["TestingEnvironmentVariables"] = test_env
dest.write_bytes(plistlib.dumps(data))
PYXCTESTRUN
    printf '%s\n' "$output"
}

boot_simulator() {
    xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$simulator_udid" -b
    if [[ "${CI:-}" == "true" || "${CI:-}" == "1" ]]; then
        xcrun simctl spawn "$simulator_udid" defaults write com.apple.Accessibility AccessibilityEnabled -bool true &
        local p1=$!
        xcrun simctl spawn "$simulator_udid" defaults write com.apple.Accessibility ApplicationAccessibilityEnabled -int 1 &
        local p2=$!
        wait "$p1" && wait "$p2"
    fi
}

run_xcodebuild() {
    local label=$1
    local log=$2
    shift 2
    local started=$SECONDS status=0
    echo "::group::$label"
    if (cd "$repo_root" && xcodebuild "$@") 2>&1 | tee "$log"; then
        status=0
    else
        status=$?
    fi
    echo "::endgroup::"
    echo "==> $label: $((SECONDS - started))s (status $status)"
    return "$status"
}

run_app_test_bundle() {
    local label=$1
    local log=$2
    shift 2
    local safe_label
    safe_label=$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '-')
    mkdir -p "$app_derived_data_path/Logs/Test"
    local bundle="$app_derived_data_path/Logs/Test/${safe_label}.xcresult"
    rm -rf -- "$bundle"
    if [[ -n "$app_base_xctestrun" ]]; then
        local active_xctestrun
        active_xctestrun=$(prepare_active_xctestrun)
        run_xcodebuild "$label" "$log" \
            test-without-building \
            -xctestrun "$active_xctestrun" \
            -destination "$simulator_destination" \
            -resultBundlePath "$bundle" \
            -collect-test-diagnostics never \
            "$@"
    else
        run_xcodebuild "$label" "$log" \
            test-without-building \
            -disableAutomaticPackageResolution \
            -project Heeler.xcodeproj \
            -scheme Heeler \
            -derivedDataPath "$app_derived_data_path" \
            -clonedSourcePackagesDirPath "$source_packages_dir" \
            -destination "$simulator_destination" \
            -resultBundlePath "$bundle" \
            -collect-test-diagnostics never \
            "$@"
    fi
}

simulator_udid="$(select_simulator)"
simulator_destination="platform=iOS Simulator,id=$simulator_udid"
echo "==> Selected simulator $simulator_udid"

# Unpack prebuilt archives before booting the Simulator to avoid cold-boot disk contention.
if [[ -n "$app_products_archive" ]]; then
    mkdir -p "$app_derived_data_path"
    tar -xf "$app_products_archive" -C "$app_derived_data_path"
    find_app_xctestrun
fi
if [[ -n "$package_products_archive" ]]; then
    mkdir -p "$package_derived_data_path"
    tar -xf "$package_products_archive" -C "$package_derived_data_path"
    find_package_xctestrun
fi

# Ordinary unit/integration shard needs no SSH fixtures.
if [[ "$ci_lane" == app && "$ci_app_shard" == ordinary ]]; then
    export HEELER_SSH_E2E_REQUIRED=0
    xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
    if [[ -z "$app_products_archive" ]]; then
        mkdir -p "$source_packages_dir"
        run_xcodebuild "Build for testing" "$fixture_dir/build-for-testing.log" \
            build-for-testing -project Heeler.xcodeproj -scheme Heeler \
            -derivedDataPath "$app_derived_data_path" \
            -clonedSourcePackagesDirPath "$source_packages_dir" \
            -destination "$simulator_destination" \
            -collect-test-diagnostics never COMPILER_INDEX_STORE_ENABLE=NO
        find_app_xctestrun || true
    fi
    boot_simulator
    push_simulator_environment HEELER_SSH_E2E_REQUIRED
    run_app_test_bundle "Full app test lane" "$fixture_dir/full-lane.log"
    exit 0
fi

# Provision unprivileged loopback SSH fixtures.
read -r base_port core_port < <("$fixture_python" - "${HEELER_CI_PORT_BASE:-55222}" <<'PYPORTS'
import socket, sys

def free(port: int) -> bool:
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        with socket.socket(family, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((host, port))
            except OSError:
                return False
    return True

start = int(sys.argv[1])
base = next(
    (cand for cand in range(start, start + 12 * 16, 12) if all(free(cand + i) for i in range(12))),
    None,
)
if base is None:
    raise SystemExit("Could not find 12 contiguous free loopback ports")
core = next(
    (cand for cand in range(55400, 55464) if not (base <= cand < base + 12) and free(cand)),
    None,
)
if core is None:
    raise SystemExit("Could not find a free core fixture port")
print(base, core)
PYPORTS
)

modern_port=$((base_port + 0))
legacy_port=$((base_port + 1))
restricted_port=$((base_port + 2))
stall_port=$((base_port + 3))
streamlocal_global_policy_port=$((base_port + 4))
streamlocal_key_policy_port=$((base_port + 5))
jump_target_port=$((base_port + 6))
jump_forwarding_denied_port=$((base_port + 7))
pairing_port=$((base_port + 8))
weak_network_port=$((base_port + 9))
weak_network_control_port=$((base_port + 10))
post_quantum_port=$((base_port + 11))

sftp_server=""
for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server; do
    if [[ -x "$candidate" ]]; then
        sftp_server="$candidate"
        break
    fi
done
[[ -n "$sftp_server" ]] || { echo "No sftp-server binary found" >&2; exit 1; }

if [[ "$ci_lane" == app && ( "$ci_app_shard" == all || "$ci_app_shard" == transport ) ]]; then
    for candidate in "${HEELER_CI_TMUX:-}" "$(command -v tmux 2>/dev/null || true)" /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            tmux_fixture_executable="$candidate"
            break
        fi
    done
    [[ -n "$tmux_fixture_executable" ]] || { echo "tmux is required for transport E2E" >&2; exit 1; }
fi

chmod 755 "$fixture_dir"
mkdir -p \
    "$fixture_home/.config/herdr/sessions/fixture" \
    "$fixture_home/.codex/skills/fixture" \
    "$fixture_home/.heeler-ci" \
    "$fixture_dir/bin"

printf '%s\n' '---' 'name: fixture' 'description: Real SSH fixture skill.' '---' 'Fixture body.' \
    > "$fixture_home/.codex/skills/fixture/SKILL.md"

# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'stty -echo' \
    'printf "\\033[?1016\\044p\\033[c"' \
    'printf "TTY-OK\\n"' \
    'printf "ARGS:%s\\n" "$*"' \
    'printf "SOCKET:%s\\n" "$HERDR_SOCKET_PATH"' \
    'stty size' \
    'while IFS= read -r line; do' \
    '    case "$line" in' \
    '        __exit__) exit 0 ;;' \
    '        __fail__) printf "herdr: fixture attach failed\\n"; exit 23 ;;' \
    '        __end_race__)' \
    '            printf "END-RACE-READY\\n"; sleep 1' \
    '            printf "END-RACE-BEFORE\\n"; sleep 10' \
    '            printf "END-RACE-AFTER\\n"; continue ;;' \
    '    esac' \
    '    printf "GOT:%s\\n" "$line"' \
    '    stty size' \
    'done' \
    > "$fixture_home/.heeler-ci/fake-attach"
chmod 755 "$fixture_home/.heeler-ci/fake-attach"

pairing_node_path=""
if [[ "$ci_lane" == app ]]; then
    pairing_node_path="$(command -v node)" || { echo "Node is required for app SSH E2E" >&2; exit 1; }
    mkdir -p "$fixture_home/.heeler-ci/usage-plugin"
    cp -R "$repo_root/plugin/src" "$fixture_home/.heeler-ci/usage-plugin/src"
    cp "$repo_root/plugin/package.json" "$fixture_home/.heeler-ci/usage-plugin/package.json"
    ln -s "$pairing_node_path" "$fixture_home/.heeler-ci/usage-node"
fi

printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_dir/bin/herdr"
chmod 755 "$fixture_dir/bin/herdr"

fixture_session_path="$fixture_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for entry in "$fixture_dir/bin" /usr/bin /bin /usr/sbin /sbin; do
    [[ ! -x "$entry/socat" ]] || { echo "socat must not exist in $entry" >&2; exit 1; }
done

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_ed25519"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$fixture_dir/host_rsa"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_jump_target_ed25519"
ssh-keygen -q -t ed25519 -N '' -C heeler-ci-device-key -f "$fixture_dir/device_key"
device_key_seed="$("$fixture_python" "$repo_root/scripts/fixtures/openssh-ed25519-seed.py" "$fixture_dir/device_key")"
cp "$fixture_dir/device_key.pub" "$fixture_dir/authorized_keys"

/usr/bin/openssl genrsa -out "$fixture_dir/rsa_key.pem" 3072 >/dev/null 2>&1
chmod 600 "$fixture_dir/rsa_key.pem"
/usr/bin/openssl rsa -in "$fixture_dir/rsa_key.pem" -outform DER -out "$fixture_dir/rsa_key.der" >/dev/null 2>&1
printf '%s heeler-ci-rsa-key\n' "$(ssh-keygen -y -f "$fixture_dir/rsa_key.pem")" >> "$fixture_dir/authorized_keys"
rsa_key_der="$(base64 < "$fixture_dir/rsa_key.der" | tr -d '\n')"
printf 'no-port-forwarding %s\n' "$(<"$fixture_dir/device_key.pub")" > "$fixture_dir/authorized_keys-no-forwarding"
cp "$fixture_dir/authorized_keys" "$fixture_dir/authorized_keys-jump-target"

pairing_home="$fixture_dir/pairing-home"
pairing_authorized_keys="$pairing_home/.ssh/authorized_keys"
pairing_state_root="$fixture_dir/pairing-state"
mkdir -p "$pairing_home/.ssh" "$pairing_state_root"
cp "$fixture_dir/authorized_keys" "$pairing_authorized_keys"
chmod 700 "$pairing_home/.ssh"
chmod 600 "$pairing_authorized_keys"

force_posix_shell="exec /bin/sh -c 'PATH=$fixture_session_path; export PATH;"
force_posix_shell+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
force_posix_shell+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"

write_common_config() {
    local port=$1 host_key=$2 pid_file=$3 auth_keys=${4:-$fixture_dir/authorized_keys}
    printf '%s\n' \
        "Port $port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512" \
        "AuthorizedKeysFile $auth_keys" \
        "UsePAM no" \
        "PermitRootLogin no" \
        "AllowUsers $fixture_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel DEBUG1" \
        "Subsystem sftp $sftp_server" \
        "SetEnv HOME=$fixture_home" \
        "ForceCommand $force_posix_shell"
}

write_pairing_config() {
    printf '%s\n' \
        "Port $pairing_port" \
        "ListenAddress $1" \
        "HostKey $2" \
        "PidFile $3" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $pairing_authorized_keys" \
        "UsePAM no" \
        "PermitRootLogin no" \
        "AllowUsers $fixture_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel DEBUG1" \
        "Subsystem sftp $sftp_server"
}

start_sshd() {
    /usr/sbin/sshd -D -e -f "$1" > "$2" 2>&1 &
    unprivileged_sshd_pids+=("$!")
}

{ write_common_config "$modern_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-modern.pid"; echo "KexAlgorithms curve25519-sha256"; } > "$fixture_dir/sshd-modern.conf"
{ write_common_config "$post_quantum_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-pq.pid"; echo "KexAlgorithms mlkem768x25519-sha256"; } > "$fixture_dir/sshd-pq.conf"
{ write_common_config "$legacy_port" "$fixture_dir/host_rsa" "$fixture_dir/sshd-legacy.pid"; echo "HostKeyAlgorithms ssh-rsa"; } > "$fixture_dir/sshd-legacy.conf"
{ write_common_config "$restricted_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-restricted.pid"; printf '%s\n' "KexAlgorithms curve25519-sha256" "MaxSessions 0"; } > "$fixture_dir/sshd-restricted.conf"
{ write_common_config "$streamlocal_global_policy_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-sl-global.pid"; printf '%s\n' "AllowTcpForwarding yes" "AllowStreamLocalForwarding no"; } > "$fixture_dir/sshd-sl-global.conf"
{ write_common_config "$streamlocal_key_policy_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-sl-key.pid" "$fixture_dir/authorized_keys-no-forwarding"; printf '%s\n' "AllowTcpForwarding yes" "AllowStreamLocalForwarding yes"; } > "$fixture_dir/sshd-sl-key.conf"
{ write_common_config "$jump_target_port" "$fixture_dir/host_jump_target_ed25519" "$fixture_dir/sshd-jump.pid" "$fixture_dir/authorized_keys-jump-target"; printf '%s\n' "AllowTcpForwarding yes" "AllowStreamLocalForwarding yes"; } > "$fixture_dir/sshd-jump.conf"
{ write_common_config "$jump_forwarding_denied_port" "$fixture_dir/host_ed25519" "$fixture_dir/sshd-jump-denied.pid"; printf '%s\n' "AllowTcpForwarding no" "AllowStreamLocalForwarding yes"; } > "$fixture_dir/sshd-jump-denied.conf"
write_pairing_config 127.0.0.1 "$fixture_dir/host_ed25519" "$fixture_dir/sshd-pairing.pid" > "$fixture_dir/sshd-pairing.conf"
write_pairing_config ::1 "$fixture_dir/host_jump_target_ed25519" "$fixture_dir/sshd-pairing-v6.pid" > "$fixture_dir/sshd-pairing-v6.conf"

streamlocal_socket="$fixture_home/.config/herdr/herdr.sock"
streamlocal_stale_socket="$fixture_home/.heeler-ci/stale.sock"
streamlocal_wake_failure_socket="$fixture_home/.heeler-ci/stale-wake-failure.sock"
streamlocal_missing_socket="$fixture_home/.heeler-ci/missing.sock"
streamlocal_count_file="$fixture_home/.heeler-ci/streamlocal-count"
ln -s "$streamlocal_socket" "$fixture_home/.config/herdr/sessions/fixture/herdr.sock"

"$fixture_python" "$repo_root/scripts/fixtures/fake-herdr-streamlocal.py" \
    --socket "$streamlocal_socket" \
    --stale-socket "$streamlocal_stale_socket" \
    --stale-socket "$streamlocal_wake_failure_socket" \
    --count-file "$streamlocal_count_file" \
    > "$fixture_dir/fake-herdr.log" 2>&1 &
fake_herdr_pid=$!

"$fixture_python" "$repo_root/scripts/fixtures/weak-network-proxy.py" \
    --listen-port "$weak_network_port" \
    --control-port "$weak_network_control_port" \
    --target-host 127.0.0.1 \
    --target-port "$modern_port" \
    > "$fixture_dir/weak-network.log" 2>&1 &
weak_network_pid=$!

"$fixture_python" -u -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen()
conns = []
while True:
    c, _ = s.accept()
    conns.append(c)
' "$stall_port" > "$fixture_dir/stall-server.log" 2>&1 &
stall_pid=$!

for name in modern pq legacy restricted sl-global sl-key jump jump-denied pairing pairing-v6; do
    start_sshd "$fixture_dir/sshd-$name.conf" "$fixture_dir/sshd-$name.log"
done

"$fixture_python" - "$pairing_port" \
    "$streamlocal_socket" "$streamlocal_stale_socket" "$streamlocal_wake_failure_socket" \
    "$modern_port" "$post_quantum_port" "$legacy_port" "$restricted_port" "$stall_port" \
    "$streamlocal_global_policy_port" "$streamlocal_key_policy_port" "$jump_target_port" \
    "$jump_forwarding_denied_port" "$weak_network_port" "$weak_network_control_port" <<'PYWAIT'
import os, socket, sys, time

pairing_port = int(sys.argv[1])
sockets = sys.argv[2:5]
ports = [int(p) for p in sys.argv[5:]]

def ready() -> bool:
    for port in ports + [pairing_port]:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", port)) != 0:
                return False
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
        if s.connect_ex(("::1", pairing_port)) != 0:
            return False
    return all(os.path.exists(path) for path in sockets)

for _ in range(60):
    if ready():
        raise SystemExit(0)
    time.sleep(0.1)
raise SystemExit("Timed out waiting for SSH fixture daemons to listen")
PYWAIT

export HEELER_SSH_E2E_REQUIRED=1
export HEELER_SSH_E2E_HOST=127.0.0.1
export HEELER_SSH_E2E_PORT="$modern_port"
export HEELER_SSH_E2E_PQ_PORT="$post_quantum_port"
export HEELER_SSH_E2E_LEGACY_PORT="$legacy_port"
export HEELER_SSH_E2E_RESTRICTED_PORT="$restricted_port"
export HEELER_SSH_E2E_STALL_PORT="$stall_port"
export HEELER_SSH_E2E_USERNAME="$fixture_username"
export HEELER_SSH_E2E_DEVICE_KEY_SEED="$device_key_seed"
export HEELER_SSH_E2E_STREAMLOCAL_SOCKET="$streamlocal_socket"
export HEELER_SSH_E2E_WEAK_PORT="$weak_network_port"
export HEELER_SSH_E2E_WEAK_CONTROL_PORT="$weak_network_control_port"

fixture_configuration_base64=$(printf \
    '{"host":"127.0.0.1","port":%s,"legacyPort":%s,"restrictedPort":%s,"stallPort":%s,"globalPolicyPort":%s,"keyPolicyPort":%s,"weakNetworkPort":%s,"weakNetworkControlPort":%s,"username":"%s","deviceKeySeed":"%s","rsaKeyDER":"%s","passwordFixture":null,"streamLocalSocketPath":"%s","socketPath":"%s","staleSocketPath":"%s","wakeFailureStaleSocketPath":"%s","missingSocketPath":"%s","countFilePath":"%s","homePath":"%s"}' \
    "$modern_port" "$legacy_port" "$restricted_port" "$stall_port" \
    "$streamlocal_global_policy_port" "$streamlocal_key_policy_port" \
    "$weak_network_port" "$weak_network_control_port" \
    "$fixture_username" "$device_key_seed" "$rsa_key_der" \
    "$streamlocal_socket" "$streamlocal_socket" "$streamlocal_stale_socket" \
    "$streamlocal_wake_failure_socket" "$streamlocal_missing_socket" \
    "$streamlocal_count_file" "$fixture_home" | base64 | tr -d '\n')

jump_fixture_configuration_base64=$(printf \
    '{"host":"127.0.0.1","jumpPort":%s,"forwardingDeniedPort":%s,"targetHost":"127.0.0.1","targetPort":%s,"outerStallPort":%s,"innerStallHost":"127.0.0.1","innerStallPort":%s,"username":"%s","deviceKeySeed":"%s","socketPath":"%s"}' \
    "$modern_port" "$jump_forwarding_denied_port" "$jump_target_port" \
    "$stall_port" "$stall_port" "$fixture_username" "$device_key_seed" "$streamlocal_socket" | base64 | tr -d '\n')

pairing_fixture_configuration_base64=""
if [[ "$ci_lane" == app ]]; then
    pairing_fixture_configuration_base64=$(printf \
        '{"host":"127.0.0.1","port":%s,"mismatchedHostAddress":"::1","username":"%s","deviceKeySeed":"%s","nodePath":"%s","acceptScriptPath":"%s","homePath":"%s","authorizedKeysPath":"%s","localStateRoot":"%s","remoteStateRoot":"%s"}' \
        "$pairing_port" "$fixture_username" "$device_key_seed" "$pairing_node_path" \
        "$repo_root/plugin/src/pair-accept.js" "$pairing_home" "$pairing_authorized_keys" \
        "$pairing_state_root" "$pairing_state_root" | base64 | tr -d '\n')
fi

run_suite() {
    local lane=$1 expected_skips=$2
    shift 2
    local log="$fixture_dir/$lane.log"
    local -a selectors=()
    local suite
    for suite in "$@"; do
        selectors+=("-only-testing:HeelerTests/$suite")
    done
    run_app_test_bundle "$lane" "$log" -parallel-testing-enabled NO "${selectors[@]}"
    local skips
    skips=$(grep -cE '(Test|Suite) .* skipped' "$log" || true)
    if [[ "$skips" != "$expected_skips" ]]; then
        echo "$lane skipped $skips tests; expected $expected_skips skips" >&2
        return 1
    fi
}

run_core_fixture_suite() {
    local release_dir="$fixture_dir/herdr-core-0.1.13" target checksum archive cached
    case "$(uname -m)" in
        x86_64) target=macos-x86_64 ;;
        *) target=macos-aarch64 ;;
    esac
    checksum=$(awk -v target="$target" '$2 == target { print $1 }' "$repo_root/scripts/fixtures/herdr-core-archive.sha256")
    mkdir -p "$release_dir" "$core_archive_cache_dir"
    archive="$release_dir/core.tar.gz"
    cached="$core_archive_cache_dir/herdr-core-$checksum.tar.gz"
    if [[ -f "$cached" && "$(shasum -a 256 "$cached" | awk '{print $1}')" == "$checksum" ]]; then
        cp "$cached" "$archive"
    else
        curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 \
            "https://releases.herdr.dev/core/0.1.13/herdr-core-$target.tar.gz" -o "$archive"
        [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$checksum" ]] || { echo "herdr-core checksum mismatch" >&2; return 1; }
        cp "$archive" "$cached"
    fi
    tar -xzf "$archive" -C "$release_dir" herdr-core
    chmod 700 "$release_dir/herdr-core"
    core_fixture_dir=$(mktemp -d /tmp/hc-ci.XXXXXX)
    "$fixture_python" "$repo_root/scripts/fixtures/herdr-core-ssh.py" start \
        --root "$core_fixture_dir" --port "$core_port" --core "$release_dir/herdr-core"
    HEELER_SSH_E2E_CONFIG=$(<"$core_fixture_dir/core-test-config")
    push_simulator_environment HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG
    run_suite HerdrCoreTransportE2ETests 0 HerdrCoreTransportE2ETests
    HEELER_SSH_E2E_CONFIG="$fixture_configuration_base64"
    push_simulator_environment HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG
    stop_core_fixture
}

run_tmux_fixture_suite() {
    tmux_fixture_dir=$(mktemp -d /tmp/ht-ci.XXXXXX)
    "$fixture_python" "$repo_root/scripts/fixtures/tmux-ssh.py" start \
        --root "$tmux_fixture_dir" --port "$core_port" --tmux "$tmux_fixture_executable"
    HEELER_SSH_E2E_CONFIG=$(<"$tmux_fixture_dir/tmux-test-config")
    push_simulator_environment HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG
    run_suite TmuxTransportE2ETests 0 TmuxTransportE2ETests
    HEELER_SSH_E2E_CONFIG="$fixture_configuration_base64"
    push_simulator_environment HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG
    stop_tmux_fixture
}

run_package_e2e_suite() {
    mkdir -p "$package_derived_data_path/Logs/Test"
    local log="$fixture_dir/package-e2e.log"
    local bundle="$package_derived_data_path/Logs/Test/package-e2e.xcresult"
    rm -rf -- "$bundle"
    push_simulator_environment \
        HEELER_SSH_E2E_REQUIRED HEELER_SSH_E2E_HOST HEELER_SSH_E2E_PORT HEELER_SSH_E2E_PQ_PORT \
        HEELER_SSH_E2E_RESTRICTED_PORT HEELER_SSH_E2E_USERNAME HEELER_SSH_E2E_DEVICE_KEY_SEED \
        HEELER_SSH_E2E_WEAK_PORT HEELER_SSH_E2E_WEAK_CONTROL_PORT HEELER_SSH_E2E_STREAMLOCAL_SOCKET
    if [[ -n "$package_base_xctestrun" ]]; then
        run_xcodebuild "HeelerSSH package E2E" "$log" \
            test-without-building -xctestrun "$package_base_xctestrun" \
            -destination "$simulator_destination" -resultBundlePath "$bundle" \
            -collect-test-diagnostics never
    else
        (
            cd "$repo_root/Packages/HeelerSSH"
            xcodebuild test-without-building -scheme HeelerSSH \
                -derivedDataPath "$package_derived_data_path" \
                -destination "$simulator_destination" -resultBundlePath "$bundle" \
                -collect-test-diagnostics never
        ) 2>&1 | tee "$log"
    fi
    if [[ "$(grep -cE '(Test|Suite) .* skipped' "$log" || true)" != "0" ]]; then
        echo "HeelerSSH package E2E had unexpected skips" >&2
        return 1
    fi
}

xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true

if [[ "$ci_lane" == package ]]; then
    if [[ -z "$package_products_archive" ]]; then
        (
            cd "$repo_root/Packages/HeelerSSH"
            xcodebuild build-for-testing -scheme HeelerSSH \
                -derivedDataPath "$package_derived_data_path" \
                -destination "$simulator_destination" \
                -collect-test-diagnostics never COMPILER_INDEX_STORE_ENABLE=NO
        ) 2>&1 | tee "$fixture_dir/package-build.log"
        find_package_xctestrun || true
    fi
    boot_simulator
    run_package_e2e_suite
    exit 0
fi

if [[ -z "$app_products_archive" ]]; then
    mkdir -p "$source_packages_dir"
    run_xcodebuild "Build for testing" "$fixture_dir/build-for-testing.log" \
        build-for-testing -project Heeler.xcodeproj -scheme Heeler \
        -derivedDataPath "$app_derived_data_path" \
        -clonedSourcePackagesDirPath "$source_packages_dir" \
        -destination "$simulator_destination" \
        -collect-test-diagnostics never COMPILER_INDEX_STORE_ENABLE=NO
    find_app_xctestrun || true
fi

boot_simulator

# shellcheck disable=SC2034
{
    HEELER_SSH_E2E_CONFIG="$fixture_configuration_base64"
    HEELER_SSH_JUMP_E2E_CONFIG="$jump_fixture_configuration_base64"
    HEELER_PAIRING_E2E_CONFIG="$pairing_fixture_configuration_base64"
}
push_simulator_environment HEELER_SSH_E2E_CONFIG HEELER_SSH_JUMP_E2E_CONFIG HEELER_PAIRING_E2E_CONFIG

case "$ci_app_shard" in
    session-weak)
        run_suite HeelerSSHSessionE2ETests 2 HeelerSSHSessionE2ETests
        run_suite WeakNetworkE2ETests 0 WeakNetworkE2ETests
        run_core_fixture_suite
        if [[ -n "$package_products_archive" ]]; then
            run_package_e2e_suite
        fi
        ;;
    transport)
        run_suite HeelerSSHDirectStreamLocalE2ETests 0 HeelerSSHDirectStreamLocalE2ETests
        run_suite SharedFixtureE2ETests 0 \
            HeelerSSHPTYE2ETests HeelerSSHJumpHostGateE2ETests \
            HeelerSSHTransportBehaviorE2ETests ChangesFieldHostE2ETests \
            ImageStagingE2ETests PairingCeremonyE2ETests
        run_tmux_fixture_suite
        ;;
    all)
        run_suite HeelerSSHSessionE2ETests 2 HeelerSSHSessionE2ETests
        run_suite HeelerSSHDirectStreamLocalE2ETests 0 HeelerSSHDirectStreamLocalE2ETests
        run_suite SharedFixtureE2ETests 0 \
            HeelerSSHPTYE2ETests HeelerSSHJumpHostGateE2ETests \
            HeelerSSHTransportBehaviorE2ETests ChangesFieldHostE2ETests \
            ImageStagingE2ETests WeakNetworkE2ETests PairingCeremonyE2ETests
        run_core_fixture_suite
        run_tmux_fixture_suite
        export HEELER_SSH_E2E_REQUIRED=0
        push_simulator_environment HEELER_SSH_E2E_REQUIRED
        run_app_test_bundle "Full app test lane" "$fixture_dir/full-lane.log"
        ;;
esac
