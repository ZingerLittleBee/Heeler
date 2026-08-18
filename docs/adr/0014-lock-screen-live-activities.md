# Show per-Host agent status on the lock screen through push-updated Live Activities

The Console answers "what are my agents doing" only while the app is open; the
moment the phone locks, the answer is gone until the next Blocked/Done alert.
ActivityKit Live Activities are iOS's mechanism for exactly this glanceable
state, but they collide with two standing decisions: ADR 0008 deliberately
filters Working/Idle traffic out of the push pipeline, and its end-to-end
encryption premise assumes a Notification Service Extension can decrypt before
anything renders — Live Activity pushes have no such hook, the system decodes
`content-state` itself. We decided: one Live Activity per Host, driven by a
second plugin hook and a `kind: "liveactivity"` branch on the same stateless
relay, carrying a **hybrid content-state** — plaintext status counts plus the
sensitive details (agent kinds, titles, host name) sealed in the existing
envelope format under a new `HERDR-ACTIVITY:1` AAD, decrypted at render time
inside the widget extension from the shared Keychain. The full contract lives
in `docs/agents/live-activity-contract.md`.

Decisions fixed during design (research reports: three OSS/API surveys, 2026-08):

- **One activity per Host, aggregate UI.** No production app renders a
  multi-row list inside one activity (~160 pt lock-screen budget); the two
  proven shapes are aggregation (Firefox downloads) and one-activity-per-item
  (Home Assistant, iTorrent). Each Host only knows its own agents, so
  per-Host is also the only push topology that works without a coordinator.
- **Hybrid encryption, not pure ciphertext.** Widget view bodies do execute on
  every update, and the Notification Keys are readable while locked
  (`AfterFirstUnlock` in the shared Keychain group), so render-time decryption
  works on the iPhone lock screen. But iOS 18 mirrors activities to the watch
  Smart Stack with the raw content-state, and pre-first-unlock the key is
  unavailable — pure ciphertext would render nothing there. Plaintext counts
  are the graceful floor everywhere; the relay now additionally observes
  counts and the update/end/priority signal, and PRIVACY.md says so. This is
  a deliberate, bounded relaxation of ADR 0008's "relay sees ciphertext only".
- **Statuses mirror herdr**: Working, Blocked, and Done show; Idle and
  Unknown do not; no client-side expiry. All three empty ends the activity.
- **Local start, push update.** The app starts the activity while
  foregrounded (`pushType: .token`) and writes the per-activity token into
  the notification registration file (additive `live_activity` field, absent
  = fail closed); after the app suspends, the plugin's second
  `pane.agent_status_changed` hook (dual hooks per event verified live on
  herdr 0.8.0) lists agents, coalesces flaps (1.5 s latest-wins claim +
  unchanged-state suppression), and posts update/end. Push-to-start is
  deferred: it succeeds only ~half the time from a killed app (Home
  Assistant's measured experience) and adds token machinery we can bolt on
  later.
- **Priority 5 by default, 10 only for a newly Blocked agent, never an
  `alert` field** — priority-10 pushes burn Apple's hourly budget and alerts
  already belong to the ADR 0008 pipeline. A stale-date of +15 min marks
  abandoned updates; `end` carries an immediate dismissal date.
- **Dead tokens self-heal through APNs 410**: the plugin prunes only the
  `live_activity` field, keeping the device's alert registration intact —
  covering the user dismissing the activity while the app is dead.

## Considered Options

- **Lock-screen widget instead of a Live Activity** — rejected: WidgetKit
  timelines refresh on the system's schedule, minutes to hours late; agent
  status changes in seconds.
- **Pure ciphertext content-state** — rejected above: Watch mirror and
  pre-first-unlock render nothing, and the only production E2EE precedent
  (Teamtailor) ends up decrypting in the app and pushing plaintext anyway.
- **Full plaintext content-state** — rejected: hands agent names, titles, and
  host names to the relay, gutting ADR 0008's disclosure story for a
  convenience the hybrid gets anyway.
- **Push-to-start in v1** — deferred, not rejected: ~50 % from a killed app,
  needs per-type start tokens and a background token round-trip; the local
  start covers the common "was just using the app" case.
- **Broadcast push channels (iOS 18)** — rejected: designed for one event
  watched by thousands; Apple's own guidance sends one-user-one-event traffic
  through device tokens.

## Consequences

- The relay gains its first content-visible bits (counts, event, priority).
  The blast radius of a relay compromise is now "how many agents are in which
  state per push", still never which agent, project, or host.
- Watch Smart Stack and pre-first-unlock lock screens show counts only. An
  accepted rendering floor, not a bug.
- If the app is killed and a new agent starts working, nothing appears until
  the app next runs — the documented cost of deferring push-to-start.
- Apple's liveactivity update budget is opaque; sustained flap storms could
  throttle priority-10 sends. The plugin-side coalescing stack is the
  mitigation; real-device soak is the only true test.
- The `AgentActivityAttributes` type name is shipped-forever (APNs
  `attributes-type` must match if push-to-start ever lands).
- The widget extension becomes a third consumer of the shared Keychain group
  and the second binary compiled from the shared notification sources.
