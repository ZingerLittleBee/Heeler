---
status: proposed
---

# Rex terminals open for viewing from the server's redraw

A Rex Host lists its Terminals (ADR 0050). Opening one means showing its
screen and scrollback, following its output, surviving the drops a phone
sees, and ending cleanly when the block goes. Rex's terminal data stream
starts with a snapshot in Rex's own format, not with bytes a terminal can
show, and Rex answers a program's terminal queries itself. Rex also gives
each block one owner client whose size it uses. This slice opens a Rex
terminal for viewing; ADR 0052 adds its input.

## Decision

- **Opening.** The view's runner waits for the Host's live control
  connection, calls `session.attach` for the Pane's session on it, then opens
  the block's data link (`RexTerminalStream`) on a channel of its own under an
  attach slot. It asks `data.connect` for the ticket only once that channel is
  open, so a wait for a slot never spends the ticket's minute, and closes the
  channel if the ticket does not come. Rex ends a channel that stays silent
  too long before its upgrade, so when the server ended it while the ticket
  came, the unused ticket goes once more on a new channel. `RexHostSession` remembers which
  sessions its control client attached. A client the server took back keeps them; after a new client, it
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
  that raced the redraw may show twice or not at all until then. Each repaint
  reads the whole redraw again, so one that output disturbed doubles the
  quiet the next one waits for, up to 30 seconds, until one is exact.
- **Bounds.** Skipping the snapshot keeps less than one marker's length
  between reads, however long it is. A view that stops reading holds its
  block back: the stream stops reading once 1 MiB waits for the view, and the
  data link reads no more than 256 KiB ahead, so the rest waits on the
  server. While a paint is read the stream is read regardless, and up to
  4 MiB of output is kept for after the paint; past that the paint is not
  exact. A redraw longer than 32 MiB ends the terminal with a message to
  clear its scrollback, rather than be read whole again at every repaint.
- **What the redraw leaves out.** The redraw carries no title, cursor shape,
  default colors set with OSC 10 or 11, or saved cursor, and while a program
  uses the alternate screen, none of the primary screen or scrollback behind
  it; that history is painted again once the program leaves the alternate
  screen. With autowrap off, soft wraps are not joined. The title follows the
  inventory's `title_changed` events (ADR 0050), and the colors stay Heeler's
  (until the update of 2026-11-25 below).
- **Query answers are dropped.** Rex answers a program's queries (device
  attributes, cursor and status reports, mode reports, colors) itself, so the
  answers Heeler's own Ghostty writes back must never reach the program.
  `RexTerminalKeyReader` drops them from what the view sends: control
  sequences ending a report, and every OSC, DCS, APC, PM and SOS string
  terminated in the same write, while keys, text, mouse reports and pastes
  pass. Ghostty writes an answer in one piece, so a string opener with no
  terminator is an Alt key (`ESC ]`, `ESC P`) and passes. Focus reports are
  real input, and go as focus events (ADR 0052).
- **Size is a request, not ownership.** The view's grid is asked for with
  the terminal's `resize` method on arrival and once a change has held for
  150 ms, never twice the same, and again when the block's owner lets go,
  since a size asked for under another owner is not applied then. Opening a
  terminal here never called `own_block`; ADR 0053 later takes the size for
  a view that shows the terminal, before its stream starts, and sets out when
  it is taken and given back. The view shows the block
  at the server's size; the server's grid, the view's grid, the owner and this
  client reach the view as `TerminalSizeReport`, from which ADR 0053's notice
  says when another device set the size.
- **Resume or a fresh paint.**
  - A data link that drops while the control link is fine is resumed with the
    exact byte count, within the server's retention; a refused resume opens a
    new stream and paints it whole.
  - A control link that drops and takes its client back on the same SSH
    connection leaves every data stream alone.
  - A new control client, or a new SSH connection, ends every open terminal's
    attach as a lost connection: the view keeps its screen, reattaches, and
    paints afresh.
  - A new SSH connection never takes back a control client that opened a
    data link; it says hello as a new client. An SSH connection that died
    half-open can leave that client's data links open on the server, which
    refuses the same client a second link to a block until it notices the
    dead one, minutes later. A new client is refused nothing, and the
    terminals paint afresh either way. A client that opened no data link is
    taken back as ADR 0050 says.
  - A stream whose new tickets the server keeps refusing for want of an
    attach ends the same way, and the next attach sends `session.attach`
    again on the same client.
  - Another server instance finishes the terminal, as another tmux server
    does; a detail keeps to the instance it opened on.
  - A block that closes, its session going, or its program exiting finishes
    the terminal. The data link closes on its own after the block's last
    output; if it has not a moment after the block's close event, the attach
    ends anyway. Nothing reattaches.
  - Suspending with the app, past the grace period, ends every data link
    with a close frame before the SSH connection closes; the view reattaches
    and paints afresh when the Host is back. The Host stopping ends the
    terminal the same way.
- **One data stream per block per client.** An attach holds its block in
  `RexHostSession` until its stream has closed, so two views, a retained
  attachment beside a new open, or a quick close and reopen never ask for a
  second while the first is open. Data links take the connection's five
  attach slots like any Attach, and the terminal pool's limit applies to Rex
  terminals as to the others.
- **Events.** The inventory follower passes each event on to the open
  terminals before the inventory applies it: a block's close, its owner, and
  its own events. The inventory is unchanged by them.
- **Input** begins with the first paint and goes out one request at a time
  (ADR 0052).

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
  default; when to take it is ADR 0053's, which takes it only while a view
  shows the terminal and gives it back when it stops.
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
- With a data connection left open as a dead SSH connection's server side
  would leave it, the client resumed on a new control connection got a
  refusal for every new data connection to that block, a second apart; a new
  client got its data connection at once.

## Considered options

- Decoding the snapshot: rejected; undocumented and version-bound.
- Ghostty's replay mode for query answers: rejected for the reasons above.
- Taking ownership on open: rejected here; it resizes the desktop's
  terminal. ADR 0053 later takes it as a shown terminal opens, and gives it
  back once the view stops showing it.
- Keeping a stream across a new control client: rejected; the server cancels
  a client's streams once that client is gone.
- Clearing a stale data connection on a new SSH connection by resuming its
  stream there before the new stream's handshake: it works, but needs the
  old links kept across attaches and every terminal route tied to the client
  instead of the SSH connection. Retrying a refused handshake instead waits
  for the server's pings to go unanswered, which takes minutes.

## Consequences

- `RexTerminalAttach` turns one stream into one view's bytes, size requests
  and endings; `RexHostSession.withTerminal` holds the block, waits for the
  connection and hands out a `RexTerminalConnection` with the block's signals.
- ADR 0052 sends the view's input; ADR 0053 takes the size for the view that
  shows the terminal, and shows `TerminalSizeReport`'s mismatch when another
  device has it.
- A first paint costs the snapshot and the redraw, each about the size of the
  scrollback; on a slow link a long history takes seconds to appear.

## Update 2026-11-25: the terminal's own colors

A Rex terminal now wears its own default colors, as the server has them,
instead of the Heeler theme. The data stream already says them: a `theme`
message right after the first resize when they are not Rex's built-in ones,
and again whenever a client changes them with `set_theme` (an empty one
when they go back to the built-in ones). Heeler read and dropped it; now
`RexTerminalPaint` keeps the latest and writes it after each paint's reset,
and a theme after the paint reaches the view at once, as OSC 10, 11 and 12
for the text, background and cursor colors, OSC 110 to 112 back to the
view's own for a color the server keeps built in, and OSC 4 for each listed
palette entry. Colors are written only from six hex digits, so nothing else
in the message reaches the terminal. A palette entry the server stops
listing has gone back to Rex's built-in color, which only the redraw says
(its OSC 4 palette), so that repaints; a new stream sets the last stream's
colors back, since it sends a theme only for colors that are not built in.

Left as they were, because neither API revision 12 nor 19 (Rex
0.1.0-preview.23's `help.all`) offers a way:

- **Cursor shape.** No `format` extra, mode or stream message carries
  DECSCUSR; only the undecoded snapshot may. It stays Heeler's until the
  program sets it again.
- **History behind the alternate screen.** `format` (`vt`, `text` and
  `html`) reads only the screen shown: on the alternate screen it carried
  none of the primary screen or scrollback. Heeler still paints it again
  once the program leaves the alternate screen.
- **A grid wider than the view.** ADR 0053's limit stands: a view scaled to
  or scrolled across another device's grid is a change to the terminal view
  every Server Kind shares (ADR 0045 has it for tmux too), and Fit to Screen
  already gives the terminal this screen's size.

Evidence: on Rex 0.1.0-preview.23 on macOS, 2026-11-25, from a client that
said hello at revision 12, on a lab session: after `set_theme` the stream
carried `{"type":"theme","foreground":"#111111","background":"#fafafa"}`,
and after an empty `set_theme` `{"type":"theme"}`; the `vt` redraw with every
extra carried the whole palette as OSC 4 (entry 1 as set by the theme) and
no OSC 10, 11 or 12, nor the `CSI 5 SP q` the shell had sent; on the
alternate screen, `modes` said `alternate` and the redraw held none of the
40 history lines printed before it.
