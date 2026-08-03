---
status: superseded by ADR-0011
---

# Transport: herdr JSON API over SSH exec + socat, no herdr changes

The app reaches herdr's JSON API (NDJSON over a Unix domain socket, one request per connection) by opening a no-PTY SSH exec channel running `socat - UNIX-CONNECT:<sock>` per request, plus one long-lived channel for `events.subscribe`. Interactive terminals use a separate SSH PTY shell channel. Citadel 0.12.1 cannot combine a PTY request with an exec request, so the app writes an injection-safe `exec herdr agent attach <pane>` bootstrap line into that shell; `exec` replaces the shell, making the resulting channel mechanically equivalent to a PTY exec channel for lifecycle and byte streaming. We deliberately require `socat` on every host and change nothing in herdr.

## Locating socat

Execution always uses an absolute path: relying on the login shell to resolve
`socat` on every exec would make each request depend on that shell's PATH, which
differs between interactive and non-interactive invocations. That constraint says
nothing about who must *supply* the path, so the app discovers it once per
connection and caches it: the Host's configured path first, then `command -v
socat` on the Host. Whatever it settles on is absolute, so PATH is consulted at
most once and never participates in an exchange.

There is deliberately no built-in list of package-manager prefixes to fall back
through. Such a list is a bet on specific distro and Homebrew layouts that rots
with every packaging change, and it can only ever name locations that are already
on PATH. A Host where discovery fails keeps the editable per-Host path as its
escape hatch, and the socat preflight hint names the usual Homebrew locations to
type in.

Discovery replaces the previous scheme, which inferred socat's absence by
matching its configured path against login-shell stderr. That test cannot tell
"not installed" apart from "installed but not executable" (no execute
permission, a missing shared library, a noexec mount), and it misreported the
latter as the former — sending the user to fix the one thing that was already
right. `[ -x ]` on the Host answers the question directly, so
`classifyExecFailure` no longer classifies socat at all.

## Considered Options

- **SSH direct-streamlocal forwarding (the "obvious" answer)** — impossible in Swift: swift-nio-ssh's channel type is a closed enum (session / directTCPIP / forwardedTCPIP) with no extension point, so Citadel inherits the gap. Every workaround was evaluated and rejected: forking swift-nio-ssh (~150 lines but a permanent security-sensitive fork), libssh (LGPL, no iOS packaging), russh via UniFFI or Go x/crypto via gomobile (a whole foreign toolchain for one channel type). Since herdr serves one request per connection anyway, streamlocal would only save the remote process spawn (~tens of ms per request) — not worth any of those costs.
- **Upstream `herdr api stdio` bridge** — a ~25-line twin of herdr's existing `remote-client-bridge` would remove the socat prerequisite. Deliberately not pursued: the owner decided against depending on upstream contributions.
- **Per-request herdr CLI over exec** (`herdr agent list` etc.) — works today and remains the bootstrap/fallback path, but covers only CLI-exposed methods and has no streaming.
- **herdr loopback TCP listener** — would downgrade herdr's security model (Unix socket 0600 → any local user), requires an auth design that is not ours to make.

## Consequences

- Every host needs `socat` installed. Onboarding finds it on its own where it can, and explains how to install it or where to point the app when it cannot.
- Discovery spends one exec channel per connection, once, from the same bounded queue as the other short remote commands.
- Exec channels are session channels: sshd's `MaxSessions` (default 10) caps concurrency, so all RPCs go through a bounding request queue.
- Real-time events work today (`events.subscribe` on a dedicated channel); no polling needed while foregrounded.
- If the Flutter Plan B is ever activated, dartssh2's `forwardLocalUnix` makes socat unnecessary — this ADR is stack-specific.
