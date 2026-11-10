---
status: proposed
---

# tmux Hosts target a running tmux server

Many people run coding agents in tmux sessions they started themselves, over
SSH or on a desktop. tmux is neither Herdr TUI nor herdr-core: it has no API
socket Heeler can speak, no plugins, and no Program Status of its own. Heeler
adds tmux Hosts beside Herdr TUI and herdr-core Hosts, whose support stays as it
is. ADR 0043 covers the Console on a tmux Host and ADR 0044 its Agent Status.

## Decision

- tmux is a third Server Kind under ADR 0031's rules: a Host added by hand is
  confirmed once in Host detail and never switches kind. A Pairing Code never
  adds one, since it describes only a Herdr TUI endpoint.
- A tmux Host targets one tmux server, named by its socket name
  (`tmux -L <name>`, `default` unless the user names another). Heeler never
  calls it a session: a tmux session is a Workspace (ADR 0043). Each connection
  first resolves the tmux executable and the socket path through the user's
  login shell, because an SSH exec's `PATH` often lacks a Homebrew tmux and the
  user's shell files may set `TMUX_TMPDIR`; everything after that runs the
  resolved executable with `-S <path>`. A socket path typed by the user is not
  supported.
- Heeler talks to tmux only through its command-line client, over SSH exec:
  one-shot commands, a polling loop, and control-mode clients
  (`tmux -C attach-session`) on exec channels without a PTY.
- Connecting reaches only a server that is already running. With none, the Host
  reads No tmux server running, and can still be confirmed. New Workspace on
  such a Host starts one with `new-session -d` through the user's login shell,
  so the server gets the environment it would get had the user signed in and
  typed `tmux`.
- Only macOS and Linux, with tmux 3.3 or newer. An older tmux reads Update
  required with the version found; a Host without tmux reads not installed.
  Detection, through the same login shell, lists the socket files in the user's
  tmux directory as servers to choose from, with `default` preselected. The
  socket name can be edited later, as a core session name can.
- A Pane's identity is its server instance and its pane id. The instance is the
  server's `#{pid}` with its `#{start_time}`. Everything Heeler keeps per Pane
  (Pins, retained Attaches, Chat bindings, seen marks) belongs to one instance,
  and a new instance ends it, as a new core id does on herdr-core.
- What Heeler changes in the user's tmux is limited to four things: pane user
  options named `@heeler-*`; a per-window size request while a device views a
  Pane (ADR 0043); windows, sessions and paste buffers Heeler creates itself;
  and its own `pipe-pane` reader on a Pane that runs Codex, Grok Build or
  OpenCode and has no pipe (ADR 0044). It never sets a global, server, session
  or window option, a key binding, a tmux hook or tmux's global environment.
  Where the user's configuration keeps a feature from working, Heeler says so
  and changes nothing.

## Why

tmux's client and server speak a private protocol that changes with its
version, so the command-line client is the only stable interface. Connecting
must never start a server for the reason in ADR 0031: a server started from
Heeler's exec would hand that exec's environment to every Pane after it.
Starting one for New Workspace is still worth offering, because on Linux
machines tmux is routinely started over SSH, and the login shell gives the
server what the user's own start would. The target is named by its socket
because "session" already means a Workspace on tmux. A new server numbers its
panes from `%0` again, so a pane id alone would let a Pin taken before a restart
point at an unrelated Pane after it.

3.3 is the first release that lets a control-mode client size one window, which
is how a device sizes the Pane it views (ADR 0043). 3.2 can only size the whole
client, and that size flips back whenever a desktop client types. It also brings
what 3.2 added for control mode: client flags, `pause-after`, and fair limits on
control-mode output.

## Evidence

Live on 2026-11-10 with tmux 3.7b on macOS 27.0 (Apple M3 Max), against private
servers (`-L`) that were killed afterwards:

- `tmux -C attach-session` runs on a pipe with no terminal and answers commands
  in `%begin` and `%end` blocks.
- After `kill-server`, a new server again numbered its first pane `%0`. Two
  servers started within the same second had equal `#{start_time}` values and
  different `#{pid}` values.
- `pipe-pane -o` on a Pane that already had a pipe closed that pipe
  (`#{pane_pipe}` went from 1 to 0) instead of leaving it, which is why ADR 0044
  reads `#{pane_pipe}` before attaching anything.

From tmux's sources and release notes:

- `cmd-refresh-client.c` parses a `@<window>:<width>x<height>` size from the
  3.3a tag on, and not at 3.2a; `tmux.1` documents a window size for a control
  mode client from 3.3.
- [CHANGES](https://github.com/tmux/tmux/blob/master/CHANGES) for 3.2 add client
  flags for any client, the `pause-after` flag and fair limits on control-mode
  output; the 3.7 entry adds the `bracket_paste_flag` format, so ADR 0043 copes
  without it before 3.7.

Distribution packages as [Repology](https://repology.org/project/tmux/versions)
listed them on 2026-11-10: tmux 3.2a in Ubuntu 22.04 and AlmaLinux and Rocky
Linux 9; 3.3a in Debian 12, CentOS Stream 10 and openSUSE Leap 15.6; 3.4 in
Ubuntu 24.04; 3.5a in Debian 13 and Fedora 42; 3.6a in Ubuntu 26.04; 3.8 in
Homebrew and Arch Linux.

## Considered options

- Speaking to the tmux socket directly, as Heeler does to herdr's. The protocol
  is private and versioned with tmux itself.
- Never starting a server, as ADR 0031 does for cores. Too strict where tmux is
  started over SSH as a matter of course.
- Calling the target a session, like the herdr and herdr-core session names.
  It collides with tmux's own sessions, which are Workspaces.
- Supporting 3.2 by attaching to a hidden grouped session per viewed window and
  sizing the whole client. A second sizing path, a session of Heeler's in
  `tmux ls`, and a size the desktop takes back on every keystroke.

## Consequences

- tmux Hosts are added by hand. Pairing still requires Herdr TUI.
- Every connection spends one login-shell exec before anything else.
- Ubuntu 22.04 and AlmaLinux and Rocky Linux 9 ship tmux 3.2a, so their users
  need a newer tmux than the system's.
- Restarting the tmux server drops the Pins and bindings of its old Panes.
