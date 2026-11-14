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
  Rex looks installed. It never runs `rex`. Should a later change ever run it,
  it runs with `REX_AUTOSTART=0`.
  - On macOS the place is the account's
    `~/Library/Application Support/rex/server.sock`, whose path has a space.
  - On Linux the places are, in order, `$REX_RUNTIME_DIR/server.sock`,
    `$XDG_RUNTIME_DIR/rex/server.sock`, `/run/user/<uid>/rex/server.sock`,
    `~/.local/state/rex/run/server.sock`, `/run/rex/server.sock` and
    `/var/run/rex/server.sock`. The account's own server comes before a shared
    one. The root-only login server's socket is never one of them.
  - A native Windows Host is never asked.
- Detection offers Rex only where it found a socket the account may use. It
  says plainly when Rex is installed and no server runs, and when a socket is
  there that this account cannot use. Confirming stores the socket found.
- One switch, `RexHostsExperiment`, decides whether this build offers Rex. It
  is off by default and cannot be turned on in a Release build; a Debug build
  turns it on with the `--rex-hosts` launch argument or the
  `experimental.rexHosts` default. With it off, the app behaves as a build
  without Rex: detection does not look for Rex, and stored Rex Hosts stay
  saved, unlisted, undialed, and kept by every catalog write.
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
  receive behaves exactly as before.

## Evidence

- On a Mac running Rex Beta 0.1.0, the server listened on the Application
  Support socket above, and the Rex command-line tool was not on the `PATH` of
  an SSH exec.
- The Linux places follow where Rex, as of 0.1.0, puts a personal and a shared
  server's socket. No running Linux server has confirmed them yet.
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

- The Console builds a projection for a Rex Host that never dials and stands
  at a failure saying this build cannot connect to Rex yet. Later changes
  replace it with the connection, the Terminal inventory and the Attach.
- Each Console projection now says what a detail keeps to when the Host's
  inventory moves on, instead of the store asking for herdr-core or tmux by
  name, so a fourth kind adds its own answers.
- Every switch over the Server Kind names Rex, and every integration that picks
  its Hosts by kind leaves Rex Hosts out.
