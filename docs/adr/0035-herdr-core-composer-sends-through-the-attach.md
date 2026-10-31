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
  viewing, over the framed connection (ADR 0031), in two steps. It notes the
  pid of the Agent's foreground process and pastes the draft as a bracketed
  paste. It then waits for a foreground sample taken after the paste: 550 ms,
  one sampling period with margin, after which it reads the Terminal's
  foreground. A foreground event can only stop the Send sooner, by showing the
  Agent gone: it may have been sampled before the paste reached the core, so
  one showing the same program spares nothing. Only when the read shows the
  same pid running the same agent program does it submit: Enter, or the
  submit key of the Template on the Terminal's record, encoded for the
  keyboard mode the program set (Enter is `CSI 13 u` once it asks for kitty's
  flag 8).
- Submit goes out within two seconds of the paste or not at all, because a
  note the core types between the two steps ends with Enter and would submit
  the draft with the note appended.
- A terminal with bracketed paste off gets nothing: the Composer keeps the
  draft and says the program is not accepting a paste. Heeler reads both
  modes from its own emulator after processing the Attach's output in order,
  because the core's repaint turns modes off before it sets them again and
  can arrive in the middle of the stream. For the same reason Send waits for
  the end of the Attach's first paint, the sequence every paint ends with,
  before it reads them: a program's modes can be in a later frame than the
  output that made the Attach live.
- While Agent Status is Blocked, Send only pastes, as on Herdr TUI, and the
  tools keyboard submits or cancels.
- If the check fails or runs out of time, nothing is submitted. Text the Agent
  had read goes with it; text it had not read reaches whatever now holds the
  terminal, usually the shell's line editor as a pending paste. When a shell
  holds the foreground, Send presses Ctrl+C once, which makes the shell drop
  that text unrun. It writes the byte 0x03 whatever keyboard mode is set,
  because an Agent that died leaves its flags behind and a shell reads no
  `CSI 99 ; 5 u`. The Composer keeps the draft and says whether the text may
  still be in the terminal.
- A Send whose steps get no answer has an unknown outcome and is never
  repeated. The core holds a viewer's input while it types a note or stitches
  a long read, and writes it once it finishes, so a paste or Enter can still
  reach the program after the connection is gone. Input held by a stitch
  arrives about a second late with no echo meanwhile, and ends the read, so
  a step's timeout allows for it.
- The next Send after an unknown outcome pastes nothing until the Host answers
  a read, because its paste would line up behind the unanswered one and its
  submit would take both. The answer says what was queued has left, so the first
  text may now be in the Agent's input, which only the user can see: that Send is
  refused with a notice, the draft stays, and the one after goes as usual.
- The Composer's Stop is `terminal.interrupt`, which does not wait for typing
  to stop and presses the stop key of the Template on the record, or Esc in
  a Terminal that has had a Program Status and Ctrl+C in one that has not.
  It then waits for the Terminal to report a change, up to 10 seconds in one
  that never reports, so Heeler sends it with a short timeout and reads the
  foreground afterwards: its result does not say whether the program still
  runs. The terminal's Composer keeps Send for Grok Build, as on Herdr TUI,
  since Esc does not stop its turns.
- Chat's Send, Stop and Blocked Card answers keep ADR 0024's rules, Stop's
  per-program keys and screen checks included, and type through an attach of
  Chat's own on the Host's framed connection; the core keeps one viewer per
  attach. Chat's Send, after its screen checks, takes the Composer's steps
  above: the paste, the fresh foreground sample, the two-second limit, the
  submit key and the Ctrl+C. On a Template's Terminal Chat's Stop presses the
  Template's stop key. Chat's attach is a resumed viewer, reports no display
  facts, and before it types sends the Terminal's latest size as its own, so
  that sending never resizes the Terminal. It is opened for one action and closed
  after, so it holds the Terminal's size no longer than it types. A Blocked Card
  answer is sent only while the dialog it answers is still on screen and the
  Agent still holds the foreground, the same process as when that screen was read.
  Opening the viewer can take seconds, so Chat checks again once its paint is in:
  a key or a paste goes only if the same process holds the foreground as before it
  opened, and an answer only if that paint shows the same dialog. The card's key
  pad counts as an answer, since it is the only one a dialog without options has:
  its keys go only if the paint shows the dialog the card shows, or still none on
  a card that could read none. A viewer that only observes cannot type.
- Chat's screen checks read a viewer's first paint. `terminal.read` has text
  only, and the emulator Heeler embeds reads text only, while every attach
  starts with the styled screen. Each read is an observing attach of its own
  that closes once the paint is in, so it neither types nor counts toward the
  Terminal's size.
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
- [viewers.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/viewers.rs#L180-L182)
  finds a viewer by its connection and channel, so each attach is a viewer
  of its own.
- [viewers.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/viewers.rs#L186-L232)
  drops an observing viewer's input and makes the viewer that types, resizes,
  reports display facts or takes focus the size leader.
- [api/types.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/types.rs#L326-L349)
  gives `terminal.read` no styled or cell form, and
  [viewers.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/viewers.rs#L281-L290)
  paints the screen first on every attach. A capture of all of Chat's screen
  fixtures through a fixture core read back alike
  ([herdr compatibility](../agents/herdr-compatibility.md)).

## Considered options

- `terminal.send`. One call, and it waits for a person to stop typing, but it
  can deliver into the wrong program or twice, as above.
- Refusing Chat's screen-gated actions and offering the terminal's Composer,
  had no styled source existed. Reading the paint keeps Chat's checks, Stop's
  guards and Blocked Cards, for one more attach per read.
- A Chat attach held open, with an emulator of Heeler's own over its bytes. It
  would spare the attach per read, but Heeler has no emulator that keeps styles.
- Checking the foreground as soon as the paste is written. Faster, but the
  core samples the foreground every 500 ms, so the check can still see an
  Agent that has just exited, and Enter then runs the paste in the shell; a
  live test did exactly that.
- Insert without Enter and leave submission to the user (PR #538). Nothing can
  submit into a shell, but every message needs the user to finish it in the
  terminal, and the core's own child notes, typed with Enter, can submit the
  unfinished line.

## Consequences

- Send needs a live Attach to the Agent; Composer opens one before sending.
- Send is offered once the connection reports a POSIX Host. Native Windows
  turns it on separately, after its foreground form is settled (ADR 0032).
- Send takes at least 550 ms and one read between paste and submit, even when a
  foreground event showing the same program comes sooner. On a link slow enough
  that the check passes two seconds, counted from when the paste was handed to
  the link, the text stays in the Agent's input unsubmitted, and the Composer
  says so.
- Under the desktop app's fish wrapper the agent shares the wrapper's pid, so
  only the program behind that pid tells an exited Agent from a live one.
- Each of Chat's screen reads is a round trip and a paint, up to one a second
  while a Blocked Card shows and more often while an answer is checked. Each of
  Chat's actions opens one more attach and closes it, so it costs a paint too.
- Chat's foreground checks before a key use the record the core's events keep,
  up to one sampling period old, as a read would be only a round trip fresher.
  A process can still take over in that period, as a dialog can change between
  the paint and the key. Chat's Stop guards (OpenCode, Grok Build) go by the read
  before the viewer opens, not by its paint, so a screen that changes as it opens
  gets the key; a foreground change does not.
- A person typing into the same Terminal on another client at that moment can
  interleave with the paste, as on Herdr TUI.
- Typing through a viewer makes it the Terminal's size leader; the viewed
  Attach leads anyway, and Chat's attach takes the size the Terminal already
  has. When the last viewer that typed leaves, the Terminal returns
  to the core's headless size.
- Only a first paint is waited for. Heeler cannot tell a repaint from the program's
  output, so a Send during the repaint of a viewer that fell behind 4 MiB can read
  the modes off and refuse, or submit in the legacy key form. The draft stays, and
  a retry reads them set again.
- Under bash, bracketed paste is on only at the prompt, so the mode gate never
  stops a paste into the shell an Agent left behind; the foreground check
  keeps it from being submitted there, and Send's Ctrl+C drops it.
- On Windows, which process the foreground names under PowerShell, and so
  what the same-pid check compares, is unverified (ADR 0032).
- A Terminal that has ever reported keeps Esc as its interrupt key after its
  Agent exits, so Stop is offered only while the Agent holds the foreground.
- Stop is also offered only while Agent Status is Working, and only a report
  makes a status, so a Terminal that has never reported reads Unknown and has
  no Stop. The core's Ctrl+C for such a Terminal is therefore not reached from
  the Composer.
- Heeler gives the core two seconds to watch for an effect and waits one second
  more for its answer, then cancels the call, so the key is never pressed late.
  A call the link had not handed to its writer never goes, and Stop says it was
  not sent. Otherwise Stop reads the foreground without the answer, and only that
  read getting an answer says the key left, since the writer keeps order; with
  neither, the outcome is unknown. A reply and an event have no order on the
  link, so a foreground event that lands during the read wins over what the read
  found.
