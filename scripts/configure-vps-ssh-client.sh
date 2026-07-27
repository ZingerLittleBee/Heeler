#!/usr/bin/env bash
# Configure a macOS SSH client for a VPS Jump Host and the tunneled Mac.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  configure-vps-ssh-client.sh \
    --profile NAME \
    --vps-host HOST \
    --target-user USER \
    [--jump-user USER] \
    [--vps-port PORT] \
    [--tunnel-port PORT] \
    [--key-file PATH] \
    [--no-passphrase]

Example:
  scripts/configure-vps-ssh-client.sh \
    --profile work \
    --vps-host 203.0.113.10 \
    --target-user alice

The script creates one client-specific Ed25519 key, installs a managed block in
~/.ssh/config, prints the public key and copies it to the macOS clipboard.
Run it on the new client Mac, not on the Mac being exposed.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

profile=''
vps_host=''
target_user=''
jump_user='herdr-jump'
vps_port='22'
tunnel_port='2222'
key_file=''
no_passphrase='false'

while (( $# > 0 )); do
  case "$1" in
    --profile)
      (( $# >= 2 )) || die '--profile requires a value'
      profile="$2"
      shift 2
      ;;
    --vps-host)
      (( $# >= 2 )) || die '--vps-host requires a value'
      vps_host="$2"
      shift 2
      ;;
    --target-user)
      (( $# >= 2 )) || die '--target-user requires a value'
      target_user="$2"
      shift 2
      ;;
    --jump-user)
      (( $# >= 2 )) || die '--jump-user requires a value'
      jump_user="$2"
      shift 2
      ;;
    --vps-port)
      (( $# >= 2 )) || die '--vps-port requires a value'
      vps_port="$2"
      shift 2
      ;;
    --tunnel-port)
      (( $# >= 2 )) || die '--tunnel-port requires a value'
      tunnel_port="$2"
      shift 2
      ;;
    --key-file)
      (( $# >= 2 )) || die '--key-file requires a value'
      key_file="$2"
      shift 2
      ;;
    --no-passphrase)
      no_passphrase='true'
      shift
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

[[ "$(uname -s)" == 'Darwin' ]] || die 'this client setup script requires macOS'
[[ "$profile" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die '--profile must contain only letters, digits, dots, underscores, or hyphens'
[[ "$vps_host" =~ ^[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]] \
  || die '--vps-host contains unsupported characters'
[[ "$target_user" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] \
  || die '--target-user contains unsupported characters'
[[ "$jump_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || die '--jump-user is not a valid account name'
valid_port "$vps_port" || die '--vps-port must be between 1 and 65535'
valid_port "$tunnel_port" || die '--tunnel-port must be between 1 and 65535'

ssh_dir="${HOME}/.ssh"
config_file="${ssh_dir}/config"
if [[ -z "$key_file" ]]; then
  key_file="${ssh_dir}/${profile}-client"
fi
[[ "$key_file" != *$'\n'* ]] || die '--key-file must not contain a newline'

mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

if [[ -e "$key_file" && ! -f "$key_file" ]]; then
  die "key path is not a regular file: $key_file"
fi

if [[ ! -f "$key_file" ]]; then
  printf 'Creating client key: %s\n' "$key_file"
  if [[ "$no_passphrase" == 'true' ]]; then
    ssh-keygen -q -t ed25519 -a 100 -N '' -f "$key_file" -C "${profile}-client"
  else
    ssh-keygen -t ed25519 -a 100 -f "$key_file" -C "${profile}-client"
  fi
fi

chmod 600 "$key_file"
if [[ ! -f "${key_file}.pub" ]]; then
  ssh-keygen -y -f "$key_file" > "${key_file}.pub"
fi
chmod 644 "${key_file}.pub"

public_key="$(sed -n '1p' "${key_file}.pub")"
[[ "$public_key" == ssh-ed25519\ * ]] \
  || die "expected an Ed25519 public key at ${key_file}.pub"
ssh-keygen -lf "${key_file}.pub" >/dev/null \
  || die "invalid public key: ${key_file}.pub"

begin_marker="# BEGIN herdr-vps-access: ${profile}"
end_marker="# END herdr-vps-access: ${profile}"
jump_alias="${profile}-jump"
mac_alias="${profile}-mac"

touch "$config_file"
chmod 600 "$config_file"

filtered_config="$(mktemp "${ssh_dir}/config.filtered.XXXXXX")"
cleanup() {
  rm -f "$filtered_config"
}
trap cleanup EXIT

awk -v begin="$begin_marker" -v end="$end_marker" '
  $0 == begin { managed = 1; next }
  $0 == end { managed = 0; next }
  !managed { print }
' "$config_file" > "$filtered_config"

if awk -v jump="$jump_alias" -v mac="$mac_alias" '
  tolower($1) == "host" {
    for (i = 2; i <= NF; i++) {
      if ($i == jump || $i == mac) {
        found = 1
      }
    }
  }
  END { exit(found ? 0 : 1) }
' "$filtered_config"; then
  die "an unmanaged Host ${jump_alias} or Host ${mac_alias} already exists in ${config_file}"
fi

if [[ -s "$filtered_config" ]] \
  && [[ "$(tail -c 1 "$filtered_config" | wc -l | tr -d ' ')" == '0' ]]; then
  printf '\n' >> "$filtered_config"
fi

cat >> "$filtered_config" <<EOF
${begin_marker}
Host ${jump_alias}
  HostName ${vps_host}
  User ${jump_user}
  Port ${vps_port}
  IdentityFile "${key_file}"
  IdentitiesOnly yes
  AddKeysToAgent yes
  UseKeychain yes
  StrictHostKeyChecking ask

Host ${mac_alias}
  HostName 127.0.0.1
  User ${target_user}
  Port ${tunnel_port}
  IdentityFile "${key_file}"
  IdentitiesOnly yes
  AddKeysToAgent yes
  UseKeychain yes
  ProxyJump ${jump_alias}
  HostKeyAlias ${profile}-mac-via-vps
  StrictHostKeyChecking ask
${end_marker}
EOF

chmod 600 "$filtered_config"
ssh -G -F "$filtered_config" -T "$mac_alias" >/dev/null \
  || die 'OpenSSH rejected the generated configuration'

cat "$filtered_config" > "$config_file"
chmod 600 "$config_file"

if command -v pbcopy >/dev/null 2>&1; then
  printf '%s\n' "$public_key" | pbcopy
  clipboard_message='The public key is now on the macOS clipboard.'
else
  clipboard_message='Copy the public key shown below.'
fi

printf '\nClient configuration is ready.\n'
ssh-keygen -lf "${key_file}.pub"
printf '%s\n\n%s\n' "$clipboard_message" "$public_key"
printf '\nAfter an administrator enrolls this key on the VPS and target Mac, run:\n'
printf '  ssh %s\n' "$mac_alias"
