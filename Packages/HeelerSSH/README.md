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
make ssh-artifacts
```

The command builds Release arm64 slices for iPhoneOS and iPhone Simulator,
creates both XCFrameworks, refreshes licenses and provenance, writes file-level
SHA-256 checksums, and verifies the result. Exact byte-for-byte output requires
the Xcode, SDK, compiler, and configuration recorded in
`Artifacts/PROVENANCE.md`.

To verify the committed artifacts without downloading or compiling sources:

```sh
make verify-ssh-artifacts
```

OpenSSL is built without its legacy provider and without the legacy algorithms
listed in the provenance record. libssh2 is compiled with its obsolete cipher
and signature switches disabled; the small reviewed patch in `Patches/`
removes SHA-1 key exchange and MAC methods that libssh2 1.11.1 otherwise has no
build switch for.

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

The suite includes a repeatable
25-exchange loopback benchmark; its output records local channel open,
exchange, and close cost and is not a WAN latency promise.

### Recorded exec-plus-socat baseline

The transport spike measured both transports on loopback over the same
authenticated session (spec #110, ADR 0011):

| Transport | Mean per exchange |
| --- | --- |
| `exec` + `socat` | 22.368 ms |
| `direct-streamlocal` | 0.514 ms |

The socat backend was deleted with the Citadel cutover, so that number cannot be
re-measured; it is kept here as the fixed comparison point. The benchmark
asserts the mean stays under a quarter of the socat baseline. That is a
regression detector — it catches a change that reintroduces per-request remote
process startup — and deliberately not a promise about any particular machine,
and never about a WAN path.

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
