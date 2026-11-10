---
status: proposed
---

# tmux Hosts poll their inventory and attach through control mode

On a tmux Host (ADR 0042) the Console needs the server's sessions, windows and
panes, which program each pane runs, a live terminal for the Pane a device
opens, and input into it. tmux offers one-shot commands and control-mode
clients. A control-mode client receives the output of only the session it is
attached to, its format subscriptions cover only that session, and attaching
one changes what the user's own tmux shows.

## Decision

- Organization: a tmux session is a Workspace, a window a Tab, and a pane a
  Pane, named and ordered as tmux shows them. Heeler keeps no organization of
  its own. A window that grouped sessions share shows once, under the group's
  session with the lowest id, so its Panes and Agents are not doubled. Rename
  Workspace runs `rename-session`, a Tab's name is its window's name, and Rename
  Agent is not offered, since programs set their own pane titles.
- Inventory: one exec per connection runs a POSIX loop that asks
  `list-panes -a -F <format>` once a second and prints only when the answer
  changed, adding the argv of a Pane whose foreground program changed, plus a
  heartbeat. The format holds only fields that change when something happens:
  ids, names, indexes, the foreground command, the current directory, the size,
  `#{pane_pipe}` and the `@heeler-*` options. It never holds a pane title, a
  cursor position or an activity time, which change on their own. The loop runs
  while the app is in the foreground and connected, and the app converges its
  snapshots as it does Herdr TUI's.
- Agents: a Pane is an Agent while its foreground program is a known agent
  program, read after ADR 0032's unwrapping of launch wrappers, `sh -c`,
  interpreters and `npx`; a shell in the foreground ends it. An unknown program
  is never an Agent on tmux, since every Program Status there comes from
  Heeler's integrations for known programs (ADR 0044).
- Attach: one control-mode client per tmux session that holds an open Attach,
  closed when its last Attach closes or retention (ADR 0017) lets it go, with
  `pause-after` so a slow link pauses a Pane instead of growing tmux's buffer.
  First paint is `capture-pane -e -p` with history and the mode formats
  (cursor, alternate screen, keypad, mouse, and from tmux 3.7
  `bracket_paste_flag`), followed by the Pane's `%output` in order. Every viewer
  may type: there is no Take Over, as on herdr-core.
- Size: as with every other Attach, the viewing device sets the size. Heeler
  requests a size for the viewed Pane's window
  (`refresh-client -C @<window>:<columns>x<rows>`), scaled from the Pane's share
  of its window so that the Pane itself gets the device's grid. tmux restores
  the window when the client leaves. Heeler never zooms a pane.
- Input: Direct Input and the tools keyboard send tmux key names with
  `send-keys` and text with `send-keys -l`, so tmux encodes each key for the
  mode the Pane's program set. Composer Send keeps ADR 0035's checked steps. Its
  paste goes through a paste buffer Heeler names, pasted with
  `paste-buffer -p -d`, and only while bracketed paste is on: from tmux 3.7 that
  is read from `#{bracket_paste_flag}`; before 3.7 a known agent program at its
  prompt is taken to have it on, unless this Attach saw the program turn it
  off. Submit is `send-keys Enter`. Stop sends Esc to a known agent program and
  Ctrl+C to anything else.
- Launches: New Agent in a Workspace opens a window in its session at the
  chosen directory; New Workspace opens a session with the name the user typed,
  or tmux's numbering, starting the server if none runs (ADR 0042); New
  Terminal opens a window running the user's shell. An Agent starts as on
  herdr-core, through the user's interactive shell replacing itself with the
  agent (ADR 0032), with ADR 0034's session flags, so its Pane, and a window it
  had alone, ends when it exits.
- Chat binds as ADR 0034 describes, finding a Pane's processes by their
  `TMUX_PANE` in place of `HC_SCOPE`.
- Worktrees: a branch the user names is checked out at
  `~/.heeler/worktrees/<repository>/<branch>`, with ADR 0032's branch slug and
  git commands, and opens as a new session named after the branch. Removing one
  ends that session's Panes, then runs `git worktree remove` under ADR 0032's
  risk checks and force rule.
- The leaked-environment check (ADR 0034) and Usage's Account variables
  (ADR 0033) read tmux's global environment (`show-environment -g`), which every
  new pane inherits, by name only.

## Why

- Format subscriptions do not cross sessions and `%output` follows only the
  attached session, so tracking every Pane's foreground program needs polling
  either way. A shell loop that prints only changes costs the Host a little more
  than a control client the app polls, but sends nothing while nothing changes,
  where the control client would send the whole snapshot every second for the
  app to compare. It also leaves the user's tmux untouched: no client in
  `list-clients`, and no change to which session a bare `tmux attach` picks.
- Agent detail shows one Agent, and tmux users often split a window between an
  agent and a shell, so a per-pane control-mode view beats attaching a real
  tmux client, which draws the whole window.
- A per-window size request holds against the desktop client's typing and is
  undone when the client leaves, whereas a client-wide size flips back whenever
  the desktop types. Zoom changes the desktop user's layout, and nothing undoes
  it if the link drops.
- `send-keys -H` turns each byte into a separate key that tmux encodes again for
  the Pane's keyboard mode, so ghostty's encoded bytes would arrive mangled once
  a program asks for extended keys, as Claude Code does inside tmux.

## Evidence

Live on 2026-11-10 with tmux 3.7b on macOS 27.0 (Apple M3 Max), against private
servers that were killed afterwards:

- A control client attached to session `a` got no `%output` from a pane of
  session `b`; after `switch-client -t b` it did. It still got
  `%unlinked-window-add`, `%unlinked-window-renamed`, `%unlinked-window-close`,
  `%sessions-changed` and `%session-renamed` for the other sessions.
- A subscription on `%*` reported only session `a`'s panes, and one naming a
  pane of session `b` reported nothing.
- With session `b` the most recent, a targetless `display -p` named `b`; once a
  control client attached to `a` it named `a`, and `a` counted one attached
  client.
- With 60 panes in 10 sessions, one `list-panes -a` with the inventory format
  took 6.8 ms of wall time (4.1 ms of client and 1.7 ms of server CPU). The
  shell loop used 536 ms of CPU over 30 seconds, about 1.8% of one core, and
  printed one 10 KB snapshot, then nothing. One control client polled the same
  way used about 0.7% of a core and read 300 KB in those 30 seconds.
- With a 160x49 desktop client attached, a control client without `ignore-size`
  asking for `@<window>:60x30` set the window to 60x30, the desktop's typing
  left it there, and the window went back to 160x49 when the control client
  left. A client-wide `refresh-client -C 50x20` was taken back by the desktop's
  next keystroke. A window split 80/79 became 45/44 at 90 columns and 90/89 at
  180.

## Considered options

- One control-mode client for inventory, with structural notifications pushed
  at once. Foreground changes still need polling; it either sends the whole
  snapshot every second or makes the app compare them, and it shows in the
  user's tmux.
- A real tmux client over a PTY, attached to a hidden grouped session with its
  status line off. tmux would encode input exactly as for a desktop terminal,
  but a split window shows whole, so the Agent gets a fraction of the screen,
  and the hidden sessions show in `tmux ls`.
- Showing the window at the desktop's size (`ignore-size`) and letting the
  device scale and pan it. It leaves the desktop alone but needs a terminal view
  with a grid fixed by the remote side, which no other Attach has.
- An Agent that leaves a shell behind when it exits, as tmux users often have
  it. A tmux Agent would then end differently from a herdr-core one.

## Consequences

- While a device views a Pane, the desktop sees that window at the device's
  size, and its session becomes the one a bare `tmux attach` picks. Heeler's
  control client shows in `list-clients` and counts as attached.
- Inventory lags by up to a second. The Host spends about 1.8% of one core per
  60 Panes on macOS while the app is in the foreground, and more Panes cost
  more; Linux has not been measured.
- Before tmux 3.7, a multi-line Send to an agent that turned bracketed paste off
  before the Attach began can submit its lines one by one.
- How faithfully `send-keys` carries modifiers, extended keys and pastes into
  each known agent program has to be verified before this design is relied on.
