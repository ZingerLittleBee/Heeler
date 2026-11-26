import Foundation
import HeelerSSH
import Synchronization

/// One element of a Rex Host session's update stream, in the order it happened.
enum RexHostSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    /// The server that answers: once per connection. Another instance is
    /// another server, and whatever was known of the last one is void.
    case server(RexServerStatus)
    /// Every terminal the server lists: once after each `server`, and again
    /// each time something changed (ADR 0050).
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

/// Owns a Rex Host's connection (ADRs 0049 and 0050), as `TmuxHostSession`
/// owns a tmux Host's. It reuses `EventsSession`'s reconnect policy and status,
/// and suspends and resumes with the app the same way.
///
/// Connected means a Rex server answered `server.status` on the control link.
/// While one does, a `RexInventoryFollower` follows its inventory on that
/// link. A link that drops without a close frame leaves its client with the
/// server for a while: the next link says hello with its reconnect token, on
/// the same SSH connection when that is still up and over a new one when it is
/// not, unless that client opened a terminal's data link (ADR 0051). Either
/// way events sent in between are lost, so every new link reads the inventory
/// again. A link the server closed is followed by a plain hello, unless it
/// closed with 1001, as Rex does for a client that stopped answering its pings
/// and still keeps: that one is resumed as a dropped one is.
///
/// Suspending, once the app's grace period ran out, and ending leave on
/// purpose: open terminals end their data links with a close frame, then the
/// control link closes with one, so the server forgets this client at once,
/// and only then does the SSH connection go. A link meant to be taken back,
/// one that dropped or one a restart replaces, goes without a close frame.
/// Connecting never starts a server.
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
    /// dropped, and what the last one published and on which server
    /// instance, whose details the next one on the same instance starts from.
    /// `lineage` is the last server and the sessions it listed, which say
    /// whether the next instance restored them.
    private final class Follows: Sendable {
        let run = Mutex<UInt64>(0)
        let lastInventory = Mutex<(instanceID: String, inventory: RexInventory)?>(nil)
        let lineage = Mutex<RexServerLineage?>(nil)

        func stopAll() {
            run.withLock { $0 &+= 1 }
        }
    }

    private nonisolated let follows = Follows()

    // Terminals (ADR 0051).
    private nonisolated let terminals = RexTerminalHub()
    private let terminalOptions: RexTerminalAttach.Options
    private let terminalSleep: RexTerminalStream.Sleep
    /// How long leaving on purpose waits for open terminals to close their
    /// data links before the SSH connection goes anyway.
    private let terminalEndingGrace: Duration
    private struct ConnectionWaiter {
        let id: UUID
        /// The activation it was asked in; nil when asked while suspended,
        /// which waits on for the next activation.
        let activationGeneration: UInt64?
        let continuation: CheckedContinuation<RexConnection, any Error>
    }
    private var connectionWaiters: [ConnectionWaiter] = []
    /// Why the run stopped for good, for terminals that ask meanwhile.
    private var connectionFailure: TransportError?
    /// Advances with each new control client, one that did not resume the
    /// last: its attachments are the server's to forget.
    private var clientEpoch: UInt64 = 0
    /// The client epoch each session was attached in with `session.attach`.
    private var attachedSessions: [String: UInt64] = [:]
    /// New Workspace's blocks whose session could not be attached, so their
    /// give back waits for the session's next attach on the same client.
    private var unreturnedCreatedBlocks: [RexPaneAddress: UInt64] = [:]
    /// The control client asked for a data channel. An SSH connection that
    /// died half-open can leave its data links open on the server, which then
    /// refuses that client another link to the same block until it notices,
    /// minutes later. So a new SSH connection does not take this client back.
    private var clientOpenedDataLinks = false
    /// The control link open terminals are on, and its SSH connection.
    private var terminalLink: RexControlLink?
    private var terminalLinkGeneration: UInt64?
    /// What each block's attaches claimed of its size and have not given
    /// back, with the client epoch they claimed it in (ADR 0053). It outlives
    /// the attach, so a give back that could not go out before an attach
    /// ended is made by the next attach of the block on the same client, or
    /// here once a link takes the client back. A new client claims nothing.
    private final class SizeClaims: Sendable {
        private let claims = Mutex<[RexPaneAddress: (epoch: UInt64, claim: RexSizeClaim)]>([:])

        func claim(at address: RexPaneAddress, epoch: UInt64) -> RexSizeClaim? {
            claims.withLock { $0[address] }.flatMap { $0.epoch == epoch ? $0.claim : nil }
        }

        /// A newer client's claim is never replaced by an older one's.
        func note(_ claim: RexSizeClaim?, at address: RexPaneAddress, epoch: UInt64) {
            claims.withLock { claims in
                guard (claims[address]?.epoch ?? 0) <= epoch else { return }
                claims[address] = claim.map { (epoch: epoch, claim: $0) }
            }
        }

        /// A block the server handed over stays this client's only while no
        /// other client owns it: once its owner changes to another client or
        /// to none, as when the one whose link dropped resumes, the claim is
        /// a place in line, given back as a size this client took and no
        /// longer kept from the next showing's take. An open attach of the
        /// block hears the change itself; this keeps the claim right when
        /// none is open.
        func ownerChanged(_ update: RexControlUpdate, client: String?) {
            guard case .event(let event) = update, let sessionID = event.sessionID,
                case .blockOwnerChanged(let blockID, let owner, _, _) = event.body,
                owner == nil || owner != client
            else { return }
            let address = RexPaneAddress(sessionID: sessionID, blockID: blockID)
            claims.withLock { claims in
                guard let held = claims[address], held.claim == .handed else { return }
                claims[address] = (epoch: held.epoch, claim: .taken)
            }
        }

        func taken(epoch: UInt64) -> [RexPaneAddress] {
            claims.withLock { claims in
                claims.compactMap { $0.value.epoch == epoch && $0.value.claim == .taken ? $0.key : nil }
            }
        }

        func clear() {
            claims.withLock { $0 = [:] }
        }
    }

    private nonisolated let sizeClaims = SizeClaims()
    /// Each block's input lane, shared by its open terminal's input and
    /// Chat's (ADR 0055).
    private nonisolated let blockLanes = RexBlockLanes()
    /// Blocks a terminal holds a data stream for, and those waiting to.
    private var heldBlocks: Set<RexPaneAddress> = []
    private var blockWaiters: [RexPaneAddress: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]] =
        [:]

    /// `connect` dials the Host; `storedSocket` is the catalog's.
    init(
        storedSocket: RexSocket?,
        connect: @escaping Connect,
        reconnectPolicy: ReconnectPolicy = .default,
        revalidateDeadline: Duration = .seconds(5),
        healthyFollowLife: Duration = .seconds(10),
        maxReadsInFlight: Int = 4,
        terminalOptions: RexTerminalAttach.Options = RexTerminalAttach.Options(),
        terminalSleep: @escaping RexTerminalStream.Sleep = { try await Task.sleep(for: $0) },
        terminalEndingGrace: Duration = .seconds(3),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        socket = storedSocket
        self.connect = connect
        self.reconnectPolicy = reconnectPolicy
        self.revalidateDeadline = revalidateDeadline
        self.healthyFollowLife = healthyFollowLife
        self.maxReadsInFlight = maxReadsInFlight
        self.terminalOptions = terminalOptions
        self.terminalSleep = terminalSleep
        self.terminalEndingGrace = terminalEndingGrace
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

    /// Bounded probe deadline after an OS network path change.
    static let networkChangeProbeTimeout: Duration = .seconds(3)

    /// Asks the server that was answering, on a foreground return or network
    /// change. A link that stays silent for `silence` before the answer, or
    /// brings no answer in half a minute however much else arrives, is dropped
    /// for a new one at once. The answer may queue behind a redraw's pages,
    /// which keep the link from going silent.
    func revalidate(timeout: Duration? = nil) async {
        guard phase == .active, liveServer != nil, let link else { return }
        let silence = timeout ?? revalidateDeadline
        let deadline = RexDeliveryDeadline(silence: silence, limit: max(silence, .seconds(30)))
        Task { [weak self] in
            do {
                _ = try await link.call("server.status", payload: JSONValue?.none, waiting: deadline)
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
        connectionFailure = nil
        startRun()
    }

    private func restart() async {
        guard phase == .active else {
            activate()
            return
        }
        connectionFailure = nil
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldStatus(.connecting)
        await windDown(leaving: false, abandon: true)
        guard phase == .active, activationGeneration == generation else { return }
        runTask = Task { await self.run(generation: generation) }
    }

    private func startRun() {
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldStatus(.connecting)
        runTask = Task { await self.run(generation: generation) }
    }

    /// Suspending comes once the app's grace period ran out, and every
    /// terminal on the Host ends with it: nothing is left for the server to
    /// keep, so the client leaves as on ending, and a resume says hello afresh.
    private func deactivate() async {
        guard phase == .active else { return }
        phase = .suspended
        failPinnedConnectionWaiters(.cancelled)
        await windDown(leaving: true)
        yieldStatus(.suspended)
    }

    private func stopConnecting() async {
        guard liveServer == nil else { return }
        await deactivate()
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        failConnectionWaiters(.cancelled)
        await windDown(leaving: true)
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
                let server = try await identify(
                    RexServerStatus(reading: try status.result(JSONValue.self)), on: link)
                guard activationIsCurrent(generation) else { break }
                await settleTerminals(on: link, server: server)
                guard activationIsCurrent(generation) else { break }
                announce(server, latency: started.duration(to: .now), routeID: transport.routeID)
                let followed = ContinuousClock.now
                let follow = await follow(link, server: server)
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
                connectionFailure = failure
                failConnectionWaiters(failure)
                yieldStatus(.failed(failure))
                return
            }
            attempt += 1
            let delay = retryAtOnce ? Duration.zero : reconnectPolicy.delay(beforeAttempt: attempt)
            yieldStatus(.reconnecting(attempt: attempt, delay: delay, failure: failure))
            if delay > .zero { try? await wait(delay) }
        }
    }

    /// What this device knew of the Host's server before this session, from
    /// an earlier run, for the first instance to continue. A session that
    /// already followed one keeps its own.
    nonisolated func seedLineage(_ lineage: RexServerLineage?) {
        follows.lineage.withLock { if $0 == nil { $0 = lineage } }
    }

    /// The server `answered` is (ADR 0050). The instance the last link
    /// reached continues its core. Another instance continues it only when
    /// it sees the same files and lists one of the sessions the last one
    /// listed, as a server restored from its saved sessions does; it is asked
    /// for its list only then. Any other is another server, with a core of
    /// its own.
    private func identify(_ answered: RexServerStatus, on link: RexControlLink) async throws -> RexServerStatus {
        var server = answered
        var listed: [String] = []
        if let last = follows.lineage.withLock({ $0 }) {
            if last.instanceID == answered.instanceID {
                server = answered.continuing(last.coreID)
                listed = last.sessionIDs
            } else if last.mayContinue(in: answered) {
                let ids = try await listedSessionIDs(on: link)
                if last.isContinued(byListing: ids) {
                    server = answered.continuing(last.coreID)
                    listed = ids
                }
            }
        }
        follows.lineage.withLock { $0 = RexServerLineage(server, sessionIDs: listed) }
        return server
    }

    /// The ids `session.list` names. A server that refuses the list, or
    /// answers in a way Heeler cannot read, says nothing of what it restored.
    private func listedSessionIDs(on link: RexControlLink) async throws -> [String] {
        do {
            let response = try await link.call("session.list")
            return RexInventoryWire.sessions(try response.result(JSONValue.self))?.map(\.id) ?? []
        } catch RexControlError.server(_), RexControlError.unreadableResult(_) {
            return []
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
        resumeConnectionWaiters()
    }

    /// Follows the inventory on `link` until the follow ends. Each update
    /// reaches the open terminals too, before the inventory applies it.
    /// Another server instance's details say nothing of this one's terminals,
    /// whose ids may repeat, so only the same instance's are carried.
    private func follow(_ link: RexControlLink, server: RexServerStatus) async
        -> (ending: RexInventoryFollower.Ending, published: Bool)
    {
        let run = follows.run.withLock {
            $0 &+= 1
            return $0
        }
        let carried =
            follows.lastInventory.withLock { last in
                last.flatMap { $0.instanceID == server.instanceID ? $0.inventory.details : nil }
            } ?? [:]
        let client = link.clientID
        let follower = RexInventoryFollower(
            link: link, carrying: carried, maxReadsInFlight: maxReadsInFlight,
            observe: { [follows, terminals, sizeClaims] update in
                guard follows.run.withLock({ $0 == run }) else { return }
                sizeClaims.ownerChanged(update, client: client)
                terminals.observe(update)
            }
        ) { [updatesContinuation, follows] inventory in
            guard follows.run.withLock({ $0 == run }) else { return }
            follows.lastInventory.withLock { $0 = (server.instanceID, inventory) }
            follows.lineage.withLock { $0 = RexServerLineage(server, sessionIDs: inventory.sessions.map(\.id)) }
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
    /// close frame, except across SSH connections once that client opened a
    /// data link: the new connection then starts a new client, whose terminals
    /// attach again and paint afresh, as they would after the resume anyway.
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
            await transport.abandon()
        }
        let previous = clientOpenedDataLinks ? nil : resumable
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

    /// Ends the activation and closes the connection. Leaving on purpose,
    /// open terminals end their data links with a close frame while the SSH
    /// connection under them is still up, waiting for them no longer than
    /// `terminalEndingGrace`, and the control link closes with one, so the
    /// server forgets this client. Otherwise the link drops without one, to
    /// be resumed. The run task is cancelled but not awaited, since a stalled
    /// SSH operation may ignore cancellation; generation checks make any late
    /// result harmless.
    private func windDown(leaving: Bool, abandon: Bool = false) async {
        waitSleep?.cancel()
        waitSleep = nil
        let task = runTask
        runTask = nil
        task?.cancel()
        follows.stopAll()
        liveServer = nil
        // Every data link rides the SSH connection going down here.
        terminals.resetAll()
        if let transport {
            self.transport = nil
            let control = await transport.control
            if leaving {
                resumable = nil
                await letOpenTerminalsEnd()
            } else {
                if await control.isOpen { await control.disconnect() }
                resumable = control
            }
            if abandon {
                await transport.abandon()
            } else {
                await transport.close()
            }
        } else if leaving {
            resumable = nil
        }
        link = nil
        transportSuspect = false
    }

    /// Waits for the open terminals, which heard their connection is going,
    /// to close their data links, for up to `terminalEndingGrace`: one whose
    /// SSH connection is dead may never finish its close frame.
    private func letOpenTerminalsEnd() async {
        guard terminals.openTerminalCount > 0 else { return }
        let terminals = terminals
        let grace = terminalEndingGrace
        let sleep = sleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await terminals.untilNoneOpen() }
            group.addTask { try? await sleep(grace) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Terminals

    /// Runs one terminal's attach on `address` (ADR 0051), once a server
    /// answers, waiting through a reconnect. Throws when the session ends, or
    /// its run stops for good, before one does.
    ///
    /// One data stream per block per client: an attach waits here until the
    /// block's last one has ended, so two views, or a quick close and reopen,
    /// never ask for a second while the first is open. Its connection hears
    /// the block's events and what becomes of the link until it returns.
    func withTerminal<Value: Sendable>(
        _ address: RexPaneAddress, _ operation: @Sendable (RexTerminalConnection) async throws -> Value
    ) async throws -> Value {
        try await holdBlock(address)
        defer { releaseBlock(address) }
        while true {
            let ready = try await awaitConnection()
            guard await ready.transport.isConnected else {
                connectionClosed(generation: ready.generation)
                continue
            }
            let (id, signals) = terminals.subscribe(address, server: ready.server)
            defer { terminals.unsubscribe(id) }
            let epoch = clientEpoch
            let connection = RexTerminalConnection(
                address: address, server: ready.server, generation: ready.generation,
                clientID: ready.control.clientID, signals: signals,
                route: terminalRoute(server: ready.server, generation: ready.generation),
                options: terminalOptions, sleep: terminalSleep,
                attachSession: { [weak self] in
                    guard let self else { throw RexTerminalEnding.connectionReset }
                    try await self.attachSession(address.sessionID, server: ready.server, generation: ready.generation)
                },
                forgetAttachment: { [weak self] in
                    await self?.forgetAttachment(address.sessionID)
                },
                call: { [weak self] method, payload in
                    guard let self else { throw RexTerminalEnding.connectionReset }
                    let control = try await self.terminalControl(server: ready.server, generation: ready.generation)
                    _ = try await control.call(method, payload: payload)
                },
                deliver: { [weak self] method, payload, deadline in
                    guard let self else { return .notSent }
                    return await self.deliverTerminalRequest(
                        method, payload: payload, deadline: deadline, server: ready.server,
                        generation: ready.generation, epoch: epoch)
                },
                maxMessageBytes: ready.control.maxMessageBytes,
                lanes: blockLanes,
                sizeClaim: sizeClaims.claim(at: address, epoch: epoch),
                noteSizeClaim: { [sizeClaims] claim in sizeClaims.note(claim, at: address, epoch: epoch) },
                isCurrent: { [weak self] in
                    await self?.connectionIsCurrent(server: ready.server, generation: ready.generation, epoch: epoch)
                        ?? false
                })
            return try await operation(connection)
        }
    }

    /// Chat's requests to the block at `address` (ADR 0055), pinned to the
    /// server, SSH connection and control client that answer now, as an open
    /// terminal's are. Reads wait for their answer as long as `readDeadline`
    /// allows; input waits as long as a terminal's. Throws while no server
    /// answers: it never waits for one.
    func blockRequests(at address: RexPaneAddress, readDeadline: RexDeliveryDeadline) throws -> RexBlockRequests {
        guard let ready = readyConnection else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        let server = ready.server
        let generation = ready.generation
        let epoch = clientEpoch
        let inputDeadline = terminalOptions.inputDeadline
        return RexBlockRequests(
            address: address, server: server, maxMessageBytes: ready.control.maxMessageBytes, lanes: blockLanes,
            ask: { [weak self] method, payload in
                guard let self else { throw TransportError.cancelled }
                return try await self.askBlock(
                    method, payload: payload, deadline: readDeadline, server: server, generation: generation,
                    epoch: epoch)
            },
            deliver: { [weak self] method, payload in
                guard let self else { return .notSent }
                return await self.deliverTerminalRequest(
                    method, payload: payload, deadline: inputDeadline, server: server, generation: generation,
                    epoch: epoch)
            })
    }

    /// New Terminal's write (ADR 0049's update of 2026-11-25): a shell block
    /// in a new window of `placement`'s session, or in a new session, on the
    /// live control link. It never waits for a server, and a request that
    /// left is never sent again, so one with no answer may still have made
    /// its terminal. The window is not made active, and the block is given
    /// back at once, as a size this client took is (ADR 0053), or, in a new
    /// session the client could not attach, once that session is attached:
    /// the view that opens it takes its size as it takes any other terminal's.
    func createTerminal(_ placement: RexNewTerminal.Placement, cwd: String?) async throws -> RexNewTerminal.Created {
        guard let ready = readyConnection else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        let control = ready.control
        let epoch = clientEpoch
        let created: RexNewTerminal.Created
        do {
            switch placement {
            case .window(let sessionID):
                try await attachForCreating(sessionID, on: control)
                let response = try await control.call(
                    RexNewTerminal.newWindowMethod, payload: RexNewTerminal.newWindowPayload(in: sessionID, cwd: cwd))
                created = try RexNewTerminal.newWindow(in: sessionID, from: response.result(JSONValue.self))
            case .session(let label):
                let response = try await control.call(
                    RexNewTerminal.newSessionMethod, payload: RexNewTerminal.newSessionPayload(label: label, cwd: cwd))
                created = try RexNewTerminal.newSession(from: response.result(JSONValue.self))
                // The session is made, so a failed attach never fails the
                // request. Rex refuses a give back from a client not attached
                // to the session, so the block of one whose attach failed is
                // kept as a size this client took: the next attach of its
                // session or of the block, or a link that takes the client
                // back, gives it back. Another attach now would only add its
                // deadline to New Workspace's wait.
                let sessionID = created.address.sessionID
                if (try? await attachForCreating(sessionID, on: control)) == nil {
                    // What the old client claimed went with it.
                    guard clientEpoch == epoch else { return created }
                    sizeClaims.note(.taken, at: created.address, epoch: epoch)
                    unreturnedCreatedBlocks[created.address] = epoch
                    // Another request may have attached the session while this
                    // one waited, past its own look for blocks to give back,
                    // and on the link that took the client back if this one ended.
                    if attachedSessions[sessionID] == epoch, let live = readyConnection?.control {
                        giveBackLeftSizes(inSession: sessionID, on: live)
                    }
                    return created
                }
            }
        } catch let error as RexControlError {
            throw RexNewTerminal.failure(error)
        }
        _ = await control.deliver(
            RexTerminalAttach.giveBackMethod, payload: RexTerminalAttach.ownershipPayload(created.address, take: false),
            deadline: terminalOptions.giveBackDeadline)
        return created
    }

    /// Attaches the control client to `sessionID`, as Rex asks of a client
    /// acting on a session. An attach with no answer comes before a new
    /// window's request leaves, so it says nothing was made.
    private func attachForCreating(_ sessionID: String, on control: RexControlLink) async throws {
        do {
            try await attachSession(sessionID, on: control)
        } catch RexTerminalEnding.finished {
            throw TransportError.rexRejected(
                code: "session_not_found",
                message: String(localized: "This Workspace is no longer on the Rex server."))
        } catch is RexTerminalEnding {
            throw RexNewTerminal.notSent
        }
    }

    /// One read of Chat's, on the live control link while it is still the
    /// one the read was pinned to. Another server is gone for good; another
    /// connection or client says the one it read on went, as does another
    /// instance of the same server.
    private func askBlock(
        _ method: String, payload: JSONValue, deadline: RexDeliveryDeadline, server: RexServerStatus,
        generation: UInt64, epoch: UInt64
    ) async throws -> JSONValue {
        guard let ready = readyConnection else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        guard ready.server.isSameServer(as: server) else { throw TransportError.rexServerGone }
        guard ready.server == server, ready.generation == generation, clientEpoch == epoch else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        let response = try await ready.control.call(method, payload: payload, waiting: deadline)
        return try response.result(JSONValue.self)
    }

    /// Terminals open now, which tests wait on.
    var openTerminalCount: Int { terminals.openTerminalCount }

    /// Input waiting for the block's lane, which tests wait on.
    nonisolated func inputWaiting(at address: RexPaneAddress) -> Int {
        blockLanes.waiting(at: address)
    }

    /// Terminals waiting for a server, which tests wait on.
    var terminalWaiterCount: Int { connectionWaiters.count }

    private func connectionClosed(generation: UInt64) {
        guard generation == currentConnectionGeneration, transport != nil, !transportSuspect else { return }
        transportSuspect = true
    }

    /// Whether a server answers on `server`, `generation` and the client of
    /// `epoch` now.
    private func connectionIsCurrent(server: RexServerStatus, generation: UInt64, epoch: UInt64) -> Bool {
        guard let ready = readyConnection else { return false }
        return ready.server == server && ready.generation == generation && clientEpoch == epoch
    }

    private var readyConnection: RexConnection? {
        guard phase == .active, let transport, let link, let liveServer, !transportSuspect else { return nil }
        return RexConnection(transport: transport, control: link, generation: currentConnectionGeneration, server: liveServer)
    }

    private func awaitConnection() async throws -> RexConnection {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if phase == .ended {
                    continuation.resume(throwing: TransportError.cancelled)
                } else if let ready = readyConnection {
                    continuation.resume(returning: ready)
                } else if phase == .active, let connectionFailure {
                    continuation.resume(throwing: connectionFailure)
                } else {
                    connectionWaiters.append(
                        ConnectionWaiter(
                            id: id, activationGeneration: phase == .active ? activationGeneration : nil,
                            continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelConnectionWaiter(id) }
        }
    }

    private func cancelConnectionWaiter(_ id: UUID) {
        guard let index = connectionWaiters.firstIndex(where: { $0.id == id }) else { return }
        connectionWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func resumeConnectionWaiters() {
        guard let ready = readyConnection else { return }
        let waiters = connectionWaiters
        connectionWaiters = []
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
    private func failPinnedConnectionWaiters(_ failure: TransportError) {
        let pinned = connectionWaiters.filter { $0.activationGeneration != nil }
        connectionWaiters.removeAll { $0.activationGeneration != nil }
        for waiter in pinned { waiter.continuation.resume(throwing: failure) }
    }

    private func failConnectionWaiters(_ failure: TransportError) {
        let waiters = connectionWaiters
        connectionWaiters = []
        for waiter in waiters { waiter.continuation.resume(throwing: failure) }
    }

    /// A new control link answered for `server`, before anyone else hears of
    /// it. Open terminals carry on over a link that took back their client on
    /// their SSH connection, whose attachments and data streams the server
    /// kept, and a size an ended attach could not give back goes back now.
    /// Otherwise they end, to open afresh, and a client the server does not
    /// know is attached again to each session they were open in; what the
    /// old client claimed went with it.
    private func settleTerminals(on link: RexControlLink, server: RexServerStatus) async {
        guard link !== terminalLink else { return }
        let generation = currentConnectionGeneration
        let fresh = !link.resumed
        let carriesOn = !fresh && terminalLinkGeneration == generation
        terminalLink = link
        terminalLinkGeneration = generation
        if fresh {
            clientEpoch &+= 1
            clientOpenedDataLinks = false
            sizeClaims.clear()
            unreturnedCreatedBlocks = [:]
        }
        terminals.linkChanged(to: server, carriesOn: carriesOn)
        guard fresh else {
            giveBackLeftSizes(server: server, generation: generation)
            return
        }
        for sessionID in terminals.openSessions(on: server).sorted() {
            try? await attachSession(sessionID, on: link)
        }
    }

    /// Each size an attach took and could not give back before it ended goes
    /// back once on the link that took the client back, unless an attach of
    /// the block that holds it now gives it back first. One whose give back
    /// is not sent, or has no answer, waits for the next attach of the block
    /// or the next resume.
    private func giveBackLeftSizes(server: RexServerStatus, generation: UInt64) {
        let epoch = clientEpoch
        for address in sizeClaims.taken(epoch: epoch) {
            Task { await self.giveBackLeftSize(address, server: server, generation: generation, epoch: epoch) }
        }
    }

    /// Waits for the block's attach, if one holds it, and holds the block
    /// while its size goes back, so no attach of it takes the size meanwhile.
    /// It goes through the same gate as a view's give back: only on the live
    /// link of the client that claimed it.
    private func giveBackLeftSize(
        _ address: RexPaneAddress, server: RexServerStatus, generation: UInt64, epoch: UInt64
    ) async {
        do { try await holdBlock(address) } catch { return }
        defer { releaseBlock(address) }
        guard sizeClaims.claim(at: address, epoch: epoch) == .taken else { return }
        // Rex answers a give back only from a client attached to the session.
        do { try await attachSession(address.sessionID, server: server, generation: generation) } catch { return }
        let delivery = await deliverTerminalRequest(
            RexTerminalAttach.giveBackMethod, payload: RexTerminalAttach.ownershipPayload(address, take: false),
            deadline: terminalOptions.giveBackDeadline, server: server, generation: generation, epoch: epoch)
        switch delivery {
        case .answered, .refused:
            sizeClaims.note(nil, at: address, epoch: epoch)
        case .notSent, .unknown:
            break
        }
    }

    /// Attaches the control client to `sessionID` unless it already is, on
    /// the link a terminal on `server` and `generation` uses.
    private func attachSession(_ sessionID: String, server: RexServerStatus, generation: UInt64) async throws {
        let control = try await terminalControl(server: server, generation: generation)
        try await attachSession(sessionID, on: control)
    }

    private func attachSession(_ sessionID: String, on link: RexControlLink) async throws {
        let epoch = clientEpoch
        guard attachedSessions[sessionID] != epoch else { return }
        do {
            _ = try await link.call("session.attach", payload: JSONValue.object(["session_id": .string(sessionID)]))
        } catch RexControlError.server(let failure) where failure.kind == .notFound {
            throw RexTerminalEnding.finished
        } catch let error as RexControlError {
            switch error {
            case .linkEnded, .deadlineExceeded: throw RexTerminalEnding.connectionReset
            default: throw TransportError(rexControl: error)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RexTerminalEnding.connectionReset
        }
        guard clientEpoch == epoch else { return }
        attachedSessions[sessionID] = epoch
        giveBackLeftSizes(inSession: sessionID, on: link)
    }

    /// Each New Workspace block in `sessionID` that could not be given back
    /// goes back once the session is attached on the live link, as a size an
    /// ended attach left goes back, unless a view of it gave it back first.
    private func giveBackLeftSizes(inSession sessionID: String, on link: RexControlLink) {
        guard let ready = readyConnection, ready.control === link else { return }
        let epoch = clientEpoch
        let waiting = unreturnedCreatedBlocks.filter { $0.key.sessionID == sessionID && $0.value == epoch }.keys
        for address in waiting {
            unreturnedCreatedBlocks[address] = nil
            Task {
                await self.giveBackLeftSize(address, server: ready.server, generation: ready.generation, epoch: epoch)
            }
        }
    }

    /// The server refused a stream in `sessionID` for want of an attach, so
    /// the next terminal there sends `session.attach` again.
    private func forgetAttachment(_ sessionID: String) {
        attachedSessions[sessionID] = nil
    }

    /// The control link a terminal on `server` and `generation` asks on: the
    /// live one, once it answers again after a drop. Another server or SSH
    /// connection has nothing for the terminal.
    private func terminalControl(server: RexServerStatus, generation: UInt64) async throws -> RexControlLink {
        let ready = try await awaitConnection()
        guard ready.server == server, ready.generation == generation else { throw RexTerminalEnding.connectionReset }
        return ready.control
    }

    /// Sends one request of a terminal's, its input or taking and giving back
    /// its size, on the live control link while it is still the terminal's:
    /// the same server, SSH connection and control client (`epoch`), which a
    /// link that resumed the client keeps. Never waits for a link, so what
    /// the view asked for while none is the terminal's is not sent, and never
    /// sent later.
    private func deliverTerminalRequest(
        _ method: String, payload: JSONValue, deadline: RexDeliveryDeadline, server: RexServerStatus,
        generation: UInt64,
        epoch: UInt64
    ) async -> RexDelivery {
        guard let ready = readyConnection, ready.server == server, ready.generation == generation,
            clientEpoch == epoch
        else { return .notSent }
        return await ready.control.deliver(method, payload: payload, deadline: deadline)
    }

    private func terminalDataChannel(generation: UInt64) async throws -> any HeelerSSHAPIChannel {
        guard phase == .active, let transport, currentConnectionGeneration == generation, !transportSuspect else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        clientOpenedDataLinks = true
        return try await transport.openDataChannel()
    }

    private nonisolated func terminalRoute(server: RexServerStatus, generation: UInt64) -> RexDataRoute {
        RexDataRoute(
            control: { [weak self] in
                guard let self else { throw RexTerminalEnding.connectionReset }
                return try await self.terminalControl(server: server, generation: generation)
            },
            openChannel: { [weak self] in
                guard let self else { throw RexTerminalEnding.connectionReset }
                return try await self.terminalDataChannel(generation: generation)
            })
    }

    private func holdBlock(_ address: RexPaneAddress) async throws {
        try Task.checkCancellation()
        guard heldBlocks.contains(address) else {
            heldBlocks.insert(address)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                blockWaiters[address, default: []].append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelBlockWaiter(id, at: address) }
        }
    }

    /// Hands the block to the next attach waiting for it, if any.
    private func releaseBlock(_ address: RexPaneAddress) {
        guard var waiters = blockWaiters[address], !waiters.isEmpty else {
            heldBlocks.remove(address)
            return
        }
        let next = waiters.removeFirst()
        blockWaiters[address] = waiters.isEmpty ? nil : waiters
        next.continuation.resume()
    }

    private func cancelBlockWaiter(_ id: UUID, at address: RexPaneAddress) {
        guard var waiters = blockWaiters[address], let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        blockWaiters[address] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume(throwing: CancellationError())
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

/// New Terminal on a Rex Host (ADR 0049's update of 2026-11-25): what it asks
/// of the server at API revision 12, and what it reads of the answer. One
/// shell block, of the flavor Rex's own New Terminal makes, starts in `cwd`,
/// or where Rex starts one when there is none (the account's home); Rex
/// starts it in the home directory too when `cwd` is not one it can enter.
enum RexNewTerminal {
    /// Where the terminal goes: a new window of a session, which stays in the
    /// background, or a new session, labeled or named by Rex.
    enum Placement: Sendable, Equatable {
        case window(sessionID: String)
        case session(label: String?)
    }

    /// A new session's label when none was given: its directory's last
    /// name, in a POSIX or a Windows path, cut to the 128 characters Rex
    /// takes. Nil for a root, which Rex then names.
    static func sessionLabel(for directory: String) -> String? {
        let name = directory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        guard let name, !name.isEmpty, !name.hasSuffix(":") else { return nil }
        return String(name.prefix(128))
    }

    static let newWindowMethod = "session.new_window"
    static let newSessionMethod = "session.create"
    static let shellFlavor = "com.superlogical.terminal.shell"

    static func newWindowPayload(in sessionID: String, cwd: String?) -> JSONValue {
        .object(["session_id": .string(sessionID), "focus": .bool(false), "layout": layout(cwd: cwd)])
    }

    static func newSessionPayload(label: String?, cwd: String?) -> JSONValue {
        var payload: [String: JSONValue] = ["initial_windows": .array([.object(["layout": layout(cwd: cwd)])])]
        if let label { payload["label"] = .string(String(label.prefix(128))) }
        return .object(payload)
    }

    private static func layout(cwd: String?) -> JSONValue {
        var block: [String: JSONValue] = ["flavor": .string(shellFlavor)]
        if let cwd { block["options"] = .object(["cwd": .string(cwd)]) }
        return .object(["block": .object(block)])
    }

    /// The terminal made: its block, and the window that holds it.
    struct Created: Sendable, Equatable {
        let address: RexPaneAddress
        let windowID: String
    }

    /// The new window and its block from `session.new_window`'s answer.
    static func newWindow(in sessionID: String, from result: JSONValue) throws -> Created {
        guard let made = window(result) else { throw unreadable }
        return Created(address: RexPaneAddress(sessionID: sessionID, blockID: made.blockID), windowID: made.windowID)
    }

    /// The new session, its window and its block from `session.create`'s answer.
    static func newSession(from result: JSONValue) throws -> Created {
        guard let sessionID = result["session_id"]?.stringValue, !sessionID.isEmpty,
            case .array(let windows)? = result["initial_windows"], let first = windows.first,
            let made = window(first)
        else { throw unreadable }
        return Created(address: RexPaneAddress(sessionID: sessionID, blockID: made.blockID), windowID: made.windowID)
    }

    private static func window(_ value: JSONValue) -> (windowID: String, blockID: String)? {
        guard let windowID = value["window_id"]?.stringValue, !windowID.isEmpty,
            case .array(let blocks)? = value["block_ids"], let blockID = blocks.first?.stringValue, !blockID.isEmpty
        else { return nil }
        return (windowID, blockID)
    }

    private static var unreadable: TransportError {
        .rexAnswerUnreadable(String(localized: "Rex made the terminal, but its answer did not name it."))
    }

    /// The attach a new window waits on had no answer, so the window's
    /// request never left and nothing was made.
    static var notSent: TransportError {
        .channelFailed(detail: String(localized: "Rex did not answer, so no terminal was made. Try again."))
    }

    /// A request with no answer may have made its terminal, so the user is
    /// told to look before asking again; a refusal says what Rex said.
    static func failure(_ error: RexControlError) -> TransportError {
        switch error {
        case .deadlineExceeded, .linkEnded:
            .channelFailed(
                detail: String(
                    localized: "Rex did not answer. The terminal may still have been made, so check the list before trying again."))
        default:
            TransportError(rexControl: error)
        }
    }
}
