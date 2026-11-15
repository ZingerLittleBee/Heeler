---
status: proposed
---

# Rex terminal size is taken only when the user asks

A Rex block has one size, its owner's (ADR 0050). Heeler asks for the view's
grid and never owns the block on its own, so a terminal that another device
owns shows at that device's size: lines wrap at its width, a line wider than
the view wraps again at the view's, and rows run past or stop short of the
screen. Owning the block would make the view's size the
block's, and every other device's view of it would follow. Against Rex
0.1.0-preview.14 (API revision 12), `session.own_block` with mode `take`
made the caller the owner at once and applied the size it had asked for, and
`session.disown_block` passed the block on to the client in line for it, or
left it with no owner at its size.

## Decision

- **Taking is explicit.** Only the user's tap takes a terminal's size: the
  notice's Fit to Screen. `RexTerminalAttach.take` sends `own_block` with mode
  `take` for the one block, always named, then asks for the view's grid as
  the block's owner, so it applies at once. Nothing else takes it: not opening
  the terminal, a reconnect, a fresh control client, a new SSH connection, the
  owner letting go or dropping, the view coming back, or the app's return.
- **The same gate as input.** A take or give back goes out only on the live
  control link while it is still the terminal's: the same server instance, SSH
  connection and control client (ADR 0051). The two go out one at a time, in
  the order asked, each once. A take that was refused, not sent, or left with
  no answer is never sent again on its own; the notice says which, and only
  another tap tries again. A take with no answer may have arrived, so it counts
  as taken for giving back. The owner an answer names is shown only when no
  owner change or grid was heard while the answer was on its way: one heard
  meanwhile may be newer, and the server's own owner change follows any take
  that moved the block.
- **What gives it back.** A size the user took goes back with
  `disown_block` when the view stops showing the terminal (the user navigates
  away, or the retention pool keeps it off screen), when its scene goes to the
  background, and when the attach ends for any reason, before the block is
  free for its next attach. Giving back is best effort: it waits at most two
  seconds of silence and ten in all, and one that was not sent or had no
  answer waits for the next of these to try. That includes the next attach
  of the block on the same control client, and the control link that takes
  the client back after a drop, which gives back what no attach holds. A give
  back while another device has the block takes this client out of line, so
  the block is not passed to it later.
- **What the server handed over after a drop stays.** When the server passes
  the block to this client because its owner's link dropped, as when the
  device that took it back drops while this client is in line, the block
  stays as the server made it: leaving does not give it up. A block passed on
  because its owner let go of it or left with a close frame is given back
  like any size the user took.
- **The notice.** A live terminal whose block another client owns, at a grid
  other than the view's, shows a small notice once that has held for a second:
  "Sized for another device", with Fit to Screen and a way to dismiss it. It
  goes as soon as the grids agree or this client owns the block. Dismissed, it
  stays away while the same client keeps the size, and comes back when another
  client takes it. It sits over the terminal's bottom rows, above the input
  row, while the last row with text is in the upper half of the view, and
  over its top rows below the back header otherwise, so it stays clear of
  where the output ends and the prompt and cursor usually are. It is drawn in
  the terminal's colors and never takes a row of its own. Other Server Kinds
  size their terminals to the view and have no notice.
- **No scaled view.** Heeler does not scale the other device's grid down to
  the screen. As with tmux (ADR 0045), that needs a terminal view whose grid
  the remote side fixes, which no Attach has.

## Why

- Taking the size changes the terminal on every other device looking at it,
  as on a desktop where its user is typing. That belongs to the user, at a
  moment they choose, never to a reconnect.
- A view that stops showing the terminal no longer needs its size, and the
  device it took the size from is often the one its user is back at. Giving
  back on leaving puts the size back in that device's hands without anyone
  having to take it again.
- Giving up a block the server handed over after a drop cannot be undone:
  Rex returns a block to an owner that comes back after a drop only while the
  block's owner has not changed since. Giving it up would leave the block with
  no owner, and the device that dropped would not get it back. A block its
  owner let go of, or left with a close frame, has nobody to go back to:
  keeping it would only hold this screen's size on every other device.
- A notice in a row of its own would shrink the view's grid, which could then
  match or miss the other device's and make the notice come and go by itself.
  Over the grid it changes nothing, and it can be dismissed. Over the top rows
  alone it hid the prompt of a terminal with a few lines of output, which is
  where a short screen's cursor is, so it moves to the blank rows under them.

## Evidence

Against Rex 0.1.0-preview.14 (API revision 12) on macOS 27.0, from lab
captures, live tests and fakes, recorded with their sources in
`docs/agents/rex-compatibility.md`:

- A take from a client that did not own the block was answered within a few
  milliseconds with that client as owner; every attached client heard the
  owner change and then the size change, and the size it had asked for
  applied at once.
- A give back from the owner passed the block to the client in line that
  claimed it last, at that client's size; with nobody in line the block kept
  its size with no owner. A give back from a client that did not own the block
  only took it out of line, with no event.
- A client that had only asked for a size, and never claimed the block, was
  never passed it.
- An owner that dropped without a close frame lost the block to the client in
  line and got it back when it resumed; when the client it passed to gave the
  block up in between, it did not.
- In `RexTerminalSizeLiveTests`, an 80x24 view of a lab block another client
  owned at 100x30 showed its notice, took the size so the server's grid became
  80x24 with Heeler's client as owner, and on leaving passed the block back to
  that client at 100x30; coming back took nothing.

## Considered options

- Taking on open, or after a reconnect: rejected; it resizes another device's
  terminal unasked, and a reconnect is no request.
- Taking with mode `request`: it applies only to a block with no owner, which
  a size request already does, so it would add nothing but a place in line.
- Giving back only when the attach ends: rejected; a terminal the retention
  pool keeps off screen, for up to five minutes, would hold the other
  device's size all that time.
- Giving up a block the server handed over after a drop: rejected for the
  reason above.
- A bar of its own above the grid: rejected; it changes the view's grid.
- Scaling the other device's grid to the screen: rejected, as in ADR 0045.

## Consequences

- `TerminalAttachSession.sizeOwnership` carries the take and the viewer
  leaving; `AttachTerminalStore` publishes `sizeNotice` from the size reports
  it reads, and `TerminalSizeNoticeView` draws it in `ShellTerminalView`.
- `RexTerminalConnection.deliver` takes a deadline of silence and a limit in
  all, so input and taking the size wait 10 seconds of silence and a minute in
  all, and giving back two and ten.
- `RexHostSession` keeps what each block's attaches claimed, per control
  client, past the attach: a give back that could not go out before an
  attach ended is made by the next attach of the block on that client, or by
  the session once a link takes the client back. Until then the client stays
  in line, and if the owner lets go meanwhile the block can be passed to it.
- A new control client claims nothing: the server forgot the old client and
  its claims. A terminal that opens again on one has nothing to give back,
  and the notice offers the size again.
