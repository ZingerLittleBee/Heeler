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
  takes no part.
- A check starts from the Terminal's foreground process and its descendants
  that share the Terminal's `HC_SCOPE`, so an npm or Node launcher leads to
  the real agent process. It reads only the variables it names from a process
  environment, on the Host, because environments hold secrets.
- Evidence by program, without installing anything:

  | Program | Evidence |
  | --- | --- |
  | Claude Code | `<config dir>/sessions/<pid>.json`, read by name, whose process start matches |
  | Codex | in embedded mode only, the rollout the process holds open, one root thread by `session_meta` |
  | Oh My Pi | Heeler's extension (ADR 0033); without it, `<agent dir>/terminal-sessions/<tty>`, confirmed by the process's own session lock or open file |
  | Grok Build | the one `active_sessions.json` row whose pid and process start match |
  | Pi, OpenCode | none; Heeler's extension or, on the user's word, plugin (ADR 0033) |

- A `heeler.*` label is a hint. Chat adopts it only when its pid and process
  start match the resolved agent process, and clears it when it can.
- An Agent Heeler starts carries its session from the start: `--session-id`
  for Claude Code and Pi, `-s` for Grok Build and OpenCode, and `--no-daemon`
  for Codex, which cannot be given an id; Oh My Pi relies on its extension.
  The launch also passes `TERM_PROGRAM=ghostty`, the terminal the core answers
  queries as: Grok Build asks for Program Status only in a terminal it
  recognizes, and the core's own default for a request without one could
  change. Some variables break session records or Program Status when the
  core leaks them (`CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `HERDR_*`,
  `TMUX`, `STY`, `ZELLIJ`, `CURSOR_TRACE_ID`, `VSCODE_GIT_ASKPASS_MAIN`,
  `CODEX_THREAD_ID`, `OMPCODE`). The launch blanks none of them until a test
  shows the program they affect reads a blank value as unset; until then the
  leak is reported as below.
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
  terminal fixes it. Heeler does not restart it. A Claude Code session that
  keeps no Transcript, because of `CLAUDE_CODE_CHILD_SESSION` or
  `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, says so instead of waiting for a file.
  `HERDR_*` in a herdr-core Terminal is never trusted.
- An Agent with no Program Status shows Unknown and says which release
  reports one. No status is inferred from the screen.
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
- A Transcript locator takes the config root from the Agent's own process
  environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` and the like),
  not from the Host's Default Account, which follows the core's environment.
  The two differ when the user's shell rc sets the variable.
- Unverified: Program Status from each harness inside a herdr-core terminal;
  Claude Code's registry after `/clear` and `/resume`; Grok Build's `pid_start`
  encoding and its leader mode; whether Oh My Pi's security scan rewrites the
  breadcrumb; `HC_TERMINAL_SOCKET`'s form on Windows; and whether Windows
  Transcripts are read over SFTP or the core's `file.read`.
