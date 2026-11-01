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
  before each Send, and on the Terminal's status, turn and foreground events
  and a change to its `heeler.session` or `heeler.chat` label: OpenCode 1.x
  reports no status, so its plugin's label is the only thing that says the
  conversation moved, and a label is the only sign of a choice made on another
  device or of a `/new` with no turn yet.
  Each check is at most one SFTP read and one exec on the Host, except that a
  Codex holding several rollouts costs one read of each one's first line, up to
  eight, since whether there is one root takes all of them. The Host Helper takes
  no part. No clock asks, including a Send's echo timeout, and neither does
  a Send having gone, since one check ran just before it. A leak answer that
  names a variable also asks again, since it changes what a reason says.
- A check needs something to look at. Between a link and its snapshot nothing is
  known of any Terminal, and an Agent that left its Terminal has no process, so
  there it says nothing and runs nothing, rather than that it cannot tell: the
  snapshot or the Agent's return asks again. A Send in either sends nothing.
- A check starts from the Terminal's foreground process and its descendants
  that share the Terminal's `HC_SCOPE`, so an npm or Node launcher leads to
  the real agent process. It skips Codex's shared daemon
  (`app-server --managed-daemon`) and the daemon's `app-server daemon
  pid-update-loop`, which keep the `HC_SCOPE` of the Terminal that started them
  while the daemon serves every window. It tells them by those exact arguments,
  and learns nothing else of any argv. It reads only the variables it names from a
  process environment, on the Host, because environments hold secrets. The core keeps a Terminal's scope out of its record, so the check
  reads `HC_SCOPE` from the Terminal's own process, in the same exec.
- For Claude Code the agent is the nearest of those processes that calls itself
  `claude` or a version number, past a launcher of the same name, or the
  foreground itself with nothing under it. Two equally near bind nothing, and a
  child carrying `CLAUDE_CODE_CHILD_SESSION` that its parent does not is that
  parent's tool, not the agent. Its config dir is the same process's
  `CLAUDE_CONFIG_DIR`, or `.claude` under its `HOME`.
- For Codex, Grok Build and OpenCode the agent is the nearest of those processes
  named `codex`, `grok` or `opencode`, or the foreground itself with nothing under
  it, and Grok Build's leader and OpenCode's service stay below it. Two equally near
  bind nothing. Codex's and Grok Build's config roots follow Claude Code's rule, with
  `CODEX_HOME` and `GROK_HOME`.
- Evidence by program, without installing anything:

  | Program | Evidence |
  | --- | --- |
  | Claude Code | `<config dir>/sessions/<pid>.json`, read by name once Claude Code reaches its prompt, whose process start matches |
  | Codex | in embedded mode only, the rollouts the process holds open, exactly one of them a root thread by `session_meta`, and no thread-writer lock held without its thread's rollout |
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
  the same id, which is what ties the two together: OpenCode binds from the label
  only while the foreground's own argv holds `-s` and that id, so a shell or another
  program in the Terminal does not count. On a core a Grok Build id may be the UUIDv4
  Heeler started it with, where Herdr TUI's reference takes only the UUIDv7 Grok
  Build creates itself.
- An OpenCode's argv keeps the id it started with when `/new` and a prompt, or a
  pick in its list, move the screen, so a check of its process still binds the old
  conversation. Its terminal title does change, so a Send compares it as ADR 0025
  does, after the check, and reads it from the core's title events. It refuses on
  another `OC | ` title. It also refuses on `OpenCode` over a conversation with a
  title of its own, which ADR 0025 lets through because herdr reports the
  conversation that title may stand for, and a core reports none. The screen read
  before each Send still holds OpenCode's home screen.
- ADR 0025's start-screen watch does not run on a core. A clock paces it and
  herdr's report ends it, and a core has neither, so Chat keeps showing the
  conversation OpenCode started with until the program is started again, and only a
  Send says the screen left.
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
- Candidates serve every program whose Chat binds on core, and only a Chat that
  already says it cannot tell offers them, on request. A list costs one exec, as
  a check does, then the listings it takes: a directory's folder, or for OpenCode
  a read-only query of its roots there, and for Codex the heads of its newest
  rollouts, up to 24, since Codex files by day. A process walk past its cap lists
  nothing, because a launcher would pass for the Agent and a daemon under it would
  go unseen. A Status child is listed only when
  its key reads as this program's session id, and such a record may name another
  Terminal's session (herdr compatibility), which is why the user reads it first.
  A confirmation needs a candidate whose conversation was read, goes through the
  mutation dispatch to the core its list came from, and is not repeated when no
  answer comes. A device the guard has dropped a pick on remembers that value, so
  a label whose removal failed, reported again, is removed again and not adopted.
  It remembers only until the core reports the label gone or holding another
  value, in an event or a fresh inventory. After that the same value is the same
  conversation confirmed again, here or on another device, and is adopted. A link
  that was down through that gap cannot tell the two apart and removes the label
  once more; having seen that removal, the device adopts the next confirmation.
  The guard judges only after a turn the core reported: a read must start at
  least two seconds after the turn ends, a `/` command does not arm it, and a
  message the program put back or refused proves nothing. Neither does one the
  Composer cannot say went, because it stayed in the input box or a step got no
  answer, unless the program's own log says another session took it. A program
  that reports no status never ends a turn, so its pick stays until the process
  changes.
- A dropped pick leaves the screen, unlike an exact binding that goes quiet, which
  keeps its last document readable because nothing says it was wrong. A pick was
  only the user's word, and a drop says that word no longer holds. A check that
  cannot see the process to hold the label against (no scope to follow, a walk
  past its cap that leaves the process out, a start it could not read, an Agent
  that cannot be told apart, a process that cannot say where its Transcripts are)
  drops nothing: the label stands, the conversation stays under a banner with its
  send guard armed, and a Send is refused until a check can say.
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
  extensions' labels, adopted only on a pid and creation-time match), each once
  tested on a Windows Host and listed in
  `HostCapabilities.confirmedWindowsCoreChatPrograms`; Codex and OpenCode follow
  later. Native
  Windows Herdr TUI Hosts stay without Chat. Codex, Grok Build and OpenCode from 2.x
  are built for Linux from the recordings below, which never saw a signed-in
  account. Each stays off in `HostCapabilities.confirmedCoreChatPrograms` until its check with a harness
  the owner signs in to passes, and one that fails stays off with its observation
  saying why.

This amends ADR 0024, and ADR 0025's source of the OpenCode session id, its
start-screen watch and what its confirmation makes of the title `OpenCode`, for
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
- An OpenCode bound from the id it was started with has no guard to move Chat after
  `/new` or a pick, only the title check that stops a Send. That check cannot help
  with `terminal.title` off, which writes no title, or while Chat's conversation has
  no title, since a new untitled one reads `OpenCode` as well, so those Sends reach
  whatever the screen shows, unless that is the home screen. It can also refuse wrongly
  and briefly: OpenCode writes `OpenCode` until a session it just opened has loaded, and a
  conversation titled since Chat's last read looks like another until the next.
- `/new` moves Codex's screen before anything on the Host says so. Until a prompt
  there it holds only the old thread's rollout and lock, the same as before `/new`,
  so Chat keeps showing the old conversation and a Send reaches the new one. A check
  of what it holds cannot catch this, and rollout times, `threads.updated_at` and
  `logs_2.sqlite` order threads by activity, which does not say what is on screen.
- The first prompt after `/new` leaves the new thread's lock with no rollout, and
  the next adds the rollout, so Codex holds two roots. Either binds nothing, and Chat
  says so from its next check until the program is started again. That first prompt
  showed no turn, so a Send's own check may be what finds it.
- A subagent's lock before its rollout reads the same as `/new`'s. No recording
  shows that order, and it would read as can't tell until a later check.
- After `/new`, Grok Build has two matching rows and nothing says which the screen
  shows, so it binds nothing and Chat says so until the program is started again.
- OpenCode has no row for its id until the first prompt, which Heeler knows the id
  before. A core's store with no such row, on a Chat that has followed nothing yet,
  waits for the first message rather than reading as a session gone.
- Ending the Terminal that started Codex's shared daemon ends the daemon, and
  every other default-mode Codex on the same `CODEX_HOME` loses its backend
  while it keeps reporting its last status, such as Idle or Done.
- Oh My Pi reports Idle while its sign-in waits, so that sign-in shows as
  Idle, not Blocked.
- Oh My Pi's breadcrumb names a session file before the file exists and
  outlives the process on a reused terminal name, so without the extension an
  Oh My Pi Agent binds only once its first message opens the file. The lock is
  not a check here, since no read-only one exists while its hash is unknown, so
  the window between the file appearing and opening reads as cannot tell.
- A Pi that Heeler started and that has no extension binds from the launch hint
  only while it is still the Terminal's own process, so a launcher in front of
  it needs the extension. That binding names the launch's session, so it is the
  in-process `/new` case above.
- `terminal.label` has no compare, so clearing a stale label can remove the one
  the next Agent wrote in the same moment. Heeler judges labels after its exec
  and compares again before clearing. That leaves one round trip, and a Pi or
  Oh My Pi Agent caught in it reads as cannot tell until its extension next
  writes, at the next session.
- A confirmed pick for a Pi without the extension, or an OpenCode without the
  plugin, cannot see an in-process `/new`: nothing on the Host changes. Chat shows
  the old conversation until the send guard drops it, and the user guide says so.
  OpenCode's terminal title still refuses a Send while it names another
  conversation, and a refused Send arms no guard.
- A Transcript locator takes the config root from the Agent's own process
  environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` and the like),
  not from the Host's Default Account, which follows the core's environment.
  The two differ when the user's shell rc sets the variable.
- Unverified: whether Oh My Pi's security scan leaves the breadcrumb rewritten,
  since the scan needs a stored OAuth account; whether a signed-in account
  changes any of the evidence below, which never saw one; whether Claude Code's
  `procStart` on macOS equals the start `ps -o lstart=` prints; whether a Host
  can work out an Oh My Pi lock's name without running its code, since the hash is not
  identified; and whether Heeler's OpenCode store query reads what OpenCode 2.2.5
  really writes. It runs against both recorded schemas, on rows of 2.0.32's shape
  put there by a test, and 2.2.5's own rows and `session_part` were not read. Owner
  confirmation with a signed-in
  harness on hc-lab remains available, and is listed in #578's Owner acceptance.
- Settled with a local fake model and no sign-in, in a throwaway Linux VM and
  not on hc-lab ([herdr compatibility](../agents/herdr-compatibility.md), which
  says what could differ for each program;
  `Tests/HeelerTests/ChatFixtures/host-evidence`): Codex's embedded native
  process holds the rollout open from the first prompt, and its `session_meta`
  tells a root from a subagent; after `/new` and a prompt that landed it holds two
  roots, so one root thread binds nothing, and the lock held without a rollout
  before that binds nothing either. Pi 1.4.0's file appears at the first prompt, before the
  reply, Pi 0.85.1's only with the reply, and no process holds either. Oh My
  Pi's file and session lock appear together with the first reply, and the
  process opens the file later, seen in one sample with the title slot filling,
  which does not show cause. The lock is one per
  session, and the owners directory and session id decide its name, so it
  covers the time the file is not open, though only the program's own code has
  checked a name so far.
  Grok Build's row appears at startup, its `pid_start` is `/proc/<pid>/stat`'s
  start in clock ticks, `/new` adds a second matching row, and in leader mode
  the row still names the Terminal's process. OpenCode 2.0.32 and 2.2.5 create
  the given `ses` id's row at the first prompt the prompt box takes; on 2.2.5 one
  sent before the box appeared left no row. For the scan, only its one
  `SessionManager.create` call ran, on its own, and it did rewrite the
  breadcrumb.
- On native Windows `HC_TERMINAL_SOCKET` holds the pipe path,
  `\\.\pipe\herdr-core-<user>-<session>.sock`, and Node's `net.connect` reaches
  it and gets a plain JSON-RPC reply
  ([observation](../agents/herdr-compatibility.md)), so the extensions connect
  by that value as they do to a Unix socket (#590). Pi and Oh My Pi themselves
  have not run there.
- Windows Transcripts are read over SFTP, the reader Unix already uses. Through
  sshd from a Mac, with a program in a Terminal appending, SFTP and `file.read`
  each returned bytes that were a prefix of the final file at every round, and
  the final file matched Windows' own hash
  ([observation](../agents/herdr-compatibility.md)). SFTP also read a non-UTF-8
  file, a single 9 MiB line and a 65 MiB file unchanged, where `file.read`
  refused each (`not_text`, `line 1 is over 8 MB`, `is over 64 MB`) and paged a
  9 MiB file by lines. That is why SFTP stays the path. A writer that shares
  nothing fails both. This is one machine and an elevated SSH token, on made-up
  files: no real Agent's Transcript has been read on Windows.
- Under PowerShell the foreground's pid is never the Agent's, so #590 binds
  through PowerShell's children, not through the foreground's pid. A session
  registry entry on Windows has not been read.
- The rules hold on Windows in the same costs: one exec, here
  `HostProcessReader.windowsCommand`, and at most one read, named variables only,
  never a `.key` file. Windows names a process by its image and a program cannot
  retitle itself, so under npm the Agent is a `node.exe` or `bun.exe`: the binder
  takes the nearest process named for the program, else for Claude Code, Pi and
  Oh My Pi the nearest runtime, with no following past it, and never the PowerShell.
  A wrong pick binds nothing, because what proves the Agent is still its pid and
  start against what the program recorded, and Grok Build gets no runtime rule since
  it is a native binary. Under `npx` the nearest runtime is the launcher, so Chat
  says it can't tell. Pi's launch hint and Oh My Pi's breadcrumb do not apply: the
  launch runs under PowerShell, and open files are not read. Chat's cannot-tell there
  is its own reason, `cannotTellSessionOnWindows`, which never offers the Helper,
  and offers no candidates yet: open files are not read there, and no listing of a
  Windows directory's Transcripts has been checked against a real one.
- Confirmed on macOS 27.0.1, against processes the spike started
  ([herdr compatibility](../agents/herdr-compatibility.md)): process start from
  `ps -o lstart=`, named variables from `KERN_PROCARGS2`, open files from
  `lsof`. macOS withholds an Apple platform binary's environment, which reads
  as unavailable, and so does an asked name that a process's rewritten argv
  (Node's `process.title`) leaves indistinguishable from an argument; a title
  shorter than argv still reads. Any of these that fails leaves the program to
  its candidate list and the leak notice to show nothing.
