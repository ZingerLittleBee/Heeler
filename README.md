<div align="center">

<img src="docs/images/logo.png" width="96" alt="Heeler logo" />

# Heeler

**A native iOS companion app for [herdr](https://herdr.dev) — an agent-first terminal runtime.**

[![CI](https://github.com/ZingerLittleBee/Heeler/actions/workflows/ci.yml/badge.svg)](https://github.com/ZingerLittleBee/Heeler/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/ZingerLittleBee/Heeler?style=flat)](https://github.com/ZingerLittleBee/Heeler/stargazers)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![iOS](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![TestFlight](https://img.shields.io/badge/TestFlight-beta-0D96F6?logo=apple&logoColor=white)](https://testflight.apple.com/join/aXSxRn4r)

**[Join the beta on TestFlight](https://testflight.apple.com/join/aXSxRn4r)**

English | [简体中文](./README-zh.md)

</div>

---

Heeler is an **agent console**: a native dashboard of every coding agent running on your machines, sorted by who needs you. Open an Agent to read and steer its live terminal, draft with the full iOS keyboard in a native Composer, and Send the complete message once — all over plain SSH.

## Screenshots

| Agent Console | Composer + tools keyboard | Live terminal |
| --- | --- | --- |
| ![Agent Console on iPhone](docs/images/console-iphone.png) | ![Agent terminal with the tools keyboard on iPhone](docs/images/agent-iphone.png) | ![Agent's live terminal above the Composer on iPhone](docs/images/composer-iphone.png) |

| Terminal | Skills | Live Activity |
| --- | --- | --- |
| ![Plain Terminal with Text and Keys on iPhone](docs/images/terminal-iphone.png) | ![Composer Skills suggestions on iPhone](docs/images/skills-iphone.png) | ![Lock-screen Live Activity tracking Agents on iPhone](docs/images/live-activity-iphone.png) |

## Features

- **Console** — every Agent on every machine in one status-sorted list
  (Blocked first), filterable by Host, updated live.
- **Attach** — the Agent's real terminal rendered by libghostty: native
  scrollback, momentum touch scrolling that also drives full-screen TUIs,
  long-press selection, takeover of a stale terminal owner, and quietly
  collected web links to open later.
- **Composer** — draft locally with the full iOS keyboard (autocorrect, IME,
  dictation), then Send once; the tools keyboard adds Agent control keys,
  Agent Skills, reusable Snippets, and terminal appearance.
- **Terminal** — open a plain shell in the Agent's directory, with Text and
  Keys modes and one reused tab per Workspace.
- **Attachments** — stage a photo or a file up to 64 MiB onto the Host over
  SFTP and insert its path into the draft.
- **QR pairing** — scan a Pairing Code to add a machine; keys are generated
  on device, private keys stay in the Keychain, and the code pins the host
  key fingerprint.
- **Notifications + Live Activities** — end-to-end encrypted pushes when an
  Agent goes Blocked or Done, and a lock-screen / Dynamic Island banner
  tracking Agents in real time; the relay can never read the content
  ([PRIVACY.md](PRIVACY.md)).
- **Worktrees** — start an Agent on a clean checkout of the workspace's repo.
- **Appearance** — System, Light, or Dark; 30 terminal themes with separate
  Light and Dark slots; bundled JetBrains Mono and IBM Plex Mono; pinch to
  zoom.
- **Jump Host** — reach unroutable machines through an SSH jump, with keys
  verified at both hops.

## How it connects

Heeler speaks herdr's JSON API over SSH: each request opens a
direct-streamlocal channel onto `herdr.sock`, one long-lived channel carries
the event stream, and interactive terminals run `herdr agent attach
--takeover` on an SSH PTY. The only prerequisites are SSH access and a
running herdr — no server changes, no extra packages. The SSH server must
allow stream-local forwarding (the OpenSSH default); onboarding calls it out
when it's disabled.

Unroutable machines can sit behind an SSH Jump Host:

- [Set up remote access step by step](docs/guides/vps-jump-host-setup.md)
- [Architecture, security boundaries, and the VPS runbook](docs/guides/vps-jump-host.md)

## Adding a machine

On the machine running herdr (Node >= 20, herdr >= 0.7.5, OpenSSH server on —
macOS: **System Settings > General > Sharing > Remote Login**):

```bash
herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes
herdr plugin action invoke heeler.pair
```

Scan the Pairing Code QR it shows and the machine is added as a Host — the
code carries the addresses, the host key fingerprint, and SSH key enrollment.
The same [plugin](plugin/README.md) delivers the encrypted notifications once
you enable them for the Host in the app.

## Stack

- SwiftUI, iOS 18+, iPhone today (iPad planned)
- The repository-local `Packages/HeelerSSH` (libssh2 + OpenSSL) for SSH
- [libghostty-spm](https://github.com/lakr233/libghostty-spm) for terminal emulation and Metal rendering

See `docs/adr/` for why — the transport story in particular is not obvious.

## Contributing

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
layout, build/test, and conventions.

## Status

Beta, on [TestFlight](https://testflight.apple.com/join/aXSxRn4r). Built for
personal use first and shaped by daily driving, so expect rough edges and
fast iteration. Not affiliated with the herdr project.
