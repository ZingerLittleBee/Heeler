# herdr-mobile

A native iOS companion app for [herdr](https://herdr.dev) — an agent-first terminal runtime.

Instead of squeezing a desktop TUI onto a phone, herdr-mobile is an **agent console**: a native dashboard of every coding agent running on your machines, sorted by who needs you. Glance at statuses, read output, reply to a blocked agent, or drop into a real terminal when you need to — all over plain SSH.

## How it connects

The app speaks herdr's JSON API (newline-delimited JSON over a Unix socket) through SSH:

- **RPC + events**: a no-PTY SSH exec channel running `socat - UNIX-CONNECT:<herdr.sock>` per request, plus one long-lived channel for `events.subscribe`.
- **Interactive terminal**: an SSH exec channel with a PTY running `herdr agent attach <pane>`, rendered by SwiftTerm.

No herdr server changes required. The only remote prerequisite is `socat` installed on the host.

## Stack

- SwiftUI, iOS 18+, iPhone + iPad
- [Citadel](https://github.com/orlandos-nl/Citadel) for SSH
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal rendering

See `docs/adr/` for why these choices were made (the transport story in particular is not obvious).

## Status

Pre-alpha. Personal-use first; not affiliated with the herdr project.
