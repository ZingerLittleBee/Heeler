---
status: accepted
---

# Live terminal output with a local Composer

Agent detail displays the live Attach PTY through libghostty and keeps the
native Composer introduced by ADR 0012. The terminal is a display surface:
incoming PTY bytes, scrollback, links, theme, font settings, and grid resize
remain active. Touch scrolling continues to send semantic wheel input when an
alternate-screen TUI requests it, but keyboard, paste, snippet, pointer-click,
and other authored input do not reach the PTY. While an input surface is
visible, Composer can switch between the iOS keyboard and a tabbed tools
keyboard. Its explicit Agent controls send Esc, Tab, Shift-Tab, arrows, Enter,
and Backspace directly to the PTY; its Snippet and Skill panes edit the local
draft. The iOS keyboard remains entirely system-owned, including its native
candidate and paste area. The tools keyboard reuses that complete measured
footprint, including the Home Indicator area.
Both modes are the Composer text view's UIKit input views: `reloadInputViews()`
replaces them while the same text view remains first responder. Neither mode
therefore dismisses the keyboard, moves Composer, or asks Ghostty to resize its
grid. Send still delivers the complete draft through one `agent.prompt`
request.

This supersedes ADR 0012's non-realtime Monitor and separate interactive
Attach destination. The snapshot renderer, polling cadence, and locally
stitched history are removed. Git history retains that implementation and its
rationale.

## Rationale

The Agent TUI is the authoritative presentation of its output. libghostty
preserves its layout, alternate-screen behavior, colors, scrollback, and
resize semantics more faithfully than reconstructing a conversation from
bounded `agent.read` snapshots. Keeping composition outside the terminal still
avoids remote echo latency while drafting and retains explicit one-request
delivery.

## Consequences

- Opening Agent detail holds one live PTY Attach channel until the screen
  leaves, and reconnect recovery continues to replace the full terminal
  pipeline after a possible suspension.
- The TUI's own prompt remains visible because the renderer no longer removes
  terminal rows. It is presentation only; the native Composer is the sole
  input control.
- Terminal size changes continue to resize the remote PTY, including changes
  caused by the Composer and software keyboard.
- Features whose only insertion path was direct terminal input are not exposed
  on this surface until they can insert into Composer instead.
