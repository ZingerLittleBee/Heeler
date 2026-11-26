# Rex compatibility observations

Consult this reference for the Rex control connection, inventory reads and
events, Program Status, and resume and close behavior on Rex Hosts. These
observations are historical evidence, not fresh tests on the installed server.
Each names the Rex version it was seen on; check it before applying an
observation to a newer server. All are written in Heeler's own words; no Linux
server has been observed yet.

## Current routing

- Rex Hosts are a fourth Server Kind, offered in every build and still
  experimental for users
  ([ADR 0049](../adr/0049-rex-hosts-reach-a-running-rex-server-by-its-socket.md)).
  Heeler reaches a running server's Unix socket over a direct-streamlocal SSH
  channel and never runs `rex` or starts a server. On native Windows it
  reaches the server's named pipe through an exec of
  `rex.exe -S <address> __internal dial-stdio --autostart=false` (`RexWindowsDial`),
  which starts none either.
- One WebSocket control connection per Host carries everything but terminal
  data: hello at API revisions 12 to 19, `server.status`, `session.attach_all`
  and the inventory reads
  ([ADR 0050](../adr/0050-rex-hosts-follow-inventory-on-one-control-connection.md)).
  `RexHostSession` owns it; `RexInventoryFollower` and `RexInventoryBook` read
  and order the inventory.
- A terminal's output arrives on a data connection of its own
  (`RexDataLink`). Heeler skips the stream's snapshot (`RexStreamScanner`) and
  paints from the server's `vt` redraw instead (`RexTerminalPaint`);
  `RexTerminalStream` runs the three for one view.
- The Console opens a Rex terminal from the server's redraw
  ([ADR 0051](../adr/0051-rex-terminals-open-for-viewing-from-the-servers-redraw.md)):
  `RexHostSession.withTerminal` calls `session.attach` on the Host's control
  connection and holds the block to one data connection, and
  `RexTerminalAttach` turns its stream into the view's bytes and asks for the
  view's size.
- Input to a Rex terminal goes on the control connection one request at a
  time ([ADR 0052](../adr/0052-rex-terminal-input-goes-one-request-at-a-time.md)):
  typed bytes as text through the terminal's `write`, read by
  `RexTerminalKeyReader`; pastes, focus changes and mouse reports text cannot
  carry through `block.event`.
- A Rex terminal's size is taken for the view that shows it
  ([ADR 0053](../adr/0053-rex-terminals-fit-the-view-that-shows-them.md)):
  `RexTerminalAttach` sends `session.own_block` with mode `take` for the one
  block, then the view's grid, as an attach for a shown view opens and before
  its stream starts, when the view is shown again, and at the notice's Fit to
  Screen. It takes nothing on its own once another client took the size in
  the same showing or a take of its own did not go through, and gives the size
  back with `session.disown_block` when the view stops showing the terminal
  or the attach ends, unless the server passed the block to Heeler because
  its owner's link dropped.
- A terminal whose foreground is a known agent program is an Agent
  ([ADR 0054](../adr/0054-rex-terminals-running-a-known-agent-are-agents.md)):
  `RexAgentRule` reads the foreground with `HerdrCoreAgentRule.program` and
  the root Program Status while its owner is that foreground. The details read
  adds `program_status`, and the control connection's `program_status_changed`
  and `program_status_removed` events keep it current.
- A Rex Agent opens the Agent detail, with its Chat and Terminal surfaces
  ([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md)):
  `HostCapabilities` offers Composer Send and Stop, and Chat for Claude
  Code, Codex, Pi and Oh My Pi once `server.version` named a Linux or macOS
  kernel; the Terminal
  surface takes the size under ADR 0053's rule and Chat takes none; the
  terminal pool holds no Agent's block, and windows take turns with a Rex
  Host's Agent terminals (`terminalsShowInOneWindow`).
- Chat's reads and binding: `RexHostReads` reads files and processes over
  the Host's SSH connection and can write nothing, `HerdrCoreSessionBinder`'s
  `.rex` scope binds from the foreground Rex names, read afresh for each
  check, and `RexConsoleProjection` keeps the Host's kernel and a terminal's
  pick in `HerdrCoreHostMemory` on this device. A Pi or Oh My Pi binds from
  the file Heeler's extension keeps for its process, and Chat adds that
  extension only when the user asks, through `RexHostExtensionPlacing`
  (`ConsoleStore.rexExtensionFlow`,
  `RexConsoleProjection.placeChatExtension`). See
  [Processes and Chat evidence](#processes-and-chat-evidence) and
  [Pi and Oh My Pi in a Rex terminal](#pi-and-oh-my-pi-in-a-rex-terminal).
- Chat's typing and Composer Send
  ([ADR 0055](../adr/0055-rex-chat-types-on-the-control-connection.md)):
  `RexBlockRequests`, from `RexHostSession.blockRequests`, reads and types
  into one block on the control connection, in the lane an open view's input
  shares (`RexBlockLanes`), with no `session.attach`, data connection, size or
  take. `RexChatScreen` reads the screen, `RexChatTyping` checks the holder
  and types, Chat's Stop and the terminal Composer's
  (`RexConsoleProjection.checkedTerminalStop`) press keys through it, and
  `RexComposerSend` pastes and submits. See
  [Chat's reads and input](#chats-reads-and-input).
- New Terminal and New Workspace are the one thing Heeler starts on a Rex
  server ([ADR 0049's update of 2026-11-25](../adr/0049-rex-hosts-reach-a-running-rex-server-by-its-socket.md#update-2026-11-25-new-terminal)):
  `RexHostSession.createTerminal` attaches to the session and sends
  `session.new_window` (`focus: false`), or sends `session.create` and then
  attaches to the new session. Either asks once for one
  `com.superlogical.terminal.shell` block in `cwd`, and the new block goes
  back with `session.disown_block`, which Rex answers only from an attached
  client. A new session whose attach failed keeps its block until the session
  is next attached. See [Starting a terminal](#starting-a-terminal).

## Known limits

What Heeler's Rex support has not covered, as of Rex 0.1.0-preview.23 (API
revision 19), most of it first seen on 0.1.0-preview.14 (API revision 12).
The user guide, [Connect Rex](../guides/rex.md), says the same
in users' words.

- **Revisions 12 to 19.** The hello offers 19 with a floor of 12; a welcome
  at any other revision, or a close before the welcome, is refused as
  `rexUnsupportedRevision`, naming the revision the server offers when it says
  ([ADR 0049](../adr/0049-rex-hosts-reach-a-running-rex-server-by-its-socket.md#update-2026-11-25-api-revisions-12-to-19)).
  Preview.14 has been seen at 12, and preview.23 and preview.25 at 19.
  Preview.25 says revision 24 and supports 0 to 24; the eight local-socket
  live suites passed against it on 2026-11-26 (`RexSSHLiveTests` was not
  run).
- **A restarted server continues only with its sessions.** Rex restores its
  sessions with the same ids under a new `instance_id`, and resumes programs
  that report (OSC 7577). Heeler continues the server when the new instance
  names the last one's `host_id` and lists one of its sessions
  ([ADR 0050](../adr/0050-rex-hosts-follow-inventory-on-one-control-connection.md#update-2026-11-26-a-restarted-server));
  a restored terminal paints a fresh screen. A `RexHostSession` probe has
  followed a real restart; the Console and its details have only followed
  a fake one. See
  [Server restart and Program Resume](#server-restart-and-program-resume).
- **No Linux server.** The Linux socket places, the `/proc/net/unix` socket
  check and a server started by a login service have never met a running
  Linux Rex server; `scripts/test-server-kind-detection.py` runs the
  detection script against fake Linux homes only. Every observation below is
  from macOS, except those that name Windows.
- **What the first paint leaves out.** The `vt` redraw carries no title,
  cursor shape, OSC 10 or 11 default colors or saved cursor, and while a
  program uses the alternate screen none of the primary screen or scrollback
  behind it (`b_redraw`). Heeler reads the title on its own and follows its
  events, applies the stream's `theme` (the terminal's own default colors)
  after each paint's reset, and paints the primary screen again once the
  program leaves the alternate screen; the cursor shape stays Heeler's until
  the program sets it again. Neither revision 12 nor 19 offers the cursor
  shape or the history behind the alternate screen
  ([Terminal colors and what stays out](#terminal-colors-and-what-stays-out)).
  With autowrap off, soft wraps are not joined. A
  program that never pauses for 250 ms keeps a best-effort first paint, and
  a redraw past 32 MiB ends the attach as too long to show
  ([ADR 0051](../adr/0051-rex-terminals-open-for-viewing-from-the-servers-redraw.md)).
- **Another client's size, when it stands.** A block another client takes
  while Heeler shows it, or one whose take of Heeler's did not go through,
  shows at the server's grid until the user taps Fit to Screen or shows the
  terminal again. Lines wider than the view wrap at the view's width, in the
  first paint, whose redraw rejoins soft-wrapped lines, and in output that
  runs past the view's last column; a program that places its rows with
  cursor moves mostly shows their left part. There is no view scaled to or
  cut at the remote grid
  ([ADR 0053](../adr/0053-rex-terminals-fit-the-view-that-shows-them.md),
  as [ADR 0045](../adr/0045-tmux-hosts-poll-inventory-and-attach-through-control-mode.md)
  says for tmux).
- **Shells only.** New Terminal and New Workspace start a shell
  ([Starting a terminal](#starting-a-terminal)); nothing else is created,
  nothing is closed or renamed, and no layout changes; no notifications, Live
  Activities, Usage, Changes or New Agent.
- **Attachments where Chat is.** Once the server has named a Linux or macOS
  kernel, an Agent's Composer can attach images and files. Heeler stages them
  over the Host's own SSH connection (one `mktemp -d` exec, then an SFTP
  write into `${TMPDIR:-/tmp}/heeler.XXXXXXXX/stage-<id>/`), never through
  Rex, and types the staged path with the message. Seen on 0.1.0-preview.14
  on macOS from the iOS Simulator: images and a file staged for stand-in
  Agents reached their terminals as one paste and one Enter each, and on
  2026-11-18 an image reached each of six real agents and a text file two of
  them ([Real agents in the Simulator](#real-agents-in-the-simulator)). Not
  yet tried from an iPhone or iPad; the transport is the one every POSIX Host
  uses
  ([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md),
  update of 2026-11-17). On native Windows they are staged over SFTP alone,
  into `AppData\Local\Temp`, with no exec; that has been tried over SFTP but
  not yet from the app
  ([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md#update-2026-11-25-native-windows)).
- **Chat for four programs.** Chat is offered for Claude Code, Codex, Pi and
  Oh My Pi only, and on native Windows for Claude Code alone. A Pi or Oh My
  Pi names its conversation through Heeler's
  extension, which no Host Helper brings to a Rex Host: Chat offers to add it
  to that Agent's own extension folder, and the Agent loads it when it is
  next started. An Agent whose program reports nothing to Rex reads Unknown,
  and then has no Stop and no Blocked Card; the user acts on its Terminal
  surface
  ([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md)).
  Real agents have been bound and typed into only from the iOS Simulator, on
  one Mac ([Real agents in the Simulator](#real-agents-in-the-simulator),
  [Pi and Oh My Pi in a Rex terminal](#pi-and-oh-my-pi-in-a-rex-terminal)).
  A Claude Code waiting on a command it put in the background has ended its
  turn, whatever its record says, and Heeler never stops that command
  ([Claude Code's record after a turn](#claude-codes-record-after-a-turn)).
- **Agents Heeler cannot see.** A program that is a block's own command
  (behind `login`), one started with `exec` from the shell, and one under a
  `sh -c` that does not exec it read as `login` or the shell, so they stay
  Terminals although Rex keeps their reports. The foreground Heeler holds can
  be behind until the terminal next prints. No real OpenCode has run inside
  Rex in a lab yet.
- **Where it has run.** Only the Simulator and the opt-in live suites, on one
  Mac. No physical iPhone or iPad has opened a Rex terminal, and no Rex
  terminal has been opened while the Rex desktop app showed the same one:
  the other devices were lab control clients on `heeler-lab-` sessions, and
  sessions whose blocks the desktop app owns were listed, never opened.

## Versioned observations

All below: Rex 0.1.0-preview.14, API revision 12, macOS 27.0, local socket,
2026-11-15. Each bullet names where it was seen: a lab capture kept outside the
repository (`f_control` for the control connection and layout operations,
`g_reconnect` for drops and resumes, `a_snapshot_skip` for how a terminal's
stream starts, `b_redraw` and `b2_edges` for the redraw, `c2_handoff` for
first paints, `d2_queries` for query answers, `d_input` for the input run,
`e_size` for sizes and owners, `r6_ownership` and `r6b_handover` for taking
and giving back a block), a review probe, the Simulator acceptance run, or a
committed live test.

### Installation

- The macOS app, installed as `Rex Beta.app`, names `com.superlogical.rex` as
  its bundle identifier in its `Info.plist`, and the server keeps its socket
  and data in `~/Library/Application Support/rex` (review probe of the
  installed app). Detection reads these, not a `rex` on the PATH, which other
  software also ships.
- On Windows 11, Rex 0.1.0-preview.23 installed with WinGet puts `rex.exe` in
  `%LOCALAPPDATA%\Microsoft\WinGet\Links`, on the account's PATH, keeps its
  logs under `%LOCALAPPDATA%\rex`, and its personal server listens on
  `\\.\pipe\rex-<SID>`, which `rex server status` writes as
  `npipe:////./pipe/rex-<SID>` (2026-11-25, over Win32-OpenSSH with a `cmd`
  DefaultShell). `rex -S <that address> __internal dial-stdio
  --autostart=false` bridged an SSH exec to it: the WebSocket upgrade, a hello
  at revision 12 and `session.list` all answered as over a Unix socket.

### Control connection

- The server welcomes a hello at revision 12 with a client id and a reconnect
  token. The welcome's limits put messages at 1 MiB (`f_control`).
- An idle control connection received one server ping at 120 seconds in a
  130-second watch (`g_reconnect`). A review probe that never answered pings
  saw them at 120, 180 and 240 seconds, then a close with 1001 and the reason
  `keepalive timeout` about 300 seconds in; the server listed that client as
  lost, and a hello with its token resumed it as the same client. A link that
  sent its own pings once a second, as `RexControlWebSocketLiveTests` sets it
  up, stayed open; Heeler's control and data links ping every 30 seconds.
- A fresh connection's `session.attach_all` answered with seq 0, and the events
  after it were numbered 1, 2, 3 and on with no gaps (`f_control` watchers).
- A text frame that was not valid UTF-8 closed the control connection with
  1007 (input run).

### API revision 19

Rex 0.1.0-preview.23 on macOS 27.2, API revision 19 (supports 0 to 19), local
socket, 2026-11-25, from a review probe that said hello at 12 and then at 19
and made the same requests in a session of its own:

- The server picks the newest revision both sides speak: a hello of 19 or 25
  with `api_min_revision` 12 was welcomed with `api_revision` 19, one of 12 at
  12, one of 11 with floor 0 at 11, and one of 25 with floor 20 was closed
  with 1008 and the reason `no common API revision: server speaks 0 to 19,
  client needs 20 to 25; update the server`. Every welcome named
  `api_server_revision` 19 and no `api_min_revision`.
- `server.status`, `server.version`, `session.list`, `session.attach_all`,
  `session.create`, `session.attach`, `session.view`, `session.list_blocks`,
  `session.new_window`, `session.own_block`, `session.disown_block`, the
  terminal's `title`, `process`, `program_status`, `size`, `modes`, `format`,
  `resize` and `write`, and `block.event` with a paste and a focus answered
  with the same fields at both revisions; an unknown terminal method answered
  `method_not_found` and a request without `session_id` `bad_request` at both.
- The events in between (`session_created`, `client_connected`,
  `block_created`, `block_owner_changed`, `window_created`,
  `session_view_changed`, `block_event` `process_changed` and `size_changed`,
  `block_closed`, `session_destroyed`) carried the same fields at both.
- A `data.connect` ticket from either revision opened `rex.data.terminal.v1`
  with the same 32-byte welcome and a `GHOSTSNP` snapshot of the same length.
- `help.all` names no method or field as new since revision 12.
- Over the stdio bridge to Rex 0.1.0-preview.23 on Windows 11, a hello of 19
  with floor 12 was welcomed at 19 and `session.list` answered.

### Attach scopes

- `session.attach_all` attaches the connection to every session, including
  ones created later, and answers with the session list (id and label each)
  (`f_control`).
- Scope `session` delivers session structure and lifecycle events. Scope `all`
  adds each block's own events (`block_event`) and client events. Heeler asks
  for `all` (`f_control`).
- With only `session.attach_all`, a connection can read `session.view`,
  `session.list_blocks`, and a terminal's title, process, format and size.
  `data.connect` answers 409 and `own_block` 400 until the connection also
  calls `session.attach` for that session (`f_control` for the view, listing,
  format and size; `RexInventoryLiveTests` for title and process).

### Inventory reads

- `session.view` answers with a revision, the session label, the active
  window, and its windows; each window lists layers (`tiled` or `floating`),
  each with a layout tree of splits (`before`, `after`) and leaves naming
  blocks, and the facts of each block in the layer (label, creator, flavor,
  owner) (`f_control`).
- `session.list_blocks` lists every block of the session in block id order,
  each with its placement: `placed` with a window id, or `detached`. The view
  leaves detached blocks out (`f_control`).
- Terminal blocks are created by `com.superlogical.terminal`, flavor
  `com.superlogical.terminal.shell` for a shell. Blocks of other creators are
  not terminals (`f_control`).
- A new window's label is `Window` followed by the last eight hex digits of
  its id with dashes removed. A new shell block's label is `shell`
  (`f_control`). A block whose label was set to empty came back labeled
  `Block` and the last eight hex digits of its id (acceptance run).
- A terminal's `title` method answers an empty title until a program sets one.
  Its `process` method names the foreground process, with its name and working
  directory, or no foreground (`f_control`).

### Events per operation

All from `f_control`. Session events arrive wrapped with their session id;
`session_created` is server-wide and carries the session's id and label.

- New layer: `block_created`, `block_owner_changed`, `session_view_changed`,
  then process changes as the shell starts.
- New detached block: `block_created`, `block_owner_changed`, with no view
  change.
- Label of a placed block, move, float and detach: `session_view_changed`
  alone.
- Window label: `window_label_changed`, then `session_view_changed`.
- Focus: `active_window_changed`, then `session_view_changed`.
- New window: `block_created`, `block_owner_changed`, `window_created`,
  `session_view_changed`.
- New split: `block_created`, `block_owner_changed`, `session_view_changed`.
- Zoom: two `session_view_changed`.
- Block close: `block_closed`, then `session_view_changed`.
- Window close: `window_closed`, `session_view_changed`, then `block_closed`
  for its blocks.
- Session destroy: client and block events for its blocks, then
  `session_destroyed`.
- `session_view_changed` carries only the new revision. Window and label
  events arrive before the view change of the same operation.
- A terminal raises `title_changed` with the new title, and `process_changed`
  with a generation and the foreground process (or none) whenever the
  foreground changes, its directory included. (Seen again 2026-11-16: only
  once the terminal prints; see [Program Status](#program-status).)

### Starting a terminal

Rex 0.1.0-preview.23 on macOS, API revision 19 (supports 0 to 19), with a
client that said hello at revision 12 (2026-11-25):

- `session.new_window` from a client attached to no session was refused with
  409 `conflict`, `stream is not attached to session <id>`; `session.view`,
  `session.disown_block` and `session.destroy` likewise. After
  `session.attach` it answered `window_id`, `block_ids` and `revision`.
- With `focus: false` the session's `active_window_id` stayed the window it
  was. The events were `block_created`, `block_owner_changed` naming the
  creating client with reason `create`, a `process_changed` with no
  foreground, `window_created` (labeled `Window <last eight digits>`) and
  `session_view_changed`, all before the response; the shell's foreground
  followed with the `cwd` asked (`/private/tmp` for `/tmp`).
- `session.create` with `label` and one `initial_windows` entry answered
  `session_id` and each window's `window_id`, `block_ids` and `revision`
  without an attach. `session.list_blocks` then listed the block labeled
  `shell`, flavor `com.superlogical.terminal.shell`. Destroying that session
  disconnected the other clients attached to it, the Rex app's among them.
- `block_creator.list` names the shell flavor's options, `cwd` among them:
  a `cwd` that is empty, missing, not a directory or not enterable starts in
  the account's home directory.
- Not observed: the same requests on Linux or on a native Windows server.

### Program Status

All from a lab run on Rex 0.1.0-preview.14, API revision 12, macOS 27.0,
local socket, 2026-11-16, the server instance unchanged throughout, with inert
stand-in agents in `heeler-lab-` sessions (lab captures kept outside the
repository), unless a bullet names `RexProgramStatusLiveTests`.

- **Reports.** A program in a Rex terminal reports with OSC 7501 in the words
  Heeler's other kinds use: a `state` of idle, working, done, blocked or error,
  and optionally `app`, `kind` (on blocked), `msg` and `title` (base64),
  `progress` and an `id` for a child record. The server rejects a whole
  report whose state is another word, upper case or missing, so it never
  stores a word Heeler would read as Unknown. `state=clear` drops the root and
  its children. A report replaces its record whole. Rex answers a program's
  `ESC ] 7501 ; ?` query itself, listing the states and kinds, so a program
  that asks before reporting should report inside Rex; no real agent was run
  to see it. (Seen on 2026-11-18: six real agents reported there, see
  [Real agents in the Simulator](#real-agents-in-the-simulator).)
- **The record's owner.** Each record names an owner, the process id and name
  of the terminal's foreground when the report arrived, not of the writer: a
  background job's report names the shell, and a launcher's child's report
  names the launcher. A first report from the next program replaces the root
  record and its owner.
- **When a program leaves.** Working and blocked records go when their program
  leaves the foreground (reason `foreground`, or `prompt` under a shell that
  marks its prompt with OSC 133, as fish does), Ctrl+C included. Idle, done
  and error records stay, after later commands too, still naming the exited
  process, which is why Heeler compares the owner with the current foreground.
  A done record stayed for 90 seconds in the lab, and an existing Codex's
  record had stayed for most of an hour while Codex held the foreground: no
  expiry was seen. `terminal.reset` drops every record, the terminal's own
  program exiting drops them with reason `child_exited`, and `block.close`
  raises `block_closed` alone, after which `program_status` answers 404.
- **Events.** On a connection attached with `session.attach_all` and event
  scope `all`, every report raised a `block_event` named
  `program_status_changed`, carrying the record's id (empty for the root),
  the whole new record and a reason, and every removal a
  `program_status_removed` listing the ids (the root as empty) and a reason.
  200 reports written back to back raised 200 events, each under a
  millisecond after the write. With event scope `session` and no
  `session.attach`, none arrived. Reading `program_status` raised no event.
- **The same report again.** A report identical to the record raised another
  `program_status_changed` and moved the record's `updated_at`, which carries
  microseconds; a done made three times in a row did so each time. Reading
  `program_status` moved nothing, and each read matched the event before it.
  Rex keeps no turn count,
  so only a connection that hears every report can tell a done made again
  from a new turn: Heeler counts the turns each connection hears end, and
  across connections reads a done whose time moved as a finished turn
  (ADR 0054).
- **Order.** A program's first report at launch arrived about 100 ms before
  the `process_changed` that named it (15 of 15 launches), already owned by
  the program. A removal arrived before the `process_changed` that named the
  shell. A process group that took the terminal for six seconds without
  printing raised no `process_changed`, going or coming back, though the
  `process` method named it at once.
- **Which foreground.** A program typed into a shell leads the foreground
  under its own name, or its first argument where the executable is named for
  a version (native Claude Code), or its script under an interpreter (Python,
  node). `HerdrCoreAgentRule.program(arguments:name:)` given the first
  argument (or the name) and the script recognised all twelve agent launches
  of the run and none of the shells and background jobs. A block whose command
  is the program itself, `exec` from the shell, and a `sh -c` that does not
  exec its program showed `login` or the shell as the foreground. An existing
  Codex under fish read as `codex` with one root record, done, whose owner was
  the current foreground.
- **Through Heeler.** In `RexProgramStatusLiveTests`, a stand-in typed into
  a lab shell, a shell started under the first argument `codex` that reports
  what it reads, was a codex Agent in the inventory a `RexHostSession`
  followed and in the Console's organization of it: Working at launch with
  the record owned by the foreground, then Blocked and Error as it reported
  them. A report with an unknown word left the record at error. Working then
  done moved the connection's turn count by one without starting a new count,
  and read Done; the same done again moved the record's time but not the
  count, so once marked as looked at it read Idle. Once it reported idle and
  exited, the terminal was no Agent, and the idle record stayed, owned by the
  stand-in. Heeler's session only read and received events.
- **Not seen.** A Linux server, a server instance change, and a block command
  run through the account's login shell. The terminals' processes are the
  server's children, so a new instance should mean new terminals with no
  records.

### Claude Code's record after a turn

Seen with a real Claude Code 2.1.327 in a `heeler-lab-` session on Rex
0.1.0-preview.14, API revision 12, macOS 27.0, local socket, 2026-11-18. A
newer Claude Code may word it differently; check before relying on it.

- **While a turn runs.** The root record reads `working`, and its `msg` says
  what the turn is doing (a foreground command's description, for one). The
  screen's last line offers `esc to interrupt`.
- **After a turn that left commands in the background.** The root record
  stays `working`, and its `msg` gives a count: `1 shell still running`, and
  `2 shells still running` after a turn that left two. The count is not the
  number of commands still running: with one left by an earlier turn and one
  by the latest, it read `1 shell still running`. Each command also has a
  child record, under its task's id, reading `working` with the command's
  description as its `title`. Claude Code is back at an empty prompt, the
  screen's last line no longer offers `esc to interrupt`, and Esc interrupts
  nothing. Its last line offers `↓ to manage`: Down, then Enter, shows the
  command with `x to stop`.
- **A later turn while the command still runs.** The root record reads
  `working` with what that turn is doing, and ends at `done` if the turn
  left nothing new in the background. An Esc during it interrupts that turn
  only: the root record reads `idle`, and the earlier command's child record
  and process stay.
- **When the command ends.** Claude Code takes a turn by itself to say so:
  the record reads `working` with what it is doing, then `done`.
- **What Heeler does.** `RexInventoryWire` reads a Claude Code root record
  that is `working` with a `msg` of a count followed by `still running` as
  `done`: the turn is over. The Agent then reads Done or Idle and the
  Composer offers Send, as on a Herdr TUI Host, where Claude Code's own hook
  reports the turn's end. Before that, the Agent read Working for as long as
  the command ran, and Stop pressed an Esc that did nothing. Heeler never
  stops the background command; that stays in the terminal. Checked in the
  Simulator against that Claude Code: while the record read `working` with
  `1 shell still running`, Chat and the Agents list read Idle and the
  Composer offered Send; a foreground turn sent then read Working with Stop,
  and Stop interrupted it. Only a shell was put in the background in this
  run; a background agent's wording was not seen.

### Processes and Chat evidence

From a lab run on Rex 0.1.0-preview.14, API revision 12, macOS 27.0, over a
disposable sshd, with inert stand-ins in `heeler-lab-` sessions (lab captures
kept outside the repository). No real agent ran, so what each program writes
is still ADR 0034's macOS evidence, not something seen inside Rex.

- **The machine.** `server.version` names a `platform`, `darwin_arm64` on an
  Apple silicon Mac. No Linux value was seen; `RexServerPlatform` reads one
  that names `linux` as Linux and anything else as unknown, and Heeler keeps
  the kernel it learns, so no exec runs only to ask for it. Each process read
  still picks its macOS or Linux reads with `uname -s` inside its own exec.
- **The foreground.** The `process` method and `process_changed` name the
  leader of the process group that holds the terminal, with its name, a first
  argument and a working directory. A launcher (node under `npx`, a shell
  script) is that leader, with the agent below it; nothing names the full
  command line or the terminal's own first process.
- **The terminal's variables.** Every program started in a terminal inherits
  `REX_SESSION` and `REX_BLOCK`, naming that terminal's session and block, and
  `REX_SERVER`, naming the server's socket. They match the terminal the
  process runs in, so they place it as `HC_SCOPE` does on herdr-core. A tmux
  started inside a terminal passes them on to its panes (inferred from how
  tmux hands its server's environment on, not observed), so Heeler also
  compares `TMUX`, `TMUX_PANE` and `HC_SCOPE` with the foreground's.
- **What macOS withholds.** As on herdr-core, `ps` shows no environment for
  Apple's own binaries, the login shell included, while SIP is on. A
  foreground shell's `REX_*` then cannot be read; an agent installed
  elsewhere shows its own.
- **What raises no event.** The foreground is announced only once the
  terminal prints, about 100 ms after the output. A process that took another
  one's pid under the same name, a program that ran another in place under
  the same pid, and a new file in a program's folders raised no event, so a
  Chat check waits for the next change Rex announces. Nor did a program that
  took its own name after it started
  ([Pi and Oh My Pi in a Rex terminal](#pi-and-oh-my-pi-in-a-rex-terminal)).
- **SSH channels.** The control and data links are direct-streamlocal
  channels, which the disposable sshd did not count against `MaxSessions`;
  exec and SFTP channels count as on any Host.
- **Programs.** Chat on a Rex Host is offered for Claude Code, Codex, Pi and
  Oh My Pi (`HostCapabilities.rexChatPrograms`). Claude Code and Codex each
  name their conversation in files their own process leads to, with nothing
  installed. Pi and Oh My Pi name theirs through Heeler's extension, which
  Chat adds when the user asks
  ([Pi and Oh My Pi in a Rex terminal](#pi-and-oh-my-pi-in-a-rex-terminal)).
  Grok Build and agy were not confirmed, and OpenCode names its only through
  Heeler's plugin, which a Rex Host never gets. Rex names no
  command line, so for a Codex the process read prints the words of its own
  argument vector that decide the shared server (`CodexLaunch.launchWords`),
  in order, and a placeholder for every other word, which never leaves the
  Host. A Codex there that holds no rollout, while the shared server's
  control socket exists, gets the shared server's notice and no list to
  choose from, as on the other Server Kinds. The read was checked against the
  macOS process table with an inert local stand-in named `codex`, not with a
  Codex inside Rex.
- **Deep process trees.** Past its 64-process cap the descendant walk names
  no process, the foreground included, so a foreground the walk leaves
  unnamed is still the one Rex named and binds; one the walk answered
  without is gone.

### Processes on Rex 0.1.0-preview.23, macOS and Windows

From reads on 2026-11-25 against Rex 0.1.0-preview.23 (API revision 19,
supporting 0 to 19), on macOS 27.2 with `ps -E`, and on Windows 11 with
Win32-OpenSSH, through `HostProcessReader`'s PowerShell read, three real
Claude Code 2.1.332 Agents running in Rex terminals there.

- **No `REX_SESSION`.** Every program in a terminal inherits `REX_BLOCK`,
  `REX_SERVER`, `REX_BIN_DIR` and `REX_AUTOSTART`, and none carries
  `REX_SESSION`, on macOS and Windows alike. A block id names one block on
  the server, so the binder places a process by `REX_BLOCK` and takes a
  `REX_SESSION` only when one is set. Heeler's extension for Pi and Oh My
  Pi still waits for both variables, so on this release it keeps no file in
  a Rex terminal.
- **The Windows foreground.** `process` names the image, such as
  `claude.exe`, with `argv0` either the bare word typed (`claude`) or the
  whole path (`C:\Users\<name>\.local\bin\claude.exe`), the working
  directory as a drive path, and `home` as `C:\Users\<name>`. A Claude Code
  started from a PowerShell has the PowerShell as `child` and itself as
  `foreground`; one started as the block's program is both. The Windows
  process read names the same process `claude`, in lower case without
  `.exe`, so Heeler takes each name Rex gave in that form there.
- **The registry on Windows.** Claude Code 2.1.332 wrote the process's
  creation FILETIME as decimal digits in `procStart`, as earlier releases
  did under herdr-core (herdr-compatibility.md), and it matched the Windows
  read's start. The Transcript was under
  `/C:/Users/<name>/.claude/projects/D--work-lms-phoenix/` over SFTP.
- **Size of the Windows read.** With Rex's two variables, `TMUX`,
  `TMUX_PANE`, `HC_SCOPE`, `HOME`, `CLAUDE_CONFIG_DIR` and Claude Code's two
  names, the encoded PowerShell command was 8,131 bytes against `cmd.exe`'s
  8,191. Native Windows runs no tmux, so the read there does not ask for
  `TMUX` or `TMUX_PANE`: 8,083 bytes for a four-digit pid, 8,115 for a
  ten-digit one.

### Pi and Oh My Pi in a Rex terminal

Rex 0.1.0-preview.14, API revision 12, macOS 27.0, 2026-11-18, from the iOS
Simulator over a disposable sshd, with a real Pi 1.5.2 and a real Oh My Pi
18.12.3 in a `heeler-lab-` session, each given tiny prompts in an empty
scratch folder (captures kept outside the repository). Heeler's extension is
the copy Host Helper 0.5.10 carries.

- **A name taken after the start.** `process_changed` named a starting Pi
  `node`, with `node` as its first argument, and no later event followed. A
  `process` read a moment later named the same pid with `pi` as its first
  argument, and the process reader names that pid `pi`, which is neither
  name Rex had announced. The foreground Heeler lists for a Pi so keeps
  Node's names for as long as the terminal stays listed, and a process read
  that goes by them finds no Pi. A Chat check therefore reads `process`
  itself first (`RexConsoleProjection.detailsWithCurrentForeground`).
- **The extension's file.** With the extension in the Agent's `extensions`
  folder, each program wrote `heeler-session/<pid>.json` beside that folder
  one to two seconds after it started. No Rex event marks it, so Chat looks
  again by its own clock after a check that could not tell
  (`AgentChatStore.Timing.unannouncedEvidenceChecks`), and bound within
  about two seconds of the start.
- **Leaving.** Pi's `/quit` reached the extension as a `session_shutdown`
  whose reason is `quit`, and the file was gone. Oh My Pi's `/exit` reached
  it with no such event, and the file stayed until the extension also
  removed it as its process ends. A file a process that had ended left was
  removed when the next session started in that Agent directory.
- **`/new`.** After `/new` in either program, Chat's next Send was held once
  with the notice that the Agent shows another conversation, Chat moved to
  the new one, and the Send after that went there.
- **Status and Stop.** Both reported their own status to Rex. Chat's Stop
  interrupted a Working turn of each: Pi printed that the operation was
  aborted, and Oh My Pi went back to idle. Oh My Pi read `working` during
  each of four turns, with an older and the newer copy of the extension
  alike.
- **Without the extension.** With only a copy from before the extension
  reported in a Rex terminal, Pi stayed at "can't tell", and Oh My Pi bound
  after its first message, from its own terminal breadcrumb.
- **Adding it.** Chat's offer named the Agent's one `extensions` folder,
  found from the process's own environment, and the file written there had
  the bytes this build carries, over the older copy. The Agent that was
  already running kept the copy it had loaded, and Chat said so.
- **Not seen.** A Linux Host, an Oh My Pi profile, a Pi before 1.1.0, either
  program started with its extensions off, and an iPhone or iPad.

### Real agents in the Simulator

Rex 0.1.0-preview.14, API revision 12, macOS 27.0, 2026-11-18: a second
agent drove the iOS Simulator, on candidate `842bbc5a`, over a disposable
sshd against a real Claude Code, Codex, Grok Build, agy, Pi and Oh My Pi in
one `heeler-lab-` session (read afterwards as Claude Code 2.1.327, codex-cli
0.169.1, Pi 1.5.2 and Oh My Pi 18.12.3; the others' versions were not
recorded). Of 63 checks 60 passed, 1 failed and 2 were not run. Its report
and captures are kept outside the repository.

- **All six.** Each was listed as an Agent with the status it reported. Each
  terminal was fitted to the screen as it opened (80 by 24 to 62 by 41,
  owned by Heeler) and given back on leaving, and a message from the
  Composer under it arrived once and was answered once. An image attached
  there reached each of the six, typed once with its message, and each
  named its color.
- **Chat, Claude Code and Codex.** Chat opened on the terminal's own
  conversation with no list to choose from. Consecutive Sends, a two-line
  message, a Send after an answer that drew links, an attached image and a
  text file each arrived once. A file edit's Blocked Card was approved once
  and declined once. Stop interrupted a turn that was printing. Coming back
  after 20 seconds in the background sent nothing twice, and Chat recovered
  by itself after the SSH link was held for 8 and for 80 seconds.
- **Failed: Stop while a command runs in the background.** A Claude Code
  that had put a shell command in the background was back at its prompt
  while Rex still read `working`, so Chat and the list read Working and
  Chat offered Stop. The Esc changed nothing and the command finished, three
  times out of three. (Fixed afterwards: Heeler reads that record as the end
  of the turn. See [Claude Code's record after a turn](#claude-codes-record-after-a-turn).)
- **Not run: Stop for Grok Build and Oh My Pi.** The Composer keeps Send for
  a Working Grok Build, and Oh My Pi's short turns showed no status record
  until `done` in that run (it read `working` in a later one, above).
- **A check that timed out.** One Claude Code Send was held with the notice
  that reading the conversation timed out and nothing was sent; nothing had
  reached Rex, the draft stayed, and a retry sent it once.

### Resume and close

- A client dropped without a close frame was kept for 60 seconds. A hello with
  its reconnect token within that time was welcomed as the same client, marked
  resumed, with a new token. A connection attached with `session.attach` got
  that session's events after resuming without attaching again
  (`g_reconnect`; the resume also in `RexControlWebSocketLiveTests` and
  `RexSSHLiveTests`).
- A reused token, or one sent after the 60 seconds, got a new client, not an
  error (`g_reconnect`).
- After a control connection closed with a close frame, that client's data
  link closed at once with 1001 (`g_reconnect`).

### Server restart and Program Resume

Rex 0.1.0-preview.25 (build 2147), API revision 24 (supports 0 to 24), macOS
27.0, 2026-11-26, on a server of its own (`rex server run` with its own
`--listen` socket, `--state-dir` and `--config`), through the `rex` CLI and
the server's log, and later a `RexHostSession` probe in the Simulator.

- Stopped with `rex server stop` and started on the same state directory, and
  again after `kill -9` (logged `clean_shutdown=false`), the server restored
  both sessions with the same session, window and block ids, under a new
  `instance_id` each time. `server.status` kept its `host_id`, which the API
  document says only tells whether two servers see the same files.
- A restored terminal started on a fresh screen: what it showed before was
  gone, and `title` answered empty until a program set one.
- Every terminal's first process had `OSC7577_TOKEN`, 22 characters. A
  stand-in that reported its own absolute path with OSC 7577, trusted by a
  rule in the server's `init.lua`, came back after both restarts with a new
  pid under `login`, then `/bin/sh -c '… (exec "$@") || :; exec "$rex_s" -l'`,
  and `process` named it as the foreground. `block.method` with
  `program_resume_records` lists a terminal's records with `chosen`,
  `trusted` and the command.
- The shell starts through `/usr/bin/login -flp <user>`, with the account's
  login shell and home whatever the server's environment holds, so a resumed
  program runs with the account's own configuration. For that reason no Claude
  Code was resumed here; Rex's `SessionStart` hook from `rex skill setup`
  (`rex __internal session-start --agent claude`) is what reports one.
- Until then Heeler took a new `instance_id` for another server: an open
  detail on its terminals was left behind with "This Terminal belongs to a Rex
  server that is gone", the Host's pins were removed, and turns, seen marks
  and Chat's cache went with the last instance. Updating the Rex app restarted
  the owner's server once that day, so updates reach this too.
- With ADR 0050's update of that day, a `RexHostSession` probe (not
  committed) over this server's local socket announced the restarted server
  with the first instance's core, after `rex server stop` and after `kill -9`
  each followed by a start on the same state directory, and read its
  inventory of both sessions.

### Terminal data connection

Lab captures `a_snapshot_skip` and `g_reconnect`, and the committed
`RexTerminalLiveTests`.

- A `data.connect` ticket is 16 bytes written as base64url without padding.
  It is good for one HELLO, within 60 seconds. A connection that sent no HELLO
  was closed after 5 seconds with 1002 (`g_reconnect`).
- A connection that stayed silent before its upgrade request was answered with
  the upgrade after 1 and 6 seconds and closed after 10 seconds (review probe).
  Heeler opens the channel before it asks for the ticket and sends the upgrade
  and the HELLO at once, so neither clock runs while it waits for an attach
  slot. The upgrade's clock does run while the ticket comes, so a channel the
  server ended before its upgrade was answered is opened once more with the
  same, still unused, ticket.
- The WELCOME said 60000 ms of retention. A connection dropped without a close
  frame was resumed with the exact byte count: same nonce, no new snapshot, and
  the output went on with nothing lost or repeated (`g_reconnect`; the resume
  also in `RexTerminalLiveTests`).
- A RESUME that counted too few bytes got reason 3, and one that counted too
  many got reason 5 and a 1002 close. After either, even a correct RESUME got
  reason 3, as did one after the client closed with 1000 (`g_reconnect`). In
  `RexTerminalLiveTests` a RESUME that counted none of the snapshot got reason
  3, and a new HELLO from the same control client then opened a new stream.
- A second HELLO for a block while the client's first connection to it was
  live got reason 2 (`RexTerminalLiveTests`).
- A review probe left a control connection and a data connection open, as the
  server side of a dead SSH connection would, and resumed the client on a new
  control connection. The server took the client back and closed the old
  control connection, but kept the old data connection open; that client's
  HELLOs for the block then got reason 2, four of them a second apart. A HELLO
  from a new client was welcomed meanwhile. A RESUME of the old stream on a
  new connection was welcomed with the same nonce and closed the old
  connection; with a count short of what the server had written into the old
  one it got reason 3 and still closed it, after which a HELLO was welcomed
  (review probe).
- The block's closing closed its connection with 4000 about 0.3 seconds later,
  after the stream's last messages. The control connection that opened the
  stream closing with a close frame closed it at once with 1001 and the reason
  `data provider canceled`; dropping without one did so 60 seconds later
  (`g_reconnect`).
- Every stream began with a snapshot starting `GHOSTSNP`, and the stream's
  first own message, a resize, began right where it ended, on every connection
  watched, busy ones included (`a_snapshot_skip`). Heeler never decodes the
  snapshot.
- Own messages: a resize with columns, rows, cell size in pixels and owner;
  a theme right after the first resize when the colors are not the defaults;
  and the program's exit, whose code was 0 on macOS whatever the program
  returned. A look-alike with another nonce that a program printed passed
  through as output (`a_snapshot_skip`).

### Terminal redraw

Lab captures `b_redraw`, `b2_edges` and `c2_handoff`, and the committed
`RexTerminalLiveTests`.

- `format` as `vt` with every `extra_*` flag and `unwrap` reproduced text, soft
  wraps, styles and modes in a Rex terminal fed the redraw, for 13 cases.
  `unwrap` broke when autowrap was off. The redraw never clears first, and
  carries no title, cursor shape, OSC 10 or 11 colors, saved cursor, or primary
  screen and scrollback behind the alternate screen (`b_redraw`).
- In Heeler's own Ghostty, a full reset followed by the redraw matched the
  server's text of the terminal: the whole history with soft wraps joined, and
  the visible rows. That held for colored output, 3,093 lines of scrollback read
  in 64 KiB pages, the alternate screen, the primary screen once the program
  left it (after the repaint that follows), wide and wrapped lines, and output
  that kept coming during the first paint. A separate `title` read matched the
  server's (`RexTerminalLiveTests`). Colors and styles were not compared there.
- Heeler's per-row viewport reader ends a row whose last cell is the spacer
  of a wide character that wrapped with that character too; the server's text
  shows it on the next row only. The whole history read agrees, so the cells
  agree (`RexTerminalLiveTests`).
- A redraw asked for with `max_bytes` 983,040 fit the 1 MiB message limit. A
  reply with an `id` had more, read with `blob_read` from an `offset` in UTF-8
  bytes read so far. A 40,000-line redraw, about 3 MB, failed whole with
  `too_large` and paged to identical bytes (`b2_edges`).
- Output kept arriving after the redraw was asked for unless the program was
  idle. The rule Heeler uses (exact only when no output arrived from the
  request until the whole answer plus a 30 to 60 ms settle; three attempts;
  then best effort, repainted after 250 ms of quiet) ended correct in 59 of 59
  handoffs, some through a 40 ± 30 ms delay (`c2_handoff`). A program writing a
  line about every 12 ms got a best-effort first paint and one exact repaint
  once it stopped (`RexTerminalLiveTests`).

### Terminal colors and what stays out

Probes on Rex 0.1.0-preview.23 on macOS, 2026-11-25, from a client that said
hello at revision 12, on a lab session made and destroyed for them.

- `set_theme` on a block with no owner applied at once. The block's open
  data stream then carried
  `{"type":"theme","foreground":"#111111","background":"#fafafa"}`, with only
  the colors given; an empty `set_theme` carried `{"type":"theme"}`. A stream
  opened while the colors were the built-in ones began with its resize and
  no theme.
- The `vt` redraw with every extra carried all 256 palette entries as OSC 4
  in `rgb:rr/gg/bb` form, entry 1 as the theme had set it, and no OSC 10, 11
  or 12. Heeler writes the theme's colors after each paint's reset.
- After the shell sent `CSI 5 SP q`, the redraw carried no cursor shape, and
  no `format` extra, `modes` entry or stream message names one. `help.all`
  at revision 19 names none either.
- With 40 lines printed and then the alternate screen entered, `modes` said
  `alternate`, and `format` as `vt`, `text` and `html` held none of the 40
  lines: only the screen shown.

### Terminal size and ownership

Lab capture `e_size`, three lab clients on one block.

- A block's size is its owner's. A `resize` request from a client that did not
  own the block was kept in a list of wanted sizes and changed nothing; once
  the block had no owner, a request applied at once, and the stream's resize
  message followed.
- When the owner let go of the block, the size stayed as it was: a size another
  client had asked for earlier was not applied until it asked again.
- `own_block` with mode `request` succeeded only for a block with no owner;
  mode `take` succeeded at once, and the taker's wanted size applied.
- An owner whose control connection dropped without a close frame lost the
  block at once to another client, and the terminal took that client's size;
  when the owner resumed, the block and its size went back to it. An owner
  that closed with a close frame lost its wanted size as well. The client the
  block went to was one in line for it (`r6_ownership` below), not merely one
  with a wanted size.
- A `resize` with 0 or more than 65535 columns or rows was refused with 400.
- In the maintainer's own session, the Rex desktop app's client owned every
  block, so a request from Heeler there would not apply.
- Live suite `RexTerminalAttachLiveTests` (Heeler's runner and view store
  over a local socket, the store kept off screen so it never takes the
  size): a shell block another control client created with
  `session.create` and then attached to was owned by a client other than
  Heeler's. Heeler's request for 100x30 left the block at 80x24, and the
  block stayed with its owner. The same run painted the terminal after
  `session.attach` and `data.connect` from Heeler's own control client,
  followed its output, and finished the view without a reattach once the
  session was destroyed.

Lab captures `r6_ownership` and `r6b_handover`, three lab clients on one lab
block: one standing in for another device, which created it and owned it at
100x30; one standing in for Heeler, attached with a data connection open and a
wanted size of 62x51; and a third.

- A take (`own_block`, mode `take`) from Heeler's stand-in, which did not own
  the block, was answered in about 3 ms, listing the stand-in as owner. Every
  attached client heard the owner change, with the reason `take`, and then the
  size change. The stand-in's earlier wanted size, 62x51, applied at once; its
  own stream carried a resize message naming it as owner, and that message
  and the owner change both arrived before the answer.
- The other device taking the block back moved it the same way, to its own
  wanted size.
- A give back (`disown_block`) from a client that did not own the block was
  answered with the current owner and raised no event: it only took the
  client out of line.
- A give back from the owner passed the block to the client in line, with the
  reason `disown`, and that client's wanted size applied. With nobody in line,
  the block was left with no owner and kept its size.
- A take of a block with no owner applied at once. While a client owned the
  block, another's `resize` only noted a wanted size; the owner's own `resize`
  applied at once.
- A client that had only asked for a size, and never claimed the block, was
  never passed it: an owner that closed with a close frame then left the block
  with no owner (reason `disconnect`) at its size.
- An owner that dropped without a close frame passed the block to the client
  in line (reason `lost`), or left it with none; when it resumed, it got the
  block back (reason `restore`), from no owner too. The resuming client was
  not sent that `restore` event itself.
- In line: the stand-in took, the other device took back, so the stand-in
  stayed in line, and the other device dropped. The stand-in was passed the
  block at its wanted size; the other device resumed and got it back at its
  own (`r6b_handover`).
- The same, but the stand-in gave up the block it was passed while the other
  device was away: the block was left with no owner at the stand-in's size,
  and the other device did not get it back when it resumed (`r6b_handover`).
  Heeler therefore leaves a block the server passed to it because its owner
  dropped as it is. One passed on with `disown` or `disconnect` has no owner
  to come back for it, so Heeler gives it back like a size it took.
- A client that took ranked ahead in line of one that had only requested
  (`own_block`, mode `request`): the taker was passed the block
  (`r6b_handover`).
- A take or give back of a closed block was refused with 400. A take from a
  client attached to no session was refused with 409, and from one attached
  only with `session.attach_all` with 400; a `resize` from that client was
  accepted and noted as a wanted size.
- Live suite `RexTerminalSizeLiveTests`, as first written for a size taken
  only at a tap (Heeler's runner and view store over a local socket): the
  lab's own client created a shell block at 100x30, asked for that size and
  took the block. Heeler's 80x24 view reported a size set elsewhere and
  showed its notice; the take from the view made Heeler's client the owner
  and the server's grid 80x24; the view going off screen passed the block
  back to the lab's client at 100x30; and the view coming back took nothing.

Lab capture `r8_fit_before_paint`, two lab clients on one lab block: one
standing in for another device, which created it and owned it at 100x30, and
one standing in for Heeler, attached to the session with no data connection
and no size asked for yet.

- The stand-in's take was answered in about a millisecond with the stand-in
  as owner, and the grid stayed 100x30: it had asked for no size. Its resize
  to 80x24 as the owner, sent after the answer, applied at once, answered in
  about two milliseconds. A data connection opened after both answers began
  with a resize message at 80x24 naming the stand-in as owner, before any
  paint.
- With the stand-in's stream already open, the other device took the block
  back at 100x30 and the stand-in asked for 70x20 without owning it. The
  stand-in's take then applied 70x20 at once, and its stream's resize message
  naming it owner arrived before the take's answer.
- Live suite `RexTerminalSizeLiveTests`, rewritten for a shown terminal that
  takes its own size (Heeler's runner and view store over a local socket):
  the lab's client created a shell block at 100x30, asked for that size and
  took the block. Heeler's 80x24 view, opened shown, heard 80x24 with its own
  client as owner as its first grid, and showed no notice; the server's grid
  was 80x24 with Heeler's client as owner. The lab's client then took the
  block back at 100x30 and kept it for the rest of the showing, while the
  view offered its notice; the view going off screen left the block with the
  lab's client, coming back took the size again, and going off screen once
  more passed the block back to the lab's client at 100x30.

### Query answers

Lab capture `d2_queries`.

- Rex answered a program's queries itself, from its own terminal: primary and
  secondary device attributes, cursor position, status, version (as a DCS
  string), a palette color (OSC 4), a mode's state and the kitty keyboard
  flags. Anything Heeler's emulator answered as well would reach the program
  as typed input; Heeler drops those answers (`RexTerminalKeyReader`).
- A background color query (OSC 11) got no answer. Answers to the window size
  reports (`CSI 14 t`, `CSI 18 t`) were not captured.
- In `RexTerminalKeyReaderTests`, Heeler's own Ghostty wrote 18 answers to 21
  queries (device attributes, status and cursor reports, version, colors, mode
  states, kitty flags, window sizes, color scheme, a setting and a terminfo
  capability); none of them left.

### Terminal input

Lab capture `d_input` (the input run), each case on a lab shell whose program
recorded the bytes it read, under a set of modes.

- Writes sent one at a time, each after the last one's answer, arrived in
  order (100 of 100). Writes sent without waiting arrived out of order in each
  of three runs of 300, and their answers did not come back in request order.
  300 paste events sent without waiting arrived in order. 200 writes and
  events mixed and sent without waiting did not.
- A `write` passed its text's UTF-8 bytes to the program unchanged: C0
  controls, ESC, DEL, C1 code points as UTF-8, a lone line feed, and 64 KiB
  and 400,000 bytes in one request. A lone surrogate escaped in the JSON
  arrived as U+FFFD. An answer counted the bytes written.
- A paste event reached the program framed with the paste markers only while
  it had bracketed paste on, line feeds kept. With it off, a line feed became
  a carriage return, and CR LF two carriage returns. ESC and other C0 controls
  in a paste became spaces either way, so an end marker inside the text could
  not end the paste early.
- A mouse event reached the program only under mouse tracking, in the
  program's own encoding, SGR or legacy, at the cell given (0-based in the
  event, 1-based in the report). Motion, with a button held or none, reached
  it under any-motion tracking (1003) and not under click tracking (1000);
  button tracking (1002) was not tried. A wheel event with
  `delta_y` -1 reported wheel up and +1 wheel down, `delta_x` +1 wheel right;
  a delta of 3 lines or 40 pixels still gave one report, and an event with no
  cell reported the top left one.
- A focus event reached the program as `CSI I` or `CSI O` only with focus
  reporting on.
- Live suite `RexTerminalInputLiveTests` (Heeler's runner, view store and
  input controller over a local socket, the store kept off screen so it
  never takes the size), on a shell block another control
  client had created and still owned while Heeler typed: writes to a block
  Heeler's client did not own were applied. 300 numbered tokens, each its own
  write from the view, sent as fast as the view handed them over to a shell
  running `cat -v` with echo off, all came back in the server's text, once
  and in order. A two-line paste reviewed through the input controller came
  back as two lines with no paste markers while the program had bracketed
  paste off, and between `^[[200~` and `^[[201~` once it turned the mode on.
  A bracketed paste carried in the view's own bytes, with an ESC inside, went
  as a paste event; `cat -v` showed that ESC as a space in both modes. The
  view finished once the session was destroyed.

### Chat's reads and input

Rex 0.1.0-preview.14, API revision 12, macOS 27.0, 2026-11-17: lab captures
`k1_typing` for input without a view, `k2_screen` and `k3_modes_keys` for the
screen and modes, `k2b_cost` and `k2c_slowlink` for what reads cost, and
`k9_blob_memory`, `k9b_blob_lifetime` and `k9c_blob_bound` for what reads
leave on the server, against made-up lab programs in `heeler-lab-` sessions.

- A control client that had only called `session.attach_all`, never
  `session.attach`, could `write` to a block and send it a paste event, and
  the program read both, whether nobody owned the block or another lab client
  did. No owner or size change was announced while it typed, the size stayed
  the owner's, and the typing client never joined the block's wanted sizes.
  Requests from two clients that each waited for their answers arrived in
  order.
- `format` as `vt` with soft wraps kept as rows answered with the history,
  then every row of the screen, a blank row as an empty line, the lines joined
  by CR LF and no line end after the last; the screen was exactly the last
  `rows` lines. While the alternate screen was up, the answer held its rows
  alone, with nothing saying which screen it was; the modes answer says.
- Inside rows the answer held three kinds of sequence: SGR, `CSI n C` over
  blank cells and tab gaps, and `CSI n X` for cells blanked in a background
  color, each time followed by a `CSI n C` of the same count. Each styled run
  began and ended with a reset, so no style ran into the next line. Wide
  characters came as themselves.
- Asked for the kitty keyboard flags, the answer ended with `CSI = flags ; 1 u`
  after the last row while the program had any flag set, and had nothing
  added while it had none. The modes answer carries no kitty flags.
- A read of the answer's tail by offset matched the whole answer's end byte
  for byte. An offset inside a character came back as U+FFFD for the cut
  part. A first page asked for 256 bytes came back with 249 characters of a
  503-byte answer, which fits a limit counted on the text as JSON escapes it:
  a page can stop short of what was asked.
- No argument limits the text to the visible screen; arguments `format` does
  not know were accepted and ignored.
- A `format` answer longer than its first page left the rest on the server
  behind an id, the 32-byte read for the kitty flags included. The server
  kept only the latest few: of 60 reads of a 10,000-line history
  (459,059 bytes an answer) sent back to back, only the last 4 ids could
  still be read. With no newer read, an id was still readable after 40
  seconds, and a read on another client did not end it. A screen read like
  Chat's (a 1 KiB first page, then a 16 KiB tail) once a second for 330
  reads over five and a half minutes raised the server's footprint from 49
  MB to between 57 and 64 MB, flat throughout, and it was back to 53 MB
  within 15 seconds of the last read; the server's RSS did not grow.
- On the local socket, whole reads of a 10,000-line history every second, then
  every 150 ms, left another block's typing and the connection's events at
  their usual pace. Through a lab proxy of about 50 ms each way and 10 Mbit/s,
  a whole read took about half a second and held typing and events back behind
  it, while a tail read (a 1 KiB first page, then the last 16 KiB) every
  second took about a quarter of a second and left them at their usual pace.
- Live suite `RexChatTypingLiveTests` (a `RexConsoleProjection` on its own
  control connection over the local socket, 2026-11-17), on a lab block its
  creating client owned, running a stand-in named `codex` that reported idle,
  turned bracketed paste on and printed what it read with `cat -v`: the
  screen read held the grid's 30 rows; keys, a paste, a two-line paste,
  Composer Send's paste and Enter, and a Blocked Card answer over the screen
  it read each arrived once, in order, pastes framed by the program's
  markers; and the block's size answer, owner included, read the same before
  and after.

Rex 0.1.0-preview.14, API revision 12, macOS 27.0, 2026-11-18: lab captures
`m1_vt_grammar` (410 answers), `m2_holes` (82) and `m3_reader_holes` (39),
each from a 40 by 8 lab block whose program wrote made-up bytes to its
terminal unchanged, and one read-only read of a real Codex screen.

- A real Codex (codex-cli 0.169.0) first showed the gap: its answer's last
  lines drew two version numbers as hyperlinks, which the reader of
  2026-11-17 refused, so every check of its input box failed while the
  composer was empty.
- Hyperlinks came as OSC 8 ended by `ESC \`, also where the program ended
  them with BEL: `ESC ] 8 ; ; URI ESC \` to open, or with `id=` and a value
  in place of the empty parameters, and `ESC ] 8 ; ; ESC \` to close. Of the
  program's parameters Rex kept at most one `id=` with a value, and wrote
  nothing for any other. URIs and id values held no C0 control, which Rex
  dropped. In URIs DEL, every C1 control (U+009C included) and U+FFFD came
  through as written, and in id values DEL, the C1 controls tried and U+FFFD
  did. A link whose parameters and URI the program wrote in more than 2,046
  bytes was dropped whole, its text kept.
- A link stayed open past a row's end and was not opened again on the next
  row. Rex closed it just before the next cell written outside it, which
  could be rows later, or after the answer's last written cell. A link of one
  URI written cell by cell without an id came back opened at each cell.
- SGR came one attribute a sequence, each change restating the cell's whole
  style after a reset, and each styled row still ended with a reset: `0`,
  `1`, `2`, `3`, `4`, `4:2` to `4:5`, `5`, `7`, `8`, `9`, `53`, and `38`,
  `48` and `58` followed by `5;n` or `2;r;g;b`. The colon came only in `4:2`
  to `4:5`. What a program set with other codes came in these forms (30 to 37
  and 90 to 97 as indexed colors, 21 as `4:2`, 6 as `5`, colon colors with
  semicolons), and no code that turns one attribute off came at all.
- With a URI holding a byte that is not UTF-8, `format` counted the answer's
  total in the program's bytes and `blob_read` in the text after
  replacement, so the totals differed and a paged read stops there.
  `RexChatScreen` takes a page only with the first answer's total, so on
  that terminal every screen or kitty flags read longer than its first page
  fails while the link stays in the answer (ADR 0055's consequences).
- A tail read starting anywhere inside a link's sequence lost only its cut
  line, since no sequence held a line end, and pages that ended inside one
  joined into the whole answer.
- For 25 of 138 marked strings, the cells Rex gave differed from Heeler's
  cell width: some Devanagari and Thai clusters, U+4DC0, a skin tone
  modifier after a letter, U+3248 and its neighbors, and unassigned code
  points in wide blocks.
- `RexChatScreen` takes these forms beside the SGR it took before, and still
  fails a read on anything else (`RexChatScreenTests`). Read through it, the
  real Codex screen gave its 53 rows, and Codex's input box on it read as
  empty.

### The Agent detail

Rex 0.1.0-preview.14, API revision 12, macOS 27.0, local socket, 2026-11-17,
with Rex Agents opening the Agent detail
([ADR 0056](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md)).

- `RexChatTypingLiveTests`, `RexTerminalSizeLiveTests` and
  `RexProgramStatusLiveTests` passed again in one run, 3 of 3. A read-only
  lab client compared the server before and after: the same server
  instance, no `heeler-lab-` session left, and every other terminal's size
  and owner unchanged.
- What each surface of the detail sends is checked against `FakeRexServer`,
  not a live server: on Chat no `session.attach`, `data.connect` or
  `own_block`; on the Terminal surface the take before `data.connect`, and a
  give back on leaving (`RexConsoleTests`).

### Documented for API revision 12, not observed

Rex's API document for this revision says the following; no lab run, probe or
live test has checked it. Heeler's code does not depend on any of it except
where noted.

- A client whose queued events grow past about 8 MiB is closed with 1008.
- A request over the message limit closes the connection with 1009; other
  protocol breaches close it with 1002, and a binary message with 1003.
- Calling `session.attach_all` a second time changes the connection's event
  scope.
- A client misses for good any event raised while it had no connection, and
  its next connection restarts event numbering at 1. Heeler reads the whole
  inventory on every new connection either way.
- A close frame ends the client at once, so its token no longer resumes it.
- Reads on a connection attached to no session are refused with 409.
- A response's seq tells how far the connection's event stream had got when
  the server took the request up, which is what `RexInventoryBook` orders
  reads and events by.
- Relabeling a detached block raises no event and leaves the view's revision
  unchanged. Heeler reads a session with detached terminals again once a
  minute for this reason.
- A data connection closed with 1013 asks for a new stream, as when more
  output piled up than the server could keep; 1008 and 1011 mean the data
  source is unavailable or failed. Heeler starts a new stream after each.
- A client that closes its data connection with any code but 1000 leaves the
  stream to resume, as a drop does.
- `format` takes no argument that limits scrollback, so Heeler pages the whole
  redraw. `max_bytes` is capped at 983,040 and counts the JSON-escaped text.
  Chat's screen read asks for no more than that cap in a page.
- The server may run a block's methods concurrently, so Heeler never relies on
  the order of the redraw and title reads.
- A take or give back that names no blocks, or an empty list, applies to every
  block in the session. Heeler always names the one block it means.

### Not observed

- A Linux server, a server started by a login service, and any revision other
  than 12.
