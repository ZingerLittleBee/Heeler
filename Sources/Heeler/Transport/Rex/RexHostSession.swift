import Foundation
import Synchronization

/// One element of a Rex Host session's update stream, in the order it happened.
enum RexHostSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    /// The server that answers: once per connection. Another instance is
    /// another server, and whatever was known of the last one is void.
    case server(RexServerStatus)
    /// Every terminal the server lists: once after each `server`, and again
    /// each time something changed (ADR 0048).
    case inventory(RexInventory)
}

/// What a Rex Host's live connection is, for whatever runs on it.
struct RexConnection: Sendable {
    let transport: any RexTransport
    let control: RexControlLink
    /// Advances with each new SSH connection.
    let generation: UInt64
    let server: RexServerStatus
}

/// Owns a Rex Host's connection (ADRs 0047 and 0048), as `TmuxHostSession`
/// owns a tmux Host's. It reuses `EventsSession`'s reconnect policy and status,
/// and suspends and resumes with the app the same way.
///
/// Connected means a Rex server answered `server.status` on the control link.
/// While one does, a `RexInventoryFollower` follows its inventory on that
/// link. A link that drops without a close frame leaves its client with the
/// server for a while: the next link says hello with its reconnect token, on
/// the same SSH connection when that is still up and over a new one when it is
/// not. Either way events sent in between are lost, so every new link reads
/// the inventory again. A link the server closed is followed by a plain hello,
/// unless it closed with 1001, as Rex does for a client that stopped answering
/// its pings and still keeps: that one is resumed as a dropped one is.
///
/// Suspending drops the link without a close frame, so a quick return may
/// take the client back; ending closes it with one, so the server forgets
/// this client at once. Connecting never starts a server.
actor RexHostSession {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    /// Dials the Host: the socket to try first, and a link whose client the
    /// new one should take back.
    typealias Connect = @Sendable (_ socket: RexSocket?, _ resuming: RexControlLink?) async throws -> any RexTransport

    private enum Phase {
        case suspended, active, ended
    }

    /// Statuses, servers and inventories in order. Finishes after `end()`.
    nonisolated let updates: AsyncStream<RexHostSessionUpdate>
    private let updatesContinuation: AsyncStream<RexHostSessionUpdate>.Continuation
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

    private let connect: Connect
    private let reconnectPolicy: ReconnectPolicy
    private let revalidateDeadline: Duration
    /// How long a follow that read the inventory must last before its end is
    /// retried at once, so a server that closes every link right after the
    /// reads meets the usual backoff instead of a tight loop.
    private let healthyFollowLife: Duration
    private let maxReadsInFlight: Int
    private let sleep: Sleep

    private var phase: Phase = .suspended
    /// The socket the next connection tries: the catalog's, then whatever a
    /// connection found.
    private var socket: RexSocket?
    private var transport: (any RexTransport)?
    private var link: RexControlLink?
    /// A link dropped without a close frame, whose client the server may
    /// still keep for the next hello to take back.
    private var resumable: RexControlLink?
    /// A stalled read or a failed revalidation leaves the SSH connection in
    /// doubt, so the next attempt dials.
    private var transportSuspect = false
    private var hasEstablishedConnection = false
    private var liveServer: RexServerStatus?
    private var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var waitSleep: Task<Void, any Error>?
    private var lifecycleTransition: Task<Void, Never>?
    /// Which follow may publish, so a late inventory from one that stopped is
    /// dropped, and what the last one published, whose details the next one
    /// starts from.
    private final class Follows: Sendable {
        let run = Mutex<UInt64>(0)
        let lastInventory = Mutex<RexInventory?>(nil)

        func stopAll() {
            run.withLock { $0 &+= 1 }
        }
    }

    private nonisolated let follows = Follows()

    /// `connect` dials the Host; `storedSocket` is the catalog's.
    init(
        storedSocket: RexSocket?,
        connect: @escaping Connect,
        reconnectPolicy: ReconnectPolicy = .default,
        revalidateDeadline: Duration = .seconds(5),
        healthyFollowLife: Duration = .seconds(10),
        maxReadsInFlight: Int = 4,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        socket = storedSocket
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.revalidateDeadline = revalidateDeadline
        self.healthyFollowLife = healthyFollowLife
        self.maxReadsInFlight = maxReadsInFlight
        self.sleep = sleep
        (updates, updatesContinuation) = AsyncStream.makeStream(of: RexHostSessionUpdate.self)
        (latencyUpdates, latencyContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Lifecycle

    /// Activates the session, initially or after `suspend()`. No-op while
    /// active or ended.
    func resume() async {
        await enqueueLifecycleTransition { await self.activate() }
    }

    /// Restarts the activation, for a stopped run or a user's Retry.
    func retry() async {
        await enqueueLifecycleTransition { await self.restart() }
    }

    /// Asks the server that was answering, on a foreground return. A link that
    /// does not answer in time is dropped for a new one at once.
    func revalidate() async {
        guard phase == .active, liveServer != nil, let link else { return }
        let deadline = revalidateDeadline
        Task { [weak self] in
            do {
                _ = try await link.call("server.status", deadline: deadline)
            } catch {
                await self?.dropInDoubt(link)
            }
        }
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

    /// Runs `operation` on the live connection. Throws while no server answers.
    func withConnection<Value: Sendable>(
        _ operation: @Sendable (RexConnection) async throws -> Value
    ) async throws -> Value {
        guard phase == .active, let transport, let link, let liveServer, !transportSuspect else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        return try await operation(
            RexConnection(
                transport: transport, control: link, generation: currentConnectionGeneration, server: liveServer))
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
        await windDown(forGood: false)
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
        await windDown(forGood: false)
        yieldStatus(.suspended)
    }

    private func stopConnecting() async {
        guard liveServer == nil else { return }
        await deactivate()
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        await windDown(forGood: true)
        yieldStatus(.ended)
        updatesContinuation.finish()
        latencyContinuation.finish()
    }

    private func yieldStatus(_ status: EventsSessionStatus) {
        if status != .connected {
            follows.stopAll()
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
            var retryAtOnce = false
            do {
                let (transport, link) = try await ensureLink(for: generation)
                let started = ContinuousClock.now
                let status = try await link.call("server.status")
                let server = try RexServerStatus(reading: try status.result(JSONValue.self))
                guard activationIsCurrent(generation) else { break }
                announce(server, latency: started.duration(to: .now), routeID: transport.routeID)
                let followed = ContinuousClock.now
                let follow = await follow(link)
                guard activationIsCurrent(generation) else { break }
                // A follow that read the inventory and lasted was healthy: its
                // end is news, and the next link is tried at once.
                if follow.published, followed.duration(to: .now) >= healthyFollowLife {
                    attempt = 0
                    retryAtOnce = true
                }
                failure = await settle(link, after: follow.ending)
            } catch {
                guard activationIsCurrent(generation) else { break }
                failure = await settleFailedAttempt(error)
            }
            guard failure.isRetryable else {
                yieldStatus(.failed(failure))
                return
            }
            attempt += 1
            let delay = retryAtOnce ? Duration.zero : reconnectPolicy.delay(beforeAttempt: attempt)
            yieldStatus(.reconnecting(attempt: attempt, delay: delay, failure: failure))
            if delay > .zero { try? await wait(delay) }
        }
    }

    private func announce(_ server: RexServerStatus, latency: Duration, routeID: UUID?) {
        latencyBox.withLock { $0 = latency }
        routeIDBox.withLock { $0 = routeID }
        let previous = liveServer
        liveServer = server
        if previous == nil { updatesContinuation.yield(.status(.connected)) }
        if previous != server { updatesContinuation.yield(.server(server)) }
        latencyContinuation.yield()
    }

    /// Follows the inventory on `link` until the follow ends.
    private func follow(_ link: RexControlLink) async -> (ending: RexInventoryFollower.Ending, published: Bool) {
        let run = follows.run.withLock {
            $0 &+= 1
            return $0
        }
        let carried = follows.lastInventory.withLock { $0?.details } ?? [:]
        let follower = RexInventoryFollower(
            link: link, carrying: carried, maxReadsInFlight: maxReadsInFlight
        ) { [updatesContinuation, follows] inventory in
            guard follows.run.withLock({ $0 == run }) else { return }
            follows.lastInventory.withLock { $0 = inventory }
            updatesContinuation.yield(.inventory(inventory))
        }
        let ending = await follower.run()
        return (ending, await follower.hasPublished)
    }

    /// Leaves `link` ready for the next attempt to resume or replace, and says
    /// what to show meanwhile.
    private func settle(_ link: RexControlLink, after ending: RexInventoryFollower.Ending) async -> TransportError {
        switch ending {
        case .linkEnded(let reason):
            // A link dropped here on purpose was already marked for resuming.
            if reason.mayResume { resumable = link }
            return TransportError(rexControl: .linkEnded(reason))
        case .stalled:
            await dropInDoubt(link)
            return .timedOut
        case .refused(let failure):
            if resumable === link { resumable = nil }
            await link.close()
            return failure
        case .cancelled:
            return .cancelled
        }
    }

    /// An attempt that failed before following: a link that dropped or stalled
    /// on its way is kept to resume.
    private func settleFailedAttempt(_ error: any Error) async -> TransportError {
        if let link {
            switch error {
            case RexControlError.deadlineExceeded:
                await dropInDoubt(link)
            case RexControlError.linkEnded(let reason) where reason.mayResume:
                resumable = link
            default:
                break
            }
        }
        return Self.transportFailure(error)
    }

    /// Drops a link that did not answer in time without a close frame, so its
    /// client can be taken back, and dials again rather than trust the SSH
    /// connection under it.
    private func dropInDoubt(_ link: RexControlLink) async {
        guard self.link === link else { return }
        resumable = link
        transportSuspect = true
        await link.disconnect()
    }

    /// The link to follow on: the one in hand while it is open, else a new one
    /// on the same SSH connection while that is up and trusted, else a new
    /// connection. A new link takes back the client of one dropped without a
    /// close frame.
    private func ensureLink(for generation: UInt64) async throws -> (any RexTransport, RexControlLink) {
        if let transport, !transportSuspect, await transport.isConnected {
            if let link, await link.isOpen { return (transport, link) }
            let resuming = resumable != nil && resumable === link
            resumable = nil
            let fresh = try await transport.reconnectControl(resuming: resuming)
            guard activationIsCurrent(generation) else {
                await fresh.close()
                throw TransportError.cancelled
            }
            link = fresh
            return (transport, fresh)
        }
        if let transport {
            self.transport = nil
            link = nil
            // A link kept to resume is dropped, so closing sends no close frame.
            if let resumable { await resumable.disconnect() }
            await transport.close()
        }
        let previous = resumable
        resumable = nil
        let fresh: any RexTransport
        do {
            fresh = try await connect(socket, previous)
        } catch {
            resumable = previous
            throw error
        }
        let control = await fresh.control
        guard activationIsCurrent(generation) else {
            await fresh.close()
            throw TransportError.cancelled
        }
        socket = fresh.socket
        transport = fresh
        link = control
        transportSuspect = false
        if hasEstablishedConnection {
            generationBox.withLock { $0 &+= 1 }
        } else {
            hasEstablishedConnection = true
        }
        return (fresh, control)
    }

    private func wait(_ duration: Duration) async throws {
        let pause = Task { [sleep] in try await sleep(duration) }
        waitSleep = pause
        defer { if waitSleep == pause { waitSleep = nil } }
        try await pause.value
    }

    private func activationIsCurrent(_ generation: UInt64) -> Bool {
        phase == .active && activationGeneration == generation && !Task.isCancelled
    }

    /// Ends the activation and closes the connection. For good, the link
    /// closes with a close frame so the server forgets this client; otherwise
    /// it drops without one, to be resumed. The run task is cancelled but not
    /// awaited, since a stalled SSH operation may ignore cancellation;
    /// generation checks make any late result harmless.
    private func windDown(forGood: Bool) async {
        waitSleep?.cancel()
        waitSleep = nil
        let task = runTask
        runTask = nil
        task?.cancel()
        follows.stopAll()
        liveServer = nil
        if let transport {
            self.transport = nil
            let control = await transport.control
            if forGood {
                resumable = nil
            } else {
                if await control.isOpen { await control.disconnect() }
                resumable = control
            }
            await transport.close()
        } else if forGood {
            resumable = nil
        }
        link = nil
        transportSuspect = false
    }

    private static func transportFailure(_ error: any Error) -> TransportError {
        if let failure = error as? TransportError { return failure }
        if let failure = error as? RexControlError { return TransportError(rexControl: failure) }
        if error is CancellationError { return .cancelled }
        if case DeviceKeyStoreError.storedKeyCorrupt = error { return .deviceKeyCorrupt }
        if case RSAKeyStoreError.storedKeyCorrupt = error { return .rsaKeyCorrupt }
        return .channelFailed(detail: String(describing: error))
    }
}
