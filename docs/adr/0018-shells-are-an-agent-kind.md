---
status: accepted
---

# Shells are an Agent kind

Every snapshot Pane that runs no Agent is projected into the Console as a
`ConsoleAgent` whose `agent.kind` is `Agent.shellKind` (`"shell"`). There is
one Console row, one Agent detail (`AgentDetailView` / `AgentTerminalView`),
one Composer and one Direct Input path for Agents and plain shells alike.
Shell rows take the ordinary Agent row's swipe-to-close, Pin, move, context
menu, rename and search; the Workspace drawer, Open Terminal and New Terminal
open a shell's Agent detail. This supersedes ADR 0015's separate Shell
Terminal surface, and ADR 0017's routing of ordinary panes to that surface
along with its no-takeover attach for existing shells: the Shell Terminal
view, its store and its separate per-Host shell connection pool are gone.
Shell attaches are
retained by the same Agent terminal cache under ADR 0017's shared five-per-Host
retention budget. ADR 0015's direct terminal attach transport remains in use.
The multi-window rule that a window showing a Shell Terminal kept its Host's
channel (so Live in Another Window offered no Take Over there) goes with the
surface: a shell's detail is an Agent detail and takes over like one.

## Why

The user's requirement is identical UX: "whether it's a default shell or OMP
or Claude agent, I expect the interface to act exactly the same because it's
still just herdr tabs." A parallel Shell Terminal type made that a copying
exercise — every Agent feature (row actions, Pins, moves, rename, switcher,
Composer, keyboard handoff) was missing on shells until it was re-implemented
there, and the two surfaces kept drifting. Projecting shells into the Agent
model makes parity the default and each divergence an explicit gate.

## The only divergences

Each follows from herdr refusing an Agent-only API on a Pane with no Agent;
everything else is shared.

- **Attach target.** `herdr agent attach` refuses a plain Pane
  (`agent_not_found`), so a shell row attaches by terminal id —
  `TerminalAttachTarget.terminal(terminalID)`, i.e. `herdr terminal attach` —
  where an Agent uses `.agentPane(paneID)`. Both ride the same attach pipeline
  with the same takeover behavior (ADR 0015's facts about the shared direct
  attach client still hold).
- **Composer delivery.** `agent.prompt` is Agent-only, so a shell's Composer
  Send is one `Transport.sendPaneInput` (`pane.send_input` with the draft and
  Enter). There is no `agent_not_ready` launch wait and no Blocked insert.
- **Rename.** `agent.rename` refuses a shell; a shell's name is its Tab
  label, renamed with `tab.rename`.
- **No Agent Status.** A shell carries the presentation-only status
  `.shellTerminal` (reads "Shell", muted palette, bottom sort bucket). herdr
  reports no status for it, so shells get no status event subscription and
  are excluded (`excludingShells`) from in-app banners, Live Activities and
  every status aggregate.

## Default Shell launches

The new-agent sheet's Default Shell creates the tab (or worktree / new
Workspace) without `agent.start`. Every such pane is created with
`HEELER_SHELL=1` in its environment so a Host's shell rc can skip agent
auto-launch hooks when a plain shell was asked for; the tabs Open Terminal and
New Terminal create carry the same marker. The existing-Workspace
launch may omit `cwd`; herdr then resolves it to that Workspace's focused
pane cwd. `worktree.create` takes no environment and its root pane's shell
has already started unmarked, so a worktree shell launch opens a marked tab at
the worktree path and closes the unmarked root tab.

## Submit-carrying input is never auto-retried

A link failure cannot say whether herdr already received the request.
Host-scoped RPCs otherwise get one redial-and-retry after a link failure;
Composer delivery — `pane.send_input` carrying Enter and `agent.prompt`
alike — opts out, because a replay could execute a shell command or submit a
prompt twice. The dead link is still distrusted, so the next call rides the
replacement transport, but the failure surfaces for a deliberate resend.

## Consequences

- New Agent features reach shells automatically; a feature that must not
  apply is gated on `isShell` / `Agent.shellKind` at the point of the
  Agent-only API call, not by a separate type.
- An Agent appearing on a Pane replaces its shell row with the Agent's, and
  the reverse when the Agent exits; the row identity (`hostID` + `paneID`) and
  its Pin carry across.
- The glossary drops **Shell Terminal** as a surface: shells are Console rows
  that open Agent detail, and **Attach** names the terminal stream behind any
  row's detail, Agent or shell, differing only in its target.
