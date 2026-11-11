---
status: proposed
---

# herdr-core Hosts fill the Console's Herdr TUI-shaped models

herdr-core Hosts (ADR 0031) have flat Terminals with labels, parents, and a
self-reported Program Status, and no workspaces, tabs, or plugins of their
own. The Herdr desktop app, when it runs on a core, keeps its spaces, tabs and
panes in the core document `herdr-app` and labels its Terminals
`herdr.space` and `herdr.tab`. Herdr TUI support stays as it is, and every
Server Kind is presented with Herdr TUI's Workspaces, Tabs, and Panes.

## Decision

- herdr-core gets its own Transport, codec, and projection. The projection
  fills the Console models Herdr TUI already fills (`Agent`, `ConsoleAgent`,
  `ConsoleTerminal` and its `PaneInfo`-shaped values) instead of neutral
  replacements. herdr-core never goes through the Herdr TUI `Transport`
  protocol.
- The Console lists the Terminals of the Host's own core only, never those of
  machines that core reaches.
- Every Terminal lands in a Workspace and a Tab. A Terminal labeled into a
  desktop space shows in that space and tab, under the names and order the
  desktop app shows. A space that exists only in labels, with no desktop
  document naming it, is named after its first Terminal's checkout folder, as
  the desktop app names a space it has not been given a name for. Any other
  Terminal joins a derived Workspace of the Terminals launched in its
  directory, as its own Tab. A Terminal without desktop labels (no
  `herdr.*` label; Heeler's own `heeler.*` labels do not count) started from
  inside another, such as a subagent, joins that Terminal's Workspace and Tab
  as another Pane.
- A launch into a desktop space that names no directory starts where the
  Terminal the space is named after is now, else in the space's folder, else
  in the home folder. The desktop app starts its own new Terminals where the
  space's focused Pane is, which its document does not record, and its folder
  only records where the space was made.
- Heeler keeps no organization of its own. Workspaces it creates, and Tabs it
  adds to a desktop space, carry the desktop app's labels, the adoption
  contract herdr-app documents, so a desktop app on that core shows them too.
  A Terminal opened in a derived Workspace carries no desktop labels, so it
  never appears in the desktop app uninvited. Heeler never writes the
  `herdr-app` document, which is that app's private model: the core refuses a
  write against a stale version, and the desktop app answers that conflict by
  replacing its own layout with the stored document, so a Heeler write would
  rearrange the desktop user's window.
- Renaming goes through the desktop app. A Workspace the desktop app shows can
  be renamed while that app runs on the Host: `herdr-app status` says whether
  it does, and `herdr-app do space.rename` with the space's id and the new
  name renames it, without automatic retry. A name typed for a new Workspace is
  applied the same way once the app has adopted it, and the field is hidden
  when the app cannot be reached. Derived Workspaces have no name to rename,
  and Rename Agent is not offered.
- A Terminal is an Agent while its foreground program is a known agent
  program, or, while the Terminal has a Program Status whose `app` is missing
  or unknown to Heeler, any program other than a shell. A Program Status with
  a known `app` counts only while that `app` names the foreground program. A
  shell in the foreground ends the Agent, whatever was reported last. The
  foreground is read after unwrapping: the desktop app's wrapper forms, `sh -c
  <command line>`, interpreters running an agent's script, and `npx` or `npm
  exec` running an agent's package or command, npm's retitled `npm exec claude`
  included. A script the shell runs is its own program, whatever it starts, so
  a known `app` reported under it makes no Agent. A cleared
  foreground names no program, so the last sample stands until the next. With
  no sample the launch arguments stand in, except a desktop wrapper that
  continues as a shell, which only a sample can name.
- Heeler starts an Agent as a kept Terminal, as the desktop app does, whose
  argv is the user's interactive shell replacing itself with the agent:
  `$SHELL -ic 'exec "$@"' $SHELL <agent> ...`, or for fish
  `fish -ic 'exec $argv[2..]' fish <agent> ...`, or on Windows PowerShell's
  `-Command "& '<agent>' ...; exit $LASTEXITCODE"`, which runs the agent as
  its child and exits with it. The interactive shell
  supplies the user's own PATH and variables, and then no shell stays: the
  Terminal ends when the Agent exits. Discovery goes through the same shell and
  asks a child `/bin/sh` to look on that PATH, so an alias or function, which
  `exec` cannot run, is not listed as installed. A kept Terminal whose program is lost
  rather than exited still comes back as a shell, one that has reported
  nothing. The launch request adds no PATH of its own. A Template is launched
  by name, as the core runs it, without the shell or the session flags of
  ADR 0034.
- Worktrees follow the desktop app's convention. The user names a branch;
  the checkout goes to `~/.herdr/worktrees/<repository>/<branch>`, the branch
  with each run of characters other than letters, digits, `.`, `_` and `-`
  made one `-` and `-` trimmed from both ends, through
  `git worktree add <path> <branch>` for a branch that exists and
  `git worktree add -b <branch> <path> HEAD` otherwise, where `<repository>`
  is the main checkout's folder name. A labeled new Workspace opens there.
  Removing one ends that Workspace's Terminals, then runs
  `git worktree remove`, forced only when the checkout has changes or
  submodules, keeping the branch. Those two git commands run as the app's do,
  with the repository's hooks, while Heeler's git reads stay neutralized. A
  removal stops before any kill when git reports a risk the confirmation did
  not name, so force never covers something the user did not hear about. The
  Terminals can write as they end, so git is read again once they have, and that
  read decides force: a risk the confirmation did not name stops the removal
  there, with the Terminals ended and the checkout kept. Remove
  waits for the read of those risks, as the desktop's mod does, and the
  confirmation carries what it named to the removal, so a read nobody was shown
  covers nothing.
- Native Windows herdr-core Hosts get the same Console, with these
  differences. Staged Images and Files are written by the core's
  `terminal.put` into its state directory beside the Terminal, which the core
  removes with the Terminal's record (`terminal.rm` or its retention, not
  `terminal.kill`); this
  amends ADR 0018's refusal of uploads for herdr-core Hosts only, since no SFTP
  mode bits are involved. A file over the 8 MiB one put takes is refused before
  anything is sent, and the put is an action on an address, so it keeps to a
  detail's core (ADR 0031). Each put takes a one-shot `connect` exec of its own, with
  any link's pipe check and core id, closed when the call ends, so its one long frame
  never sits ahead of Terminal input, a Send's Enter or Stop (ADR 0035). A launch goes through `powershell.exe -Command`, and
  discovery through one exec of the same program, with its profile, counting any
  command type `&` can run. New Workspace is offered, with no name field. Rename
  and Worktrees stay off until each passes a test on a Windows Host. A space nobody named still takes its Checkout's folder: one
  bounded PowerShell exec asks git only for the top level of each directory,
  from inside it, so no Worktree is known there, and without git on that exec's
  PATH the space takes its directory's name. Until a later ticket turns them on,
  what a Windows core Host cannot do stays hidden whatever its connection reads,
  stopped, update required, not installed or a refused session name included:
  Rename, Worktrees and Chat for a program not confirmed there. Send and Stop are
  on (ADR 0035). Changes and Skills, which run POSIX
  scripts on the Host, and Grok Build's status edit, which reads and writes through
  them, are not offered there either, so a native Windows Herdr TUI Host differs: it
  keeps showing the first two as ADR 0018 left them. New Agent, New Terminal and New Workspace
  show there as on any other Host that is not connected, and read not connected
  if tried. A core Host offers no New while its first attempt runs with nothing
  known of its platform, and this device remembers the kernel a locator last
  found, so that a relaunch knows before the Host answers. Add Host's detection
  notes a native Windows machine there too, since that Host's first attempt may
  never reach it. A Host that gets a status gets what that attempt found with it.

## Why

The desktop app's wrapper shell outlives the agent, and the core keeps the
agent's last Program Status while the Terminal runs on, so a reported status
alone keeps an exited Agent, or the program that replaced it, looking like the
Agent that left. Nothing ties a report to a process: a report carries no pid or
time, and a program's first report arrives before the foreground sample that
names it, so the rule matches names, not order. Launching through the user's
interactive shell matches the desktop app, which a Terminal Heeler starts may
end up shown in, and avoids copying the SSH session's PATH over a core that the
desktop app started with the user's login PATH. Heeler's launch does not keep
the desktop app's shell after the agent: the core types a child Terminal's
note, its last lines and Enter, into any Terminal that has reported and is not
blocked, and a shell left there runs those lines as commands.

## Evidence

Source-reviewed against herdr-core v0.1.13 (`88fe4e7`) and the Herdr desktop
app v0.1.9 (`3e32d75`). This is source evidence, not runtime acceptance from
the app. The 2026-10-30 live observations on a Debian 13 VM in [herdr
compatibility](../agents/herdr-compatibility.md) confirm or refine these points
with test clients, not the app.

- [defaults/AGENTS.md](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/AGENTS.md#L131-L139)
  and [src/SKILL.md](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/SKILL.md#L63-L66)
  document the adoption contract: `herdr.space` shows a Terminal in that
  space, `herdr.tab` picks its tab or the app creates one, adoption turns on
  keep, and unlabeled Terminals stay hidden.
- [api/doc.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/doc.rs#L9-L38)
  refuses a `doc.set` whose version is not current;
  [window.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/window.rs#L1756)
  treats that conflict as a replace of the app's own layout.
- [control.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/control.rs#L90-L96)
  maps `herdr-app status` and `herdr-app do <command> <args>` onto its
  control socket;
  [commands.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/commands.rs#L35)
  defines `space.rename` with an id and a name, and
  [model.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/model.rs#L232-L242)
  names an unnamed space after its first Terminal's checkout folder.
- [notes.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/notes.rs#L56-L58)
  takes a note for any live Terminal that has reported and is not blocked,
  whatever holds its foreground.
- [window.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/window.rs#L110-L119)
  builds the POSIX and fish wrappers, and
  [programs.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/programs.rs#L268-L287)
  recognizes those and the PowerShell form.
- [mods/worktree/main.js](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/mods/worktree/main.js#L15-L22)
  places checkouts under `~/.herdr/worktrees/<repository>/<branch slug>`,
  [names the repository](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/mods/worktree/main.js#L98-L104)
  after the main checkout's folder,
  [adds](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/mods/worktree/main.js#L182-L192)
  the branch the user typed, with `-b` only when it is new, and
  [removes](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/mods/worktree/main.js#L210-L225)
  a checkout after closing its space, forced for changes or submodules.
- [api/run.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/run.rs#L6-L11)
  runs a Template when `terminal.run`'s first argument names one.
- [put.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/put.rs#L5-L6)
  caps one `terminal.put` at 8 MiB and
  [writes it](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/put.rs#L36-L67)
  under `<state>/files/<address>/`, which
  [runtime.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/runtime.rs#L647)
  removes with the Terminal.

## Considered options

- Neutral models first, then both projections. Cleaner, but it rewrites the
  Herdr TUI side, whose support stays as it is.
- A separate Console for herdr-core Hosts. It keeps two lists and two details
  apart for good, while Pins, the Host filter, banners, and Live Activities
  already gather Agents across Hosts.
- Heeler's own organization stored in the core. It would allow renames on
  headless cores, but a core that also serves the desktop app would then show
  two organizations of the same Terminals.
- Grouping every Terminal by its launch directory, ignoring the desktop app's
  labels (PR #538). Simple, but a desktop user would see a different
  organization on the phone than on the desktop.
- Running the agent's executable directly, with the PATH an SSH probe found
  (PR #538). It needs no shell, but the agent misses what only the user's
  shell rc sets.
- The desktop app's wrapper, which leaves the user's shell behind as Herdr
  TUI's Pane does. It matches the desktop app, but the core goes on typing
  child notes into that shell, which runs them.

## Consequences

- herdr's generated `PaneInfo` becomes a model both projections fill;
  regenerating herdr's wire types can require a matching change in Heeler's
  herdr-core projection.
- Agent Status gains Error, which only herdr-core reports.
- Actions only Herdr TUI can serve are offered by Server Kind, not attempted
  and failed.
- Derived Workspaces exist only in the app's view and change as Terminals come
  and go. A kept Terminal that restarts takes its last directory as its new
  launch directory, so the device remembers the directory it first saw a
  Terminal launched in and keeps it in the same derived Workspace. The
  Workspace's id is a hash of that directory, and its label the directory's
  last path component, so two directories of one name are two cards that read
  alike.
- When an Agent Heeler started exits, its Pane closes, where a Herdr TUI Pane
  returns to the shell. Its foreground is the agent itself from the moment the
  shell replaces itself.
- Under PowerShell, which does not replace itself, the foreground is
  PowerShell for the Terminal's whole life: one event, with PowerShell's pid
  and the launch arguments, never the child
  ([observation](../agents/herdr-compatibility.md)). Recognizing a Windows
  Agent therefore reads the program out of PowerShell's `-Command` argument
  (`HerdrCoreAgentRule.readPowerShell`). Under Heeler's form the Terminal finished when its program ended, so
  its Pane closes as on Unix. `choice.exe` finished it with its own code, 2.
  Claude Code stopped by two Ctrl+C keys finished it with 1, not separated from
  PowerShell's own code. On 2026-11-03 Claude Code 2.1.286's `/exit` finished it
  with 0 and its trust dialog's "No, exit" with 1, both reason `exited`, so a
  program's own code comes through when it exits normally. Under the
  desktop's `-NoExit` form an Agent's exit leaves the foreground's pid, name and
  arguments unchanged and sends no new foreground event, so "a shell in the
  foreground ends the Agent" never fires. A read of PowerShell's children
  showed the exit, and the attach stream later carried PowerShell's prompt. The
  Terminal's title shows it too: on 2026-11-03 Claude Code 2.1.286's `/exit`
  under the desktop app 0.1.12 took the title from Claude Code's own back to
  `C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe`
  ([observation](../agents/herdr-compatibility.md)). That path is not the title a
  console starts with: the core's own `-NoExit` PowerShell, at its prompt with
  nothing run, read an empty title. So a `-NoExit` PowerShell in the foreground
  (`-NoExit` in any case, after `-`, `--` or `/`, or cut short to `-NoE`) whose
  Terminal title is a path to that same PowerShell reads as that shell, and the
  Terminal leaves the Agents for the Terminals tab. An empty title, as in a
  console nothing has titled yet or after a core restart, which empties titles
  (the Windows observations), keeps the foreground's reading. The title is the
  program's to set, so this costs something: a program that sets that path as its
  own title reads as the shell, and whether one that never titles itself leaves
  the path behind when it exits was not seen, so such an Agent may stay listed
  after its exit. Claude Code titles itself as it starts, and Grok Build 1.0.70
  and Oh My Pi 18.13.3 titled their Terminals under Heeler's form; no harness but
  Claude Code was run under the desktop form. `cmd /k` was not run and has no
  title reading.
  Heeler's launch does not use `-NoExit`, so this reaches only a Terminal the
  desktop app started. #590's read of PowerShell's children still serves Chat's
  binding only (ADR 0034), and Send still refuses such a Terminal while it is an
  Agent (ADR 0035): a title read before the paste says nothing of the moment
  Enter arrives.
- The same `choice.exe` runs through `connect` over one SSH exec gave the same
  foreground and finishes, 2 under Heeler's form and the shell's `exit 5` under
  `-NoExit`. On that machine the exec refused a program on a path through fnm's
  `fnm_multishells` junction (`ERROR_UNTRUSTED_MOUNT_POINT`), which a Terminal of
  the core ran, so discovery cannot read an exec's miss on such a path as
  not installed ([observation](../agents/herdr-compatibility.md)). It lists a
  program `Get-Command` finds even when that program's `--version` fails, and the
  user guide says one may be missing.
- Recognizing an Agent works on the foreground's arguments, not the launch
  arguments, and needs a table from reported `app` names (`claude-code`,
  `codex`, `opencode`, `pi`, `omp`, `grok-build`) to Heeler's agent kinds.
  Under the desktop app's fish wrapper the agent runs in the wrapper's process
  group, so the foreground stays the wrapper and the agent's exit shows only
  as new arguments on the same pid. Debian's `/bin/sh` runs a Template's
  command as a child, so a Template Agent's foreground is `sh -c` for its
  whole life.
- The core clears the foreground when it cannot read the group's leader: one
  that left while a member stays (`printf x | less`), or any failed read of the
  process. A record omits a cleared foreground, so a snapshot cannot tell it
  from one not sampled yet. Keeping the last sample means a shell stays a shell
  and a launch never brings back an Agent that left. In exchange, an Agent whose
  own group lost its leader stays, with its last report, until the group ends,
  and a reconnect during that shows no Agent until the next sample. A desktop
  wrapper's Terminal is an Agent from its first sample, about half a second in.
- An Agent whose `app` Heeler does not know keeps its status when the user
  runs another program in the shell it left, until something reports again.
- A kept Terminal between losing its program and restarting has no foreground;
  it shows as restarting and is no Agent. The core announces the loss without
  clearing the foreground, so the app clears it, and reattaches after the
  restart, since the loss closes the attach. A kept Terminal whose program
  exits with a code, including a user's `exit`, ends for good; only a lost
  program restarts. An Agent detail open on either stays on screen, showing
  restarting or ended, though the Terminal has stopped being an Agent. The app
  keeps that departed Agent for the detail alone, so no list shows it, and a
  reconnect forgets it. The core clears the program's status just before it
  says the program was lost or finished, which takes an Agent whose `app`
  Heeler does not know off the list first, so that Agent departs too when the
  same program's end follows; one whose shell took the Terminal back did not.
  Its Chat stays too, on the conversation it showed, says what became of the
  Agent, shows the Composer rather than a Blocked card, since no program is
  left there to show a dialog, and follows the next Agent back at that address.
- Close ends a Terminal for good with `terminal.kill`, one for each Terminal
  it takes, and never sends one twice: a kill the core did not answer reads as
  outcome unknown. A kill is final even on a kept Terminal, so keep is left as
  it is. The Console hides the record the core keeps. A row whose Tab has other
  Panes closes only its own Terminal, as on Herdr TUI; what becomes of a
  Terminal it started is the core's call.
- A Template launch returns once the program first reports, which can take
  35 seconds, and the record carries the Template's submit and stop keys. A
  program Heeler does not know is no Agent until it reports, so a Template
  whose program never does stays a Terminal. One whose program ended by the
  time New Agent would close reads as a failed start.
- A subagent started with `hc run` gets the core's environment, not its
  parent shell's.
- Any process on the core can rewrite any Terminal's labels, desktop labels
  included, so labels place Terminals but prove nothing.
- On a host whose zsh has no startup files, a launch through zsh stops at
  zsh's new-user wizard until someone answers it in the terminal.
- The desktop app prefers a reported `app` over the foreground
  ([window.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/window.rs#L4363-L4367)),
  so it can show an exited Agent's status that Heeler hides.
- Renaming over SSH depends on `herdr-app do` reaching the desktop app's
  socket from an SSH session. The owner's check on a Mac passed on 2026-11-05
  (Herdr desktop 0.1.13, herdr-core 0.1.18, macOS 27.0.1;
  [compatibility notes](../agents/herdr-compatibility.md#versioned-observations)),
  so Rename and applying a typed name are on; no Linux desktop has run it.
  `HerdrAppControl.isRenameOn` turns both off again if a desktop app release
  stops answering from SSH; New Workspace does not depend on it.
- Heeler asks `herdr-app status` when it connects, returns to the foreground,
  opens an Agent detail, New Agent or New Terminal, and after a rename fails,
  and does not poll. An Agent detail left open while the app quits keeps
  offering Rename until that one `do` fails: nothing is renamed, the sheet says
  the app could not be reached, and the offer goes.
- On Windows a Staged Image or File larger than 8 MiB is refused before it is
  sent, as the core refuses it (`invalid_params`); exactly 8 MiB is accepted.
  Over one SSH exec a put in one 8 MiB frame arrived with the same hash and 8 MiB
  plus one byte was refused the same way.
  The files sit at `<state>\files\<address>\<cleaned name>` under the user's
  profile, with the inherited access of SYSTEM, Administrators and the account
  ([observation](../agents/herdr-compatibility.md)). The name is the picked
  file's own, cleaned as ADR 0006 says, or `image.<ext>`, and the core numbers a
  name already taken there (`name-2.ext`). A program in the Terminal
  reads them by that path. The folder outlives `terminal.kill` and goes with
  `terminal.rm`. By the core's source at v0.1.16, which was not run, an ended
  Terminal's record also goes once it passes the core's retention, about a day, or
  a cap on finished records, and its folder goes with it. The inherited access was
  seen on one machine, and the core sets none.
