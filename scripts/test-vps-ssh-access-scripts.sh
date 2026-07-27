#!/usr/bin/env bash
# Exercise client configuration and two-sided key enrollment without a real VPS.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/herdr-vps-scripts.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fake_bin="${test_root}/bin"
client_home="${test_root}/client"
target_home="${test_root}/target"
remote_home="${test_root}/remote"
clipboard="${test_root}/clipboard"
mkdir -p "$fake_bin" "$client_home" "$target_home" "$remote_home"

cat > "${fake_bin}/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF

cat > "${fake_bin}/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat > "$HERDR_TEST_CLIPBOARD"
EOF

cat > "${fake_bin}/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s:x:501:20::%s:/bin/bash\n' "$2" "$HERDR_TEST_REMOTE_HOME"
EOF

cat > "${fake_bin}/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == '-gn' ]]; then
  printf 'staff\n'
else
  /usr/bin/id "$@"
fi
EOF

cat > "${fake_bin}/install" <<'EOF'
#!/usr/bin/env bash
args=()
while (( $# > 0 )); do
  case "$1" in
    -o|-g)
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
/usr/bin/install "${args[@]}"
EOF

cat > "${fake_bin}/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '-G' ]]; then
  exit 0
fi

[[ "${1:-}" == '-o' ]]
[[ "${2:-}" == 'StrictHostKeyChecking=yes' ]]
shift 2
destination="$1"
shift
if [[ "$destination" == 'failing-admin' ]]; then
  exit 42
fi
[[ "$destination" == 'test-admin' ]]

command="$1"
arguments="${command#sudo /bin/bash -s -- }"
eval "set -- ${arguments}"
/bin/bash -s -- "$@"
EOF

chmod +x "${fake_bin}/"*

export PATH="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"
export HERDR_TEST_CLIPBOARD="$clipboard"
export HERDR_TEST_REMOTE_HOME="$remote_home"

HOME="$client_home" "${repo_root}/scripts/configure-vps-ssh-client.sh" \
  --profile test-herdr \
  --vps-host 203.0.113.10 \
  --target-user alice \
  --jump-user testjump \
  --no-passphrase >/dev/null

HOME="$client_home" "${repo_root}/scripts/configure-vps-ssh-client.sh" \
  --profile test-herdr \
  --vps-host 203.0.113.10 \
  --target-user alice \
  --jump-user testjump \
  --no-passphrase >/dev/null

config="${client_home}/.ssh/config"
[[ "$(grep -c '^# BEGIN herdr-vps-access: test-herdr$' "$config")" == '1' ]]
grep -q '^Host test-herdr-jump$' "$config"
grep -q '^Host test-herdr-mac$' "$config"
grep -q '^  User testjump$' "$config"
grep -q '^  ProxyJump test-herdr-jump$' "$config"
cmp -s "$clipboard" "${client_home}/.ssh/test-herdr-client.pub"

public_key="$(cat "${client_home}/.ssh/test-herdr-client.pub")"
read -r key_type key_blob _ <<< "$public_key"

mkdir -p "${target_home}/.ssh" "${remote_home}/.ssh"
printf '# keep-local\n%s\n%s\n' "$public_key" "$public_key" \
  > "${target_home}/.ssh/authorized_keys"
printf '# keep-remote\n%s\n%s\n' "$public_key" "$public_key" \
  > "${remote_home}/.ssh/authorized_keys"

printf '%s\n' "$public_key" \
  | HOME="$target_home" "${repo_root}/scripts/manage-vps-ssh-client.sh" add \
      --vps-admin test-admin \
      --jump-user testjump \
      --tunnel-port 2222 >/dev/null

[[ "$(grep -c "$key_blob" "${target_home}/.ssh/authorized_keys")" == '1' ]]
[[ "$(grep -c "$key_blob" "${remote_home}/.ssh/authorized_keys")" == '1' ]]
grep -q "^no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${key_type} ${key_blob}" \
  "${target_home}/.ssh/authorized_keys"
grep -q "^restrict,port-forwarding,permitopen=\"127.0.0.1:2222\" ${key_type} ${key_blob}" \
  "${remote_home}/.ssh/authorized_keys"
grep -q '^# keep-local$' "${target_home}/.ssh/authorized_keys"
grep -q '^# keep-remote$' "${remote_home}/.ssh/authorized_keys"

printf '%s\n' "$public_key" \
  | HOME="$target_home" "${repo_root}/scripts/manage-vps-ssh-client.sh" revoke \
      --vps-admin test-admin \
      --jump-user testjump \
      --tunnel-port 2222 >/dev/null

if grep -q "$key_blob" "${target_home}/.ssh/authorized_keys"; then
  exit 1
fi
if grep -q "$key_blob" "${remote_home}/.ssh/authorized_keys"; then
  exit 1
fi

printf '%s\n' "$public_key" > "${target_home}/.ssh/authorized_keys"
before_failure="$(shasum -a 256 "${target_home}/.ssh/authorized_keys")"
if printf '%s\n' "$public_key" \
  | HOME="$target_home" "${repo_root}/scripts/manage-vps-ssh-client.sh" add \
      --vps-admin failing-admin \
      --jump-user testjump \
      --tunnel-port 2222 >/dev/null 2>&1; then
  exit 1
fi
after_failure="$(shasum -a 256 "${target_home}/.ssh/authorized_keys")"
[[ "$before_failure" == "$after_failure" ]]

printf 'VPS SSH access script tests passed.\n'
