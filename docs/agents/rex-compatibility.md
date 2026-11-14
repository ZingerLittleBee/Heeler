# Rex compatibility observations

Consult this reference for the Rex control connection, inventory reads and
events, and resume and close behavior on Rex Hosts. These observations are
historical evidence, not fresh tests on the installed server. Each names the
Rex version it was seen on; check it before applying an observation to a newer
server. All were made in Heeler's own words from lab runs against a local
server; no Linux server has been observed yet.

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
2026-11-15, from the lab scripts kept outside the repository.

### Control connection

- The server welcomes a hello at revision 12 with a client id and a reconnect
  token. Message size is limited to 1 MiB in the welcome's limits.
- The server pings every 120 seconds and drops a client after three unanswered
  pings with close code 1001. Heeler also pings on its own interval.
- Every response carries `seq`: the last event the server queued for this
  connection before it started the request, 0 when none. Events are numbered
  from 1 with no gaps on one connection.
- A client with more than about 8 MiB of events queued is closed with code
  1008 ("event backlog exceeded"). A message over the size limit closes with
  1009; malformed frames or messages with 1002, 1003 or 1007.

### Attach scopes

- `session.attach_all` attaches the connection to every session, including
  ones created later, and answers with the session list (id and label each).
  Calling it again replaces the scope; it works after a resume.
- Scope `session` delivers session structure and lifecycle events. Scope `all`
  adds each block's own events (`block_event`) and client events. Heeler asks
  for `all`.
- With only `session.attach_all`, a connection can read `session.view`,
  `session.list_blocks`, and a terminal's title, process, format and size.
  `data.connect` answers 409 and `own_block` 400 until the connection also
  calls `session.attach` for that session.
- A connection attached to nothing gets 409 on `session.view`.

### Inventory reads

- `session.view` answers with a revision, the session label, the active
  window, and its windows; each window lists layers (`tiled` or `floating`),
  each with a layout tree of splits (`before`, `after`) and leaves naming
  blocks, and the facts of each block in the layer (label, creator, flavor,
  owner).
- `session.list_blocks` lists every block of the session in block id order,
  each with its placement: `placed` with a window id, or `detached`. The view
  leaves detached blocks out.
- Terminal blocks are created by `com.superlogical.terminal`, flavor
  `com.superlogical.terminal.shell` for a shell. Blocks of other creators are
  not terminals.
- A new window's label is `Window` followed by the last eight hex digits of
  its id with dashes removed. A new shell block's label is `shell`.
- A terminal's `title` method answers an empty title until a program sets one.
  Its `process` method names the foreground process, with its name and working
  directory, or no foreground.

### Events per operation

Session events arrive wrapped with their session id; `session_created` is
server-wide and carries the session's id and label.

- New layer: `block_created`, `block_owner_changed`, `session_view_changed`,
  then process changes as the shell starts.
- New detached block: `block_created`, `block_owner_changed`, with no view
  change.
- Block label, move, float and detach: `session_view_changed` alone.
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

- A client dropped without a close frame is kept for 60 seconds. A hello with
  its reconnect token within that time is welcomed as the same client, marked
  resumed, with a new token; its attachments and scope are kept.
- Events sent while it was away are not replayed, and seqs start again at 1.
- A reused or expired token gets a new client, not an error.
- A close frame makes the server forget the client at once.

### Not observed

- A Linux server, a server started by a login service, and any revision other
  than 12.
