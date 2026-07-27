#!/usr/bin/env bash
# Enroll or revoke one SSH client key on the target Mac and its VPS Jump Host.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  manage-vps-ssh-client.sh add|revoke \
    --vps-admin SSH_DESTINATION \
    [--jump-user USER] \
    [--tunnel-port PORT] \
    [--public-key-file PATH]

Examples:
  pbpaste | scripts/manage-vps-ssh-client.sh add \
    --vps-admin root@203.0.113.10

  scripts/manage-vps-ssh-client.sh revoke \
    --vps-admin vps-admin \
    --public-key-file old-client.pub

Run this script on the Mac being exposed. It replaces any existing occurrence
of the same key, so rerunning it is safe and also repairs an unrestricted key
line. Without --public-key-file, the public key is read from standard input.

The VPS administrator destination must already have a verified host key.
The remote account must be root or have non-interactive sudo access.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 64
}

action="$1"
shift
[[ "$action" == 'add' || "$action" == 'revoke' ]] \
  || die 'the first argument must be add or revoke'

vps_admin=''
jump_user='herdr-jump'
tunnel_port='2222'
public_key_file=''

while (( $# > 0 )); do
  case "$1" in
    --vps-admin)
      (( $# >= 2 )) || die '--vps-admin requires a value'
      vps_admin="$2"
      shift 2
      ;;
    --jump-user)
      (( $# >= 2 )) || die '--jump-user requires a value'
      jump_user="$2"
      shift 2
      ;;
    --tunnel-port)
      (( $# >= 2 )) || die '--tunnel-port requires a value'
      tunnel_port="$2"
      shift 2
      ;;
    --public-key-file)
      (( $# >= 2 )) || die '--public-key-file requires a value'
      public_key_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$vps_admin" ]] || die '--vps-admin is required'
[[ "$vps_admin" != *$'\n'* && "$vps_admin" != *[[:space:]]* ]] \
  || die '--vps-admin must be one SSH destination without whitespace'
[[ "$vps_admin" != -* ]] || die '--vps-admin must not start with a hyphen'
[[ "$jump_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || die '--jump-user is not a valid account name'
valid_port "$tunnel_port" || die '--tunnel-port must be between 1 and 65535'

if [[ -n "$public_key_file" ]]; then
  [[ -f "$public_key_file" ]] || die "public key file not found: $public_key_file"
  key_input="$(sed -n '/[^[:space:]]/p' "$public_key_file")"
else
  key_input="$(sed -n '/[^[:space:]]/p')"
fi

[[ -n "$key_input" ]] || die 'no public key was provided'
[[ "$key_input" != *$'\n'* ]] || die 'provide exactly one public key'

read -r key_type key_blob _ <<< "$key_input"
[[ "$key_type" == 'ssh-ed25519' && -n "$key_blob" ]] \
  || die 'only one ssh-ed25519 public key is accepted'

validation_file="$(mktemp "${TMPDIR:-/tmp}/herdr-public-key.XXXXXX")"
local_candidate=''
cleanup() {
  rm -f "$validation_file"
  if [[ -n "$local_candidate" ]]; then
    rm -f "$local_candidate"
  fi
}
trap cleanup EXIT

printf '%s\n' "$key_input" > "$validation_file"
ssh-keygen -lf "$validation_file" >/dev/null || die 'the public key is invalid'
fingerprint="$(ssh-keygen -lf "$validation_file" | awk '{print $2}')"

ssh_dir="${HOME}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
if [[ -e "$authorized_keys" && ! -f "$authorized_keys" ]]; then
  die "authorized_keys is not a regular file: $authorized_keys"
fi

local_entry="no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc ${key_input}"
local_candidate="$(mktemp "${ssh_dir}/authorized_keys.candidate.XXXXXX")"
local_source='/dev/null'
if [[ -f "$authorized_keys" ]]; then
  local_source="$authorized_keys"
fi

awk \
  -v action="$action" \
  -v needle="${key_type} ${key_blob}" \
  -v entry="$local_entry" '
  index(" " $0 " ", " " needle " ") {
    if (action == "add" && !written) {
      print entry
      written = 1
    }
    next
  }
  { print }
  END {
    if (action == "add" && !written) {
      print entry
    }
  }
' "$local_source" > "$local_candidate"
chmod 600 "$local_candidate"

encoded_key="$(printf '%s' "$key_input" | base64 | tr -d '\r\n')"

printf 'Updating VPS Jump Host through %s...\n' "$vps_admin"
ssh -o StrictHostKeyChecking=yes "$vps_admin" \
  "sudo /bin/bash -s -- '$action' '$jump_user' '$tunnel_port' '$encoded_key'" <<'REMOTE_SCRIPT'
set -euo pipefail

action="$1"
jump_user="$2"
tunnel_port="$3"
encoded_key="$4"

key_input="$(printf '%s' "$encoded_key" | base64 -d)"
read -r key_type key_blob _ <<< "$key_input"
[[ "$key_type" == 'ssh-ed25519' && -n "$key_blob" ]]

jump_home="$(getent passwd "$jump_user" | cut -d: -f6)"
[[ -n "$jump_home" && -d "$jump_home" ]]
jump_group="$(id -gn "$jump_user")"

ssh_dir="${jump_home}/.ssh"
authorized_keys="${ssh_dir}/authorized_keys"
install -d -m 700 -o "$jump_user" -g "$jump_group" "$ssh_dir"
touch "$authorized_keys"
chown "$jump_user:$jump_group" "$authorized_keys"
chmod 600 "$authorized_keys"

entry="restrict,port-forwarding,permitopen=\"127.0.0.1:${tunnel_port}\" ${key_input}"
candidate="$(mktemp "${ssh_dir}/authorized_keys.candidate.XXXXXX")"
trap 'rm -f "$candidate"' EXIT

awk \
  -v action="$action" \
  -v needle="${key_type} ${key_blob}" \
  -v entry="$entry" '
  index(" " $0 " ", " " needle " ") {
    if (action == "add" && !written) {
      print entry
      written = 1
    }
    next
  }
  { print }
  END {
    if (action == "add" && !written) {
      print entry
    }
  }
' "$authorized_keys" > "$candidate"

chown "$jump_user:$jump_group" "$candidate"
chmod 600 "$candidate"
mv "$candidate" "$authorized_keys"
trap - EXIT
REMOTE_SCRIPT

mv "$local_candidate" "$authorized_keys"
local_candidate=''
chmod 600 "$authorized_keys"

if [[ "$action" == 'add' ]]; then
  printf 'Enrolled %s on the VPS Jump Host and this Mac.\n' "$fingerprint"
else
  printf 'Revoked %s from the VPS Jump Host and this Mac.\n' "$fingerprint"
fi
