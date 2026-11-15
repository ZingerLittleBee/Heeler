---
status: proposed
---

# Rex terminals open for viewing from the server's redraw

A Rex Host lists its Terminals (ADR 0048). Opening one means showing its
screen and scrollback, following its output, surviving the drops a phone
sees, and ending cleanly when the block goes. Rex's terminal data stream
starts with a snapshot in Rex's own format, not with bytes a terminal can
show, and Rex answers a program's terminal queries itself. Rex also gives
each block one owner client whose size it uses. This slice opens a Rex
terminal for viewing only; input is the next slice.

## Decision

- **Opening.** The view's runner waits for the Host's live control
  connection, calls `session.attach` for the Pane's session on it, then opens
  the block's data link (`RexTerminalStream`) on a channel of its own under an
  attach slot. `RexHostSession` remembers which sessions its control client
  attached. A client the server took back keeps them; after a new client, it
  sends `session.attach` again for every session with an open terminal.
- **The first paint skips the snapshot.** Heeler never decodes the snapshot.
  It reads the server's `vt` redraw of screen and scrollback, every `extra_*`
  flag on, paged with `blob_read`, and writes a full reset (RIS) followed by
  the redraw as one write. The view shows nothing before that paint, and
  reads as live only once it is in. Every later paint, after a refused
  resume or a stream started over, is the same single write, so the view
  replaces what it showed without a blank frame between.
- **The exactness rule.** Output keeps arriving while the redraw is read.
  A paint counts as exact only when no output arrived from the request until
  the whole answer plus a 30 to 60 ms settle. Up to three attempts are made;
  then the last one is shown best effort and repainted after 250 ms with no
  output. A program that never goes quiet for 250 ms, such as a spinner or a
  streaming agent, keeps a best-effort first paint until it pauses: the lines
  that raced the redraw may show twice or not at all until then.
- **What the redraw leaves out.** The redraw carries no title, cursor shape,
  default colors set with OSC 10 or 11, or saved cursor, and while a program
  uses the alternate screen, none of the primary screen or scrollback behind
  it; that history is painted again once the program leaves the alternate
  screen. With autowrap off, soft wraps are not joined. The title follows the
  inventory's `title_changed` events (ADR 0048), and the colors stay Heeler's.
- **Query answers are dropped.** Rex answers a program's queries (device
  attributes, cursor and status reports, mode reports, colors) itself, so the
  answers Heeler's own Ghostty writes back must never reach the program.
  `RexTerminalAnswerFilter` drops them from what the view sends: control
  sequences ending a report, focus reports, and every OSC, DCS, APC, PM and
  SOS string terminated in the same write, while keys, text, mouse reports
  and pastes pass. Ghostty writes an answer in one piece, so a string opener
  with no terminator is an Alt key (`ESC ]`, `ESC P`) and passes. In this build
  input is shut altogether (below), so nothing leaves during a paint or after.
- **Size is a request, never ownership.** The view's grid is asked for with
  the terminal's `resize` method on arrival and once a change has held for
  150 ms, never twice the same, and again when the block's owner lets go,
  since a size asked for under another owner is not applied then. Heeler
  never calls `own_block`. The view shows the block at the server's size; the
  server's grid, the view's grid, the owner and this client reach the view as
  `TerminalSizeReport`, which the next slice uses for its notice and an
  explicit take.
- **Resume or a fresh paint.**
  - A data link that drops while the control link is fine is resumed with the
    exact byte count, within the server's retention; a refused resume opens a
    new stream and paints it whole.
  - A control link that drops and takes its client back on the same SSH
    connection leaves every data stream alone.
  - A new control client, or a new SSH connection, ends every open terminal's
    attach as a lost connection: the view keeps its screen, reattaches, and
    paints afresh.
  - Another server instance finishes the terminal, as another tmux server
    does; a detail keeps to the instance it opened on.
  - A block that closes, its session going, or its program exiting finishes
    the terminal. The data link closes on its own after the block's last
    output; if it has not a moment after the block's close event, the attach
    ends anyway. Nothing reattaches.
  - Suspending with the app, past the grace period, closes the SSH
    connection and so every data link; the view reattaches and paints afresh
    when the Host is back. The Host stopping ends the terminal.
- **One data stream per block per client.** An attach holds its block in
  `RexHostSession` until its stream has closed, so two views, a retained
  attachment beside a new open, or a quick close and reopen never ask for a
  second while the first is open. Data links take the connection's five
  attach slots like any Attach, and the terminal pool's limit applies to Rex
  terminals as to the others.
- **Events.** The inventory follower passes each event on to the open
  terminals before the inventory applies it: a block's close, its owner, and
  its own events. The inventory is unchanged by them.
- **Input stays shut** behind `RexTerminalInput.isOpen`. A Rex attach gives
  the view no writer, so keys, pastes, scrolling, focus, the Keys panel and
  Stop send nothing and report nothing as sent; the view scrolls its own
  history.

## Why

- The snapshot is Rex's private format and changes with Rex; the redraw is
  plain VT that Heeler's Ghostty already reads, and the lab and the live tests
  found it reproduces text, wraps, styles and modes.
- One write per paint is what keeps a repaint from flashing.
- Dropping answers on the way out keeps the fix to Heeler's own side of the
  wire. The alternative, Ghostty's replay mode for bytes written during a
  paint, is not reachable through the pinned `GhosttyTerminal` product's
  public API, would need ordering against its write queue, and would cover
  only answers to bytes fed during the paint: focus, in-band size and color
  scheme reports are written later and need dropping anyway.
- Taking ownership would resize the desktop's terminal under its user. A
  request is applied only when no one owns the block, which is the polite
  default; an explicit take belongs to the user.
- A client the server does not know has no streams, so painting afresh is the
  only way back. A resumed one has them all, so tearing them down would cost a
  full redraw for nothing.

## Evidence

Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, from lab
captures, live tests and fakes, recorded with their sources in
`docs/agents/rex-compatibility.md`:

- `data.connect` answered 409 until the control connection called
  `session.attach` for the session; a client that resumed kept getting that
  session's events without attaching again.
- Resuming a dropped data connection with the exact byte count continued it
  with nothing lost or repeated; a wrong count got a refusal, after which
  only a new stream worked.
- A full reset followed by the redraw matched the server's text of the
  terminal in Heeler's own Ghostty, scrollback, wide and wrapped lines and
  the alternate screen included; 59 of 59 lab handoffs ended correct under
  the exactness rule.
- A resize request applied at once only to a block with no owner; Rex.app
  owns the blocks of its own windows.
- A program writing about every 12 ms got a best-effort first paint and one
  exact repaint once it stopped.

## Considered options

- Decoding the snapshot: rejected; undocumented and version-bound.
- Ghostty's replay mode for query answers: rejected for the reasons above.
- Taking ownership on open: rejected; it resizes the desktop's terminal.
- Keeping a stream across a new control client: rejected; the server cancels
  a client's streams once that client is gone.

## Consequences

- `RexTerminalAttach` turns one stream into one view's bytes, size requests
  and endings; `RexHostSession.withTerminal` holds the block, waits for the
  connection and hands out a `RexTerminalConnection` with the block's signals.
- The next slice opens `RexTerminalInput`, sends what
  `RexTerminalAnswerFilter` keeps, and shows `TerminalSizeReport`'s mismatch.
- A first paint costs the snapshot and the redraw, each about the size of the
  scrollback; on a slow link a long history takes seconds to appear.
