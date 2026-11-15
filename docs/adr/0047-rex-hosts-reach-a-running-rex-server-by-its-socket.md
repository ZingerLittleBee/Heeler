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

Amended 2026-11-16 (see [Update 2026-11-16](#update-2026-11-16)): the switch
is gone, and every build offers Rex.

## Decision

- Rex is an experimental Server Kind under ADR 0031's rules: a Host added by
  hand is confirmed once in Host detail and never switches kind, and a Pairing
  Code never adds one. A confirmed Rex Host persists in a defaults catalog of
  its own (`rexHosts`), which builds before this change never read, so they
  neither show nor rewrite its Hosts.
- A Rex Host is one Rex server that is already running on a macOS or Linux
  machine, found by the Unix socket it listens on. The Host stores that
  socket's absolute path. It has no session name. A stored path that does not
  read, or one Heeler could not quote as one shell word, is a lookup to make
  again, never a reason to hide the Host or fail the catalog.
- Heeler never starts a Rex server. Where none runs, Rex is not offered, and a
  Rex Host's checks say to start Rex on the machine.
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
  runs nothing of Rex's.
- A Rex Host's checks say hello and close with a close frame, which changes
  nothing on the server. A control connection that drops without a close frame
  comes back with the reconnect token from its welcome, so the server keeps the
  client; leaving for good sends a close frame. The token is never logged or
  shown.
- A Rex Host lists Terminals only. It offers no Agent status, Chat, Composer,
  New Agent, New Terminal, Rename, Close or uploads, and no notifications,
  Live Activities, Usage, Accounts, plugin or Host Helper. A first version
  attaches only to Terminals that already exist and accepts one Rex API
  revision.

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

- The Console connects a Rex Host and lists its Terminals as ADR 0048 says;
  opening one is a later change. (Later decisions made it: a terminal opens
  from the server's redraw (ADR 0049), takes input one request at a time
  (ADR 0050), and has its size taken only at the user's tap (ADR 0051).) The
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
  by Server Kind, as before.
