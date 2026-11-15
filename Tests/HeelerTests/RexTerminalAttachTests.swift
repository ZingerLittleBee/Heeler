import Foundation
import HeelerSSH
import Synchronization
import Testing

@testable import Heeler

/// A Rex terminal opened for viewing (ADR 0049), from the Console's runner to
/// a fake server's block and data endpoint, through the store the view uses:
/// the first paint, live output and repaints, the size asked for and never
/// owned, input that never leaves, and every way it ends or survives a drop.
/// Ids, nonces, tokens and the redraw are invented.
@MainActor
@Suite("Rex terminal attach", .timeLimit(.minutes(1)))
struct RexTerminalAttachTests {
    static let socket = "/run/user/1000/rex/server.sock"
    static let address = RexPaneAddress(sessionID: "session:studio", blockID: "block:left")
    nonisolated static let redraw = "\u{1B}[H\u{1B}[2Jprompt$ "
    nonisolated static let ownerClient = "client:00000000-0000-7000-8000-0000000000aa"

    static func painted(_ redraw: String = RexTerminalAttachTests.redraw) -> Data {
        RexTerminalPaint.reset + Data(redraw.utf8)
    }

    /// What every control link of one Host is served from: one world, one
    /// data endpoint and its tickets, one block's reads, and the attach slots
    /// data channels take.
    final class Rig: Sendable {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let endpoint: FakeRexDataEndpoint
        let reads = FakeRexTerminalReads(redraw: RexTerminalAttachTests.redraw, title: "lab")
        let admission = SSHChannelAdmission()

        init(streams: Int = 3) {
            endpoint = FakeRexDataEndpoint(nonces: (0..<streams).map { 0x1111_2222_3333_4400 + UInt64($0) })
        }

        func server() async -> FakeRexServer {
            let server = FakeRexServer()
            await world.install(on: server)
            await endpoint.tickets.install(on: server)
            await reads.install(on: server)
            return server
        }

        /// One SSH connection whose control channels open to `controls`, in
        /// order, and whose data channels all open to the endpoint.
        func host(_ controls: [ScriptedRexHost.Channel]) async -> ScriptedRexHost {
            let host = ScriptedRexHost(control: controls, admission: admission)
            await host.serveData(from: endpoint)
            return host
        }

        /// Writes the start of stream `index`: a stand-in snapshot, then its
        /// first resize, owned by another client.
        func begin(stream index: Int = 0, columns: Int = 80, rows: Int = 24) async {
            await endpoint.waitForStreams(index + 1)
            let nonce = await endpoint.nonce(of: index)
            await endpoint.send(
                FakeRexStream.snapshot(byteCount: 300) + FakeRexStream.resize(
                    columns: columns, rows: rows, nonce: nonce, owner: RexTerminalAttachTests.ownerClient),
                on: index)
        }

        var attachSlotsTaken: Int {
            get async { await admission.snapshot().attach }
        }
    }

    /// Every chunk a store's view took, in order.
    final class Chunks: Sendable {
        private let chunks = Mutex<[Data]>([])
        func append(_ chunk: Data) { chunks.withLock { $0.append(chunk) } }
        var all: [Data] { chunks.withLock { $0 } }
        var text: String { String(decoding: all.reduce(Data(), +), as: UTF8.self) }
    }

    private func hostSession(_ hosts: [ScriptedRexHost]) -> RexHostSession {
        var options = RexTerminalAttach.Options()
        options.stream.link = .testing
        options.stream.startOverDelay = .milliseconds(20)
        options.stream.resumeDelay = .milliseconds(20)
        options.sizeSettle = .milliseconds(40)
        options.closeGrace = .milliseconds(150)
        let dialer = RexHostSessionTests.Dialer(hosts)
        return RexHostSession(
            storedSocket: RexSocket(path: Self.socket), connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            terminalOptions: options)
    }

    private var rexHost: Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: Self.socket))
    }

    /// A view's store on `address`, opened through the Rex Console's runner
    /// and keeping to `pin`'s server.
    private func store(
        _ session: RexHostSession, address: RexPaneAddress = Self.address, chunks: Chunks = Chunks(),
        input: TerminalInputController = TerminalInputController(), pin: TerminalCorePin = TerminalCorePin()
    ) -> AttachTerminalStore {
        let runner = RexConsoleProjection(host: rexHost, session: session, onChange: {}).terminalRunner()
        return AttachTerminalStore(
            target: .terminal(address.paneID), input: input, observeOutput: { chunks.append($0) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
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

    /// A store whose terminal painted once, on a session that answered.
    private func openPainted(
        _ rig: Rig, session: RexHostSession, chunks: Chunks = Chunks(),
        input: TerminalInputController = TerminalInputController(), pin: TerminalCorePin = TerminalCorePin()
    ) async throws -> AttachTerminalStore {
        let store = store(session, chunks: chunks, input: input, pin: pin)
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin()
        try await waitUntil("the first paint") { store.status == .live }
        return store
    }

    private func methods(_ server: FakeRexServer) async -> [String] {
        await server.requests.map(\.method)
    }

    private static let resizeMethod = RexInventoryWire.terminalMethod("resize")

    // MARK: Opening and painting

    /// The session is attached before the block's data link opens, nothing
    /// reaches the view before the first paint, and output follows it.
    @Test func itPaintsFirstThenFollowsTheOutput() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = store(session, chunks: chunks)

        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin()
        #expect(store.status == .connecting)
        try await waitUntil("the first paint") { store.status == .live }
        #expect(chunks.all == [Self.painted()])
        await rig.endpoint.send(Data("hello\r\n".utf8))
        try await waitUntil("the output") { chunks.all.count == 2 }
        #expect(chunks.all.last == Data("hello\r\n".utf8))

        let methods = await methods(control)
        let attach = try #require(methods.firstIndex(of: "session.attach"))
        let ticket = try #require(methods.firstIndex(of: "data.connect"))
        #expect(attach < ticket)
        let attachRequest = await control.requests.first { $0.method == "session.attach" }
        #expect(attachRequest?.payload == ["session_id": "session:studio"])
        #expect(await rig.attachSlotsTaken == 1)

        await store.stop()
        #expect(await rig.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])
        #expect(await rig.attachSlotsTaken == 0)
        #expect(await session.openTerminalCount == 0)
    }

    /// A new stream's first paint replaces the view in one write, and the
    /// view stays live through it.
    @Test func aRepaintReplacesTheView() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        await rig.endpoint.script(.refuse(reason: 3))
        rig.reads.set(redraw: "again")
        await rig.endpoint.drop()
        await rig.begin(stream: 1)
        try await waitUntil("the repaint") { chunks.all.count == 2 }

        #expect(chunks.all == [Self.painted(), Self.painted("again")])
        #expect(store.status == .live)
        await store.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    // MARK: Input and size

    /// Nothing the view writes leaves: no writer while connecting, painting
    /// or live, so its emulator's answers to a program's queries go nowhere.
    @Test func nothingTheViewWritesLeaves() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = store(session, input: input)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the stream") { await rig.endpoint.streamCount == 1 }
        // A program asks for its device attributes and cursor while it paints.
        await rig.begin()
        await rig.endpoint.send(Data("\u{1B}[c\u{1B}[6n".utf8))
        let answers = Data("\u{1B}[?62;22c\u{1B}[24;1R".utf8)
        #expect(!input.send(answers))
        try await waitUntil("the first paint") { store.status == .live }

        #expect(!RexTerminalInput.isOpen)
        #expect(input.liveGeneration == nil)
        #expect(!input.send(answers))
        #expect(!input.send(Data("ls\r".utf8)))
        #expect(input.requestPaste("echo hi", bracketedPaste: true) == .blocked)
        input.scroll(Data("\u{1B}[A".utf8), rows: 1)
        store.send(Data("ls\r".utf8))
        try await Task.sleep(for: .milliseconds(100))

        let asked = Set(await methods(control))
        let allowed = Set([
            "server.status", "session.attach_all", "session.view", "session.list_blocks", "session.attach",
            "data.connect", Self.resizeMethod,
        ]).union(["title", "process", "modes", "format", "blob_read"].map(RexInventoryWire.terminalMethod))
        #expect(asked.isSubset(of: allowed), "\(asked.subtracting(allowed))")
        await store.stop()
    }

    /// The view's grid is asked for on arrival and once it settles after a
    /// change, again when the owner lets go, and the block is never owned.
    @Test func itAsksForItsSizeAndNeverOwnsTheBlock() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openPainted(rig, session: session)
        func resizes() async -> [JSONValue?] {
            await control.requests.filter { $0.method == Self.resizeMethod }.map { $0.payload?["args"] }
        }
        func asked(_ columns: Int, _ rows: Int) -> JSONValue? {
            ["columns": .number(Double(columns)), "rows": .number(Double(rows))]
        }
        try await waitUntil("the size on arrival") { await resizes().count == 1 }
        #expect(await resizes() == [asked(80, 24)])
        let report = try #require(store.sizeReport)
        #expect(report.server == .init(columns: 80, rows: 24))
        #expect(report.local == .init(columns: 80, rows: 24))
        #expect(report.owner == Self.ownerClient)
        #expect(report.client == "client:00000000-0000-7000-8000-000000000001")

        store.viewDidResize(cols: 100, rows: 30)
        store.viewDidResize(cols: 90, rows: 30)
        try await waitUntil("the settled size") { await resizes().count == 2 }
        #expect(await resizes().last == asked(90, 30))
        #expect(store.sizeReport?.isMismatched == true)
        // A foreground return's nudge settles where it started: nothing new.
        store.didBecomeActive()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await resizes().count == 2)

        await control.push(
            "block_owner_changed", ["block_id": "block:left", "owner": .null, "previous": .string(Self.ownerClient)],
            session: "session:studio")
        try await waitUntil("the size asked again") { await resizes().count == 3 }
        #expect(await resizes().last == asked(90, 30))
        #expect(store.sizeReport?.owner == nil)
        #expect(await methods(control).allSatisfy { !$0.contains("own_block") })
        await store.stop()
    }

    // MARK: Endings

    @Test func aClosedBlockFinishesTheTerminal() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        await rig.endpoint.send(Data("bye".utf8))
        await rig.endpoint.close(code: WebSocketCloseCode(rawValue: RexDataEnding.blockClosedCode))
        try await waitUntil("the end") { store.status == .finished }
        #expect(chunks.all.last == Data("bye".utf8))
        // No reattach follows.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.endpoint.tickets.requests.count == 1)
        #expect(await rig.attachSlotsTaken == 0)
        #expect(await session.openTerminalCount == 0)
    }

    /// The block's close event ends the terminal even when its data link
    /// says nothing.
    @Test func aBlockClosedEventFinishesTheTerminal() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let store = try await openPainted(rig, session: session)

        await control.push("block_closed", ["block_id": "block:left"], session: "session:studio")
        try await waitUntil("the end") { store.status == .finished }
        #expect(await rig.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])
        #expect(rig.endpoint.tickets.requests.count == 1)
    }

    /// Another block's close changes nothing.
    @Test func anotherBlocksCloseChangesNothing() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        await control.push("block_closed", ["block_id": "block:right"], session: "session:studio")
        try await Task.sleep(for: .milliseconds(250))
        await rig.endpoint.send(Data("still".utf8))
        try await waitUntil("the output") { chunks.all.count == 2 }
        #expect(store.status == .live)
        await store.stop()
    }

    @Test func theProgramsExitFinishesTheTerminal() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        let nonce = await rig.endpoint.nonce(of: 0)
        await rig.endpoint.send(Data("logout\r\n".utf8) + FakeRexStream.childExited(code: 0, nonce: nonce))
        try await waitUntil("the end") { store.status == .finished }
        #expect(chunks.all.last == Data("logout\r\n".utf8))
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// A dropped data link, the control link fine, is resumed with every
    /// byte counted: no new stream, no new paint.
    @Test func aDroppedDataLinkIsResumedWithItsExactCount() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)
        await rig.endpoint.send(Data("one".utf8))
        try await waitUntil("the output") { chunks.all.count == 2 }

        let sent = await rig.endpoint.sentByteCount(of: 0)
        await rig.endpoint.drop()
        await rig.endpoint.waitForHandshakes(2)
        #expect(await rig.endpoint.handshakes.last?.kind == .resume(count: sent))
        #expect(await rig.endpoint.handshakes.last?.outcome == .welcomed(stream: 0))
        await rig.endpoint.send(Data("two".utf8))
        try await waitUntil("the output after the resume") { chunks.all.count == 3 }
        #expect(chunks.all.dropFirst().map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
        #expect(store.status == .live)
        #expect(await rig.attachSlotsTaken == 1)
        await store.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// A control link that drops and takes its client back leaves the data
    /// stream alone, and the client's attachment stands.
    @Test func aResumedControlClientKeepsTheStream() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: resumed)])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        await first.drop()
        try await waitUntil("the resumed link") { await second.requests.contains { $0.method == "server.status" } }
        try await Task.sleep(for: .milliseconds(50))
        await rig.endpoint.send(Data("still here".utf8))
        try await waitUntil("the output") { chunks.all.count == 2 }
        #expect(store.status == .live)
        #expect(await rig.endpoint.handshakes.count == 1)
        #expect(await !methods(second).contains("session.attach"))
        await store.stop()
    }

    /// A control client the server does not know has no attachments and no
    /// streams: the session is attached again, and the terminal reattaches
    /// and paints afresh.
    @Test func aNewControlClientPaintsAfresh() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = "client:00000000-0000-7000-8000-000000000002"
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        rig.reads.set(redraw: "fresh")
        await first.drop()
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { chunks.all.count == 2 && store.status == .live }
        #expect(chunks.all.last == Self.painted("fresh"))
        let methods = await methods(second)
        #expect(methods.filter { $0 == "session.attach" }.count == 1)
        #expect(methods.contains("data.connect"))
        #expect(await rig.endpoint.clientCloses.first == WebSocketClose(code: .normalClosure))
        try await waitUntil("one slot") { await rig.attachSlotsTaken == 1 }
        await store.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// A stream refused for want of an attach means the server no longer
    /// counts the session as attached for this client: the next attach sends
    /// `session.attach` again, on the same client, and paints afresh.
    @Test func aStreamRefusedForWantOfAnAttachAttachesAgain() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        // The resume is refused, and each new ticket after it too.
        let conflict = FakeRexServer.Answer.error(code: "conflict", message: "attach first", status: 409)
        rig.endpoint.tickets.fail(with: Array(repeating: conflict, count: 3))
        await rig.endpoint.script(.refuse(reason: 3))
        rig.reads.set(redraw: "attached again")
        await rig.endpoint.drop()
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { chunks.all.count == 2 && store.status == .live }

        #expect(chunks.all.last == Self.painted("attached again"))
        #expect(await methods(control).filter { $0 == "session.attach" }.count == 2)
        #expect(rig.endpoint.tickets.requests.count == 5)
        await store.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// A new SSH connection ends the terminal's link, and the next attach
    /// paints afresh on the new one.
    @Test func aNewSSHConnectionPaintsAfresh() async throws {
        let rig = Rig()
        let firstHost = await rig.host([.server(await rig.server())])
        let secondHost = await rig.host([.server(await rig.server())])
        let session = hostSession([firstHost, secondHost])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        rig.reads.set(redraw: "new connection")
        try await firstHost.close()
        await firstHost.servers.first?.drop()
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { chunks.all.count == 2 && store.status == .live }
        #expect(chunks.all.last == Self.painted("new connection"))
        #expect(session.currentConnectionGeneration == 1)
        await store.stop()
    }

    /// Another server instance on the socket finishes a terminal of the last
    /// one, with no reattach.
    @Test func anotherServerFinishesTheTerminal() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = "client:00000000-0000-7000-8000-000000000003"
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let pin = TerminalCorePin()
        let store = try await openPainted(rig, session: session, pin: pin)

        rig.world.restart(as: "instance-0002")
        await first.close(.goingAway, reason: "shutting down")
        try await waitUntil("the end") { store.status == .finished }
        #expect(!pin.admits("instance-0002"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !methods(second).contains("data.connect"))
    }

    /// Suspending with the app ends the terminal's link with the SSH
    /// connection; the next activation paints it afresh.
    @Test func suspendingThenResumingPaintsAfresh() async throws {
        let rig = Rig()
        let session = hostSession([
            await rig.host([.server(await rig.server())]), await rig.host([.server(await rig.server())]),
        ])
        defer { Task { await session.end() } }
        await session.resume()
        let chunks = Chunks()
        let store = try await openPainted(rig, session: session, chunks: chunks)

        await session.suspend()
        try await waitUntil("the wait for the Host") { store.status == .reconnecting }
        rig.reads.set(redraw: "back")
        await session.resume()
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { chunks.all.count == 2 && store.status == .live }
        #expect(chunks.all.last == Self.painted("back"))
        await store.stop()
    }

    /// The Host stopping ends the terminal, and its data link closes.
    @Test func theHostStoppingEndsTheTerminal() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        await session.resume()
        let store = try await openPainted(rig, session: session)

        await session.end()
        try await waitUntil("the end") {
            if case .ended = store.status { true } else { false }
        }
        #expect(await rig.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])
        #expect(await session.openTerminalCount == 0)
    }

    // MARK: One stream per block

    /// A second view of the same block waits for the first one's stream to
    /// end before it asks for its own, so the block never has two.
    @Test func aBlockHasOneDataConnectionAtATime() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let firstChunks = Chunks()
        let first = try await openPainted(rig, session: session, chunks: firstChunks)

        let secondChunks = Chunks()
        let second = store(session, chunks: secondChunks)
        second.viewDidResize(cols: 80, rows: 24)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.endpoint.handshakes.count == 1)
        #expect(rig.endpoint.tickets.requests.count == 1)
        #expect(second.status == .connecting)

        rig.reads.set(redraw: "second")
        await first.stop()
        await rig.begin(stream: 1)
        try await waitUntil("the second view's paint") { second.status == .live }
        await rig.endpoint.send(Data("only the second".utf8), on: 1)
        try await waitUntil("the second view's output") { secondChunks.all.count == 2 }

        // The replaced view never heard of the new link.
        #expect(firstChunks.all == [Self.painted()])
        #expect(secondChunks.all == [Self.painted("second"), Data("only the second".utf8)])
        #expect(await rig.endpoint.handshakes.map(\.kind) == [.hello, .hello])
        #expect(await rig.attachSlotsTaken == 1)
        await second.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// Data links take the connection's attach slots: a sixth waits for one
    /// of five to end, and every ending gives its slot back.
    @Test func dataLinksTakeTheAttachSlots() async throws {
        let rig = Rig(streams: 7)
        rig.world.update { sessions in sessions[0].detached.append(FakeRexWorld.Block("block:extra")) }
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let blocks = ["block:left", "block:right", "block:solo", "block:float", "block:detached"]
        var stores: [AttachTerminalStore] = []
        for (index, block) in blocks.enumerated() {
            let store = store(session, address: RexPaneAddress(sessionID: "session:studio", blockID: block))
            store.viewDidResize(cols: 80, rows: 24)
            await rig.begin(stream: index)
            try await waitUntil("\(block)'s paint") { store.status == .live }
            stores.append(store)
        }
        #expect(await rig.attachSlotsTaken == 5)

        let sixth = store(session, address: RexPaneAddress(sessionID: "session:studio", blockID: "block:extra"))
        sixth.viewDidResize(cols: 80, rows: 24)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await rig.endpoint.handshakes.count == 5)
        #expect(sixth.status == .connecting)

        await stores.removeFirst().stop()
        await rig.begin(stream: 5)
        try await waitUntil("the sixth view's paint") { sixth.status == .live }
        #expect(await rig.attachSlotsTaken == 5)
        for store in stores + [sixth] { await store.stop() }
        #expect(await rig.attachSlotsTaken == 0)
        #expect(await session.openTerminalCount == 0)
    }

    /// A view closed and opened again at once never meets its old stream.
    @Test func aQuickCloseAndReopenAsksForOneStreamAtATime() async throws {
        let rig = Rig()
        let session = hostSession([await rig.host([.server(await rig.server())])])
        defer { Task { await session.end() } }
        await session.resume()
        let first = try await openPainted(rig, session: session)

        let closing = Task { await first.stop() }
        let reopened = store(session)
        reopened.viewDidResize(cols: 80, rows: 24)
        await closing.value
        await rig.begin(stream: 1)
        try await waitUntil("the reopened view's paint") { reopened.status == .live }
        #expect(await rig.endpoint.handshakes.map(\.outcome) == [.welcomed(stream: 0), .welcomed(stream: 1)])
        await reopened.stop()
    }
}
