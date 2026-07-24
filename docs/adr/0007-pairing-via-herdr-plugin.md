# Pair new devices through a herdr plugin with a one-time Bootstrap Key

New-device onboarding previously required carrying the Device Key's public half to the server out of band, plus manual Host entry and a TOFU fingerprint prompt. herdr is a third-party project, so the server side cannot live in herdr core; its plugin system (`herdr plugin install owner/repo/subdir`, unsandboxed, full CLI access) is the extension surface we control. We decided Pairing is the primary onboarding path: a herdr plugin renders a Pairing Code in a herdr popup pane, the app scans it, connects with the embedded Bootstrap Key, performs Enrollment through a forced command, then reconnects with the Device Key. The Host is persisted only after the full ceremony succeeds.

Decisions fixed during design:

- **Plugin**: Node ≥ 20 (`node:crypto` exports the raw Ed25519 seed; `qrcode` renders without system dependencies; `npm ci` build), living in this repo under `plugin/`. Developed via `herdr plugin link`; publishing requires this repo to become public first.
- **Pairing Code payload**: minimal and versioned — user-selected candidate addresses (enumerated, likely ones pre-checked), port, username, host key fingerprint, Bootstrap Key seed, expiry. No herdr session data; session discovery stays in preflight.
- **Bootstrap Key**: single-use, 2-minute TTL, `restrict,command=` line pointing at the plugin's accept script; deleted on success, expiry, or stale-line sweep. Enrollment is fully automatic — no human confirmation on the computer — with the enrolled fingerprint displayed afterward and a one-key revoke as the compensating control.
- **App**: scanning is the primary action when adding a Host; the manual form and copy-paste `authorized_keys` line remain the fallback. Pairing uses a dedicated one-shot client beside `SSHTransport`, which keeps its socat/herdr semantics.
- **Testing**: real-sshd e2e on both ends (the app exercises the actual accept script as a forced command) plus shared protocol test vectors consumed by both the Node and Swift implementations.

## Considered Options

- **Add pairing to herdr core** — not ours to change; the plugin API is the supported surface and needs no herdr modifications.
- **Standalone server script** — rejected because distributing the script is itself an out-of-band step, which defeats the feature's purpose; `herdr plugin install` is one command.
- **In-app ssh-copy-id over password auth** — dropped: it depends on `PasswordAuthentication yes`, which hardened developer servers commonly disable. May return if password users show up.
- **Config-only QR without a Bootstrap Key** — subsumed: it is this payload minus the seed, not a separate feature.
- **Staged confirmation or numeric-comparison pairing** — rejected for ceremony cost; the accepted residual risk is a same-room attacker photographing the QR and racing the user inside the TTL.

## Consequences

- A private key rides inside a QR code on purpose. Its blast radius is bounded by `restrict`, the forced command, single use, and the 2-minute TTL — not by secrecy of the screen.
- The pairing envelope is a cross-implementation protocol; changes require a version bump honored by both the plugin and the app.
- Reachability is scoped to same-LAN or same-VPN (Tailscale interfaces enumerate like any other); cellular-only phones are explicitly unsupported, and failure copy must say which Pairing step failed.
- The plugin pins `min_herdr_version`; herdr plugin API changes become an upgrade dependency for onboarding.
