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
user is already looking. The property is now `TransportError.presentation`.

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

Amendment (#130): the promise that channel state machines may make concurrent
progress is bounded by libssh2 in three places — channel open, the outbound
transport packet, and any one SFTP handle. The first is channel open. In the
pinned 1.11.1 the continuation state for an unfinished open lives on the
session, not on any channel — `open_state`, `open_channel`, `open_packet`,
`open_data` and
`open_packet_requirev_state` for the generic open, `direct_state` and
`direct_message` for direct-streamlocal, all fields of `LIBSSH2_SESSION` in
`src/libssh2_priv.h`. A second open entered while the first is at `EAGAIN`
skips its own setup, resumes the first state machine, and returns the first
call's channel to the second caller. Every open therefore stays serialized
under the driver's operation mutex and finishes before another one begins.
Waiting for that serialized slot is admission, not an open attempt: cancelling
or timing out there leaves the session reusable because no native continuation
belongs to the waiter. Once its own open call begins, an interrupted open still
invalidates the session under the original cancellation rule above.

Post-open continuation is usually channel-owned — process startup, reads,
writes, close, wait-closed and free each keep their state on `LIBSSH2_CHANNEL`
— so an established channel may make progress in bounded turns instead of
holding the session for a whole round trip. A turn re-acquires the operation
mutex, confirms the driver is still valid and still owns the same session,
re-resolves its channel from a driver-owned registry by stable id, does one
bounded piece of libssh2 work, and releases before it waits or yields. No
native pointer survives a release across a turn boundary: invalidation clears
the registries before it frees the session, and freeing a session destroys
every channel on it, so a resumed turn that finds no entry has nothing left to
dereference. The rule belongs to the shared retry primitive rather than to the
three round-trip methods alone, because a resize holds the session across its
own waits for exactly the same reason an ordinary RPC does, and a resize that
cannot reach the Host promptly is the failure this decision exists to prevent.

"Usually" is load-bearing: every packet producer also shares one session-owned
outbound transport continuation. A send that could not flush its whole packet
records that packet on the session and requires the next attempt to arrive with
the same data pointer and the same length; a different producer is handed
`EAGAIN` and cannot advance it. So when a packet-producing call returns `EAGAIN`
while the session reports an outbound block, the driver records that logical
operation as the transport-send owner, and until the same logical call returns
a non-`EAGAIN` result no other libssh2 call may enter that session unless it is
proved incapable of producing a packet. Channel open is not exempt and cannot
cut ahead of the owner. The rule reads only the public block-direction report,
never private packet layout, and is conservative by construction: recording
ownership too eagerly costs concurrency, while recording it too late strands
the owner behind a caller that can never make progress and can only end at its
own deadline.

Ownership ends only from the exact owning call or whole-session invalidation,
and a caller giving up is neither. A successful non-`EAGAIN` result clears the
owner regardless of a possibly stale outbound direction bit. A negative
non-`EAGAIN` result clears only when no outbound block remains; otherwise the
caller captures any native error status first and then invalidates the session.
Completed whole-session invalidation reclaims the session and its pending
packet together. Cancellation or a deadline observed while that call is
parked clears nothing by itself, because the native packet outlives the task
that produced it and the next producer or cleanup call to enter meets the same
refusal and rebuilds the livelock. An operation cancelled or timed out while it
owns the send must therefore first drive the exact owning call non-cancellably
to a non-`EAGAIN` result inside its own reclamation budget and only then run
channel-scoped cleanup; a budget that expires invalidates the whole session,
exactly as a channel that cannot be reclaimed already does. There is no
admissible state in which the owner is clear while the session is still valid
and its packet still pending.

Yielding is a per-resource privilege rather than a session-wide one: only an
operation whose complete native continuation is proven safe for its own
resource may take bounded turns. SFTP does not qualify and stays outside this
decision. One `LIBSSH2_SFTP` holds a single continuation slot per operation
kind and one partial-packet parser shared across all of them, so a second call
of the same kind resumes the first call's state instead of starting its own,
and a handle id re-resolves to exactly that shared state rather than isolating
it. Every call on one SFTP handle therefore remains mutually exclusive for its
whole logical operation, waits included, and `libssh2_sftp_init` stays fully
serialized because its continuation is session-owned. Letting SFTP yield needs
its own decision and a per-handle logical-operation lease to go with it.

Three costs are accepted with it. Waking is session-wide: an operation that
takes bytes off the socket releases every wait armed before it, so raising the
number of channels that can be parked at once raises the number of wakeups each
inbound packet causes, and the turn body has to stay small enough that the
extra wakeups cost less than the stall they remove. Concurrency is suspended
for as long as a transport-send owner exists, which is precisely when the link
is congested — the case where the stall this decision removes hurts most. And
an open the server is slow to confirm still holds the session for that one
round trip; only a separate single-flight open owner could relax that, and it
needs its own evidence that open itself costs user-visible time.

Error precedence is unchanged. A turn checks cancellation and the deadline
before it checks session validity, and the error that entered the catch is the
error the caller sees; whole-session invalidation remains a side effect of
cleanup that could not reclaim its channel, never a reported outcome that
replaces the caller's own. Channel admission is unchanged too: a lease is held
for a channel's whole lifetime, and yielding the operation mutex mid-turn
neither releases one nor creates capacity for another.

Close is an explicit resource transition. Before PTY exit-status, PTY close,
or direct-streamlocal teardown yields, its registry entry stops accepting user
reads, writes, and resizes. The cleanup operation alone may re-resolve the
entry while closing, so close/free cannot race same-id I/O even though
unrelated resources can keep using the session. PTY close waits for an
in-flight exit-status handshake instead of treating it as an already-complete
close; exit-status failure restores ordinary I/O eligibility so the caller can
retry or close explicitly.

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
