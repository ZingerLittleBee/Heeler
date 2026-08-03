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
`HeelerSSHDirectStreamLocalE2ETests` suite. The fixture does not install or
invoke socat. The suite includes a repeatable 25-exchange loopback benchmark;
its output records local channel open, exchange, and close cost and is not a
WAN latency promise.
