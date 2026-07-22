# herdr-mobile

A native iOS companion app for [herdr](https://herdr.dev) — an agent-first terminal runtime.

herdr-mobile is an **agent console**: a native dashboard of every coding agent running on your machines, sorted by who needs you. Open an Agent to enter its real terminal with the standard iOS input method, a compact terminal control keyboard, native scrollback, and continuous touch scrolling for full-screen TUIs, all over plain SSH.

## How it connects

The app speaks herdr's JSON API (newline-delimited JSON over a Unix socket) through SSH:

- **RPC + events**: a no-PTY SSH exec channel running `socat - UNIX-CONNECT:<herdr.sock>` per request, plus one long-lived channel for `events.subscribe`.
- **Interactive terminal**: the Agent detail screen opens an SSH PTY shell channel bootstrapped with an injection-safe `exec herdr agent attach <pane>` line, then rendered by SwiftTerm with native normal-buffer scrolling and alternate-screen wheel gestures.

No herdr server changes required. The only remote prerequisite is `socat` installed on the host.

## Stack

- SwiftUI, iOS 26+, iPhone + iPad
- [Citadel](https://github.com/orlandos-nl/Citadel) for SSH
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal rendering

See `docs/adr/` for why these choices were made (the transport story in particular is not obvious).

## Status

Pre-alpha. Personal-use first; not affiliated with the herdr project.
