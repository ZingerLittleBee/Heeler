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
{"agents": [{"kind": "claude", "name": "reviewer", "pane": "wV:p1", "status": "blocked", "title": "...", "workspace": "Heeler"}],
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
  graphemes; omitted (not empty) when the agent is unnamed.
- `workspace` is the herdr workspace label resolved by `workspace_id`, trimmed
  to ≤80 graphemes and omitted when unavailable. It is additive v1 metadata,
  so older senders remain readable with a kind-only identity. Agent entry key
  order is `kind` < `name` < `pane` < `rows` < `status` < `title` < `workspace`.
- Optional `rows` carries the Agent's rendered Agent List Fields, using this
  device's resolved `live_activity.row_layout`. It contains at most three
  nonempty rows, each an array of plain-text spans:
  `[{"bold":true,"dim":false,"fg":"#AbC","text":"Heeler"},{"text":" · "},{"text":"reviewer"}]`.
  Span keys are ordered `bold` < `dim` < `fg` < `text`; styles are optional,
  `fg` accepts only `#RGB` or `#RRGGBB`, and text keeps the first 80 graphemes without adding an ellipsis.
  Separators are separate unstyled spans. Empty fields and rows are omitted;
  plugin text is never interpreted as Markdown. An absent or malformed layout
  omits `rows`, preserving the legacy workspace/kind identity. An explicitly
  empty layout produces `rows: []`.
- Field values match the Console: workspace label; tab label (hide the sole
  tab when its label equals its 1-based position); AgentInfo `title`, falling
  back to the matching pane label only when absent; Agent display name
  (`display_agent`, then `name`, then raw kind); raw terminal title; stripped terminal title (an absent value falls back
  to the raw title with one leading activity glyph removed only at a whitespace
  boundary, while an explicitly empty value stays empty); configured Host display name; capitalized status;
  trimmed `cwd` for directory; and `tokens` values for `$custom` fields.
  `state_icon` and `state_text` render no text because the status indicator
  owns that information. Missing context suppresses that field only.
- `host` is the Host machine's short hostname (first DNS label), ≤80
  graphemes.
- Unknown fields in plaintext or envelope frame are ignored (additive v1
  metadata); breaking changes bump `v` on both ends together.
- Size budget: the base64url `ct` should stay ≤ ~2800 bytes so the full
  APNs payload stays under 4096. Producers degrade in order: drop all
  `title` and legacy `name` fields, then `rows`, then send `agents: []`;
  workspace/kind identity remains after rows are dropped; counts always fit.

The widget renders the configured rows beside each Agent's status marker: a
colored dot on the Lock Screen, a status glyph in the Dynamic Island.
It preserves field colors, bold and dim styles. When `rows` is absent it uses
workspace and friendly Agent kind as the legacy identity. Agent order remains
unchanged. The lock-screen list fits as many complete Agent entries as the
banner budget allows, followed by "+N more" when needed. The compact Dynamic
Island shows status counts as glyph-and-count tokens in attention order
(blocked, done, working); the expanded view uses configured rows.
The envelope's `host` is not a separate heading, but a configured `host` field
can display the per-device Host name.

## Conversational rows

Opt-in plugin setting `activity_rows: "conversational"` in `notify.json`
(default `"layout"`, which keeps everything above unchanged, including when
pushes are sent). In that mode the plugin builds `rows` itself for every Agent
and ignores the device's `row_layout`. The wire shape is the ordinary `rows`
shape, so the app needs no change. Each Agent gets at most three nonempty
rows, and **each row is at most 80 graphemes in total** (not per span). A
longer row is cut to 79 graphemes plus `…`; a separator, joiner or earlier
`…` is never left at the cut.

1. Identity: `<agent name> · <workspace label>` (name bold; name is
   `display_agent`, then `name`, then raw kind, then `unknown`). This row is
   never removed by the size limit.
2. Working title: `terminal_title_stripped`, or when that is absent or blank
   the raw `terminal_title` minus one leading activity glyph. Omitted when
   there is no title; no filler text.
3. State, when it began, and when the row was updated:

   ```
   row3  = state [ " " word " " start ] " · " "updated " hhmm " " zone
   state = "Working" | "Blocked" | "Turn ended"
   word  = "since" | "at"            ; "at" after "Turn ended"
   start = [ "Oct 8 " ] hhmm [ " " zone ]
   ```

   For example `Working since 14:03 · updated 16:12 CDT` or
   `Turn ended at 15:58 · updated 16:12 CDT`. When the start is unknown
   (see "Since") it is left out, `Working · updated 16:12 CDT`, rather than
   shown as a word that carries no information; no start is ever guessed.
   Times are 24-hour in one display zone: `activity_time_zone` (an IANA name)
   when valid, else the Host's zone. The zone label is the `en-US` short name
   (`CDT`, or `GMT+5:30` where no abbreviation exists) and follows `updated`.
   The start adds its date when that differs from the date of `updated`, and
   its own zone label when that differs (a daylight-saving change between the
   two instants), so `since 01:30 CDT · updated 01:10 CST` is never read as a
   negative age. `done` is worded `Turn ended`, never as completion.

All text comes from herdr fields or the fixed labels above; nothing is
summarised. Untrusted text drops control, format (except ZWJ/ZWNJ), line and
paragraph separator characters, lone surrogates and Hangul filler characters,
collapses whitespace, and is cleaned before it is clipped. It is only ever a
span `text` and is never interpreted as Markdown. In this mode the `title`,
`name` and `workspace` wire fields are cleaned the same way. No `fg` colour is
set, so state is carried by text.

**When rows refresh.** The Live Activity is refreshed when herdr reports an
Agent status change, or a change to its metadata-derived title or label. A
terminal title that changes while the status stays the same is not sent
until the next such event. `updated` is the time the hook read herdr. iOS marks
the activity stale 15 minutes after the last push (`stale-date`), the
phone-side signal that nothing has arrived.

### Since

`since` is the time this hook first observed the Agent's current
`(status, state_change_seq)` pair; it is hook-observed, not reported by herdr.
State lives in `activity/last-state.json` with `v: 2`, keyed by herdr's
`terminal_id` (never sent to the device), plus an `epoch` naming the herdr
server (inode and change time of `HERDR_SOCKET_PATH`). The start is unknown,
and left out of row 3, when there is no comparable saved state: none saved, a different or
unknown epoch, any saved `state_change_seq` above the current one, or an
Agent without a `terminal_id`. A start stays unknown until its pair changes.
The state is read again after the debounce claim is won and saved on every run
that passes the claim, including runs that send nothing and failed sends, so a
failed send never moves `since`.

### Push volume

Apple publishes an hourly ActivityKit push budget without the number;
priority 10 counts against it and priority 5 does not but may be grouped or
delayed. In conversational mode:

1. The duplicate check is per device: a sha256 of the counts and the final
   rows after the size limit, with the `updated` clock masked. A change no device
   would see (a hidden sixth Agent's title, a spinner glyph) sends nothing.
2. Between two sends to one device the hook waits until
   `activity_min_interval_ms` (default 15000) has passed, checks that no newer
   invocation has claimed, reads herdr again and sends the newest state. `end`
   and a newly blocked Agent do not wait.
3. Priority 10 stays reserved for a newly blocked Agent; after
   `activity_p10_per_hour` (default 6) such pushes to one device in the
   trailing hour, further ones go at priority 5 and a line is logged.
4. A content-only send (every Agent's `(status, state_change_seq)` already
   recorded) is priority 5 and is limited to `activity_content_per_hour`
   (default 60) per device; past that it is skipped with a log line while
   status changes keep sending.

These defaults are conservative guesses, not a measured allowance.

### Size limit

When the payload exceeds the budgets (ciphertext 2800 bytes, APNs payload 4096,
relay request 8192) the plugin degrades one Agent per step, always the
lowest-ranked Agent that still has the thing being removed. Rank is blocked,
then working, then done; ties keep pinned Agents first, then display order.

1. drop row 2 of done Agents, then of working Agents, then of blocked Agents;
2. drop the `title` and `name` wire fields;
3. drop whole Agents, never a blocked one while another Agent remains;
   `counts` still cover every eligible Agent;
4. identity-only rows;
5. `agents: []`.

Test fixtures for this mode are synthetic: pane ids `w1:p1`, names `agent-a`,
neutral titles, host `example-host`.

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
                  "pinned_pane_ids": ["wV:p7X", "wV:p1"],
                  "host_name": "My Mac",
                  "row_layout": {"rows": [[{"token":"workspace"}],
                                          [{"token":"agent"}],
                                          [{"token":"directory"}]],
                                 "row_gap": 0, "rows_by_agent": {}}}
```

Missing field = send nothing (fail closed; `notify` flags do not gate this
path). On APNs 410 the plugin deletes only this field, preserving the
device entry's alert `token`, `key`, `notify`, and unknown fields. A user
dismissing the activity while the app is dead self-heals through that 410
on the next push.

Hosts on several herdr sessions of one remote user share one
`notifications.json`, so the field lives on the Host's **own** device entry:
the one carrying this device token and the Host's Notification Key. That
entry also carries `session` (`""` for the default session, otherwise the
session name; see [plugin/README.md](../../plugin/README.md#herdr-sessions)),
and the app keeps at most one entry per device token and session. Before
writing a token the app strips `live_activity` holding that same token from
every other entry; pin and layout writes touch only the own entry and fail
with `deviceNotRegistered` when there is none. A clear removes the field
from the own entry, or, without one, from whichever entry holds that token;
another Host's `live_activity` with a different token is never touched. The
activity hook in each session pushes only to entries of its own session plus
legacy entries without a string `session`, and keeps its claim and last
state per session, so two sessions never drive the same activity.

`pinned_pane_ids` is this Host's pin recency list: pane-id strings,
most-recently-pinned first. The app writes it whenever it writes
`live_activity` and pushes an update when the pin set changes while the
Host is connected and an activity is running. Missing, null, a
non-array, or any non-string entry is treated as an empty list (older
apps never write the field). Empty
string entries are still strings and are kept. The field is additive v1
metadata; unknown sibling keys on `live_activity` must survive a rewrite.

`row_layout` is the app's resolved per-Host Agent List Fields layout: at most
three rows, at most 16 fields per row, no per-kind overrides. Each field has
`token` and optional `fg`, `bold`, and `dim`, matching the Console layout JSON.
`row_gap` and `rows_by_agent` are accepted for structural compatibility but do
not change activity rendering. The app writes this layout and optional
`host_name` on registration, layout edits, Host name changes, and plugin sync.
The plugin falls back to the short hostname when `host_name` is absent.
Registration preferences participate in duplicate-update suppression, so the
next status hook can send changed layout or pin preferences even if statuses
are unchanged. The hook reads tab/pane context only when configured fields
need it, once per workspace rather than once per Agent. Foreground app updates
use the same resolved layout; background delivery still follows status events.

## Shared vectors

`plugin/test-vectors/live-activity-content-v1.json`, same schema style as
`notification-payload-v1.json`: non-`decodeOnly` `valid` vectors must be
reproduced byte-for-byte by the seal side and opened by the open side;
`invalid` vectors must fail with the given typed error. Includes the
cross-AAD case proving domain separation. Pin-order cases also carry
`inventory`, `pinned_pane_ids`, and `counts` so both suites pin the
shared sort rule. Conversational-row cases carry a `conversational` object
(herdr `agent list` entries, status, workspace, `sinceMs`, `asOfMs`,
`timeZone`) that the Node suite must turn into exactly the payload's `rows`.
Consumed by both the Node suite and HeelerTests;
regenerate only via an independent raw-crypto script.
