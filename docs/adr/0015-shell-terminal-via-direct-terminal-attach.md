---
status: accepted
---

# Shell Terminal rides herdr's direct terminal attach

Agent detail gains **Open Terminal** (#231): one tap creates one fresh herdr
tab in the Agent's launch directory — `tab.create` with the Agent's workspace
id, a concrete `cwd`, and `focus: false` — and opens the returned root pane's
ordinary shell as a **Shell Terminal**: a full interactive libghostty terminal
attached by executing `herdr terminal attach <terminal_id> --takeover` over
the existing SSH PTY pipeline. Directory selection is the Agent's non-empty
`cwd`, then the worktree checkout path; the request never omits `cwd` to
silently follow a different focused pane. The Shell Terminal replaces Agent
detail while open; Back detaches and leaves the remote tab alive for desktop
handoff.

## herdr 0.8.2 facts this rests on

Verified against the installed 0.8.2 CLI and the `v0.8.2` source tag. The
composed behavior over Heeler's SSH PTY pipeline (direct and Jump) still needs
Heeler end-to-end validation.

- `herdr agent attach` resolves an Agent over the API and then enters the
  same direct terminal attach client as `herdr terminal attach`:
  `src/cli/agent.rs` extracts `result.agent.terminal_id` and calls
  `run_terminal_attach`. The Shell Terminal therefore reuses exactly the
  machinery Agent Attach already exercises, differing only in how the target
  terminal id is obtained (`tab.create`'s root pane instead of Agent
  resolution).
- `terminal attach` targets a **terminal id**, not a pane id. The client
  speaks the client socket derived from `HERDR_SOCKET_PATH` by inserting
  `-client` before `.sock` (`herdr.sock` → `herdr-client.sock`,
  `src/server/socket_paths.rs`), so the socket export Heeler already performs
  for Agent attach selects the same session's client socket. It supports raw
  input, resize, and `--takeover`.
- One writable attach owner per terminal: a second attach without
  `--takeover` is refused ("already has an attached client; retry with
  --takeover"), and takeover displaces the previous owner with an explicit
  shutdown message (`src/server/headless.rs`). Attaching a missing terminal
  fails outright ("terminal … not found") rather than hanging, which is what
  lets an exited terminal reach an honest ended state.
- Direct terminal attach is Unix-only in the inspected source
  (`run_terminal_attach` is `#[cfg(unix)]`; Windows returns `Unsupported`).
  Heeler Hosts are Unix, so no broader claim is made.

## Considered Options

- **Direct terminal attach over the SSH PTY pipeline** — chosen, as above.
- **JSON API polling console (`pane.read` + `pane.send_input`)** — rejected.
  The read/refresh limitations verified live on 0.8.0 stand: no subscribable
  output-change push, a 1000-line server cap on every read, and
  `pane.output_matched` edge-triggered and silent under sustained output.
  This is the same evidence that shaped ADR 0012's snapshot Monitor, which
  ADR 0013 superseded for the richer Agent case; rebuilding a worse terminal
  for the simpler shell case has no upside.
- **Bare SSH shell (exec the user's shell over a PTY, without herdr)** —
  rejected. The session would live in the SSH connection rather than in
  herdr: no tab on the desktop to hand off to, nothing survives Heeler
  disconnecting, and the working-directory and workspace semantics would
  diverge from every other surface.
- **Attach the shell pane via `herdr agent attach`** — impossible. Attach
  resolution is Agent-only: a plain shell pane fails with `agent_not_found`
  (verified live on 0.7.5; resolution is unchanged in the 0.8.2 source).

## Direct input: a scoped exception to ADR 0013

ADR 0013 keeps Agent Attach display-only because the Agent TUI renders its
own input box — both compose-bar predecessors collided with it — and because
drafting locally avoids remote-echo latency for prompt-sized text. A plain
shell has neither property: there is no TUI input region to collide with, and
shell interaction is short commands against a prompt, where a
draft-then-deliver step adds friction instead of removing it. The Shell
Terminal therefore accepts direct keyboard input to the PTY. The exception is
scoped to ordinary terminals; Agent Attach remains display-only with Composer
as its sole authored-input path.

## Single Host terminal lifetime

The Host has one live terminal channel (ADR 0011 reserves one Attach PTY in
the session budget). The Shell Terminal replaces Agent detail rather than
stacking on it, so the handoff is explicit: opening it tears the Agent's
Attach down first, and leaving tears the shell down and lets Agent Attach
rejoin. Both directions ride the existing per-Host terminal serialization
instead of a second ownership mechanism.

## Consequences

- Every Open Terminal creates a new tab; once a tab exists, attach failures
  retry the same terminal id and never create another tab implicitly.
  Takeover is safe here because the tab was freshly created for this surface;
  pointing takeover at an arbitrary existing terminal would displace a
  desktop attach owner, which is why the flow never targets one.
- Back detaches only. Closing the remote tab is out of scope, shell tabs are
  not projected into the Console, and the Shell Terminal is not a
  `ConsoleAgent` and stays outside Agent notification routing.
- The glossary gains **Shell Terminal**, **Pane** broadens to host either an
  Agent or an ordinary shell, and **Attach** stays Agent-specific and
  display-only; unqualified "Attach" must not be used for this surface.
