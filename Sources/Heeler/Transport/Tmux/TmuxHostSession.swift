import Foundation
import Synchronization

/// One element of a tmux Host session's update stream, in the order it happened.
enum TmuxHostSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    /// The server that answers and the paths that reached it: once per
    /// connection, and again whenever either changed. Another instance is
    /// another server, and whatever was known of the last one is void.
    case server(TmuxServerStatus)
    /// A connection resolved the Host's tmux paths again, for the catalog to keep.
    case paths(TmuxPaths)
    /// Every pane the server lists: once after each `server`, and again each
    /// time something changed (ADR 0043).
    case inventory(TmuxInventory)
}

/// Owns a tmux Host's connection, as `HerdrCoreHostSession` owns a herdr-core
/// Host's link. It reuses `EventsSession`'s reconnect and keepalive policies and
/// status, and suspends and resumes with the app the same way.
///
/// Connected means a tmux server answered on the Host's socket. A Host with no
/// server running stays retryable with backoff, on the SSH connection it has;
/// a missing or too old tmux is never retried. Every ask carries `-N`, so
/// nothing here ever starts a server (ADR 0042).
///
/// While a server answers, one long exec follows its inventory (ADR 0043). A
/// loop that ends, as it does when its server stops, is followed by an ask of
/// the server, and the next answer starts another.
actor TmuxHostSession {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private enum Phase {
        case suspended, active, ended
    }

    /// Statuses, servers and paths in order. Finishes after `end()`.
    nonisolated let updates: AsyncStream<TmuxHostSessionUpdate>
    private let updatesContinuation: AsyncStream<TmuxHostSessionUpdate>.Continuation
    /// A signal that `currentLatency` holds a new sample.
    nonisolated let latencyUpdates: AsyncStream<Void>
    private let latencyContinuation: AsyncStream<Void>.Continuation
    /// Written before the status that makes it observable, and cleared before
    /// any status that ends a connection, as `EventsSession.currentLatency` is.
    nonisolated var currentLatency: Duration? { latencyBox.withLock { $0 } }
    private nonisolated let latencyBox = Mutex<Duration?>(nil)
    nonisolated var currentRouteID: UUID? { routeIDBox.withLock { $0 } }
    private nonisolated let routeIDBox = Mutex<UUID?>(nil)
    /// Advances with each new SSH connection.
    nonisolated var currentConnectionGeneration: UInt64 { generationBox.withLock { $0 } }
    private nonisolated let generationBox = Mutex<UInt64>(0)

    private let connect: @Sendable (TmuxPaths?) async throws -> any TmuxTransport
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?
    /// A loop that ran this long was following its server, and its end is news.
    private let settledLoopLife: Duration
    private let sleep: Sleep

    /// The paths the next connection starts from: the catalog's, then whatever
    /// a connection resolved since.
    private nonisolated let storedPaths: Mutex<TmuxPaths?>
    private var phase: Phase = .suspended
    private var currentTransport: (any TmuxTransport)?
    private var hasEstablishedConnection = false
    /// A timed-out ask leaves the connection in doubt, so the next attempt dials.
    private var transportSuspect = false
    private var liveServer: TmuxServerStatus?
    /// The loop following the server's inventory, and which start of it this is.
    private var inventoryTask: Task<Void, Never>?
    private var inventoryRun: UInt64 = 0
    private var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var waitSleep: Task<Void, any Error>?
    private var lifecycleTransition: Task<Void, Never>?

    /// `connect` dials the Host with the paths to ask first; `storedPaths` are
    /// the catalog's.
    init(
        storedPaths: TmuxPaths?,
        connect: @escaping @Sendable (TmuxPaths?) async throws -> any TmuxTransport,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default,
        settledLoopLife: Duration = .seconds(2),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.storedPaths = Mutex(storedPaths)
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.keepalive = keepalive
        self.settledLoopLife = settledLoopLife
        self.sleep = sleep
        (updates, updatesContinuation) = AsyncStream.makeStream(of: TmuxHostSessionUpdate.self)
        (latencyUpdates, latencyContinuation) = AsyncStream.makeStream(
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

    /// Asks a server that was answering, on a foreground return. A failed ask
    /// goes down the keepalive's path at once instead of at its next interval.
    func revalidate() async {
        guard phase == .active, liveServer != nil else { return }
        waitSleep?.cancel()
    }

    /// Takes the connection down until `resume()`.
    func suspend() async {
        await enqueueLifecycleTransition { await self.deactivate() }
    }

    /// Stops an attempt in flight or its backoff. A server that answers is left alone.
    func cancelConnecting() async {
        await enqueueLifecycleTransition { await self.stopConnecting() }
    }

    func end() async {
        await enqueueLifecycleTransition { await self.finish() }
    }

    /// The catalog's paths moved without this session, as Host detail's checks
    /// move them. The connection in use keeps its own.
    nonisolated func adoptStoredPaths(_ paths: TmuxPaths?) {
        storedPaths.withLock { $0 = paths }
    }

    /// Runs one call on the installed transport, whatever became of the server.
    func withTransport<Value: Sendable>(
        _ operation: @Sendable (any TmuxTransport) async throws -> Value
    ) async throws -> Value {
        guard let currentTransport else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        return try await operation(currentTransport)
    }

    private func activate() {
        guard phase == .suspended else { return }
        phase = .active
        startRun()
    }

    private func restart() async {
        guard phase == .active else {
            activate()
            return
        }
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldStatus(.connecting)
        await windDown()
        guard phase == .active, activationGeneration == generation else { return }
        runTask = Task { await self.run(generation: generation) }
    }

    private func startRun() {
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldStatus(.connecting)
        runTask = Task { await self.run(generation: generation) }
    }

    private func deactivate() async {
        guard phase == .active else { return }
        phase = .suspended
        await windDown()
        yieldStatus(.suspended)
    }

    private func stopConnecting() async {
        guard liveServer == nil else { return }
        await deactivate()
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        await windDown()
        yieldStatus(.ended)
        updatesContinuation.finish()
        latencyContinuation.finish()
    }

    private func yieldStatus(_ status: EventsSessionStatus) {
        if status != .connected {
            stopInventory()
            liveServer = nil
            latencyBox.withLock { $0 = nil }
            routeIDBox.withLock { $0 = nil }
        }
        updatesContinuation.yield(.status(status))
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

    // MARK: The connection

    private func run(generation: UInt64) async {
        var attempt = 0
        while activationIsCurrent(generation) {
            let failure: TransportError
            do {
                let transport = try await ensureTransport(for: generation)
                let started = ContinuousClock.now
                let asked = await Self.ask(transport)
                let resolved = await transport.resolvedPaths()
                guard activationIsCurrent(generation) else { break }
                // A tmux that moved is where the next connection must look,
                // whether or not its server answers.
                if let resolved, storedPaths.withLock({ $0 != resolved }) {
                    storedPaths.withLock { $0 = resolved }
                    updatesContinuation.yield(.paths(resolved))
                }
                switch asked {
                case .success(let server):
                    attempt = 0
                    announce(server, latency: started.duration(to: .now), routeID: transport.routeID)
                    followInventory(on: transport, generation: generation)
                    try await waitForNextAsk()
                    continue
                case .failure(let error):
                    failure = error
                }
            } catch {
                guard activationIsCurrent(generation) else { break }
                failure = Self.transportFailure(error)
            }
            if failure == .timedOut { transportSuspect = true }
            guard failure.isRetryable else {
                yieldStatus(.failed(failure))
                return
            }
            attempt += 1
            let delay = reconnectPolicy.delay(beforeAttempt: attempt)
            yieldStatus(.reconnecting(attempt: attempt, delay: delay, failure: failure))
            try? await wait(delay)
        }
    }

    private static func ask(_ transport: any TmuxTransport) async -> Result<TmuxServerStatus, TransportError> {
        do {
            return .success(try await transport.status())
        } catch {
            return .failure(transportFailure(error))
        }
    }

    private func announce(_ server: TmuxServerStatus, latency: Duration, routeID: UUID?) {
        latencyBox.withLock { $0 = latency }
        routeIDBox.withLock { $0 = routeID }
        let previous = liveServer
        liveServer = server
        if previous == nil { updatesContinuation.yield(.status(.connected)) }
        if previous != server {
            // Another server, or other paths to it: the loop that ran is not its.
            stopInventory()
            updatesContinuation.yield(.server(server))
        }
        latencyContinuation.yield()
    }

    // MARK: Inventory

    /// Starts the loop unless one runs. A loop that cannot start is tried
    /// again at the next ask.
    private func followInventory(on transport: any TmuxTransport, generation: UInt64) {
        guard inventoryTask == nil else { return }
        inventoryRun &+= 1
        let run = inventoryRun
        inventoryTask = Task { [weak self, settledLoopLife] in
            let started = ContinuousClock.now
            var listed = false
            do {
                for try await inventory in try await transport.inventory() {
                    guard await self?.noteInventory(inventory, run: run, generation: generation) == true
                    else { return }
                    listed = true
                }
            } catch {}
            let lasted = started.duration(to: .now) >= settledLoopLife
            await self?.inventoryEnded(run: run, asksAtOnce: listed && lasted)
        }
    }

    private func noteInventory(_ inventory: TmuxInventory, run: UInt64, generation: UInt64) -> Bool {
        guard run == inventoryRun, inventoryTask != nil, activationIsCurrent(generation), liveServer != nil
        else { return false }
        updatesContinuation.yield(.inventory(inventory))
        return true
    }

    /// A loop that followed the server and then ended says something happened
    /// to it: the server is asked at once. One that listed nothing, or ended
    /// as soon as it started, waits for the next ask, so a Host that refuses
    /// the exec or ends it is not asked in a spin.
    private func inventoryEnded(run: UInt64, asksAtOnce: Bool) {
        guard run == inventoryRun, inventoryTask != nil else { return }
        inventoryTask = nil
        if asksAtOnce { waitSleep?.cancel() }
    }

    private func stopInventory() {
        inventoryTask?.cancel()
        inventoryTask = nil
    }

    /// The pause between two asks of a server that answers, which a
    /// revalidation cuts short. Without a keepalive only that asks again.
    private func waitForNextAsk() async throws {
        try? await wait(keepalive?.interval ?? .seconds(60 * 60 * 24 * 365))
        try Task.checkCancellation()
    }

    private func wait(_ duration: Duration) async throws {
        let pause = Task { [sleep] in try await sleep(duration) }
        waitSleep = pause
        defer { if waitSleep == pause { waitSleep = nil } }
        try await pause.value
    }

    private func ensureTransport(for generation: UInt64) async throws -> any TmuxTransport {
        if let transport = currentTransport {
            if !transportSuspect, await transport.isConnected { return transport }
            currentTransport = nil
            try? await transport.close()
        }
        let transport = try await connect(storedPaths.withLock { $0 })
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

    /// Ends the activation and closes the connection. The run task is cancelled
    /// but not awaited, since a stalled SSH operation may ignore cancellation;
    /// generation checks make any late result harmless.
    private func windDown() async {
        waitSleep?.cancel()
        waitSleep = nil
        let task = runTask
        runTask = nil
        task?.cancel()
        stopInventory()
        liveServer = nil
        if let transport = currentTransport {
            currentTransport = nil
            try? await transport.close()
        }
        transportSuspect = false
    }

    private static func transportFailure(_ error: any Error) -> TransportError {
        if let failure = error as? TransportError { return failure }
        if error is CancellationError { return .cancelled }
        if case DeviceKeyStoreError.storedKeyCorrupt = error { return .deviceKeyCorrupt }
        if case RSAKeyStoreError.storedKeyCorrupt = error { return .rsaKeyCorrupt }
        return .channelFailed(detail: String(describing: error))
    }
}
