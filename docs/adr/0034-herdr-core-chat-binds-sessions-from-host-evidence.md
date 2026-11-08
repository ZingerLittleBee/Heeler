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
  a Send having gone, since one check ran just before it, with the one
  exception below. A leak answer that names a variable also asks again, since
  it changes what a reason says.
- The exception: Grok Build and an Oh My Pi without its extension write their
  evidence just after they report idle, so while Chat is open and can't tell, an
  idle report asks once more a few seconds later, 3 s for Grok Build and 10 s
  for Oh My Pi, and nothing repeats it. On hc-lab on 2026-11-03 Grok Build
  1.0.70 wrote its `active_sessions.json` row 0.18 s after the core's first
  idle, and Oh My Pi 18.13.3 held its session file 8.6 s after the first
  message, about 6 s after the file appeared holding the finished turn; each
  stayed Can't Tell until Check Again. An Oh My Pi whose title model returns no
  title never opens its file (seen once), and stays Can't Tell.
- A check that moves Chat to another conversation of an exact binding, with no
  Send waiting on it, holds the next Send once, as a Send whose own check moves
  Chat does, unless the draft changed since: the draft may have been written for
  the conversation Chat showed. On hc-lab on 2026-11-02, `/clear` moved Claude
  Code 2.1.316's registry entry with no status change, an event's check moved
  Chat, and a draft from before went into the new conversation 7 s later.
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
  and learns nothing else of any argv, past a macOS name (below). It reads only the variables it names from a
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
  `CODEX_HOME` and `GROK_HOME`. Antigravity CLI's agent is found the same way by the
  name `agy`; a binding's root is the one its lock's path names, and a pick's and the
  candidate list's is `.gemini/antigravity-cli` under its `HOME`, since no variable is
  known to move it.
- Evidence by program, without installing anything:

  | Program | Evidence |
  | --- | --- |
  | Claude Code | `<config dir>/sessions/<pid>.json`, read by name once Claude Code reaches its prompt, whose process start matches |
  | Codex | in embedded mode only, the rollouts the process holds open, exactly one of them a root thread by `session_meta`, and no thread-writer lock held without its thread's rollout |
  | Oh My Pi | Heeler's extension (ADR 0033); without it, `<agent dir>/terminal-sessions/<tty>`, confirmed by the process holding that file open |
  | Grok Build | the one `active_sessions.json` row whose pid and process start match |
  | OpenCode | from 2.1, the `ses` id Heeler started it with; otherwise none, and the plugin on the user's word (ADR 0033) |
  | Pi | none; Heeler's extension (ADR 0033) |
  | Antigravity CLI | the one `<data root>/presence/<id>.lock` the process holds open |

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
  which cannot be given an id. Oh My Pi relies on its extension, and Antigravity
  CLI on its lock, since agy 1.5.3 warns that `--conversation <new id>` is not found
  and creates nothing under it. OpenCode 1.x's
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
- An OpenCode's argv keeps the id it started with when `/new` and a prompt move the
  screen, and a pick in its list is expected to do the same, so a check of its process
  still binds the old conversation. By a source review of 2.2.5, which ran nothing, its
  terminal title changes, so a Send compares it as ADR 0025 does, after the check, and reads it from the core's title events. It refuses on
  another `OC | ` title. It also refuses on `OpenCode` over a conversation with a
  title of its own, which ADR 0025 lets through because herdr reports the
  conversation that title may stand for, and a core reports none. The screen read
  before each Send still holds OpenCode's home screen.
- ADR 0025's start-screen watch does not run on a core. That watch reads the screen
  on a clock and herdr's report ends it, and a core reports no such thing. A core's
  `title` event would say the screen left with neither, pushed and with no exec, but
  Chat does not act on it, so Chat keeps showing the conversation OpenCode started
  with until the program is started again, and only a Send says the screen left.
  On 2026-11-02 the owner kept it this way for now.
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
  with `codex resume --no-daemon`, picking the session in Codex's own list. A
  Pi or Oh My Pi whose own extension folder already holds Heeler's extension,
  and that wrote no label, is told it hasn't loaded it rather than to install
  the Helper: it runs with its extensions turned off, which its arguments name
  when they still show `--no-extensions` (Oh My Pi's own, or the Terminal's for
  a Pi it started, since Pi's title overwrites its own), or it started before
  the extension was there. That costs one SFTP read when nothing else binds. If
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
  a read-only query of its roots there, whose store problem replaces the list, and for Codex the heads of its newest
  rollouts, up to 24, since Codex files by day. A process walk past its cap lists
  nothing, because a launcher would pass for the Agent and a daemon under it would
  go unseen. A Status child is listed only when
  its key reads as this program's session id, and such a record may name another
  Terminal's session (herdr compatibility), which is why the user reads it first.
  A confirmation needs a candidate whose conversation was read, goes through the
  mutation dispatch to the core its list came from, and is not repeated when no
  answer comes. A device the guard has dropped a pick on remembers that value, also
  when the verdict lands between links and only the last inventory held it, so a
  label whose removal failed is removed again at that device's next check, or when
  it is reported again, and not adopted.
  It remembers only until the core reports the label gone or holding another
  value, in an event or a fresh inventory. After that the same value is the same
  conversation confirmed again, here or on another device, and is adopted. A link
  that was down through that gap cannot tell the two apart and removes the label
  once more; having seen that removal, the device adopts the next confirmation.
  The guard judges only after a turn the core reported: a read must start at
  least two seconds after the turn ends and reach the end of what the source holds,
  a message read past by a source reopened at its tail proves nothing, a `/`
  command does not arm it, and a
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
  with `CLAUDE_CODE_CHILD_SESSION=1` keeps neither a registry entry nor a
  Transcript, and one with `CLAUDE_CODE_SKIP_PROMPT_HISTORY` keeps an entry and
  no Transcript; Chat says so instead of waiting for a file. Claude Code reads
  the first one's value: 2.1.316 ignored `made-up` and kept both, so with that
  variable Chat says so only when no registry entry turned up, and binds by the
  entry when one did (#579). `HERDR_*` in a
  herdr-core Terminal is never trusted.
- An Agent with no Program Status shows Unknown and says which release
  reports one where that is known
  ([herdr compatibility](../agents/herdr-compatibility.md)). A
  Terminal that has reported but holds no state, as Claude Code leaves it
  before sign-in, has none. No status is inferred from the screen.
- Chat covers the seven programs it reads today. Codex, Grok Build, OpenCode from
  2.x, Pi and Oh My Pi are built for Linux and macOS core Hosts from the
  recordings below, made with no sign-in. On native Windows herdr-core Hosts the
  candidates are Claude Code and Grok Build (session registry plus the Windows
  process tree and creation times) and Pi and Oh My Pi (their extensions' labels,
  adopted only on a pid and creation-time match); Codex and OpenCode follow
  later. Antigravity CLI binds on Linux and macOS from its lock and is on both
  their lists, and never a Windows candidate, since Windows reads no open file.
  Native Windows Herdr TUI Hosts stay without Chat. Each kernel keeps its
  own list, `HostCapabilities.confirmedLinuxCoreChatPrograms`,
  `confirmedMacOSCoreChatPrograms` and `confirmedWindowsCoreChatPrograms`, and a
  program joins one only once its check with a harness the owner signs in to
  passes on that kernel, on the versions its ticket names: Chat shows the
  conversation and sends from Chat. A program that binds only after Check Again
  has a defect to fix, not a failed check; a bound Agent that shows no messages
  fails. One that fails stays off there with its observation saying why
  ([herdr compatibility](../agents/herdr-compatibility.md)).
  On 2026-11-02 the owner's Mac passed Codex, Grok Build, Pi and Oh My Pi, which
  the owner turned on for macOS beside Claude Code; OpenCode 2.0.32 from New Agent
  reached only candidates there, and 2.1 or later was not run, so it stays off on
  macOS. On 2026-11-03 hc-lab passed Codex 0.165.0 with `--no-daemon`, Grok Build
  1.0.70, Pi 1.4.0 and Oh My Pi 18.13.3, which the Linux list now holds beside
  Claude Code, though a Grok Build whose Chat opened before its first message,
  and an Oh My Pi without the extension, each bound only after Check Again, which
  the one later check above now covers, and a Pi started from a Template left no
  saved evidence of its reply. On the 2026-11-04 recheck on hc-lab both bound
  with no Check Again, though each Grok Build Chat opened after its row was
  written, and the Oh My Pi with its title model answering.
  OpenCode stays off on Linux, since one switch covers every release. On
  2026-11-03 2.2.2 passed, but a 1.19.5 Agent bound through Heeler's plugin
  showed no messages, since Chat read only 2.x's tables. Chat now reads 1.x's own
  tables (ADR 0025). On the recheck 2.2.2 passed again, and a 1.19.5 started by
  hand with `-s` and the launch label showed its conversation, but every Send
  from Chat was refused as finding no input box on screen, and its last turn
  never ended in Chat (watched about 28 minutes), since, by Heeler's source, a
  1.x session has no `idle` row and a turn read from its tables ends only at the
  next prompt. Started as New Agent starts 1.x, without
  either, its conversation could not be told.
  On 2026-11-03 the owner's Windows machine passed Claude Code 2.1.286 and
  2.1.316 and Pi 1.4.0 with the extension. Oh My Pi 18.13.3 bound, but every
  Send from Chat was refused as finding no input box on screen, because under its
  profile the band read `π-hwa > `, and Grok Build 1.0.70 could not bind, since
  its rows there carry no `pid_start`. Once the send check knew that band and
  Chat matched `opened_at` against the process's creation, the 2026-11-04
  recheck there passed Grok Build 1.0.70 and Oh My Pi 18.13.3, with a profile
  and without, so the Windows list holds Claude Code, Grok Build, Pi and Oh My
  Pi. Codex and OpenCode were not run on Windows.
  On 2026-11-08 the owner's Mac passed Antigravity CLI 1.5.3, started with colors
  and with `NO_COLOR` in herdr-core 0.1.18 Terminals, and the owner turned it on
  for macOS. On 2026-11-09 a Linux VM passed it in herdr-core 0.1.18 Terminals,
  and it joined Linux's list (below).

This amends ADR 0024, and ADR 0025's source of the OpenCode session id, its
start-screen watch, what its confirmation makes of the title `OpenCode` and its
rule that every row read is filtered on one session id, which the candidate
list's query of a directory's roots is not, for herdr-core Hosts only.

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
  waits for the first message rather than reading as a session gone. Chat's query
  sees only the exec's environment, so an OpenCode whose `OPENCODE_DB` or
  `XDG_DATA_HOME` is set only where it runs, on a Host that also has the default
  database, looks the same: Chat waits until a message from Chat goes unrecorded past
  its echo timeout, then says ADR 0025's Conversation Not Found. A message sent only
  from the terminal does not end the wait, and a Send after it is refused on the
  terminal's title, which then names this very conversation.
- Grok Build writes its row and session folder as it starts, and `updates.jsonl` with
  the first message, so a Chat that has followed nothing waits for that message too.
  A search cut short by a listing limit reads the same way. Pi and Oh My Pi wait on an
  id the same way, searching their own folders on every pass and every project's once
  per activity, as Claude Code does.
- Ending the Terminal that started Codex's shared daemon ends the daemon, and
  every other default-mode Codex on the same `CODEX_HOME` loses its backend
  while it keeps reporting its last status, such as Idle or Done.
- Oh My Pi reports Idle while its sign-in waits, so that sign-in shows as
  Idle, not Blocked.
- Oh My Pi's breadcrumb names a session file before the file exists and
  outlives the process on a reused terminal name, so without the extension an
  Oh My Pi Agent binds only once its first message opens the file. The lock is
  not a check here, since no read-only one exists while its hash is unknown, so
  the window between the file appearing and opening reads as cannot tell. On
  hc-lab on 2026-11-03, with Oh My Pi 18.13.3 and a real provider, the open
  followed the title model, seen once each way: a process whose title came back empty did not open its file in the 2.5
  minutes before it exited, so it could not bind this way.
- A Pi that Heeler started and that has no extension binds from the launch hint
  only while it is still the Terminal's own process, so a launcher in front of
  it needs the extension. That binding names the launch's session, which an
  in-process `/new` leaves with nothing on the Host saying so, so the send guard
  watches it as it does a pick: a message missing once a turn ends drops the
  hint, clears the label, and the device does not adopt that id again, while a
  check that cannot see the process leaves it standing, as it does a pick. On
  hc-lab on 2026-11-03 a Send from Chat after `/new` read **Sent. It hasn't
  appeared in the conversation yet.** six minutes later, with no guard.
- A `pi` wrapper script around a real `pi` reads as the Agent, being the nearest of
  that name, and its child might be a subagent, so nothing tells them apart. Such a
  Terminal says can't tell, and a label from the child stays, since it would never be
  written again. Only a process of the Agent's name below the foreground keeps a label
  this way. No recording shows this tree.
- A launch's id and the file a label names for it are one conversation, so the label's
  arrival neither rebuilds what Chat reads nor refuses a Send.
- `terminal.label` has no compare, so clearing a stale label can remove the one
  the next Agent wrote in the same moment. Heeler judges labels after its exec
  and compares again before clearing. That leaves one round trip, and a Pi or
  Oh My Pi Agent caught in it reads as cannot tell until its extension next
  writes, at the next session. Closing it needs a compare in the core, or the
  extension writing its label every turn, a Helper change with a version bump.
  On 2026-11-02 the owner left it open for now.
- A confirmed pick for a Pi without the extension, or an OpenCode without the
  plugin, cannot see an in-process `/new`: nothing on the Host changes. Chat shows
  the old conversation until the send guard drops it, and the user guide says so.
  OpenCode's terminal title still refuses a Send while it names another
  conversation, and a refused Send arms no guard.
- Antigravity CLI 1.5.3 holds `<data root>/presence/<id>.lock` under an exclusive
  lock for the conversation on its screen: from the first prompt of a new one, which
  is when the conversation first exists, and from about 0.2 s after start for one
  resumed by id. `/clear` and `/fork` move it at once and keep the folder and database
  of the conversation left behind open, so only a held lock binds and those never do;
  `/exit` releases it. Lock files stay after their process, so one on disk proves
  nothing. A second agy opened on a conversation already open never holds the lock,
  so it says it cannot tell; on macOS it holds that conversation's folder and
  database, and lists those for one confirmation. Its list also holds the
  conversation that the Terminal foreground's argv names with `--conversation <id>`
  or `--conversation=<id>`, read from the core's record and counted only while that
  foreground is the agy the check found: on Linux (2026-11-09, Ubuntu 24.04.5,
  herdr-core 0.1.18, agy 1.5.3), read through `/proc/<pid>/fd`, neither agy held
  that conversation's folder open, and each held its database only for about 30 s
  after it started, the first then holding only its lock, so without the argv a
  list opened after that named nothing. The check's exec still
  learns nothing of agy's argv. Its list has nothing from a directory: agy files
  conversations by id, and `history.jsonl`, which names a workspace, is one log for
  every agy on the data root and names no id for a fresh launch's first prompt.
  `/clear` from idle reports no status, so Chat keeps showing the conversation before
  it until the next status or the check before a Send, which moves Chat and holds
  that Send once.
  Seen on 2026-11-07 on one signed-in Mac, macOS 27.0.1, in a plain PTY outside herdr
  and herdr-core, the open files through `HostProcessReader`'s own macOS read
  (`host-evidence/agy`). In herdr-core 0.1.18 Terminals on macOS 27.0.1, with the
  Herdr desktop app 0.1.13 (2026-11-08), the same held: a fresh agy, from New Agent
  or typed in a Terminal, held no lock before its first prompt and exactly one from
  it, `/clear` moved the lock at once, and a second agy opened with `--conversation`
  on a conversation another agy had open held its folder and database but not the
  lock, and its Chat listed that one conversation for one confirmation. A `/clear`
  after a finished turn had Chat on the new conversation before any Send, so the
  check before a Send went unexercised, again on a second run that day, where the
  Send that followed went in unheld. agy's environment there carries the Terminal's
  `HC_SCOPE` and whatever the core's `herdr-core hold` process carries
  ([herdr compatibility](../agents/herdr-compatibility.md)): on the first run a
  `NO_COLOR` among them, under which agy draws no colors (ADR 0024). On the second
  run the hold carried none and agy drew in color, and a `NO_COLOR=1 agy` typed in
  a Terminal drew none. With each, Chat answered the trust prompt, a command, a file
  creation and edit, a two-question form with Skip and a multi-select question from
  cards, sent from Chat with no hold for the input box, held a message while agy
  worked, and stopped a turn. An agy typed in a Terminal lists as an Agent titled
  with the Terminal's title, where New Agent's reads `Antigravity`.
  agy reports Program Status from 1.4.0 as `app=antigravity`, which the Agent rule
  now reads as agy's, and at every start sends `blocked` with `kind=auth` about
  50 ms before `idle`, signed in. On a core it reports each dialog as `blocked`:
  `kind=permission` for the trust prompt, a command and a file creation or edit
  (herdr 0.9.5 reads the file dialogs from the screen as done), and `kind=question`
  for a question. A start at the trust prompt sent `kind=auth`, then the prompt's
  `kind=permission`, with no `idle` between: 4.8 s apart on the second run's start
  in color, and 0.03 s apart under `NO_COLOR`. Through the 4.8 s Heeler showed
  Blocked, for about 2 s of it with an unreadable Waiting for Input card, since
  nothing in Heeler debounces the report.
  On a Linux VM, Ubuntu 24.04.5 on x86_64, with herdr-core 0.1.18 started from
  Heeler's **Start herdr-core** under user systemd and no desktop app, and agy 1.5.3
  signed in (2026-11-09), the owner's check passed, and Antigravity CLI joined
  Linux's list. The hold carried no `NO_COLOR`. The lock read through
  `/proc/<pid>/fd` bound an agy from New Agent, drawn in color, a typed `agy` and a
  typed `NO_COLOR=1 agy`, which drew none, each from its first prompt sent in the
  terminal, and `/clear` moved Chat to the new conversation before any Send, in
  color and under `NO_COLOR`. No agy there held a conversation's folder open, and
  one held its database (with `-wal` and `-shm`) only for a while, right after a
  first prompt but not 41 s after one, and for about 30 s after a start with
  `--conversation`, then its lock alone. A second agy on a conversation already open
  listed it from the argv, above, in both forms, and choosing it showed that
  conversation. A start at the trust prompt, from New Agent or typed, sent no
  `kind=auth`: the core's first status was the prompt's `blocked` `kind=permission`,
  for New Agent 0.4 s after its Terminal's creation, so no unreadable card showed. A
  trusted start with `--conversation` sent `kind=auth` and `idle` 0.8 s later, and
  the second and third agy on that conversation sent `idle` alone. In color and
  under `NO_COLOR`, Chat answered the trust prompt, a command, a file creation and
  edit, a two-question form with Skip and a multi-select question from cards, sent
  from Chat with no hold for the input box, held a message while agy worked and
  stopped a turn. That held message showed **Sending** for about 1.5 to 2.5 s before
  the hold replaced it, and nothing reached agy. Stop ended the turn but not a
  command agy had moved to the background, which ran to its end. Not seen: `/resume`
  and `/rewind`, whether `--remote-control` leaves a second process named `agy` in
  the Terminal, and whether the Host Helper notifies on the auth report.
- A Transcript locator takes the config root from the Agent's own process
  environment (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME` and the like),
  not from the Host's Default Account, which follows the core's environment.
  The two differ when the user's shell rc sets the variable.
- Unverified: whether Oh My Pi's security scan leaves the breadcrumb rewritten,
  since the scan needs a stored OAuth account, which neither the VM nor hc-lab's
  signed-in run had; whether OpenCode's terminal title moves on a pick as 2.2.5's
  source says and equals its conversation's title, since on hc-lab 2.2.2's title
  was seen only to move to `OpenCode` on `/new` and to `OC | ` and the stored
  title at a turn's end, with Sends refused on the title after `/new`, and 2.2.5
  itself was not run there; whether a pick keeps the argv as `/new` does,
  which no run recorded, and whether the home screen check, from 2.0.32's screen,
  holds on 2.2.5; whether a Host can work out an Oh My Pi lock's name without
  running its code, since the hash is not identified; whether Oh My Pi ever opens
  its file when its title model returns nothing, which one run did not do in 2.5
  minutes; and whether Heeler's OpenCode store query reads what OpenCode 2.2.5
  really writes. The query read 2.2.2's own rows on hc-lab, and 2.2.5's own rows
  were not read.
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
- Settled with signed-in harnesses and real providers on hc-lab, Debian 13 with
  herdr-core 0.1.13, on 2026-11-03 (#578, [herdr
  compatibility](../agents/herdr-compatibility.md)): what the VM showed held
  except as noted here. A signed-in Codex 0.165.0 with `--no-daemon` holds its one
  root rollout from just after the prompt, and `session_meta` also carries the
  account's creator ids, which a fixture must scrub. Unlike the VM, the first
  message after its `/new` showed a turn and created and held the new rollout,
  beside the old one. The shared daemon can be an older
  release than the CLI and can update itself, and one that did outlived the
  `/quit` of the Codex that started it and kept its thread loaded, so the reopen
  message's `codex resume --no-daemon` was refused until `codex app-server daemon
  stop`. Grok Build's row is there at startup with `pid_start` as field 22 and no
  leader, but it came 0.18 s after the core's first `idle`, so a Chat opened before
  the first message did not check again by itself. OpenCode 2.2.2 with a real
  provider wrote no `session_part` rows and keeps the reply in `session_message`.
  Pi 1.4.0's file appears before the reply and nothing holds it. Oh My Pi
  18.13.3's file and lock appear together, `fresh` goes in the same sample, and no
  lasting child runs, while its open of the file followed the title model (above). Heeler's OpenCode plugin is listed in `cli.json` `plugins` on 2.2.2 and
  `tui.json` `plugin` on 1.19.5, and 1.19.5 reports no Program Status.
- On native Windows `HC_TERMINAL_SOCKET` holds the pipe path,
  `\\.\pipe\herdr-core-<user>-<session>.sock`, and Node's `net.connect` reaches
  it and gets a plain JSON-RPC reply
  ([observation](../agents/herdr-compatibility.md)), so the extensions connect
  by that value as they do to a Unix socket (#590). On 2026-11-03, on one
  machine, Pi 1.4.0 running as `node.exe` and Oh My Pi 18.13.3 running as
  `omp.exe` loaded the extension from the folders Heeler wrote and labeled their
  Terminals with a `start` equal to the creation time.
- Windows Transcripts are read over SFTP, the reader Unix already uses. Through
  sshd from a Mac, with a program in a Terminal appending, SFTP and `file.read`
  each returned bytes that were a prefix of the final file at every round, and
  the final file matched Windows' own hash
  ([observation](../agents/herdr-compatibility.md)). SFTP also read a non-UTF-8
  file, a single 9 MiB line and a 65 MiB file unchanged, where `file.read`
  refused each (`not_text`, `line 1 is over 8 MB`, `is over 64 MB`) and paged a
  9 MiB file by lines. That is why SFTP stays the path. A writer that shares
  nothing fails both. That was one machine and an elevated SSH token, on made-up
  files. On 2026-11-03 the same machine's Chat showed real Claude Code, Pi and Oh
  My Pi conversations read this way.
- Under PowerShell the foreground's pid is never the Agent's, so #590 binds
  through PowerShell's children, not through the foreground's pid. Claude Code
  2.1.286 and 2.1.316 there wrote the creation FILETIME as decimal digits in
  `procStart`, with no `procStartFt`, though 2.1.316's source text was read as
  naming `procStartFt`; the binder takes `procStartFt` and falls back to
  `procStart`, and bound both.
- The check of a core's own leaked variables reads the same way on Windows: one
  `HostProcessReader.windowsCommand` per link, names only, and any failure reads as
  no names. On 2026-11-03 an elevated SSH token's read named `CLAUDECODE` and
  `HERDR_CHECK` in a core started without elevation in the desktop session; a
  core the token cannot read was not tried, so no notice there still proves
  nothing.
- The rules hold on Windows in the same costs: one exec, here
  `HostProcessReader.windowsCommand`, and at most one read, named variables only,
  never a `.key` file. Windows names a process by its image and a program cannot
  retitle itself, so under npm the Agent can be a runtime: Pi 1.4.0 ran as
  `node.exe`, while npm Claude Code 2.1.316 ran its package's native `claude.exe`,
  and Oh My Pi 18.13.3, a binary install, ran as its own `omp.exe`. The binder
  takes the nearest process named for the program, else for Claude Code, Pi and
  Oh My Pi the nearest runtime, with no following past it, and never the PowerShell.
  A wrong pick binds nothing, because what proves the Agent is still its pid and
  start against what the program recorded, and Grok Build gets no runtime rule since
  it is a native binary; its 1.0.70 rows there carry no `pid_start`, only
  `opened_at`, so there a row of the Agent's pid proves it when it was opened no
  earlier than the process's creation FILETIME, which a row a reused pid's earlier
  process left cannot be. Under `npx` Claude Code 2.1.316 reported status and
  its record matched, but the Terminal was not listed as an Agent at all, so Chat
  had nothing to say; the Agent rule now reads `npx` (ADR 0032), and on the
  2026-11-04 recheck such an Agent bound and sent from Chat. Pi's launch hint and
  Oh My Pi's breadcrumb do not apply: the launch runs under PowerShell, and open
  files are not read. Chat's cannot-tell there
  is its own reason, `cannotTellSessionOnWindows`, which never offers the Helper,
  and offers no candidates yet: open files are not read there, and no listing of a
  Windows directory's Transcripts has been checked against a real one. A process read
  that failed, as across an elevation mismatch or under constrained language mode,
  reads as `cannotReadProcessesOnWindows`, which offers Check Again and not the
  extension, since adding that would not change the read.
- Confirmed on macOS 27.0.1, against processes the spike started
  ([herdr compatibility](../agents/herdr-compatibility.md)): process start from
  `ps -o lstart=`, named variables from `KERN_PROCARGS2`, open files from
  `lsof`. macOS withholds an Apple platform binary's environment, which reads
  as unavailable, and so does an asked name that a process's rewritten argv
  (Node's `process.title`) leaves indistinguishable from an argument; a title
  shorter than argv still reads. Open files or an asked name that cannot be read
  leave the program to its candidate list and the leak notice to show nothing. What
  a confirmation binds to has no such fallback: a start that cannot be read, or an
  environment withheld between the foreground and the Agent, reads as cannot tell
  with no list, because a list would bind to no process or to the launcher's pid.
  On the owner's Mac, macOS 27.0.1 with SIP on and a clock eight hours ahead of UTC,
  native Claude Code 2.1.316's `procStart` equalled that start read in UTC with its
  trailing spaces trimmed, started from New Agent and by hand under `/bin/zsh -l`,
  as it had in a macOS 26.5 VM with SIP off.
- Chat on a macOS core Host binds as on Linux, through the macOS forms of the same
  reads, for the programs in `confirmedMacOSCoreChatPrograms`. Claude Code, Codex,
  Grok Build, OpenCode, Pi and Oh My Pi were each seen through those reads in a
  macOS 26.5 VM with SIP off and no sign-in (`host-evidence/macos`,
  [herdr compatibility](../agents/herdr-compatibility.md)). Antigravity CLI was not
  in that VM: its lock was seen through the open-file read on a signed-in Mac
  outside a core (`host-evidence/agy`) and in the owner's herdr-core runs of
  2026-11-08, above.
  On the owner's Mac, macOS 27.0.1 with SIP on and signed-in harnesses, Claude
  Code, Codex with `--no-daemon`, Grok Build, Pi and Oh My Pi through Heeler's
  extension, and OpenCode 2.0.32 through Heeler's plugin each bound exactly. A
  program taken out of `macOSExactCoreChatPrograms` reads as cannot tell there and
  goes through its candidate list with one confirmation, and binds as before on
  Linux. Only a read that fails on a Mac takes one out; none has. Three things
  differ. The walk's `W ok` says the tree is whole, so a pick's process it no longer
  lists has left. Grok Build's `pid_start` is microseconds, compared to the second
  the start read gives. Oh My Pi's breadcrumb goes by `ttys006`. A Mac with SIP on
  withholds `/bin/zsh`'s environment, which is usually the Terminal's own process,
  so there alone the foreground's `HC_SCOPE` stands in for the Terminal's. With both
  withheld no process is the Agent, and a walk still drops a pick whose process left.
  An Apple binary between the foreground and the Agent therefore reads as cannot
  tell with no list, also under a launcher that can be read, which is not taken for
  the Agent while something below it is out of sight. Asking again finds the same,
  so the list's answer says to start the program directly and not to retry.
  A process's name there comes from `ps -o comm=`, which is argv[0] and so a
  program's title: a Node program names itself no other way. That is the one part of
  an argv a check brings off the Host. Only its last path part leaves, only when it
  holds nothing but `[A-Za-z0-9._-]`, which rules out `--token=x` but not a bare token
  a process set as its argv[0], and it is only ever compared to a program's name.
