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
  adds one, since it describes only a Herdr TUI endpoint. A confirmed tmux Host
  persists in a defaults catalog of its own, as a herdr-core Host does, which
  builds before this change never read.
- A tmux Host targets one tmux server, named by its socket name
  (`tmux -L <name>`, `default` unless the user names another). Heeler never
  calls it a session: a tmux session is a Workspace (ADR 0043). When the Host is
  confirmed, and again whenever the stored paths stop answering, Heeler resolves
  the tmux executable and the socket path through the user's interactive login
  shell (`$SHELL -lic`, as in ADR 0031), because an SSH exec's `PATH` often
  lacks a Homebrew tmux and the user's shell files may set `TMUX_TMPDIR`. The
  Host stores both, every command runs the stored executable with
  `-S <path>`, and the Host Helper gets them from the app (ADR 0044). A socket
  path typed by the user is not supported.
- Heeler talks to tmux only through its command-line client, over SSH exec:
  one-shot commands, a polling loop, and control-mode clients
  (`tmux -C attach-session`) on exec channels without a PTY. Every command
  carries `-N`, so none can start a server, except the one that starts a server
  for New Workspace (below).
- Connecting reaches only a server that is already running. With none, the Host
  reads No tmux server running, and can still be confirmed. On Linux, New
  Workspace on such a Host starts one with `new-session -d` through
  `$SHELL -lic`, so the server gets the environment it would get had the user
  signed in and typed `tmux`. On macOS it says to start tmux on the Mac first.
  With a server running, New Workspace runs `new-session -d -E`, so the new
  session takes the server's environment, not the exec's.
- Only macOS and Linux, with tmux 3.3 or newer. An older tmux reads Update
  required with the version found; a Host without tmux reads not installed.
  Detection, through the same login shell, offers the sockets in the user's
  tmux directory that a server answers on, with `default` preselected. The
  socket name can be edited later, as a core session name can.
- A Pane's identity is its server instance and its pane id. The instance is the
  server's `#{pid}` with its `#{start_time}`. Everything Heeler keeps per Pane
  (Pins, retained Attaches, Chat bindings, seen marks) belongs to one instance,
  and a new instance ends it, as a new core id does on herdr-core.
- What Heeler changes in the user's tmux without being asked is limited to:
  pane user options named `@heeler-*`; the size of a window while a device
  shows one of its Panes; sessions of its own, one per Attach, each holding a
  link to the window it shows, with their own options (ADR 0043); and its own
  `pipe-pane` reader on a Pane that runs Codex, Grok Build or OpenCode and has
  no pipe (ADR 0044). Everything else, such as typing into a Pane or opening,
  renaming or ending a window or session, happens because the user asked for it
  in Heeler, and a session opened for a Worktree carries a `@heeler-worktree`
  option. Heeler never sets a global or window option, an option of a session
  not its own, a key binding, a tmux hook or tmux's global environment. Where
  the user's configuration keeps a feature from working, Heeler says so and
  changes nothing.

## Why

tmux's client and server speak a private protocol that changes with its
version, so the command-line client is the only stable interface. Connecting
must never start a server for the reason in ADR 0031: a server started from
Heeler's exec would hand that exec's environment to every Pane after it.
`attach-session` starts one whenever the user's configuration creates a
session, as `new-session -d` lines and session-restoring plugins do, so `-N` is
on everything. Starting a server for New Workspace is still worth offering on
Linux, where tmux is routinely started over SSH and the login shell gives the
server what the user's own start would. On macOS a server started over SSH runs
outside the user's desktop login session, as a core would, and its Panes would
lack the login keychain. The target is named by its socket because "session"
already means a Workspace on tmux. A new server numbers its panes from `%0`
again, so a pane id alone would let a Pin taken before a restart point at an
unrelated Pane after it. Resolving paths once per Host, not per connection,
spares every connection an interactive shell's startup.

3.3 is the first release that lets a control-mode client size one window, which
is how a device sizes the Pane it shows (ADR 0043). 3.2 can only size the whole
client, and that size flips back whenever a desktop client types. It also brings
what 3.2 added for control mode: client flags, `pause-after`, and fair limits on
control-mode output.

## Evidence

Live on 2026-11-10 with tmux 3.7b on macOS 27.0 (Apple M3 Max), against private
servers (`-L`) that were killed afterwards:

- `tmux -C attach-session` runs on a pipe with no terminal and answers commands
  in `%begin` and `%end` blocks.
- With a configuration file holding `new-session -d -s autostarted` and no
  server running, `tmux -C attach-session` started a server that kept running
  with that session. With `-N` it said no server was running and started none.
- After `kill-server`, a new server again numbered its first pane `%0`. Two
  servers started within the same second had equal `#{start_time}` values and
  different `#{pid}` values. The killed server's socket file stayed in place.
- `pipe-pane -o` on a Pane that already had a pipe closed that pipe
  (`#{pane_pipe}` went from 1 to 0) instead of leaving it, which is why ADR 0044
  reads `#{pane_pipe}` before attaching anything.

From tmux's sources and release notes:

- `cmd-refresh-client.c` parses a `@<window>:<width>x<height>` size from the
  3.3a tag on, and not at 3.2a; `tmux.1` documents a window size for a control
  mode client from 3.3, along with `-N`, `new-session -E`, `refresh-client -f`
  and the `ignore-size` client flag.
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
- Never starting a server on any platform, as ADR 0031 does on macOS and
  Windows. Too strict on Linux, where tmux is started over SSH as a matter of
  course.
- Resolving the paths on every connection. Always current, but every
  connection would wait for the user's interactive shell files.
- Calling the target a session, like the herdr and herdr-core session names.
  It collides with tmux's own sessions, which are Workspaces.
- Supporting 3.2 by attaching to a hidden grouped session per viewed window and
  sizing the whole client. A second sizing path, and a size the desktop takes
  back on every keystroke.

## Consequences

- tmux Hosts are added by hand. Pairing still requires Herdr TUI.
- Confirming a Host, and any connection whose stored paths stopped answering,
  waits for one interactive login-shell exec.
- A macOS tmux Host with no server running offers no New Workspace until the
  user starts tmux on the Mac.
- Ubuntu 22.04 and AlmaLinux and Rocky Linux 9 ship tmux 3.2a, so their users
  need a newer tmux than the system's.
- Restarting the tmux server drops the Pins and bindings of its old Panes.
