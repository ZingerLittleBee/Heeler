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
  Unknown. Done stays per device on the other kinds, and Rex keeps no turn
  count, so a Rex Agent never reads Done.
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
  Unknown until this connection's own read answers. Another server instance
  carries nothing. The Console's rows still come back only with a connection's
  first settled inventory (ADR 0050).
- **Listed as Agents.** A Rex Agent is in the Agents list in every mode, with
  its kind's mark, its Host, the status filter and search, and leaves the
  Terminals list, as an Agent on any other kind does. Its title is the
  terminal's title, else its kind's name, and its name the block's label; its
  directory is the foreground's. A session is its Workspace and a window its
  Tab. Pins work as on tmux: they keep to the panes the inventory lists and go
  with another server instance.
- **Opening one opens its terminal.** A Rex Agent's detail is the terminal
  detail the Terminals list opens (ADRs 0051 to 0053): the server's redraw
  first, typing, paste, Snippets, the size notice and Fit to Screen. It has no
  Chat, Composer, Stop, Changes, rename, close, worktree, New Agent or Usage,
  and its row offers Pin alone: no window of its own, which the Terminals list
  does not offer either, and no Changes read. When its program leaves the
  foreground the detail reads Agent Gone, as a tmux Agent's does, and the
  terminal is back under Terminals.
- **Still left out.** Notifications, Live Activities, widgets, Usage, Accounts,
  background refresh, the plugin, the Host Helper and Pairing Codes still pick
  their Hosts by kind and leave Rex out, so no code that walks every Agent acts
  on a Rex one.

## Why

- The rule and the status words are the ones the other kinds use, so a kind
  added from one place applies to Rex too, and there is no second vocabulary.
- The owner check is what tells a current record from a stale one: Rex keeps
  an exited program's idle, done and error records, and a terminal may host
  another program since.
- Events cost nothing between reports, and every report raised one in the lab.
- Opening a Rex Agent as its terminal reuses a detail that already does
  everything Rex supports, and offers nothing Rex cannot serve.

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
- The rule recognised every agent launch typed into a shell, a native Claude
  Code by its first argument (its executable is named for its version) and
  interpreted ones by their script, and read shells and background jobs as
  terminals.
- A launch report reached Heeler about 100 ms before the `process_changed`
  that named its program. `process_changed` followed output only: a foreground
  change that printed nothing raised none.

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
- A per-device Done from counting reports while connected: left out. It would
  miss turns that end while the app is away.

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
- `RexTerminalDetails` holds the foreground's process id, first argument and
  script and the root Program Status; `RexAgentRule` reads them; the Rex
  projection lists Agents and prunes Pins; `HostCapabilities.agentsOpenAsTerminals`
  routes a Rex Agent's detail and its row's offers.
