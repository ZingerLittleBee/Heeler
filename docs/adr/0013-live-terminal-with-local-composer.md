---
status: accepted
---

# Live terminal output with a local Composer

Agent detail displays the live Attach PTY through libghostty and keeps the
native Composer introduced by ADR 0012. The terminal is a display surface:
incoming PTY bytes, scrollback, links, theme, font settings, and grid resize
remain active. Touch scrolling continues to send semantic wheel input when an
alternate-screen TUI requests it, but keyboard, paste, snippet, pointer-click,
and other authored input do not reach the PTY. Send delivers the complete
Composer draft through one `agent.prompt` request.

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
