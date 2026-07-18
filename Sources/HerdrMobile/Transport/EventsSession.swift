import Foundation

/// Bounded backoff for events-channel reconnects (#18): capped exponential
/// delay, unlimited attempts. The Console keeps trying forever and shows
/// staleness through the session's status; the user decides when to give up.
struct ReconnectPolicy: Sendable, Equatable {
    var initialDelay: Duration
    var multiplier: Int
    var maxDelay: Duration

    static let `default` = ReconnectPolicy(
        initialDelay: .seconds(1), multiplier: 2, maxDelay: .seconds(30))

    /// The delay before reconnect attempt `attempt` (1-based): the initial
    /// delay grown by `multiplier` per prior failure, clamped at `maxDelay`.
    func delay(beforeAttempt attempt: Int) -> Duration {
        let factor = max(multiplier, 1)
        var delay = initialDelay
        var remaining = attempt - 1
        while remaining > 0, delay < maxDelay {
            delay = delay * factor
            remaining -= 1
        }
        return min(delay, maxDelay)
    }
}

/// Keepalive for the events session (#18). Citadel 0.12.1 exposes no
/// SSH-level keepalive (no ignore-packet or global-request API in it or its
/// NIOSSH fork) and no path to the NIO channel for TCP keepalive socket
/// options (`SSHClient.session` is internal; the `channelHandlers:` connect
/// parameter is stored but never installed). So the session pings herdr over
/// the ordinary RPC path instead — which is also the stronger check: it
/// generates SSH traffic that keeps NAT mappings alive, is bounded by the
/// per-request deadline, and exercises the whole path (SSH + socat + herdr),
/// so a dead connection is detected within interval + request timeout.
struct KeepalivePolicy: Sendable, Equatable {
    /// Idle time between pings while the events channel is live.
    var interval: Duration

    static let `default` = KeepalivePolicy(interval: .seconds(30))
}

/// Where the events session stands; the UI derives staleness from this.
enum EventsSessionStatus: Sendable, Equatable {
    /// The events channel is live. Emitted on every (re)connect — herdr does
    /// not replay state on subscribe (#4), so each `.connected` is the
    /// consumer's signal to re-snapshot via `listAgents()`.
    case connected
    /// The stream is down and attempt `attempt` starts after `delay`;
    /// everything shown since the last `.connected` may be stale. `failure`
    /// is what killed the previous attempt, for actionable user guidance.
    case reconnecting(attempt: Int, delay: Duration, failure: TransportError)
    /// Deliberately torn down (app backgrounded); no reconnect activity
    /// until `resume()`.
    case suspended
    /// `end()` was called; the session is finished for good.
    case ended
}

/// One element of the session's update stream: status transitions and events
/// interleaved in the order they happened.
enum EventsSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    case event(HerdrEvent)
}

/// The self-healing events channel for one Host (#18): owns the Host's
/// Transport, keeps its dedicated `events.subscribe` channel alive across
/// network blips and foreground/background transitions, and reports every
/// transition so the UI can show staleness.
///
/// Layer-honest reconnect: a dropped *channel* re-subscribes on the same SSH
/// connection through the transport's single-channel state machine; a dead
/// *SSH connection* (`isConnected == false`, or a timeout that means the
/// connection cannot be trusted) is closed and re-established via `connect`,
/// then pinged — the first call on every new connection path — before
/// re-subscribing.
///
/// Lifecycle: a fresh session is suspended; `resume()` activates it (call on
/// launch and on foregrounding), `suspend()` tears the channel and the SSH
/// connection down deliberately (call on backgrounding — iOS suspends
/// sockets anyway, an explicit close makes resume cheap and deterministic),
/// `end()` is terminal. All teardown is by explicit close, never by
/// cancelling a live exec channel (ADR 0002). Lifecycle calls serialize
/// internally — a `resume()` racing into a `suspend()`'s in-flight teardown
/// waits for it instead of interleaving (quick background→foreground
/// bounces are routine on iOS; callers never need to serialize their own
/// calls).
///
/// `updates` supports a single consumer and buffers without bound, exactly
/// like the underlying event stream (fine foregrounded in M0).
actor EventsSession {
    private enum Phase {
        case suspended, active, ended
    }

    /// Status transitions and events, in order. Finishes after `end()`.
    nonisolated let updates: AsyncStream<EventsSessionUpdate>
    private let updatesContinuation: AsyncStream<EventsSessionUpdate>.Continuation

    private let subscriptions: [EventSubscription]
    private let connect: @Sendable () async throws -> any Transport
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?

    private var phase: Phase = .suspended
    /// The Host's live Transport; consumers run snapshot RPCs (`listAgents`)
    /// through it after each `.connected`. Nil while suspended or between
    /// SSH re-establishments.
    private(set) var currentTransport: (any Transport)?
    /// Set when the connection can no longer be trusted even though it may
    /// still look alive (a timed-out request or keepalive ping): the next
    /// reconnect replaces the transport instead of reusing it.
    private var transportSuspect = false
    /// The keepalive failure that forced the current teardown, surfaced in
    /// the following `.reconnecting` status.
    private var pendingKeepaliveFailure: TransportError?
    private var liveStream: HerdrEventStream?
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var backoffSleep: Task<Void, any Error>?
    /// The most recently enqueued lifecycle transition; each new one chains
    /// behind it, so transitions never interleave across the suspension
    /// points inside a teardown (see the actor doc).
    private var lifecycleTransition: Task<Void, Never>?

    init(
        subscriptions: [EventSubscription],
        connect: @escaping @Sendable () async throws -> any Transport,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default
    ) {
        self.subscriptions = subscriptions
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.keepalive = keepalive
        (updates, updatesContinuation) = AsyncStream.makeStream(of: EventsSessionUpdate.self)
    }

    /// Activates the session (initially, or after `suspend()`): establishes
    /// the transport and channel, emitting `.connected` on success and
    /// `.reconnecting` transitions until then. Returns once any in-flight
    /// teardown has finished and the activation is underway. No-op while
    /// active or ended.
    func resume() async {
        await enqueueLifecycleTransition { await self.activate() }
    }

    /// Deliberate teardown for backgrounding: ends the events channel by
    /// explicit close, closes the SSH connection, and stops all reconnect
    /// activity. Returns once everything is down. No-op unless active.
    func suspend() async {
        await enqueueLifecycleTransition { await self.deactivate() }
    }

    /// Terminal teardown: like `suspend()`, then finishes `updates` for
    /// good. Idempotent.
    func end() async {
        await enqueueLifecycleTransition { await self.finish() }
    }

    private func activate() {
        guard phase == .suspended else { return }
        phase = .active
        runTask = Task { await self.run() }
    }

    private func deactivate() async {
        guard phase == .active else { return }
        phase = .suspended
        await windDown()
        updatesContinuation.yield(.status(.suspended))
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        await windDown()
        updatesContinuation.yield(.status(.ended))
        updatesContinuation.finish()
    }

    /// Chains `transition` behind the previously enqueued one and waits for
    /// it. Enqueueing is synchronous on the actor, so the chain order is the
    /// call order and no transition ever observes another one mid-teardown.
    private func enqueueLifecycleTransition(
        _ transition: @escaping @Sendable () async -> Void
    ) async {
        let previous = lifecycleTransition
        let task = Task {
            await previous?.value
            await transition()
        }
        lifecycleTransition = task
        await task.value
    }

    // MARK: Reconnect loop

    /// One activation's lifetime: connect/subscribe, stream, and reconnect
    /// with bounded backoff, until the phase leaves `.active`. Exactly one
    /// run loop exists at a time — `suspend()`/`end()` await its exit before
    /// returning, and only `resume()` starts one.
    private func run() async {
        var attempt = 0
        while phase == .active {
            let stream: HerdrEventStream
            do {
                let transport = try await ensureTransport()
                guard phase == .active else { break }
                stream = try await transport.subscribeToEvents(subscriptions)
            } catch {
                guard phase == .active else { break }
                let failure = Self.transportFailure(error)
                if failure == .timedOut {
                    // The connection swallowed a request whole; do not trust
                    // it for the retry even if it still looks alive.
                    transportSuspect = true
                }
                attempt += 1
                await emitReconnectingAndBackOff(attempt: attempt, failure: failure)
                continue
            }
            if phase != .active {
                await stream.end()
                break
            }
            liveStream = stream
            attempt = 0
            pendingKeepaliveFailure = nil
            updatesContinuation.yield(.status(.connected))
            startKeepalive(stream: stream)

            var streamFailure: TransportError?
            do {
                for try await event in stream.events {
                    updatesContinuation.yield(.event(event))
                }
                // Graceful finish: the channel was ended explicitly, by
                // suspend()/end() or by a failed keepalive.
            } catch {
                streamFailure = Self.transportFailure(error)
            }
            stopKeepalive()
            liveStream = nil
            guard phase == .active else { break }
            let failure =
                streamFailure ?? pendingKeepaliveFailure
                ?? .channelFailed(detail: "events stream ended unexpectedly")
            pendingKeepaliveFailure = nil
            attempt += 1
            await emitReconnectingAndBackOff(attempt: attempt, failure: failure)
        }
    }

    /// The Host's live transport: reuses the current one while its SSH
    /// connection is alive and trusted, otherwise closes it and establishes
    /// a fresh one — pinged first, as on every new connection path.
    private func ensureTransport() async throws -> any Transport {
        if let transport = currentTransport {
            if !transportSuspect, await transport.isConnected {
                return transport
            }
            currentTransport = nil
            try? await transport.close()
        }
        let transport = try await connect()
        do {
            _ = try await transport.ping()
        } catch {
            try? await transport.close()
            throw error
        }
        transportSuspect = false
        currentTransport = transport
        return transport
    }

    private func emitReconnectingAndBackOff(attempt: Int, failure: TransportError) async {
        let delay = reconnectPolicy.delay(beforeAttempt: attempt)
        updatesContinuation.yield(
            .status(.reconnecting(attempt: attempt, delay: delay, failure: failure)))
        let sleep = Task { try await Task.sleep(for: delay) }
        backoffSleep = sleep
        try? await sleep.value
        backoffSleep = nil
    }

    /// Ends the current activation and closes everything: interrupts a
    /// backoff wait, ends the channel by explicit close, awaits the run
    /// loop's exit, then closes the SSH connection.
    private func windDown() async {
        backoffSleep?.cancel()
        stopKeepalive()
        if let stream = liveStream {
            await stream.end()
        }
        if let task = runTask {
            await task.value
            runTask = nil
        }
        if let transport = currentTransport {
            currentTransport = nil
            try? await transport.close()
        }
        transportSuspect = false
        pendingKeepaliveFailure = nil
    }

    // MARK: Keepalive

    private func startKeepalive(stream: HerdrEventStream) {
        guard let keepalive, let transport = currentTransport else { return }
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: keepalive.interval)
                if Task.isCancelled { break }
                do {
                    _ = try await transport.ping()
                } catch is CancellationError {
                    break
                } catch TransportError.cancelled {
                    break
                } catch {
                    await self.keepaliveDidFail(Self.transportFailure(error), on: stream)
                    break
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// A keepalive ping failed: the connection cannot be trusted. Tears the
    /// stream down by explicit close; the run loop then reconnects with a
    /// fresh transport and surfaces this failure in `.reconnecting`.
    private func keepaliveDidFail(_ failure: TransportError, on stream: HerdrEventStream) async {
        guard phase == .active, liveStream === stream else { return }
        transportSuspect = true
        pendingKeepaliveFailure = failure
        await stream.end()
    }

    private static func transportFailure(_ error: any Error) -> TransportError {
        (error as? TransportError) ?? .channelFailed(detail: String(describing: error))
    }
}
