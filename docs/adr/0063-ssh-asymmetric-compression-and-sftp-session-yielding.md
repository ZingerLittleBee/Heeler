---
status: accepted
---

# Asymmetric inbound SSH compression and SFTP session yielding

Heeler multiplexes interactive terminals, event streams, git probes, and SFTP
transcript/file reads over a single `LIBSSH2_SESSION` per Host
([ADR 0011](0011-libssh2-direct-streamlocal-transport.md)). On high-RTT WAN links
(200–300 ms), two design limits in the transport layer compounded into seconds
of interactive lag and megabytes of redundant traffic:

1. **Uncompressed Host-to-App payloads.** JSONL transcripts, git patches, and
   tmux ANSI screen captures are highly compressible text, yet libssh2 was built
   with `-DENABLE_ZLIB_COMPRESSION=OFF` and negotiated `none` in both
   directions.
2. **SFTP head-of-line blocking and cancellation desync.** While `libssh2`
   waited on `EAGAIN` during SFTP metadata or range-read calls, `SessionDriver`
   held the single operation mutex across full WAN round trips, stalling
   concurrent PTY reads/writes behind background Chat prefetch. Worse,
   cancelling an SFTP `stat`/`open` call mid-flight returned immediately while
   the server's SFTP reply was still in transit; the next caller on the shared
   `LIBSSH2_SFTP` handle could receive the orphaned packet's response
   (reproduced 5/5 times against a remote Linux VM).

## Decision

- **Enable delayed post-auth compression Host-to-App only (`zlib@openssh.com`).**
  `Packages/HeelerSSH` links the system `libz` (`-DENABLE_ZLIB_COMPRESSION=ON`)
  and sets `LIBSSH2_METHOD_COMP_CS = "none"` and
  `LIBSSH2_METHOD_COMP_SC = "zlib@openssh.com,none"` with
  `LIBSSH2_FLAG_COMPRESS = 1`. Delayed compression activates only after
  `SSH_MSG_USERAUTH_SUCCESS`, avoiding pre-auth attack surface and credential
  length oracles. Keeping Client-to-Host uncompressed avoids CRIME/BREACH-style
  keystroke oracles and avoids wasting CPU re-compressing uploaded photos and
  videos. Jump Host outer hops pass `compressInbound: false` so inner encrypted
  SSH ciphertext is never fed through zlib.
- **Patch upstream libssh2's asymmetric decompression check.** Pinned libssh2
  (`c755785`) checked `session->local.comp` (CS) instead of
  `session->remote.comp` (SC) in `src/transport.c:312-315` before calling
  `session->remote.comp->decomp(...)`, which silently skipped inflation whenever
  `COMP_CS = "none"` and `COMP_SC = "zlib@openssh.com"`. The 3-line fix lives in
  `Packages/HeelerSSH/Patches/libssh2-remote-decomp-check.patch`, is applied by
  `Packages/HeelerSSH/Scripts/build-native.sh`, and is recorded in
  `Artifacts/PROVENANCE.md`. Drop the patch when bumping to an upstream libssh2
  commit that fixes `src/transport.c`.
- **Yield the operation mutex during SFTP waits and prioritize interactive PTY
  turns.** `SessionDriver` serializes SFTP operations on the shared handle with
  its SFTP gate while releasing the session operation mutex during `EAGAIN`
  waits (`waitForSessionYielding`), except during `libssh2_sftp_init` (which
  opens the SFTP subsystem channel and remains bound by the channel-open rule).
  Interactive `readPTY` and `writePTY` turns acquire the operation mutex with
  `.interactive` priority ahead of queued normal operations, eliminating mutex
  contention behind concurrent SFTP reads while preserving transport-send owner
  safety.
- **Drain or retire cancelled in-flight SFTP requests.** When a Swift task is
  cancelled while an SFTP metadata/open/read call is awaiting the server's reply,
  `SessionDriver` performs a bounded non-cancellable drain (up to 2 seconds) to
  consume the in-flight response before releasing the SFTP gate. If the drain
  budget expires, `retireDesyncedSFTPClient` closes and discards the shared SFTP
  client so the next caller opens a clean handle rather than reading a shifted
  reply.
- **Enable `TCP_NODELAY` and `SO_NOSIGPIPE` on SSH sockets.** `SocketConnector`
  disables Nagle's algorithm so small interactive keystrokes, SFTP requests, and
  control commands leave immediately without delayed-ACK stalls.
- **Avoid redundant SFTP metadata round trips.** `readSFTPFileRange` opens the
  file directly without a pre-open path `STAT` and calls `FSTAT` only when the
  read did not reach `FX_EOF` (or returned empty), keeping the read buffer
  bounded to `wanted / 4` (capped at 256 KiB) so range reads never over-read
  remote files.

## Considered options

- **Symmetric `zlib@openssh.com` in both directions.** Would have bypassed the
  upstream `libssh2` bug without patching `src/transport.c`, but compresses
  interactive client keystrokes and already-compressed image/video uploads,
  adding CPU overhead on the device and unnecessary side-channel exposure.
- **Opening a second SSH connection for SFTP.** Would isolate PTY traffic from
  SFTP at the TCP level, at the cost of doubling SSH handshakes, server session
  slots (`MaxSessions` / `MaxStartups`), route leases, and reconnect state.
  Yielding the operation mutex plus interactive PTY priority eliminated mutex
  waits (20 → 0) on the existing connection without a second dial.
- **Disabling shared SFTP client reuse (init/shutdown per call).** Would prevent
  cancellation desyncs trivially, but adds an `openSFTP` + `closeSFTP` round
  trip (~400–600 ms on WAN) to every Chat poll and file read. Bounded drain with
  retire-on-expiry keeps steady-state idle polls at a single RTT.
