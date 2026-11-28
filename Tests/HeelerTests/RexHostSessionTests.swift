import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A Rex Host's session over scripted SSH connections and fake servers: what
/// it attaches to, how it follows the inventory, how it survives a dropped
/// link or a server that let go of its client, another server instance, and
/// failures that read as status (ADR 0050). Ids, labels and tokens are invented.
@Suite("Rex Host session", .timeLimit(.minutes(1)))
struct RexHostSessionTests {
    static let path = "/run/user/1000/rex/server.sock"

    /// Everything a session said, in order.
    final class UpdateLog: Sendable {
        private final class Store: Sendable {
            let updates = Mutex<[RexHostSessionUpdate]>([])
        }

        private let store = Store()
        private let task: Task<Void, Never>

        init(_ session: RexHostSession) {
            task = Task { [store] in
                for await update in session.updates { store.updates.withLock { $0.append(update) } }
            }
        }

        var snapshot: RexHostSessionUpdateLog { RexHostSessionUpdateLog(updates: store.updates.withLock { $0 }) }
        var statuses: [EventsSessionStatus] { snapshot.statuses }
        var servers: [String] { snapshot.servers }
        var inventories: [RexInventory] { snapshot.inventories }

        func waitUntil(
            _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
            _ condition: (RexHostSessionUpdateLog) async -> Bool
        ) async throws {
            for _ in 0..<500 {
                if await condition(snapshot) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
        }
    }

    /// SSH connections in the order the session dials them, and what each
    /// dial was asked to resume.
    final class Dialer: Sendable {
        private let hosts: Mutex<[ScriptedRexHost]>
        private let resumed = Mutex<[Bool]>([])

        init(_ hosts: [ScriptedRexHost]) {
            self.hosts = Mutex(hosts)
        }

        var dialsResuming: [Bool] { resumed.withLock { $0 } }

        func dial(_ socket: RexSocket?, _ previous: RexControlLink?) async throws -> any RexTransport {
            resumed.withLock { $0.append(previous != nil) }
            guard let host = hosts.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                throw TransportError.sshUnreachable(detail: "no more scripted connections")
            }
            return try await RexSSHTransport.connect(over: host, socket: socket, resuming: previous, options: .testing)
        }
    }

    private func session(_ dialer: Dialer, healthyFollowLife: Duration = .zero) -> RexHostSession {
        RexHostSession(
            storedSocket: RexSocket(path: Self.path), connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            healthyFollowLife: healthyFollowLife)
    }

    private func world() -> FakeRexWorld {
        FakeRexWorld(sessions: [FakeRexWorld.studio()])
    }

    private func server(_ world: FakeRexWorld) async -> FakeRexServer {
        let server = FakeRexServer()
        await world.install(on: server)
        return server
    }

    /// Waits for the first link's inventory with its details, after which
    /// it publishes nothing more until something changes.
    private func waitForSettledInventory(_ log: UpdateLog) async throws {
        try await log.waitUntil("an inventory with details") {
            $0.inventories.last?.sessions.first?.terminals.first?.details.title == "make test"
        }
    }

    private func blockIDs(_ inventory: RexInventory?) -> [String] {
        inventory?.sessions.flatMap { $0.terminals.map(\.blockID) } ?? []
    }

    // MARK: Following

    /// It asks the server who it is, attaches to every session with their
    /// terminals' own events, and publishes once the inventory and its
    /// details are read.
    @Test func itAttachesToEverySessionAndPublishesTheInventory() async throws {
        let world = world()
        let server = await server(world)
        let host = ScriptedRexHost(control: [.server(server)])
        let session = session(Dialer([host]))
        let log = UpdateLog(session)

        await session.resume()
        try await log.waitUntil("an inventory with details") {
            $0.inventories.last?.sessions.first?.terminals.first?.details.title == "make test"
        }

        #expect(log.statuses == [.connecting, .connected])
        #expect(log.servers == ["instance-0001"])
        let inventory = try #require(log.inventories.last)
        #expect(blockIDs(inventory) == ["block:left", "block:right", "block:solo", "block:float", "block:detached"])
        #expect(inventory.sessions.first?.terminals.map(\.details.program) == ["make", "zsh", "vim", "zsh", "tail"])
        #expect(inventory.sessions.first?.terminals.first?.details.directory == "/home/dev/app")
        // Structure first, then details: never more than one inventory without them.
        #expect(log.inventories.count <= 2)
        let requests = await server.requests
        let attach = try #require(requests.first { $0.method == "session.attach_all" })
        #expect(attach.payload?["event_scope"] == "all")
        #expect(requests.first?.method == "server.status")

        await session.end()
    }

    /// A terminal's own events, and changes to the layout, reach the inventory.
    @Test func eventsKeepTheInventoryCurrent() async throws {
        let world = world()
        let server = await server(world)
        let session = session(Dialer([ScriptedRexHost(control: [.server(server)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await log.waitUntil("the first inventory") { $0.inventories.last?.sessions.first?.terminals.first?.details.title != nil }

        await server.push(
            "block_event",
            ["block_id": "block:solo", "creator_name": .string(RexInventoryWire.terminalCreator), "name": "title_changed",
             "payload": ["title": "vim main.swift"]],
            session: "session:studio")
        try await log.waitUntil("the new title") {
            $0.inventories.last?.sessions.first?.windows.last?.terminals.first?.details.title == "vim main.swift"
        }

        world.update { sessions in
            sessions[0].windows[1].layers.removeLast()
            sessions[0].revision = 4
        }
        await server.push("block_closed", ["block_id": "block:float"], session: "session:studio")
        await server.push("session_view_changed", ["revision": 4], session: "session:studio")
        try await log.waitUntil("the closed terminal gone") { !blockIDsOf($0.inventories.last).contains("block:float") }
        #expect(blockIDsOf(log.inventories.last) == ["block:left", "block:right", "block:solo", "block:detached"])

        await session.end()
    }

    /// A burst of events while a session's structure read is out costs that
    /// read and one more, however many events came, and the inventory ends
    /// where the last of them left it.
    @Test func aBurstOfEventsCostsTheReadOutAndOneMore() async throws {
        let world = world()
        let server = await server(world)
        let session = session(Dialer([ScriptedRexHost(control: [.server(server)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)
        let viewsBefore = await server.requests.filter { $0.method == "session.view" }.count
        let inventoriesBefore = log.inventories.count

        await server.stopAnswering("session.view")
        world.update { $0[0].revision = 4 }
        let askedAt = await server.push("session_view_changed", ["revision": 4], session: "session:studio")
        let held = await server.nextRequest()
        #expect(held.method == "session.view")
        let asked = world.sessions[0]
        for revision in 5...300 {
            await server.push("session_view_changed", ["revision": .number(Double(revision))], session: "session:studio")
            await server.push(
                "block_event",
                ["block_id": "block:solo", "creator_name": .string(RexInventoryWire.terminalCreator),
                 "name": "title_changed", "payload": ["title": .string("step \(revision)")]],
                session: "session:studio")
        }
        // Where the burst left the server: the floating terminal closed, and
        // the last title is what a read of it would say too.
        world.update { sessions in
            sessions[0].windows[1].layers.removeLast()
            sessions[0].revision = 300
            for window in sessions[0].windows.indices {
                for layer in sessions[0].windows[window].layers.indices {
                    for block in sessions[0].windows[window].layers[layer].blocks.indices
                    where sessions[0].windows[window].layers[layer].blocks[block].id == "block:solo" {
                        sessions[0].windows[window].layers[layer].blocks[block].title = "step 300"
                    }
                }
            }
        }
        await world.install(on: server)
        await server.respond(to: held, with: FakeRexWorld.view(asked), seq: askedAt)

        try await log.waitUntil("the burst settled") { seen in
            let terminals = seen.inventories.last?.sessions.first?.terminals ?? []
            return !terminals.contains { $0.blockID == "block:float" }
                && terminals.first { $0.blockID == "block:solo" }?.details.title == "step 300"
        }
        #expect(await server.requests.filter { $0.method == "session.view" }.count - viewsBefore <= 2)
        #expect(log.inventories.count - inventoriesBefore <= 2)
        await session.end()
    }

    /// Rex raises no event when a detached terminal's label changes, so the
    /// follower reads a session with detached terminals again on its interval.
    @Test func aDetachedTerminalsLabelIsReadAgainOnAnInterval() async throws {
        final class Published: Sendable {
            let inventories = Mutex<[RexInventory]>([])
            var last: RexInventory? { inventories.withLock { $0.last } }
        }
        let world = world()
        let (server, link) = try await FakeRexServer.open()
        await world.install(on: server)
        let clock = ManualClock()
        let published = Published()
        let follower = RexInventoryFollower(
            link: link, detachedRereadInterval: .seconds(60), sleep: clock.parkedSleep(for:)
        ) { inventory in published.inventories.withLock { $0.append(inventory) } }
        let following = Task { await follower.run() }
        func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            #expect(condition(), "Timed out waiting for \(what)")
        }
        try await waitUntil("the inventory with details") {
            published.last?.sessions.first?.terminals.first?.details.title == "make test"
        }
        let viewReads = await server.requests.count(where: { $0.method == "session.view" })

        world.update { $0[0].detached[0].label = "deploy" }
        #expect(await clock.pass(.seconds(60)))
        try await waitUntil("the new label") { published.last?.sessions.first?.detached.first?.label == "deploy" }
        #expect(await server.requests.count(where: { $0.method == "session.view" }) == viewReads + 1)

        await link.close()
        #expect(await following.value == .linkEnded(.closedHere))
    }

    /// A session whose first structure read the server refused is not
    /// published as missing: the follower reads it again after a pause, and
    /// the inventory shows once it reads.
    @Test func aRefusedFirstStructureReadIsTriedAgain() async throws {
        final class Published: Sendable {
            let inventories = Mutex<[RexInventory]>([])
            var all: [RexInventory] { inventories.withLock { $0 } }
        }
        let world = world()
        let (server, link) = try await FakeRexServer.open()
        await world.install(on: server)
        let refusals = Mutex(1)
        let studio = world.sessions[0]
        await server.answer("session.view") { _ in
            let refuse = refusals.withLock { count in
                defer { count -= 1 }
                return count > 0
            }
            return refuse ? .error(code: "internal", message: "busy", status: 500) : .result(FakeRexWorld.view(studio))
        }
        let clock = ManualClock()
        let published = Published()
        let follower = RexInventoryFollower(
            link: link, firstReadRetryDelay: .seconds(2), detachedRereadInterval: nil, sleep: clock.parkedSleep(for:)
        ) { inventory in published.inventories.withLock { $0.append(inventory) } }
        let following = Task { await follower.run() }

        #expect(await clock.parks(for: .seconds(2)))
        #expect(published.all.isEmpty)
        clock.advance(.seconds(2))
        for _ in 0..<500 where published.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(published.all.first?.sessions.map(\.id) == [studio.id])
        #expect(await server.requests.count(where: { $0.method == "session.view" }) == 2)

        await link.close()
        #expect(await following.value == .linkEnded(.closedHere))
    }

    /// A link that carries the last one's details publishes them first, with
    /// no Program Status. A terminal's status then publishes as soon as its
    /// own read answers, while another terminal's read is still unanswered:
    /// an Agent does not read Unknown until every terminal is read (ADR 0054).
    @Test func aProgramStatusPublishesWithoutWaitingForEveryTerminal() async throws {
        final class Published: Sendable {
            let inventories = Mutex<[RexInventory]>([])
            var all: [RexInventory] { inventories.withLock { $0 } }
        }
        var studio = FakeRexWorld.studio()
        var codex = FakeRexWorld.Block.running("block:left", program: "codex")
        codex.status = codex.record("blocked", app: "codex")
        studio.windows[0].layers[0].blocks[2] = codex
        let world = FakeRexWorld(sessions: [studio])
        let (server, link) = try await FakeRexServer.open()
        await world.install(on: server)
        // Titles are answered by hand, so one terminal's read can wait.
        await server.stopAnswering(RexInventoryWire.terminalMethod("title"))
        let left = RexPaneAddress(sessionID: studio.id, blockID: "block:left")
        let detached = RexPaneAddress(sessionID: studio.id, blockID: "block:detached")
        let carried = RexTerminalDetails(
            title: "codex", program: "codex", processID: 4242, argv0: "codex",
            status: RexProgramStatus(state: "working", app: "codex", ownerProcessID: 4242, ownerName: "codex"))
        let published = Published()
        let follower = RexInventoryFollower(link: link, carrying: [left: carried], detachedRereadInterval: nil) {
            inventory in published.inventories.withLock { $0.append(inventory) }
        }
        let following = Task { await follower.run() }
        func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
            for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            #expect(condition(), "Timed out waiting for \(what)")
        }

        var held: FakeRexServer.Request?
        while held == nil {
            let request = await server.nextRequest()
            if request.payload?["block_id"]?.stringValue == detached.blockID {
                held = request
            } else {
                await server.respond(to: request, with: ["title": ""])
            }
        }
        try await waitUntil("the Agent's status") { published.all.last?.details[left]?.status?.state == "blocked" }

        let first = try #require(published.all.first)
        #expect(first.details[left]?.program == "codex")
        #expect(first.details[left]?.status == nil)
        #expect(published.all.allSatisfy { $0.details[detached]?.title == nil })

        let request = try #require(held)
        await server.respond(to: request, with: ["title": "tail -f log"])
        try await waitUntil("the last terminal's details") {
            published.all.last?.details[detached]?.title == "tail -f log"
        }
        await link.close()
        #expect(await following.value == .linkEnded(.closedHere))
    }

    // MARK: Drops

    /// A link that drops without a close frame is resumed with its reconnect
    /// token on the same SSH connection, and the inventory is read again.
    @Test func aDroppedLinkResumesAndReadsAgain() async throws {
        let world = world()
        let first = await server(world)
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        resumed.reconnectToken = "fake-reconnect-token-0002"
        let second = await server(world)
        let host = ScriptedRexHost(control: [.server(first), .server(second, welcome: resumed)])
        let dialer = Dialer([host])
        let session = session(dialer)
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)
        let before = log.inventories.count

        await first.drop()
        try await log.waitUntil("a second inventory") { $0.inventories.count > before && $0.statuses.last == .connected }

        #expect(await second.nextHello()["reconnect_token"] == "fake-reconnect-token-0001")
        #expect(await second.requests.contains { $0.method == "session.attach_all" })
        #expect(!(await first.clientSentCloseFrame))
        #expect(dialer.dialsResuming == [false])
        let reconnecting = log.statuses.first {
            if case .reconnecting = $0 { true } else { false }
        }
        #expect(reconnecting == .reconnecting(
            attempt: 1, delay: .zero, failure: .channelFailed(detail: "The connection to Rex ended.")))
        #expect(blockIDs(log.inventories.last) == blockIDs(log.inventories.first))

        await session.end()
    }

    /// A link that drops soon after its reads waits out the backoff, so a
    /// server that closes every link at once is not dialed in a tight loop.
    @Test func aLinkThatDropsSoonAfterItsReadsBacksOff() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let host = ScriptedRexHost(control: [.server(first), .server(second)])
        let session = session(Dialer([host]), healthyFollowLife: .seconds(60))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)
        let before = log.inventories.count

        await first.drop()
        try await log.waitUntil("a second inventory") { $0.inventories.count > before && $0.statuses.last == .connected }

        let reconnecting = log.statuses.first {
            if case .reconnecting = $0 { true } else { false }
        }
        #expect(reconnecting == .reconnecting(
            attempt: 1, delay: .milliseconds(10), failure: .channelFailed(detail: "The connection to Rex ended.")))

        await session.end()
    }

    /// A server that let go of the client, as Rex does when too many events
    /// queue up, gets a plain hello and a fresh read.
    @Test func aServerThatLetGoGetsAFreshHello() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let session = session(Dialer([ScriptedRexHost(control: [.server(first), .server(second)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        let before = log.inventories.count
        await first.close(.policyViolation, reason: "event backlog exceeded")
        try await log.waitUntil("the second link's inventory") {
            $0.inventories.count > before && $0.statuses.last == .connected
        }

        #expect(await second.nextHello()["reconnect_token"] == nil)
        #expect(await second.requests.contains { $0.method == "session.attach_all" })
        #expect(log.statuses.last == .connected)
        let reconnecting = log.statuses.first {
            if case .reconnecting = $0 { true } else { false }
        }
        guard case .reconnecting(_, _, let failure)? = reconnecting else {
            Issue.record("No reconnect after the server let go")
            return
        }
        #expect(failure.presentation.message.contains("too many events were waiting"))
        await session.end()
    }

    /// A server that closed the link for unanswered pings keeps the client,
    /// so the next hello on the same SSH connection carries its token.
    @Test func aClientClosedForMissedPingsIsResumed() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let dialer = Dialer([ScriptedRexHost(control: [.server(first), .server(second)])])
        let session = session(dialer)
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        let before = log.inventories.count
        await first.close(.goingAway, reason: "keepalive timeout")
        try await log.waitUntil("the second link's inventory") {
            $0.inventories.count > before && $0.statuses.last == .connected
        }

        #expect(await second.nextHello()["reconnect_token"] == "fake-reconnect-token-0001")
        #expect(await second.requests.contains { $0.method == "session.attach_all" })
        #expect(dialer.dialsResuming == [false])
        await session.end()
    }

    /// Suspending comes once the app's grace period ran out: the link closes
    /// with a close frame, so the server forgets the client at once, and the
    /// next connection says hello afresh.
    @Test func aSuspendedSessionLeavesAndSaysHelloAfresh() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let firstHost = ScriptedRexHost(control: [.server(first)])
        let dialer = Dialer([firstHost, ScriptedRexHost(control: [.server(second)])])
        let session = session(dialer)
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        await session.suspend()
        #expect(await first.clientClose?.code == .normalClosure)
        #expect(await firstHost.log.last == "close")
        try await log.waitUntil("the suspension") { $0.statuses.last == .suspended }
        let before = log.inventories.count
        await session.resume()
        try await log.waitUntil("an inventory after resuming") {
            $0.statuses.last == .connected && $0.inventories.count > before
        }

        #expect(dialer.dialsResuming == [false, false])
        #expect(await second.nextHello()["reconnect_token"] == nil)
        await session.end()
    }

    /// Leaving for good closes the link with a close frame, so the server
    /// forgets the client at once.
    @Test func endingClosesTheLinkWithACloseFrame() async throws {
        let world = world()
        let server = await server(world)
        let host = ScriptedRexHost(control: [.server(server)])
        let session = session(Dialer([host]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        await session.end()

        #expect(await server.clientClose?.code == .normalClosure)
        #expect(await host.log.last == "close")
        try await log.waitUntil("the end") { $0.statuses.last == .ended }
    }

    // MARK: Servers

    /// Another server instance on the same socket says so, so what was known
    /// of the last one goes.
    @Test func anotherInstanceIsAnotherServer() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let session = session(Dialer([ScriptedRexHost(control: [.server(first), .server(second)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        world.restart(as: "instance-0002")
        await first.close(.goingAway, reason: "shutting down")
        try await log.waitUntil("the new server") { $0.servers.count == 2 }

        #expect(log.servers == ["instance-0001", "instance-0002"])
        await session.end()
    }

    /// What one server instance knew of its terminals is not shown for
    /// another's, whose ids may repeat: the new instance's terminals wait for
    /// its own reads of their titles and programs.
    @Test func anotherInstanceStartsWithoutTheLastOnesDetails() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        await second.stopAnswering(RexInventoryWire.terminalMethod("title"))
        await second.stopAnswering(RexInventoryWire.terminalMethod("process"))
        let session = session(Dialer([ScriptedRexHost(control: [.server(first), .server(second)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)
        let before = log.inventories.count

        world.restart(as: "instance-0002")
        await first.close(.goingAway, reason: "shutting down")
        try await log.waitUntil("the new server's inventory") {
            $0.servers.count == 2 && $0.inventories.count > before
        }
        let terminals = log.inventories[before].sessions.first?.terminals ?? []
        #expect(!terminals.isEmpty)
        // Nothing of them is known yet, their foreground included.
        var unread = RexTerminalDetails()
        unread.awaitsForeground = true
        #expect(terminals.allSatisfy { $0.details == unread })
        await session.end()
    }

    /// A server restarted on the same files that lists the sessions the last
    /// one listed restored them, so it continues the last one's core; one
    /// that lists none of them is another server.
    @Test(arguments: [(true, ["instance-0001", "instance-0001"]), (false, ["instance-0001", "instance-0002"])])
    func aRestartedServerContinuesItsCoreOnlyWithItsSessions(restored: Bool, cores: [String]) async throws {
        let world = FakeRexWorld(hostID: "host-0001", sessions: [FakeRexWorld.studio()])
        let first = await server(world)
        let second = await server(world)
        let session = session(Dialer([ScriptedRexHost(control: [.server(first), .server(second)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        world.restart(as: "instance-0002")
        if !restored { world.update { $0 = [FakeRexWorld.studio(id: "session:other")] } }
        await first.close(.goingAway, reason: "shutting down")
        try await log.waitUntil("the restarted server") { $0.servers.count == 2 }

        #expect(log.servers == ["instance-0001", "instance-0002"])
        #expect(log.snapshot.cores == cores)
        await session.end()
    }

    /// What an earlier run knew of the server lets the first connection of
    /// this one continue its core.
    @Test func aSeededLineageContinuesTheEarlierRunsCore() async throws {
        let world = FakeRexWorld(hostID: "host-0001", sessions: [FakeRexWorld.studio()])
        let session = session(Dialer([ScriptedRexHost(control: [.server(await server(world))])]))
        session.seedLineage(
            RexServerLineage(
                RexServerStatus(instanceID: "instance-0000", hostID: "host-0001"), sessionIDs: ["session:studio"]))
        let log = UpdateLog(session)
        await session.resume()
        try await log.waitUntil("the server") { $0.servers.count == 1 }

        #expect(log.snapshot.cores == ["instance-0000"])
        await session.end()
    }

    // MARK: Failures

    /// A server that is not running is retried; a socket SSH will not forward
    /// stops until the user acts.
    @Test(arguments: [
        ("missing", true, TransportError.rexServerNotRunning(socketPath: RexHostSessionTests.path)),
        ("listening", false, TransportError.rexForwardingRefused(socketPath: RexHostSessionTests.path)),
    ])
    func connectFailuresReadAsStatus(socketCheck: String, retried: Bool, failure: TransportError) async throws {
        let hosts = (0..<3).map { _ in ScriptedRexHost(socketCheck: socketCheck, control: [.refused]) }
        let session = session(Dialer(hosts))
        let log = UpdateLog(session)

        await session.resume()
        try await log.waitUntil("a failure status") { $0.statuses.count >= 2 }

        let status = log.statuses[1]
        if retried {
            #expect(status == .reconnecting(attempt: 1, delay: .milliseconds(10), failure: failure))
        } else {
            #expect(status == .failed(failure))
        }
        await session.end()
    }

    @Test func setWindowLabelSendsWirePayloadConfirmsTrimmedNameAndResetsToDefault() async throws {
        let world = world()
        let server = await server(world)
        let windowID = "window:0000-0000-0000-00000000a0a0"
        await server.answer(RexControlProtocol.setWindowLabelMethod) { [world] request in
            guard let sessionID = request.payload?["session_id"]?.stringValue,
                let targetWindowID = request.payload?["window_id"]?.stringValue,
                let label = request.payload?["label"]?.stringValue
            else {
                return .error(code: "bad_request", message: "missing fields", status: 400)
            }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            world.update { sessions in
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
                    let windowIndex = sessions[sessionIndex].windows.firstIndex(where: { $0.id == targetWindowID })
                else { return }
                if trimmed.isEmpty {
                    let digits = targetWindowID.split(separator: ":").last
                        .map { $0.replacingOccurrences(of: "-", with: "") } ?? ""
                    sessions[sessionIndex].windows[windowIndex].label = "Window \(digits.suffix(8))"
                } else {
                    sessions[sessionIndex].windows[windowIndex].label = trimmed
                }
            }
            return .result(.object([:]))
        }
        let session = session(Dialer([ScriptedRexHost(control: [.server(server)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        try await session.setWindowLabel(sessionID: "session:studio", windowID: windowID, label: "  Build Logs  ")
        try await session.setWindowLabel(sessionID: "session:studio", windowID: windowID, label: "")

        let writes = await server.requests.filter { $0.method == RexControlProtocol.setWindowLabelMethod }
        #expect(writes.count == 2)
        #expect(
            writes[0].payload
                == RexControlProtocol.setWindowLabelPayload(
                    sessionID: "session:studio", windowID: windowID, label: "  Build Logs  "))
        #expect(
            writes[1].payload
                == RexControlProtocol.setWindowLabelPayload(
                    sessionID: "session:studio", windowID: windowID, label: ""))
        #expect(world.sessions.first?.windows.first?.label == "Window 0000a0a0")

        await server.answer(RexControlProtocol.setWindowLabelMethod) { _ in .result(.object([:])) }
        await #expect(throws: TransportError.self) {
            try await session.setWindowLabel(sessionID: "session:studio", windowID: windowID, label: "Unconfirmed")
        }

        await session.end()
    }

    @MainActor
    @Test func projectionRenameTabRenamesWindowResetsDefaultAndRejectsDetachedTab() async throws {
        let world = world()
        let server = await server(world)
        let windowID = "window:0000-0000-0000-00000000a0a0"
        await server.answer(RexControlProtocol.setWindowLabelMethod) { [world] request in
            guard let sessionID = request.payload?["session_id"]?.stringValue,
                let targetWindowID = request.payload?["window_id"]?.stringValue,
                let label = request.payload?["label"]?.stringValue
            else {
                return .error(code: "bad_request", message: "missing fields", status: 400)
            }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            world.update { sessions in
                guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
                    let windowIndex = sessions[sessionIndex].windows.firstIndex(where: { $0.id == targetWindowID })
                else { return }
                if trimmed.isEmpty {
                    let digits = targetWindowID.split(separator: ":").last
                        .map { $0.replacingOccurrences(of: "-", with: "") } ?? ""
                    sessions[sessionIndex].windows[windowIndex].label = "Window \(digits.suffix(8))"
                } else {
                    sessions[sessionIndex].windows[windowIndex].label = trimmed
                }
            }
            return .result(.object([:]))
        }
        let host = Host(address: "rex.example", username: "dev", serverKind: .rex, rexSocket: RexSocket(path: Self.path))
        let rexSession = session(Dialer([ScriptedRexHost(control: [.server(server)])]))
        let suite = "rex-rename-tab-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projection = RexConsoleProjection(
            host: host, session: rexSession, memory: HerdrCoreHostMemory(defaults: defaults),
            pins: PinnedAgentsStore(), onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }

        for _ in 0..<500 where projection.inventory == nil || projection.kernel == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(projection.inventory != nil)
        try #require(projection.kernel != nil)

        try await projection.renameTab(windowID, label: "  Editor  ")
        try await projection.renameTab(windowID, label: "")

        let writesAfterValid = await server.requests.filter { $0.method == RexControlProtocol.setWindowLabelMethod }
        #expect(writesAfterValid.count == 2)
        #expect(writesAfterValid[0].payload?["label"] == .string("  Editor  "))
        #expect(writesAfterValid[1].payload?["label"] == .string(""))

        let detachedTabID = RexOrganization.detachedTabID(ofSession: "session:studio")
        await #expect(throws: TransportError.self) {
            try await projection.renameTab(detachedTabID, label: "Detached")
        }
        let writesAfterDetached = await server.requests.filter { $0.method == RexControlProtocol.setWindowLabelMethod }
        #expect(writesAfterDetached.count == 2)
    }

    @Test func rev20To24WirePayloadsAndCapabilitiesGateByNegotiatedRevision() {
        #expect(RexControlProtocol.apiRevision == 24)
        #expect(RexControlProtocol.undoableCloseMinimumRevision == 20)
        #expect(RexControlProtocol.transferWindowMinimumRevision == 22)
        #expect(RexControlProtocol.closeBlockMethod == "block.close")
        #expect(RexControlProtocol.closeWindowMethod == "session.close_window")
        #expect(RexControlProtocol.transferWindowMethod == "session.transfer_window")
        #expect(RexControlProtocol.createSessionMethod == "session.create")
        #expect(RexControlProtocol.destroySessionMethod == "session.destroy")

        #expect(
            RexControlProtocol.closeBlockPayload(sessionID: "session:studio", blockID: "block:left", undoable: true)
                == ["session_id": "session:studio", "block_id": "block:left", "undoable": true])
        #expect(
            RexControlProtocol.closeWindowPayload(sessionID: "session:studio", windowID: "window:1", undoable: true)
                == ["session_id": "session:studio", "window_id": "window:1", "undoable": true])
        #expect(
            RexControlProtocol.transferWindowPayload(
                sessionID: "session:studio", windowID: "window:1", toSessionID: "session:dest")
                == ["session_id": "session:studio", "window_id": "window:1", "to_session_id": "session:dest", "focus": false])
        #expect(RexControlProtocol.createEmptySessionPayload(label: nil) == [:])
        #expect(RexControlProtocol.createEmptySessionPayload(label: "Scratch") == ["label": "Scratch"])
        #expect(RexControlProtocol.destroySessionPayload(sessionID: "session:tmp") == ["session_id": "session:tmp"])

        let rev19 = HostCapabilities(serverKind: .rex, coreKernel: HerdrCoreLocator.macOSKernel, rexAPIRevision: 19)
        #expect(!rev19.closeTab)
        #expect(!rev19.movesPanes)

        let rev20 = HostCapabilities(serverKind: .rex, coreKernel: HerdrCoreLocator.macOSKernel, rexAPIRevision: 20)
        #expect(rev20.closeTab)
        #expect(!rev20.movesPanes)

        let rev22 = HostCapabilities(serverKind: .rex, coreKernel: HerdrCoreLocator.macOSKernel, rexAPIRevision: 22)
        #expect(rev22.closeTab)
        #expect(rev22.movesPanes)
    }

    @Test func rev20CloseBlockAndCloseWindowAttachAndSendUndoablePayloads() async throws {
        let world = world()
        let server = await server(world)
        let windowID = "window:0000-0000-0000-00000000a0a0"
        await server.answer(RexControlProtocol.closeBlockMethod) { request in
            let blockID = request.payload?["block_id"]?.stringValue ?? ""
            return .result(["block_id": .string(blockID), "revision": 4])
        }
        await server.answer(RexControlProtocol.closeWindowMethod, with: .result(["revision": 5]))
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = 24
        welcome.serverRevision = 24
        let session = session(Dialer([ScriptedRexHost(control: [.server(server, welcome: welcome)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        try await session.closeBlock(RexPaneAddress(sessionID: "session:studio", blockID: "block:left"), undoable: true)
        try await session.closeWindow(sessionID: "session:studio", windowID: windowID, undoable: true)

        let requests = await server.requests
        let attachIndex = try #require(requests.firstIndex {
            $0.method == "session.attach" && $0.payload?["session_id"] == "session:studio"
        })
        let closeBlockIndex = try #require(requests.firstIndex { $0.method == RexControlProtocol.closeBlockMethod })
        #expect(attachIndex < closeBlockIndex)
        #expect(
            requests[closeBlockIndex].payload
                == RexControlProtocol.closeBlockPayload(
                    sessionID: "session:studio", blockID: "block:left", undoable: true))
        let closeWindow = try #require(requests.first { $0.method == RexControlProtocol.closeWindowMethod })
        #expect(
            closeWindow.payload
                == RexControlProtocol.closeWindowPayload(
                    sessionID: "session:studio", windowID: windowID, undoable: true))

        await session.end()
    }

    @Test func rev22TransferWindowMovesToExistingAndNewSession() async throws {
        let studio = FakeRexWorld.studio()
        let dest = FakeRexWorld.Session(id: "session:dest", label: "dest", activeWindowID: nil, windows: [])
        let world = FakeRexWorld(sessions: [studio, dest])
        let server = await server(world)
        let windowID = "window:0000-0000-0000-00000000a0a0"
        await server.answer(RexControlProtocol.createSessionMethod) { [world] request in
            let label = request.payload?["label"]?.stringValue ?? "unnamed"
            world.update { sessions in
                sessions.append(FakeRexWorld.Session(id: "session:created-1", label: label, activeWindowID: nil, windows: []))
            }
            return .result(["session_id": "session:created-1"])
        }
        await server.answer(RexControlProtocol.transferWindowMethod) { [world] request in
            guard let sourceID = request.payload?["session_id"]?.stringValue,
                let targetWindowID = request.payload?["window_id"]?.stringValue,
                let destID = request.payload?["to_session_id"]?.stringValue
            else {
                return .error(code: "bad_request", message: "missing transfer fields", status: 400)
            }
            world.update { sessions in
                guard let sourceIndex = sessions.firstIndex(where: { $0.id == sourceID }),
                    let destIndex = sessions.firstIndex(where: { $0.id == destID }),
                    let windowIndex = sessions[sourceIndex].windows.firstIndex(where: { $0.id == targetWindowID })
                else { return }
                let moved = sessions[sourceIndex].windows.remove(at: windowIndex)
                sessions[destIndex].windows.append(moved)
                sessions[sourceIndex].revision += 1
                sessions[destIndex].revision += 1
            }
            return .result(["revision": 4, "to_revision": 2])
        }
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = 24
        welcome.serverRevision = 24
        let session = session(Dialer([ScriptedRexHost(control: [.server(server, welcome: welcome)])]))
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        let movedToExisting = try await session.transferWindow(
            sessionID: "session:studio", windowID: windowID, to: .session("session:dest"),
            blockIDs: ["block:left", "block:right"])
        #expect(movedToExisting == "session:dest")

        let movedToNew = try await session.transferWindow(
            sessionID: "session:dest", windowID: windowID, to: .newSession(label: "Moved"),
            blockIDs: ["block:left", "block:right"])
        #expect(movedToNew == "session:created-1")

        let creates = await server.requests.filter { $0.method == RexControlProtocol.createSessionMethod }
        #expect(creates.count == 1)
        #expect(creates[0].payload == RexControlProtocol.createEmptySessionPayload(label: "Moved"))

        let transfers = await server.requests.filter { $0.method == RexControlProtocol.transferWindowMethod }
        #expect(transfers.count == 2)
        #expect(
            transfers[0].payload
                == RexControlProtocol.transferWindowPayload(
                    sessionID: "session:studio", windowID: windowID, toSessionID: "session:dest", focus: false))
        #expect(
            transfers[1].payload
                == RexControlProtocol.transferWindowPayload(
                    sessionID: "session:dest", windowID: windowID, toSessionID: "session:created-1", focus: false))

        await session.end()
    }

    @MainActor
    @Test func projectionMovePaneTransfersSinglePaneWindowAndRejectsDetachedOrMultiPaneWindows() async throws {
        var studio = FakeRexWorld.studio()
        let single = FakeRexWorld.Block("block:single")
        studio.windows.append(
            FakeRexWorld.Window(
                id: "window:0000-0000-0000-00000000c0c0", label: "single",
                layers: [FakeRexWorld.Layer(layout: .block(single.id), blocks: [single])]))
        let destBlock = FakeRexWorld.Block("block:dest")
        let dest = FakeRexWorld.Session(
            id: "session:dest", label: "dest", activeWindowID: "window:0000-0000-0000-00000000d0d0",
            windows: [
                FakeRexWorld.Window(
                    id: "window:0000-0000-0000-00000000d0d0", label: "main",
                    layers: [FakeRexWorld.Layer(layout: .block(destBlock.id), blocks: [destBlock])])
            ])
        let world = FakeRexWorld(sessions: [studio, dest])
        let server = await server(world)
        await server.answer(RexControlProtocol.transferWindowMethod) { [world] request in
            guard let sourceID = request.payload?["session_id"]?.stringValue,
                let targetWindowID = request.payload?["window_id"]?.stringValue,
                let destID = request.payload?["to_session_id"]?.stringValue
            else {
                return .error(code: "bad_request", message: "missing transfer fields", status: 400)
            }
            world.update { sessions in
                guard let sourceIndex = sessions.firstIndex(where: { $0.id == sourceID }),
                    let destIndex = sessions.firstIndex(where: { $0.id == destID }),
                    let windowIndex = sessions[sourceIndex].windows.firstIndex(where: { $0.id == targetWindowID })
                else { return }
                let moved = sessions[sourceIndex].windows.remove(at: windowIndex)
                sessions[destIndex].windows.append(moved)
                sessions[sourceIndex].revision += 1
                sessions[destIndex].revision += 1
            }
            return .result(["revision": 4, "to_revision": 2])
        }
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = 24
        welcome.serverRevision = 24
        let host = Host(address: "rex.example", username: "dev", serverKind: .rex, rexSocket: RexSocket(path: Self.path))
        let rexSession = session(Dialer([ScriptedRexHost(control: [.server(server, welcome: welcome)])]))
        let suite = "rex-move-pane-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let projection = RexConsoleProjection(
            host: host, session: rexSession, memory: HerdrCoreHostMemory(defaults: defaults),
            pins: PinnedAgentsStore(), onChange: {})
        projection.start(isActive: true)
        defer { projection.end() }

        for _ in 0..<500 where projection.inventory == nil || projection.kernel == nil || projection.apiRevision != 24 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(projection.inventory != nil)
        try #require(projection.kernel != nil)
        try #require(projection.apiRevision == 24)

        let moved = try await projection.movePane("session:studio/block:single", to: .workspace(id: "session:dest"))
        #expect(moved == "session:dest/block:single")

        let transfersAfterValid = await server.requests.filter { $0.method == RexControlProtocol.transferWindowMethod }
        #expect(transfersAfterValid.count == 1)
        #expect(
            transfersAfterValid[0].payload
                == RexControlProtocol.transferWindowPayload(
                    sessionID: "session:studio", windowID: "window:0000-0000-0000-00000000c0c0",
                    toSessionID: "session:dest", focus: false))

        await #expect(throws: (any Error).self) {
            _ = try await projection.movePane("session:studio/block:left", to: .workspace(id: "session:dest"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await projection.movePane("session:studio/block:detached", to: .workspace(id: "session:dest"))
        }
        let transfersAfterRejected = await server.requests.filter { $0.method == RexControlProtocol.transferWindowMethod }
        #expect(transfersAfterRejected.count == 1)
    }
}

/// A snapshot of a session's updates, for a wait's condition.
struct RexHostSessionUpdateLog {
    let updates: [RexHostSessionUpdate]

    var statuses: [EventsSessionStatus] {
        updates.compactMap { if case .status(let status) = $0 { status } else { nil } }
    }

    var servers: [String] {
        updates.compactMap { if case .server(let server) = $0 { server.instanceID } else { nil } }
    }

    var cores: [String] {
        updates.compactMap { if case .server(let server) = $0 { server.coreID } else { nil } }
    }

    var inventories: [RexInventory] {
        updates.compactMap { if case .inventory(let inventory) = $0 { inventory } else { nil } }
    }
}

private func blockIDsOf(_ inventory: RexInventory?) -> [String] {
    inventory?.sessions.flatMap { $0.terminals.map(\.blockID) } ?? []
}
