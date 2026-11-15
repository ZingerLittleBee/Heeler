---
status: proposed
---

# Rex terminal input goes out one request at a time

A Rex terminal opens for viewing from the server's redraw (ADR 0049). Typing
into it, pasting, scrolling, the Keys panel and Stop must reach the program in
order, exactly once, and never in another terminal. Rex takes input on the
control connection in two ways: the terminal's `write` method, whose text
reaches the program as written, and `block.event`, which hands the block a
paste, a mouse or wheel event, a focus change or a key for the server's own
terminal to encode. Against Rex 0.1.0-preview.14 (API revision 12), writes
sent without waiting for their answers reached the program out of order, and
so did writes mixed with events; a text frame that was not valid UTF-8 closed
the whole control connection.

## Decision

- **One queue, one request out.** Each open terminal has one input queue for
  every kind of input: keys, pastes, scrolling, focus, the Keys panel and
  Stop. `RexTerminalAttach` sends one request at a time on the control link
  and waits for its answer before the next.
- **Typed bytes go through `write` as text.** `RexTerminalKeyReader` reads
  each write the view makes, whole, into what leaves. Keystrokes that queued
  while a request was out join the next write, within a budget under the
  link's message limit, and never across a paste or an event. Text is cut
  only between characters and between whole escape sequences.
- **Answers to queries are dropped** on the way out, as ADR 0049 set out: Rex
  answers a program's queries itself.
- **Never invalid text.** The bytes the view writes are not always UTF-8. A
  legacy mouse report past column or row 95 goes as the mouse or wheel event
  it reports. Any other byte that is not part of a character is an 8-bit Meta
  key and goes as ESC and the byte without its high bit, the form programs
  read as Alt.
- **Pastes go as the server's paste event**, never as bytes: single lines,
  reviewed multiline pastes and multiline Snippets. Heeler never frames one
  with bracket markers; the server frames it as its own terminal's mode says.
  A paste whose request would pass the message limit is refused, with the
  reason in the view's Paste Blocked alert, and never cut. A bracketed paste
  found in the view's own bytes goes as a paste event too. The clipboard
  safety check every Server Kind applies still runs first.
- **Mouse and wheel reports go as the emulator wrote them.** Heeler's Ghostty
  mirrors the program's mouse modes from the paint and encodes each report in
  the program's own protocol, which goes as text when it is valid; only a
  report text cannot carry becomes a `block.event`. With no mouse tracking on
  the primary screen, scrolling moves the view's own scrollback only. On the
  alternate screen with no tracking, scrolling sends arrow keys, as it does
  for the other Server Kinds.
- **Focus changes go as focus events**, `in` and `out`, which the server
  reports to a program that asked for them.
- **The gate.** Input begins with the first paint: the view gets no writer
  until the first output, which for Rex is that paint. Each request then goes
  only on the live control link while it is still the terminal's: the same
  server instance, the same SSH connection and the same control client, which
  a link that resumed the client keeps. The gate closes at once when the
  block's close is heard, the block's stream ends, the program exits, or the
  attach ends for a reset, another server or the view letting go; a terminal
  that comes back opens again with its next paint. Input that meets a closed
  gate, or no link that is the terminal's, is dropped with what queued behind
  it, never kept for later.
- **An unknown outcome is never sent again.** A request that left with no
  answer, because the link ended, its 10-second deadline passed or its sender
  was cancelled, may have reached the program. So may one the server
  refused. Neither is sent again: what queued behind it is dropped, the queue
  takes nothing more, and the attach ends with `RexTerminalEnding.inputFailed`,
  which the view shows as the other Server Kinds show a failed input write
  ("Connection dropped: attach input failed."), with Reattach. That ending wins
  over a connection reset the view has not yet heard of. A refusal because the
  block is gone finishes the terminal instead.

## Why

- Rex applied pipelined writes out of order, so order needs one request out at
  a time; joining what queued meanwhile keeps a burst to a few round trips.
- `write` passes Ghostty's own encoding of every key through unchanged: kitty
  keyboard flags, modifyOtherKeys, IME text and the Keys panel's bytes. Turning
  those bytes back into key events would lose fidelity and need a second model
  of the program's keyboard modes.
- The server knows its terminal's real bracketed paste mode; the view's copy
  can lag a mode change by a round trip. A paste cut in two would reach the
  program as two pastes.
- Mouse reports as written need no second encoder and cover every protocol
  Ghostty speaks, SGR pixel reports included. The paint carries the program's
  modes, so the view's emulator reports what the program asked for.
- Sending a keystroke again whose fate is unknown could run a command twice,
  and sending what typed after it alone could change what the program reads.
  Ending the attach is what the other Server Kinds do when an input write
  fails, so the user sees the same thing.
- The other Server Kinds reject input while their terminal reconnects rather
  than hold it, since a key typed at a screen the program has left would
  answer whatever it moved on to. Rex keeps that rule.

## Evidence

Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, from the input
lab capture and the live input test, recorded with their sources in
`docs/agents/rex-compatibility.md`:

- Writes each waited for arrived in order; writes sent without waiting did not,
  and neither did writes and events mixed. Paste events sent without waiting
  arrived in order.
- A `write` wrote its text's UTF-8 bytes unchanged: control characters, DEL,
  C1 code points and 400,000 bytes in one request.
- A paste event was framed with the paste markers only while the program had
  bracketed paste on; with it off, line feeds became carriage returns. ESC and
  other control characters in a paste became spaces either way.
- A text frame that was not valid UTF-8 closed the control connection with
  1007.

## Considered options

- Sending requests without waiting, ordered by a sequence number: rejected;
  the server does not apply them in order.
- `block.event` keys for every key: rejected for the fidelity reasons above.
- Framing pastes in Heeler from the view's mode: rejected; the server frames
  from the real one.
- Cutting a large paste into several: rejected; the program sees several
  pastes.
- Holding input typed during a reconnect for the next link: rejected, as for
  the other Server Kinds.
- Sending a request again after an unknown outcome: rejected; it may apply
  twice.

## Consequences

- Each write costs one round trip on the control connection before the next
  leaves; on a slow link, keys typed meanwhile leave together.
- `TerminalAttachInputQueue` gains a way to take the keystrokes queued at its
  head and to drop everything on an unknown outcome; `TerminalAttachSession`
  says when input begins and carries a paster that sends a paste as itself.
- Input typed while a dropped control link is being resumed is dropped
  silently: the view stays live over the data stream meanwhile.
- The next slice shows `TerminalSizeReport`'s mismatch and an explicit take
  of the block's size.
