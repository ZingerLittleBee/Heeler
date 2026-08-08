---
status: accepted
---

# Monitor: a non-realtime default Agent surface with a local Composer

The Agent detail screen becomes two surfaces. **Monitor**, the new default, is
a non-realtime view: an ANSI-rendered snapshot of the pane's latest screen,
locally scrollable history captured while the Agent was idle, and a **Composer**
that drafts input entirely on device and delivers it in one RPC. **Attach**,
today's embedded live terminal, remains as the escape hatch — pushed full
screen on demand, its PTY opened on entry and closed on exit.

The motivation is weak-link latency. Attach puts every keystroke on the wire
and waits for the remote echo, which on a slow link means typing blind; and it
holds a live PTY channel the whole time the user is merely reading. Monitor
inverts both costs: reading is served from local cache with staleness signaled
honestly, and typing costs zero round trips until the user explicitly sends.

## Third attempt — the history matters

This is the third run at local composition, and the first as its own surface:

1. **AgentInputBar + Dictation** — removed wholesale in `1f770d8`
   ("use the iOS system keyboard"), together with the `pane.send_input` /
   `pane.send_keys` transport methods. No rationale was recorded.
2. **TerminalComposeBar** — built later (`fd058c3`) for exactly this latency
   argument, shelved unmerged on `x/compose-bar`; only its
   `TerminalInputController` landed on main. It left one binding iOS lesson:
   the draft field cannot live inside the Keys keyboard (the terminal's
   `inputView`) because the responder change that focuses it tears that
   keyboard down — a composer must ride the surface, not the keyboard.

Both predecessors layered a second input box onto a live terminal that already
renders the agent's own input box. Monitor removes that collision: the
non-realtime surface has exactly one input control, the Composer, and the live
TUI is only ever seen inside Attach.

## API reality this design is shaped by (verified live on herdr 0.8.0)

- Remote history is **not addressable**: `pane.read`/`agent.read` take only
  `visible`/`recent` and a line count — no offset, no cursor — with a server
  hard cap of 1000 lines. "Scroll to load older from the server" cannot exist.
- For alternate-screen TUIs (claude), history is capturable **only while the
  Agent is idle** (`agent_not_idle` otherwise); while working, only the
  current screen is readable.
- `revision` is always 0, `pane_output_changed` is not subscribable, and
  `pane.output_matched` is edge-triggered — none works as an output-change
  signal. `pane.agent_status_changed` is precise and tiny, and is the one
  push signal Monitor uses.
- `agent.prompt` types text plus Enter and, without `wait`, returns
  immediately as a delivery acknowledgment. Prompting a working agent is
  accepted unconditionally; queueing is the agent TUI's behavior, not herdr's.

Hence the model: while working, Monitor mirrors the latest screen by adaptive
foreground polling; on idle/done it stops polling and follows status events;
history is backfilled on demand (view opened cold, or scroll hitting the top
while idle) — the only place a loading state exists. While working, older
history is truthfully "unavailable", not "loading". The Composer sends via
`agent.prompt` without `wait`; the RPC result marks the optimistic echo
Delivered, and subsequent status events carry the working→done story.

## Considered Options

- **Monitor + Attach escape hatch** — chosen, as above.
- **Compose bar over the live terminal** — tried twice, abandoned twice; two
  input boxes on one live screen, and it leaves reading costs untouched.
- **Chat-style structured view** — rejected. herdr has no conversation API;
  message boundaries would be reverse-engineered from TUI repaints and break
  with every upstream TUI change (ADR 0010 documents the cost of extracting
  even URLs from the byte stream).
- **`wait`-based prompt delivery** — rejected. It occupies one of eight RPC
  channels for the length of an agent turn, and its `until` semantics are a
  trap (claude finishes on `done`, not `idle`).
- **`pane.output_matched` as the refresh signal** — rejected on live
  measurement: edge-triggered, silent during sustained output.
- **Plugin-side output archive** for full, addressable history — deferred, not
  rejected; it is its own project and the only route past the 1000-line cap.

## Consequences

- The transport regains `agent.prompt`/`send_keys`-shaped methods removed in
  `1f770d8`; Attach stays the only consumer of the PTY path.
- History reads must use `agent.read`: `pane.read` silently degrades to the
  visible screen while a claude agent works and reports `truncated: false`,
  which is indistinguishable from "this is everything".
- Cross-reconnect cache reconciliation is overlap-stitching, not incremental
  fetch; where snapshots do not overlap, Monitor shows an honest gap marker.
- Draft insertions (Snippets, Skills, image paths) become plain local text
  edits in the Composer; ADR 0009's insert-without-submit semantics hold
  trivially there. First shipping cut is plain text plus the control-key
  strip; the accessory surfaces migrate after.
- Deep links and Console navigation target Monitor; Attach is reached only
  through it.
