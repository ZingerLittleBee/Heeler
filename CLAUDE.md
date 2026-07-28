# herdr-mobile

Native iOS companion app for herdr (https://herdr.dev): an agent console over SSH, not a terminal app. Read `CONTEXT.md` for vocabulary and `docs/adr/` before challenging architecture decisions — the transport design in particular was reached after eliminating several dead ends.

## Architecture

- **Stack**: SwiftUI, iOS 26+, iPhone + iPad. SSH via Citadel, terminal rendering via the pinned libghostty-spm `GhosttyTerminal` product. See ADR 0001 (native stack), ADR 0003 (iOS 26 target raise), and ADR 0004 (terminal engine).
- **Transport**: herdr's JSON API (NDJSON over a remote Unix socket) reached through SSH exec channels running `socat - UNIX-CONNECT:<sock>`. The remote socat path is discovered once per connection (Host's configured path, then `command -v`) and always executed absolute. Interactive terminals use a PTY exec channel running `herdr agent attach`. See ADR 0002.
- The UI layer must depend on a transport abstraction (protocol), never on Citadel types directly.

## Load-bearing herdr facts

Rediscovering these is expensive; they were verified against herdr 0.7.4 source and a live server:

- The herdr API socket serves **one request per connection** (read one line, write one line, close). Only `events.subscribe` and `pane.graphics.stream` keep the connection open. Plan channel usage accordingly.
- Wire format: request `{"id": "<any string>", "method": "...", "params": {...}}` + `\n`. Success `{"id", "result"}`, failure `{"id", "error": {"code", "message"}}`, subscription event lines `{"event", "data"}` with no id.
- The first message on any new connection path should be `ping` — it returns the server protocol version. herdr's API has no stability guarantee; parse leniently (ignore unknown fields) and surface version mismatches.
- The API schema is exported offline via `herdr api schema --json` (JSON Schema 2020-12, ~85 methods). Its `$ref` paths are non-standard nested (`#/schemas/request/$defs/X`) — preprocess before feeding codegen tools. 26 event kinds are subscribable but only 3 have typed payloads; verify others empirically.
- SSH exec channels are session channels, capped by sshd's `MaxSessions` (default 10) per connection. All RPC traffic must go through a request queue that bounds concurrency.
- `herdr agent attach` requires a TTY (ratatui). It works over an exec channel only when a PTY is requested.
- herdr 0.7.5 tightened `agent.start` (verified against a live 0.7.5 server): the kind must be on its supported-agent list (arbitrary commands like `bash -i` are rejected with `unsupported interactive agent kind`), and a freshly created pane is rejected with `agent_pane_busy` ("not an available shell") until its shell reaches the interactive prompt — a few seconds. The transport retries on that code; see `SSHTransport.startAgentAwaitingShell`.
- Default remote socket: `~/.config/herdr/herdr.sock`; named sessions live under `~/.config/herdr/sessions/<name>/herdr.sock`. Resolve `$HOME` over exec once per host.
- If the herdr server is not running, connecting to the socket fails outright; there is no auto-start on the socket path. Fallback: run a herdr CLI command over exec (verify auto-spawn behavior — open question).
- `herdr agent attach` resolves its target against **agents only**: attaching a plain shell pane fails with `agent_not_found` (verified against a live 0.7.5 server). Shell panes cannot reuse the attach terminal path; interacting with them over the API means `pane.send_text`/`pane.send_keys` plus `pane.read`, with the subscribable `pane_output_changed` event as the change signal.
- `pane.send_text` types into any pane's PTY; a trailing `\n` presses Enter and the shell executes the line (verified live). `tab.create`/`workspace.create` accept `cwd`, `env`, and `label`, and `workspace.create` already returns a root pane running the user's shell — a plain terminal pane needs no `agent.start`.
- `workspace.rename`, verified against a live 0.7.5 server, accepts any label
  (empty, whitespace, 500 chars). The app withholds empty labels because a
  blank Console grouping label is not useful.
- herdr 0.7.5 **replays recently buffered events on `events.subscribe`** (verified live; 0.7.4 replayed nothing). Still no state replay — initial sync stays snapshot-based; treat replayed events as ordinary change signals.
- `herdr remote-client-bridge` bridges stdin/stdout to the **client socket** (the TUI client/server protocol for `herdr --remote`), not the API socket — verified against herdr 0.7.5 source (`src/remote/unix.rs`, `run_remote_client_bridge`). It cannot replace socat for API traffic; no API-socket stdio bridge exists in 0.7.5. Its "ensure server running" side effect is why it works as the wake command.

## Conventions

- Build, test, device installs, and TestFlight uploads all go through `make` (see `make help`). A new TestFlight build is `make bump && make testflight` — App Store Connect rejects reused build numbers.

- Swift 6 strict concurrency. No force unwraps or `try!` outside tests.
- Secrets never leave the Keychain; private keys are generated on device (CryptoKit Ed25519) where possible. Host key policy is TOFU with fingerprint confirmation.
- Pin Citadel exactly in `Package.resolved` and review updates: Citadel 0.12.1 depends on a third-party fork of swift-nio-ssh (Wellz26), not Apple's repo.
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
