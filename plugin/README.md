# Herdr Mobile Pairing plugin

A [herdr plugin](https://herdr.dev/docs/plugins/) that renders a **Pairing Code**
QR so the herdr-mobile app can add this machine as a Host by scanning it
(ADR 0007). The `pair` action opens a popup pane: confirm which of the
machine's addresses go into the code, then scan the QR with the app.

The Pairing Code carries a single-use **Bootstrap Key**: the app connects with
it once, submits its Device Key public line, and the plugin's Enrollment
entrypoint appends that key to `authorized_keys` automatically. See
[Bootstrap Key lifecycle](#bootstrap-key-lifecycle).

## Requirements

- Node.js >= 20 on `PATH`
- herdr >= 0.7.5
- An OpenSSH server on this machine (the code pins its host key fingerprint)

## Install

```bash
herdr plugin install zinger-labs/herdr-mobile/plugin   # once this repo is public
```

For local development, link the working tree instead (build it yourself,
`plugin link` does not run build commands):

```bash
cd plugin && npm ci
herdr plugin link "$(pwd)"
herdr plugin action invoke herdr-mobile.pairing.pair
```

The popup checklist: arrows or `j`/`k` move, space toggles, `a` toggles all,
enter mints a Bootstrap Key and renders the QR, `q`/escape closes (revoking
the key). When the code expires, enter generates a fresh one. Once a device
enrolls, the QR is replaced by a success screen showing the enrolled Device
Key's fingerprint and label; press `r` there to revoke that key (removing its
`authorized_keys` line), or any other key to close.

Known limitation: the advertised SSH port is currently fixed at 22.

## Pairing Code envelope (v1)

The Pairing Code is a single-line string; the QR image is just its rendering.

```
HERDR-PAIR:<version>:<base64url(JSON, no padding)>
```

- `HERDR-PAIR` is a literal prefix; anything else is rejected (`bad_prefix`).
- `<version>` is a decimal integer. This document specifies version `1`;
  any other value is rejected (`unsupported_version`).
- The body is the payload JSON, UTF-8, encoded as unpadded base64url
  (RFC 4648 `-`/`_` alphabet). Invalid base64url or JSON is rejected
  (`bad_encoding`).

### Payload fields

| Wire key | Type    | Required | Meaning |
| -------- | ------- | -------- | ------- |
| `addrs`  | string[]| yes      | Candidate addresses in the order the app should try them. Non-empty; each entry a non-empty string without whitespace. IPv6 literals carry no brackets and no zone id. |
| `port`   | integer | yes      | SSH port, `1..65535`. |
| `user`   | string  | yes      | SSH username. Non-empty, no whitespace. |
| `fp`     | string  | yes      | Host key fingerprint exactly as OpenSSH prints it: `SHA256:` + 43 chars of unpadded standard base64. The app pins this instead of showing a TOFU prompt. |
| `seed`   | string  | no       | Raw 32-byte Ed25519 seed of the Bootstrap Key, unpadded base64url. Present together with `exp` or not at all. |
| `exp`    | integer | no       | Unix-seconds expiry of the Bootstrap Key. Present together with `seed` or not at all. |

A payload violating these rules is rejected (`bad_payload`). A code without
`seed`/`exp` is a config-only Pairing Code: same ceremony minus the bootstrap
connection.

### Canonical encoding

Encoders emit the keys in the order of the table above with no JSON
whitespace, so a given payload has exactly one canonical code. Decoders do not
depend on key order.

### Compatibility rules

- Decoders ignore unknown payload fields; additive metadata may appear within
  v1.
- Any breaking change (removing, renaming, or re-typing a field, or changing
  the envelope framing) bumps `<version>`, and both implementations must be
  updated together.

## Bootstrap Key lifecycle

Confirming the address checklist mints an ephemeral Ed25519 **Bootstrap Key**.
Its raw 32-byte seed rides in the Pairing Code (`seed`/`exp`); its public half
is written to `~/.ssh/authorized_keys` as a restricted line:

```
restrict,command="'<node>' '<plugin>/src/pair-accept.js' --state-dir '<state>' --pairing-id <id>" ssh-ed25519 <blob> herdr-pairing:<id>:exp:<unix-seconds>
```

- `restrict` plus the forced command mean the key can do exactly one thing:
  run the Enrollment accept entrypoint. The command embeds absolute paths
  because sshd provides no plugin environment.
- The trailing `herdr-pairing:<id>:exp:<unix-seconds>` comment marks the line
  so cleanup and the sweep can find it with no state beyond the file.
- All edits to `authorized_keys` are atomic (exclusive lock, temp file +
  rename) and preserve the file mode, so sshd `StrictModes` keeps accepting
  the file.

The line is removed on successful Enrollment (self-revoke), when the 2-minute
TTL expires, when the popup exits (including SIGTERM/SIGHUP), and by a sweep
of expired lines every time the popup starts — so a killed popup leaves at
worst a line that dies with its TTL and is swept at the next start. Pending
ceremony state lives under `$HERDR_PLUGIN_STATE_DIR/pending/<id>.json`, never
in the plugin checkout. On successful Enrollment the accept entrypoint writes
`$HERDR_PLUGIN_STATE_DIR/enrolled/<id>.json` (the enrolled fingerprint and
line); the popup polls for it to show the success screen and drive the revoke,
and clears it on exit. An invalid submission does not consume the line; the
app may retry until the TTL runs out.

### Enrollment accept protocol

The app connects with the Bootstrap Key and writes its Device Key public line
(`ssh-ed25519 <blob> [comment]`, printable-ASCII comment) followed by a
newline to stdin. The forced command answers with one line on stdout:

| Response | Meaning |
| -------- | ------- |
| `HERDR-ENROLL:OK:<SHA256:fingerprint>` | Device Key appended (or already authorized); bootstrap line revoked. Exit 0. |
| `HERDR-ENROLL:ERR:invalid_key` | Submission is not a bare Ed25519 public line. Line not consumed; retry allowed. Exit 1. |
| `HERDR-ENROLL:ERR:no_input` | Nothing arrived on stdin. Line not consumed. Exit 1. |
| `HERDR-ENROLL:ERR:expired` | TTL passed; the bootstrap line was removed. Regenerate the code. Exit 1. |
| `HERDR-ENROLL:ERR:unknown_pairing` | No pending ceremony (already used, cleaned up, or never existed). Exit 1. |

Human-readable detail goes to stderr. Manual demo from another machine:

```bash
# On the phone side stand-in: seed.key holds the Bootstrap Key in any format
# ssh accepts; the app itself uses the raw seed from the Pairing Code.
ssh -i seed.key <user>@<host> < device_key.pub
```

### Shared test vectors

`test-vectors/pairing-code-v1.json` is the single source of truth for the
envelope, consumed by the Node tests here and the Swift tests in the app.
Valid vectors must decode to the given payload and (unless `decodeOnly`)
re-encode to the exact code; invalid vectors must fail with the given error
code (`bad_prefix`, `unsupported_version`, `bad_encoding`, `bad_payload` —
these map to the "parse" step of the pairing failure taxonomy).

## Notification envelope (v1)

The encrypted Agent Notification payload (ADR 0008): the notify hook
encrypts it on the Host, the Push Relay and APNs carry it opaquely, and the
app's service extension decrypts it. One compact JSON object:

```json
{"v": 1, "kid": "<key id>", "n": "<nonce>", "ct": "<ciphertext>"}
```

### Cleartext fields

| Wire key | Type    | Meaning |
| -------- | ------- | ------- |
| `v`      | integer | Envelope version. This document specifies version `1`; any other integer is rejected (`unsupported_version`). |
| `kid`    | string  | Key id: the first 8 bytes of SHA-256 over the raw 32-byte Notification Key, unpadded base64url. Derived on both ends, never stored. The app uses it to select the right Notification Key (and thus Host) when several Hosts are registered. |
| `n`      | string  | 12-byte AES-GCM nonce, unpadded base64url. Freshly random per envelope. |
| `ct`     | string  | AES-256-GCM ciphertext followed by the 16-byte tag, unpadded base64url. |

A missing or mistyped field, invalid base64url, or wrong nonce/tag length is
rejected (`bad_envelope`).

### Ciphertext

AES-256-GCM under the per-host Notification Key, with the UTF-8 bytes of
`HERDR-NOTIFY:1` as additional authenticated data so a ciphertext re-framed
under another version fails authentication. Tampered material or the wrong
key is rejected (`decrypt_failed`) — GCM cannot tell those apart. The
plaintext is compact JSON:

| Wire key | Type    | Meaning |
| -------- | ------- | ------- |
| `pane`   | string  | herdr pane id the Agent lives in. Non-empty. |
| `kind`   | string  | Agent kind as herdr reports it (`claude`, `codex`, ...). Non-empty. |
| `status` | string  | The new Agent Status. An open set: decoders pass unrecognized values through. Non-empty. |
| `ts`     | integer | Unix-seconds of the status transition. Positive. |

A plaintext that is not JSON or violates these rules is rejected
(`bad_payload`). Every rejection is a typed error on the app side; the
service extension answers any of them with a generic fallback banner, never
a crash.

### Canonical encoding

Encoders emit both JSON objects with the keys in table order and no
whitespace, so given inputs yield exactly one envelope; the shared vectors
assert on the exact string. Decoders do not depend on key order and ignore
unknown fields at either layer (additive v1 metadata). Any breaking change
bumps `v`, and both implementations must be updated together.

### Shared test vectors

`test-vectors/notification-payload-v1.json` is the single source of truth,
consumed by the Node tests here (encrypt direction: non-`decodeOnly` valid
vectors must be reproduced byte-for-byte) and the Swift tests in the app
(decrypt direction: valid vectors must yield the payload, invalid vectors —
including tampered-ciphertext and wrong-key cases — must fail with the given
error code: `bad_envelope`, `unsupported_version`, `decrypt_failed`,
`bad_payload`).

## Notification Registration file (v1)

Where a Host learns which devices to notify: the app writes this file over
SSH during Notification Registration; the notify hook reads it and POSTs one
push per device entry. It lives at `notifications.json` inside this plugin's
config directory (the app resolves that directory via
`herdr plugin config-dir`). Writers replace the whole file atomically
(temp file + rename), keyed one entry per device token; removing an entry
revokes that device.

```json
{
  "v": 1,
  "devices": [
    {
      "token": "a1b2c3...",
      "key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
      "env": "production",
      "notify": { "blocked": true, "done": true }
    }
  ]
}
```

| Field            | Type    | Meaning |
| ---------------- | ------- | ------- |
| `v`              | integer | File format version. This document specifies version `1`; a reader finding any other value must treat the file as absent (send nothing) rather than guess. |
| `devices`        | array   | One entry per registered device. Empty means no notifications. |
| `token`          | string  | The device's APNs device token, lowercase hex. Unique within the file. |
| `key`            | string  | Raw 32-byte Notification Key, unpadded base64url. Generated on the device, per Host. |
| `env`            | string  | `production` or `sandbox`: which APNs environment the token belongs to, following the app build that registered it. |
| `notify.blocked` | boolean | Send a push when an Agent becomes Blocked. |
| `notify.done`    | boolean | Send a push when an Agent reaches Done. A missing flag means do not send (fail closed). |

Readers ignore unknown fields (additive v1 metadata); breaking changes bump
`v`, honored by plugin and app together.

## Tests

```bash
npm test
```

Uses Node's built-in test runner; no test dependencies.
