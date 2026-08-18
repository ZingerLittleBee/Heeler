# Third-party notices — android/native

- The Zig/Android build orchestration (`src/ndk.zig`, `src/vendor/libssh2/`) and the
  ghostty-vt snapshot-bridge design in `src/bridge/` are adapted from
  [chuchu](https://github.com/jossephus/chuchu) (MIT License, Copyright (c) jossephus),
  at commit `73dfe07d40b6634d8a5ac4ff442d4687ce8361d8`.
- `src/bridge/heeler_terminal.zig` and the Android terminal renderer/input
  sources are adapted from chuchu's `chuchu_snapshot.zig`,
  `TerminalSnapshot.kt`, `TerminalCanvas.kt`, `TerminalSelection.kt`, and
  `TerminalInputView.kt` at that commit.
- [ghostty](https://github.com/ghostty-org/ghostty) (`ghostty-vt` module) — MIT License.
- [libssh2](https://libssh2.org) — BSD-3-Clause. Fetched by content hash at build time.
- [OpenSSL](https://openssl.org) 3.x via [openssl-zig](https://github.com/jossephus/openssl-zig) — Apache-2.0.
- [zigimg](https://github.com/zigimg/zigimg) — MIT License.
