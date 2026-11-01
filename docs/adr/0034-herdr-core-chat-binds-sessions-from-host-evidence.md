---
status: proposed
---

# herdr-core Chat binds each Agent's session from Host evidence

On Herdr TUI, herdr's integrations report each Agent's session and Chat reads
that session's Transcript (ADR 0024). herdr-core reports no session: Program
Status has no session field, and the core never identifies an agent by brand.
Every herdr-core Agent the Console shows must still offer Chat, and Chat must
never show or send into a conversation it has guessed.

## Decision

- The app binds a herdr-core Agent's session itself, lazily: when Chat opens,
  before each Send, and on the Terminal's status, turn and foreground events.
  Each check is at most one SFTP read and one exec on the Host. The Host Helper
  takes no part. No clock asks, including a Send's echo timeout, and neither does
  a Send having gone, since one check ran just before it. A leak answer that
  names a variable also asks again, since it changes what a reason says.
- A check needs something to look at. Between a link and its snapshot nothing is
  known of any Terminal, and an Agent that left its Terminal has no process, so
  there it says nothing and runs nothing, rather than that it cannot tell: the
  snapshot or the Agent's return asks again. A Send in either sends nothing.
- A check starts from the Terminal's foreground process and its descendants
  that share the Terminal's `HC_SCOPE`, so an npm or Node launcher leads to
  the real agent process. It skips Codex's shared daemon
  (`app-server --managed-daemon`), which keeps the `HC_SCOPE` of the Terminal
  that started it while serving every window. It reads only the variables it
  names from a process environment, on the Host, because environments hold
  secrets. The core keeps a Terminal's scope out of its record, so the check
  reads `HC_SCOPE` from the Terminal's own process, in the same exec.
- For Claude Code the agent is the nearest of those processes that calls itself
  `claude` or a version number, past a launcher of the same name, or the
  foreground itself with nothing under it. Two equally near bind nothing, and a
  child carrying `CLAUDE_CODE_CHILD_SESSION` that its parent does not is that
  parent's tool, not the agent. Its config dir is the same process's
  `CLAUDE_CONFIG_DIR`, or `.claude` under its `HOME`.
- Evidence by program, without installing anything:

  | Program | Evidence |
  | --- | --- |
  | Claude Code | `<config dir>/sessions/<pid>.json`, read by name once Claude Code reaches its prompt, whose process start matches |
  | Codex | in embedded mode only, the rollout the process holds open, one root thread by `session_meta` |
  | Oh My Pi | Heeler's extension (ADR 0033); without it, `<agent dir>/terminal-sessions/<tty>`, confirmed by the process's own session lock or open file |
  | Grok Build | the one `active_sessions.json` row whose pid and process start match |
  | OpenCode | from 2.x, the `ses` id Heeler started it with; otherwise none, and the plugin on the user's word (ADR 0033) |
  | Pi | none; Heeler's extension (ADR 0033) |

- Claude Code's registry entry appears only at its prompt. Before that, during
  sign-in or the trust dialog, its sessions folder holds a `<pid>.<hash>.key`
  file instead, which Heeler never reads. The entry follows `/clear` and
  `/resume`. Its process start is, on Linux, the start time from
  `/proc/<pid>/stat` in clock ticks since boot. The entry's own status word
  cannot tell Done or Error from Idle, so it is no Program Status.
- A `heeler.*` label is a hint. Chat adopts it only when its pid and process
  start match the resolved agent process, and clears it when it can.
- An Agent Heeler starts, other than from a Template (ADR 0032), carries its
  session from the start: `--session-id` for Claude Code and Pi, `-s` for
  Grok Build, `-s ses…` for OpenCode from 2.1, and `--no-daemon` for Codex,
  which cannot be given an id. Oh My Pi relies on its extension. OpenCode 1.x's
  `-s` only continues an existing session, so an OpenCode Agent older than 2.1,
  or whose version does not read, starts without one, as does a Template Agent,
  which binds from evidence alone. Arguments that already pick a session or the
  mode, such as `--resume`, take no flag, since these programs refuse a second.
  The generated id is the label `heeler.launch-session`, the id alone. Nothing
  has started when it is written, so it has no pid or process start, and it stays
  apart from the extensions' `heeler.session`. The Terminal's launch argv carries
  the same id, which is what ties the two together.
- Some variables break session records or Program Status when the core leaks
  them (`CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SKIP_PROMPT_HISTORY`,
  `CLAUDECODE`, `HERDR_*`, `TMUX`, `STY`, `ZELLIJ`, `CURSOR_TRACE_ID`,
  `VSCODE_GIT_ASKPASS_MAIN`, `CODEX_THREAD_ID`, `OMPCODE`,
  `PI_PROGRAM_STATUS`). A launch request cannot unset a variable, only set it
  empty, so the launch blanks those a test showed the affected program reads
  blank as unset: `CLAUDE_CODE_CHILD_SESSION` and
  `CLAUDE_CODE_SKIP_PROMPT_HISTORY` for Claude Code, and `TMUX`, `STY` and
  `ZELLIJ` for Grok Build, which turns Program Status off inside a terminal
  multiplexer. Every other leak is reported as below.
- Without exact evidence Chat says it cannot tell the session, and offers the
  fix: install the Helper, accept the one configuration edit, or reopen Codex
  with `codex resume --no-daemon`, picking the session in Codex's own list. If
  the user wants Chat now, it lists candidates (recent Transcripts in the
  Agent's directory, files the process holds open, Program Status child ids)
  for one confirmation. The choice is stored as the Terminal's `heeler.chat`
  label with the pid and process start, and dropped when the process changes,
  a session-switch signal arrives, or the send guard fails: a message Chat
  sent that does not appear in the bound Transcript once the Agent's next turn
  ends. Chat never binds by itself from a directory or the newest Transcript.
  A confirmed candidate differs from that guess: the user saw the
  conversation before choosing it, and the guard drops it the first time it
  proves wrong.
- Codex's shared daemon gets no binding of its own and no candidate list,
  since every daemon window's sessions look alike from outside: the
  title-prefix match rejected in
  [herdr compatibility](../agents/herdr-compatibility.md) stays rejected, and
  only reopening with `--no-daemon` offers Chat.
- When the core's own environment carries such leaked variables, the Host
  says what they break and that restarting the core from the user's own
  terminal fixes it. Heeler does not restart it. A Claude Code Agent started
  with `CLAUDE_CODE_CHILD_SESSION` keeps neither a registry entry nor a
  Transcript, and one with `CLAUDE_CODE_SKIP_PROMPT_HISTORY` keeps no
  Transcript; Chat says so instead of waiting for a file. `HERDR_*` in a
  herdr-core Terminal is never trusted.
- An Agent with no Program Status shows Unknown and says which release
  reports one where that is known
  ([herdr compatibility](../agents/herdr-compatibility.md)). A
  Terminal that has reported but holds no state, as Claude Code leaves it
  before sign-in, has none. No status is inferred from the screen.
- Chat covers the six programs it reads today. On native Windows herdr-core
  Hosts it opens for Claude Code and Grok Build (session registry plus the
  Windows process tree and creation times) and Pi and Oh My Pi (their
  extensions, which need nothing from the process table), each once tested on
  a Windows Host; Codex and OpenCode follow later. Native
  Windows Herdr TUI Hosts stay without Chat.

This amends ADR 0024, and ADR 0025's source of the OpenCode session id, for
herdr-core Hosts only.

## Considered options

- Binding by working directory or newest Transcript, marked as a guess. Always
  available, but it can show one conversation and send into another.
- Codex's terminal title with the thread id prefix, after a configuration
  edit. Distinguishes daemon windows, but the prefix is not the id, which is
  why it was rejected before.
- Program Status carrying the session. It has no such field, and changing
  herdr-core is not ours to do.

## Consequences

- A confirmed binding for Pi without the extension or OpenCode without the
  plugin cannot notice an in-process `/new`. Send still reaches whatever
  session the program shows, but Chat keeps showing the old one until a guard
  catches it.
- Ending the Terminal that started Codex's shared daemon ends the daemon, and
  every other default-mode Codex on the same `CODEX_HOME` loses its backend
  while it still reports Idle.
- Oh My Pi reports Idle while its sign-in waits, so that sign-in shows as
  Idle, not Blocked.
- Oh My Pi's breadcrumb names a session file before the file exists and
  outlives the process on a reused terminal name, so without the extension an
  Oh My Pi Agent binds only once its first message opens the file.
- A Transcript locator takes the config root from the Agent's own process
  environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` and the like),
  not from the Host's Default Account, which follows the core's environment.
  The two differ when the user's shell rc sets the variable.
- Unverified: whether Oh My Pi's security scan leaves the breadcrumb rewritten,
  since the scan needs a stored OAuth account; whether a signed-in account
  changes any of the evidence below, which never saw one; whether Claude Code's
  `procStart` on macOS equals the start `ps -o lstart=` prints;
  `HC_TERMINAL_SOCKET`'s form on Windows; whether Windows Transcripts are
  read over SFTP or the core's `file.read`; and whether a Host can work out an
  Oh My Pi lock's name without running its code, since the hash is not
  identified. Owner confirmation with a signed-in
  harness on hc-lab remains available, and is listed in #578's Owner acceptance.
- Settled with a local fake model and no sign-in, in a throwaway Linux VM and
  not on hc-lab ([herdr compatibility](../agents/herdr-compatibility.md), which
  says what could differ for each program;
  `Tests/HeelerTests/ChatFixtures/host-evidence`): Codex's embedded native
  process holds the rollout open from the first prompt, and its `session_meta`
  tells a root from a subagent; after `/new` it holds two roots, so one root
  thread binds nothing. Pi 1.4.0's file appears at the first prompt, before the
  reply, Pi 0.85.1's only with the reply, and no process holds either. Oh My
  Pi's file and session lock appear together with the first reply, and the
  process opens the file later, as the title slot fills. The lock is one per
  session, and the owners directory and session id decide its name, so it
  covers the time the file is not open, though only the program's own code has
  checked a name so far.
  Grok Build's row appears at startup, its `pid_start` is `/proc/<pid>/stat`'s
  start in clock ticks, `/new` adds a second matching row, and in leader mode
  the row still names the Terminal's process. OpenCode 2.0.32 and 2.2.5 create
  the given `ses` id's row at the first prompt. For the scan, only its one
  `SessionManager.create` call ran, on its own, and it did rewrite the
  breadcrumb.
- Confirmed on macOS 27.0.1, against processes the spike started
  ([herdr compatibility](../agents/herdr-compatibility.md)): process start from
  `ps -o lstart=`, named variables from `KERN_PROCARGS2`, open files from
  `lsof`. macOS withholds an Apple platform binary's environment, which reads
  as unavailable, and so does an asked name that a process's rewritten argv
  (Node's `process.title`) leaves indistinguishable from an argument; a title
  shorter than argv still reads. Any of these that fails leaves the program to
  its candidate list and the leak notice to show nothing.
