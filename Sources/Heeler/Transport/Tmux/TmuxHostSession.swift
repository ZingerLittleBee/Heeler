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
    /// time something changed (ADR 0045).
    case inventory(TmuxInventory)
    /// Leaked names from `show-environment`, after the inventory's user
    /// sessions are known. A failed read yields nothing, so nothing new is shown.
    case environment(Set<String>)
}

/// Owns a tmux Host's connection, as `HerdrCoreHostSession` owns a herdr-core
/// Host's link. It reuses `EventsSession`'s reconnect and keepalive policies and
/// status, and suspends and resumes with the app the same way.
///
/// Connected means a tmux server answered on the Host's socket. A Host with no
/// server running stays retryable with backoff, on the SSH connection it has;
/// a missing or too old tmux is never retried. Every ask carries `-N`, so
/// nothing here ever starts a server (ADR 0044).
///
/// While a server answers, one long exec follows its inventory (ADR 0045). A
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
    /// `uname -s` from the latest probe, written before the status or server update that publishes it.
    nonisolated var currentKernel: String? { kernelBox.withLock { $0 } }
    private nonisolated let kernelBox = Mutex<String?>(nil)

    private let connect: @Sendable (TmuxPaths?) async throws -> any TmuxTransport
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?
    /// A loop that ran this long was following its server, and its end is news.
    private let settledLoopLife: Duration
    private let sleep: Sleep

    /// The paths the next connection starts from: the catalog's, then whatever
    /// a connection resolved since.
    private nonisolated let storedPaths: Mutex<TmuxPaths?>
    private nonisolated let pendingAdoptedPaths = Mutex<TmuxPaths??>(nil)
    private var phase: Phase = .suspended
    private var currentTransport: (any TmuxTransport)?
    private var hasEstablishedConnection = false
    /// A timed-out ask leaves the connection in doubt, so the next attempt dials.
    private var transportSuspect = false
    private var liveServer: TmuxServerStatus?
    /// The loop following the server's inventory, and which start of it this is.
    private var inventoryTask: Task<Void, Never>?
    private var inventoryTransport: (any TmuxTransport)?
    private var inventoryRun: UInt64 = 0
    /// The environment read in flight, and the one that succeeded, so a later
    /// inventory of the same user sessions does not ask again. A failure leaves
    /// the success empty, and the next inventory retries.
    private var environmentTask: Task<Void, Never>?
    private var environmentToken: UInt64 = 0
    private var environmentFlight: (server: TmuxServerInstance, sessions: Set<String>)?
    private var environmentRead: (server: TmuxServerInstance, sessions: Set<String>)?
    /// The server instance whose leftover unattached `@heeler-attach` sessions
    /// have been checked on this connection, or whose retry budget ran out.
    private static let maxLeftoverCleanupAttempts = 3
    private var leftoverCleanupTask: Task<Void, Never>?
    private var leftoverCleanupToken: UInt64 = 0
    private var leftoverCleanupFlight: TmuxServerInstance?
    private var leftoverCleanupChecked: TmuxServerInstance?
    private var leftoverCleanupFailures: (server: TmuxServerInstance, count: Int)?
    private var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var waitSleep: Task<Void, any Error>?
    private var immediateAskRequested = false
    private var lifecycleTransition: Task<Void, Never>?
    /// Attaches waiting for a server to answer on a connection.
    private var attachWaiters: [AttachWaiter] = []
    /// Why the run stopped for good, for an Attach asked after it did.
    private var attachFailure: TransportError?

    private struct AttachWaiter {
        let id: UUID
        /// The activation it was asked in; nil when asked while suspended.
        let activationGeneration: UInt64?
        let continuation: CheckedContinuation<AttachTransport, any Error>
    }

    /// What an Attach runs on: the transport, its connection's generation, and
    /// the server that answered on it.
    typealias AttachTransport = (transport: any TmuxTransport, generation: UInt64, server: TmuxServerStatus)

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

    /// Asks the Host's server at once on the connection in hand, after Heeler's
    /// own launch started one without waiting out backoff or a stopped run.
    func askNow() async {
        await enqueueLifecycleTransition { await self.wakeForServer() }
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
    /// move them. A connection with no answering server adopts them too, while a
    /// live server keeps the paths it answered on.
    nonisolated func adoptStoredPaths(_ paths: TmuxPaths?) {
        storedPaths.withLock { $0 = paths }
        pendingAdoptedPaths.withLock { $0 = .some(paths) }
    }

    /// Runs one call on the installed transport, whatever became of the server.
    func withTransport<Value: Sendable>(
        _ operation: @Sendable (any TmuxTransport) async throws -> Value
    ) async throws -> Value {
        guard let currentTransport else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        await applyPendingAdoptedPaths(to: currentTransport)
        return try await operation(currentTransport)
    }

    private func applyPendingAdoptedPaths(to transport: any TmuxTransport) async {
        guard let adopted = pendingAdoptedPaths.withLock({
            defer { $0 = nil }
            return $0
        }) else { return }
        guard liveServer == nil else { return }
        await transport.adoptStoredPaths(adopted)
    }

    /// Runs an Attach once a server answers on the connection (ADR 0045),
    /// waiting through a reconnect. Throws when the session ends, or its run
    /// stops for good, before one does. A connection the Attach finds closed
    /// is asked again at once, on a new one, rather than handed out.
    func withAttachTransport<Value: Sendable>(
        _ operation: @Sendable (AttachTransport) async throws -> Value
    ) async throws -> Value {
        while true {
            let ready = try await awaitAttachTransport()
            if await ready.transport.isConnected { return try await operation(ready) }
            connectionClosed(generation: ready.generation)
        }
    }

    private func connectionClosed(generation: UInt64) {
        guard generation == currentConnectionGeneration, currentTransport != nil, !transportSuspect else { return }
        transportSuspect = true
        waitSleep?.cancel()
    }

    /// Attaches waiting for a server, which tests wait on.
    var attachWaiterCount: Int { attachWaiters.count }

    private func awaitAttachTransport() async throws -> AttachTransport {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if phase == .ended {
                    continuation.resume(throwing: TransportError.cancelled)
                } else if phase == .active, let ready = readyAttachTransport {
                    continuation.resume(returning: ready)
                } else if phase == .active, let attachFailure {
                    continuation.resume(throwing: attachFailure)
                } else {
                    attachWaiters.append(
                        AttachWaiter(
                            id: id, activationGeneration: phase == .active ? activationGeneration : nil,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelAttachWaiter(id) }
        }
    }

    private var readyAttachTransport: AttachTransport? {
        guard let currentTransport, let liveServer, !transportSuspect else { return nil }
        return (currentTransport, currentConnectionGeneration, liveServer)
    }

    private func cancelAttachWaiter(_ id: UUID) {
        guard let index = attachWaiters.firstIndex(where: { $0.id == id }) else { return }
        attachWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeAttachWaiters() {
        guard let ready = readyAttachTransport else { return }
        let waiters = attachWaiters
        attachWaiters = []
        for waiter in waiters {
            if let asked = waiter.activationGeneration, asked != activationGeneration {
                waiter.continuation.resume(throwing: TransportError.cancelled)
            } else {
                waiter.continuation.resume(returning: ready)
            }
        }
    }

    /// Those asked in an activation that is going away get nothing from it.
    /// One asked while suspended waits on for the next activation.
    private func failPinnedAttachWaiters(_ failure: TransportError) {
        let pinned = attachWaiters.filter { $0.activationGeneration != nil }
        attachWaiters.removeAll { $0.activationGeneration != nil }
        for waiter in pinned { waiter.continuation.resume(throwing: failure) }
    }

    private func failAttachWaiters(_ failure: TransportError) {
        let waiters = attachWaiters
        attachWaiters = []
        for waiter in waiters { waiter.continuation.resume(throwing: failure) }
    }

    private func activate() {
        guard phase == .suspended else { return }
        phase = .active
        attachFailure = nil
        immediateAskRequested = false
        startRun()
    }

    private func restart() async {
        guard phase == .active else {
            activate()
            return
        }
        attachFailure = nil
        immediateAskRequested = false
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldStatus(.connecting)
        await windDown()
        guard phase == .active, activationGeneration == generation else { return }
        runTask = Task { await self.run(generation: generation) }
    }

    private func wakeForServer() {
        guard phase == .active else { return }
        if attachFailure != nil || runTask == nil {
            attachFailure = nil
            immediateAskRequested = false
            waitSleep?.cancel()
            waitSleep = nil
            runTask?.cancel()
            runTask = nil
            startRun()
            return
        }
        immediateAskRequested = true
        waitSleep?.cancel()
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
        failPinnedAttachWaiters(.cancelled)
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
        failAttachWaiters(.cancelled)
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
        defer { if activationGeneration == generation { runTask = nil } }
        var attempt = 0
        while activationIsCurrent(generation) {
            let failure: TransportError
            do {
                let transport = try await ensureTransport(for: generation)
                immediateAskRequested = false
                let started = ContinuousClock.now
                let asked = await Self.ask(transport)
                if let kernel = await transport.hostFacts().kernel {
                    kernelBox.withLock { $0 = kernel }
                }
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
                attachFailure = failure
                failAttachWaiters(failure)
                yieldStatus(.failed(failure))
                return
            }
            if immediateAskRequested {
                immediateAskRequested = false
                continue
            }
            attempt += 1
            let delay = reconnectPolicy.delay(beforeAttempt: attempt)
            yieldStatus(.reconnecting(attempt: attempt, delay: delay, failure: failure))
            try? await wait(delay)
        }
    }

    private static func ask(_ transport: any TmuxTransport) async -> Result<TmuxServerStatus, TransportError> {
        do {
            try Task.checkCancellation()
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
        resumeAttachWaiters()
    }

    // MARK: Inventory

    /// Starts the loop unless one runs. A loop that cannot start is tried
    /// again at the next ask.
    private func followInventory(on transport: any TmuxTransport, generation: UInt64) {
        guard inventoryTask == nil else { return }
        inventoryRun &+= 1
        let run = inventoryRun
        inventoryTransport = transport
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
        guard run == inventoryRun, inventoryTask != nil, activationIsCurrent(generation),
            let current = liveServer
        else { return false }
        if let instance = inventory.instance, instance != current.instance {
            let replaced = TmuxServerStatus(instance: instance, version: current.version, paths: current.paths)
            liveServer = replaced
            environmentToken &+= 1
            environmentTask?.cancel()
            environmentTask = nil
            environmentFlight = nil
            environmentRead = nil
            resetLeftoverCleanup()
            updatesContinuation.yield(.server(replaced))
        }
        updatesContinuation.yield(.inventory(inventory))
        considerEnvironment(of: inventory, generation: generation)
        considerLeftoverAttachCleanup(of: inventory, generation: generation)
        return true
    }

    /// Asks `show-environment` once the user sessions are known, and again when
    /// that set changes. Heeler's own sessions are not part of it. The ask does
    /// not block the inventory loop.
    private func considerEnvironment(of inventory: TmuxInventory, generation: UInt64) {
        guard let server = liveServer, let transport = inventoryTransport else { return }
        let sessions = Set(inventory.panes.filter { !$0.isInHeelerSession }.map(\.sessionID))
        let key = (server: server.instance, sessions: sessions)
        if environmentRead?.server == key.server, environmentRead?.sessions == key.sessions { return }
        if environmentFlight?.server == key.server, environmentFlight?.sessions == key.sessions { return }
        environmentToken &+= 1
        let token = environmentToken
        environmentTask?.cancel()
        environmentFlight = key
        let paths = server.paths
        environmentTask = Task { [weak self] in
            let reading = await Self.loadEnvironment(sessions: sessions, paths: paths, on: transport)
            await self?.noteEnvironment(
                reading, token: token, key: key, generation: generation)
        }
    }

    private func noteEnvironment(
        _ reading: Set<String>?, token: UInt64,
        key: (server: TmuxServerInstance, sessions: Set<String>), generation: UInt64
    ) {
        guard token == environmentToken, activationIsCurrent(generation), liveServer?.instance == key.server
        else { return }
        environmentFlight = nil
        guard let reading else { return }
        environmentRead = key
        updatesContinuation.yield(.environment(reading))
    }

    /// Nil when an ask failed. The caller retries on a later inventory and shows
    /// nothing for this one, as an unreadable core environment shows no notice.
    private static func loadEnvironment(
        sessions: Set<String>, paths: TmuxPaths, on transport: any TmuxTransport
    ) async -> Set<String>? {
        guard let global = await scope(TmuxLaunch.showEnvironment(paths: paths), on: transport) else { return nil }
        var deltas: [String: TmuxEnvironment.Scope] = [:]
        for id in sessions.sorted() {
            guard let delta = await scope(TmuxLaunch.showEnvironment(session: id, paths: paths), on: transport)
            else { return nil }
            deltas[id] = delta
        }
        return TmuxEnvironment.reading(global: global, sessions: deltas)
    }

    private static func scope(
        _ command: TmuxLaunch.Command, on transport: any TmuxTransport
    ) async -> TmuxEnvironment.Scope? {
        guard !Task.isCancelled else { return nil }
        let result: GitExecResult
        do { result = try await transport.runTmuxScript(command.script, throughLoginShell: false) } catch { return nil }
        guard result.exitStatus == 0 else { return nil }
        return TmuxEnvironment.parse(result.stdout)
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
        inventoryTransport = nil
        environmentToken &+= 1
        environmentTask?.cancel()
        environmentTask = nil
        environmentFlight = nil
        environmentRead = nil
        resetLeftoverCleanup()
    }

    private func resetLeftoverCleanup() {
        leftoverCleanupToken &+= 1
        leftoverCleanupTask?.cancel()
        leftoverCleanupTask = nil
        leftoverCleanupFlight = nil
        leftoverCleanupChecked = nil
        leftoverCleanupFailures = nil
    }

    /// Ends leftover unattached `@heeler-attach` sessions (such as from a
    /// Host-side `SIGKILL` of an earlier Attach's wrapper, feeder and `tmux -C`
    /// together) once per connection and server instance once it succeeds,
    /// without blocking the inventory loop and running nothing when no
    /// `@heeler-attach` session is listed. A failed cleanup exec retries on a
    /// later inventory up to `maxLeftoverCleanupAttempts` so it never loops. A
    /// brief pause lets any concurrent detached-to-attached startup attach
    /// before tmux checks `#{session_attached} == 0` and `@heeler-attach`.
    private func considerLeftoverAttachCleanup(of inventory: TmuxInventory, generation: UInt64) {
        guard let server = liveServer, let transport = inventoryTransport else { return }
        if leftoverCleanupChecked == server.instance { return }
        if leftoverCleanupFlight == server.instance { return }
        let sessions = Set(inventory.panes.filter(\.isInHeelerSession).map(\.sessionID)).sorted()
        guard !sessions.isEmpty else {
            leftoverCleanupChecked = server.instance
            leftoverCleanupFailures = nil
            return
        }
        leftoverCleanupToken &+= 1
        let token = leftoverCleanupToken
        leftoverCleanupTask?.cancel()
        leftoverCleanupFlight = server.instance
        let instance = server.instance
        let paths = server.paths
        leftoverCleanupTask = Task { [weak self, sleep] in
            do {
                try await sleep(.milliseconds(100))
            } catch {
                await self?.clearLeftoverCleanupFlight(token: token)
                return
            }
            guard !Task.isCancelled,
                await self?.canCleanLeftovers(for: instance, generation: generation, token: token) == true
            else {
                await self?.clearLeftoverCleanupFlight(token: token)
                return
            }
            var succeeded = true
            for session in sessions {
                guard !Task.isCancelled else {
                    await self?.clearLeftoverCleanupFlight(token: token)
                    return
                }
                guard let command = TmuxLaunch.endUnattachedAttachSession(
                    id: session, instance: instance, paths: paths)
                else { continue }
                if !(await Self.cleanLeftoverAttachSession(command, on: transport)) {
                    succeeded = false
                }
            }
            await self?.noteLeftoverAttachCleanup(
                succeeded: succeeded, token: token, instance: instance, generation: generation)
        }
    }

    private func clearLeftoverCleanupFlight(token: UInt64) {
        guard token == leftoverCleanupToken else { return }
        leftoverCleanupFlight = nil
        leftoverCleanupTask = nil
    }

    private func noteLeftoverAttachCleanup(
        succeeded: Bool, token: UInt64, instance: TmuxServerInstance, generation: UInt64
    ) {
        guard token == leftoverCleanupToken else { return }
        leftoverCleanupFlight = nil
        leftoverCleanupTask = nil
        guard activationIsCurrent(generation), liveServer?.instance == instance else { return }
        if succeeded {
            leftoverCleanupChecked = instance
            leftoverCleanupFailures = nil
            return
        }
        let count = (leftoverCleanupFailures?.server == instance ? leftoverCleanupFailures?.count ?? 0 : 0) + 1
        leftoverCleanupFailures = (server: instance, count: count)
        if count >= Self.maxLeftoverCleanupAttempts {
            leftoverCleanupChecked = instance
        }
    }

    private static func cleanLeftoverAttachSession(
        _ command: TmuxLaunch.Command, on transport: any TmuxTransport
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let result: GitExecResult
        do {
            result = try await transport.runTmuxScript(
                command.script, throughLoginShell: command.throughLoginShell)
        } catch {
            return false
        }
        if result.exitStatus == 0 { return true }
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        return stderr.contains("can't find session:") || stderr.contains("can't find target:")
    }

    private func canCleanLeftovers(
        for instance: TmuxServerInstance, generation: UInt64, token: UInt64
    ) -> Bool {
        token == leftoverCleanupToken && activationIsCurrent(generation)
            && liveServer?.instance == instance && currentTransport != nil
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
            if !transportSuspect, await transport.isConnected {
                await applyPendingAdoptedPaths(to: transport)
                return transport
            }
            currentTransport = nil
            try? await transport.close()
        }
        pendingAdoptedPaths.withLock { $0 = nil }
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
