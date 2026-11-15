# Rex compatibility observations

Consult this reference for the Rex control connection, inventory reads and
events, and resume and close behavior on Rex Hosts. These observations are
historical evidence, not fresh tests on the installed server. Each names the
Rex version it was seen on; check it before applying an observation to a newer
server. All are written in Heeler's own words; no Linux server has been
observed yet.

## Current routing

- Rex Hosts are an experimental fourth Server Kind behind `RexHostsExperiment`
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
- The Console opens a Rex terminal for viewing only
  ([ADR 0049](../adr/0049-rex-terminals-open-for-viewing-from-the-servers-redraw.md)):
  `RexHostSession.withTerminal` calls `session.attach` on the Host's control
  connection and holds the block to one data connection, `RexTerminalAttach`
  turns its stream into the view's bytes and asks for the view's size, and
  input stays shut behind `RexTerminalInput`.

## Versioned observations

All below: Rex 0.1.0-preview.14, API revision 12, macOS 27.0, local socket,
2026-11-15. Each bullet names where it was seen: a lab capture kept outside the
repository (`f_control` for the control connection and layout operations,
`g_reconnect` for drops and resumes, `a_snapshot_skip` for how a terminal's
stream starts, `b_redraw` and `b2_edges` for the redraw, `c2_handoff` for
first paints, the input run), a review probe, the Simulator acceptance run, or
a committed live test.

### Control connection

- The server welcomes a hello at revision 12 with a client id and a reconnect
  token. The welcome's limits put messages at 1 MiB (`f_control`).
- An idle control connection received one server ping at 120 seconds in a
  130-second watch (`g_reconnect`). A review probe that never answered pings
  saw them at 120, 180 and 240 seconds, then a close with 1001 and the reason
  `keepalive timeout` about 300 seconds in; the server listed that client as
  lost, and a hello with its token resumed it as the same client. Heeler's own
  pings, once a second, kept a link up (`RexControlWebSocketLiveTests`).
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
  block at once to the next client with a wanted size, and the terminal took
  that client's size; when the owner resumed, the block and its size went back
  to it. An owner that closed with a close frame lost its wanted size as well.
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

### Query answers

Lab capture `d2_queries`.

- Rex answered a program's queries itself, from its own terminal: primary and
  secondary device attributes, cursor position, status, version (as a DCS
  string), a palette color (OSC 4), a mode's state and the kitty keyboard
  flags. Anything Heeler's emulator answered as well would reach the program
  as typed input; Heeler drops those answers (`RexTerminalAnswerFilter`).
- A background color query (OSC 11) got no answer. Answers to the window size
  reports (`CSI 14 t`, `CSI 18 t`) were not captured.

### Documented for API revision 12, not observed

Rex's API document for this revision says the following; no lab run, probe or
live test has checked it. Heeler's code does not depend on any of it except
where noted.

- A client whose queued events grow past about 8 MiB is closed with 1008.
- A request over the message limit closes the connection with 1009; other
  protocol breaches close it with 1002, and a binary message with 1003.
- Calling `session.attach_all` a second time changes the connection's event
  scope.
- Events raised while a client has no connection are not delivered later, and
  the new connection numbers its events from 1 again. Heeler reads the whole
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

### Not observed

- A Linux server, a server started by a login service, and any revision other
  than 12.
