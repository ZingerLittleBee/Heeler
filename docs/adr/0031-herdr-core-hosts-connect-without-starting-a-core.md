---
status: proposed
---

# herdr-core Hosts bind one Server Kind and connect without starting a core

herdr-core (`hc`) is the vendor's headless terminal runtime. It shares no
Agents with Herdr TUI, has no workspaces, tabs, or plugins, and speaks its own
JSON-RPC 2.0 protocol, which switches to a framed multiplex after
`hello {framed: true}`. Heeler adds herdr-core Hosts, for people who run `hc`
headless or under the Herdr desktop app, beside Herdr TUI Hosts, whose support
stays as it is.

## Decision

- A Host binds one Server Kind. Adding a Host detects which servers the SSH
  target runs, the user confirms one, and the Host stores it. A Pairing Code
  always adds a Herdr TUI Host: its version 2 describes only a Herdr TUI
  endpoint. Neither a connection nor an edit switches a Host to the other
  kind. An SSH target that runs both is added once per kind, as two Hosts.
- Both platforms carry the same byte stream: one
  `hello {generation: 1, framed: true}` line, then frames, which carry
  requests, the events subscription and every live terminal over one channel.
  Unix opens a direct-streamlocal channel to the core's socket, whose path the
  app reads from the core's `core.lock` with a read-only exec. Native Windows
  reads `core.lock` the same way, checks that the named pipe it names exists,
  and only then runs
  `.\AppData\Local\Programs\herdr-core\herdr-core.exe connect --session <s>`
  over SSH exec, because a pipe cannot be forwarded. As in ADR 0018, the
  Windows path is a platform branch, never a fallback. `<s>`, and the
  `core.lock` the app reads on either platform, follow the core session the
  Host stores: hc's `HC_SESSION`, `default` unless the user names another.
- The app requires `hello`'s generation 1 and the features `framed`, `attach`,
  `events` and `status`. A core without them reads as unsupported and the Host
  says to run `hc update` on that machine, as does a request answered with
  `unknown_method`. The version Heeler was tested with is advisory, as for
  Herdr TUI. The app offers no update of its own.
- Connecting never starts a core. A Host with no core running reads as not
  running. On Linux the user may start one with a confirmed action that runs
  `herdr-core server start` through the user's interactive login shell, so
  the core and every Terminal it starts get the environment of the user's own
  terminal; the confirmation says that the start also tries to turn on
  systemd linger for the user. macOS and Windows Hosts only say how to start
  it on that machine: a core started over SSH runs outside the user's desktop
  login session.

## Why

Pins, deep links, Notification Registrations, and retained terminals are keyed
by Host plus an opaque id. One Host serving two inventories would make every
such key ambiguous, and switching kinds on connect or edit would show a broken
core as an empty Herdr TUI inventory, or carry one inventory's keys into the
other.

`herdr-core connect` is what hc's own machine dialer runs, but it starts a core
whenever none is listening, and Unix offers no way to turn that off. Every
Terminal takes the core's environment, not its caller's: `hc run` sends only
terminal identity variables. A core started by the app's minimal SSH exec
would hand that environment to every Agent the user later starts from their
own shell, until the core restarts, and a core the user stopped would come
back on the app's next background reconnect. On macOS that core would also run
outside the user's GUI login session. During research, an `hc` probe from an
agent session started a core that restored a kept Terminal with the agent
session's variables. A direct-streamlocal channel to a socket nobody listens on
simply fails. Windows refuses an SSH start only for an elevated token while the
user has a desktop session, so its `connect` needs the pipe check first.

Framed is not an optimisation. `terminal.attach` refuses a plain connection, so
a plain bridge needs one `hc attach` PTY per live terminal. That CLI viewer
cannot attach as resumed, takes the Terminal's size again on every reconnect,
and consumes its configured detach chord (Ctrl+\ by default) from the user's
input; each one also holds an SSH session slot, which a forwarded channel does
not.

## Evidence

Source-reviewed against herdr-core v0.1.13 (`88fe4e7`). This is source
evidence, not runtime acceptance from the app.

- [cli.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/cli.rs#L808-L809)
  `connect` uses `connect_or_start`;
  [client.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/client.rs#L73-L96)
  spawns a core when nobody listens; Unix
  [`may_autostart`](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/unix.rs#L20-L26)
  never refuses, and `status_may_start_core` is true, so every Unix
  subcommand except `server stop` can start one.
- [client.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/client.rs#L167-L186)
  and [platform/unix.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/unix.rs#L121-L135)
  start the core detached with the caller's environment: `setsid` on macOS, a
  systemd user service on Linux, which
  [tries to turn on linger](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/systemd.rs#L167-L191).
  [api/run.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/run.rs#L211-L235)
  builds each Terminal's environment from the core's own, and
  [cli.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/cli.rs#L386-L390)
  `hc run` passes only `TERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` and
  `COLORTERM`.
- [platform/windows.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/windows.rs#L239-L241)
  and [windows_session.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/windows_session.rs#L13-L27)
  refuse an SSH start only when the token is elevated and the user has a
  desktop session.
- [paths.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/paths.rs#L17-L35)
  and [platform/unix.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/unix.rs#L88-L95)
  resolve the socket from `HC_SOCKET`, else config `socket`, else
  `$XDG_RUNTIME_DIR/herdr-core`, else `/run/user/<uid>/herdr-core` when it
  exists, else the state directory; on Windows the default is
  `\\.\pipe\herdr-core-<user>-<session>.sock`
  ([platform/windows.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/platform/windows.rs#L349-L352)).
  [server.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/server.rs#L19-L31)
  holds `core.lock` under `flock` and writes the socket path it bound into it.
- [api.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api.rs#L378-L385)
  answers `terminal.attach` on a plain connection with `needs_framed`.
- [machines.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/machines.rs#L200-L217)
  dials Windows through the installer path, not PATH.
- [cli.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/cli.rs#L156-L163)
  exits for `--version` while parsing arguments, before any path or
  connection, so `--version` is a safe install probe.
- [server.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/server.rs#L92-L121)
  keeps the core's identity in `core.json` until its state is wiped or the disk
  turns up under another machine id;
  [api.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api.rs#L168-L184)
  returns it as `core` in the `hello` reply, beside the generation and the
  [feature list](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api.rs#L15-L16).
  [paths.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/paths.rs#L83-L84)
  names the session `default` when `HC_SESSION` is unset or blank. The terminal registry, saved in
  `terminals.json`, keeps its `next_id` across restarts
  ([terminals.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/terminals.rs#L202-L208)).

## Considered options

- SSH exec of `herdr-core connect` on every platform, plain JSON-RPC per
  request, with an `hc attach` PTY per live terminal (the shape of PR #538):
  one code path, and exit status 127 names a missing install. Rejected for
  the autostart above, which every request, keepalive and reconnect can
  trigger, and for the CLI viewer's limits.

## Consequences

- Add Host and preflight need a read-only exec probe (`command -v`,
  `--version`, read `core.lock`) to tell not installed, not running, and a
  wrong path apart; a refused channel alone cannot.
- `core.lock` outlives its core. Its stale path refuses the channel and reads
  as not running, never as another core.
- On Windows a core that stops between the pipe check and `connect` is
  started by `connect`; the window is one round trip.
- The state directory follows `XDG_STATE_HOME`. An override set only in an
  interactive shell's rc file is invisible to the probe (unverified).
- The app's `hello` request never carries a `core` field, which would register
  the connection as a peer core
  ([remote.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/remote.rs#L589-L613)).
- A Host's core identity is `core.id` in the `hello` reply. Terminal addresses
  are never reused across core restarts, so a restart keeps Pins; a changed id
  is a different core and drops them.
