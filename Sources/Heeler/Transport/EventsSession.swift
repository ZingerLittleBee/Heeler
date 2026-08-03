import Foundation

/// Bounded backoff for transient events-channel failures (#18): capped
/// exponential delay, unlimited attempts. Action-required failures stop and
/// surface their exact cause instead of burning retries forever.
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

/// Keepalive for the events session (#18). The Transport seam deliberately
/// exposes no SSH-specific keepalive machinery, so the session pings herdr
/// over the ordinary RPC path instead — which is also the stronger check: it
/// generates SSH traffic that keeps NAT mappings alive, is bounded by the
/// per-request deadline, and exercises the whole path (SSH + socat + herdr),
/// so a dead connection is detected within interval + request timeout.
struct KeepalivePolicy: Sendable, Equatable {
    /// Idle time between pings while the events channel is live. Pings are
    /// skipped while real traffic within the interval — a successful RPC or
    /// an arriving event — already proves the connection alive; both of the
    /// ping's jobs (liveness detection, NAT-mapping refresh) are done by
    /// that traffic.
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
    /// Reconnecting cannot repair this failure. The session remains stopped
    /// until the caller retries after the Host's configuration is corrected.
    case failed(TransportError)
    /// Deliberately torn down (the app's background grace period elapsed);
    /// no reconnect activity until `resume()`.
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
/// connection down deliberately (call once the app's background grace period
/// elapses — iOS freezes sockets anyway when the process suspends, and an
/// explicit close makes resume cheap and deterministic),
/// `end()` is terminal. All teardown closes the live forwarding channel
/// explicitly. Lifecycle calls serialize
/// internally — a `resume()` racing into a `suspend()`'s in-flight teardown
/// waits for it instead of interleaving (quick background→foreground
/// bounces are routine on iOS; callers never need to serialize their own
/// calls).
///
/// `updates` supports a single consumer and buffers at most
/// `updatesBufferLimit` updates (#22): under overflow the oldest are shed
/// and an `.event(.eventsDropped)` marker is yielded in their place (see
/// `HerdrEvent.eventsDropped` for the delivery guarantee), so the consumer
/// always learns it must resync instead of trusting incomplete deltas.
/// Statuses can be shed too — they are state, not edges, so the newest one
/// wins: terminal transitions (`.suspended`, `.ended`) are always the last
/// thing yielded and therefore survive, and a shed `.connected`'s resync
/// duty is covered by the marker.
actor EventsSession {
    private enum Phase {
        case suspended, active, ended
    }

    /// Status transitions and events, in order. Finishes after `end()`.
    nonisolated let updates: AsyncStream<EventsSessionUpdate>
    private let updatesContinuation: AsyncStream<EventsSessionUpdate>.Continuation
    /// Successful herdr ping round trips on the Host's live SSH connection.
    /// This is separate from `updates`: latency is latest-value telemetry, not
    /// part of the ordered status/event convergence stream.
    nonisolated let latencyUpdates: AsyncStream<Duration>
    private let latencyContinuation: AsyncStream<Duration>.Continuation
    /// How many updates the bounded buffer has shed so far. Every shed
    /// update is covered by a marker (see `yieldUpdate`), so this is
    /// observability for diagnostics and tests, not a consumer signal.
    private(set) var droppedUpdateCount = 0

    private var subscriptions: [EventSubscription]
    private let connect: @Sendable () async throws -> any Transport
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?

    private var phase: Phase = .suspended
    /// The Host's live Transport. It never escapes this module; consumers
    /// use `withTransport` or `withTerminalTransport` so replacement and
    /// terminal exclusivity remain local.
    private var currentTransport: (any Transport)?
    /// Monotonic identity for the installed Transport. Subscription-only
    /// reconnects reuse the same Transport and therefore do not advance it.
    private(set) var transportGeneration: UInt64 = 0
    private var hasEstablishedTransport = false
    /// Set when the connection can no longer be trusted even though it may
    /// still look alive (a timed-out request or keepalive ping): the next
    /// reconnect replaces the transport instead of reusing it.
    private var transportSuspect = false
    /// The keepalive failure that forced the current teardown, surfaced in
    /// the following `.reconnecting` status.
    private var pendingKeepaliveFailure: TransportError?
    /// The most recent proof the connection is alive: the connect-path ping,
    /// a successful RPC through `withTransport`, an arriving event, or an
    /// answered keepalive. The keepalive loop skips its ping while this is
    /// fresher than its interval (see `KeepalivePolicy.interval`).
    private var lastConnectionActivity: ContinuousClock.Instant?
    /// Set while `updateSubscriptions` tears the live channel down on
    /// purpose: the run loop then re-subscribes immediately — same
    /// connection, no backoff, no `.reconnecting` — instead of treating the
    /// graceful stream end as a failure.
    private var resubscribeRequested = false
    private var liveStream: HerdrEventStream?
    /// Identifies the current activation so a cancelled connection attempt
    /// cannot install itself after a later resume has already started.
    private var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var backoffSleep: Task<Void, any Error>?
    private var backoffGeneration: UInt64?
    /// The most recently enqueued lifecycle transition; each new one chains
    /// behind it, so transitions never interleave across the suspension
    /// points inside a teardown (see the actor doc).
    private var lifecycleTransition: Task<Void, Never>?
    /// Exactly one Attach operation may hold the Host's terminal channel.
    /// Waiters are FIFO and cancellation-safe; the permit spans the entire
    /// operation, including explicit terminal teardown.
    private var terminalInUse = false
    private var terminalWaiters: [TerminalWaiter] = []
    private var terminalIdleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        subscriptions: [EventSubscription],
        connect: @escaping @Sendable () async throws -> any Transport,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default,
        updatesBufferLimit: Int = HerdrEventStream.bufferLimit
    ) {
        self.subscriptions = subscriptions
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.keepalive = keepalive
        // Bounded (#22): dropping is safe because every drop is surfaced
        // through `yieldUpdate`'s marker; see the actor doc for the policy
        // and HerdrEventStream.bufferLimit for the sizing rationale.
        (updates, updatesContinuation) = AsyncStream.makeStream(
            of: EventsSessionUpdate.self,
            bufferingPolicy: .bufferingNewest(updatesBufferLimit))
        (latencyUpdates, latencyContinuation) = AsyncStream.makeStream(
            of: Duration.self,
            bufferingPolicy: .bufferingNewest(1))
    }

    /// Activates the session (initially, or after `suspend()`): establishes
    /// the transport and channel, emitting `.connected` on success and
    /// `.reconnecting` transitions for transient failures. Returns once any
    /// in-flight teardown has finished and the activation is underway. No-op
    /// while active or ended.
    func resume() async {
        await enqueueLifecycleTransition { await self.activate() }
    }

    /// Restarts an active session whose reconnect loop stopped on a
    /// non-retryable failure. Also provides an explicit retry for a currently
    /// reconnecting session after the user changes Host settings.
    func retry() async {
        await enqueueLifecycleTransition { await self.restart() }
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

    /// Replaces the subscription set. Needed because pane-scoped kinds
    /// (`pane.agent_status_changed`) subscribe per pane id, and panes come
    /// and go. While the channel is live it is ended by explicit close and
    /// re-subscribed immediately on the same connection; the fresh
    /// `.connected` that follows is the consumer's usual re-snapshot signal,
    /// so anything missed in the gap rides the normal snapshot-then-delta
    /// path. While suspended or between reconnects the new set simply takes
    /// effect on the next subscribe. No-op when the set is unchanged.
    ///
    /// Pane-scoped entries survive only as long as the subscription that
    /// carries them: any disconnect drops them (see `dropPaneSubscriptions`),
    /// so callers must reinstall the set after every `.connected` rather than
    /// assume the last one is still in force.
    func updateSubscriptions(_ subscriptions: [EventSubscription]) async {
        guard self.subscriptions != subscriptions else { return }
        self.subscriptions = subscriptions
        guard phase == .active, let stream = liveStream else { return }
        resubscribeRequested = true
        await stream.end()
    }

    /// Runs an ordinary RPC against the currently installed Transport.
    /// Calls are intentionally concurrent; the Transport owns its channel
    /// budget. The Transport value never becomes caller-owned state.
    func withTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let transport = currentTransport else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        let value = try await operation(transport)
        noteConnectionActivity()
        return value
    }

    /// Runs one terminal lifetime with exclusive access to the Host's
    /// terminal channel. The next caller cannot observe a Transport until
    /// the previous operation, including its teardown, has returned.
    func withTerminalTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        try await acquireTerminal()
        do {
            try Task.checkCancellation()
            let value = try await withTransport(operation)
            releaseTerminal()
            return value
        } catch {
            releaseTerminal()
            throw error
        }
    }

    private func activate() {
        guard phase == .suspended else { return }
        phase = .active
        activationGeneration &+= 1
        let generation = activationGeneration
        runTask = Task { await self.run(generation: generation) }
    }

    private func restart() async {
        guard phase == .active else {
            activate()
            return
        }
        phase = .suspended
        await windDown()
        activate()
    }

    private func deactivate() async {
        guard phase == .active else { return }
        phase = .suspended
        await windDown()
        yieldUpdate(.status(.suspended))
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        await windDown()
        yieldUpdate(.status(.ended))
        updatesContinuation.finish()
        latencyContinuation.finish()
    }

    /// The single gate every update leaves through: yields it and, when the
    /// bounded buffer sheds something to make room, follows up with the drop
    /// marker. One marker covers every update shed before it; a marker that
    /// is later shed itself lands right back here and is re-armed (see
    /// `HerdrEvent.eventsDropped`).
    private func yieldUpdate(_ update: EventsSessionUpdate) {
        guard case .dropped = updatesContinuation.yield(update) else { return }
        droppedUpdateCount += 1
        if case .dropped = updatesContinuation.yield(.event(.eventsDropped)) {
            droppedUpdateCount += 1
        }
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
    /// with bounded backoff, until the phase or generation changes. A stale
    /// run may outlive suspend while an SSH bridge ignores cancellation, but
    /// it can never install a Transport into a newer activation.
    private func run(generation: UInt64) async {
        var attempt = 0
        while activationIsCurrent(generation) {
            let stream: HerdrEventStream
            do {
                let transport = try await ensureTransport(for: generation)
                guard activationIsCurrent(generation) else { break }
                stream = try await transport.subscribeToEvents(subscriptions)
            } catch {
                guard activationIsCurrent(generation) else { break }
                let failure = Self.transportFailure(error)
                if failure == .timedOut {
                    // The connection swallowed a request whole; do not trust
                    // it for the retry even if it still looks alive.
                    transportSuspect = true
                }
                // A pane that exited between the snapshot behind this
                // subscription set and this subscribe is an ordinary race,
                // not a connection problem: retry it straight away with the
                // global set rather than showing the user a failure.
                if Self.namesAMissingPane(failure), dropPaneSubscriptions() {
                    continue
                }
                guard failure.isRetryable else {
                    yieldUpdate(.status(.failed(failure)))
                    return
                }
                dropPaneSubscriptions()
                attempt += 1
                await emitReconnectingAndBackOff(
                    attempt: attempt, failure: failure, generation: generation)
                continue
            }
            if !activationIsCurrent(generation) {
                await stream.end()
                break
            }
            liveStream = stream
            attempt = 0
            pendingKeepaliveFailure = nil
            yieldUpdate(.status(.connected))
            startKeepalive(stream: stream)

            var streamFailure: TransportError?
            do {
                for try await event in stream.events {
                    noteConnectionActivity()
                    yieldUpdate(.event(event))
                }
                // Graceful finish: the channel was ended explicitly, by
                // suspend()/end() or by a failed keepalive.
            } catch {
                streamFailure = Self.transportFailure(error)
            }
            if liveStream === stream {
                stopKeepalive()
                liveStream = nil
            }
            guard activationIsCurrent(generation) else { break }
            if resubscribeRequested {
                // Deliberate teardown by updateSubscriptions: re-subscribe
                // right away (the connection is still trusted), even if the
                // stream happened to die on its own in the same instant —
                // the subscribe path re-checks the connection anyway.
                resubscribeRequested = false
                continue
            }
            let failure =
                pendingKeepaliveFailure ?? streamFailure
                ?? .channelFailed(detail: "events stream ended unexpectedly")
            pendingKeepaliveFailure = nil
            guard failure.isRetryable else {
                yieldUpdate(.status(.failed(failure)))
                return
            }
            dropPaneSubscriptions()
            attempt += 1
            await emitReconnectingAndBackOff(
                attempt: attempt, failure: failure, generation: generation)
        }
    }

    /// Discards the pane-scoped subscriptions, keeping the global ones.
    /// Returns whether the set actually changed.
    ///
    /// Pane-scoped entries are derived from a snapshot, and herdr rejects an
    /// entire `events.subscribe` when a single one names a pane that has
    /// exited (verified against 0.7.5). Keeping them across a disconnect
    /// would let one dead pane wedge the Host offline permanently, because
    /// the reconnect loop would resend the same doomed set forever and the
    /// `.connected` that refreshes it would never arrive. Every `.connected`
    /// already obliges the consumer to re-snapshot, and that resync
    /// reinstalls the pane set through `updateSubscriptions`.
    @discardableResult
    private func dropPaneSubscriptions() -> Bool {
        let globalsOnly = subscriptions.filter { subscription in
            if case .global = subscription { true } else { false }
        }
        guard globalsOnly.count != subscriptions.count else { return false }
        subscriptions = globalsOnly
        return true
    }

    private static func namesAMissingPane(_ failure: TransportError) -> Bool {
        guard case .apiRejected(let code, _) = failure else { return false }
        return code == "pane_not_found"
    }

    /// The Host's live transport: reuses the current one while its SSH
    /// connection is alive and trusted, otherwise closes it and establishes
    /// a fresh one — pinged first, as on every new connection path.
    private func ensureTransport(for generation: UInt64) async throws -> any Transport {
        guard activationIsCurrent(generation) else {
            throw TransportError.cancelled
        }
        if let transport = currentTransport {
            if !transportSuspect, await transport.isConnected {
                return transport
            }
            currentTransport = nil
            try? await transport.close()
        }
        let transport = try await connect()
        do {
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            let latency = try await measureLatency(on: transport)
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            latencyContinuation.yield(latency)
        } catch {
            try? await transport.close()
            throw error
        }
        transportSuspect = false
        noteConnectionActivity()
        currentTransport = transport
        if hasEstablishedTransport {
            transportGeneration &+= 1
        } else {
            hasEstablishedTransport = true
        }
        return transport
    }

    private func activationIsCurrent(_ generation: UInt64) -> Bool {
        phase == .active && activationGeneration == generation && !Task.isCancelled
    }

    private func emitReconnectingAndBackOff(
        attempt: Int,
        failure: TransportError,
        generation: UInt64
    ) async {
        let delay = reconnectPolicy.delay(beforeAttempt: attempt)
        yieldUpdate(.status(.reconnecting(attempt: attempt, delay: delay, failure: failure)))
        let sleep = Task { try await Task.sleep(for: delay) }
        backoffSleep = sleep
        backoffGeneration = generation
        try? await sleep.value
        if backoffGeneration == generation {
            backoffSleep = nil
            backoffGeneration = nil
        }
    }

    /// Ends the current activation and closes everything. The run task is
    /// cancelled but deliberately not awaited: a stalled SSH operation may
    /// ignore task cancellation. Generation checks
    /// make any late result harmless, while an installed Transport is still
    /// closed explicitly before lifecycle teardown returns.
    private func windDown() async {
        backoffSleep?.cancel()
        backoffSleep = nil
        backoffGeneration = nil
        stopKeepalive()
        let task = runTask
        runTask = nil
        task?.cancel()
        let stream = liveStream
        liveStream = nil
        if let transport = currentTransport {
            currentTransport = nil
            try? await transport.close()
        }
        if let stream {
            await stream.end()
        }
        await waitForTerminalIdle()
        transportSuspect = false
        pendingKeepaliveFailure = nil
        resubscribeRequested = false
        lastConnectionActivity = nil
        dropPaneSubscriptions()
    }

    // MARK: Keepalive

    private func startKeepalive(stream: HerdrEventStream) {
        guard let keepalive, let transport = currentTransport else { return }
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: keepalive.interval)
                if Task.isCancelled { break }
                guard self.connectionIsIdle(within: keepalive.interval) else { continue }
                do {
                    let latency = try await self.measureLatency(on: transport)
                    self.latencyContinuation.yield(latency)
                    self.noteConnectionActivity()
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

    private func noteConnectionActivity() {
        lastConnectionActivity = .now
    }

    /// Measures only the herdr `ping` request on an established Transport.
    /// SSH connection setup is deliberately excluded, so Hosts remain
    /// comparable across reconnects and authentication methods.
    private func measureLatency(on transport: any Transport) async throws -> Duration {
        let started = ContinuousClock.now
        _ = try await transport.ping()
        return started.duration(to: .now)
    }

    /// Whether no liveness proof arrived within `interval`, meaning the next
    /// keepalive ping is actually needed.
    private func connectionIsIdle(within interval: Duration) -> Bool {
        guard let last = lastConnectionActivity else { return true }
        return ContinuousClock.now - last >= interval
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
        if let failure = error as? TransportError {
            return failure
        }
        if let rejection = error as? HerdrAPIError {
            return .apiRejected(code: rejection.code, message: rejection.message)
        }
        if case DeviceKeyStoreError.storedKeyCorrupt = error {
            return .deviceKeyCorrupt
        }
        return .channelFailed(detail: String(describing: error))
    }

    // MARK: Terminal exclusivity

    private struct TerminalWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private func acquireTerminal() async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if terminalInUse {
                    terminalWaiters.append(
                        TerminalWaiter(id: id, continuation: continuation))
                } else {
                    terminalInUse = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelTerminalWaiter(id: id) }
        }
    }

    private func cancelTerminalWaiter(id: UUID) {
        guard let index = terminalWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = terminalWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseTerminal() {
        while !terminalWaiters.isEmpty {
            let waiter = terminalWaiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        terminalInUse = false
        let waiters = terminalIdleWaiters
        terminalIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTerminalIdle() async {
        guard terminalInUse else { return }
        await withCheckedContinuation { terminalIdleWaiters.append($0) }
    }
}
