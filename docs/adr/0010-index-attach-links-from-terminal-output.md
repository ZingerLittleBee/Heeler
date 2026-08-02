# Index Attach Links from terminal output

Heeler will not make terminal text directly tappable while libghostty lacks
a public iOS point-to-link query. Each Attach instead owns a bounded,
memory-only index of web links observed in its terminal output and presents that
index through native UI. This avoids waiting on a long libghostty development
cycle, synthesizing modifier-clicks into mouse-aware TUIs, or duplicating a
terminal parser to map touch coordinates back to wrapped text.

## Considered Options

- **Add a point-to-link API to libghostty** — the clean long-term solution, but
  rejected for this feature because its delivery is outside the app's control.
- **Probe or activate links through synthetic mouse input** — rejected because
  it depends on undocumented hover behavior and can interfere with TUIs that
  capture the mouse.
- **Parse only the current viewport** — rejected because the exposed viewport
  text does not distinguish a visual soft wrap from a real line break.
- **Index links from terminal output** — chosen. Incremental output preserves a
  complete URL across network chunks, ANSI styling, and terminal soft wrapping;
  viewport text may supplement discovery but is not treated as an exact
  terminal-cell model.

## Consequences

- An Attach Link is an absolute `http` or `https` target found as visible text
  or as an OSC 8 target. Real line breaks are never guessed away. Complex
  cursor movement and overwrite sequences that assemble a URL on screen are
  explicitly best-effort.
- User input echoed by the remote terminal is indistinguishable from other PTY
  output and therefore participates in discovery. Loopback and private-network
  targets are retained literally; the app never rewrites them to a Host
  address.
- One Attach keeps at most 20 distinct targets, ordered by most recent
  occurrence. Exact repeats move to the front. A target larger than 32 KiB is
  ignored rather than truncated.
- The index survives terminal retries, Transport reconnection, and ordinary
  backgrounding while the Attach remains alive. Leaving Attach or terminating
  the app clears it. Nothing is written to persistent storage.
- A toolbar item appears only when the index is non-empty and opens the list.
  Discovery is silent; rows expose the real Host and full URL, open through the
  system default browser, and support explicit copying. Failed opens retain the
  link and offer copying.
- There is no terminal-text tap handling, manual deletion, clear action,
  feature setting, timestamp display, or background notification.
