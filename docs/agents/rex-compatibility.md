# Rex compatibility observations

Consult this reference for the Rex control connection, inventory reads and
events, and resume and close behavior on Rex Hosts. These observations are
historical evidence, not fresh tests on the installed server. Each names the
Rex version it was seen on; check it before applying an observation to a newer
server. All are written in Heeler's own words; no Linux server has been
observed yet.

## Current routing

- Rex Hosts are a fourth Server Kind, offered in every build and still
  experimental for users
  ([ADR 0047](../adr/0047-rex-hosts-reach-a-running-rex-server-by-its-socket.md)).
  Heeler reaches a running server's Unix socket over a direct-streamlocal SSH
  channel and never runs `rex` or starts a server.
- One WebSocket control connection per Host carries everything but terminal
  data: hello at API revision 12 only, `server.status`, `session.attach_all`
  and the inventory reads
  ([ADR 0048](../adr/0048-rex-hosts-follow-inventory-on-one-control-connection.md)).
  `RexHostSession` owns it; `RexInventoryFollower` and `RexInventoryBook` read
  and order the inventory.
- A terminal's output arrives on a data connection of its own
  (`RexDataLink`). Heeler skips the stream's snapshot (`RexStreamScanner`) and
  paints from the server's `vt` redraw instead (`RexTerminalPaint`);
  `RexTerminalStream` runs the three for one view.
- The Console opens a Rex terminal from the server's redraw
  ([ADR 0049](../adr/0049-rex-terminals-open-for-viewing-from-the-servers-redraw.md)):
  `RexHostSession.withTerminal` calls `session.attach` on the Host's control
  connection and holds the block to one data connection, and
  `RexTerminalAttach` turns its stream into the view's bytes and asks for the
  view's size.
- Input to a Rex terminal goes on the control connection one request at a
  time ([ADR 0050](../adr/0050-rex-terminal-input-goes-one-request-at-a-time.md)):
  typed bytes as text through the terminal's `write`, read by
  `RexTerminalKeyReader`; pastes, focus changes and mouse reports text cannot
  carry through `block.event`.
- A Rex terminal's size is taken only when the user taps the notice's Fit to
  Screen ([ADR 0051](../adr/0051-rex-terminal-size-is-taken-only-when-the-user-asks.md)):
  `RexTerminalAttach` sends `session.own_block` with mode `take` for the one
  block, then the view's grid, and gives the size back with
  `session.disown_block` when the view stops showing the terminal or the
  attach ends, unless the server passed the block to Heeler because its
  owner's link dropped.

## Known limits

What Heeler's Rex support has not covered, as of Rex 0.1.0-preview.14 (API
revision 12). The user guide, [Connect Rex](../guides/rex.md), says the same
in users' words.

- **One API revision.** Only revision 12 is accepted; a server that welcomes
  no hello at revision 12 is refused as `rexUnsupportedRevision`, naming the
  revision it offers when it says ([ADR 0047](../adr/0047-rex-hosts-reach-a-running-rex-server-by-its-socket.md)).
- **No Linux server.** The Linux socket places, the `/proc/net/unix` socket
  check and a server started by a login service have never met a running
  Linux Rex server; `scripts/test-server-kind-detection.py` runs the
  detection script against fake Linux homes only. Every observation below is
  from macOS.
- **What the first paint leaves out.** The `vt` redraw carries no title,
  cursor shape, OSC 10 or 11 default colors or saved cursor, and while a
  program uses the alternate screen none of the primary screen or scrollback
  behind it (`b_redraw`). Heeler reads the title on its own and follows its
  events, keeps its own colors, and paints the primary screen again once the
  program leaves the alternate screen; the cursor shape stays Heeler's until
  the program sets it again. With autowrap off, soft wraps are not joined. A
  program that never pauses for 250 ms keeps a best-effort first paint, and
  a redraw past 32 MiB ends the attach as too long to show
  ([ADR 0049](../adr/0049-rex-terminals-open-for-viewing-from-the-servers-redraw.md)).
- **Another client's size is not fitted.** A block another client owns at
  another grid shows at the server's grid until the user takes the size.
  Lines wider than the view wrap at the view's width, in the first paint,
  whose redraw rejoins soft-wrapped lines, and in output that runs past the
  view's last column; a program that places its rows with cursor moves
  mostly shows their left part. There is no view scaled to or cut at the
  remote grid
  ([ADR 0051](../adr/0051-rex-terminal-size-is-taken-only-when-the-user-asks.md),
  as [ADR 0045](../adr/0045-tmux-hosts-poll-inventory-and-attach-through-control-mode.md)
  says for tmux).
- **Existing terminals only.** Nothing is created, closed or renamed, and no
  layout changes; no Agents, Chat, Composer, notifications, Live Activities
  or Usage.
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
  foreground changes, its directory included.

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
  over a local socket): a shell block another control client created with
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
  to come back for it, so Heeler gives it back like a size the user took.
- A client that took ranked ahead in line of one that had only requested
  (`own_block`, mode `request`): the taker was passed the block
  (`r6b_handover`).
- A take or give back of a closed block was refused with 400. A take from a
  client attached to no session was refused with 409, and from one attached
  only with `session.attach_all` with 400; a `resize` from that client was
  accepted and noted as a wanted size.
- Live suite `RexTerminalSizeLiveTests` (Heeler's runner and view store over a
  local socket): the lab's own client created a shell block at 100x30, asked
  for that size and took the block. Heeler's 80x24 view reported a size set
  elsewhere and showed its notice; the take from the view made Heeler's client
  the owner and the server's grid 80x24; the view going off screen passed the
  block back to the lab's client at 100x30; and the view coming back took
  nothing.

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
  input controller over a local socket), on a shell block another control
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
- The server may run a block's methods concurrently, so Heeler never relies on
  the order of the redraw and title reads.
- A take or give back that names no blocks, or an empty list, applies to every
  block in the session. Heeler always names the one block it means.

### Not observed

- A Linux server, a server started by a login service, and any revision other
  than 12.
