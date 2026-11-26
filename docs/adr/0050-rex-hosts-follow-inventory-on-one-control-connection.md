---
status: proposed
---

# Rex Hosts follow their inventory on one control connection

A confirmed Rex Host (ADR 0049) lists its Terminals in the Console. Rex keeps
its own organization, sessions holding windows holding layers of blocks, and
pushes numbered events over the control connection as it changes. Heeler has
to read that organization once, keep it current, and survive dropped links and
restarted servers without showing a stale or half-read list.

## Decision

- Each Rex Host has one control connection, owned by `RexHostSession`, as a
  tmux Host's connection is owned by `TmuxHostSession`. Inventory, server
  identity and, later, terminal attachment requests all go over it. Terminal
  data takes channels of its own (ADR 0049).
- The connection attaches to every session at once with `session.attach_all`,
  asking for every event, terminals' own events included, so a row's title,
  program and directory follow `title_changed` and `process_changed` without
  polling. Events a row does not use, such as bells and clipboard writes, are
  skipped as they arrive.
- The inventory is read, never assumed: the session list from
  `session.attach_all`, each session's structure from `session.view` and
  `session.list_blocks`, and each terminal's details once per connection from
  its `title` and `process` methods (and, since ADR 0054, `program_status`). A response's seq says how far the
  connection's event stream had got when the server took the request up, so an
  event numbered above it is newer than the response and one at or below it is
  already in it. An event that changes a session's layout reads its
  structure again. One structure read is in flight per session, so a burst of
  events costs that read and one more. No response replaces what a newer event
  or response said: a closed block stays closed, a view with a lower revision
  is not applied, and a title an event set is not undone by an older read. At
  most four reads are in flight per Host, structure ahead of details. Rex's
  API document says relabeling a detached block raises no event, so a session
  with detached terminals also reads its structure again once a minute.
- A read's answer comes in order after everything else the connection
  carries, terminal redraw pages included (ADR 0051), so a read waits as long
  as the connection keeps receiving: it gives up after half a minute in which
  nothing arrives, or two minutes in all. The check on a return to the
  foreground waits the same way, with five seconds of silence and half a
  minute in all, before it drops the connection for a new one.
- The Console sees an inventory only once every session's structure is
  current: first with the structure, then again when the terminals' details
  are read, then on each change once it settles. (Updated 2026-11-18: the
  first of these lists terminals nothing has named a foreground for yet, and
  says so for each, `RexTerminalDetails.awaitsForeground`. Such a terminal
  is not known to host an Agent or to host none, so a detail a relaunch
  restored on one reads Loading Agents until its read answers. It read Agent
  Gone for that moment before.) A session whose view the
  server refuses, or answers in a way Heeler cannot read, before it was ever
  read is read again twice, two seconds apart, rather than shown empty or left
  out at once. After that the inventory shows without it, and it is read
  again once a minute with the sessions that have detached terminals.
- A control connection that drops without a close frame is followed by a new
  one whose hello carries its reconnect token, on the same SSH connection when
  that is still up and over a new one when it is not, unless the client opened
  a terminal's data link (ADR 0051). Rex's API document says
  events sent in between are lost even when the server takes the client back,
  so every new connection reads the whole inventory again. A connection the server closed, as it does
  when too many events queue up for a client, is followed by a plain hello and
  a fresh read. The exception is a close with 1001, which Rex sends a client
  that stopped answering its pings and then keeps as it keeps a dropped one:
  that connection is resumed as a dropped one is. The first new connection after a healthy one, which read the
  inventory and lasted, is tried at once; later ones back off as other Server
  Kinds do, so a server that closes every connection right after the reads is
  not dialed in a tight loop.
- `server.status` names the server instance. Another instance is another
  server: every detail open on the last one's terminals has left the inventory,
  as with another tmux server (ADR 0045), and none of the last one's titles,
  programs or directories is shown for the new one's terminals before they are
  read. (Updated 2026-11-26: an instance that restored the last one's
  sessions continues its server, as the update below says.)
- Leaving on purpose closes the connection with a close frame, so the server
  forgets the client at once: suspending with the app once its grace period
  ran out, and the Host removed or replaced or the Console ending. Open
  terminals close their data links first, each with a close frame, waiting no
  longer than three seconds, and only then does the SSH connection go. A
  short trip to the background keeps the connection as it is, and a
  connection that dropped is taken back by the next one.
- Only API revision 12 is accepted (ADR 0049). (Updated 2026-11-25: revisions
  12 to 19, as ADR 0049's update of that day says.)
- A Rex session is a Workspace, a window a Tab and a terminal block a Pane,
  named and ordered as Rex shows them. A window lists its terminals in reading
  order: its tiled layout before-then-after, then its floating layers. A
  session's detached terminals, which belong to none of its windows, share one
  Tab of their own named Detached, after its windows. Blocks that are not
  terminals are left out, and so is a session with no terminal. The labels Rex
  gives a new window and a new block read as unnamed. A Pane's id is an opaque
  string written from the session id and the block id. A Rex Host reports no
  Agents. (Amended by ADR 0054: a terminal running a known agent program is an
  Agent, kept current by `program_status_changed` and `program_status_removed`
  on this connection.)

## Why

- One connection with every session attached is what Rex offers for watching
  a whole server; one per session would multiply connections, keepalives and
  reconnects by the number of sessions.
- Response seqs order reads against events exactly, so the inventory never
  needs a timer or a full re-read to settle a race.
- Rex's API document says events are not replayed after a resume, so
  anything short of a full re-read after a new connection could keep a stale
  row forever.
- Subscribing to every event costs a little traffic at human pace and saves a
  poll of every terminal's title and process.
- Detached terminals are still the user's terminals; leaving them out would
  hide work, and putting them in a window they are not in would misplace it.

## Evidence

Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, from a lab
client on the local socket, a review probe and the live tests (2026-11-15,
recorded with their sources in `docs/agents/rex-compatibility.md`):

- `session.attach_all` answered with the session list and seq 0, and a client
  attached with `session.attach` kept getting that session's events after a
  resume.
- A connection with only `session.attach_all` could read `session.view`,
  `session.list_blocks` and a terminal's title, process and size.
- Each layout operation's events arrived in a fixed order, with window and
  label events before the `session_view_changed` of the same change, and
  `session_view_changed` carrying only a revision.
- A client that stopped answering pings was closed with 1001 and could still
  be resumed with its token.
- New windows were labeled `Window` and the last eight hex digits of their id,
  and new shell blocks `shell`.

That events sent while a client is away are lost, and that a detached block's
relabel raises no event, come from Rex's API document for revision 12 and
were not tested; Heeler re-reads the inventory on every new connection, and a
session with detached terminals once a minute, whichever holds.

## Considered options

- One control connection per session: rejected for the cost above.
- Re-reading the whole inventory on any event: rejected; a busy server would
  read without end.
- Attaching with session events only and polling titles and processes:
  rejected, since polling every terminal costs more than its events and lags.
- Showing detached terminals in their last window: rejected, since Rex no
  longer places them there.

## Consequences

- `RexHostSession` and `RexInventoryFollower` own the connection and the
  inventory; `RexInventoryBook` holds the ordering rules and is tested without
  a server.
- Opening a Rex terminal is the next step: it needs `session.attach` on this
  control connection before a data link, and `RexHostSession.withConnection`
  hands both out. Until then a Rex Pane's detail says it cannot open yet,
  with a way back and nothing to retry, and an Attach fails with that reason.
  (ADR 0051 took that step and replaced this: `RexHostSession.withTerminal`
  attaches the session on this connection, holds the block to one data
  stream and hands out the terminal's connection, and a Rex Pane's detail
  opens its terminal. Its input goes on this connection too (ADR 0052).)

## Update 2026-11-26: a restarted server

Rex 0.1.0-preview.25 restores its sessions when it starts again on the same
state directory, after `rex server stop` and after a crash alike: the same
session, window and block ids, under a new `instance_id`, with `server.status`
keeping its `host_id`. Reading every new instance as another server left each
open detail behind, removed the Host's pins and forgot its turns, seen marks,
picks and Chat's cache on every restart, and updating the Rex app restarts the
server.

A Rex Host now has a core, as a herdr-core Host does (ADR 0031): the server
across its instances.

- The first instance Heeler meets starts a core named by its `instance_id`.
- Another instance continues the last one's core only when its `server.status`
  names the same non-empty `host_id` as the last one did and `session.list`
  names at least one of the session ids the last instance listed. Only such an
  instance is asked for its list. An instance with no `host_id` or another
  one, or one listing none of those sessions, is another server, as before.
- The core, its last instance, that instance's `host_id` and the sessions it
  listed are kept in the Host's memory with the core, so the first connection
  after a relaunch continues it too.
- Details, pins, turns, seen marks, picks and Chat's cache keep to the core.
  Where ADRs 0051, 0054, 0055 and 0056 say something keeps to the server
  instance, it now keeps to the server: the instances that continue one core.
- What ran in the terminals does not carry over. A restored terminal starts on
  a fresh screen, so the new instance's terminals still start with none of the
  last instance's titles, programs or directories, Chat forgets the picks a
  send guard dropped, and a pick's foreground no longer matches a program
  started again. Chat's typing into a terminal stays, since an open Chat holds
  it: it reads the program started again as another process holding the
  terminal, so nothing is typed over a screen read before the restart. An open
  terminal reconnects and paints afresh, as after a dropped connection, and a
  request or input pinned to the last instance fails as the connection having
  gone, not as the server.

### Why

- `host_id` alone says only that two servers see the same files, which a
  server started on the same state directory after its sessions were removed
  does too. Rex names each session with a UUID, so a list holding one of the
  last instance's restored it rather than met it by chance. Asking for both
  is the narrowest rule that matches what preview.25 did.
- Session ids rather than block ids: a restore brings back whole sessions, and
  `session.list` is one read, made before any of the inventory's.

### Evidence

Against Rex 0.1.0-preview.25 (API revision 24) on macOS 27.0, 2026-11-26, on
a server of its own with its own socket, state directory and configuration
(recorded in `docs/agents/rex-compatibility.md`):

- After `rex server stop` and after `kill -9`, the server started on the same
  state directory listed the same session, window and block ids under a new
  `instance_id`, with the same `host_id`.
- A `RexHostSession` probe over the server's local socket, not committed,
  announced the restarted server with the first instance's core after each
  restart, and read its inventory.
- `RexHostSessionTests`, `RexConsoleTests` and `RexTerminalAttachTests` assert
  the rule against a fake world that keeps its ids across a restart, with and
  without a `host_id`.

### Consequences

- `RexServerStatus` carries the `host_id` and the core beside the instance;
  `isSameServer(as:)` compares cores, and checks that a connection is still
  the one a request was made on still compare instances.
- `RexServerLineage` is what one instance listed, kept by `RexHostSession`
  and in `HerdrCoreHostMemory`.
