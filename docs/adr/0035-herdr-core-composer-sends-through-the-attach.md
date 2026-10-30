---
status: proposed
---

# herdr-core Composer sends through the Attach in checked steps

On Herdr TUI, Composer Send is one `agent.prompt`, which herdr resolves
against the Agent it currently detects in the pane (ADR 0013). herdr-core's own
`terminal.send` pastes and presses Enter only after a person has stopped typing
in that Terminal for three seconds, queues behind other input, checks only the
reported status word, not the process, and keeps the queued input when the
client disconnects. A send can therefore land after the Agent has exited, in
the shell that stays behind, and a retry can deliver it twice.

## Decision

- Composer Send on a herdr-core Agent writes into the Attach the user is
  viewing, over the framed connection (ADR 0031), in two steps. It pastes the
  draft as a bracketed paste. It then checks that the Agent still holds the
  foreground, and only then submits: Enter, or the submit key of the
  Template on the Terminal's record, encoded for the keyboard mode the
  program set (Enter is `CSI 13 u` once it asks for kitty's flag 8).
- A terminal with bracketed paste off gets nothing: the Composer keeps the
  draft and says the program is not accepting a paste. Heeler reads both
  modes from its own emulator after processing the Attach's output in order,
  because the core's repaint turns modes off before it sets them again and
  can arrive in the middle of the stream.
- While Agent Status is Blocked, Send only pastes, as on Herdr TUI, and the
  tools keyboard submits or cancels.
- If the check fails, nothing is submitted. Text the Agent had read goes
  with it; text it had not read reaches whatever now holds the terminal,
  usually the shell's line editor as a pending paste. The Composer keeps the
  draft and says it may be in the terminal.
- A Send whose steps get no answer has an unknown outcome and is never
  repeated. The core holds a viewer's input while it types a note or stitches
  a long read, and writes it once it finishes, so a paste or Enter can still
  reach the program after the connection is gone. Input held by a stitch
  arrives about a second late with no echo meanwhile, and ends the read, so
  a step's timeout allows for it.
- The Composer's Stop is `terminal.interrupt`, which does not wait for typing
  to stop and presses the stop key of the Template on the record, or Esc in
  a Terminal that has had a Program Status and Ctrl+C in one that has not.
  It then waits for the Terminal to report a change, up to 10 seconds in one
  that never reports, so Heeler sends it with a short timeout and reads the
  foreground afterwards: its result does not say whether the program still
  runs. The terminal's Composer keeps Send for Grok Build, as on Herdr TUI,
  since Esc does not stop its turns.
- Chat's Send, Stop and Blocked Card answers keep ADR 0024's rules, Stop's
  per-program keys and screen checks included, and type through a connection
  of Chat's own. It attaches as a resumed viewer, reports no display facts,
  and before it types sends the Terminal's latest size as its own, so that
  sending never resizes the Terminal. A Blocked Card answer is sent only while
  the dialog it answers is still on screen and the Agent still holds the
  foreground. A viewer that only observes cannot type.
- `terminal.send` and `terminal.keys` are not used for authored input.

This amends ADR 0013's Composer Send and Stop, and the herdr requests behind
ADR 0024's Chat Send, Stop and Blocked Card answers, for herdr-core Hosts only.

## Evidence

Source-reviewed against herdr-core v0.1.13 (`88fe4e7`). This is source
evidence, not runtime acceptance from the app. The 2026-10-30 live observations
on a Debian 13 VM in [herdr compatibility](../agents/herdr-compatibility.md)
confirm or refine these points with test clients, not the app.

- [input.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/input.rs#L64-L67)
  waits for three quiet seconds before `terminal.send` and `terminal.keys`,
  and its
  [`if` condition](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/input.rs#L178-L183)
  compares only the status word.
- [input.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/input.rs#L144-L150)
  and [stitch.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/stitch.rs#L204-L208)
  write a viewer's held input once the core's own typing or stitching ends.
- [input.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/input.rs#L262-L278)
  picks `terminal.interrupt`'s key and waits for no quiet period.
- [viewers.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/viewers.rs#L186-L232)
  drops an observing viewer's input and makes the viewer that types, resizes,
  reports display facts or takes focus the size leader.

## Considered options

- `terminal.send`. One call, and it waits for a person to stop typing, but it
  can deliver into the wrong program or twice, as above.
- Insert without Enter and leave submission to the user (PR #538). Nothing can
  submit into a shell, but every message needs the user to finish it in the
  terminal, and the core's own child notes, typed with Enter, can submit the
  unfinished line.

## Consequences

- Send needs a live Attach to the Agent; Composer opens one before sending.
- Send waits for one foreground check between paste and submit, under a
  second on a healthy connection.
- A person typing into the same Terminal on another client at that moment can
  interleave with the paste, as on Herdr TUI.
- Typing through a viewer makes it the Terminal's size leader; the viewed
  Attach leads anyway, and Chat's connection takes the size the Terminal
  already has. When the last viewer that typed leaves, the Terminal returns
  to the core's headless size.
- Under bash, bracketed paste is on only at the prompt, so the mode gate never
  stops a paste into the shell an Agent left behind; only the foreground
  check does.
- A Terminal that has ever reported keeps Esc as its interrupt key after its
  Agent exits, so Stop is offered only while the Agent holds the foreground.
