# Heeler

Native iOS companion app for herdr (https://herdr.dev): an agent console over SSH, not a terminal app. Read `CONTEXT.md` for vocabulary and `docs/adr/` before challenging architecture decisions — the transport design in particular was reached after eliminating several dead ends.

## Architecture

- **Stack**: SwiftUI, iOS 18+, iPhone + iPad. SSH via the repository-local `Packages/HeelerSSH` (libssh2 + OpenSSL), terminal rendering via the pinned libghostty-spm `GhosttyTerminal` product. See ADR 0001 (native stack), ADR 0003 (the superseded Dictation-era target raise), and ADR 0004 (terminal engine).
- **Transport**: herdr's JSON API (NDJSON over a remote Unix socket) reached through OpenSSH direct-streamlocal channels onto the socket itself — no socat, and no Host-side prerequisite beyond SSH access and a running herdr. A server that denies stream-local forwarding fails preflight rather than falling back. Interactive terminals request a PTY and exec `herdr agent attach` on it. See ADR 0011, which supersedes ADR 0002.
- The UI layer must depend on a transport abstraction (protocol), never on an SSH library's types directly.
- Sibling deliverables live in this repo: `plugin/` is the herdr plugin that renders Pairing Codes and posts Agent Notifications (Node, zero framework, `npm test`); `relay/` is the stateless Push Relay it posts to (dependency-free Node, `npm test`). Wire types in `Sources/Heeler/Transport/Generated/` are produced by `scripts/generate-wire-types.py` from the committed schema snapshot `scripts/herdr-schema.json` — regenerate rather than hand-edit; CI fails on drift. The vectors in `plugin/test-vectors/` are consumed by both the Node and Swift suites so the two implementations cannot drift; change them in lockstep.

## Load-bearing herdr facts

Rediscovering these is expensive. Each fact names the herdr version it was verified against; a fact **not** marked 0.8.0 has not been re-tested since its stated version, so treat its version label as its expiry date rather than assuming it still holds.

- The herdr API socket serves **one request per connection** (read one line, write one line, close). Only `events.subscribe` keeps the connection open. Plan channel usage accordingly. (Re-verified live on 0.8.0: a second write on a served connection gets `EPIPE`. `pane.graphics.stream`, previously listed here, does not exist in the 0.8.0 schema — graphics methods are `pane.graphics.set`/`clear`/`info`, all one-shot.)
- Wire format: request `{"id": "<any string>", "method": "...", "params": {...}}` + `\n`; `params` is required, and `{}` satisfies it. Success `{"id", "result"}`, failure `{"id", "error": {"code", "message"}}` (both re-verified live on 0.8.0), subscription event lines `{"event", "data"}` with no id.
- The first message on any new connection path should be `ping` — it returns the server protocol version (0.8.0 answers `{"version":"0.8.0","protocol":19,...}`, verified live). herdr's API has no stability guarantee; parse leniently (ignore unknown fields). The app enforces a **floor**, not equality: `HeelerSSHTransport.minimumProtocolVersion` refuses older servers, `generatedProtocolVersion` only drives an advisory notice. Equality here made every 0.8.0 Host unusable (#140) — do not restore it.
- The API schema is exported offline via `herdr api schema --json` (JSON Schema 2020-12). Its `$ref` paths are non-standard nested (`#/schemas/request/$defs/X`) — preprocess before feeding codegen tools. The committed 0.8.0 snapshot declares 90 request methods and 26 event kinds, and every one of those kinds has a typed `EventData` variant; separately, 3 pane-scoped kinds (`pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed`) have typed `SubscriptionEventData`. Payloads herdr actually emits are still worth verifying empirically.
- SSH exec channels are session channels, capped by sshd's `MaxSessions` (default 10) per connection. All RPC traffic must go through a request queue that bounds concurrency.
- `herdr agent attach` requires a TTY (ratatui). It works over an exec channel only when a PTY is requested.
- herdr 0.7.5 tightened `agent.start` (verified against a live 0.7.5 server): the kind must be on its supported-agent list (arbitrary commands like `bash -i` are rejected with `unsupported interactive agent kind`), and a freshly created pane is rejected with `agent_pane_busy` ("not an available shell") until its shell reaches the interactive prompt — a few seconds. The transport retries on that code; see `SSHTransport.startAgentAwaitingShell`. On 0.8.0 `agent.start` is asynchronous instead: it returns `launch_pending: true` immediately (verified live 6ms after pane creation) and `agent_pane_busy` no longer occurs — the retry path stays as harmless 0.7.5 compat.
- Default remote socket: `~/.config/herdr/herdr.sock` (still the path a live 0.8.0 server serves); named sessions live under `~/.config/herdr/sessions/<name>/herdr.sock` (not re-tested on 0.8.0). Resolve `$HOME` over exec once per host.
- If the herdr server is not running, connecting to the socket fails outright; there is no auto-start on the socket path. Fallback: run a herdr CLI command over exec (verify auto-spawn behavior — open question).
- `herdr agent attach` resolves its target against **agents only**: attaching a plain shell pane fails with `agent_not_found` (verified against a live 0.7.5 server). Shell panes cannot reuse the attach terminal path; interacting with them over the API means `pane.send_text`/`pane.send_keys` plus `pane.read`. Note `pane_output_changed` is emitted but **not subscribable** (0.8.0: the one emitted kind missing from the `Subscription` oneOf), so there is no output-change push — see the read/refresh facts below.
- `pane.send_text` types into any pane's PTY; a trailing `\n` presses Enter and the shell executes the line (verified live). `tab.create`/`workspace.create` accept `cwd`, `env`, and `label`, and `workspace.create` already returns a root pane running the user's shell — a plain terminal pane needs no `agent.start`.
- Reading pane content, verified live on 0.8.0: `pane.read`/`agent.read` take `source: visible|recent|recent_unwrapped` plus `lines` — **no offset or cursor**, so remote history is not addressable. `recent` defaults to 80 lines; the server caps every read at **1000 lines**. For alternate-screen TUIs (claude), history is capturable **only while the agent is idle**: `agent.read` fails `agent_not_idle` while working, and `pane.read` silently degrades to the visible screen while reporting `truncated: false` — use `agent.read` whenever depth matters. `read.revision` is always 0, never a change signal. The text lives at `result.read.text` (nested), not top-level.
- Output-change signals, verified live on 0.8.0: `pane.output_matched` is edge-triggered — one push when the visible buffer's match predicate flips no-match→match (plus one at subscribe time if already matching), silence during sustained output — useless as a change feed. `pane.agent_status_changed` is the precise push signal (two ~125-byte events per prompt round trip). `pane.updated` remains a ~4/s noise source. `events.wait` implements only pane agent-status matches despite the schema declaring 19 `EventMatch` variants, and its param is `match_event` (a single object).
- `agent.prompt`, verified live on 0.8.0: types the text **and Enter** (auto-submits); without `wait` it returns `agent_prompted` immediately — a delivery ack, nothing more. `wait.until` must include `done`: claude finishes on `done`, not `idle`, so idle-only waits reliably time out. Prompting a **working** agent is accepted unconditionally; queueing happens inside the agent TUI (verified for claude), not in herdr. `target` accepts pane ids and agent names, not agent-session UUIDs.
- `pane.send_input {pane_id, text?, keys?}` (verified live on 0.8.0) inserts without submitting when `keys` is omitted; `{text, keys: ["enter"]}` is an atomic type-and-submit. Key-name parsing is shared with `send_keys` and laxer than 0.7.4: `enter`/`esc`/`ctrl+c`/`C-c` accepted case-insensitively, `ctrl-c` still rejected with `invalid_key`.
- Malformed requests are answered with `id: ""` instead of the request id (verified live on 0.8.0) — id-keyed response matching needs a fallback or such requests pend forever. `ping` on 0.8.0 also reports `capabilities` (`live_handoff`, `detached_server_daemon`).
- Starting claude in a cwd absent from `~/.claude.json` blocks on an in-TUI trust dialog herdr cannot dismiss (hit live on 0.8.0) — a fresh-directory agent launch can wedge before its first prompt.
- Rename methods, verified against a live 0.7.5 server: `agent.rename` enforces `^[a-z][a-z0-9_-]{0,31}$` (`invalid_agent_name` otherwise) and clears the custom name when `name` is null or omitted; `workspace.rename` accepts **any** label (empty, whitespace, 500 chars). The `pane_updated` event a rename fires does **not** carry the agent name, and `pane.updated` fires on every terminal-title change (34 events in 6s measured live) — do not use it as a resync trigger; renames surface via post-RPC resync instead.
- herdr 0.7.5 **replays recently buffered events on `events.subscribe`** (verified live; 0.7.4 replayed nothing). Still no state replay — initial sync stays snapshot-based; treat replayed events as ordinary change signals.
- `events.subscribe` is **all-or-nothing**: one pane-scoped entry naming a dead pane fails the entire request with `pane_not_found` (re-verified live on 0.8.0, including alongside a valid global entry; the error id is `<requestID>:sub:<index>:probe`, so it does not correlate with the request id). Pane-scoped subscriptions are snapshot-derived and must never outlive the connection they were taken on, or a single exited pane wedges the Host offline forever — see `EventsSession.dropPaneSubscriptions`.
- `herdr remote-client-bridge` bridges stdin/stdout to the **client socket** (the TUI client/server protocol for `herdr --remote`), not the API socket — verified against herdr 0.7.5 source (`src/remote/unix.rs`, `run_remote_client_bridge`); no API-socket stdio bridge exists in 0.7.5. Its "ensure server running" side effect is why it works as the wake command.

## Conventions

- Build, test, device installs, and TestFlight uploads all go through `make` (see `make help`). An interim TestFlight build is `make bump && make testflight` — App Store Connect rejects reused build numbers.
- Cutting a release is `make publish` (`scripts/publish.sh`, documented in `docs/guides/releasing.md`): it cuts `CHANGELOG.md`'s `[Unreleased]`, bumps `MARKETING_VERSION` in `project.yml`, builds and uploads to TestFlight, then tags and creates the GitHub release. `CHANGELOG.md` is the source of both the version and the notes; never hand-edit `MARKETING_VERSION` or create a `vX.Y.Z` tag by hand. Preview with `make publish DRY_RUN=1`.
- A single suite runs with `xcodebuild test -project Heeler.xcodeproj -scheme Heeler -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:HeelerTests/<SuiteTypeName>`; `make test` runs everything.
- CI (`.github/workflows/ci.yml`) builds the committed `Heeler.xcodeproj` and never runs xcodegen, so commit the regenerated project alongside any `project.yml` change (every `make` build target regenerates it). `scripts/run-ci-ios-tests.sh` provisions disposable sshd instances and asserts executed test counts for the mandatory real-SSH suites; the remaining locally-gated suites skip cleanly on machines without a local sshd and seeded key.

- Swift 6 strict concurrency. No force unwraps or `try!` outside tests.
- Private keys never leave the Keychain and are generated on device (CryptoKit Ed25519) where possible. Per-Host Notification Keys are symmetric keys: the app retains each one in the shared Keychain and copies it over SSH to that Host so the plugin can encrypt notifications. Host key policy is TOFU with fingerprint confirmation.
- Pin libssh2 and OpenSSL exactly in `Packages/HeelerSSH` and review both the source hashes and the committed XCFramework checksums before updating; normal builds consume the checked-in artifacts.
- Pin libghostty-spm exactly and review both its Swift sources and prebuilt XCFramework checksum before updating.
- Tracker is GitHub issues in this repo (`gh issue ...`). Reference issues from commits with `refs #<n>`.
- User-visible changes get a `CHANGELOG.md` entry under Unreleased, referencing the PR; internal refactors and test work stay out of it.
- Update `CONTEXT.md` when domain terms change; add an ADR only for hard-to-reverse, surprising trade-offs.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to repo labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
