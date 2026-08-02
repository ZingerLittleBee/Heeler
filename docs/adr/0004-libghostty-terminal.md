# Replace SwiftTerm with libghostty-spm

We use the `GhosttyTerminal` product from libghostty-spm for the interactive
Agent terminal. The app supplies an `InMemoryTerminalSession`: incoming SSH PTY
bytes enter through `receive(_:)`, while Ghostty's write and resize callbacks
feed the existing Attach transport. The transport layer remains independent of
the terminal engine.

libghostty-spm owns terminal parsing, Metal rendering, CoreText font handling,
IME integration, and scrollback storage. herdr-mobile continues to own its
two-mode keyboard UI, touch-scroll routing, URL policy, Attach lifecycle, and
the native text-selection presentation requested by Ghostty's iOS delegate.

## Considered Options

- **Keep SwiftTerm** — rejected. It required app-owned gesture translation for
  alternate-screen TUIs and did not provide the rendering and selection path we
  want to build on long term.
- **Embed official libghostty directly** — rejected. The C API supplies the
  terminal engine, not a complete UIKit surface. Owning the Metal renderer,
  CoreText integration, IME bridge, and touch input layer would duplicate the
  work already maintained by libghostty-spm.
- **Use libghostty-spm** — chosen. Its UIKit `UITerminalView` and
  `InMemoryTerminalSession` match the app's host-managed SSH PTY boundary, so
  the migration does not leak Ghostty into transport or domain code.

## Consequences

- libghostty-spm is an unofficial wrapper and distributes libghostty as a
  prebuilt XCFramework. Pin its exact version, retain SwiftPM's checksum
  verification, and review supply-chain changes before every update.
- libghostty's embedding API is still evolving. Keep all package-specific code
  behind `HeelerTerminalView` and the terminal selection presenter.
- The custom control keyboard sends raw terminal sequences. A small incremental
  DEC cursor-mode tracker preserves application-cursor sequences because the
  wrapper does not expose its internal synthetic-key path publicly.
- Long-press selection is intentionally presented in a native selectable text
  sheet. The wrapper supplies a viewport snapshot and anchor range; it does not
  present selection handles on behalf of the host app.
- libghostty-spm normally makes every direct terminal touch request first
  responder status. herdr-mobile instead gates first-responder eligibility on
  taps within the current IME cursor row. The full-width target is at least 44
  points tall, while pans and long presses remain dedicated to scrolling and
  selection.
- libghostty-spm 1.3.2's internal iOS touch-scroll path does not emit remote TUI
  wheel input through an in-memory session, and its mouse-scroll API is not
  public. The adapter therefore owns one vertical Pan gesture: normal-buffer
  drags invoke Ghostty scrollback actions, while tracked alternate-screen drags
  encode SGR or legacy terminal wheel events through the session's public input
  seam. DEC private-mode tracking is incremental so split SSH packets remain
  correct.
- Terminal zoom is app state, not surface state. The package's own pinch
  handler mutates the surface font size through a private counter the host app
  cannot read, so `HeelerTerminalView` disables that gesture and owns pinch and
  ⌘+/⌘- itself, routing every change through `TerminalController`'s per-session
  configuration. That keeps one persisted app-wide size, applies it to open and
  future Attach terminals alike, and lets Ghostty's cell-size callback resize
  the remote PTY as usual.
- Theme selection uses the package's `GhosttyTheme` catalog but exposes only a
  small curated set. The persisted selection resolves to a light/dark
  `TerminalTheme`; `TerminalController.setTheme` updates existing Attach
  surfaces and the settings preview without rebuilding their in-memory session.
- Xcode may retain an empty binary-artifact directory after an interrupted
  first download. Resolving packages with fresh DerivedData repairs that cache
  state without changing the pinned dependency.
