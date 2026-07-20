# Transport: herdr JSON API over SSH exec + socat, no herdr changes

The app reaches herdr's JSON API (NDJSON over a Unix domain socket, one request per connection) by opening a no-PTY SSH exec channel running `socat - UNIX-CONNECT:<sock>` per request, plus one long-lived channel for `events.subscribe`. Interactive terminals use a separate SSH PTY shell channel. Citadel 0.12.1 cannot combine a PTY request with an exec request, so the app writes an injection-safe `exec herdr agent attach <pane>` bootstrap line into that shell; `exec` replaces the shell, making the resulting channel mechanically equivalent to a PTY exec channel for lifecycle and byte streaming. We deliberately require `socat` on every host and change nothing in herdr.

## Considered Options

- **SSH direct-streamlocal forwarding (the "obvious" answer)** — impossible in Swift: swift-nio-ssh's channel type is a closed enum (session / directTCPIP / forwardedTCPIP) with no extension point, so Citadel inherits the gap. Every workaround was evaluated and rejected: forking swift-nio-ssh (~150 lines but a permanent security-sensitive fork), libssh (LGPL, no iOS packaging), russh via UniFFI or Go x/crypto via gomobile (a whole foreign toolchain for one channel type). Since herdr serves one request per connection anyway, streamlocal would only save the remote process spawn (~tens of ms per request) — not worth any of those costs.
- **Upstream `herdr api stdio` bridge** — a ~25-line twin of herdr's existing `remote-client-bridge` would remove the socat prerequisite. Deliberately not pursued: the owner decided against depending on upstream contributions.
- **Per-request herdr CLI over exec** (`herdr agent list` etc.) — works today and remains the bootstrap/fallback path, but covers only CLI-exposed methods and has no streaming.
- **herdr loopback TCP listener** — would downgrade herdr's security model (Unix socket 0600 → any local user), requires an auth design that is not ours to make.

## Consequences

- Every host needs `socat` installed; onboarding must check for it and explain.
- Exec channels are session channels: sshd's `MaxSessions` (default 10) caps concurrency, so all RPCs go through a bounding request queue.
- Real-time events work today (`events.subscribe` on a dedicated channel); no polling needed while foregrounded.
- If the Flutter Plan B is ever activated, dartssh2's `forwardLocalUnix` makes socat unnecessary — this ADR is stack-specific.
