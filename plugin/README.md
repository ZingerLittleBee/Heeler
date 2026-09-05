# heeler

A [herdr plugin](https://herdr.dev/docs/plugins/) that renders a **Pairing Code**
QR so the Heeler app can add this machine as a Host by scanning it
(ADR 0007). The `pair` action opens a popup pane: confirm which of the
machine's addresses go into the code, then scan the QR with the app.

The Pairing Code carries a single-use **Bootstrap Key**: the app connects with
it once, submits its Device Key public line, and the plugin's Enrollment
entrypoint appends that key to `authorized_keys` automatically. See
[Bootstrap Key lifecycle](#bootstrap-key-lifecycle).

The plugin also delivers **Agent Notifications** (ADR 0008) and per-Host
**Live Activity** updates: two independent `[[events]]` entries on
`pane.agent_status_changed`. herdr runs every matching hook for the same
event (verified on 0.8.0). The notify hook pushes encrypted Blocked/Done
alerts; the activity hook pushes the Host's eligible-agent snapshot to any
device that has registered a Live Activity token. See
[Notify hook](#notify-hook) and [Activity hook](#activity-hook).

Starting with plugin 0.4.0, a startup hook also exports the Host's herdr
sidebar layout for Heeler. Both event hooks refresh it before their notification
gates. See [Sidebar layout snapshot (v1)](#sidebar-layout-snapshot-v1).

## Requirements

- Node.js >= 20 on `PATH`
- herdr >= 0.7.5
- An OpenSSH server on this machine (the code pins its host key fingerprint)

## Install

On a new machine, first install the requirements above and make sure the
OpenSSH server is running. On macOS, enable **System Settings > General >
Sharing > Remote Login**. Confirm the command-line requirements:

```bash
herdr --version   # 0.7.5 or newer
node --version    # 20 or newer
```

Install the plugin from GitHub:

```bash
herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes
```

Herdr stores the plugin in its managed checkout and runs the manifest's
`npm ci` build command automatically. Verify that the plugin is installed and
enabled:

```bash
herdr plugin list --plugin heeler
herdr plugin config-dir heeler
```

Open the Pairing Code popup:

```bash
herdr plugin action invoke heeler.pair
```

Scan the code in Heeler to add this machine as a Host, or press `c` on the
QR screen to copy the Pairing Code and paste it in the app (macOS uses
`pbcopy`; elsewhere the code is printed for manual selection). Then open the
Heeler settings, enable Agent Notifications, grant the iOS notification
permission, and enable Notifications for this Host. Leave **Custom Push
Relay** empty to use the production endpoint at
`https://heeler-apns.bybee.dev`.

To update an installed GitHub-managed plugin, run the same `plugin install`
command again. To inspect notification or pairing failures:

```bash
herdr plugin log list --plugin heeler --limit 20
```

For local development, link the working tree instead. Build it first because
`plugin link` does not run build commands:

```bash
cd plugin && npm ci
herdr plugin link "$(pwd)"
herdr plugin action invoke heeler.pair
```

The popup checklist: arrows or `j`/`k` move, space toggles, `a` toggles all,
enter mints a Bootstrap Key and renders the QR, `q`/escape closes (revoking
the key). On the QR screen, `c` copies the Pairing Code; any other key
closes. When the code expires, enter generates a fresh one. Once a device
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
| `project`| string  | Optional, display only: the workspace label the Agent runs in — the project name the app's alert leads with. Omitted when the Host cannot resolve it. At most 256 characters (the hook trims to 80 before encrypting). |
| `title`  | string  | Optional, display only: the Agent's terminal title with status glyphs stripped — what it is working on. Same absence and length rules as `project`. |

A plaintext that is not JSON or violates these rules is rejected
(`bad_payload`). Every rejection is a typed error on the app side; the
service extension answers any of them with a generic fallback banner, never
a crash.

### Canonical encoding

Encoders emit both JSON objects with the keys in table order and no
whitespace, so given inputs yield exactly one envelope; the shared vectors
assert on the exact string. An optional field with no value is omitted
entirely rather than sent empty, so absent, null, and `""` all encode
identically. Decoders do not depend on key order and ignore unknown fields at
either layer (additive v1 metadata). Any breaking change bumps `v`, and both
implementations must be updated together.

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
      "notify": { "blocked": true, "done": true },
      "live_activity": { "token": "c4d5e6...", "started_at": "2026-01-01T00:00:00Z" }
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
| `live_activity`  | object  | Optional per-device Live Activity registration. Present while the app is showing this Host's activity. See [Activity hook](#activity-hook). |
| `live_activity.token` | string | The per-activity APNs push token, lowercase hex. Distinct from the alert `token`. |
| `live_activity.started_at` | string | ISO 8601 timestamp the app wrote when it started (or rotated) the activity. Ignored by the hook; preserved on rewrite. |
| `live_activity.pinned_pane_ids` | string[] | Optional. Pane ids the device has pinned, most-recently-pinned first. Reorders Live Activity rows; does not change eligibility or counts. Missing, null, non-array, or any non-string entry is ignored (treated as empty). |

Readers ignore unknown fields (additive v1 metadata); breaking changes bump
`v`, honored by plugin and app together.

## Sidebar layout snapshot (v1)

`src/sidebar-hook.js` runs through `[[startup]]` at server start and live
handoff. It needs only `HERDR_PLUGIN_CONFIG_DIR`; startup has no
`HERDR_PLUGIN_EVENT_JSON`. Startup hooks are supported by herdr 0.7.5, so the
minimum herdr version stays 0.7.5.

The hook reads the config using the server environment inherited by plugin
processes, in this order:

1. `HERDR_CONFIG_PATH`, when set, is the exact source path.
2. Otherwise, `XDG_CONFIG_HOME/herdr/config.toml`, when `XDG_CONFIG_HOME` is set.
3. Otherwise, `HOME/.config/herdr/config.toml` (the system temporary directory
   replaces `HOME/.config` when `HOME` is unset).

Named sessions share this source; they do not add a session directory to its
path. The plugin parses TOML with `smol-toml`, validates the sidebar agent
layout and sort, then writes **`HERDR_PLUGIN_CONFIG_DIR/sidebar.json`**, next
to `notify.json`. It never writes this snapshot to `HERDR_PLUGIN_STATE_DIR`.
Writes use an exclusive mode **0600** temporary file followed by atomic rename;
a newly created plugin config directory has mode **0700**.

```json
{
  "v": 1,
  "generated_at": 1757040000,
  "source": {
    "path": "/home/u/.config/herdr/config.toml",
    "found": true,
    "mtime_ms": 1757039000123
  },
  "agent_panel_sort": "priority",
  "sidebar": {"agents": {
    "row_gap": 0,
    "rows": [
      [{"token":"state_icon"},{"token":"terminal_title_stripped","fg":"#6c7086","dim":false}],
      [{"token":"$pin_icon"},{"token":"workspace","dim":true},{"token":"agent"}]
    ],
    "rows_by_agent": {"claude":[[{"token":"terminal_title_stripped"}]]}
  }},
  "diagnostics": []
}
```

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `v` | integer | Snapshot version, currently `1`. Swift treats any other version as absent. |
| `generated_at` | integer | Unix seconds when the snapshot was written. Unchanged sources retain their previous snapshot and timestamp. |
| `source.path` | string | Resolved herdr config path. |
| `source.found` | boolean | Whether the source was found. Missing source is `false`; a source that can be statted but cannot be read is `true` with a diagnostic. |
| `source.mtime_ms` | number or null | Source `mtimeMs`, including fractional milliseconds; `null` when the source cannot be statted. |
| `agent_panel_sort` | string | `spaces` (default) or `priority`; the input alias `workspaces` normalizes to `spaces`. Independent of Heeler's flat / by-Host grouping. |
| `sidebar.agents.row_gap` | integer | `0..65535`, default `0`. herdr's blank terminal rows between Agent entries, not between lines of one entry. |
| `sidebar.agents.rows` | token[][] | Whole default layout, at most 16 rows and 16 tokens per row. Empty layouts and rows are valid. |
| `sidebar.agents.rows_by_agent` | object | Canonical Agent id to whole replacement rows; default `{}`. Unlisted Agents use `rows`. |
| `diagnostics` | string[] | Empty on success or a missing source. Otherwise `parse_error`, `invalid_token`, `invalid_schema`, or `read_error`. Raw config values and parser excerpts are never included. |

Every token is an object, including TOML string tokens. Builtins are
`state_icon`, `state_text`, `workspace`, `tab`, `pane`, `agent`,
`terminal_title`, and `terminal_title_stripped`. Custom names must match
`^\$[A-Za-z0-9_-]{1,32}$` and retain their `$` in the snapshot. A styled TOML
table accepts only `token`, `fg`, `bold`, and `dim`: `fg` must be `#RGB` or
`#RRGGBB`; `bold` and `dim` must be booleans. Optional style fields appear
only when explicitly provided, preserving `false` and the original hex case.
Other config fields are ignored. This is validation of the exported subset,
not a substitute for `herdr config check` for unrelated herdr settings.

`rows_by_agent` accepts the canonical ids verified against herdr v0.8.2:
`pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`, `omp`,
`mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`, `grok`,
`hermes`, `kilo`, `qodercli`, `qwen`, and `maki`. Aliases, case variations,
and unknown ids are invalid. A future herdr release adding canonical ids
requires updating this validation list and the shared vectors.

Missing files or fields use herdr defaults: sort `spaces`, `row_gap: 0`,
`rows: [[{"token":"state_icon"},{"token":"workspace"},{"token":"tab"}],
[{"token":"agent"}]]`, and `rows_by_agent: {}`. TOML parse errors, invalid
tokens, or invalid schema revert the **entire layout and sort** to those
defaults with a diagnostic. Read errors also produce defaults with a
diagnostic and are retried at the next invocation.

Both `notify-hook.js` and `activity-hook.js` refresh at the beginning of
`main()`, before debounce, dedupe, or no-device exits. An unchanged source
path, existence, and `mtimeMs` reuses the snapshot without reparsing or
rewriting. A missing/corrupt snapshot is rebuilt. Changes that preserve the
source mtime are not detected. Snapshot write failures are logged but do not
prevent the event hooks from delivering notifications.

There is no watcher and config reload does not run startup hooks. A config
edit with no Agent Status transition is picked up at the next transition or
server start. The snapshot reflects the file on disk, not any live TUI
`agent.view.set` sort override. Heeler never installs or updates this plugin;
older installations have no `sidebar.json`, which the app treats as nil
without a version gate.

Swift readers ignore unknown fields and drop individual unknown token names.
The app resolves whole layouts in this order: per-Host user layout, global
user layout, plugin snapshot, Heeler default. Rows are never merged across
sources. Its renderer skips `state_icon` and `state_text` because the status
column already shows Agent Status; `$name` resolves as plain text from
`AgentInfo.tokens["name"]`. Heeler's Pin is independent. Styles are retained
in the Swift model; rendering may ignore them (color is ignored by default).

### Shared test vectors

`test-vectors/sidebar-layout-v1.json` is shared by the Node parser tests and
the Swift snapshot decoder tests, and registered as a `HeelerTests` resource.
Its `valid` and `invalid` arrays contain `name`, `toml`, and a full expected
`snapshot`; invalid entries also contain the expected `error` diagnostic.
Node asserts normalized layout equality and whole-layout fallback. Swift
consumes the structured snapshots to assert decoded layout, defaults, and
diagnostics; it does not parse TOML. Change the contract and vectors together.

## Notify hook

The manifest `[[events]]` hook on `pane.agent_status_changed` runs
`src/notify-hook.js` as one short-lived process per Agent Status transition;
there is no long-running watcher. Only **Blocked** and **Done** notify, and
only for devices whose registration entry sets the matching `notify` flag.

Anti-noise, in order:

1. **Debounce**: the script sleeps ~5 s, re-checks the pane's current status
   through `HERDR_BIN_PATH` (`herdr agent get <pane>`), and aborts if the
   status moved on (or the agent is gone).
2. **Dedupe**: the last notified status is recorded per pane under
   `HERDR_PLUGIN_STATE_DIR/notify/`; a same-status repeat sends nothing. A
   *different* status that survives its own debounce re-arms the pane.

Each eligible device gets one `POST https://heeler-apns.bybee.dev/push` by
default (see `relay/README.md`), carrying the encrypted envelope and an opaque
per-pane `collapse` key (derived from the device's Notification Key and the
pane id, so the relay cannot guess the pane while newer statuses still replace
older notifications). Transient failures (network errors, 429, 5xx) are
retried up to 3 attempts; a `410 Unregistered` verdict prunes that token from
`notifications.json` (preserving any fields this plugin does not understand);
other 4xx verdicts are final.

Plugin-side settings live in `notify.json` next to the registration file in
the plugin config dir:

| Field            | Type    | Meaning |
| ---------------- | ------- | ------- |
| `relay_url`      | string  | Optional Push Relay base URL override for a self-built app. Defaults to `https://heeler-apns.bybee.dev`; the app writes the resolved value during Notification Registration. |
| `debounce_ms`    | integer | Debounce sleep override for the alert notify hook. Default 5000. |
| `activity_debounce_ms` | integer | Latest-wins debounce sleep for the Live Activity hook. Default 1500. |
| `retry_delay_ms` | integer | Delay between retry attempts. Default 1000. |

### Hook event JSON (verified against herdr 0.7.5)

`HERDR_PLUGIN_EVENT_JSON` as captured empirically from a live herdr 0.7.5
event hook invocation — note the `event` value is snake_case on the wire even
though the manifest subscribes to the dot name:

```json
{"event":"pane_agent_status_changed",
 "data":{"type":"pane_agent_status_changed","pane_id":"wV:p1",
         "workspace_id":"wV","agent_status":"blocked","agent":"claude"}}
```

`agent` (plus `title`, `display_agent`, `state_labels` per herdr source) is
optional. herdr's wire shapes carry no stability guarantee, so the hook parses
leniently: it requires only `data.pane_id` and `data.agent_status` and ignores
everything it does not recognize.

## Activity hook

The second manifest `[[events]]` hook on `pane.agent_status_changed` runs
`src/activity-hook.js` as its own short-lived process. herdr invokes both
this command and `src/notify-hook.js` for the same event (verified on
0.8.0); there is no in-plugin dispatcher. It is independent of the alert
notify hook: `notify` flags do not gate it, and a Host with no
`live_activity` registration sends nothing.

The hook lists the Host's agents through `HERDR_BIN_PATH` (`herdr agent list`),
resolves workspace labels best-effort through `herdr workspace list`, and drives
one Live Activity per Host. Eligible statuses are **Working**,
**Blocked**, and **Done**; idle and unknown panes are hidden. The encrypted
details envelope uses the same Notification Key as alerts, sealed under AAD
`HERDR-ACTIVITY:1` (see `docs/agents/live-activity-contract.md` and
`test-vectors/live-activity-content-v1.json`).

Anti-noise, in order:

1. **Cheap exits**: no device has a `live_activity` object with a plausible
   hex token, valid env, and 32-byte key; or `activity/last-state.json`
   recorded `ended: true` and the incoming status is not working/blocked/done.
2. **Latest-wins debounce**: the script writes `activity/claim.json` and
   sleeps `activity_debounce_ms` (default 1500). A newer claim from an
   overlapping invocation wins; the loser exits without sending.
3. **Unchanged snapshot**: a `{pane_id: status}` map identical to last-state
   sends nothing.

An empty eligible set sends `event: end` (skipped if already ended) with zero
counts, `dismissal_date` equal to the timestamp, and an envelope whose
`agents` array is empty. Otherwise it sends `event: update` with
`stale_date` = timestamp + 900. Priority is **10** only when some pane is
blocked now and was not blocked in last-state (absent last-state counts as
empty); otherwise **5**.

Each eligible device gets one `POST /push` with `kind: liveactivity`, the
activity token, and the sealed envelope. Transient failures (network errors,
429, 5xx) are retried up to 3 attempts. A `410 Unregistered` verdict deletes
only that entry's `live_activity` field, preserving the alert `token`, `key`,
`notify` flags, and any field this plugin does not understand. A relay-origin
`413` degrades the envelope once per step (drop every `title` while retaining
the displayed workspace/kind/status, then send `agents: []`) and retries;
the hook also pre-degrades when the projected ciphertext would exceed the Live
Activity size budget.

Last-state (`activity/last-state.json`: `sent_at_ms`, `statuses`, `ended`) is
written only after at least one successful delivery. All state writes are
temp-file + rename.

## Tests

```bash
npm test
```

Uses Node's built-in test runner; no test dependencies.
