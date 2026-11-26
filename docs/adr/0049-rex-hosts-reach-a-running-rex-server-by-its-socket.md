---
status: proposed
---

# Rex Hosts reach a running Rex server by its socket

Rex is a terminal multiplexer with a server of its own, on macOS and Linux.
People who keep their terminals in Rex want to watch and type into them from
Heeler, as they do with Herdr TUI, herdr-core and tmux. Rex is none of those: it
shares no Agents with them, has no Heeler plugin or Host Helper, and reports no
Program Status Heeler reads. Heeler adds Rex as a fourth Server Kind, first as
an experiment that ships switched off.

Amended by [ADR 0054](0054-rex-terminals-running-a-known-agent-are-agents.md):
Rex keeps a Program Status per terminal, which Heeler now reads, and a Rex
terminal running a known agent program is an Agent.

Amended by [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md):
a Rex Agent opens the Agent detail, with Chat for Claude Code and Codex and
the Composer, read over the Host's SSH connection and typed on the control
connection. Since its update of 2026-11-17, a file or image the user
attaches to a message is staged on the Host over that SSH connection too.
Since its update of 2026-11-18, Chat is also offered for Pi and Oh My Pi,
whose Chat adds Heeler's extension to the Agent's extension folder when the
user asks.

Amended 2026-11-16 (see [Update 2026-11-16](#update-2026-11-16)): the switch
is gone, and every build offers Rex.

Amended 2026-11-25 (see [Update 2026-11-25](#update-2026-11-25-native-windows)):
a native Windows Host is asked for Rex's named pipe, and each channel to it is
an exec of Rex's own stdio bridge.

Amended 2026-11-25 (see [Update 2026-11-25: New Terminal](#update-2026-11-25-new-terminal)):
New Terminal starts a shell in a new window of a Workspace's session, or in
a new session, on the control connection.

Amended 2026-11-25 (see [Update 2026-11-25: API revisions 12 to 19](#update-2026-11-25-api-revisions-12-to-19)):
the hello offers revision 19 with a floor of 12, and a welcome at any
revision in that range is accepted.

Amended by [ADR 0047](0047-a-host-is-one-machine-and-lists-its-servers.md), as
[Update 2026-11-16: a Server of its Host](#update-2026-11-16-a-server-of-its-host)
says: a Rex server is a Server of its Host, listed by the look that adds or
scans the Host and turned on with a switch, so nothing is confirmed in Host
detail.

## Decision

- Rex is an experimental Server Kind under ADR 0031's rules: a Host added by
  hand is confirmed once in Host detail and never switches kind, and a Pairing
  Code never adds one. (Amended 2026-11-16: a Rex Server is turned on, not
  confirmed; see the update below. Amended 2026-11-18: since
  [ADR 0057](0057-heeler-pair-pairs-a-machine-without-herdr.md)
  Pairing ends on Add Host's Servers step, whose look lists a Rex Server like
  any other.) A confirmed Rex Host persists in a defaults catalog of
  its own (`rexHosts`), which builds before this change never read, so they
  neither show nor rewrite its Hosts.
- A Rex Host is one Rex server that is already running on a macOS or Linux
  machine, found by the Unix socket it listens on. The Host stores that
  socket's absolute path. It has no session name. A stored path that does not
  read, or one Heeler could not quote as one shell word, is a lookup to make
  again, never a reason to hide the Host or fail the catalog.
- Heeler never starts a Rex server. Where none runs, Rex is not offered, and a
  Rex Host's checks say to start Rex on the machine. (Amended 2026-11-16: an
  installed Rex with no server is listed as not running; see the update
  below.)
- Detection works without the Rex command-line tool. It tests files in the
  detection exec Heeler already runs: whether each place a server listens holds
  a socket, whether the account owns it and may read and write it, and whether
  Rex looks installed. It never runs `rex`.
  - On macOS the place is the account's
    `~/Library/Application Support/rex/server.sock`, whose path has a space.
  - On Linux the places are, in order, `$REX_RUNTIME_DIR/server.sock`,
    `$XDG_RUNTIME_DIR/rex/server.sock`, `/run/user/<uid>/rex/server.sock`,
    `~/.local/state/rex/run/server.sock`, `/run/rex/server.sock` and
    `/var/run/rex/server.sock`. The account's own server comes before a shared
    one. The root-only login server's socket is never one of them.
  - Rex looks installed on macOS when its data folder, named exactly `rex`, or
    an app whose bundle names Rex is there, and on Linux when
    `~/.local/state/rex` is. A `rex` command alone is not enough: other
    software has one.
  - A native Windows Host is never asked.
- Detection offers Rex only where it found a socket the account may use. It
  says plainly when Rex is installed and no server runs, and when a socket is
  there that this account cannot use. Confirming stores the socket found.
  (Superseded 2026-11-16 by the update below: turning Rex on stores it.)
- (Removed 2026-11-16, see the update below.) One switch,
  `RexHostsExperiment`, decides whether this build offers Rex. It
  is off by default and cannot be turned on in a Release build; a Debug build
  turns it on with the `--rex-hosts` launch argument or the
  `experimental.rexHosts` default. With it off, the app behaves as a build
  without Rex: detection does not look for Rex, and stored Rex Hosts stay
  saved, unlisted, undialed, and kept by every catalog write.
- Heeler reaches the server through the Host's SSH connection. A
  direct-streamlocal channel to the stored socket carries one WebSocket control
  connection, whose hello asks for API revision 12 only; a server that does not
  welcome it at revision 12 is named as unsupported, with the revision it
  offers. More channels to the same socket carry data links under the Attach
  admission slots. A Host whose socket was not stored has it looked up again
  on each connection. The Host's checks have the catalog keep what they found;
  the Console keeps a socket it found only for that Host session.
- When SSH will not open the socket, one bounded exec reads whether a socket
  file is there and whether a server listens on it (`/proc/net/unix` on Linux,
  `lsof` over the account's own processes on macOS). The reason then says Rex
  is not running, or that the SSH server refuses socket forwarding. It still
  runs nothing of Rex's. (Amended by ADR 0056: the same SSH connection also
  carries Chat's reads, which write nothing, and the staging of a file or
  image the user attaches to a message, the one write: one exec that makes
  a private directory under the account's temporary directory and an SFTP
  write into it, as on the other Server Kinds (ADRs 0005 and 0006). Neither
  runs anything of Rex's.)
- A Rex Host's checks say hello and close with a close frame, which changes
  nothing on the server. A control connection that drops without a close frame
  comes back with the reconnect token from its welcome, so the server keeps the
  client; leaving for good sends a close frame. The token is never logged or
  shown.
- A Rex Host lists Terminals only. It offers no Agent status, Chat, Composer,
  New Agent, New Terminal, Rename, Close or uploads, and no notifications,
  Live Activities, Usage, Accounts, plugin or Host Helper. A first version
  attaches only to Terminals that already exist and accepts one Rex API
  revision. (Amended by ADR 0054: a terminal running a known agent program is
  an Agent with its Agent Status. Amended by ADR 0056: that Agent opens the
  Agent detail, with Chat for Claude Code and Codex, Composer Send and Stop,
  and, since 2026-11-17, uploads of the images and files its messages carry.
  Amended 2026-11-25: New Terminal starts a shell, see the update below; the
  rest of this list stands.)

## Why

- A running server is all Heeler needs, and the user already runs one. Starting
  a server from an SSH exec would start it outside the user's session, with an
  environment and lifetime the user did not choose, which is the trade-off
  ADRs 0031 and 0044 declined for herdr-core and tmux.
- The Rex command-line tool is a poor probe. A non-interactive SSH exec often
  lacks it on `PATH`, and some of its commands start a server when none runs.
  The socket is what a connection needs anyway, and testing a file starts
  nothing.
- A catalog of its own keeps older builds from listing a kind they cannot
  connect, and from dropping Hosts they cannot read, as with herdr-core and
  tmux.
- Shipping behind a switch lets the work land in steps while every build users
  receive behaves exactly as before. (This held until 2026-11-16, see the
  update below.)

## Evidence

- On a Mac running Rex Beta 0.1.0, the server listened on the Application
  Support socket above, and the Rex command-line tool was not on the `PATH` of
  an SSH exec.
- The Linux places follow where Rex, as of 0.1.0, puts a personal and a shared
  server's socket. No running Linux server has confirmed them yet.
- Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, through a
  user-level OpenSSH 10.3p1 sshd on loopback (2026-11-15,
  `RexControlWebSocketLiveTests` and `RexSSHLiveTests`): a forwarded channel to
  the Application Support socket, with its space, was welcomed at revision 12;
  `server.status`, `session.attach_all` and `session.list` agreed on the
  session count; a connection idling under one-second pings stayed open; and a
  connection dropped without a close frame came back on a new one as the same
  client, marked resumed. A second channel to the socket opened beside the
  control connection.
- With that sshd, `AllowStreamLocalForwarding no` refused the channel, and so
  did `AllowTcpForwarding no` with stream-local forwarding allowed. libssh2
  reported the refusal exactly as it reported a missing socket, which is why
  the socket check exists.
- `scripts/test-server-kind-detection.py` runs the detection script through
  `/bin/sh`, dash, bash and ksh against fake Darwin and Linux homes, with a
  socket in a path with spaces, and checks that a `rex` on `PATH` never runs.

## Considered options

- Run `rex` to ask for the server: rejected, for the reasons above.
- Offer Rex wherever it is installed and start its server on connect: rejected,
  since Heeler starts no server on a Host it only watches.
- Store Rex Hosts in the shared catalog: rejected, since an older build would
  list them as Herdr TUI Hosts and connect to the wrong server.

## Consequences

- The Console connects a Rex Host and lists its Terminals as ADR 0050 says;
  opening one is a later change. (Later decisions made it: a terminal opens
  from the server's redraw (ADR 0051), takes input one request at a time
  (ADR 0052), and takes its size for the view that shows it (ADR 0053).) The
  Host's checks connect on their own.
- Each Console projection now says what a detail keeps to when the Host's
  inventory moves on, instead of the store asking for herdr-core or tmux by
  name, so a fourth kind adds its own answers.
- Every switch over the Server Kind names Rex, and every integration that picks
  its Hosts by kind leaves Rex Hosts out.

## Update 2026-11-16

By the maintainer's decision, the `RexHostsExperiment` switch is removed, with
its `--rex-hosts` launch argument and its `experimental.rexHosts` default. Rex
is a Server Kind in every build, Release included, as tmux is. That the
support is still experimental is said in the user guide and the changelog, not
in the app.

The switch had let the work land in steps on the main branch while every build
users received behaved as one without Rex: detection did not look for Rex, no
Host could be confirmed as one, and stored Rex Hosts stayed saved, unlisted
and undialed. Debug builds turned it on for development and acceptance.

What every build now does, and what it means for people without Rex:

- Detection looks for Rex on every macOS and Linux Host. The Rex part stays a
  part of the one detection exec, so it adds no exec and no round trip; it
  only tests files, starts nothing, and reports between markers of its own, so
  a part that does not read leaves the other findings as they are. A native
  Windows Host is still never asked. Through a user-level OpenSSH 10.3p1 sshd
  on loopback on macOS 27.0, with Rex running, the whole exec took a median of
  about 330 ms with or without the Rex part; the Rex part added a median of 12
  to 23 ms over 20 to 40 paired runs, and alone took 12 ms more than an empty
  exec.
- A Host without a Rex socket this account may use is offered what it was
  offered before. Detection lists Rex beside the other kinds, and an installed
  Rex with no server says to start it.
- The `rexHosts` catalog stays separate and now always loads, so builds before
  Rex Hosts still read their own Hosts untouched. No other stored data changed
  shape.
- Agents, Chat, Composer, New Agent and New Terminal, notifications, Live
  Activities, widgets, Usage and background refresh still leave Rex Hosts out
  by Server Kind, as before. (Agents no longer do since ADR 0054, and Chat
  and the Composer no longer do since ADR 0056.)

## Update 2026-11-16: a Server of its Host

ADR 0047, written on the main branch beside this one, made a Host the machine
and had it list its Servers. A Rex server joins that model the way a tmux
server did. Where Rex differs from tmux, this says how and why.

- **One Rex Server per Host.** A look lists one at most: the server on the
  socket it prefers, the account's own before a shared one. Its key names
  nothing (`HostServerKey(kind: .rex, name: "")`), so it reads `Rex` wherever a
  Server is named, and a Rex record of the Host maps to that key whatever
  socket it stores. The socket stays in the record, not in the key. A key that
  held the path would put a home directory into labels, would change when a
  Linux runtime directory does, and could not match a record that stores no
  socket yet.
- **Running, not running, missing.** A socket this account may use is a Server
  that runs, and Add Host starts it checked. Rex installed with no socket is a
  Server that is not running, listed unchecked as a stopped tmux is. Turned on,
  it connects once the user starts Rex. Until then its page and the Console
  say to start Rex, since the reason, `rexServerNotRunning`, is retried on its
  own. That replaces the note that told the user to start Rex before Rex could
  be confirmed. A socket this account cannot use is the one case where a look
  names Rex missing, with that reason. Unlike a tmux that is not installed,
  Rex that is not installed, a Rex part that did not read, and a kernel other
  than macOS or Linux name Rex nowhere: Rex is experimental, the Setup Guide
  covers herdr only, and a Host whose user has no Rex shows nothing new. The
  row for a Rex named missing gives its reason and offers no Setup Guide.
- **On and off.** Turning Rex on, in Add Host or in Host detail, stores the
  socket the look found, in the `rexHosts` catalog. Turned on while Rex is not
  running, it stores none and looks the socket up on each connection, as a
  stored path that does not read already did. The socket its page's checks
  note later is taken without a reconnect, as a tmux Host's resolved paths
  are, so open terminals stay; any other change to the record is another
  Host, as before. Turning it off removes its record, which ends its
  connections, and leaves the Host's other Servers as they are. A Rex Host
  saved before this change keeps its stored shape and is the Rex Server of
  the Host its connection matches.
- **Not by name.** Add by Name does not offer Rex. A Rex Server has no name to
  type, its socket is found and never typed, and a look already lists an
  installed Rex that is not running.
- **Found later.** A Rex server that starts on a Host added earlier is marked in
  the Hosts list and tagged New in Host detail, and stays off, as any Server
  found later does.
- **Remembered apart.** The device's memory of what each look found keeps a
  Rex Server under a key of its own, as Rex Hosts keep a catalog of their
  own. A build with that memory and without Rex reads the shared key whole,
  so one Rex Server in it would make that build forget what it found on
  every Host and point out each Server that is off as new again.
- **Kept out by kind.** Usage reads a Host through its records that can read
  Usage, so a Rex record is never what a Host is read through or named by, and
  a Host whose only Server is Rex has no Usage entry. Where Rex Servers are
  all that is on, Usage and the Accounts in Settings say that Rex reports
  none, rather than asking for a Host that Hosts already lists. Agent List
  Fields is kept on this device and asks nothing of the Host, so it lists a
  Rex record beside the others (`HostStore.rowLayoutHosts`), and its rows can
  show the `backend` field as `rex`. Having no plugin, a Rex record starts,
  there and in the Console alike, from Heeler's two-row default
  (`AgentRowLayout.withoutPlugin(on:)`: `terminal_title_stripped` with `host`
  on the right, then `workspace` with `changes` on the right). Agents, Chat,
  Composer, New Agent and New Terminal, notifications, Live Activities,
  widgets, background refresh, the plugin, the Host Helper and Pairing Codes
  still leave Rex out. (Agents no longer do since ADR 0054, Chat and the
  Composer no longer do since ADR 0056, and Pairing Codes no longer do since
  ADR 0057.)

For Rex this supersedes the confirmation in Host detail, "where none runs,
Rex is not offered", and detection that offers Rex only for a usable socket.
ADR 0047's change to ADR 0031's confirmation applies to Rex as it does to
herdr-core and tmux.

## Update 2026-11-25: native Windows

Rex runs on native Windows too, where a personal server listens on the named
pipe `\\.\pipe\rex-<SID>`, the account's SID, and not on a Unix socket.
SSH forwards no named pipe, so direct-streamlocal cannot reach it. Rex's own
command-line tool reaches such a server over SSH with an exec of
`rex __internal dial-stdio`, which copies bytes between the exec's stdio and
the pipe. Heeler now does the same:

- **Detection asks Windows.** The Windows detection exec gains a Rex part,
  under the same markers as the Unix one. It lists the pipe namespace by
  name for `rex-<SID>`, the account that signed in, without opening a pipe:
  testing the path itself would connect to the server as a client, and miss
  it while every instance is busy. Rex looks installed when its data folder,
  `%LOCALAPPDATA%\rex`, is there, as on the Unix side a `rex` on PATH is
  not enough. A pipe is usable only when `rex.exe` is on the exec's PATH,
  which the bridge runs; a pipe without it is named missing, with that
  reason. The part still never runs `rex`, and a Rex Host's checks run it
  alone. A native Windows Host is no longer "never asked".
- **The pipe is stored as Rex writes it.** The Host stores the address
  `npipe:////./pipe/rex-<SID>` where a Unix Host stores its socket's path.
  Only that name, `rex-` and letters, digits and hyphens, is accepted, so the
  address goes on a command line unquoted. A build before this change reads
  the address as a socket path it cannot use and looks the socket up again,
  as for any stored path that does not read.
- **Each channel is an exec of the bridge.** The control link and each data
  link run `cmd /d /c "echo <marker>&& cd /d %USERPROFILE%&& rex.exe -S
  <address> __internal dial-stdio --autostart=false"`, naming `rex.exe` in
  full so no `rex.cmd` or `rex.bat` takes its place, and carry the same WebSocket they carry over a Unix
  socket, after the marker drops whatever the account's shell printed, as
  herdr-core's `connect` does on Windows (ADR 0031). The control link holds
  the events slot and a data link an attach slot, as before.
  `--autostart=false` keeps the bridge from starting a server, so connecting
  still starts nothing; where none listens, the bridge exits before the
  upgrade, and a fresh look says whether Rex is not running, not
  installed, or not on the PATH.
- **Chat stays on macOS and Linux.** Chat's reads and the staging of an
  attachment are written for a POSIX Host, so a Rex Host reached by a pipe
  offers no Chat yet. Its terminals, Agents and Agent Status work as on the
  other platforms, and the Composer's Send and Stop type on the control link.

Running `rex` on the Host is new here. The reasons above for not running it
stand for detection, which still does not. The bridge is different: it is the
one way to a pipe over SSH, the command-line tool itself uses it for the same
purpose, and `--autostart=false` keeps the promise that connecting starts no
server. The command is an internal one of Rex's and may change between
previews; a change shows as a link that does not open, which the Console
retries.

Evidence: against Rex 0.1.0-preview.23 (API revision 19, supporting 0 to 19)
on Windows 11 with Win32-OpenSSH, through an SSH exec whose DefaultShell is
`cmd` (2026-11-25): the bridge's exec answered Heeler's upgrade to
`/api/control` with `101 Switching Protocols` and `rex.control.v1`, welcomed a
hello at revision 12 with `api_revision` 12, and answered `session.list`. With
no server at the address, the bridge printed `no Rex server is running at
\\.\pipe\rex-<SID>, and autostart is disabled` and exited 1. Listing the
pipe namespace found the running server's pipe in about 0.35 s per exec.

## Update 2026-11-25: New Terminal

A Rex Host listed its terminals but started none, so a terminal for a new
command meant going to the machine first. Rex's own clients start one with a
request on the control connection, which Heeler already holds. Heeler now
does the same, for a shell only:

- **New Terminal is a new window.** New Terminal, and New Terminal Here on a
  Workspace's card, send `session.new_window` for the Workspace's session,
  with one block of Rex's shell flavor, `com.superlogical.terminal.shell`,
  whose `cwd` option is the directory New Terminal resolved, as on every
  other Server Kind. `focus` is false, so the window Rex's own app shows
  stays active. Rex answers only a client attached to the session, so the
  control client sends `session.attach` first, as an open terminal does.
- **New Workspace is a new session.** New Workspace sends `session.create`
  with one such window, labeled with the name the user gave, else with the
  directory's last name, as the other kinds name a new Workspace. A tab name
  has nowhere to go and is not asked for.
- **The block is given back at once.** Rex makes the creating client the new
  block's owner. Heeler sends `session.disown_block` for it straight away, so
  the block's size stays as ADR 0053 has it: taken by a view that shows the
  terminal and given back when it leaves, never held by a terminal nobody is
  looking at. Rex refuses that request from a client not attached to the
  session, so New Workspace attaches to the session it made first. When that
  attach fails, the session is made all the same and New Workspace still
  gives its terminal: the block is kept as a size the client took, and goes
  back on the session's next attach, as ADR 0053 has it. The attach is not
  tried again, which would only add its deadline to the wait.
- **Sent once.** A create that left is never sent again. One with no answer
  may still have made its terminal, so the error says to check the list
  before trying again. The new terminal lists from the server's events, as
  any other does, and opens like a new terminal on the other kinds.
- **The home directory and Browse Directory** come from the probe and SFTP
  listing every Host's New Terminal uses, on the same SSH connection, which on
  native Windows reads `USERPROFILE`. A Rex Host's reported directories may be
  a Windows machine's, so a Windows path starts a terminal there too.

New Agent, Rename and Close stay unoffered: each is a request Rex has, but
each needs its own decision on what Heeler may change on a server it does not
own. Starting a shell is the smallest such change, and the one Rex's
`--autostart=false` promise does not cover: it starts a program in a running
server, never a server.

Evidence: against Rex 0.1.0-preview.23 on macOS (2026-11-25), a client that
said hello at API revision 12 was refused `session.new_window` with `409
conflict` (`stream is not attached to session ...`) until it sent
`session.attach`. After it, the call answered `window_id` and `block_ids`,
the session's active window stayed as it was, and the events that followed
were `block_created`, `block_owner_changed` to the creating client with
reason `create`, `window_created` and `session_view_changed`. The shell's
foreground reported the `cwd` asked (`/private/tmp` for `/tmp`).
`session.create` with `initial_windows` answered `session_id` and each
window's `window_id` and `block_ids` without an attach.

## Update 2026-11-25: API revisions 12 to 19

Heeler said hello at revision 12 alone, and Rex 0.1.0-preview.23 speaks 0 to
19. Heeler now offers 19 with a floor of 12 (`api_revision` 19,
`api_min_revision` 12), accepts a welcome at any revision from 12 to 19, and
keeps the revision agreed on with the control link. Rex picks the newest
revision both sides speak, so an older Rex such as 0.1.0-preview.14 still
welcomes the hello at 12, and a server whose oldest revision is newer than
19 closes with a policy code before welcoming, read as unsupported as
before.

Nothing Heeler sends or reads differs between 12 and 19, so no behavior is
gated on the revision: when a later change uses something newer than 12, it
checks the agreed revision first.

Evidence: against Rex 0.1.0-preview.23 on macOS (2026-11-25), the same probe
said hello at 12 and at 19 and made the same requests in a session of its
own: `server.status`, `server.version`, `session.list`, `session.attach_all`,
`session.create`, `session.attach`, `session.view`, `session.list_blocks`,
`session.new_window`, `session.own_block` and `session.disown_block`, the
terminal's `title`, `process`, `program_status`, `size`, `modes`, `format`,
`resize` and `write`, `block.event` with a paste and a focus, an unknown
method, a malformed request and `data.connect`. Every answer, every event
and the terminal data connection's handshake and first snapshot had the same
shape at both revisions. A hello of 19 with floor 12, or 25 with floor 12,
was welcomed at 19, one of 12 at 12, and one of 25 with floor 20 was closed
with 1008 (`no common API revision: server speaks 0 to 19, client needs 20 to
25; update the server`). Over the Windows stdio bridge to Rex
0.1.0-preview.23 on Windows 11, a hello of 19 with floor 12 was welcomed at
19 and `session.list` answered.
