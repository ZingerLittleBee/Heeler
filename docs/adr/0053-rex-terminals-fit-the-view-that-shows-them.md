---
status: proposed
---

# Rex terminals fit the view that shows them

A Rex block has one size, its owner's (ADR 0051). A view that does not own
the block shows it at the owner's size: lines wrap at its width, a line wider
than the view wraps again at the view's, and rows run past or stop short of
the screen. Owning the block makes the view's size the block's, and every
other device's view of it follows. Against Rex 0.1.0-preview.14 (API revision
12), `session.own_block` with mode `take` made the caller the owner at once
and applied the size it had asked for, and `session.disown_block` passed the
block on to the client in line for it, or left it with no owner at its size.

This ADR first made taking explicit: only the notice's Fit to Screen took the
size, so the user tapped it every time they opened a terminal another device
had sized. The maintainer asked for Heeler to fit it by itself. The rules on
another client's take, on a take that fails, on which terminals take, and on
having no setting were set as defaults with that change, not asked for in it;
each can change without revisiting the rest.

Amended by [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md):
a Rex Agent's terminal shows on the Agent detail's Terminal surface, which is
a showing under these rules, and never while its Chat surface is on screen.

## Decision

- **Shown means fitted.** When Heeler shows a live Rex terminal, it takes the
  block's size for this screen with no tap, once per showing. A showing
  begins when the terminal's screen is on screen in a scene in the
  foreground: when it opens from Terminals, or as a Rex Agent's Terminal
  surface in the Agent detail (ADR 0056); when the retention pool or the
  Agent detail brings a kept attach back on screen; and when its scene comes
  back from the background. It ends when the screen goes off screen (for an
  Agent, also when its detail turns to Chat), its scene goes to the
  background, or the attach is stopped. A reattach while the screen stays
  shown, after a drop, over a new SSH connection, or on a fresh control client
  after a longer drop, belongs to the same showing, and each new attach takes
  the size as it opens. On iPad a terminal shows in one scene at a time, since
  the retention pool refuses it a second window and windows take turns with a
  Rex Host's Agent terminals (ADR 0056), so two scenes never take it from each
  other.
- **Before the first paint.** An attach that opens for a showing takes the
  block before its stream starts: `own_block` with mode `take`, then the
  view's grid asked for as the owner, then `data.connect`. Rex applies an
  owner's size at once, so the stream starts at the view's grid and the first
  paint is drawn at it, with no notice on the way. The paint waits for two
  round trips on the control link, the take and then the view's grid as its
  owner, and each waits no longer than the input deadline when it has no
  answer. A take for an attach already painted,
  as when the pool brings one back or the scene returns, moves the block to
  the view's grid while the screen shows it: the screen keeps the earlier
  layout until the server's grid change, which arrives before the take's
  answer, repaints it (ADR 0051).
- **The same take as the tap's.** A take on its own goes through the tap's
  gate, one-at-a-time queue and deadlines (ADR 0052), and is given back the
  same way. It is sent once and never again on its own, whatever became of
  it: one refused, not sent, or with no answer leaves the size where it is,
  and the notice offers Fit to Screen for the rest of the showing. One with no
  answer may have arrived, so it counts as taken for giving back. A take on
  its own sends nothing while this client owns the block already. A take that
  Heeler's own stop of the attach cuts short, before it goes out or while its
  answer is awaited, did not fail: the stop is Heeler's, as when the screen's
  pipeline is replaced while it shows, and the attach that replaces it takes
  the size as it opens. A refusal counts whenever it comes. A showing that
  begins just as Heeler replaces the screen's pipeline, as when the scene
  comes back or the retention pool hands a kept attach back after a possible
  suspension, takes nothing for the attach on its way out, which would only
  give the size back as it stops.
- **No tug of war.** When another client takes the size while the screen
  shows the terminal, Heeler leaves it there: the notice offers Fit to Screen,
  and nothing takes the size back on its own for the rest of the showing, its
  reattaches included. The next showing takes it on its own again. Another
  client's take is told from the owner changes the control link carries and
  from the take's answer: an owner change to another client with the reason
  `take`, heard while this client held the size, or heard after its own take
  went out with no owner change to this client after it. This client's own
  take, heard as an owner change to itself, counts for nothing, and so does a
  grid the stream shows before this client's take applies. The owner an
  answer names is used only when no owner change or grid came while the
  answer was on its way, since those may be newer.
- **Only a terminal the user looks at.** Nothing else takes a size: not an
  attach the retention pool keeps off screen, not a prefetch, not the lists, a
  row, Agent Status or a "looked at" mark (ADR 0054), not Chat's reads or
  typing (ADR 0055), and not a screen whose scene is in the background.
- **The tap stays.** The notice and its Fit to Screen stay as they were, as
  the fallback and the way to take the size back within a showing; there is
  no setting and no new control. A tap that goes through lets the showing take
  the size on its own again, as its next reattach opens, unless another
  client took the size after the tap's take. Dismissing the notice keeps the
  other device's size for the rest of the showing.
- **What gives it back.** A size this client took goes back with
  `disown_block` when the screen goes off screen (the user navigates away, or
  the retention pool keeps it off screen), when its scene goes to the
  background, and when the attach ends for any reason, before the block is
  free for its next attach. A showing that ends while its attach opens gives
  back what that attach takes, as soon as the attach is in hand. Giving back
  is best effort: it waits at most two seconds of silence and ten in all, and
  one that was not sent or had no answer waits for the next of these to try.
  That includes the next attach of the block on the same control client, and
  the control link that takes the client back after a drop, which gives back
  what no attach holds. A give back while another device has the block takes
  this client out of line, so the block is not passed to it later.
- **What the server handed over after a drop stays.** When the server passes
  the block to this client because its owner's link dropped, as when the
  device that took it back drops while this client is in line, the block
  stays as the server made it: leaving does not give it up, and a take on its
  own sends nothing for it, since this client owns it already. It stays so
  only while it is this client's: once its owner changes to another client or
  to none, as when the device that dropped resumes and gets it back, this
  client is only in line for it, as for a size it took, and the next showing
  takes the size again. The Host session follows that change for a block no
  attach has open. A block passed on because its owner let go of it or left
  with a close frame is given back like any size this client took.
- **The notice.** A live terminal whose block another client owns, at a grid
  other than the view's, shows a small notice once that has held for a second
  and no take of its own is out: "Sized for another device", with Fit to
  Screen and a way to dismiss it. An ordinary open shows none, and neither
  does a screen whose scene is in the background, though the size it gave
  back there is another client's: the showing that begins as the scene comes
  back takes the size again, so the notice would only greet the user on the
  way back. It goes as soon as the grids agree or this client owns the
  block. Dismissed, it stays away while the same client keeps the size, and
  comes back when another client takes it. It sits over the terminal's bottom
  rows, above the input row, while the last row with text is in the upper
  half of the view, and over its top rows below the back header otherwise, so
  it stays clear of where the output ends and the prompt and cursor usually
  are. It is drawn in the terminal's colors and never takes a row of its own.
  Other Server Kinds size their terminals to the view and have no notice.
- **No scaled view.** Heeler does not scale the other device's grid down to
  the screen. As with tmux (ADR 0045), that needs a terminal view whose grid
  the remote side fixes, which no Attach has. So while a line on the other
  device's grid is wider than the view, the rows do not match: the cursor,
  which the redraw places by the server's row and column, and output that
  moves it the same way land on the server's row, over the wrapped text,
  until a fit paints the terminal at the view's grid. Moving the cursor to
  where the wrap put the text would need the view to lay the redraw out
  first, and the program's next move by row and column would undo it.

## Why

- A terminal shown at another device's size is hard to read and type into on
  a phone, and the user opened it to use it here. A tap on every open was a
  step nobody skipped.
- Taking the size still changes the terminal on every other device showing
  it, as on a desktop where its user is typing. Taking only while this screen
  shows the terminal, giving it back as soon as it stops, and leaving a size
  another client takes during the showing with that client keep the change to
  the time the user is looking here, and keep two devices showing the same
  terminal from taking it from each other: the last to show it keeps it until
  someone taps.
- A take that failed on its own points at the link or the block, which trying
  again on its own would not fix, and a take sent again could arrive twice.
  The tap stays for a deliberate retry.
- A terminal kept off screen, or one in a scene in the background, is not
  being looked at: taking for it would hold this screen's size on every other
  device for nobody.
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
- Taking before the stream starts costs a round trip before the first paint,
  and spares a first paint at the other device's grid followed at once by a
  second at the view's.
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
- A take from a client that had asked for no size yet left the grid as it
  was, with that client as owner; the owner's resize that followed applied at
  once, and a data stream opened after both started with a resize at that
  grid naming the client as owner. On a stream already open, a take from a
  client that had asked for a size as a non-owner brought that size, and the
  stream's resize naming it owner arrived before the take's answer.
- A give back from the owner passed the block to the client in line that
  claimed it last, at that client's size; with nobody in line the block kept
  its size with no owner. A give back from a client that did not own the block
  only took it out of line, with no event.
- A client that had only asked for a size, and never claimed the block, was
  never passed it.
- An owner that dropped without a close frame lost the block to the client in
  line and got it back when it resumed; when the client it passed to gave the
  block up in between, it did not.
- In `RexTerminalSizeLiveTests`, an 80x24 view opened shown on a lab block
  another client owned at 100x30: the first grid it heard was 80x24 with
  Heeler's client as owner, and no notice showed. The other client then took
  the block back and kept it, with the notice offered; leaving left the block
  with that client, coming back took the size again, and leaving once more
  passed the block back to that client at 100x30.

## Considered options

- Taking only at the user's tap, this ADR's first decision: dropped. It kept
  another device's view of the terminal from being resized unasked, but made
  the user tap on every open. The rules above keep most of that: the size
  changes only while this screen shows the terminal, goes back when it stops,
  and stays with another client that takes it during the showing.
- Taking it back whenever another client takes it while shown: rejected; two
  devices showing the terminal would take it from each other at every change.
- Trying a failed take again on its own: rejected for the reason above.
- Taking for an attach kept off screen, or as the lists or Agent Status read a
  terminal: rejected; nobody is looking at it.
- A setting to turn taking on its own off: not added. Dismissing the notice
  keeps another device's size for a showing.
- Taking after the first paint, for an attach that opens shown: rejected; it
  paints at the other device's grid, then again at the view's.
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

- `TerminalSessionHandler.takesSizeOnOpen()` asks the view's store, as a Rex
  attach opens, whether the terminal is shown and its showing still takes the
  size on its own; `RexTerminalAttach.session(fitting:)` then holds the
  stream until that take has ended.
- `TerminalAttachSession.sizeOwnership` carries the tap's take, the take on
  its own for an attach already open, how the take made as the attach opened
  ended, and the viewer leaving. `TerminalSizeReport.takenAway` counts another
  client's takes from this one in an attach.
- `AttachTerminalStore.SizeShowing` keeps whether the screen's scene is in the
  background and whether the showing still takes the size on its own; a store
  that replaces another carries it, as it carries `isViewed`.
  `TerminalSizeNoticeOverlay` tells the store when its scene goes to the
  background and when it comes back. `AgentAttachStore` forwards the same
  rule for the Agent detail's terminal (ADR 0056), and the overlay reads
  either through `TerminalSizeNoticeSource`.
- An attach replaced while the screen stays shown, as after a possible
  suspension, gives the size back as the old attach stops and takes it again
  as the new one opens, even when the old one's take was cut short by that
  stop. `ShellTerminalStore` calls `AttachTerminalStore.willBeReplaced()`
  before it stops the old store, so a showing that began in the same pass,
  as the scene came back or the pool handed the attach back, asks the old
  attach for nothing. A showing that began a pass earlier has its take out
  already; that one goes and comes back as before.
- `RexTerminalConnection.deliver` takes a deadline of silence and a limit in
  all, so input and taking the size wait 10 seconds of silence and a minute in
  all, and giving back two and ten.
- `RexHostSession` keeps what each block's attaches claimed, per control
  client, past the attach: a give back that could not go out before an
  attach ended is made by the next attach of the block on that client, or by
  the session once a link takes the client back. Until then the client stays
  in line, and if the owner lets go meanwhile the block can be passed to it.
  A block the server handed over is kept as handed over until an owner change
  the control link carries names another client or none.
- A new control client claims nothing: the server forgot the old client and
  its claims. A terminal that opens again on one has nothing to give back, and
  takes the size as it opens if its showing still does.
