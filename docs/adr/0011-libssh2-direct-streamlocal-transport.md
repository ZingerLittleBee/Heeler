---
status: accepted
---

# Replace Citadel and socat with libssh2 direct-streamlocal

Heeler will replace Citadel with a libssh2-based SSH transport and connect to
the herdr API socket through OpenSSH `direct-streamlocal` channels. A Host that
prohibits stream-local forwarding will fail preflight with an actionable error;
Heeler will not retain `exec + socat` as a compatibility fallback, because that
would preserve two transport paths and the socat configuration, discovery,
error, and test surface indefinitely.

The generic SSH implementation will live in a repository-local
`Packages/HeelerSSH` Swift package rather than a separate repository. The
package will own the native dependencies, non-blocking session driver, channel
lifecycle, cancellation, exec, PTY, forwarding, and SFTP primitives without
exposing libssh2 types. The app target will retain the herdr-aware `Transport`
adapter, Host and Pairing policy, wire semantics, persistence, and UI.

The local package will contain the device and Simulator XCFrameworks for
libssh2 and OpenSSL. Exact upstream versions and source checksums, a
reproducible build script, build provenance, license notices, and artifact
checksums will be committed beside them. Normal app and CI builds will consume
the checked-in artifacts rather than rebuilding OpenSSL; dependency updates are
the only workflow that regenerates them.

libssh2 does not expose the server description that distinguishes a stale Unix
socket from SSH forwarding policy denial after a stream-local channel-open
failure. On that failure path, Heeler will run one read-only remote `test -S`
diagnostic. A missing socket maps to `socketNotFound`. When the socket exists,
Heeler reports one honest combined failure: herdr may not be running, or SSH
stream-local forwarding may be disabled. It does not claim a narrower cause
that the client cannot observe. This diagnostic is not a socat transport
fallback.

That combined failure is therefore not retryable, and the two properties are
not separable. A cause the client cannot narrow is a cause only the user can
resolve, by starting herdr or by enabling stream-local forwarding — so the
failure has to reach the user unprompted, not merely be reachable. The Console
is the surface a user watches, and there `connectionGuidance` is rendered for a
failed Host only; a reconnecting one shows a short summary phrase that names no
action. The Host detail sheet does render the full guidance while a Host is
reconnecting, but only for a user who already suspected something and opened
it. Combined with a reconnect policy that has no attempt cap, marking this
error retryable would leave a Host with `AllowStreamLocalForwarding no` — a
permanent configuration error, the exact case this classification exists to
make legible — retrying forever behind that actionless phrase, with the
sentence written for it parked one navigation away. Stopping is what moves the
actionable text to where the user is already looking. A later bounded-retry
design could revisit this, but it would have to carry the guidance onto the
ambient surface, or terminate soon enough that the failed state carries it.

Correction (#156): the clause "but only for a user who already suspected
something and opened it" is false, and it is not part of this decision. It
arrived with `b34e67b`, a later correction to this same paragraph's claims
about where guidance is shown. Measured against `HostListView`, that sheet's
detail screen (`HostOnboardingView`) is reached four ways — a Host row, a
saved add form (`HostListView.swift:165`), a finished Pairing scan (`:183`),
and a deep link (`:225`) that the Console's own issue buttons use — and two of
them, the add form and the Pairing scan, push the user onto it with nothing
suspected. Suspicion is not what that surface selects for, so nothing should
be inferred from the clause; what is true of the screen is that its subject is
one Host's connection health and that it is not ambient. The decision rests on
the sentence before the clause — the Console, the surface a user watches,
withholds the guidance while a Host is reconnecting — and is unchanged. See
Connection Guidance in `CONTEXT.md` for what each of the four surfaces shows.

Terminology (#163): the pointer above outlives the term it names. `CONTEXT.md`
no longer carries Connection Guidance. It carries Transport Error Presentation,
which splits that one string into a Summary, an optional Detail and an optional
Recovery Suggestion. The reason is a fact this paragraph already half-states:
"a reconnecting one shows a short summary phrase that names no action" turned
out to describe the whole retryable set, not one surface's choice — so naming
no action is a property of those errors, and a type total over the error set
could not honestly be named for guidance. Stated exactly: every retryable
error's Summary names no action; an unreachable Host may separately carry a
Recovery Suggestion, rendered only on surfaces permitted by the
automatic-recovery presentation rule. The per-surface inventory the pointer
promised is deliberately not in the glossary any more: it is implementation, it
was got wrong repeatedly while it lived there (#156), and it belongs with the
presentation types and their tests.
The earlier statement that Host detail renders the "full guidance" refers to
every part of the retryable string that existed when this ADR was accepted;
under Transport Error Presentation that content is the Explanation. It does not
authorize a newly modeled Recovery Suggestion during automatic recovery. No
Reconnecting surface renders that Suggestion.
Nothing above is retracted. The sentence this decision rests on survives the
rename intact — withholding an instruction from the ambient surface during
automatic recovery is exactly what the replacement makes a rule rather than an
accident, and a stopped Host still carries the whole presentation to where the
user is already looking. The property is renamed by #163's implementation;
until then the app still calls it `connectionGuidance`.

Cancellation and timeout recovery will be channel-scoped only when the
affected channel has been allocated and can be closed cleanly. A timeout while
opening a channel, handshaking, authenticating, or establishing a nested Jump
Host session, or a channel close that misses its cleanup deadline, invalidates
the entire SSH connection. Deliberately ending Events or Attach closes only its
live channel and leaves the connection reusable.

The libssh2 method preferences will preserve the Host Key algorithm order used
by the current NIOSSH transport. Existing algorithm-aware TOFU records must
continue without a new prompt, and Heeler will not silently accept a different
Host Key algorithm merely because libssh2 would otherwise negotiate it first.
If a Host removes its previously trusted algorithm, the connection remains a
Host Key mismatch until the user explicitly removes and re-establishes trust.

Citadel and libssh2 adapters may coexist temporarily on the implementation
branch so the same behaviour tests can run against both. The production
cutover is atomic: RPC, Events, PTY, SFTP, Jump Host, and Pairing must all use
libssh2 before release, after which Citadel, NIOSSH, their NIO dependencies,
and the socat transport are removed. The product will not expose a backend
switch or retain runtime fallback to the old transport.

Release requires parity across the existing Transport, Events, Attach, SFTP,
Pairing, and Jump Host end-to-end suites; new coverage for stream-local socket
and policy failures, cancellation, timeout, and channel reuse; real sshd
authentication with Password, Device Key, and Bootstrap Key; migration of
existing Host Key trust without a prompt; a full Host flow where socat is not
installed; physical-iPhone foreground/background, Attach, and image-staging
acceptance; and an App Store archive check for slices, signing, notices, and
size. Citadel, NIOSSH, socat configuration, and their runtime code must be
absent from the release tree.

The migration may adopt libssh2-specific improvements that strictly dominate
the current internal implementation without changing caller semantics. Any
observable change to errors, retries, concurrency, connection lifetime, Host
requirements, security policy, persistence, or the `Transport` interface
requires a separate explicit decision before implementation. Each accepted
optimization needs a benchmark or concrete failure scenario and regression
coverage; the herdr one-request-per-socket contract remains unchanged.

Each SSH hop will have one non-blocking session driver that exclusively owns
and serializes every call into its `LIBSSH2_SESSION`. Swift tasks submit async
operations to that driver; channel state machines may make concurrent progress,
but no task or channel calls the session directly. The driver owns socket
readiness, fairness, backpressure, cancellation, and teardown. A nested Jump
Host driver uses the outer direct-tcpip channel as its transport and coordinates
progress with the outer driver; blocking libssh2 calls and a global cross-Host
lock are prohibited.

The native dependencies will be built without the OpenSSL legacy provider and
will not enable obsolete SSH-DSS, SHA-1 SSH-RSA, CBC, group1, or equivalent
legacy algorithms for compatibility. The supported algorithm set must be at
least as strong as the current NIOSSH baseline and cover modern Ed25519,
ECDSA, RSA-SHA2, KEX, and cipher choices. Algorithm negotiation failure will be
reported distinctly from authentication failure; any future legacy-Host
support requires a separate security decision.

The replacement package will not depend on SwiftNIO. Direct connections use
non-blocking POSIX sockets with `DispatchSourceRead` and
`DispatchSourceWrite` readiness, while nested Jump Host sessions use an
internal byte-transport interface backed by the outer direct-tcpip channel.
NIO futures, buffers, and event loops will not cross or remain below the
package interface.

Device Key and Bootstrap Key private material remains in Keychain-backed
CryptoKit objects. The package receives only the public key blob and a
synchronous signing closure for bytes supplied by libssh2; it does not accept,
serialize, log, or persist those private keys.

`HeelerSSH` will implement only capabilities with current Heeler callers:
Password and callback-based public-key authentication, Host Key data, exec,
PTY exec and resize, direct-streamlocal, direct-tcpip Jump Host, the SFTP
operations needed by staging and plugin files, keepalive, close, deadlines,
and cancellation. SSH agent, keyboard-interactive, private-key file parsing,
SCP, remote listeners, SOCKS, SSH config parsing, generic subsystems, and CLI
tooling remain out of scope until a real caller requires them.

Channel admission will use separate budgets because OpenSSH `MaxSessions`
limits shell, login, and subsystem channels but not forwarding channels. Eight
ordinary direct-streamlocal RPC channels plus one reserved Events channel use
the forwarding budget; eight ordinary exec or SFTP channels plus one reserved
Attach PTY use the session budget, leaving headroom under the default
`MaxSessions` value of ten. A connection-level ceiling prevents the combined
budgets from growing without bound. Initial limits remain conservative and may
change only after stress and weak-network evidence; SFTP staging no longer
blocks ordinary RPC admission.

The existing herdr `ping` remains the authoritative connection health check
because it exercises SSH, both Jump Host hops, direct-streamlocal, the Unix
socket, and the herdr server and protocol. A libssh2 SSH keepalive may be used
internally for a demonstrated idle-network problem, but it cannot replace the
application ping or by itself mark a Host healthy; simultaneous keepalive
intervals must avoid redundant cellular wakeups.

Implementation will treat the production non-blocking Jump Host path as an
early go/no-go gate. After direct connection, Host Key, Device Key, and one
direct-streamlocal exchange work through the package, the next milestone must
prove a real nested direct-tcpip session, independent trust at both hops,
cancellation, timeout, and teardown before Events, PTY, SFTP, Pairing, or broad
app migration proceeds.

Merge CI will start two disposable, unprivileged loopback sshd instances with
independent ports, Host Keys, and temporary authorization, plus a temporary
Unix-socket fake herdr server. The real Password, Device Key, Bootstrap Key,
two-hop trust, direct-streamlocal RPC and Events, Jump Host, PTY, SFTP, policy
denial, cancellation, and timeout suites must execute rather than skip, and CI
will verify executed test counts. The fixture will neither install nor invoke
socat and will clean up every process and temporary file.
