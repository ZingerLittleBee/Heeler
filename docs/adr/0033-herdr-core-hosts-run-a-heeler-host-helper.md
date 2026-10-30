---
status: proposed
---

# herdr-core Hosts run a Heeler Host Helper and its harness extensions

On Herdr TUI the Heeler plugin runs inside herdr: its hooks send Agent
Notifications and Live Activity updates through the Push Relay while the app is
away, and it collects Usage on the Host (ADRs 0027 and 0028). herdr-core runs
no plugins and sends nothing to anyone. Its status and turn events reach only
clients connected to its socket. Its only other signal is a note: a marked
line the core types into a parent agent's Terminal when a child Terminal that
agent started gets stuck or exits
([notes.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/notes.rs#L165-L177)),
which reaches that agent and nobody else. Chat also needs every displayed
herdr-core Agent's session (ADR 0034), and Pi has no record of its session
that Heeler can read from outside the process.

## Decision

- macOS and Linux herdr-core Hosts run the Host Helper: Heeler's own
  background service, built from the plugin's sources, bundled with the app,
  copied over SFTP into a directory Heeler owns, and registered as a user
  service (a LaunchAgent on macOS, a systemd user unit on Linux). The app
  replaces it only with a newer version, or when it is missing or damaged,
  never over a newer one another device installed, as ADR 0027 does for the
  plugin. It runs on the Node.js the Host already has, found as for the
  plugin and named by its absolute path in the service, since a systemd user
  unit's `PATH` holds only system directories. The service restarts whenever
  it stops, not only on failure. A user service does not start with the
  core's environment, so for Usage the Helper reads the variables that locate
  Accounts, such as `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, from the core
  process's environment, only those by name.
- On Linux the Helper needs systemd linger, as the core does, to run while
  nobody is logged in. The install screen checks it and offers to turn it on.
- The Helper connects to the core's socket directly, never through `hc`, so it
  never starts a core. While no core runs it waits for one. It finds the
  socket as the app does (ADR 0031): the session's `core.lock`, else the
  session's default socket path, because `core.lock` appears only once a core
  has started for that session. On each connection it asks `server.status`
  for the core's pid before it subscribes, and it rebuilds its inventory from
  the subscription's snapshot, since event numbers restart with every core
  process.
- It subscribes to status and turn events and sends Agent Notifications for
  Blocked, Error and Done, and Live Activity updates, through the Push Relay,
  to the devices whose Notification Registrations it holds, encrypted with
  their Notification Keys. It serves Usage reads as the plugin does. Those
  Notification Registrations live in the Helper's own directory, one entry
  per device for the core session the Host targets, never in the plugin's
  registration file.
- A turn's end comes from the status word, as in the app: a program that
  reports done ends a turn when it reports done, and one that never does
  (OpenCode, or a program whose `app` Heeler does not know) when it goes
  from Working to Idle. Turn events cannot tell it: the turn count also moves
  when an Agent enters Blocked or Error, or when Codex passes through Working
  as it starts, and a move from Blocked straight to Done brings no turn event.
- Done is per device there as in the app. When the app opens an Agent, or
  has one open as it ends a turn, it writes a small seen mark (device, core
  id, Terminal address, turn, status word) into the Helper's directory over
  SFTP. The Helper counts an Agent as Done for a device when it ended a turn
  after that device's last mark and still reports idle or done, in
  notifications and Live Activity updates alike. A device's marks go with its
  registration, and all of them with the Helper.
- With the Helper come Heeler's extensions for Pi and Oh My Pi, placed in the
  folders those programs load extensions from on their own
  (`~/.pi/agent/extensions`, and `~/.omp/agent/extensions` for each Oh My Pi
  profile). No configuration file changes. An extension does nothing outside
  a herdr-core Terminal (no `HC_TERMINAL_ID`); inside one it reports its
  session as a `heeler.*` label on its own Terminal, through one JSON-RPC line
  to `$HC_TERMINAL_SOCKET`, and Pi's also reports Program Status for Pi
  releases before 1.1.0. The install screen lists every file. Removing the
  Helper removes them, its service and its directory, and any folder the
  install created that is then empty.
- A harness configuration file changes only when the user accepts that one
  change, shown exactly, and every such change can be undone. There are two:
  - OpenCode, offered from Chat when an OpenCode Agent's session cannot be
    bound. OpenCode loads a TUI plugin only from its plugin list, so Heeler
    copies its OpenCode plugin into a folder of its own under OpenCode's
    config directory and adds that folder to the list (`plugin` in
    `tui.json(c)`, or `plugins` in `cli.json`, by OpenCode's release). Undoing
    removes the entry, then the folder; removing the Helper undoes it.
  - Grok Build, offered where a Grok Build Agent shows no status because its
    automatic check left Program Status off: `[ui.notifications]
    program_status = on` in its configuration.

  Heeler never edits Claude Code's settings, Codex's hooks or their trusted
  hashes, or Grok Build's global hooks.
- Native Windows herdr-core Hosts get no Helper for now, so no background
  notifications, Live Activity pushes or Usage: Windows needs a user-service
  design of its own, and none has been tested there. The app writes the Pi and
  Oh My Pi extensions there itself, through the core's `file.write`.

This amends ADR 0024's "nothing is installed on the Host", and ADR 0025's
rejection of a Heeler OpenCode plugin, for herdr-core Hosts only; Herdr TUI
Hosts are unchanged.

## Considered options

- No background features on herdr-core. Nothing installed, but Blocked and
  Done reach the user only while the app is open.
- Running the Helper as a kept herdr-core Terminal. No service to register,
  but a kept Terminal comes back as a shell, not as the Helper, and it would
  show in every client's terminal list.
- Asking for each extension separately. The two folders load files without
  configuration or trust prompts and are cleaned by deleting the files, so
  one listed install is enough.
- Done without seen marks: one Done notification per finished turn, and no
  Done in Live Activity. Nothing written on open, but the Live Activity would
  count differently from the app, or count Agents the user already opened.

## Consequences

- A Host without Node.js gets no Helper; the app says so where the user turns
  on notifications.
- Without linger, systemd stops the Helper and the core about ten seconds
  after the user's last login ends, so the Helper runs only while some login,
  Heeler's own included, is open. Debian 13 lets a user turn linger on
  without a password; other distributions can ask for an administrator.
- The app runs `systemctl --user` over SSH exec with `XDG_RUNTIME_DIR` set
  itself, since a Host without `pam_systemd` leaves it unset. Its health
  check reads the unit's state, result and restart count, because a Helper
  that keeps failing at start, for example after Node.js moved, ends up
  failed for good.
- The Helper computes the default socket path from its own environment. A
  core started under another `XDG_STATE_HOME` keeps its `core.lock` where the
  Helper does not look and has another core id behind the same socket path,
  so seen marks written for the earlier core do not apply to it.
- Opening an Agent on a Host with the Helper costs one small SFTP write. A mark
  that fails to write leaves that Agent counted as Done in the next push.
- Pairing still requires Herdr TUI; herdr-core Hosts are added by hand.
- The extensions load in every Pi and Oh My Pi session on the Host and must
  stay inert outside herdr-core.
- `heeler.*` labels are not authenticated and outlive the process that wrote
  them, so the app treats them as hints to verify (ADR 0034).
- Heeler's OpenCode plugin needs a user configuration file edited, and only
  on the user's word.
