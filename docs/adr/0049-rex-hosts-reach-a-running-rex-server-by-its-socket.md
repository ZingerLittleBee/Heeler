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
  and, since 2026-11-17, uploads of the images and files its messages carry;
  the rest of this list stands.)

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
