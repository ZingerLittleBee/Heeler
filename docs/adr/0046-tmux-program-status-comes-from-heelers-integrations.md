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
  in OSC 7501's words (`state=…`, `app=…`, optional `kind=…` and `msg=…`) with
  two counts. `turn=<n>` advances when the status leaves working or blocked for
  done or error, or leaves working, for a program not known to report done, for
  idle, so a turn that starts and finishes between two looks still counts;
  blocked to done ends a turn, as herdr-core's turn end does
  (`HerdrCoreTurnState`, `herdr-core-turn-end-v1.json`).
  `blocked=<n>` advances each time the status enters blocked, so two questions
  between two looks are two. Both belong to the Pane and never go back:
  whatever writes next, another program or another integration, reads them and
  continues. Only Heeler writes the option: its integrations, and the app and
  the Helper in the cases below.
  A hook or extension writes only for a program that runs on the Pane's own
  terminal and leads its foreground process group, through the server named in
  its `TMUX`, so a program in a herdr pane running inside tmux, or a
  `claude -p` a tool started in the Pane, writes nothing. The integrations:
  - Claude Code: hooks, below.
  - Pi and Oh My Pi: Heeler's extensions (ADR 0033), which inside a tmux Pane
    write the status and their session, whatever Pi's release. Pi makes no
    report there on its own, and Oh My Pi's stops at tmux.
  - Codex, Grok Build and OpenCode 2.1 or later: the Host Helper attaches a
    reader with `pipe-pane` to a Pane whose foreground is one of them and whose
    `#{pane_pipe}` is 0, parses bare reports and Grok Build's `ESC P tmux;`
    wrapped ones, and writes the option. The reader marks the Pane with
    `@heeler-pipe` while it runs and clears the mark when its pipe closes, so a
    restarted Helper knows its own pipes. Heeler closes a pipe only while its
    mark is on it, once the Pane's foreground is no longer that program. A pipe
    that closes without Heeler, as when the user's `pipe-pane -o` toggles it
    off, leaves that Pane alone until its program changes. A Pane the user
    already pipes is left alone, and its Agent says why it has no status. Grok
    Build's default `auto` stays silent in tmux, so Heeler offers ADR 0033's
    `program_status = "on"` edit there too. OpenCode before 2.1 has none, as on
    herdr-core.
- Claude Code hooks: for each Claude Code configuration root, the default one
  and each Account's (ADR 0037), Host detail offers to add Heeler's hooks to that
  root's user settings. It shows the exact change, applies it only on the user's
  word, and undoes it on request, from any device, by removing the hook entries
  that run Heeler's script. An Agent Heeler starts under a root without them
  gets the same hooks for that launch alone, through `--settings`, editing
  nothing. The hooks run one POSIX script Heeler keeps in its own directory on
  the Host, apart from the Helper. It runs the tmux the Host stores (ADR 0044),
  does nothing outside a tmux Pane (no `TMUX_PANE`), since the same settings
  serve Claude Code under Herdr TUI and herdr-core, and a hook whose script is
  gone does nothing, so status works without the Helper and no hook is left
  failing.
- Events map to words: UserPromptSubmit, PreToolUse, PostToolUse and
  PostToolUseFailure to working; PermissionRequest and the `permission_prompt`
  Notification to blocked, the Notification standing alone for a sandboxed
  command's network request; Stop to done; StopFailure to error; SessionStart
  from `startup`, `resume` or `clear`, and the `idle_prompt` Notification, to
  idle, which never ends a turn; SessionEnd clears the status. SessionStart
  after a compaction changes nothing. Once blocked, the status moves only on the
  asking tool's PostToolUse or PostToolUseFailure, matched by tool name and
  input since PermissionRequest carries no tool id, on UserPromptSubmit, Stop,
  StopFailure or SessionEnd, or by Heeler (below), so tool events from subagents
  (`agent_id`) or from tools running alongside cannot hide the question; a
  subagent's PermissionRequest still reads blocked. The hooks also write
  `@heeler-session` (session id, transcript path, and Claude Code's pid and
  start), a hint Chat verifies as it does `heeler.session` (ADR 0034).
- Claude Code runs no hook when the user interrupts it or declines a permission
  with Esc. Heeler's own Stop, and an answer from Heeler that declines (Esc from
  the tools keyboard, or a Blocked Card's decline), therefore write idle at once;
  any other answer from Heeler writes working. A decline at the desktop is
  caught by the Host Helper: while a Claude Code Pane reads working or blocked,
  it watches the end of the Transcript `@heeler-session` names, holds a new
  `turn_duration` entry for 1 second so a normal turn's Stop hook can write done
  first, and sets idle on a follow-up check if `@heeler-status` and
  `@heeler-session` are still unchanged with no new turn activity. An interrupt
  at the desktop
  while Claude Code waits on its model writes nothing anywhere, so that Agent
  reads Working until Claude Code's next event. After the user approves a
  permission, Claude Code sends nothing until the tool finishes, so a long
  approved tool reads Blocked; Send stays refused then, as ADR 0035 has it for
  Blocked, and Stop is offered (ADR 0045).
- Agent Status follows `@heeler-status` as herdr-core's follows Program Status,
  Done included: an Agent is Done for a device when it finished a turn after
  that device's last seen mark (ADR 0033) and reads idle or done. Marks keep
  ADR 0033's form and rules, with the server instance (ADR 0044) and the Pane in
  place of the core id and the Terminal address. Without a Helper the app keeps
  its marks itself.
- The Host Helper runs on macOS and Linux tmux Hosts as ADR 0033 installs it,
  with the tmux executable and socket path the app writes for it (ADR 0044). Its
  tmux follower carries `-N` on every command, so it never starts a server; it
  waits for one, and starts over with a new server instance. It reads
  `list-panes -a` every 5 seconds by default — dropping to every 1 second while
  any followed Agent Pane reads blocked or while a Claude Code `turn_duration`
  entry awaits its 1-second confirmation — which attaches and closes readers,
  notices Panes that ended, sees status changes and clears desktop-declined
  Claude Code prompts within about 2 seconds once blocked (or about 5 seconds if
  the prompt opened and was declined between two 5-second looks), and from those
  changes sends Agent Notifications and
  Live Activity updates as ADR 0033 does, a step of `blocked=<n>` counting as a
  new Blocked. Notification Registrations hold one entry per device for each
  tmux server, and the Helper keeps a tmux server's records under
  `tmux/<socket name>/`, apart from core sessions', which can share a name. A
  Live Activity's workspace is the tmux session's name. The integrations write
  only to tmux, never to the Helper.

This amends ADR 0033 for tmux Hosts only: Heeler adds hooks to Claude Code's
settings where the user accepts them; the Pi and Oh My Pi extensions also act
inside a tmux Pane, where both report a status, Pi's whatever its release; the
extensions and the Helper's service also start the stored tmux, beside
`/bin/ps`; and the Helper keeps a tmux server's records apart from a core
session's. The extensions stay inert anywhere else.

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
- Claude Code's hooks are the only live signal it gives inside tmux, and they
  reach sessions the user started on the desktop, which a wrapper around
  Heeler's own launches could not. Its Transcript is the one place a decline at
  the desktop shows.
- A script apart from the Helper keeps status working on a Host without one,
  and leaves no failing hook when the Helper is removed from another device.
- The counts keep Done and Blocked right at a 5-second interval while Panes are
  idle or working, sparing the Host most of the cost of sampling every second
  (ADR 0045); polling every second only while an Agent Pane reads blocked (or a
  `turn_duration` confirmation is pending) keeps idle cost unchanged while
  clearing a declined prompt well within 5 seconds without racing Claude Code's
  Stop hook.

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
  writes bare reports without checking `TMUX` or the question's answer. No 2.1
  or later release has been run in tmux; 2.2.2 runs on hc-lab (ADR 0033).
- `pipe-pane` delivered both the bare and the wrapped report bytes unchanged.
- Claude Code 2.1.322 ran hooks given through `--settings`, as a file in an
  interactive session and as inline JSON with `-p`, and the user's settings
  file kept its hash. One interactive session logged SessionStart,
  UserPromptSubmit and Stop; then PreToolUse, PermissionRequest with the dialog
  on screen, the `permission_prompt` Notification 6 s later, PostToolUse after
  the approval, and Stop; StopFailure in place of Stop on an API error; the
  `idle_prompt` Notification 60 s after a turn; and SessionEnd on exit. Every
  event carried `session_id` and `transcript_path`. PermissionRequest carried
  the tool's name and input but no `tool_use_id`, which PreToolUse, sent in the
  same millisecond, did. In a directory not yet trusted, no hook ran until the
  trust dialog was accepted.
- With a permission dialog open for 93 s, no `idle_prompt` ran. Declining it
  with Esc ran no hook in the 150 s after, PermissionDenied and
  PostToolUseFailure included, while the Transcript got the rejected tool
  result, `[Request interrupted by user for tool use]` and a `system`
  `turn_duration` entry at once. An Esc 5 s into a model request put the prompt
  back in the input, ran no hook, and added nothing to the Transcript in the
  30 s after.
- Measured on 2026-11-12 to 2026-11-13 across tmux 3.2a, 3.3a, 3.4, 3.5a, 3.6b
  and 3.7b (Ubuntu 24.04 distro 3.4 acceptance B09 and macOS builds), tmux 3.4
  and 3.5a run `utf8_stravisx(..., VIS_OCTAL|VIS_CSTYLE|VIS_NOSLASH)` on
  `display-message -p`, `list-panes -F`, `show-options` and `show-environment`
  output (raw UTF-8 on 3.3a and 3.6+), escaping `0x1f` as `\037` and, on 3.4
  alone, `$` before `[A-Za-z_{]` as `\$`. The Claude Code hook and Helper
  readers therefore frame free-text format fields with `#{q:...}` and ` .` rather
  than control-byte separators or `#{n:...}` byte counts.
- Measured on Ubuntu 24.04 Linux against tmux 3.7b and distro tmux 3.4
  (acceptance B10, 2026-11-12 to 2026-11-13): because a normal turn's
  `turn_duration` entry lands slightly before Claude Code's Stop hook updates
  `@heeler-status`, the transcript watcher holds a new `turn_duration` candidate
  for 1 second and confirms on a second sample so `Stop -> done` is not
  overwritten. Under a fixed 5-second poll interval across both samples, a
  desktop permission decline stayed `blocked` for up to 10 seconds (9.333 s in
  acceptance on 3.7b; 9.251 s on 3.7b and 9.195 s on 3.4 in stand-in
  reproduction). Polling every 1 second while an Agent Pane reads `blocked` and
  scheduling a 1-second follow-up sample while a `turn_duration` candidate is
  pending brought Blocked-to-Idle recovery down to 1.167–1.770 s on 3.7b and
  1.144–1.841 s on 3.4 while keeping idle and working polling at 5 seconds.

From Claude Code's hooks reference, as read in the 2026-11-10 review: Stop does
not run after a user interrupt; a sandboxed command's network request runs the
`permission_prompt` Notification and no PermissionRequest; SessionStart runs on
compaction with the source `compact`; and a subagent's tool events carry
`agent_id`.

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
- Clearing Working after a quiet spell. A long tool run or model wait would
  read Idle.
- Hooks that run the Helper's own files. A Helper removed from another device
  would leave them pointing at nothing.
- Integrations that also tell the Helper directly. Notifications about 2.5 s
  sooner on average, at the price of a second channel.

## Consequences

- Until a directory's trust dialog is accepted, Claude Code there reads
  Unknown.
- A Claude Code turn the user interrupts at the desktop while it waits on its
  model reads Working until Claude Code's next event. A decline at the desktop
  reads Blocked until the Helper spots `turn_duration` and confirms it 1 second
  later (about 1 to 2 seconds once the Helper has seen Blocked, or up to about
  5 seconds if the prompt opened and was declined inside one 5-second interval),
  or, without the Helper, until the next event.
- Codex, Grok Build and OpenCode have a status only where the Helper runs, which
  needs Node.js on the Host, and not in a Pane the user already pipes.
- Claude Code settings carry Heeler's hooks only where the user accepted them,
  until Undo. Removing the Helper leaves them, and the status they write,
  working.
- A notification can trail its status change by up to 5 seconds plus the
  debounce. The Helper's sampling should cost about a fifth of ADR 0045's
  foreground loop; it has not been measured.
- Not yet seen live: OpenCode 2.1 or later in tmux, Oh My Pi's and Grok Build's
  error and permission prompts, Pi's blocked, Claude Code's question tool and
  MCP elicitation, a sandboxed network request's prompt, parallel subagents'
  tool events, and SessionStart after a compaction.
