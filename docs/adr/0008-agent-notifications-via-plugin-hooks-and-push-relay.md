# Deliver Agent Notifications through plugin event hooks and a stateless push relay

Agent Notifications only earn their keep if they arrive while the app is backgrounded or killed — exactly when iOS suspends the process and its SSH connections, so `events.subscribe` cannot carry them. The only reliable background channel on iOS is APNs, pushing to our bundle requires the developer's APNs auth key, and end users cannot be asked to provision Apple certificates. We decided on this pipeline: a herdr plugin `[[events]]` hook on `pane.agent_status_changed` (hookable since plugin v1; verified in herdr source, `PLUGIN_HOOK_EVENT_KINDS`) runs a short-lived notify script, which encrypts the payload with the per-host Notification Key and POSTs it to a developer-hosted stateless Push Relay; the relay holds the `.p8`, signs the APNs JWT, and forwards the ciphertext to Apple. No long-running watcher, no user-side certificate work.

Decisions fixed during design:

- **Triggers**: Blocked and Done transitions notify (Done individually togglable in settings); Working/Idle transitions never do. `pane.exited` (agent died) is hookable and deferred, not rejected. (ADR 0014 later relaxes the Working/Idle rule for the separate Live Activity path only — alert notifications keep this trigger table.)
- **Anti-noise**: herdr's status detection is heuristic and can flap, so the hook script waits ~5 s and re-checks the status via `HERDR_BIN_PATH` before sending; same-status repeats are deduped through `HERDR_PLUGIN_STATE_DIR`; the app suppresses the banner when the user is foregrounded on that Agent.
- **Foreground banners** (amended by #77, decided during on-device testing): while the app is foregrounded, system push banners are fully silenced (`willPresent` returns `[]`) and Blocked/Done transitions are announced by an in-app banner driven by the app's own live event stream — near-zero latency, no plugin debounce. The in-app path mirrors the plugin's gates app-side: hold-before-announce, same-status dedupe per pane, presented-Agent suppression, and fail-closed preference checks. Background/killed delivery stays APNs, unchanged.
- **Notification Registration**: the app writes its push token and a freshly generated Notification Key to a file on the Host over the existing SSH channel. The matching Notification Key remains in the device Keychain so the extension can decrypt; the Host holds the token and its copy of the key so the plugin can encrypt. The relay holds neither persistently. Multi-device fanout is edge-side: the token file holds N tokens, the plugin POSTs once per token.
- **Relay shape**: one `POST /push` endpoint, no accounts, no database, no queue, no retries (the plugin retries). Per-IP/per-token rate limits and the APNs 4 KB payload cap from day one. APNs `410 Unregistered` is relayed back so the plugin prunes dead tokens. If abuse appears, the upgrade path is stateless signed grants minted at registration time — still no database.
- **Trust story**: the relay is open source, and both app and plugin accept a custom relay URL. A custom relay is only useful to people who build the app from source with their own bundle ID and APNs credentials — the docs must say so. User-facing disclosure has three layers: a plain-language explainer before the iOS permission prompt, a persistent settings entry, and a `PRIVACY.md` listing what the relay observes (device token, ciphertext, source IP, request timing and frequency) and why it cannot read the content.

## Considered Options

- **Foreground-only local notifications** — rejected: when the user is staring at the Console they can already see the status; the feature's value is precisely the backgrounded case.
- **Plugin holds the APNs `.p8` directly** — rejected: users cannot obtain keys for our bundle ID, and shipping ours inside a public plugin repo publishes it. Obfuscation is not custody.
- **Third-party push apps (ntfy, Bark official)** — rejected: notifications pop from a foreign app with no deep link into the Agent, and users must install and configure a second app.
- **Long-running watcher process on the Host** — unnecessary: `[[events]]` hooks fire a command per event with `HERDR_PLUGIN_EVENT_JSON`, so there is no daemon lifecycle to install, supervise, or explain.
- **Stateful relay (token directory, accounts, delivery queue)** — rejected: pushing state to the two ends keeps the relay a dumb pipe whose compromise yields ciphertext and tokens, nothing else, and keeps its operation near zero-cost.

## Consequences

- The relay is a single point of failure for notifications only: while it is down, notifications drop silently; Console and Attach are untouched because they never talk to it.
- The feature costs the developer a paid Apple Developer membership and one deployed Worker-class service; users pay nothing and configure nothing beyond `herdr plugin install`.
- The push endpoint is public. Residual risk is quota-burning traffic and junk pushes to a leaked token — and leaking a token requires compromising the Host it is stored on. iOS will not let the service extension fully suppress an alert push, so forged ciphertext degrades to a generic fallback banner, not silence.
- The encrypted payload format between app and plugin is a cross-implementation contract like the pairing envelope: changes require a version bump honored on both ends.
- The notify hook pins the plugin's `min_herdr_version`; hookable-event changes in herdr become an upgrade dependency for notifications, as with pairing.
