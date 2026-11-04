---
status: accepted
---

# The plugin collects Agent usage on the Host

Heeler shows Usage Limits and Token Usage for Claude Code and Codex. The data
lives on the Host: Transcripts that can run to gigabytes, and sign-in
credentials that only the programs themselves should hold. Users configure
their status lines differently, and most have no usage tool installed.

## Decision

The Heeler herdr plugin computes both on the Host and the app reads a small
JSON document from it with one bounded SSH exec per query
([design](../design/agent-usage.md)).

- The app runs `node <plugin_root>/src/usage-query.js` through
  `runBoundedScript`. The plugin's startup and `pane.agent_status_changed`
  hooks write a `runtime.json` from herdr's environment: the `node`, `codex`
  and `claude` to run, herdr's `PATH`, `HOME` and `USER` (for Claude Code's
  macOS keychain account), the variables that locate the Agents' data roots,
  the proxy and CA variables (`HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` and
  `NO_PROXY` in both cases, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`,
  `SSL_CERT_DIR`, `CODEX_CA_CERTIFICATE`) that Usage Limits requests need on
  some networks, and `HERDR_PLUGIN_STATE_DIR`. A proxy URL can embed
  credentials, so the file is private (0600). The cache lives
  under that directory in a subdirectory keyed by the Transcript roots that
  environment names, whether or not they exist yet, so instances share a
  cache when they read the same Transcripts. Without the file the query asks
  the user to use any Agent once or restart herdr instead of guessing.
  No SFTP, no listening port, no herdr plugin action.
- The query never blocks on work. It returns the cached snapshot and spawns a
  single detached worker that scans Transcripts incrementally and reads Usage
  Limits.
- The plugin never reads a credential. Usage Limits come from the programs
  themselves, which own their sign-in and its refresh: Codex's `app-server`
  (`account/rateLimits/read`) and Claude Code's stream-json `get_usage`
  control request. Claude Code limits are opt-in per Host, because
  `get_usage` is undocumented and the use is automated use of the
  subscription.
- The plugin keeps no history of its own. Token Usage covers at most 30 days,
  bounded by the Transcripts still on the Host, and its cache can always be
  rebuilt from them.
- Prices come from a bundled, versioned table; nothing is fetched at runtime
  for Token Usage.

## Considered Options

- **Read Transcripts from the app over SFTP**: rejected. It moves gigabytes
  over the user's mobile link, and the app would repeat the deduplication on
  every device.
- **Require an existing usage CLI on the Host**: rejected. Users don't have
  one, and pinning someone else's output format makes it a wire contract.
- **Read the program's status line output**: rejected. Every user configures
  it differently, and it only reports while a session runs.
- **`plugin.action.invoke`**: rejected. It is asynchronous, so stdout is only
  available by polling capped logs, and the action would appear in every
  user's herdr palette.
- **A startup-hook poller**: rejected. One would run per herdr session, and it
  would call the services when nobody is looking.
- **Copy credentials to the device and call the services from iOS**:
  rejected. It moves secrets off the Host and is what Anthropic's terms
  forbid most clearly.
- **Read Claude Code's stored OAuth token on the Host and call
  `/api/oauth/usage`**: rejected. Claude Code's legal page says developers
  "may not collect, store, or intermediate Claude.ai credentials or session
  tokens"; the keychain service name gains a hash suffix under
  `CLAUDE_CONFIG_DIR` and a plaintext fallback file can be stale; and a
  community report says requests without Claude Code's User-Agent keep
  getting 429, while sending it would breach the Usage Policy's ban on
  misrepresenting "the product or client being used". Claude Code's own
  `get_usage` answers the same question without the plugin touching the
  token.
- **Restart herdr to record the runtime**: rejected as the only path. herdr
  runs startup hooks only at server start and live handoff, never on plugin
  install or update, and a restart ends every pane. The status-change hook
  runs in the same environment, so the first Agent activity records it.
- **Persist long-term history in the plugin**: rejected for scope. Thirty
  days, as long as the Transcripts last, is enough, and a cache that is never
  authoritative can always be deleted safely.

## Consequences

- The usage contract (`usage` v1, shared vector in `plugin/test-vectors/`) is
  a cross-implementation contract. Changing it means a version bump honored
  by both the plugin and the app.
- The feature needs the plugin and Node.js on the Host, so it is unavailable
  on native Windows Hosts.
- The plugin, not herdr, becomes the owner of how Claude Code and Codex
  records are counted. Changes in either program's Transcript format become
  plugin updates. Codex is counted from its per-response
  `token_usage_record` (0.153.0 and later) with `token_count` as the
  fallback for older files. Codex writes no usage for background remote
  compaction, so that usage is not counted.
- Codex compresses cold rollouts to `.jsonl.zst` (most of the last 30 days
  on one development machine), so complete Codex totals need Node 22.15.0
  or 23.8.0 and later, or `zstd` on herdr's `PATH`; otherwise the app reports
  how many archives were skipped.
- Claude Code Usage Limits depend on an undocumented control request and on
  launching the user's `claude` headless with hooks and MCP servers off;
  either can change with a Claude Code release.
- This deviates from the Transcript being read only by the app: the plugin now
  reads Transcripts on the Host as well, still read-only.
- The plugin itself never writes Transcripts, but starting `codex app-server`
  for Usage Limits runs Codex's own startup maintenance where the user's Codex
  enables it (migrating legacy rollouts and compressing cold ones to
  `.jsonl.zst`), as any Codex start does. The Transcript scan handles both.
