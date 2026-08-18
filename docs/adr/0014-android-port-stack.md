# 14. Android port: native Kotlin/Compose with a Zig ghostty-vt + libssh2 substrate

Date: 2026-08-17

## Status

Accepted

## Context

ADR 0001 chose a native Swift stack and accepted dropping Android, naming
Flutter as the fallback if Android ever became required. It has: we want a
full-parity Android companion. Since ADR 0001, two facts changed the option
space. First, the app's hard problems are now well understood and mostly
platform-neutral: the herdr wire protocol and its load-bearing behavioral
facts, the Transport abstraction, snapshot-plus-events sync, the pairing and
notification-envelope formats (pinned by shared test vectors in
`plugin/test-vectors/`). Second, [chuchu](https://github.com/jossephus/chuchu)
(MIT) demonstrated at commit `73dfe07` that ghostty's `ghostty-vt` Zig module
cross-compiles to all four Android ABIs behind a Zig JNI bridge, with a
Compose-side renderer and a veto-able input path — on iOS, terminal fidelity
was the decision that superseded two earlier designs (ADRs 0004, 0012, 0013).

Forking chuchu itself was considered and rejected after a source audit: its
SSH JNI layer holds exactly one channel per session and supports neither
`direct-streamlocal` channels (our entire transport, ADR 0011) nor jump hosts
nor exit statuses; private keys live as plaintext Room columns; and its app
layer is an SSH client, not an agent console.

## Decision

- **Native Kotlin + Jetpack Compose**, in this repository under `android/`,
  sharing the schema snapshot, wire-type generator, and test vectors with the
  iOS app. Flutter is rejected: the terminal surface and SSH stack would be
  native-bridged anyway, leaving Flutter only the screens — the layer Compose
  does better with less indirection.
- **Terminal**: ghostty-vt via a Zig JNI bridge (`android/native/`), adapting
  chuchu's snapshot-bridge design with attribution (`android/native/NOTICE.md`).
  Ghostty owns VT state, scrollback, and selection; Kotlin owns glyph drawing,
  IME, and input policy — which keeps Attach display-only per ADR 0013.
- **SSH**: a fresh, thin, nonblocking libssh2 JNI surface
  (`NativeSsh.kt` ⇄ `heeler_ssh.zig`) with channel-registry semantics,
  `direct-streamlocal`, exec ± PTY, and SFTP; the connection lifecycle,
  channel admission, and retry policy live in Kotlin, porting `HeelerSSH`'s
  proven design rather than chuchu's. libssh2/OpenSSL/ghostty are pinned by
  content hash in `android/native/build.zig.zon`, mirroring the repo's
  exact-pinning convention.
- **Keys**: Android Keystore-backed storage; private key material is passed
  to libssh2 from memory only, never persisted in plaintext.
- **Push**: the notification envelope is provider-neutral and unchanged; the
  registration file and Push Relay gain an additive provider discriminator so
  FCM tokens coexist with APNs tokens.

## Consequences

- Android becomes the third consumer of `plugin/test-vectors/`; vector changes
  now touch Node, Swift, and Kotlin in lockstep.
- The Zig toolchain (0.15.2, matching the ghostty pin) joins the build
  prerequisites for Android native builds; CI builds the `.so` before Gradle.
- chuchu is a reference and substrate donor, not a dependency: nothing tracks
  its upstream, and adapted code is reviewed and owned here.
- The herdr facts in `AGENTS.md` govern both clients; behavioral discoveries
  on either platform must land there, not in platform code comments.
