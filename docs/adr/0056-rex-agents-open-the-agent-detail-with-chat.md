---
status: proposed
---

# Rex Agents open the Agent detail with Chat

ADR 0054 made a Rex terminal that runs a known agent program an Agent, and
opened it as its terminal: the Agent detail was rejected because it asked the
Host for things a Rex Host could not serve. ADR 0055 then built Chat's reads,
typing and Composer Send for Rex on the control connection, and left them
switched off. The maintainer decided on 2026-11-17 that Chat is to ship in
full with Rex support. This ADR records how a Rex Agent now opens the Agent
detail, what its Chat reads and types, and what still stays out. Its
[update of the same day](#update-2026-11-17-attachments) adds images and files
in messages, [the next day's](#update-2026-11-18-pi-and-oh-my-pi) adds Chat
for Pi and Oh My Pi, and [the update of 2026-11-25](#update-2026-11-25-native-windows)
opens Chat for Claude Code, with attachments, on a native Windows Host.

## Settings

The orchestrator of the change set these, from the maintainer's decision, and
the code follows them:

- **G1. tmux's way.** Chat reads the conversation over the Host's own SSH
  connection, through SFTP and bounded read-only execs, and binds the session
  from Host evidence with the shared `HerdrCoreSessionBinder`, starting from
  the foreground process Rex names for the terminal. The Host is POSIX by the
  same fallback tmux uses, and its kernel is learned and kept as tmux's is.
- **G2. Nothing on the machine.** No plugin, Host Helper, hooks, status file
  or pick file, and no option or label on the Rex server; a pick lives on this
  device. The Host services stay closed, so Skills, Changes, harness edits,
  the agy model list and the platform probe stay out. A file the user attaches
  to a message is the one write allowed, only through a narrow seam of its
  own (built on 2026-11-17, see
  [Update 2026-11-17: attachments](#update-2026-11-17-attachments)).
  (Updated 2026-11-18: Heeler's extension for a Pi or Oh My Pi is a second
  write, also only when the user asks, and it then keeps one small file per
  running Agent; see
  [Update 2026-11-18: Pi and Oh My Pi](#update-2026-11-18-pi-and-oh-my-pi).)
- **G3. Typing on the control connection.** One request per block at a time,
  shared with an open terminal view's input, each sent once. Typing opens no
  data link, asks for no size and takes or gives back nothing. A fresh read of
  the foreground comes before typing, and a screen that cannot be read with
  certainty counts as no screen (ADR 0055).
- **G4. The Agent detail.** Rex Agents open the Agent detail, with its Chat and
  Terminal surfaces. The Terminal surface keeps ADR 0053's size rule and one
  holder per block, and looking at the Agent on either surface clears its
  Done on this device.
- **G5. Programs.** Claude Code and Codex. Another program with a transcript
  adapter is offered only once a lab shows it binds with nothing on the
  machine. (Updated 2026-11-18: Pi and Oh My Pi as well, bound through
  Heeler's extension, which Chat offers to add.)
- **G6. Status decides.** Stop and the Blocked Card follow the Agent Status as
  on the other kinds. Unknown, from a program that reports nothing to Rex,
  means no Stop and no Blocked Card; the Terminal surface is where the user
  acts.
- **G7. Rex wording.** No text that points the user at the Host Helper,
  Heeler's plugin, hooks or New Agent is shown for a Rex Agent. (Updated
  2026-11-18: a Pi or Oh My Pi's Chat names Heeler's extension and its
  folder, and still none of those.)

## Decision

- **Capabilities by kernel.** `HostCapabilities` for a Rex record offers
  Composer Send and Stop, and Chat for `rexChatPrograms` (Claude Code and
  Codex) once the server has named a Linux or macOS kernel, as a tmux
  record's Chat waits on its kernel. Starting, renaming and closing anything,
  Worktrees, uploads, Host scripts and take over stay off. (Updated
  2026-11-17: uploads turn on with Chat, wherever the server has named a Linux
  or macOS kernel. Updated 2026-11-18: `rexChatPrograms` gains Pi and Oh My
  Pi. Updated 2026-11-25: Chat for `rexWindowsChatPrograms`, Claude Code
  alone, and uploads, once the server has named Windows; see
  [Update 2026-11-25: native Windows](#update-2026-11-25-native-windows).
  The same day, ADR 0049's update lets New Terminal start a shell.)
  The kernel comes
  from the socket lookup or `server.version` and is kept in the Host's memory
  on this device; the Host as the catalog stores it knows none, so nothing
  reads Chat ahead for it. `ConsoleStore.chatProgram(for:)` reads a Rex Host
  as POSIX without asking, and `requestHostPlatforms` never asks a Rex Host,
  so no task retries a probe that can only fail.
- **The Agent detail.** A Rex Agent opens `AgentDetailView`, as every other
  kind's Agent does. A program without Chat on Rex opens on the Terminal
  surface with no Chat. `agentsOpenAsTerminals` is gone, with the terminal
  screen's Agent route, its stand-in row, its core pins and its viewer
  presence. A Rex Terminal that is not an Agent opens as before, and one whose
  shell starts an agent leaves for that Agent's detail, as on the other kinds.
- **What the detail offers.** Its menus show only what the Host serves, alike
  on Chat and the terminal (`AgentDetailMenuOffers`): no New Agent,
  attachments, Rename Agent, Rename Workspace or Close. Skills and the agy
  model list need Host scripts, and Changes needs them too, so none shows;
  an Agent's row reads no Changes totals (`rowsReadChanges`). Snippets,
  Back to Console, the surfaces, the Composer and the Agent switcher stay.
  Grok Build, Pi, Oh My Pi, OpenCode and Antigravity CLI Agents open on the
  Terminal surface. (Updated 2026-11-17: once the server has named a Linux or
  macOS kernel, the detail offers attachments as well, on Chat and on the
  terminal alike. Updated 2026-11-18: Pi and Oh My Pi Agents have Chat.)
- **One holder per block.** The Agent detail's terminal (`AgentTerminalCache`)
  holds an Agent's block, and the terminal pool lets a connection to an
  Agent's block go at the next inventory, as on the other kinds. A Rex
  terminal shows in one window at a time (`terminalsShowInOneWindow`): an
  Agent row offers no window of its own, and windows take turns with a Rex
  Host's Agent terminals through the scene directory, as with a Herdr TUI
  Host's channel, with Live in Another Window and Take Over Here.
- **The Terminal surface's size.** The surface is a showing in ADR 0053's
  sense, through the same `AttachTerminalStore` rule: it takes the size as
  it opens, before the first paint, once per showing; never while the Chat
  surface is what is on screen; with the size notice and Fit to Screen when
  another device takes it; and gives it back when the surface, the screen or
  the foreground is left. An Attach the detail replaces carries the showing
  over and takes the size again as it opens.
- **Done.** Looking at a Rex Agent on either surface is looking at it, through
  the same `setAgentShown` every kind's detail reports. `focusAgent` tells the
  server nothing, since Done is kept on this device.
- **Stop and the Blocked Card.** The Chat Composer's Stop runs Chat's stop
  plan through `sendAgentKeys` (ADR 0055). The terminal Composer's Stop
  (`RexConsoleProjection.checkedTerminalStop`) presses one Esc the same way, on
  the control connection in the block's lane, only while the Agent that leads
  the foreground still does; a block with no Agent listed keeps Send, as a
  herdr-core Terminal's shell does. Both are offered only while the Agent is
  Working; Stop while Blocked stays tmux's. A Blocked
  Card reads the screen for Blocked, and for the idle cases every kind has;
  it never reads for an Unknown Claude Code or Codex.
- **Attachments stay off.** ADR 0055 found no narrow way to write one file on
  the Host: the stagers need the Host services, and `RexHostReads` writes
  nothing. Images and files are not offered. (Superseded by
  [Update 2026-11-17: attachments](#update-2026-11-17-attachments): they stage
  through `RexHostStaging`, a seam of their own.)
- **Still out.** Notifications, Live Activities, widgets, Usage, Accounts,
  background refresh, the plugin, the Host Helper and Pairing Codes leave Rex
  out by Server Kind, as before. (Updated 2026-11-18: Pairing no longer does.
  Since [ADR 0057](0057-heeler-pair-pairs-a-machine-without-herdr.md)
  it ends on Add Host's Servers step, which lists a Rex Server.)

## What runs over SSH

Before this change, a Rex Host's SSH connection carried the detection look,
the socket check when forwarding was refused, and direct-streamlocal channels
to the server's socket. Chat adds reads, and nothing that writes:

- an SFTP client held for the connection, which only stats, lists and reads
  ranges of files;
- one exec per connection that prints the home directory, and only if it
  prints none, one that checks for native Windows;
- one bounded exec per process read, which prints a process's start time,
  selected environment variables and open files, and for a Codex the words
  of its command line that decide the shared server, every other word as a
  placeholder; it picks its macOS or Linux reads with `uname -s`, and is cut
  off by an 8-second watchdog on the Host and a 12-second deadline here.

They run under the connection's ordinary session slots, so a slow read waits
behind other reads, never behind the control or data links. `RexHostReads`
offers no write, by type. No `rex` command runs, and no server is started.
(Updated 2026-11-17: a staging adds the one write, through `RexHostStaging`;
see [Update 2026-11-17: attachments](#update-2026-11-17-attachments). Updated
2026-11-18: adding Heeler's extension is a second, through
`RexHostExtensionPlacing`, and each Chat check first reads the foreground on
the control link; see
[Update 2026-11-18: Pi and Oh My Pi](#update-2026-11-18-pi-and-oh-my-pi).)

## Evidence

From lab runs against Rex 0.1.0-preview.14 (API revision 12) on an Apple
silicon Mac with macOS 27.0, with made-up programs in `heeler-lab-` sessions
(2026-11-16 and 2026-11-17, recorded in `docs/agents/rex-compatibility.md`):

- A control client that had only attached to every session could write and
  paste into a block without owning it, and neither the owner nor the size
  moved. Requests sent without waiting for answers could arrive out of order.
  A write right after the program exited was still answered as written, so
  an answer does not prove the program read it.
- The terminal's `vt` text held every row of the screen at its end, with only
  three kinds of sequence inside rows, and its tail could be read from any
  offset. Over a lab link of about 50 ms each way, a whole read of a
  10,000-line history took about half a second and held events back, where a
  tail read did not.
- The foreground Rex names is the leader of the terminal's foreground process
  group, which is a launcher's process when one started the agent. Every
  program typed into a terminal inherited variables naming its session, block
  and server, which places it as `HC_SCOPE` does on herdr-core. The process
  reader read start times, environments and open files of programs that are
  not Apple's own.
- The foreground was announced about 100 ms after the terminal printed, and
  not at all for a same-name process replacing another without output, an
  `exec` in place or a new file in a program's folders. A read of the
  foreground was current within about 30 ms.
- `server.version` named the platform, so no exec runs only to ask for it;
  a process read's own exec still runs `uname -s` to pick its reads.
  Direct-streamlocal channels did not count toward the lab sshd's
  `MaxSessions`; exec and SFTP channels did.
- A real Codex already running in a terminal, read only through the process
  table and never typed into, showed the facts a check needs; it held no
  rollout open at that moment. Rex names no command line, so the check now
  reads the Codex's own launch words to tell the shared server's notice from
  "can't tell"; that read was checked against an inert local stand-in, not
  that Codex.
- Live suite `RexChatTypingLiveTests` typed keys, pastes, Composer Send and a
  Blocked Card answer into a stand-in on the live server, each arriving once
  and in order, with the block's size and owner unchanged.
- `RexConsoleTests` hosts a Rex Agent's detail against a scripted server: on
  Chat it opens no data link and takes no size, and a finished turn reads
  seen; on the Terminal surface the take precedes `data.connect`, the pool
  holds nothing for the block, and leaving gives the size back.

## Considered options

- Keeping Rex Agents on their terminal screen (ADR 0054): superseded by the
  maintainer's decision. The detail's Host asks are now gated by capability
  instead of reached.
- Typing through the open terminal, herdr-core's way, or an Attach of Chat's
  own, tmux's way: dropped in ADR 0055, since either needs a data link and
  takes or paints at a size.
- A platform probe through the Host services, or an exec only for `uname`:
  dropped; the server names its platform, and the Host services stay closed.
- A second window's own viewer of the same terminal, as core Terminals have:
  dropped. A Rex block has one stream per client, so that viewer would wait on
  the block until the first window's Attach let go, which a retained Attach
  does only at its idle timeout. Windows take turns instead.
- Grok Build, Oh My Pi and Antigravity CLI: their binders need nothing
  installed, but no lab bound one inside Rex, so they are not offered (G5).
  Pi and OpenCode name their conversation only through Heeler's extension or
  plugin, which a Rex Host never gets. (Updated 2026-11-18: Pi and Oh My Pi
  are offered, with the extension added from Chat when the user asks; see
  [Update 2026-11-18: Pi and Oh My Pi](#update-2026-11-18-pi-and-oh-my-pi).)
- Staging attachments over SFTP: no seam narrower than the Host services
  exists, so attachments stay off (G2). (Taken on 2026-11-17, through a seam
  built for it; see
  [Update 2026-11-17: attachments](#update-2026-11-17-attachments).)
- Keeping a pick or a Blocked Card's answer as an option or label on the
  server: rejected (G2); both stay on this device.
- Guessing Stop or a Blocked Card for an Unknown Agent from its screen:
  rejected (G6).

## Consequences

- An Agent whose program reports nothing to Rex reads Unknown and has no Stop
  and no Blocked Card; the user acts on the Terminal surface.
- Images and files cannot be attached on a Rex Host. (Superseded on
  2026-11-17: they can, once the server has named a Linux or macOS kernel.)
- Windows take turns per Host, not per block: two windows on two Agents of the
  same Rex Host take turns too.
- A program that changes its conversation without printing is followed only
  at the next foreground or status change Rex announces.
- No real Claude Code or Codex has run inside Rex in a lab yet; binding rests
  on ADR 0034's macOS evidence and fixtures, and typing on stand-ins.
  (Superseded on 2026-11-18: both, and Pi and Oh My Pi, have run in the iOS
  Simulator against a running server; `docs/agents/rex-compatibility.md`
  says what was tried.)
- `HostCapabilities` gains `rowsReadChanges` and `terminalsShowInOneWindow`,
  and `AgentDetailMenuOffers` decides the detail's lifecycle items for every
  kind.

## Update 2026-11-17: attachments

The maintainer then asked for images and files on Rex Agents, as the other
Server Kinds have them. G2's one write is built this way:

- **A seam of its own.** `RexTransport.staging` hands out `RexHostStaging`, the
  Host's own SSH connection behind a type that can stage a prepared image and
  a prepared file and nothing else: no read of the Host's files, no other exec
  and no path but the ones it makes. It sits beside `RexHostReads` and is not
  one. `RexConsoleProjection.withHostServices` still throws for a Rex Host.
- **What it runs.** The staging every POSIX Host uses (ADRs 0005 and 0006):
  one exec that makes `${TMPDIR:-/tmp}/heeler.XXXXXXXX` at mode 0700, then an
  SFTP write of `stage-<id>/<name>.part` at 0600, renamed to `<name>` once it
  is whole. An image lands as `image.jpg` or `image.png`; a file keeps its
  name, with characters other than ASCII letters, digits, `.`, `-` and `_`
  turned into `_` and the stem cut to 64 characters. A failed or cancelled
  transfer tries once, on its own SFTP client, to remove its `.part`; a link
  that stalls until the app moves to a new connection leaves it (see the
  evidence below). A staged file stays, as on every kind (ADR 0005). Nothing
  of Rex's runs, and no server is started.
- **Slots.** The exec, and then the SFTP channel for the transfer, each take
  one of the connection's four ordinary session slots, one at a time, at
  normal priority. Chat's file and process reads ask at interactive priority,
  so they take the next free slot ahead of a waiting staging, and a slow
  upload holds one slot. The control link and the data links are
  direct-streamlocal channels under their own budgets (events and attach),
  which a staging never asks for.
- **The pin.** `RexConsoleProjection.imageStager` and `fileStager` keep to the
  server instance the Agent's detail opened on (`TerminalCorePin`): before
  anything is staged and again once the connection is in hand, an Agent of a
  server that is gone fails with `rexServerGone`, in those words, not
  retryable, and nothing is staged. A staging begun while no server answers
  fails as the Host not being connected, retryable. Nothing is checked after
  the transfer, as on a herdr-core Host: an upload under way when Rex
  restarts finishes and its file stays, and Send, which keeps to the same
  pin, refuses its path with the same words.
- **Delivery.** A staged path is part of the draft: a file's path where the
  cursor is, an image's at the end, each followed by a space, as on the other
  kinds. It reaches the program with the message's own typing, in Composer
  Send's one paste in the block's lane (ADR 0055), then Enter, once and never
  sent again; an unanswered last request reads as an unknown outcome, as for
  any Send. Status gates nothing more than Send already does, so an Agent at
  Unknown can attach and send. Cancel, removing an attachment before Send and
  a connection lost mid-transfer behave as on tmux: nothing of that attachment
  is typed, and a lost connection's upload can be retried.
- **Where it is offered.** `HostCapabilities.uploads` turns on for a Rex
  record exactly where Chat does, once the server has named a Linux or macOS
  kernel, so Add Image, Paste Image, Add File and drop show on both of the
  detail's surfaces. A Rex Terminal that is not an Agent offers none, as
  before, and nothing else opens with it.

Evidence: `RexStagingTests` stages through a scripted Rex Host, checks the
seam's type and the pin across a server restart, holds an upload while the
control link, a data link and a Chat process read go on, and types the staged
paths once with a message through Composer Send on either route, for an idle
and an Unknown Agent; Chat's own send policy (its send rules and screen
checks) is not run with a staged path there. The live path rests on the SSH
staging every POSIX Host shares (`ImageStagingE2ETests`). On 2026-11-17 the
iOS Simulator staged images and a file for stand-in Agents on a running Rex
0.1.0-preview.14 server on macOS, from Chat and from the Composer under the
terminal, an Unknown Agent's included, and each path was typed once with its
message; removing an attachment or cancelling an upload typed nothing, and an
upload that failed while the link was down was retried and sent once. A
cancel while the link was stalled left its `.part`: the app had moved to a
new SSH connection, and the removal, tried on the old one, did not run.
Uploads have not been tried from an iPhone or iPad, or with a real Claude
Code or Codex.

## Update 2026-11-18: Pi and Oh My Pi

The maintainer asked that a Pi or Oh My Pi Agent's Chat on a Rex Host open and
remind the user to add what it needs, where until now those Agents had no
Chat. G5 gains the two programs, and G2 a second write:

- **Offered.** `HostCapabilities.rexChatPrograms` gains Pi and Oh My Pi, so
  their Agents open the Agent detail with Chat as a Claude Code's does. Grok
  Build, agy and OpenCode stay on the Terminal surface.
- **What names the session.** Heeler's extension, the one file a Host Helper
  brings on other Server Kinds (ADR 0033). A Rex terminal has no labels and
  no socket of a core's to report to, so inside one the extension keeps what
  a label would hold in a file of its process's own:
  `<agent directory>/heeler-session/<pid>.json`, beside the `extensions`
  folder it was loaded from, holding the session id, its file when it has
  one, the pid and the process's start. It is written at mode 0600 in a
  folder at 0700, as a temporary file renamed into place, when a session
  starts, switches or branches. It is removed when the program says it quits
  and when its process ends, and a session's first write removes the files
  of processes that are gone. The extension does this only in a process
  whose environment names a Rex terminal (`REX_SESSION` and `REX_BLOCK`) and
  no tmux Pane, loaded from a folder named `extensions`, in the program's
  terminal interface. For a Pi before 1.1.0, which reports no status of its
  own, it also prints the status as OSC 7501, as it does in a herdr-core
  Terminal, which Rex reads.
- **Binding.** `HerdrCoreSessionBinder` reads that one file over SFTP for the
  Pi or Oh My Pi it found in the terminal's foreground, and takes it only
  when its pid and start are that process's, as it holds a label on
  herdr-core (ADR 0034). A file a reused pid left names nothing.
- **The reminder.** When that process has no such file, Chat reads "Can't
  Tell the Conversation" with a reason of its own
  (`ChatUnavailableReason.cannotTellSessionOnRex`). The binder reads the
  Agent's own `extensions/heeler-session.js` and looks for the name of the
  variable every copy that reports in a Rex terminal reads. A folder with no
  copy, or one from before the extension could report there, gets **Add
  Heeler's Extension…**. A copy that can report gets no button: the text
  says this Agent has not loaded it and asks the user to start it again. For
  Oh My Pi both texts add that Chat follows the conversation after its first
  message even without the extension, from its own terminal breadcrumb once
  its process holds the conversation's file open. Nothing is offered outside
  Chat, and nothing on the Rex Server's page.
- **The write.** `RexTransport.extensionPlacing` hands out
  `RexHostExtensionPlacing`, the Host's SSH connection behind a type with
  one function. The folder is the one this Agent loads from, read from its
  own process's environment by one bounded process read, and the sheet names
  it before anything is written. On the user's word, over SFTP, it makes
  that `extensions` folder only when the Agent's directory is there and has
  none, then writes the file this build carries as a 0600 temporary file
  renamed into place, over an older copy when there is one. It keeps to the
  server instance the detail opened on, as a staging does, and refuses any
  folder not named `extensions`. Only that Agent's folder is written, not
  every profile's as on native Windows, since the Agent in front of the user
  is the one that named it.
- **After the write.** Chat looks again and says the extension is in place
  but not loaded. Once the user starts the Agent again, Chat binds on its
  own.
- **Following an Agent Rex does not announce.** Two things a restart changes
  raise no event. Rex names a foreground once, as it starts, and a Pi starts
  under Node's name and takes its own afterwards, so the listed name matched
  no process the read found. A Chat check, the read of a Claude Code's
  launch, the conversation list and the look for the extension's folder now
  each read the foreground on the control link first, as typing does (ADR
  0055), and fall back to the listed one when the read fails or another
  server answers. The extension's file then appears a
  second or two after the program starts. After a check that could not tell
  for a Pi or Oh My Pi on a Rex Host, Chat checks again after 2, 4 and 8
  seconds, counted anew after any check something else asked for, and then
  waits for the next change Rex announces.
- **One file, one version.** The extension is the same file on every Server
  Kind, so its Rex branch raises the Host Helper to 0.5.10 and Hosts with a
  Helper are offered that update, whose only change does nothing outside a
  Rex terminal.

Considered and dropped: writing the extension as the Host is added, or from
the Rex Server's page (G2: nothing is written until the user asks, where the
need shows); keeping the session as a Rex label or option (G2); and binding a
Pi from its newest session file, which is a guess between two Pis in one
directory.

Evidence: `plugin/test/helper-extension-rex.test.js` loads the extension as
those programs do and checks the file, its modes, the sweep, the removal at
quit and at process end, and that it does nothing outside a Rex terminal.
`RexChatTests` binds a Pi from that file through a scripted Rex Host, takes
nothing from a file a reused pid left, tells a missing or older copy from one
not loaded, places the extension through the seam and refuses to after a
server restart, binds a Pi Rex still lists as `node`, and steps through the
three later checks. On 2026-11-18 the iOS Simulator ran this against Pi 1.5.2
and Oh My Pi 18.12.3 in a running Rex 0.1.0-preview.14 server on macOS 27.0,
each with an older copy of the extension in its folder: Chat offered the
extension, the sheet named the one folder, the file written matched this
build's, Chat then said it was not loaded, and after the Agent was started
again Chat bound without being touched. A message sent from Chat was answered
and shown, Stop interrupted a turn, a Send after `/new` was held once and the
next one went to the new conversation, and the file was gone after each
program quit. Not tried: an iPhone or iPad, a Linux Host, an Oh My Pi profile,
and a Pi before 1.1.0.

## Update 2026-11-25: native Windows

ADR 0049's update of the same day reaches a Rex server on native Windows
through Rex's stdio bridge and left Chat off there, since Chat's reads were
written for POSIX. Chat now opens for Claude Code on such a Host, read as a
native Windows core's Chat reads it (ADR 0034), with G1 to G7 unchanged.

- **Capabilities.** A server that names Windows (`windows_x86_64`) offers
  Chat for `HostCapabilities.rexWindowsChatPrograms`, Claude Code alone, and
  uploads. `ConsoleStore.chatProgram(for:)` reads a Rex Host reached by a
  pipe as native Windows, and `AgentChatAvailability` opens Chat on native
  Windows for a Rex Host as for a core Host, for the programs the
  capabilities name.
- **The reads.** On a Rex connection that `remoteEnvironment` finds to be
  native Windows, `HeelerSSHTransport.readProcesses` runs
  `HostProcessReader.windowsCommand`, one bounded PowerShell exec at
  interactive priority, and `hostHomeDirectory` gives `USERPROFILE` in the
  form SFTP opens, `/C:/Users/<name>`. File reads take the held SFTP channel,
  as a core's do on Windows. Nothing else changes: the binder is the shared
  one, on `HerdrCoreHostSystem.windows`, so it finds Claude Code by
  `agentOnWindows` and holds its registry entry's `procStart` to the
  process's creation FILETIME.
- **The terminal's variables.** Rex 0.1.0-preview.23 sets `REX_BLOCK` and
  no `REX_SESSION`, on macOS as on Windows (rex-compatibility.md), so the
  binder places a process by its block and takes a session id only when one
  is set. A block id names one block on the server. On Windows the read asks
  for `HC_SCOPE` and not tmux's variables, which native Windows never sets,
  keeping the PowerShell command under `cmd.exe`'s 8,191 bytes.
- **The foreground's names.** Rex names a Windows foreground by its image,
  `claude.exe`, and a path that parts at `\`; the Windows read names it
  `claude`. `RexConsoleProjection.foregroundNames` takes each name in that
  form there, so the check that the pid is still the one Rex named holds.
- **Uploads.** POSIX staging makes its folder with a `mktemp` exec, and a
  core stages on Windows through its own `terminal.put`, which Rex has no
  counterpart of over SSH. On a Rex connection to native Windows,
  `HeelerSSHTransport.stageOnWindows` uses SFTP alone: it makes a
  `heeler.<8 random>` folder once per connection under
  `USERPROFILE\AppData\Local\Temp`, a `stage-<uuid>` folder in it, writes
  the file as `.part` and renames it with `posix-rename@openssh.com`, which
  Win32-OpenSSH's server offers, and hands the Composer the Windows path
  (`C:\Users\<name>\AppData\Local\Temp\heeler.…\stage-…\image.png`,
  `WindowsStagePath`). Windows keeps no POSIX mode, so the folder is the
  account's by the temp folder's own ACL, and no mode is set or checked
  there. Names are already cleaned for Windows (`FilePreparer.cleanStem`),
  and a sent message shows such a path as a staged image or video
  (`ChatImageLink`).
- **Wording.** A read that finds no process on a Rex terminal says Chat
  can't tell the conversation, not the herdr-core text about elevation and
  constrained PowerShell.

Considered and dropped: Codex, whose binding reads the rollout its process
holds open, which nothing reads on Windows, as on a core Host; Pi and Oh My
Pi, until Heeler's extension is checked in a Rex terminal on Windows (and it
waits for `REX_SESSION`, which preview.23 does not set); and uploads through
Rex's own `upload_begin`, which types the paths itself rather than handing
them to the Composer, so it would bypass Send's checks.

Evidence: `RexSessionBinderTests` binds Claude Code in a Rex terminal on
Windows from a scripted Windows read and registry entry, refuses another
block, another session and another image, binds with no `REX_SESSION`, and
checks the read fits the command line for a ten-digit pid.
`RexConsoleTests` offers Chat for Claude Code alone, and uploads, on a
Rex Host reached by a pipe whose server names Windows; `RexStagingTests`
builds the Windows stage paths and reads them back as staged media. Against
the same PC over the same relay, SFTP made a `heeler.*` folder and a
`stage-*` folder in `AppData/Local/Temp`, wrote a `.part`, renamed it and
removed all three; the server listed `posix-rename@openssh.com`.
On 2026-11-25, against
Rex 0.1.0-preview.23 on Windows 11 with three Claude Code 2.1.332 Agents,
`process` named each foreground as `claude.exe`, the Windows process read of
each found `REX_BLOCK` matching its block and no `REX_SESSION`, its start
matched `procStart` in the Agent's registry entry, and SFTP over the same
relay listed its Transcript at the path the binder builds.
