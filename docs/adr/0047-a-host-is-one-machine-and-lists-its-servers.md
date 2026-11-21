---
status: proposed
---

# A Host is one machine and lists its Servers

Amended by [ADR 0057](0057-heeler-pair-pairs-a-machine-without-herdr.md):
a Host added by Pairing Code is no longer one Herdr TUI Server. Pairing ends
on Add Host's last step, with the Servers the look found. Only a code with a
Herdr Endpoint still adds its one Server. A code scanned for a Host in the
catalog is also a way the user replaces its changed key.

Amended by [ADR 0058](0058-a-hosts-servers-share-one-route.md): each Server
still keeps its own connection, and the connections of one Host now hold one
Route. A Server's page no longer shows the connection or a Show in Heeler
switch; Host detail shows the connection under its Routes.

Amended 2026-11-21: the Agents and Terminals lists say one condition for a
Host, not one for each Server. Their corner status tile and the sheet it opens
count a Host once, under its name alone, and read it as the By Host heading
does: connected while any Server is connected, otherwise as the Server that
most needs the user, a failure of the connection ahead of one Server's own.
The connection sheet speaks for the Host, and its Retry Now and Stop
Connecting reach every Server the Host has on. The rows under a By Host
heading, one for each Server's problem, are gone. A Server that fails on its
own beside a connected Server of its Host therefore shows on the Hosts tab's
row and in Host detail, not in the lists.

ADR 0031 bound a Host to one Server Kind, so a machine that ran Herdr TUI and
tmux was added twice, with the address, account, key and trust typed and
confirmed each time, and showed as two rows nobody could tell were one
computer. Adding a Host saved it unconfirmed, and the kind was chosen on a
second screen after the fact. With three kinds, several sessions and several
tmux sockets on one machine, that is the common case, not the odd one.

## Decision

- A Host is a machine: what the user adds, names, authenticates against and
  trusts. It lists Servers: a Herdr TUI session, a herdr-core session, or a
  tmux socket. Each Server is switched on or off for this device, and only a
  Server that is on connects, shows Agents and Terminals, and notifies.
- The catalog does not change. Each Server that is on stays one stored record
  of the type the code still calls `Host`, in the catalog its kind already
  used, with its own id. Records with the same account, the same way to
  authenticate and the same Routes in the same order are one Host
  (`HostMachine`), grouped when the catalog is read. Nothing is migrated, and
  a build before this change reads the same records as one Host for each
  Server, as it always did.
- A Host with no Server on is held by one record with no kind (the stored
  state ADR 0031 called unconfirmed). Turning the first Server on gives that
  record its kind; each further Server adds a record with the Host's name,
  account, Routes and a copy of its saved password. Turning the last Server
  off first adds such a holding record and then removes the Server's, so the
  Host stays with its Routes, account and trust. Remove Host removes every
  record.
- A record still never changes kind (ADR 0031). Turning a Server off removes
  its record and what goes with it on this device, as removing a Host did;
  turning it on again is a new record.
- Add Host is three steps in one sheet: Connect, Trust, Servers. Nothing is
  saved before the last step. One look (ADR 0031's detection exec) lists what
  the machine runs; Servers that run start checked, and the rest stay in Host
  detail, switched off. A Host may be added with none on, and after a failed
  connection it may be saved as typed. A connection that is already a Host
  turns Servers on there and adds no second Host.
- Host detail lists the Host's Servers with a switch each, and looks again
  when it opens and on Scan Again. Add by Name turns on a session or socket no
  look lists. A Server that is on opens its own page, which holds what Host
  detail held before: connection state, checks, plugin, Host Helper, sessions.
- While the Hosts list shows and a Server of a Host is connected, the list
  looks at that Host again without being asked, at most once an hour after a
  look that worked and once in ten minutes after one that did not. It never
  asks about a host key. A Server found that way is never turned on: the
  Hosts list marks it and Host detail tags it New until the user has seen it.
  What was found and what was shown is kept per Host on this device, outside
  the catalog.
- A look lists Herdr TUI's default session whether it runs or not, since it
  starts with herdr, and a named session only while it runs. herdr keeps every
  session it ever had, and a stopped one is turned on by name.
- Host key trust stays keyed by record. A record gets the Host's trusted keys
  before it is added, a look that reaches the Host gives them to any record
  that has none, and replacing a changed key replaces it for every record of
  the Host. A key is never replaced without the user.
- A record that would read like another of its Host carries the Server's
  label beside the Host's name (`studio · tmux`) wherever one record is named
  on its own: a picker of Servers, its Server page, a notification, a problem
  with that Server. The label is derived, not stored. The Console's Host
  filter names the Host, not its records: it lists each Host once, and
  choosing one shows every Server it has on.
- The Agents and Terminals lists name the Host alone, as the Hosts tab does,
  on every row, Workspace card and By Host heading. A record the user named
  apart before it was one Host with the others goes by the Host's name there,
  derived like the label. By Host has one section per Host, in the Hosts
  tab's order, holding its Servers' Agents in the Console's status-priority
  order (catalog Server order breaking ties) and its Servers' Terminal
  Workspaces one Server after another in catalog order, with the counts summed.
  The heading reads as the Hosts tab's row does — connected while any Server
  is connected, otherwise as the Server that most needs the user — and opens a
  connection sheet only for a Host with one Server on. Each Server's problem is
  a row under the heading, which names the Server when the Host has more than
  one. A Workspace stays one Server's:
  two of one name on two Servers are two cards, both under the Host's name.
  Folding a Host is stored by record id, as the filter is: a Host is folded
  while any of its records is, and folding or unfolding it sets or clears them
  all, so a Host folded while each Server had its own section stays folded.
- A Host with nothing to list, nothing to say and nothing to offer has no
  section in a list's By Host. It has something to say while a Server is not
  connected, still loading or out of sync, and something to offer while a
  Server's kind can start what the list shows, so only a connected Rex Host
  can be left out ([ADR 0054](0054-rex-terminals-running-a-known-agent-are-agents.md)).
- Usage counts a Host once. A Host's Servers read the same Transcripts under
  the same account, so the Usage tab, its widgets and Accounts in Settings
  list the Host, not its records, under the id of its first record that can
  read Usage. Each of those Servers is still read, and the Host's figures are
  those of the first that reports, so a Server without the plugin or the Host
  Helper does not hide what another can read.

This supersedes ADR 0031's "an SSH target that runs both is added once per
kind, as two Hosts" and its confirmation in Host detail, and ADR 0044's
"confirmed once in Host detail" for tmux. Everything else in both stands.
A Rex server ([ADR 0049](0049-rex-hosts-reach-a-running-rex-server-by-its-socket.md),
whose update of 2026-11-16 says how) is a Server of its Host in the same way.

## Why

- The record per Server is what every other part of the app is built on: the
  Console keys connections, Agents, Pins, notification keys, Live Activities
  and the Host Helper by record id. Keeping it means none of them moves.
- A catalog of machines with Servers nested in them would need a migration no
  older build could read back, for a grouping the records already imply.
- Servers found later are not turned on because a connection is not free: it
  brings notifications, a Live Activity and a Host Helper offer for work the
  user may not want on this phone.
- Listing every stopped herdr session filled a real Host's row with dozens of
  sessions long gone.

## Considered options

- **A stored catalog of machines.** Rejected above: a migration and a second
  source of truth for what the records say.
- **One SSH connection shared by a Host's Servers.** Less to dial, and a
  rework of every transport for it. Each Server keeps its own connection.
- **Turning found Servers on automatically.** Rejected above.

## Consequences

- Hosts added twice before this change show as one Host with two Servers the
  first time the list is read. A Host that was never confirmed shows with no
  Server on.
- Two records are one Host only while their account, authentication and
  Routes match. Hosts added apart with different Routes to one machine stay
  two Hosts until the user makes them match.
- Edit changes every record of the Host at once.
- A second Server appearing on a Host, or going, gives the other record its
  label or takes it away, and that record reconnects once. A Host whose
  records were named apart goes by its first named record's name; turning that
  Server off moves the Host to the next one's, and each record whose list name
  that changes reconnects once in the same way.
- Searching the Agents and Terminals lists finds a row by the Host's name,
  no longer by a Server's label; the optional `backend` field in Agent List
  Fields shows `core`, `tui`, `rex`, or `tmux` separately from `host`. By
  Workspace lists cards in the Hosts tab's order of Hosts, so two Hosts the
  catalog interleaved read apart.
- With every Host connected and each with nothing to list and nothing it
  could start, which only a Rex Host can be, By Host shows the same empty
  state the flat list does, not a list of bare headings.
- Opening Host detail and each look from the list open one more SSH
  connection for the detection exec, beside one connection for each Server
  that is on.
- A Host added by Pairing Code is a Herdr TUI Server on the Host its
  connection matches, or on a Host of its own.
- A Usage widget set to a Host names it by that first record. Turning that
  Server off, or a widget set before this change to another record of the
  Host, leaves the widget without its Host until it is set again.
