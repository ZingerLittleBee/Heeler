import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A Rex Host's session over scripted SSH connections and fake servers: what
/// it attaches to, how it follows the inventory, how it survives a dropped
/// link or a server that let go of its client, another server instance, and
/// failures that read as status (ADR 0048). Ids, labels and tokens are invented.
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

    /// Suspending drops the link without a close frame, and the next
    /// connection takes the client back over a new SSH connection.
    @Test func aSuspendedSessionResumesItsClientOverANewConnection() async throws {
        let world = world()
        let first = await server(world)
        let second = await server(world)
        let dialer = Dialer([ScriptedRexHost(control: [.server(first)]), ScriptedRexHost(control: [.server(second)])])
        let session = session(dialer)
        let log = UpdateLog(session)
        await session.resume()
        try await waitForSettledInventory(log)

        await session.suspend()
        #expect(!(await first.clientSentCloseFrame))
        try await log.waitUntil("the suspension") { $0.statuses.last == .suspended }
        let before = log.inventories.count
        await session.resume()
        try await log.waitUntil("an inventory after resuming") {
            $0.statuses.last == .connected && $0.inventories.count > before
        }

        #expect(dialer.dialsResuming == [false, true])
        #expect(await second.nextHello()["reconnect_token"] == "fake-reconnect-token-0001")
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

    var inventories: [RexInventory] {
        updates.compactMap { if case .inventory(let inventory) = $0 { inventory } else { nil } }
    }
}

private func blockIDsOf(_ inventory: RexInventory?) -> [String] {
    inventory?.sessions.flatMap { $0.terminals.map(\.blockID) } ?? []
}
