---
status: proposed
---

# Rex Chat reads and types on the control connection

A Rex terminal running Claude Code or Codex is an Agent (ADR 0054), and Chat
can already bind it to its conversation from what the Host's own SSH
connection reads (`RexHostReads`, `HerdrCoreSessionBinder`). Chat's Send, Stop
and Blocked Card answers, and Composer Send, still need to read the Agent's
screen and reach its program. herdr-core Hosts type through the open Attach
(ADR 0035) and tmux Hosts through an Attach of Chat's own (ADR 0045). On Rex
an open terminal is a `session.attach`, a data connection and the block's size
taken for the view that shows it (ADRs 0051 and 0053). Chat shows no terminal:
taking the size for it would reshape a block another client shows, and the
data connection exists only to paint a view.

Against Rex 0.1.0-preview.14 (API revision 12), a control client that had
only called `session.attach_all` could read a block's foreground, modes, grid
and text, and could write and paste into it, without the block's size or
owner moving. Rex answers those reads and takes that input on the control
connection Heeler already holds (ADR 0050).

Amended by [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md):
Chat and the Composer are offered on Rex Hosts, in the Agent detail, and the
terminal Composer offers Stop. Since its update of 2026-11-17, images and
files are attached as well: staged over the Host's SSH connection, their
paths typed with the message.

## Decision

- **Requests to one block on the control connection.** Chat's reads and input
  go through `RexBlockRequests`, which `RexHostSession.blockRequests(at:readDeadline:)`
  hands out pinned to the server instance, the SSH connection and the control
  client the Host holds now. A request made once any of them changed is not
  sent; another server instance is refused as `rexServerGone`. It reads the
  foreground (`process`), the modes, the grid and the text, writes text and
  sends paste events. It never calls `session.attach`, opens no data
  connection, asks for no size and never takes or gives back a block.
- **One lane per block.** Input to a block waits its turn in that block's lane
  (`RexBlockLanes`), which the input of a terminal view open on the same block
  shares, so ADR 0052's one request at a time holds across Chat and the view.
  The last check before Chat's input runs in the lane too, so nothing the view
  sends falls between that check and the input. Screen reads stay outside the
  lane, except the read a Blocked Card answer makes just before its keys.
- **Each request once.** A request that got no answer may have reached the
  program and is never sent again. A failure before the first request of a
  step left means nothing was sent; one after it is reported as an unknown
  outcome, which for Chat's keys and pastes is the Host not confirming the
  action, never that nothing was pressed. A Composer Send whose last request
  went unanswered warns once that the message may still be in the Agent's
  input, as on herdr-core.
- **The holder.** Typing goes only to the known Agent that leads the
  foreground (`RexAgentHolder`, read with `RexAgentRule`): read before
  anything is encoded, and again once the lane is held. A Blocked Card's
  answer goes only while the process read with its screen still holds the
  terminal. Rex names no start time, so a process that took the same process
  id under the same program reads as the same holder.
- **The screen, only where its shape is certain.** `RexChatScreen` reads the
  grid, then the `vt` text with soft wraps kept as rows and the kitty keyboard
  flags appended, then the grid again, which must not have changed. A short
  answer comes in its first page of 1 KiB; a longer one is read from its last
  16 KiB, then 64 KiB, then 128 KiB, each in at most eight pages, so a long
  history never costs more than that. The screen is the answer's last `rows`
  lines. Each line may hold only the SGR codes the lab saw, `CSI n C` for
  blank cells, `CSI n X` followed by the same `CSI n C` for cells blanked in
  a background color, and hyperlinks in the forms Rex writes, which change no
  cell and are passed over; it must close its style, though a link may stay
  open into the next line. Any other sequence or control character, a cut
  character, a style left open, too few lines or a row wider than the grid
  makes the read fail, which Chat shows as the terminal's screen not being
  readable through Rex, and nothing is answered over it.
- **The read rhythm.** The Blocked Card keeps the watch every Server Kind
  uses: a read each second, and reads every 150 ms only in the short windows
  after the user answers. Each read is serial, bounded as above and usually
  four requests, runs on the control connection outside the lane so it never
  delays typing, and gives up after 5 seconds of silence or 10 seconds in all.
  In the lab, over a link of about 50 ms each way and 10 Mbit/s, a tail read
  each second left typing and events at their usual pace, where whole reads
  held both back. Each read leaves the rest of the answer on the server
  behind an id, as does the short read for a key's kitty flags; Rex
  0.1.0-preview.14 kept only the latest few, and a watch of a 10,000-line
  history once a second for five and a half minutes held the server's
  footprint at most 15 MB up, flat, until it ended.
- **Keys and pastes.** Heeler encodes the keys for the modes and kitty
  keyboard flags Rex reports, with the encoder herdr-core Chat uses, and sends
  them in one `write`, so keys that must arrive together do. A paste goes whole
  as Rex's paste event and must fit in one message. Text with a line break is
  pasted only while the program has bracketed paste on, read in the lane just
  before the paste, since otherwise the server would turn each line break
  into a carriage return that submits.
- **Composer Send in tmux's order of checks** (ADRs 0035 and 0045), from the
  terminal and from Chat alike: a known Agent holds the foreground, its status
  is not Blocked, bracketed paste is on (for any draft, as on tmux), and the
  draft fits; the paste, after the holder and bracketed paste are read again
  in the lane; then Enter, after the holder and status are read again in the
  lane, within the two-second submit window. A shell that took over after the
  paste gets one `0x03`, which drops the pasted text unrun, only while that
  shell still leads the foreground, read again in the lane; the Agent back by
  then, or another process, gets nothing. A Send from an open terminal
  view adds what it submitted to that view's message index, as on the other
  Server Kinds.
- **Stop.** Chat's Stop presses the keys of the program's Stop plan through
  these key presses, screen checks included, as on herdr-core Hosts (ADR
  0024). The terminal Composer offers no Stop on a Rex Host. (Amended by ADR
  0056: the Agent detail's terminal Composer offers Stop while the Agent is
  Working, and presses one Esc as these key presses do, holder check
  included.)
- **Status decides Stop and the Blocked Card.** Both follow the Agent Status
  read from Rex's Program Status (ADR 0054). An Agent whose status is Unknown,
  because its program reported none, gets no Stop and no Blocked Card.
- **Nothing is recorded on the Host.** A Blocked Card's answers are not
  written anywhere on the machine, and a confirmed conversation is kept on the
  device (`HerdrCoreHostMemory`), not in an option or file on the Host. (A
  file the user attaches is staged there since ADR 0056's update of
  2026-11-17; that is the user's own file, not a record of Heeler's.)
- **Attachments.** Images and files in a message need a file written on the
  Host. On the other Server Kinds the stagers write it over SFTP through the
  Host services, which a Rex Host keeps closed
  (`RexConsoleProjection.withHostServices` throws), and `RexHostReads` can
  write nothing, so this change left Rex's `imageStager` and `fileStager`
  throwing. (Amended by ADR 0056's update of 2026-11-17: they stage through
  `RexHostStaging`, a seam of the Host's SSH connection that can do nothing
  else. A staged path is part of the message's text, so it reaches the
  program in Composer Send's one paste, in the block's lane, once.)
- **Claude Code and Codex only**, as `HostCapabilities.rexChatPrograms` says.
  (Amended by ADR 0056's update of 2026-11-18: Pi and Oh My Pi as well. A
  Chat check now also reads the foreground on the control link, as typing
  does, before it reads the Host's processes.)
- **Built, not offered.** `RexConsoleProjection` answers `readAgentScreen`,
  `sendAgentKeys`, `pasteIntoAgent`, `checkedChatTyping` and
  `checkedComposerSend` this way, while `HostCapabilities` still offers a Rex
  Host no Chat and no Composer. Opening them is a separate change. (Opened by
  ADR 0056: a Rex Host whose server named a Linux or macOS kernel offers Chat
  for Claude Code and Codex, and every Rex Host offers Composer Send and
  Stop.)

## Why

- **The control connection, not an Attach of Chat's own.** An Attach would
  either take the block's size, reshaping a terminal the desktop app or
  another device shows, or paint at a grid it does not own. The control
  connection is already open, and the lab showed input on it moves neither
  size nor owner.
- **One lane, not one connection per caller.** Rex may apply requests sent
  without waiting out of order (ADR 0052). A second queue for Chat beside the
  view's would let Chat's Enter overtake the view's last keys, or the reverse.
- **Fail closed on the screen.** A Blocked Card answers by pressing keys over
  what it read. Rex's `vt` text is a redraw, not a screen dump, and only the
  sequences the lab saw are known to mean what the decoder takes them to; a
  misread dialog would be answered wrongly, so an unexpected shape is no
  screen.
- **Heeler's own key encoding.** Rex's key events would leave the encoding to
  the server, which the lab did not check against every key Chat presses, and
  could not carry two keys in one request.

## Consequences

- An Agent with Unknown status cannot be stopped or answered from Chat; the
  user turns to its Terminal surface (ADR 0056).
- A program with bracketed paste off gets no Composer Send.
- A screen the decoder does not know, as after a Rex update that writes
  another sequence, stops Blocked Card answers, Stop and Send until the
  decoder learns it. A real Codex's hyperlinks did so before the decoder
  took them.
- A hyperlink whose URI holds a byte that is not UTF-8 makes Rex count the
  answer's length two ways, so every read of that terminal that takes more
  than one page fails, the short kitty flags read included. While the link
  stays in the answer, its history included, that terminal gets no Blocked
  Card answers, Stop or Send, from Chat or the Composer.
- A process that replaced the Agent under the same process id and program is
  not told apart.
