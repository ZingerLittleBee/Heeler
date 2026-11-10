---
status: proposed
---

# tmux Program Status comes from Heeler's integrations

On herdr-core, Agent Status follows the Program Status harnesses report through
OSC 7501 (ADRs 0032 and 0033). Inside tmux most of them report nothing. Claude
Code and Pi first ask the terminal whether it takes OSC 7501, behind a DA1
sentinel; tmux answers the DA1 at once and never the question, so both decide
it does not. Grok Build stays silent in its default mode. Codex, Oh My Pi and,
by its source, OpenCode 2.1 and later still write their reports, but tmux keeps
them from any terminal attached to it.

## Decision

- A tmux Pane's Program Status is recorded in its user option `@heeler-status`,
  in OSC 7501's words (`state=…`, `app=…`, optional `kind=…` and `msg=…`) with a
  `turn=<n>` count. Whatever records it advances the count when the status
  leaves working for done or error, or, for a program not known to report done,
  for idle, so a turn that starts and finishes between two looks still counts.
  Only Heeler's own integrations write it:
  - Claude Code: hooks, below.
  - Pi and Oh My Pi: Heeler's extensions (ADR 0033), which inside a tmux Pane
    also write the status. Pi makes none there on its own.
  - Codex, Grok Build and OpenCode 2.1 or later: the Host Helper attaches a
    reader with `pipe-pane` to a Pane whose foreground is one of them and whose
    `#{pane_pipe}` is 0, parses bare reports and Grok Build's `ESC P tmux;`
    wrapped ones, and writes the option. A Pane the user already pipes is left
    alone, and its Agent says why it has no status. Grok Build's default `auto`
    stays silent in tmux, so Heeler offers ADR 0033's
    `program_status = "on"` edit there too. OpenCode before 2.1 has none, as on
    herdr-core.
- Claude Code hooks: for each Claude Code configuration root, the default one
  and each Account's (ADR 0037), Host detail offers to add Heeler's hooks to that
  root's user settings. It shows the exact change, applies it only on the user's
  word, and undoes it on request and with the Helper's removal. An Agent Heeler
  starts under a root without them gets the same hooks for that launch alone,
  through `--settings`, editing nothing. The hook command does nothing outside a
  tmux Pane (no `TMUX_PANE`), since the same settings serve Claude Code under
  Herdr TUI and herdr-core. Events map to words: UserPromptSubmit, PreToolUse
  and PostToolUse to working; PermissionRequest to blocked; Stop to done;
  StopFailure to error; SessionStart and the `idle_prompt` Notification to idle,
  which never ends a turn; SessionEnd clears the status. The `permission_prompt`
  Notification, which repeats PermissionRequest seconds later, is ignored. The
  hooks also write `@heeler-session` (session id, transcript path, and Claude
  Code's pid and start), a hint Chat verifies as it does `heeler.session`
  (ADR 0034). This amends ADR 0033's "Heeler never edits Claude Code's
  settings" for tmux Hosts only.
- After the user approves a permission, Claude Code sends no event until the
  tool finishes, so a long approved tool reads Blocked until then. When the user
  answers a Blocked Claude Code from Heeler's tools keyboard, Heeler writes
  working at once; the next hook corrects a denial.
- Agent Status follows `@heeler-status` as herdr-core's follows Program Status,
  Done included: an Agent is Done for a device when it finished a turn after
  that device's last seen mark (ADR 0033) and reads idle or done. A mark names
  the server instance (ADR 0042), the Pane and the turn. Without a Helper the
  app keeps its marks itself.
- The Host Helper runs on macOS and Linux tmux Hosts as ADR 0033 installs it.
  Its tmux follower never starts a server, waits for one, and starts over with
  a new server instance. It reads `list-panes -a` every 5 seconds, which is
  enough to attach readers, notice Panes that ended and see status changes, and
  from those changes sends Agent Notifications and Live Activity updates as
  ADR 0033 does. Notification Registrations hold one entry per device for each
  tmux server. A Live Activity's workspace is the tmux session's name. The
  integrations write only to tmux, never to the Helper.

## Why

- Answering the question is out of reach: tmux answers the DA1 that follows it
  before anything Heeler could type into the Pane arrives, and Claude Code and
  Pi settle on no.
- A reader on an agent's Pane sees only that Pane's bytes and leaves sessions
  as they were, where a Helper control client per session would receive every
  Pane's output and make every session read attached in `tmux ls`.
- Codex and Grok Build already say everything in their output, while editing
  their own hook configurations would mean more user files and, for Codex, its
  trusted hashes.
- Claude Code's hooks are the only signal it gives inside tmux, and they reach
  sessions the user started on the desktop, which a wrapper around Heeler's own
  launches could not.
- The turn count keeps Done right at a 5-second interval, which spares the Host
  most of the cost of sampling every second (ADR 0043).

## Evidence

Live on 2026-11-10, in panes of a private tmux 3.7b server on macOS 27.0, each
program with its own isolated home and configuration, against a local mock
model, with nobody signed in:

- Claude Code 2.1.322's debug log read
  `programStatus=no (probe: no reply to OSC 7501 ; ?)`. It sent the question
  0.17 s after starting and reported nothing over six turns.
- Pi 1.4.0 sent `ESC ] 7501 ; ? ESC \` followed by DA1 and reported nothing over
  a turn. With `PI_PROGRAM_STATUS=1` it reported idle, working, done and error,
  bare. Its source decides on the question's answer, not on `TMUX`.
- Codex 0.167.0 reported idle, working, done, blocked (`kind=permission`) and
  error, bare, without asking. Oh My Pi 18.12.3 reported idle, working, done and
  blocked (`kind=question`), bare, without asking.
- Grok Build 1.0.77 reported nothing in `auto`. With `program_status = "on"` it
  reported idle, working, done and blocked (`kind=question`), wrapped as
  `ESC P tmux; ESC ESC ] 7501 ; … ESC ESC \ ESC \`, with `allow-passthrough` on
  or off.
- OpenCode 2.0.32 reported nothing over two turns, and its binary holds no
  `7501`. OpenCode's program-status source on its dev branch (`c7ddff776c`)
  writes bare reports without checking `TMUX` or the question's answer; no 2.1
  or later release was run.
- `pipe-pane` delivered both the bare and the wrapped report bytes unchanged.
- Claude Code 2.1.322 ran hooks given through `--settings`, as a file in an
  interactive session and as inline JSON with `-p`, and the user's settings
  file kept its hash. One interactive session logged SessionStart,
  UserPromptSubmit and Stop; then PreToolUse, PermissionRequest with the dialog
  on screen, the `permission_prompt` Notification 6 s later, PostToolUse after
  the approval, and Stop; StopFailure in place of Stop on an API error; the
  `idle_prompt` Notification 60 s after a turn; and SessionEnd on exit. Every
  event carried `session_id` and `transcript_path`. In a directory not yet
  trusted, no hook ran until the trust dialog was accepted.

## Considered options

- A PTY shim between the Pane and an agent Heeler starts, answering the
  question before DA1 passes. Every reporting harness would work, but only for
  Agents Heeler starts, and the shim would be a new program on every Host.
- Reading status off the screen. It covers every start, but each harness's
  interface change breaks it.
- A Helper control client per session, reading every Pane's output. No pipes,
  but every session reads attached and the Helper scans all output.
- Editing Codex's and Grok Build's own hook configurations. More user files,
  and Codex's trusted hashes.
- Only what tmux itself shows: the foreground program, the title and silence.
  No Blocked, so no Blocked notification.
- Integrations that also tell the Helper directly. Notifications about 2.5 s
  sooner on average, at the price of a second channel.

## Consequences

- Until a directory's trust dialog is accepted, Claude Code there reads
  Unknown.
- Codex, Grok Build and OpenCode have a status only where the Helper runs, which
  needs Node.js on the Host, and not in a Pane the user already pipes.
- Claude Code settings carry Heeler's hooks only where the user accepted them,
  until Undo or the Helper's removal.
- A notification can trail its status change by up to 5 seconds plus the
  debounce. The Helper's sampling should cost about a fifth of ADR 0043's
  foreground loop; it has not been measured.
- Not yet seen live: OpenCode 2.1 or later in tmux, Oh My Pi's and Grok Build's
  error and permission prompts, Pi's blocked, and Claude Code's question tool
  and MCP elicitation.
