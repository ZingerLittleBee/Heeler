# herdr-mobile

A native iOS companion app for [herdr](https://herdr.dev) — an agent-first terminal runtime.

herdr-mobile is an **agent console**: a native dashboard of every coding agent running on your machines, sorted by who needs you. Open an Agent to enter its real terminal with the standard iOS input method, a compact terminal control keyboard, native scrollback, and continuous touch scrolling for full-screen TUIs, all over plain SSH.

## How it connects

The app speaks herdr's JSON API (newline-delimited JSON over a Unix socket) through SSH:

- **RPC + events**: a no-PTY SSH exec channel running `socat - UNIX-CONNECT:<herdr.sock>` per request, plus one long-lived channel for `events.subscribe`.
- **Interactive terminal**: the Agent detail screen opens an SSH PTY shell channel bootstrapped with an injection-safe `exec herdr agent attach <pane>` line, then renders it through a host-managed libghostty-spm session with Metal output, persistent appearance-aware themes, input-row keyboard activation, IME input, long-press text selection, and app-routed touch scrolling for both local scrollback and remote TUIs.

No herdr server changes required. The only remote prerequisite is `socat` installed on the host; the app finds it via the Host's configured path or the Host's own PATH, and onboarding tells you where to point it if neither answers.

Hosts that are not directly reachable can be placed behind an SSH Jump Host.
The recommended deployment keeps the reverse-forwarded port on the VPS
loopback interface instead of publishing the Mac's SSH port. See
[VPS Jump Host and reverse-tunnel deployment](docs/guides/vps-jump-host.md)
for the architecture, hardening rules, setup procedure, and VPS migration
runbook.

## Stack

- SwiftUI, iOS 26+, iPhone + iPad
- [Citadel](https://github.com/orlandos-nl/Citadel) for SSH
- [libghostty-spm](https://github.com/lakr233/libghostty-spm) for terminal emulation and Metal rendering

See `docs/adr/` for why these choices were made (the transport story in particular is not obvious).

## Status

Pre-alpha. Personal-use first; not affiliated with the herdr project.
