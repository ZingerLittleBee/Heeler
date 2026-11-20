import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Chat's requests to one Rex block on the control link (ADR 0055): reads and
/// input pinned to the server, connection and client they were made on,
/// input once each and in the block's lane, which an open terminal view's
/// input shares, and nothing that opens a data link, asks for a size or
/// takes a block. Ids, tokens and texts are invented.
@MainActor
@Suite("Rex block requests", .timeLimit(.minutes(1)))
struct RexBlockRequestsTests {
    typealias Rig = RexTerminalAttachTests.Rig
    static let address = RexTerminalAttachTests.address
    static let write = RexInventoryWire.terminalMethod("write")
    static let readDeadline = RexDeliveryDeadline(silence: .seconds(5), limit: .seconds(10))

    /// Everything Chat may ask of a block, and the inventory's own reads.
    static let allowedMethods: Set<String> = [
        "server.status", "server.version", "session.attach_all", "session.view", "session.list_blocks",
        RexInventoryWire.terminalMethod("title"), RexInventoryWire.terminalMethod("process"),
        RexInventoryWire.terminalMethod("program_status"), RexInventoryWire.terminalMethod("modes"),
        RexInventoryWire.terminalMethod("size"), RexInventoryWire.terminalMethod("format"),
        RexInventoryWire.terminalMethod("blob_read"), write, "block.event",
    ]

    private func hostSession(
        _ dialer: RexHostSessionTests.Dialer, inputDeadline: RexDeliveryDeadline? = nil
    ) -> RexHostSession {
        var options = RexTerminalAttach.Options()
        options.stream.link = .testing
        options.stream.startOverDelay = .milliseconds(20)
        options.stream.resumeDelay = .milliseconds(20)
        options.sizeSettle = .milliseconds(40)
        options.closeGrace = .milliseconds(150)
        if let inputDeadline { options.inputDeadline = inputDeadline }
        return RexHostSession(
            storedSocket: RexSocket(path: RexTerminalAttachTests.socket), connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            terminalOptions: options)
    }

    private func served(_ world: FakeRexWorld) async -> FakeRexServer {
        let server = FakeRexServer()
        await world.install(on: server)
        return server
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool
    ) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    /// Requests on a session that answered.
    private func requests(_ session: RexHostSession) async throws -> RexBlockRequests {
        var made: RexBlockRequests?
        try await waitUntil("a server") {
            made = try? await session.blockRequests(at: Self.address, readDeadline: Self.readDeadline)
            return made != nil
        }
        return try #require(made)
    }

    private func inputRequests(_ server: FakeRexServer) async -> [FakeRexServer.Request] {
        await server.requests.filter { $0.method == Self.write || $0.method == "block.event" }
    }

    // MARK: What goes out

    /// Reads name the block and the read's own arguments; text goes to the
    /// terminal's `write` and a paste as `block.event`, in order, and nothing
    /// asks for a size, takes the block, attaches the session or opens a
    /// data link.
    @Test func readsAndInputGoOnTheControlLinkAndTakeNothing() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        await server.answer(RexInventoryWire.terminalMethod("format"), with: .result(["content": "row", "eof": true]))
        await server.answer(RexInventoryWire.terminalMethod("blob_read"), with: .result(["data": "w", "eof": true]))
        await server.answer(RexInventoryWire.terminalMethod("size"), with: .result(["columns": 80, "rows": 24]))
        await server.answer(RexInventoryWire.terminalMethod("modes"), with: .result(["screen": "primary", "modes": []]))
        await server.answer(Self.write, with: .result(["bytes_written": 2]))
        await server.answer("block.event", with: .result([:]))
        let host = ScriptedRexHost(control: [.server(server)])
        let session = hostSession(RexHostSessionTests.Dialer([host]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        #expect(try await requests.read(.process)["foreground"]?["name"] == "make")
        #expect(try await requests.read(.size)["rows"] == 24)
        _ = try await requests.read(.modes)
        _ = try await requests.read(.format(maxBytes: 1024))
        _ = try await requests.read(.format(maxBytes: 64, kittyKeyboard: true))
        _ = try await requests.read(.blobRead(id: 7, offset: 300, maxBytes: 4096))
        #expect(try await requests.send([.text("hi"), .paste("first\nsecond")]) == .sent)

        let sent = await server.requests
        let formats = sent.filter { $0.method == RexInventoryWire.terminalMethod("format") }
        #expect(formats.map { $0.payload?["args"] } == [
            ["format": "vt", "unwrap": false, "max_bytes": 1024],
            ["format": "vt", "unwrap": false, "max_bytes": 64, "extra_kitty_keyboard": true],
        ])
        #expect(formats.allSatisfy { $0.payload?["session_id"] == "session:studio" && $0.payload?["block_id"] == "block:left" })
        let blob = sent.first { $0.method == RexInventoryWire.terminalMethod("blob_read") }
        #expect(blob?.payload?["args"] == ["id": 7, "offset": 300, "max_bytes": 4096])
        #expect(
            await inputRequests(server).map { $0.payload?["args"]?["data"] ?? $0.payload?["event"] ?? .null } == [
                "hi", ["type": "paste", "payload": ["text": "first\nsecond"]],
            ])
        #expect(Set(sent.map(\.method)).isSubset(of: Self.allowedMethods))
        #expect(await host.log == ["control \(RexTerminalAttachTests.socket)"])
    }

    /// Only text and pastes go: an event of any other kind is not Chat's.
    @Test func otherEventsAreNotSent() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let session = hostSession(RexHostSessionTests.Dialer([ScriptedRexHost(control: [.server(server)])]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        let outcome = try await requests.send([.text("a"), .event(type: "focus", payload: ["action": "in"])])
        #expect(outcome == .notSent(nil))
        #expect(await inputRequests(server).isEmpty)
    }

    // MARK: Once each

    /// A request with no answer may have arrived: nothing after it goes, and
    /// it is never sent again.
    @Test func nothingFollowsOrRepeatsARequestWithNoAnswer() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let session = hostSession(
            RexHostSessionTests.Dialer([ScriptedRexHost(control: [.server(server)])]),
            inputDeadline: RexDeliveryDeadline(silence: .milliseconds(100), limit: .milliseconds(200)))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        #expect(try await requests.send([.text("first"), .text("second")]) == .unknown)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inputRequests(server).map { $0.payload?["args"]?["data"] } == ["first"])
    }

    /// The server's refusal of the first request says the block got nothing,
    /// and why; one after an answered request leaves the outcome unknown.
    @Test func aRefusalSaysWhetherAnythingArrived() async throws {
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let session = hostSession(RexHostSessionTests.Dialer([ScriptedRexHost(control: [.server(server)])]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        async let first = requests.send([.text("gone"), .text("never")])
        await server.fail(await server.nextRequest(), code: "not_found", message: "no such block", status: 404)
        guard case .notSent(let failure?) = try await first else {
            Issue.record("A refused first request should send nothing")
            return
        }
        #expect(failure.kind == .notFound)

        async let second = requests.send([.text("one"), .text("two"), .text("three")])
        await server.respond(to: await server.nextRequest(), with: ["bytes_written": 3])
        await server.fail(await server.nextRequest(), code: "internal", message: "input/output error", status: 500)
        #expect(try await second == .unknown)
        #expect(await inputRequests(server).map { $0.payload?["args"]?["data"] } == ["gone", "one", "two"])
    }

    /// A confirmation that throws, holding the lane, sends nothing.
    @Test func aConfirmationThatThrowsSendsNothing() async throws {
        struct Changed: Error {}
        let server = await served(FakeRexWorld(sessions: [FakeRexWorld.studio()]))
        let session = hostSession(RexHostSessionTests.Dialer([ScriptedRexHost(control: [.server(server)])]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        await #expect(throws: Changed.self) {
            try await requests.send([.text("x")]) { throw Changed() }
        }
        #expect(await inputRequests(server).isEmpty)
        // The lane is free again.
        await server.answer(Self.write, with: .result(["bytes_written": 1]))
        #expect(try await requests.send([.text("y")]) == .sent)
    }

    // MARK: Pinned

    /// Requests made on one server mean nothing to another on the same
    /// socket, whose block ids may repeat: a read says the server is gone and
    /// input is not sent, there or anywhere.
    @Test func anotherServerGetsNothing() async throws {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let servers = [await served(world), await served(world)]
        let session = hostSession(
            RexHostSessionTests.Dialer([ScriptedRexHost(control: servers.map { .server($0) })]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)

        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") {
            (try? await session.blockRequests(at: Self.address, readDeadline: Self.readDeadline))?.server.instanceID
                == "instance-0002"
        }

        await #expect(throws: TransportError.rexServerGone) { try await requests.read(.process) }
        #expect(try await requests.send([.text("late")]) == .notSent(nil))
        #expect(await inputRequests(servers[0]).isEmpty)
        #expect(await inputRequests(servers[1]).isEmpty)
    }

    /// A new SSH connection and client of the same server are not the ones
    /// the requests were made on: nothing goes until Chat makes them again.
    @Test func aNewConnectionGetsNothing() async throws {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let first = await served(world)
        let second = await served(world)
        let session = hostSession(
            RexHostSessionTests.Dialer([
                ScriptedRexHost(control: [.server(first)]), ScriptedRexHost(control: [.server(second)]),
            ]))
        defer { Task { await session.end() } }
        await session.resume()
        let requests = try await requests(session)
        let generation = session.currentConnectionGeneration

        await session.suspend()
        await session.resume()
        try await waitUntil("the next connection") {
            guard session.currentConnectionGeneration != generation else { return false }
            return (try? await session.blockRequests(at: Self.address, readDeadline: Self.readDeadline)) != nil
        }

        await #expect(throws: TransportError.self) { try await requests.read(.process) }
        #expect(try await requests.send([.text("late")]) == .notSent(nil))
        #expect(await inputRequests(first).isEmpty)
        #expect(await inputRequests(second).isEmpty)
    }

    /// With no server answering there is nothing to pin to.
    @Test func noServerNoRequests() async throws {
        let session = hostSession(RexHostSessionTests.Dialer([]))
        defer { Task { await session.end() } }
        var refused = false
        do {
            _ = try await session.blockRequests(at: Self.address, readDeadline: Self.readDeadline)
        } catch is TransportError {
            refused = true
        }
        #expect(refused)
    }

    // MARK: Taking turns with an open terminal

    private func openTerminal(
        _ rig: Rig, session: RexHostSession, input: TerminalInputController
    ) async throws -> AttachTerminalStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(host: host, session: session, pins: PinnedAgentsStore(), onChange: {})
            .terminalRunner()
        let pin = TerminalCorePin()
        let store = AttachTerminalStore(
            target: .terminal(Self.address.paneID), input: input, observeOutput: { _ in },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin()
        try await waitUntil("the first paint") { store.status == .live }
        return store
    }

    /// Chat's input and an open terminal's go one request at a time between
    /// them, in the order they asked: a key typed while Chat's pieces are out
    /// waits for all of them, and Chat waits for a key that is out.
    @Test func chatAndAnOpenTerminalTakeTurnsAtTheBlock() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession(RexHostSessionTests.Dialer([await rig.host([.server(control)])]))
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openTerminal(rig, session: session, input: input)
        let requests = try await requests(session)

        async let chat = requests.send([.text("chat-1"), .paste("chat-2")])
        let chatFirst = await control.nextRequest()
        #expect(input.send(Data("k".utf8)))
        try await waitUntil("the key in line") { session.inputWaiting(at: Self.address) == 1 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await inputRequests(control).count == 1)
        await control.respond(to: chatFirst, with: ["bytes_written": 6])
        let chatSecond = await control.nextRequest()
        #expect(chatSecond.method == "block.event")
        await control.respond(to: chatSecond)
        #expect(try await chat == .sent)
        let key = await control.nextRequest()
        #expect(key.payload?["args"]?["data"] == "k")

        // A key out holds Chat back until it is answered.
        async let later = requests.send([.text("chat-3")])
        try await waitUntil("Chat in line") { session.inputWaiting(at: Self.address) == 1 }
        #expect(await inputRequests(control).count == 3)
        await control.respond(to: key, with: ["bytes_written": 1])
        let chatThird = await control.nextRequest()
        #expect(chatThird.payload?["args"]?["data"] == "chat-3")
        await control.respond(to: chatThird, with: ["bytes_written": 6])
        #expect(try await later == .sent)
        await store.stop()
    }
}
