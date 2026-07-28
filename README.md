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
loopback interface instead of publishing the Mac's SSH port.

- [Set up remote access step by step](docs/guides/vps-jump-host-setup.md)
- [Automate additional desktop-client enrollment](docs/guides/vps-jump-host-setup.md#automate-additional-desktop-clients)
- [Understand the architecture, security boundaries, and VPS migration runbook](docs/guides/vps-jump-host.md)

## Adding a machine: install the plugin, scan the code

The repo ships a [herdr plugin](plugin/README.md) that pairs the app with a
machine by QR code and delivers Agent Notifications over APNs. On the machine
running herdr (Node >= 20, herdr >= 0.7.5, OpenSSH server enabled — on macOS
that is **System Settings > General > Sharing > Remote Login**):

```bash
herdr plugin install ZingerLittleBee/herdr-mobile/plugin --ref main --yes
herdr plugin action invoke herdr-mobile.pairing.pair
```

The `pair` action opens a popup with a Pairing Code QR; scan it with the app
and the machine is added as a Host — addresses, host key fingerprint, and SSH
key enrollment are all handled by the code, nothing to type. The same plugin
pushes encrypted Blocked/Done notifications to the app once you enable Agent
Notifications for the Host in the app's settings; the relay only ever sees
ciphertext (see [PRIVACY.md](PRIVACY.md)).

## Stack

- SwiftUI, iOS 26+, iPhone + iPad
- [Citadel](https://github.com/orlandos-nl/Citadel) for SSH
- [libghostty-spm](https://github.com/lakr233/libghostty-spm) for terminal emulation and Metal rendering

See `docs/adr/` for why these choices were made (the transport story in particular is not obvious).

## Status

Pre-alpha. Personal-use first; not affiliated with the herdr project.
