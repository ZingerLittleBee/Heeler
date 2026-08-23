# HeelerSSH

`HeelerSSH` is Heeler's repository-local Swift package for the native SSH
implementation accepted in ADR 0011. The package owns libssh2 and OpenSSL so
the app target consumes only the `HeelerSSH` product and never imports native
modules or owns native pointers directly.

The checked-in XCFrameworks are the normal build input. Rebuilding them is a
dependency-maintenance operation, not part of ordinary app or CI builds.

## Audit and rebuild

`Sources.lock` records the exact upstream release archives, tags, commits, and
SHA-256 hashes. `Scripts/build-native.sh` verifies both archives before
extracting or compiling them. A mismatch is fatal.

Run the complete rebuild from the repository root:

```sh
HEELER_SSH_XCFRAMEWORK_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" \
    make ssh-artifacts
```

The command builds Release arm64 slices for iPhoneOS and iPhone Simulator,
creates both XCFrameworks, refreshes licenses and provenance, writes file-level
SHA-256 checksums, signs the OpenSSL XCFramework, and verifies the result. Use
an Apple Development or Apple Distribution identity belonging to team
`9VM4RM39R3`. Exact byte-for-byte output requires the Xcode, SDK, compiler, and
configuration recorded in `Artifacts/PROVENANCE.md`; the signature and its
checksum also change when the signing timestamp changes.

To verify the committed artifacts without downloading or compiling sources:

```sh
make verify-ssh-artifacts
```

OpenSSL is built without its legacy provider and without the legacy algorithms
listed in the provenance record. libssh2 is compiled with its obsolete cipher
and signature switches disabled; the small reviewed patch in `Patches/`
removes SHA-1 key exchange and MAC methods that libssh2 1.11.1 otherwise has no
build switch for.

## Session scheduling

`SessionDriver` owns one `LIBSSH2_SESSION` and serializes every call into it
behind one operation mutex. What may release that mutex mid-operation is fixed
by where libssh2 keeps its non-blocking continuation state, so re-check this
section against `Sources.lock` whenever libssh2 is bumped.

In 1.11.1 an unfinished channel open is **session** state: `open_state`,
`open_channel`, `open_packet`, `open_data` and `open_packet_requirev_state`
drive `_libssh2_channel_open`, and `direct_state` with `direct_message` drives
both `channel_direct_tcpip` and `channel_direct_streamlocal` — one state
machine for the two, despite the declaring comment naming only the first. All
of them are fields of `LIBSSH2_SESSION` in
`src/libssh2_priv.h`. `_libssh2_channel_open` only builds its request while
`open_state` is idle, so a second open entered during another's `EAGAIN`
resumes the first state machine and hands the first call's channel to the
second caller. Channel opens must not interleave.

Waiting for that serialized open slot is not itself an open attempt. A task
cancelled or timed out while queued has no uncertain native channel state, so
it leaves the connection reusable; once its own open call has started, the
existing whole-session invalidation rule still applies to an interrupted open.

Most of what follows open is **channel** state — `process_state`, `read_state`,
`write_state`, `close_state`, `wait_eof_state`, `wait_closed_state`,
`free_state` and `reqPTY_state` all live on `LIBSSH2_CHANNEL` — which is why
the PTY and long-lived stream-local paths can take one short turn per call.
Any operation that means to release the mutex between turns has to re-resolve
its channel by id from a driver registry afterwards: invalidation frees the
session, `libssh2_session_free` destroys every channel attached to it, and a
pointer captured before the release would dangle.

Sending is the exception, and it cuts across every channel. The pending
outbound packet is **session** state: `odata`, `olen`, `osent` and `ototal_num`
on `struct transportpacket` (`src/libssh2_priv.h`), reached through
`session->packet`. `_libssh2_transport_send` records them whenever a send could
not flush the whole packet — including when it sent nothing — and
`send_existing` refuses any retry whose `data` pointer or length differs, with
the comment "Address is different, returning EAGAIN" (`src/transport.c`). It
returns `EAGAIN` without advancing the packet, so a foreign producer can never
drain it.

The consequence is a livelock, not a slowdown. `_libssh2_channel_write` sends
from the channel's own `write_packet` buffer, so the owning channel can resume
across a mutex release; anyone else cannot. If a caller holds the operation
mutex across its own `EAGAIN` loop while another channel owns a pending packet,
it spins until its deadline and the owner never gets a turn. Channel open is
such a caller. Any call that loops on `EAGAIN` while holding the mutex must
therefore first establish that no other operation is the transport-send owner;
`libssh2_session_block_directions` reporting an outbound block after a
packet-producing `EAGAIN` is the public signal for it, and `send_existing` runs
before `_libssh2_transport_send` clears that bit, so the report is conservative
rather than falsely clear.

Only two things end that ownership: the **exact** owning call returning a
non-`EAGAIN` result after outbound state is clear, or completed whole-session
invalidation, which frees
`session->packet` along with the session. A cancelled or timed-out Swift task
is not one of them — the native packet outlives it. `_libssh2_channel_write`
leaves `write_state` at `libssh2_NB_state_created` on `EAGAIN`, so re-calling
`libssh2_channel_write_ex` on the same channel resends the same
`write_packet`/`write_packet_len` and is the only call that can drain it;
`send_existing` sanity-checks `data` and `data_len` alone and never the payload,
so a caller that resumes with a different payload buffer gets no diagnostic.
Before #130, `writePTY` and `writeStreamLocal` threw directly out of their wait,
so cancellation could strand a packet for the rest of the session's life.
Cleanup now drives the exact owning call non-cancellably to a non-`EAGAIN`
result within its reclamation budget, and invalidates the session if that
budget expires. A negative non-`EAGAIN` result while libssh2 still reports
outbound state also invalidates: clearing the owner in that state would admit
a foreign producer while the native packet may still be pending.

Channel teardown has its own resource transition. As soon as PTY or
direct-streamlocal close begins, the registry entry stops accepting reads,
writes, and resizes. Cleanup may still re-resolve that entry across yielded
turns, but user I/O cannot interleave with close/free on the same native
channel.

SFTP is a second exception and a stronger one. `struct _LIBSSH2_SFTP`
(`src/sftp.h`) carries one continuation slot per operation kind —
`mkdir_state`/`mkdir_packet`/`mkdir_request_id`, `stat_*`, `unlink_*`,
`rename_*`, `fstat_*` and the rest — plus one shared inbound parser
(`packet_state`, `partial_packet`, `partial_len`, `partial_received`). A second
call of the same kind resumes the first call's state instead of starting its
own, so it can combine one request's packet with another's length or deliver
one call's result into another's output buffer. Re-resolving the handle by id
does not isolate this, because the id resolves to the same shared state. Every
call on one SFTP handle stays mutually exclusive for its whole logical
operation, waits included, and `libssh2_sftp_init` stays serialized on its own
session-owned `open_state`.

Waits are released session-wide rather than per channel. libssh2 buffers what
it decrypts, so an operation reading its own channel consumes the packets the
others are blocked on and the socket keeps no edge to report; `SessionActivity`
therefore counts receives and wakes every wait armed before the last one. The
number of wakeups per inbound packet grows with the number of channels parked
at once, so turn bodies stay small.

## Test lanes

`make test` runs the app suites and then `scripts/run-heelerssh-package-tests.sh`
for this package's own suites, including `SessionDriverE2ETests`. The local
package runner asserts only that something executed, not an exact count, so
machines without the disposable sshd fixture can skip the E2E suite cleanly.

The E2E integration package must update `scripts/run-ci-ios-tests.sh` before
merge so its package lane expects **42** executed tests and pins these new
display names exactly:

- `outbound backpressure does not livelock a channel open`
- `cancelling a transport-send owner drains`
- `cancelling a transport-send owner invalidates`
- `timing out a transport-send owner at loop-top drains`
- `timing out a transport-send owner at loop-top invalidates`
- `one-shot RPCs yield so a live PTY can progress`
- `cancelling a yielded one-shot distinguishes cleanup outcomes`
- `timing out a yielded one-shot distinguishes cleanup outcomes`
- `invalidation during a yielding wait does not touch a stale native pointer`
- `yielded channel teardown rejects same-id I/O`
- `repeated invalidation reclaims every file descriptor`
- `measurement: Attach throughput with concurrent RPCs`
- `SFTP operations and close wait out an in-flight handle use`
- `a serialized channel-open wait honors deadline and cancellation`
- `an invalidation generation rejects a watch armed before it`
- `a transport-send owner error with outbound pending invalidates`

This core package intentionally does not edit that integration script.

## Direct-streamlocal acceptance

`scripts/run-ci-ios-tests.sh` provisions disposable OpenSSH endpoints and a
temporary Unix-socket fake herdr server, then runs the mandatory
`HeelerSSHDirectStreamLocalE2ETests` suite.

Every sshd instance runs unprivileged, as the invoking account, so the whole
gate runs on a developer machine with no `sudo` and leaves nothing behind. Each
session is forced through POSIX `sh` with an isolated `HOME` and a fixed `PATH`
that contains a `herdr` stub and no `socat`, so the fixture means the same thing
on every machine and can never reach a real herdr server. The single exception
is real password authentication: macOS cannot verify an account password
without root, and an unprivileged sshd can only authenticate the account it
already runs as. Those two tests need a disposable account and one root-owned
sshd, so they skip without passwordless `sudo` and are mandatory in merge CI
(`HEELER_CI_MANDATORY=1`).

The suite includes a repeatable 25-exchange loopback measurement. Its printed
output is telemetry for local channel open, exchange, and close cost — not a
merge gate, not a machine-speed promise, and not a WAN latency promise.
Absolute loopback timing varies with the CI scheduler; accidental remote-process
fallback is a hard functional failure under the socat-free Host PATH the
fixture already enforces (see `scripts/run-ci-ios-tests.sh`).

### Recorded exec-plus-socat baseline

The transport spike measured both transports on loopback over the same
authenticated session (spec #110, ADR 0011). Kept as historical context for
telemetry comparison only:

| Transport | Mean per exchange |
| --- | --- |
| `exec` + `socat` | 22.368 ms |
| `direct-streamlocal` | 0.514 ms |

The socat backend was deleted with the Citadel cutover, so that number cannot be
re-measured. Architecture regression (reintroducing per-request remote process
startup) is caught by the socat-free fixture and the suite's functional
direct-streamlocal coverage, not by an absolute timing ceiling.

## Jump Host acceptance

`SSHConnection.connectThrough(to:timeout:)` opens a `direct-tcpip` channel on
an authenticated Jump Host and runs a second, independent SSH session over its
byte stream. The target performs its own Host Key verification and
authentication. Closing the target connection tears down the target session,
forwarding channel, and Jump Host session in that order.

The same CI fixture also runs `HeelerSSHJumpHostGateE2ETests` against two
disposable sshd instances with independent Host Keys. The suite is a hard gate
for protocol-17 direct-streamlocal traffic, failure taxonomy, cancellation,
deadlines, cleanup, and sequential and concurrent stress.
