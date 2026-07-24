#!/usr/bin/env bash
# Tracer demo for Agent Notifications (#71): encrypt one vector-conformant
# envelope and curl it through a deployed Push Relay so a decrypted
# notification pops on the registered device. Run it once the relay is
# deployed (#70's TODO); until then it only needs a URL to point at.
#
# Usage:
#   scripts/notification-tracer.sh <relay-base-url> <device-token-hex> \
#     <notification-key-b64url> [sandbox|production] [status]
#
# Where to find the inputs: after Notification Registration (#72) the Host's
# notifications.json (inside `herdr plugin config-dir`) holds one entry per
# device with `token`, `key`, and `env` — pass those three through verbatim.
# Status defaults to "blocked"; "done" is the other trigger worth demoing.
#
# Requires node >= 20 (reuses the plugin's envelope encoder, so the tracer
# cannot drift from the contract) and curl.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

relay_url="${1%/}"
token="$2"
key_b64url="$3"
env="${4:-sandbox}"
status="${5:-blocked}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Build the POST body: encrypt the envelope with the device's Notification
# Key, then wrap it in the relay's /push request shape (relay/README.md).
body="$(
  node --input-type=module - "$key_b64url" "$token" "$env" "$status" <<EOF
import { encryptNotificationEnvelope } from "${repo_root}/plugin/src/notification-envelope.js";

const [key, token, env, status] = process.argv.slice(2);
const envelope = encryptNotificationEnvelope(
  {
    paneId: "%tracer",
    agentKind: "claude",
    status,
    timestamp: Math.floor(Date.now() / 1000),
  },
  Buffer.from(key, "base64url"),
);
process.stdout.write(
  JSON.stringify({ token, env, envelope, collapse: "%tracer" }),
);
EOF
)"

echo "POST ${relay_url}/push" >&2
curl -sS -X POST "${relay_url}/push" \
  -H 'content-type: application/json' \
  -d "$body"
echo
