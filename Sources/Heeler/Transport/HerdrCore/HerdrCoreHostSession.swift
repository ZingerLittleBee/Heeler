import Foundation
import Synchronization

/// How long a refused channel is polled while a terminal holder restarts its
/// core, about three seconds after the core dies (ADR 0031).
struct HerdrCoreHolderRestartPolicy: Sendable, Equatable {
    var pollInterval: Duration
    var window: Duration

    static let `default` = HerdrCoreHolderRestartPolicy(
        pollInterval: .milliseconds(500), window: .seconds(5))

    var polls: Int { Int(window / pollInterval) }
}

/// One element of the Host session's update stream, in the order it happened.
enum HerdrCoreHostSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    /// A subscribe snapshot, which replaces the inventory. Every link gets
    /// one, and its core id says which core it came from.
    case snapshot(HerdrCoreSnapshot, coreID: String)
    case event(HerdrCoreEvent)
}

/// Owns a herdr-core Host's framed link, as `EventsSession` owns a Herdr TUI
/// Host's events channel. It reuses that session's reconnect and keepalive
/// policies and status, and suspends and resumes with the app the same way.
///
/// A link that ends while SSH stays up reopens on the same connection, without
/// leaving Connected, and a channel refused while the socket file is there is
/// polled across the holder's restart before it reads not running. Each link
/// takes a fresh cursor and snapshot; event numbers never carry over, since a
/// restarted core counts from zero.
///
/// Update required is never retried, and not running stays retryable with
/// backoff. Reconnecting only ever runs the locator and opens channels, so it
/// never starts a core, and a core the user stopped stays stopped (ADR 0031).
actor HerdrCoreHostSession {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private enum Phase {
        case suspended, active, ended
    }

    /// Statuses, snapshots and events in order. Finishes after `end()`. Bounded
    /// like `EventsSession.updates`: under overflow the oldest are shed and an
    /// `.event(.dropped)` marker takes their place, so the consumer resubscribes.
    nonisolated let updates: AsyncStream<HerdrCoreHostSessionUpdate>
    private let updatesContinuation: AsyncStream<HerdrCoreHostSessionUpdate>.Continuation
    /// A signal that `currentLatency` holds a new sample.
    nonisolated let latencyUpdates: AsyncStream<Void>
    private let latencyContinuation: AsyncStream<Void>.Continuation
    /// Written before the status that makes it observable, and cleared before
    /// any status that ends a connection, as `EventsSession.currentLatency` is.
    nonisolated var currentLatency: Duration? { latencyBox.withLock { $0 } }
    private nonisolated let latencyBox = Mutex<Duration?>(nil)
    nonisolated var currentRouteID: UUID? { routeIDBox.withLock { $0 } }
    private nonisolated let routeIDBox = Mutex<UUID?>(nil)
    /// Advances with each new SSH connection, not with each link on one.
    nonisolated var currentConnectionGeneration: UInt64 { generationBox.withLock { $0 } }
    private nonisolated let generationBox = Mutex<UInt64>(0)
    /// A signal that `currentLeakedEnvironment` holds a new answer.
    nonisolated let leakedEnvironmentUpdates: AsyncStream<Void>
    private let leakedEnvironmentContinuation: AsyncStream<Void>.Continuation
    /// Which variables the connected core inherited, by name only (ADR 0034).
    /// Empty when it holds none of them and when the check could not tell.
    /// Cleared before any status that ends a connection, as `currentLatency` is.
    nonisolated var currentLeakedEnvironment: Set<String> { leakedEnvironmentBox.withLock { $0 } }
    private nonisolated let leakedEnvironmentBox = Mutex<Set<String>>([])

    private let connect: @Sendable () async throws -> any HerdrCoreTransport
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?
    private let holderRestart: HerdrCoreHolderRestartPolicy
    private let sleep: Sleep

    private var phase: Phase = .suspended
    private var currentTransport: (any HerdrCoreTransport)?
    private var hasEstablishedConnection = false
    /// A swallowed request or silent link: the next reconnect redials SSH.
    private var transportSuspect = false
    private var pendingKeepaliveFailure: TransportError?
    /// Whether the last status said Connected. A link reopening on the same
    /// connection stays there, so a core restart never reads as a lost Host.
    private var isAnnouncedConnected = false
    private var resubscribeRequested = false
    private var liveStream: HerdrCoreEventStream?
    /// A line arrived since the keepalive last looked, heartbeats included.
    private(set) var hasTrafficSinceLastKeepalive = false
    private var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var backoffSleep: Task<Void, any Error>?
    private var backoffGeneration: UInt64?
    private var lifecycleTransition: Task<Void, Never>?

    init(
        connect: @escaping @Sendable () async throws -> any HerdrCoreTransport,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default,
        holderRestart: HerdrCoreHolderRestartPolicy = .default,
        updatesBufferLimit: Int = HerdrCoreEventStream.bufferLimit,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.keepalive = keepalive
        self.holderRestart = holderRestart
        self.sleep = sleep
        (updates, updatesContinuation) = AsyncStream.makeStream(
            of: HerdrCoreHostSessionUpdate.self,
            bufferingPolicy: .bufferingNewest(updatesBufferLimit))
        (latencyUpdates, latencyContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        (leakedEnvironmentUpdates, leakedEnvironmentContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Lifecycle

    /// Activates the session, initially or after `suspend()`. No-op while
    /// active or ended.
    func resume() async {
        await enqueueLifecycleTransition { await self.activate() }
    }

    /// Restarts the activation, for a stopped loop or a user's Retry.
    func retry() async {
        await enqueueLifecycleTransition { await self.restart() }
    }

    /// Asks a link that believes it is alive, on a foreground return. A failed
    /// ask goes down the keepalive's path.
    func revalidate() async {
        guard phase == .active, let stream = liveStream, let transport = currentTransport else { return }
        do {
            let latency = try await measureLatency(on: transport)
            publishLatency(latency, measuredOn: stream)
        } catch is CancellationError {
        } catch TransportError.cancelled {
        } catch {
            await keepaliveDidFail(Self.transportFailure(error), on: stream)
        }
    }

    /// Takes the link and the connection down until `resume()`.
    func suspend() async {
        await enqueueLifecycleTransition { await self.deactivate() }
    }

    /// Stops an attempt in flight or its backoff. A live link is left alone.
    func cancelConnecting() async {
        await enqueueLifecycleTransition { await self.stopConnecting() }
    }

    func end() async {
        await enqueueLifecycleTransition { await self.finish() }
    }

    /// Takes a fresh snapshot on the same link, for a consumer that lost
    /// updates. No-op without a live link: the next one brings its own.
    func resubscribe() async {
        guard phase == .active, let stream = liveStream else { return }
        resubscribeRequested = true
        await stream.end()
    }

    /// Runs one call on the installed transport. Unlike `EventsSession` it
    /// never retries: a mutation that may have left must not be sent twice.
    func withTransport<Value: Sendable>(
        _ operation: @Sendable (any HerdrCoreTransport) async throws -> Value
    ) async throws -> Value {
        guard let currentTransport else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return try await operation(currentTransport)
    }

    private func activate() {
        guard phase == .suspended else { return }
        phase = .active
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldUpdate(.status(.connecting))
        runTask = Task { await self.run(generation: generation) }
    }

    private func restart() async {
        guard phase == .active else {
            activate()
            return
        }
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldUpdate(.status(.connecting))
        await windDown()
        guard phase == .active, activationGeneration == generation else { return }
        runTask = Task { await self.run(generation: generation) }
    }

    private func deactivate() async {
        guard phase == .active else { return }
        phase = .suspended
        await windDown()
        yieldUpdate(.status(.suspended))
    }

    private func stopConnecting() async {
        guard liveStream == nil else { return }
        await deactivate()
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        await windDown()
        yieldUpdate(.status(.ended))
        updatesContinuation.finish()
        latencyContinuation.finish()
        leakedEnvironmentContinuation.finish()
    }

    private func yieldUpdate(_ update: HerdrCoreHostSessionUpdate) {
        if case .status(let status) = update {
            isAnnouncedConnected = status == .connected
            if status != .connected {
                latencyBox.withLock { $0 = nil }
                routeIDBox.withLock { $0 = nil }
                leakedEnvironmentBox.withLock { $0 = [] }
            }
        }
        guard case .dropped = updatesContinuation.yield(update) else { return }
        _ = updatesContinuation.yield(.event(.dropped))
    }

    private func enqueueLifecycleTransition(_ transition: @escaping @Sendable () async -> Void) async {
        let previous = lifecycleTransition
        let task = Task {
            await previous?.value
            await transition()
        }
        lifecycleTransition = task
        await task.value
    }

    // MARK: The link

    private func run(generation: UInt64) async {
        var attempt = 0
        /// Links in a row that ended before anything arrived on them. One is a
        /// core restarting; more would be a hot loop without a backoff.
        var silentLinkEnds = 0
        /// One holder window per outage: a socket file left behind by a crash
        /// would otherwise add it to every retry.
        var mayAwaitHolder = true
        while activationIsCurrent(generation) {
            let transport: any HerdrCoreTransport
            let stream: HerdrCoreEventStream
            let coreID: String
            do {
                transport = try await ensureTransport(for: generation)
                let info = try await hello(on: transport, generation: generation, awaitingHolder: mayAwaitHolder)
                guard activationIsCurrent(generation) else { break }
                if !isAnnouncedConnected {
                    let latency = try await measureLatency(on: transport)
                    guard activationIsCurrent(generation) else { break }
                    latencyBox.withLock { $0 = latency }
                    latencyContinuation.yield()
                    routeIDBox.withLock { $0 = transport.routeID }
                    yieldUpdate(.status(.connected))
                }
                checkLeakedEnvironment(on: transport, generation: generation)
                stream = try await transport.subscribeEvents()
                coreID = info.coreID
            } catch {
                guard activationIsCurrent(generation) else { break }
                let failure = Self.transportFailure(error)
                if failure == .timedOut { transportSuspect = true }
                if case .herdrCoreNotRunning = failure { mayAwaitHolder = false }
                guard failure.isRetryable else {
                    yieldUpdate(.status(.failed(failure)))
                    return
                }
                attempt += 1
                await emitReconnectingAndBackOff(attempt: attempt, failure: failure, generation: generation)
                continue
            }
            guard activationIsCurrent(generation) else {
                await stream.end()
                break
            }
            mayAwaitHolder = true
            liveStream = stream
            pendingKeepaliveFailure = nil
            hasTrafficSinceLastKeepalive = false
            yieldUpdate(.snapshot(stream.snapshot, coreID: coreID))
            startKeepalive(stream: stream, transport: transport)

            var linkCarriedTraffic = false
            var streamFailure: TransportError?
            do {
                for try await event in stream.events {
                    guard activationIsCurrent(generation) else { break }
                    hasTrafficSinceLastKeepalive = true
                    linkCarriedTraffic = true
                    switch event {
                    case .heartbeat:
                        break
                    case .dropped, .unknown:
                        // Deltas can no longer be trusted: start over from a snapshot.
                        resubscribeRequested = true
                        await stream.end()
                    default:
                        yieldUpdate(.event(event))
                    }
                }
            } catch {
                streamFailure = Self.transportFailure(error)
            }
            if liveStream === stream {
                stopKeepalive()
                liveStream = nil
            }
            guard activationIsCurrent(generation) else { break }
            if resubscribeRequested {
                resubscribeRequested = false
                continue
            }
            if linkCarriedTraffic { attempt = 0 }
            silentLinkEnds = linkCarriedTraffic ? 0 : silentLinkEnds + 1
            if let keepaliveFailure = pendingKeepaliveFailure {
                pendingKeepaliveFailure = nil
                attempt += 1
                await emitReconnectingAndBackOff(attempt: attempt, failure: keepaliveFailure, generation: generation)
                continue
            }
            let failure = streamFailure ?? .channelFailed(detail: "The herdr-core link closed.")
            guard failure.isRetryable else {
                yieldUpdate(.status(.failed(failure)))
                return
            }
            if !transportSuspect, await transport.isConnected, silentLinkEnds < 2 { continue }
            attempt += 1
            await emitReconnectingAndBackOff(attempt: attempt, failure: failure, generation: generation)
        }
    }

    /// Asked after every `hello`; the transport runs the exec once per link. The
    /// connection neither waits for the answer nor depends on it. Not cancelled:
    /// its own deadlines bound it, and the generation makes a late answer harmless.
    private func checkLeakedEnvironment(on transport: any HerdrCoreTransport, generation: UInt64) {
        Task { [weak self] in
            guard let names = await transport.leakedEnvironmentNames() else { return }
            await self?.publishLeakedEnvironment(names, generation: generation)
        }
    }

    private func publishLeakedEnvironment(_ names: Set<String>, generation: UInt64) {
        guard activationIsCurrent(generation), isAnnouncedConnected else { return }
        leakedEnvironmentBox.withLock { $0 = names }
        leakedEnvironmentContinuation.yield()
    }

    /// The core's `hello`. A channel refused with the socket file present may
    /// be a core its holder is about to restart, so it is polled before the
    /// failure is believed. A missing socket file reads not running at once.
    private func hello(
        on transport: any HerdrCoreTransport, generation: UInt64, awaitingHolder: Bool
    ) async throws -> HerdrCoreServerInfo {
        do {
            return try await transport.hello()
        } catch TransportError.herdrCoreNotRunning(socketPath: let path, socketFilePresent: true) where awaitingHolder {
            for _ in 0..<holderRestart.polls {
                try await sleep(holderRestart.pollInterval)
                guard activationIsCurrent(generation) else { throw TransportError.cancelled }
                do {
                    return try await transport.helloAtLastLocation()
                } catch TransportError.herdrCoreNotRunning(socketPath: _, socketFilePresent: true) {
                    continue
                }
            }
            throw TransportError.herdrCoreNotRunning(socketPath: path, socketFilePresent: true)
        }
    }

    private func ensureTransport(for generation: UInt64) async throws -> any HerdrCoreTransport {
        if let transport = currentTransport {
            if !transportSuspect, await transport.isConnected { return transport }
            currentTransport = nil
            isAnnouncedConnected = false
            try? await transport.close()
        }
        let transport = try await connect()
        guard activationIsCurrent(generation) else {
            try? await transport.close()
            throw TransportError.cancelled
        }
        transportSuspect = false
        currentTransport = transport
        if hasEstablishedConnection {
            generationBox.withLock { $0 &+= 1 }
        } else {
            hasEstablishedConnection = true
        }
        return transport
    }

    private func activationIsCurrent(_ generation: UInt64) -> Bool {
        phase == .active && activationGeneration == generation && !Task.isCancelled
    }

    private func emitReconnectingAndBackOff(
        attempt: Int, failure: TransportError, generation: UInt64
    ) async {
        let delay = reconnectPolicy.delay(beforeAttempt: attempt)
        yieldUpdate(.status(.reconnecting(attempt: attempt, delay: delay, failure: failure)))
        let backoff = Task { [sleep] in try await sleep(delay) }
        backoffSleep = backoff
        backoffGeneration = generation
        try? await backoff.value
        if backoffGeneration == generation {
            backoffSleep = nil
            backoffGeneration = nil
        }
    }

    /// Ends the activation and closes everything. The run task is cancelled but
    /// not awaited, since a stalled SSH operation may ignore cancellation;
    /// generation checks make any late result harmless.
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
        await stream?.end()
        if let transport = currentTransport {
            currentTransport = nil
            try? await transport.close()
        }
        transportSuspect = false
        pendingKeepaliveFailure = nil
        resubscribeRequested = false
    }

    // MARK: Keepalive

    /// Each interval must have carried a line, and the core sends a heartbeat
    /// every 15 seconds, so a silent interval is a lost link. `server.status`
    /// then proves channel 0 as well and measures the round trip.
    private func startKeepalive(stream: HerdrCoreEventStream, transport: any HerdrCoreTransport) {
        guard let keepalive else { return }
        keepaliveTask = Task { [sleep] in
            while !Task.isCancelled {
                do { try await sleep(keepalive.interval) } catch { break }
                if Task.isCancelled { break }
                guard await self.takeTraffic() else {
                    await self.keepaliveDidFail(.timedOut, on: stream)
                    break
                }
                do {
                    let latency = try await self.measureLatency(on: transport)
                    guard await self.publishLatency(latency, measuredOn: stream) else { break }
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

    private func takeTraffic() -> Bool {
        defer { hasTrafficSinceLastKeepalive = false }
        return hasTrafficSinceLastKeepalive
    }

    @discardableResult
    private func publishLatency(_ latency: Duration, measuredOn stream: HerdrCoreEventStream) -> Bool {
        guard phase == .active, liveStream === stream else { return false }
        latencyBox.withLock { $0 = latency }
        latencyContinuation.yield()
        return true
    }

    private func measureLatency(on transport: any HerdrCoreTransport) async throws -> Duration {
        let started = ContinuousClock.now
        _ = try await transport.serverStatus()
        return started.duration(to: .now)
    }

    private func keepaliveDidFail(_ failure: TransportError, on stream: HerdrCoreEventStream) async {
        guard phase == .active, liveStream === stream else { return }
        transportSuspect = true
        pendingKeepaliveFailure = failure
        await stream.end()
    }

    /// Its own mapping: a core asking for an update is never retried, and a
    /// mutation's unknown outcome is never read as a broken link.
    private static func transportFailure(_ error: any Error) -> TransportError {
        if let failure = error as? TransportError { return failure }
        if error is HerdrCoreUpdateRequired {
            return .herdrCoreUpdateRequired(command: "herdr-core update")
        }
        if let rejection = error as? HerdrAPIError {
            return .apiRejected(code: rejection.code, message: rejection.message)
        }
        if case DeviceKeyStoreError.storedKeyCorrupt = error { return .deviceKeyCorrupt }
        if case RSAKeyStoreError.storedKeyCorrupt = error { return .rsaKeyCorrupt }
        return .channelFailed(detail: String(describing: error))
    }
}
