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
  reads `core.lock` from its second byte, since a running core holds the first
  under a file lock, restores the leading backslash, checks with PowerShell's
  `Test-Path` that the named pipe it names exists, and only then runs
  `.\AppData\Local\Programs\herdr-core\herdr-core.exe connect --session <s>`
  over SSH exec, because a pipe cannot be forwarded. As in ADR 0018, the
  Windows path is a platform branch, never a fallback. `<s>`, and the
  `core.lock` the app reads on either platform, follow the core session the
  Host stores: hc's `HC_SESSION`, `default` unless the user names another,
  trimmed and refused as hc refuses it. Where no `core.lock` exists yet, the
  app tries the session's default socket path.
- The app requires `hello`'s generation 1 and the features `framed`, `attach`,
  `events` and `status`. A core without them reads as unsupported and the Host
  says to update herdr-core on that machine (`herdr-core update`, by the
  probed path), as does a request answered with `unknown_method`. The version
  Heeler was tested with is advisory, as for Herdr TUI. The app offers no
  update of its own. Errors are told apart by `error.data.kind`, since every
  domain error shares one code.
- Connecting never starts a core. A Host with no core running reads as not
  running. On Linux the user may start one with a confirmed action that runs
  the probed `herdr-core` by its absolute path through the user's interactive
  login shell (`$SHELL -lic`), so the core and every Terminal it starts get the
  environment of the user's own terminal. `HC_SESSION` is set inside the command,
  after the rc files run, so an rc file cannot send the start to another session.
  The confirmation says that the start also tries to turn on systemd linger for
  the user when it is off. macOS and
  Windows Hosts only say how to start it on that machine: a core started over
  SSH runs outside the user's desktop login session.
- The app never runs `hc` by that name. The installer links `hc` only when no
  other program owns the name, so the probe looks for `herdr-core`: on the
  exec's `PATH`, then at the installer's `~/.local/bin/herdr-core`, which a
  plain SSH exec's `PATH` lacks.

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
evidence, not runtime acceptance from the app. The 2026-10-30 live observations
on a Debian 13 VM in [herdr compatibility](../agents/herdr-compatibility.md)
confirm or refine these points with test clients, not the app.

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
  keeps the core's identity in `core.json` until its state is wiped or the
  disk turns up under another machine id;
  [api.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api.rs#L168-L184)
  returns it as `core` in the `hello` reply, beside the generation and the
  [feature
  list](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api.rs#L15-L16).
  [paths.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/paths.rs#L83-L84)
  names the session `default` when `HC_SESSION` is unset or blank. The
  terminal registry, saved in `terminals.json`, keeps its `next_id` across
  restarts
  ([terminals.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/terminals.rs#L202-L208)).

## Considered options

- SSH exec of `herdr-core connect` on every platform, plain JSON-RPC per
  request, with an `hc attach` PTY per live terminal (the shape of PR #538):
  one code path, and exit status 127 names a missing install. Rejected for
  the autostart above, which every request, keepalive and reconnect can
  trigger, and for the CLI viewer's limits.

## Consequences

- An older Heeler build cannot switch a Host either. herdr-core Hosts persist in
  a second defaults catalog of the same shape, which builds before this change
  never read, so such a build can neither show one nor re-save it as Herdr TUI.
  The merged Host order is stored with that catalog; ids it lacks follow in the
  shared catalog's order. A Host found in both loads as herdr-core.
- A Host added by hand stays unconfirmed in the shared catalog until its detail
  confirms a kind, once. An older build reads it as Herdr TUI, so a session name
  only herdr refuses is kept under `unconfirmedSessionName` rather than failing
  that build's catalog decode. Confirming herdr-core writes the herdr-core catalog
  before removing the shared entry, so an interruption reloads as herdr-core.
- Detection is one exec holding the Herdr TUI session read and the locator for the
  typed session. Neither starts a server
  ([observation](../agents/herdr-compatibility.md)). The confirmation offers
  herdr-core with no launch argument, now that a framed attach works.
- Add Host and preflight need a read-only exec probe (`command -v`,
  `--version`, read `core.lock`) to tell not installed, not running, and a
  wrong path apart; a refused channel alone cannot. SSH reports a missing
  socket, a refused one and a forbidden path with the same channel error.
- `core.lock` outlives its core. Its stale path refuses the channel while
  nothing listens there, and reads as not running. A core that does answer
  there, such as one started under another `XDG_STATE_HOME`, is told apart by
  the `core.id` in its `hello` reply.
- A core that dies while it still holds Terminals comes back about three
  seconds later: the core's terminal holder restarts it, with the environment
  of whoever started the first one. The app retries briefly before it shows
  not running or offers Start, and a core can return without anyone
  connecting.
- A start through an interactive shell over an exec without a terminal writes
  job-control warnings, and the user's rc files may print, so the action
  judges by exit status and the last line of output. `server start` against a
  running core changes nothing, which the reported uptime shows: it is compared
  with the time since the app sent the exec, so the two machines' clocks need not
  agree. The action promises the user's environment only for a fresh start. A
  core that has just reported itself running while its channel is still refused
  leaves one of the two causes a socket file names, so the Host says only that the
  SSH server refuses socket forwarding, until the next run of its checks.
- One SSH session's forwarding survives core restarts: each connection is a
  new channel.
- On Windows a core that stops between the pipe check and `connect` is
  started by `connect`; the window is one round trip.
- On Windows `core.lock` is unreadable as a whole while its core runs: a plain
  read fails with a lock violation, an SFTP read at offset 0 fails too, and
  only a read from byte 1 returns the path. A stopped core's file reads whole
  and stays, so the file's presence says nothing about a running core and the
  pipe does ([observation](../agents/herdr-compatibility.md)). `Test-Path`,
  `[IO.File]::Exists` and a `GetFiles` listing told the two states apart;
  `cmd /c if exist` and Node's `fs.existsSync` said no in both. The Windows
  probe (#587) therefore cannot read the file as Unix does, and must name
  `powershell.exe`, since an exec on a default server runs under `cmd.exe`.
  Over a real SSH exec with the core running, those reads and the one-line
  guard behave the same on the one machine tried, and `type` on the locked file
  exits 0 with its error on stderr, so an exit code alone says nothing there.
- Across one Windows OpenSSH exec of `connect` from a Mac, no byte changed in
  either direction ([observation](../agents/herdr-compatibility.md)): a raw
  control program returned every byte value and 8 MiB unchanged, request and
  reply lengths each covered all 256 low byte values (0x0A, 0x0D and 0x1A among
  them), and frames carried to and from a Terminal matched the local capture
  and a client on the pipe. That is one machine, Windows PowerShell 5.1 and an
  elevated SSH token. What a Terminal's program reads and prints still changes
  past the link (0x00 in, lone bytes of 0x80 or above, a bare LF), as it did
  locally.
- **Unverified, and it blocks calling #587's link proven for the normal case:**
  whether the pipe of a core started at medium integrity admits an elevated SSH
  token. In that round the core's own token read elevated, so the only entry
  observed is elevated client on elevated core, on a pipe labelled High. By
  source (`pipe_security`, v0.1.16) a core that is not elevated labels its pipe
  medium with the same account in the DACL, which should admit a High client of
  that account, but no run shows it. Conversely, a core started elevated is
  out of reach of a normal desktop client, by that source. Before #587 relies on
  this, the owner starts the check's core from a window that is confirmed not
  elevated and the connect is repeated. A stopped core has also not been read
  through sshd.
- A viewer granting credit for every frame can still get a repaint instead of
  the bytes: a program writing about 6 MiB at once reached the Mac end as
  2,196,107 bytes with gaps, and a client on the pipe got all of it. #587's
  attach must treat that repaint as ordinary, not as a broken link. What limited
  the viewer was not separated from the lab client.
- A guard or probe run from the same client must not share the connection's
  stdin: `ssh` reads it, and one run lost `hello` that way.
- The state directory follows `XDG_STATE_HOME`. An override set only in an
  interactive shell's rc file is invisible to the probe, and a core started
  under it has another `core.id` behind the same socket path.
- The app's `hello` request never carries a `core` field, which would register
  the connection as a peer core
  ([remote.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/remote.rs#L589-L613)).
- A Host's core identity is `core.id` in the `hello` reply. Terminal addresses
  are never reused across core restarts, so a restart keeps Pins; a changed id
  is a different core and drops them.
- An address means another Terminal on another core, so nothing crosses from one
  to the next. A snapshot takes its id from its own link's `hello`. A link that
  reopens onto another id refuses anything an older inventory addressed, with
  nothing sent, until that core's snapshot arrives. An open terminal stays on the
  core it first joined and ends there, and opening the address again starts fresh.
  That snapshot only mends what acts on fresh inventory, as a Console row does. A
  detail keeps to the core whose row it opened on, by a `TerminalCorePin` its
  Composer session holds, so once the Host serves another core everything the
  detail sends by address is refused with nothing sent, for good: Close of an
  Agent or a Shell Terminal, a Worktree's removal, Composer Send and Stop, and
  Chat's Send, Stop, keys and Blocked answers. Chat, which goes on to the
  address's new Agent, gives way in that detail to its ended terminal, which says
  the core is gone. The pin belongs to the window's selection, not to the detail's
  views (`ConsoleDetailCores`): a detail rebuilt by a reconnect's placeholder, a
  list tab's return or a size-class change is still the one opened on the old core.
  Leaving it, or picking the row at its address, opens the new core's Terminal. So
  that pick works beside the list, the list stops marking that row as selected.
