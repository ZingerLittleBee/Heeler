---
status: proposed
---

# tmux Hosts poll their inventory and attach through control mode

On a tmux Host (ADR 0042) the Console needs the server's sessions, windows and
panes, which program each pane runs, a live terminal for the Pane a device
opens, and input into it. tmux offers one-shot commands and control-mode
clients. A control-mode client receives the output of only the session it is
attached to, its format subscriptions cover only that session, and once it asks
for any size it takes part in sizing every window of that session.

## Decision

- Organization: a tmux session is a Workspace, a window a Tab, and a pane a
  Pane, named and ordered as tmux shows them. Heeler keeps no organization of
  its own. A window that several sessions share, grouped or linked, shows once,
  under the one with the lowest id, so its Panes and Agents are not doubled.
  Heeler's own sessions (below) never show. Rename Workspace runs
  `rename-session`, a Tab's name is its window's name, and Rename Agent is not
  offered, since programs set their own pane titles.
- Inventory: one exec per connection runs a POSIX loop that asks
  `list-panes -a -F <format>` once a second and prints only when the answer
  changed, plus a heartbeat. It adds the argv of a Pane whose foreground program
  changed, by its command or by the program its `@heeler-status` names. The
  format holds only fields that change when something happens: ids, names,
  indexes, the foreground command, the current directory, the size,
  `#{pane_dead}`, `#{pane_pipe}`, and the `@heeler-*` options of the pane and its
  session. It never holds a pane title, a cursor position or an activity time,
  which change on their own. The loop runs while the app is in the foreground
  and connected, and the app converges its snapshots as it does Herdr TUI's. It
  takes one of ADR 0017's four ordinary SSH sessions while it runs, leaving
  three for one-shot commands, so a connection still opens at most nine.
- Agents: a Pane is an Agent while its foreground program is a known agent
  program, read after ADR 0032's unwrapping of launch wrappers, `sh -c`,
  interpreters and `npx`; a shell in the foreground ends it, and a dead Pane
  (`remain-on-exit`) hosts none. An unknown program is never an Agent on tmux,
  since every Program Status there comes from Heeler's integrations for known
  programs (ADR 0044).
- Attach: each Attach is a session of Heeler's own, marked `@heeler-attach`,
  holding a link to the window of the Pane it shows (`link-window`), with one
  control-mode client attached to it, so that client's output and size reach
  that window alone. The session is opened around a placeholder window that
  closes once the link is in, gets `destroy-unattached` once its client is
  attached, so it goes when the client does, and ends when its Attach closes or
  retention (ADR 0017) lets it go. When the window's last other link goes, as
  when the user ends its session, Heeler closes the window, which would
  otherwise live on in Heeler's session. The client runs with `pause-after`, so
  a slow link pauses the Pane rather than growing tmux's buffer, and a paused
  Pane resumes with a new first paint.
- Everything for one Attach goes through its control client, in order: first
  paint, keys, text, pastes, Send's steps and Stop. First paint is built from
  `capture-pane -e -p` with history, of both screens when the Pane is on the
  alternate one, and the mode formats (cursor, alternate screen, scroll region,
  keypad, mouse, and from tmux 3.7 `bracket_paste_flag`), followed by the Pane's
  `%output`. Output from the window's other Panes is dropped. Every viewer may
  type: there is no Take Over, as on herdr-core.
- Size: while a device shows a Pane, Heeler asks for a size for its window
  (`refresh-client -C @<window>:<columns>x<rows>`), scaled from the Pane's share
  of the window, reads back the Pane's size, and corrects the request until the
  Pane fits the device's grid. tmux takes the request as a ceiling: a window a
  terminal of the user's also shows stays no larger than that terminal, so the
  Pane can come out smaller than the device's grid, and the view shows it at its
  own size with the rest blank. It is never larger. When the device stops
  showing the Pane, including while ADR 0017 retains the Attach, the client
  turns on `ignore-size` and tmux sizes the window by its other clients again;
  a window no other client shows keeps the size it had. Heeler never zooms a
  pane.
- Input: Direct Input and the tools keyboard send tmux key names with
  `send-keys` and text with `send-keys -l`, so tmux encodes each key for the
  mode the Pane's program set. Composer Send keeps ADR 0035's checked steps.
  Its paste goes through a paste buffer Heeler names, pasted with
  `paste-buffer -p -d`, and only while bracketed paste is on: from tmux 3.7 that
  is read from `#{bracket_paste_flag}`; before 3.7 a known agent program at its
  prompt is taken to have it on, unless this Attach saw the program turn it
  off. Send reads the foreground itself, as the process leading the foreground
  process group of `#{pane_tty}`, with `ps` before the paste and again once the
  control client has acknowledged it, in place of the core's sampling period.
  Submit is `send-keys Enter`. Stop sends Esc to a known agent program and
  Ctrl+C to anything else, and is offered while the Agent reads Working or
  Blocked, since a Blocked Claude Code can be running a tool the user approved
  (ADR 0044). This amends the Working-only Stop of ADRs 0013 and 0035 for tmux
  Hosts.
- Chat's Send, Stop and Blocked Card answers keep ADR 0035's rules and type
  through an Attach of Chat's own, which asks for no size and closes after the
  action. Chat's screen checks read `capture-pane -e -p`.
- Launches: New Agent in a Workspace opens a window in its session with
  `new-window -d` at the chosen directory, leaving the session's current window
  as it was; New Workspace opens a session with the name the user typed, or
  tmux's numbering, starting the server as ADR 0042 allows; New Terminal opens
  a window running the user's shell. An Agent starts as on herdr-core, through
  the user's interactive shell replacing itself with the agent (ADR 0032),
  with ADR 0034's session flags, so its Pane, and a window it had alone, ends
  when it exits.
- Chat binds as ADR 0034 describes, finding a Pane's processes by their
  `TMUX_PANE` together with the socket path and server pid in their `TMUX`,
  which must name the Host's server instance, in place of `HC_SCOPE`.
- Worktrees: a branch the user names is checked out at
  `~/.heeler/worktrees/<repository>/<branch>`, with ADR 0032's branch slug and
  git commands, and opens as a new session named after the branch, numbered
  when that name is taken, carrying `@heeler-worktree` set to the checkout's
  path. Removing one ends the Panes of the session carrying that path, never a
  session that only shares its name, then runs `git worktree remove` under
  ADR 0032's risk checks and force rule.
- The leaked-environment check (ADR 0034) and Usage's Account variables
  (ADR 0033) read tmux's global environment (`show-environment -g`), which new
  panes inherit, and the session's (`show-environment -t`), which overrides it
  for that session's new panes, by name only.

## Why

- Format subscriptions do not cross sessions and `%output` follows only the
  attached session, so tracking every Pane's foreground program needs polling
  either way. A shell loop that prints only changes costs the Host a little more
  than a control client the app polls, but sends nothing while nothing changes,
  where the control client would send the whole snapshot every second for the
  app to compare. It also leaves the user's tmux untouched: no client in
  `list-clients`. Reading process groups each second would catch every
  foreground change, but `ps` costs a Mac with many processes more than the
  whole loop; the agents worth telling apart all name themselves in their
  status.
- Agent detail shows one Agent, and tmux users often split a window between an
  agent and a shell, so a per-pane control-mode view beats attaching a real
  tmux client, which draws the whole window.
- A control client attached to the user's session shrinks that session's
  current window to the client's own 80x24 the moment it asks for any size, and
  under `aggressive-resize` cannot size a window that is not current. A session
  of Heeler's holding only the shown window keeps the client's size away from
  every other window, under every `window-size` and `aggressive-resize` setting
  tried, with or without a desktop client, and limits its output to that
  window. A grouped session would hold every window of the group, and its
  client would size all of them under `smallest` or when no desktop client is
  attached.
- A ceiling only ever makes the Pane smaller than the device asked for, which a
  view can show with blank space, so a terminal view whose grid the remote side
  fixes is still not needed. Turning on `ignore-size` hands the window back at
  once without closing the Attach.
- `send-keys -H` turns each byte into a separate key that tmux encodes again for
  the Pane's keyboard mode, so ghostty's encoded bytes would arrive mangled once
  a program asks for extended keys, as Claude Code does inside tmux. Separate
  one-shot execs have no order between them, so keys go through the Attach's
  client, as does first paint, which only lines up with `%output` there.

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
  way used about 0.7% of a core and read 300 KB in those 30 seconds. With 2,342
  processes running, one `ps -A -o tpgid=,tty=` cost about 57 ms of CPU, and one
  limited to 60 terminals about 29 ms.
- A 160x49 desktop client showed window 0 of session `a`, and a control client
  attached to `a` asked for window 1 at 60x30. Window 1 became 60x30 and window
  0 80x24, whether or not the desktop had typed; under `window-size latest` the
  desktop's next keystroke restored window 0, under `smallest` it stayed. With
  `aggressive-resize` on, window 1 kept its size and window 0 still became
  80x24. With no desktop client, windows 0 and 1 became 80x24 and 60x30 and kept
  those sizes after the control client left.
- With the desktop showing the same window, requests of 60x30, 45x60 and 200x80
  gave 60x30, 45x49 and 160x49, and the desktop's typing changed none of them.
  A client-wide `refresh-client -C 50x20` was taken back by the desktop's next
  keystroke. A window split 80/79 became 45/44 at 90 columns and 90/89 at 180.
- A grouped session with its current window on window 1 kept window 0 at
  160x49 under `latest`, `largest` and with `aggressive-resize`, but its control
  client shrank window 0 to 80x24 under `smallest`, and with no desktop client.
  While it was attached, a bare `tmux attach` chose an unattached session of
  the user's.
- A session holding only a link to window 1, its control client asking for
  60x30, gave window 1 60x30 and left windows 0 and 2 at their sizes under
  `latest`, `latest` with `aggressive-resize`, `smallest`, `largest`, and with no
  desktop client under `latest` and `smallest`. Its client got `%output` from
  window 1's pane only. `refresh-client -f ignore-size` handed window 1 back to the desktop's
  160x49 at once; turning it off took 60x30 again. After `kill-session -t a`,
  window 1 lived on in that session with `#{window_linked}` 0, and the client
  got `%sessions-changed` and `%unlinked-window-close`.
- `destroy-unattached` set on a session before its client attached ended the
  session at once; set after, it ended the session when the client left.

From the 2026-11-10 review of this ADR, on the same tmux: a window of 121
columns split in two gave panes of 61 and 59; `remain-on-exit` left a dead pane
listed with `#{pane_dead}` 1; a window linked into two sessions without a group
appeared twice in `list-panes -a`; and `new-window` without `-d` changed the
session's current window.

## Considered options

- One control-mode client for inventory, with structural notifications pushed
  at once. Foreground changes still need polling; it either sends the whole
  snapshot every second or makes the app compare them, and it shows in the
  user's tmux.
- A control client attached to the user's session, sizing one window. It
  shrinks the session's current window and fails under `aggressive-resize`.
- A grouped session per Attach. Its client sizes every window of the group
  under `smallest` or when no desktop client is attached, and its output covers
  all of them.
- A real tmux client over a PTY, attached to a hidden grouped session with its
  status line off. tmux would encode input exactly as for a desktop terminal,
  but a split window shows whole, so the Agent gets a fraction of the screen.
- Showing the window at the desktop's size (`ignore-size`) and letting the
  device scale and pan it. It leaves the desktop alone but needs a terminal view
  with a grid fixed by the remote side, which no other Attach has.
- An Agent that leaves a shell behind when it exits, as tmux users often have
  it. A tmux Agent would then end differently from a herdr-core one.

## Consequences

- While a device shows a Pane, the desktop sees that window at the device's
  size where its own terminal is larger, and a window no other client shows
  keeps the device's size until one does.
- Heeler's sessions, one per Attach with one window each, show in `tmux ls`,
  in `choose-tree` and to tools that save and restore sessions, and its control
  clients show in `list-clients`. The user's own sessions read as before, and a
  bare `tmux attach` picks one of them while any is unattached.
- Inventory lags by up to a second. The Host spends about 1.8% of one core per
  60 Panes on macOS while the app is in the foreground, and more Panes cost
  more; Linux has not been measured.
- One agent that replaces another in a Pane within a second, without a status
  naming it, keeps the first one's identity until its foreground command
  changes.
- Before tmux 3.7, a multi-line Send to an agent that turned bracketed paste off
  before the Attach began can submit its lines one by one.
- How faithfully `send-keys` carries modifiers, extended keys and pastes into
  each known agent program has to be verified before this design is relied on.
