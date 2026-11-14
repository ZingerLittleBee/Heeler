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

On a herdr-core Host the Heeler Host Helper takes the plugin's place (ADR 0033):
the app writes the push token into the Helper's `notifications.json`, and the
Helper drives updates and the end through this same relay request. It reads
every status below from what the core reports, and counts Done per device from
that device's seen marks, so each device's token has its own counts and list.

herdr-core adds one status, Error, which the wire does not name. **An Error
Agent counts under `blocked` and carries `"status": "blocked"` in its agent
entry**, in the app's content and the Helper's updates alike. It sorts with
Blocked, and entering it can raise priority 10 as entering Blocked does. Only a
configured `status` row field still says "Error", being display text. No count,
field or status value is added, and the Push Relay neither changes nor needs a
redeploy.

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
  the last component of trimmed `cwd` for `directory`; trimmed `cwd` for `path`; `tokens` values for `$custom` fields; and on a
  herdr-core Host the Terminal's label for `label:<key>` fields, which the Helper
  reads from the same `tokens`.
  On a herdr-core Host the app takes an Agent's `cwd` from its Terminal's
  foreground sample, else the record's launch `cwd`. Host Helper 0.5.7 still
  sends the record's `cwd` for its rows and its notifications' project, so an
  Agent typed after a `cd` names its Terminal's starting folder there once the
  app suspends, until the next plugin version follows the app.
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

## Widget rendering

The widget preserves configured Agent List Fields, including field colors,
bold and dim styles. When `rows` is absent it uses workspace and friendly
Agent kind as the legacy identity. Agent order stays in the sender's pin-aware
order. Error remains Blocked on the wire and reads "Needs you" on the Lock
Screen and expanded Dynamic Island; a configured status field may still say
"Error".

The Lock Screen uses the system background material through
`.activityBackgroundTint(nil)`, with no painted background layer. Text and
status colors remain unresolved dynamic UIKit colors so an existing activity
can follow system appearance changes when ActivityKit refreshes it. The End
control receives unresolved `UIColor.label` through `Color(uiColor:)`.
ActivityKit's SwiftUI `colorScheme` is never consulted. Status glyphs use
dynamic Lock Screen inks from `AgentActivityStatusStyle`.

A separate, one-line semibold Host heading on the Lock Screen and expanded
Dynamic Island uses middle truncation. Its name
comes from the local Host snapshot by attributes `hostID`, then the envelope's
`host`, then no heading when neither supplies a nonempty name. There are no
header count chips. Each linked Agent entry starts with an open ring for
Working, a filled exclamation circle for Blocked, or a check circle for Done.
Its configured fields stay between that glyph and a secondary status word,
"Working", "Needs you", or "Done". Accessibility reads those same fields and
the displayed status word. Each entry opens its Agent; surrounding chrome
keeps the Console fallback link.

The list fits complete entries within 160 pt, including the optional 20 pt
heading, 6 pt vertical padding on each edge, and one overflow/stale caption.
It shows at most four entries. One or two entries have a 44 pt minimum target;
three or four use a 28 pt dense minimum. Configured entries are budgeted at,
and held to, their rendered height: their text lines plus 1 pt of padding on
each edge, so 31 pt for two lines and 44 pt for three. A named Host therefore
fits four two-line entries without a caption or three with one, and two
three-line entries plus the caption. Lock Screen text retains the system
Dynamic Type size; only the Dynamic Island caps it through `islandTypeSize()`.
Overflow uses the full plaintext inventory count minus the number of visible
entries.
Stale content adds "May be out of date", sharing the overflow line when
needed. Debug decrypt diagnostics remain outside the production height budget.

An absent or undecryptable envelope, or empty decrypted Agent details, shows
only the optional Host heading and localized count phrases in Blocked,
Working, Done order, such as "1 needs you · 2 working". English plurals use
"2 need you". Staleness remains visible. Counts-only does not imply a
connection failure and has no overflow from an Agent list.

### Dynamic Island

Compact presentations show one status mark per Agent in attention order,
Blocked, Done, Working, using the full plaintext counts even without decrypted
details. Marks use the same open ring, filled exclamation circle, and check
circle as the Agent rows. At most four slots appear. When the inventory exceeds
four, the first three marks remain and the last slot becomes a plus mark.
The first two slots lead the camera and the rest trail it. One Agent leaves
the trailing region empty. There are no visible count numbers or status words.

A rounded-square Host tile precedes the compact leading marks only when the
local snapshot contains at least two Hosts and the current Host has a nonempty
`label`. This uses the entire configured catalog, including quiet Hosts, rather
than the set of running activities. One Host has no tile in any Island region.
An absent snapshot, unknown Host, or missing label omits the tile.

Minimal presentation without a tile shows up to four status marks in a two by
two cluster, with the same overflow rule. A single mark stays larger. With an
eligible tile, minimal shows the Host label wearing its most urgent status,
filled for Blocked, outlined for Working, or outlined with a small check for
Done. Compact and minimal expose one accessibility summary of all counts,
using localized phrases such as "1 needs you, 1 working, 1 done". Only a
snapshot listing at least two Hosts adds the Host name to that summary.

The expanded header shows the full Host name with the eligible tile before
it. Its trailing region may summarize the status marks. The bottom preserves
configured Agent List Fields, status marks, and the displayed status words
used by the Lock Screen. Complete linked entries remain in envelope order,
with at most three entries inside the existing 100 pt row budget, including
the overflow caption. Surrounding chrome keeps the Console fallback link.
Without Agent details, expanded content shows the localized count phrases
instead of Agent rows.
Island type sizes cap at `.large` through `islandTypeSize()`. Island inks
remain Mocha regardless of ambient appearance.

### Local Host snapshot

The app writes `live-activity-hosts.json` in the shared app-group container.
It contains `{"v":1,"hosts":[{"id":"<Host UUID string>","name":"<displayName>","label":"L"}]}`
in the app's Host catalog order. `id` is `Host.id.uuidString`, identical to the
Activity attributes' `hostID`. This file is local presentation data, separate
from the encrypted envelope and relay payload.

Optional `label` is additive v1 metadata. Older files without it still decode
and supply Host names, but omit Island tiles. On every publish the app computes
labels with `HostMonogram.labels(for:)` over the full catalog's ids and display
names, including when there is only one Host. A first letter identifies a
distinct name; collisions use word initials or two letters, then the first
letter and a number. Numbers run in catalog order per first letter and skip any
label an unnumbered Host already holds. IPv4 names use the last octet, or the
last two octets on a collision.
The widget never computes labels from the subset of active Hosts, and labels
never pass through the Push Relay.

The app publishes at initialization and after catalog changes, including
rename, addition, removal, and reorder. Equal snapshots suppress writes,
including on relaunch. Replacement is atomic, protected until first unlock,
and excluded from backup, matching the other app-group snapshot writers.
Missing, malformed, or unknown-version snapshots read as absent; unknown
future fields are ignored. A write makes the current catalog available on the
next widget render; it does not itself request an ActivityKit refresh. A
running activity shows a Host rename on its next update.

## Relay request (plugin → relay)

Extends the existing `POST /push`. Bodies without `kind` take the alert path,
which this extension leaves unchanged; the alert path rejects any body that
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
         "relevance-score": <update only: derived from counts>,
         "stale-date": <update only: timestamp + 900>,
         "dismissal-date": <end only: = timestamp, immediate removal>}}
```

Never an `alert` field — the existing alert-notification path owns alerts.
Priority 10 only when an agent **newly** entered `blocked`; 5 otherwise.
Existing 4096-byte pre-check applies; 410/413 verdicts pass through to the
plugin unchanged (`{"reason": ...}`).

Relevance is derived only from plaintext `counts`, with no count tiebreak.
The first matching tier sets the score:

| Condition | Score |
| --------- | ----- |
| `blocked >= 1` | 3 |
| `working >= 1` | 2 |
| `done >= 1` | 1 |
| All counts are zero | 0 |

Higher scores rank a Host's Live Activity above lower scores on the Lock
Screen and in the Dynamic Island. The app sets `ActivityContent.relevanceScore`
on local starts and updates. The relay derives the numeric `aps["relevance-score"]`
on every `update` and omits it on `end`. The relay request has no relevance
field, so existing plugins and Host Helpers receive this behavior after the
relay is deployed.

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
three rows, at most 16 fields per row, no per-kind overrides. It carries only
each row's left side: the app keeps the rows' right sides and the right-only
`status_badge` and `changes` fields out of it, because they never reach a Live
Activity and installed plugins drop a layout with a field they do not know. Each field has
`token` and optional `fg`, `bold`, and `dim`, matching the Console layout JSON.
A `label:<key>` token follows the app's rule for a label it offers
(`AgentRowToken.terminalLabel`): a key of 1 to 64 UTF-8 bytes, not all whitespace,
with no `=` and no control or format character. Any other token makes the layout
malformed. The app writes `label:<key>` tokens only for a herdr-core Host. A Herdr
TUI Host has no Terminal labels, and plugin 0.8.0 reads the token as malformed and
omits all of that Host's `rows`, so a label field that Apply to All Hosts copied
there stays out of its `row_layout`.
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
shared sort rule, and one such case pins Error under `blocked`. Consumed by both
the Node suite and HeelerTests;
regenerate only via an independent raw-crypto script.
