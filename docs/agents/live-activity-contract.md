# Live Activity wire contract (v1)

The single authority for every shape crossing a process boundary in the
per-Host agent Live Activity pipeline (app ↔ widget ↔ registration file ↔
plugin ↔ relay ↔ APNs). Implementations in `Sources/`, `plugin/`, and
`relay/` must match this file byte-for-byte where it says canonical; the
shared vectors in `plugin/test-vectors/live-activity-content-v1.json` assert
it. Change this file and the vectors in lockstep, never one side alone.

Feature decisions this contract encodes: one Live Activity per Host; shows
agents whose herdr status is `working`, `blocked`, or `done` (idle/unknown
hidden); hybrid encryption (plaintext counts, encrypted details); the app
starts activities locally and writes the per-activity push token to the
Host; the plugin drives updates and end over APNs after the app suspends.
No push-to-start in v1.

## ContentState

Decoded by ActivityKit's default `JSONDecoder` (no date/key strategies).
Every field primitive; statuses are strings, never enums — OS-side decoding
drops the whole update on any type mismatch.

```json
{"counts": {"working": 2, "blocked": 1, "done": 0},
 "envelope": {"v": 1, "kid": "...", "n": "...", "ct": "..."}}
```

- `counts` counts the **full** eligible inventory (not capped).
- `envelope` is Optional on the Swift side: absent or undecryptable
  degrades rendering to counts-only, never drops the update.
- The Swift attributes type is `AgentActivityAttributes` (static content:
  `hostID` UUID string only). The name is shipped-forever: APNs
  `attributes-type` must match it exactly if push-to-start is ever added.

## Encrypted details envelope

Same AES-256-GCM mechanics, `{v,kid,n,ct}` framing, and kid derivation
(first 8 bytes of SHA-256 over the 32-byte key, unpadded base64url) as the
notification envelope, with AAD **`HERDR-ACTIVITY:1`** for domain
separation: a `HERDR-NOTIFY:1` ciphertext must fail authentication when
opened as an activity envelope, and vice versa.

Decrypted plaintext (canonical form):

```json
{"agents": [{"kind": "claude", "name": "reviewer", "pane": "wV:p1", "status": "blocked", "title": "..."}],
 "host": "mbp", "v": 1}
```

- Canonical encoding, identical on both sides: compact JSON (no
  whitespace), object keys in **ascending alphabetical order** at every
  level (Swift: `.sortedKeys, .withoutEscapingSlashes`; Node: construct
  objects with alphabetically ordered keys, then `JSON.stringify`).
- `agents` ordered as: eligible agents whose pane id appears in this
  device's `live_activity.pinned_pane_ids` first, by that array's index
  (most recently pinned first); remaining eligible agents in the existing
  order (`blocked` > `done` > `working`, ties by `pane` ascending byte
  order). Cap at **5** after that sort. `counts` still covers everything.
  Pins never change eligibility: idle/unknown stay hidden. A pinned
  working agent may displace an unpinned blocked agent from the visible
  rows. The widget renders rows in envelope order and does not re-sort.
- `title` is `terminal_title_stripped ?? terminal_title`, trimmed to ≤80
  graphemes; omitted (not empty) when unavailable. `kind` falls back to
  `"unknown"`.
- `name` is the herdr agent name (`display_agent ?? name`), trimmed to ≤80
  graphemes; omitted (not empty) when the agent is unnamed. Agent entry key
  order stays alphabetical: `kind` < `name` < `pane` < `status` < `title`.
- `host` is the Host machine's short hostname (first DNS label), ≤80
  graphemes.
- Unknown fields in plaintext or envelope frame are ignored (additive v1
  metadata); breaking changes bump `v` on both ends together.
- Size budget: the base64url `ct` should stay ≤ ~2800 bytes so the full
  APNs payload stays under 4096. Producers degrade in order: drop all
  `title` fields, then send `agents: []`; counts always fit.

The widget renders no Host identity: an agent renders as two lines
mirroring the herdr sidebar's hierarchy — the task `title` on top with
the identity (`name`, falling back to `kind` when unnamed, exactly like
the TUI) indented beneath; a missing title promotes the identity to the
top line alone. The lock screen draws a uniform list in envelope order
(pinned eligible first, then status rank): all four rows when the
inventory fits, otherwise three rows plus "+N more" (the ~160pt banner
budget). The `host` field stays in the wire for producers but is not
displayed.

## Relay request (plugin → relay)

Extends the existing `POST /push`. Bodies without `kind` behave exactly as
today (alert path, byte-identical); the alert path rejects any body that
does carry `kind`.

```json
{"kind": "liveactivity", "token": "<hex activity push token>",
 "env": "production" | "sandbox",
 "event": "update" | "end", "priority": 5 | 10,
 "timestamp": <unix seconds>,
 "stale_date": <optional, > timestamp>,
 "dismissal_date": <optional, end only>,
 "counts": {"working": N, "blocked": N, "done": N},
 "envelope": "<canonical envelope JSON string>"}
```

Validation (relay-origin failures use `{"error": ...}`): `event` whitelist;
`priority` ∈ {5, 10} and 10 requires `counts.blocked >= 1`; `timestamp`
integer within `[now − 86400, now + 300]`; `counts` exactly the three keys,
integers 0..999; `envelope` non-empty string, never parsed; `collapse`
absent. The relay additionally observes the counts and the
update/end/priority signal — nothing else new (PRIVACY.md documents this).

## APNs request (relay → Apple)

`POST /3/device/<activity token>` with the existing ES256 JWT. Headers:
`apns-push-type: liveactivity`, `apns-topic:
<APNS_TOPIC>.push-type.liveactivity` (suffix-derived, no new config),
`apns-priority: 5|10`. Body:

```json
{"aps": {"timestamp": <unix seconds>, "event": "update" | "end",
         "content-state": {"counts": {...}, "envelope": {...}},
         "stale-date": <update only: timestamp + 900>,
         "dismissal-date": <end only: = timestamp, immediate removal>}}
```

Never an `alert` field — the existing alert-notification path owns alerts.
Priority 10 only when an agent **newly** entered `blocked`; 5 otherwise.
Existing 4096-byte pre-check applies; 410/413 verdicts pass through to the
plugin unchanged (`{"reason": ...}`).

## Registration file (additive per-device field)

Written by the app (set on start and token rotation, cleared on local end
or user dismissal while foregrounded), read fresh by the plugin on every
event:

```json
"live_activity": {"token": "<hex per-activity push token>",
                  "started_at": "<ISO 8601>",
                  "pinned_pane_ids": ["wV:p7X", "wV:p1"]}
```

Missing field = send nothing (fail closed; `notify` flags do not gate this
path). On APNs 410 the plugin deletes only this field, preserving the
device entry's alert `token`, `key`, `notify`, and unknown fields. A user
dismissing the activity while the app is dead self-heals through that 410
on the next push.

`pinned_pane_ids` is this Host's pin recency list: pane-id strings,
most-recently-pinned first. The app writes it whenever it writes
`live_activity` and pushes an update when the pin set changes while the
Host is connected and an activity is running. Missing, null, a
non-array, or any non-string entry is treated as an empty list (older
apps never write the field). Empty
string entries are still strings and are kept. The field is additive v1
metadata; unknown sibling keys on `live_activity` must survive a rewrite.

## Shared vectors

`plugin/test-vectors/live-activity-content-v1.json`, same schema style as
`notification-payload-v1.json`: non-`decodeOnly` `valid` vectors must be
reproduced byte-for-byte by the seal side and opened by the open side;
`invalid` vectors must fail with the given typed error. Includes the
cross-AAD case proving domain separation. Pin-order cases also carry
`inventory`, `pinned_pane_ids`, and `counts` so both suites pin the
shared sort rule. Consumed by both the Node suite and HeelerTests;
regenerate only via an independent raw-crypto script.
