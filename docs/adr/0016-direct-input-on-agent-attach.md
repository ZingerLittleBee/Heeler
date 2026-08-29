---
status: accepted
---

# Direct Input: opt-in system keyboard on Agent Attach

Agent detail gains an explicit, app-wide **Direct Input** preference (#251),
default off. Composer remains the default authored-input path from ADR 0013.
When Direct Input is on, Agent detail hides the Composer card, preserves the
`AgentComposerStore` draft unchanged, enables Ghostty local input, and routes
the system keyboard into the live Agent Attach PTY. A compact app-owned
shortcut row (Esc, Tab, Shift-Tab, Enter) sits above the Agent switcher strip
as ordinary content — never as `inputAccessoryView`. Show Composer restores the
card immediately. Mode changes disable animation, never Send, insert, or clear
the draft, and do not force Composer when Agent Status is Blocked.

## Rationale

ADR 0013 keeps Attach display-only because the Agent TUI draws its own input
box and because drafting locally avoids remote-echo latency for prompt-sized
text. On a compact phone that Composer card plus the tools keyboard still
occludes most of the TUI, and the tools pad only offers Esc/Tab/Enter by
*replacing* the Apple keyboard. Issue 251 asks for the opposite arrangement:
Apple keyboard as terminal input, with those shortcuts available at the same
time.

ADR 0015 already scoped direct keyboard input to ordinary shells (Shell
Terminal). Reusing Shell Terminal for an Agent would attach a different herdr
tab, drop Agent switcher and notification semantics, and leave the Agent TUI.
Direct Input is therefore a second, Agent-detail-scoped exception: same Attach
PTY, same Agent chrome, optional presentation mode.

Composer stays default because Direct Input reintroduces the dual-prompt
collision ADR 0012/0013 rejected and uses PTY CR for Return rather than
`agent.prompt`. Making it opt-in keeps that surprise behind an explicit Hide
Composer / Keyboard control.

## Consequences

- ADR 0013 remains the accepted default architecture. This ADR records the
  intentional exception; it does not rewrite 0013's Composer-default story.
- Mode preference is app-wide `UserDefaults`, never auto-enabled by size class.
- Skills, Snippets, and Add remain Composer-owned: reaching them from Direct
  Input restores Composer before inserting into the draft.
- Paste review rides the existing Attach path once local input is enabled.
- Keyboard handoff across Agent switch and terminal pipeline replacement
  claims Ghostty in Direct Input the way Composer claims the draft field.
- Blocked status does not force Composer; Esc/Enter operate the Agent TUI.
- Glossary gains **Direct Input**. Attach is display-only in Composer mode;
  Direct Input is the named exception. Avoid Keys mode, terminal mode, and
  unqualified Attach for this surface.
