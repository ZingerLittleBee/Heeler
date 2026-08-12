# Native Swift stack (SwiftUI + Citadel + SwiftTerm), iOS-only

Status: Partially superseded by ADR 0004 and ADR 0011. The native Swift choice
remains active; libghostty-spm replaced SwiftTerm as the terminal engine, and
the repository-local HeelerSSH package (libssh2) replaced Citadel for SSH.

Distribution update (2026-08-13): current App Store builds target iPhone only.
The original native-stack decision below included iPad, and the adaptive layout
code remains available if iPad distribution is restored later.

We build natively in Swift for iOS 18+ (iPhone + iPad) with Citadel for SSH and SwiftTerm for terminal rendering, and accept dropping Android. The embedded terminal is a core UX surface, and SwiftTerm is the most mature mobile terminal component in any ecosystem, while the alternatives' terminal stories are structurally weaker.

## Considered Options

- **Flutter (dartssh2 + xterm.dart)** — the strongest alternative, fully validated: dartssh2 is pure Dart, very active, and since v2.14.0 even supports `direct-streamlocal@openssh.com` natively (`forwardLocalUnix`), which Swift libraries cannot do. Rejected because Android was demoted to non-essential and xterm.dart is the weak board (no stable release since 2024-02, ~96 open issues, unproven IME handling). **This is the designated Plan B if Android ever becomes a requirement.**
- **React Native** — rejected: no maintained SSH library (only a 5-star unverified NMSSH wrapper or a DIY pure-JS stack), and the only terminal option is WebView + xterm.js, a structural disadvantage for streaming PTY bytes.

## Consequences

- Citadel 0.12.1 pulls swift-nio-ssh from a third-party fork (`Wellz26/swift-nio-ssh`), not Apple's repo. Pin versions and review dependency updates.
- Core Citadel APIs were compile-verified (Swift 6.3.3): interactive bidirectional `withExec`, `withPTY` + `changeSize`, CryptoKit Ed25519 auth, custom host-key validator, reconnect modes. Known gaps, all minor: OpenSSH private-key import parser is internal (extract raw bytes manually), no keyboard-interactive (custom delegate), no built-in keepalive ping (send SSH ignore periodically).
