# testloop — 2026-08-25 — composer-skills (issue #234)

**Verdict:** pass · **Rounds:** 3 (1 environment-blocked, 1 test, 1 re-verify)

## Covered

- Both new Skills entry points on a live claude agent: the More-menu picker
  (sheet, Global grouping, case-insensitive search, insert-without-send,
  Done leaves the draft alone) and inline suggestions (trigger on `/`,
  filter while typing, token replacement to the full invocation plus
  trailing space, ✕ dismissal, auto-close after insertion).
- The Codex `$` path end to end: `$apple` suggests and inserts
  `$apple-design `; a `/` token on a codex agent correctly triggers nothing
  (prefixes ride the agent's skill catalog, not the Composer).
- Two disposable live agents (claude + codex) were provisioned on the local
  herdr for the run and closed afterwards; no live session was touched.

## Found & fixed

- The inline suggestion panel reserved its full 176pt cap even for a single
  match, leaving a large empty area. Fixed by sizing the panel's scroll
  view to the measured list height, capped at 176pt
  (`Sources/Heeler/Console/AgentComposerView.swift`,
  AgentComposerSkillSuggestions). Re-verified in the Simulator.

## Still open

- The GUI pass did not exercise: unmatched-query/mid-token non-triggering
  (unit-tested), the codex More-menu picker (kind-independent code path),
  the tools-keyboard Skills tab sharing (structural), or VoiceOver.
- The Codex computer-use tester could not drive this screen reliably: its
  screen-coordinate taps landed on the agent-switcher strip below the
  Composer, and one stray long-press trapped its own session's detail view
  in a terminal Select Text overlay. The driver finished the plan with
  device-level HID automation instead. Future rounds on Agent detail
  should steer the tester toward idb-style point coordinates or expect
  driver takeover.
- Environment repair made durable: the `local-ui-test-17pro` Host now
  targets 127.0.0.1:22 with the app's device key enrolled on the Mac;
  preflight is fully green (herdr 0.8.2 / protocol 20).
