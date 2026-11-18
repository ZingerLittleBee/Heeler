---
status: proposed
---

# Rex terminals running a known agent are Agents

A Rex Host listed Terminals only (ADR 0049): a terminal running Codex or
Claude Code read as one more shell under Terminals, with no status. Rex keeps
a Program Status per terminal itself. A program reports it with OSC 7501, the
words Heeler already reads on herdr-core and tmux, and Rex answers the
program's query for that support, so an agent that reports elsewhere reports
inside Rex too. Heeler's control connection (ADR 0050) already receives each
report as an event of its terminal. That is enough to list such a terminal as
an Agent with its Agent Status without installing, configuring or running
anything on the machine.

Amended by [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md):
a Rex Agent opens the Agent detail, with Chat for Claude Code and Codex, its
Terminal surface and the Composer, not the Terminals list's terminal detail.
`agentsOpenAsTerminals` is gone. Since ADR 0056's update of 2026-11-18, Chat
is offered for Pi and Oh My Pi too.

## Decision

- **Which terminal is an Agent.** A Rex terminal is an Agent while a known
  agent program holds its foreground, read by the rule and program table every
  other kind uses (`HerdrCoreAgentRule.program(arguments:name:)`, as
  `TmuxAgentRule` reads a tmux Pane). The foreground is the one Rex's `process`
  method and `process_changed` event name: its first argument, or its name
  where it has none, followed by its script when an interpreter runs one, and
  its name beside them. `RexAgentRule` reads it. A shell, any other program,
  a terminal with no foreground and a closed block are terminals only, whatever
  status they reported. Nothing else makes an Agent: a report whose `app`
  names a known program does not, on its own, turn a terminal into one.
- **Its status.** Only the terminal's root record counts, the one a report
  without an `id` writes; child records are a program's subtasks, as Heeler's
  tmux reader ignores them. The record counts for the Agent only while its
  owner, the foreground process when the report arrived, is the current
  foreground by both process id and name, since Rex keeps idle, done and error
  records after their program exits and the system reuses process ids. A
  record whose `app` (or `effective_app`) names another known program is that
  program's. Either way the Agent reads Unknown, and so does an Agent with no
  record. Otherwise its state maps as on herdr-core: `idle` and `done` read
  Idle, `working` Working, `blocked` Blocked, `error` Error, and any other word
  Unknown, but for Done, below. (Updated 2026-11-18: one record is not read
  as reported. Claude Code keeps its record at `working` after a turn ended
  while commands it put in the background still run, and counts them in
  `msg`, as in "1 shell still running", where a running turn says what it is
  doing. Heeler reads that record as `done`: the turn is over, Claude Code
  takes the next prompt, and Esc has nothing to interrupt, so the Agent reads
  Done or Idle and the Composer offers Send, as on a Herdr TUI Host. Before,
  it read Working for as long as the command ran, with a Stop that did
  nothing. Heeler leaves the background command alone. Any other wording
  reads as reported; the observation is in
  `docs/agents/rex-compatibility.md`.)
- **Done per device.** A Rex Agent reads Done as an Agent of the other kinds
  does (ADRs 0033 and 0046): it finished a turn this device has not looked at
  since, and its record says idle or done; opening its terminal looks at it.
  Rex keeps no turn count and moves a record's `updated_at` on every report,
  the same report made again included, so a finished turn is named by the
  report that ended it: its owner and `updated_at`. Each control connection
  counts, per terminal, the reports it hears that take the root record from
  working or blocked to done for the same program, and starts a new count when
  a read finds another record than it held. Within one count a turn ended when
  the count moved, so the same done reported again ends nothing, and a done
  after the working or blocked known here ended one whatever the count, since
  Rex removes that record while its program is out of the foreground; across
  counts (another connection, a relaunch) a record whose time has not moved
  is the one known, and any other done ended a turn. A program not known to
  report done ends a turn going from working to idle, as on herdr-core. At
  first sight a done reads Done and an idle Idle, as nothing says it worked.
  A report from another owner, or a foreground read as no agent, starts
  over, so another program's turn is never the one this device looked at; a
  terminal whose foreground a new connection has yet to read keeps what this
  device knew. Turns and seen marks stay on this device, in the Host's memory
  with the server instance, and go with the terminals the server stops
  listing, another instance and the Host.
- **Kept current by events.** Each terminal's details read, once per control
  connection, now asks `program_status` after `title` and `process`, gated by
  the response's seq like the other two. Then `program_status_changed` replaces
  the root record and `program_status_removed` naming the root drops it,
  whatever the reason, and `process_changed` keeps the foreground's process id,
  name, first argument and script. Both status events arrive on the existing
  `session.attach_all` with every event: nothing is polled, no data link is
  opened, nothing is attached, owned or resized, and nothing is written to a
  terminal. A record that fails the owner check is kept and checked again on
  every foreground or status change, since a program's first report can arrive
  before the foreground change that names it.
- **Fresh on each connection.** A new control connection carries a terminal's
  title, program and directory from the last one on the same server instance
  until it reads them again, as before, but not its status: an Agent reads
  Unknown until this connection's own read of its terminal answers, and what
  this device saw of its turns stays. A status
  publishes as soon as it is read or reported, without waiting for the other
  terminals' reads, which hold back their titles, programs and directories
  only. Another server instance
  carries nothing. The Console's rows still come back only with a connection's
  first settled inventory (ADR 0050).
- **Listed as Agents.** A Rex Agent is in the Agents list in every mode, with
  its kind's mark, its Host, the status filter and search, and leaves the
  Terminals list, as an Agent on any other kind does. Its title is the
  terminal's title, else its kind's name, and its name the block's label; its
  directory is the foreground's. A session is its Workspace and a window its
  Tab. Pins work as on tmux: they keep to the panes the inventory lists and go
  with another server instance. A session whose terminals are all Agents has
  no card under Terminals: another kind's such card holds New Terminal, which
  a Rex Host does not offer.
- **Opening one opens its terminal.** A Rex Agent's detail is the terminal
  detail the Terminals list opens (ADRs 0051 to 0053): the size taken for
  this screen as it opens, the server's redraw first, typing, paste,
  Snippets, the size notice and Fit to Screen. It has no
  Chat, Composer, Stop, Changes, rename, close, worktree, New Agent or Usage,
  and its row offers Pin alone: no window of its own, which the Terminals list
  does not offer either, and no Changes read. When its program leaves the
  foreground the detail reads Agent Gone, as a tmux Agent's does, and the
  terminal is back under Terminals. (Superseded by ADR 0056: a Rex Agent
  opens the Agent detail, whose Terminal surface keeps ADR 0053's size rule
  and notice, with Chat for Claude Code and Codex, Composer Send and Stop.
  Its menus offer only what the Host serves, so Changes, rename, close,
  worktrees and New Agent stay out, and its row still offers Pin alone.
  Attachments stayed out too until ADR 0056's update of 2026-11-17, which
  offers them wherever Chat is.)
- **Still left out.** Notifications, Live Activities, widgets, Usage, Accounts,
  background refresh, the plugin, the Host Helper and Pairing Codes still pick
  their Hosts by kind and leave Rex out, so no code that walks every Agent acts
  on a Rex one. (Updated 2026-11-18: Pairing no longer does. Since
  [ADR 0057](0057-heeler-pair-pairs-a-machine-without-herdr.md)
  it ends on Add Host's Servers step, which lists a Rex Server.)

## Why

- The rule and the status words are the ones the other kinds use, so a kind
  added from one place applies to Rex too, and there is no second vocabulary.
- The owner check is what tells a current record from a stale one: Rex keeps
  an exited program's idle, done and error records, and a terminal may host
  another program since.
- Events cost nothing between reports, and every report raised one in the lab.
- Only a connection that hears every report can tell the same done made
  again from a new turn, so the count is kept where each event arrives: one
  published inventory may stand for several reports. Once reports went
  unheard the two look alike, and a done whose time moved counts as a turn
  rather than miss one that ended while the app was away: ADR 0046 counts a
  turn that starts and ends between two looks too.
- Opening a Rex Agent as its terminal reuses a detail that already does
  everything Rex supports, and offers nothing Rex cannot serve. (ADR 0056
  gated the Agent detail's Host asks by capability instead, once Chat was to
  ship.)

## Evidence

Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, from a lab
client on the local socket with inert stand-in agents in lab sessions
(2026-11-16, recorded in `docs/agents/rex-compatibility.md`):

- Programs' OSC 7501 reports were kept per terminal in the words above, and
  each one raised a `program_status_changed` event carrying the whole record
  on a connection attached with `session.attach_all` and every event; a
  connection with session events only received none.
- Leaving the foreground removed working and blocked records and kept idle,
  done and error ones, whose owner still named the exited process.
- The same report made again raised another event and moved the record's
  `updated_at`, a done three times in a row included; a read moved nothing,
  and matched the event before it.
- The rule recognised every agent launch typed into a shell, a native Claude
  Code by its first argument (its executable is named for its version) and
  interpreted ones by their script, and read shells and background jobs as
  terminals.
- A launch report reached Heeler about 100 ms before the `process_changed`
  that named its program. `process_changed` followed output only: a foreground
  change that printed nothing raised none.
- `RexProgramStatusLiveTests` carries a lab stand-in's reports through a
  `RexHostSession` into the inventory and the Agent the Console makes of it,
  and its exit back to a terminal, with Heeler's session only reading. Its
  working-then-done moved the connection's count by one and read Done; the
  same done again moved the time and not the count.

## Considered options

- Taking a record's `app` as the Agent where the foreground does not say:
  rejected. It would make an Agent of a shell whose background job reported,
  and of a terminal whose program exited, and decision 1 asks for the
  foreground rule.
- Rex's own reading of an unknown state as idle: rejected for the other kinds'
  Unknown. This server refuses an unknown word, so the two do not differ yet.
- Polling `program_status`: rejected; every report is an event.
- Opening a Rex Agent in the Agent detail with its Chat and Composer hidden:
  rejected. That detail asks its Host for the Agent's process, presence and
  Changes, which a Rex Host cannot serve, and lacks the size notice.
  (Reversed by ADR 0056: the detail now asks only what a capability allows,
  its terminal carries the size notice, and Chat and the Composer show.)
- A Rex Agent that never reads Done, as first decided: superseded on
  2026-11-16 by the maintainer's decision that it reads Done as the other
  kinds' Agents do.
- Counting reports while connected alone: it would miss turns that end while
  the app is away, which the record's time covers.
- The record's time alone: the same done reported again would read Done again
  while the app watches.

## Consequences

- A program Rex started as a block's own command under `login` (Rex's default
  for a block with no shell), one run with `exec` from a shell, and one under a
  `sh -c` line that does not exec it read as `login` or the shell, so they are
  terminals only, though their reports are kept. Showing them would need a
  rule that trusts a record's `app`, a new decision.
- Linux Rex servers were not tested. An interpreter whose first argument is a
  versioned name the rule does not list could lose its script there.
- Heeler's foreground can be stale until the terminal next prints, as
  `process_changed` follows output. An agent prints as it works, so this
  delays an Agent's arrival or departure rather than its status.
- A program that reports the same done again while no connection hears it
  reads Done again on this device. An idle Agent seen first, as on a Host
  just added, reads Idle even if its last turn was never looked at.
- `RexTerminalDetails` holds the foreground's process id, first argument and
  script and the root Program Status with its time and the connection's count
  (`RexStatusFollow`); `RexAgentRule` reads them; `RexTurnState` keeps Done
  per device; the Rex projection lists Agents and prunes Pins;
  `HostCapabilities.agentsOpenAsTerminals` routes a Rex Agent's detail and its
  row's offers, and that terminal screen reports the Agent as shown.
  (Replaced by ADR 0056: Rex Agents route as every kind's do, and
  `rowsReadChanges` and `terminalsShowInOneWindow` decide the row's offers;
  the Agent detail reports the Agent as shown from either surface.)
