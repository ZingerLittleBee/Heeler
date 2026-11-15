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

## Versioned observations

All below: Rex 0.1.0-preview.14, API revision 12, macOS 27.0, local socket,
2026-11-15. Each bullet names where it was seen: a lab capture kept outside the
repository (`f_control` for the control connection and layout operations,
`g_reconnect` for drops and resumes, the input run), a review probe, the
Simulator acceptance run, or a committed live test.

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

### Not observed

- A Linux server, a server started by a login service, and any revision other
  than 12.
