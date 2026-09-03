# testloop — 2026-09-02 — issue-268-message-jump

**Verdict:** stopped: driver verified the last two behaviours by hand after the
GUI tester could not · **Rounds:** 3

## Covered

- Attach message-jump chrome on the alternate screen: presence, placement above
  the keyboard band, disabled-while-Working, touch pass-through to the terminal.
- Walking backwards and forwards between user messages on two agent TUIs
  (Grok and Codex), including history from before the app session.
- Captions for a walk that ends without a target.
- Index behaviour across a cold relaunch.

## Found & fixed

- **The walk skipped every message sharing the viewport.** It stepped until no
  message matched before hunting the next one; a phone viewport holds tens of
  rows, so consecutive messages leave together and one press scrolled past all
  of them. It now stops at the first message that was not on screen when the
  press landed, which also removed the phase machine
  (`Sources/Heeler/Terminal/TerminalMessageJumpController.swift`).
- **Matching failed outright on a TUI that right-aligns a send time into the
  message's own first row.** The whole-frame line join then reads
  `...reply with the 7:49 PM word Charlie...`, and no long head of the
  submitted text is a substring of it. Submitted messages now also match a
  shorter head against a single rendered line
  (`Sources/Heeler/Terminal/AttachUserMessageIndex.swift`).
- **Only messages this session sent were targets.** Prompt lines the TUI draws
  are now targets in their own right, so history reached by scrolling back is
  jumpable. A glyph must be followed by a space, which keeps Codex's
  `>_ OpenAI Codex (...)` banner from becoming a stop (same file).
- **The buttons took no actual touch.** The overlay's hit test rejected any hit
  whose view was the hosting root, but SwiftUI does not back a `Button` with
  its own `UIView` — the hosting view answers for the whole interactive area.
  The buttons worked under VoiceOver and under nothing else
  (`Sources/Heeler/Console/MessageJumpControl.swift`).

## Still open

- **Automated GUI testing cannot see this class of bug here.** All three rounds
  drove the accessibility tree, which bypasses hit testing, so every round
  reported the buttons working while a finger could not press them. The defect
  surfaced only when the driver sent a synthesized touch through `idb ui tap`.
  Any future round on interactive chrome should include one real-touch probe.
- A caption lives 1.6 seconds. A tester that screenshots after a walk settles
  will never catch it; only a burst capture across the press does. Rounds 1-3
  each recorded a caption failure for this reason and none was a defect.
- On a session with a very long stretch of output between user turns, a press
  travels its whole step budget and reports "Couldn't find the message". That
  is accurate, not a fault, but the reach is deliberately conservative — worth
  revisiting if it proves annoying in daily use.
- The prompt-glyph rule is a heuristic. Agent output that opens a line with
  `> ` will read as a user message and cost one surplus press.
