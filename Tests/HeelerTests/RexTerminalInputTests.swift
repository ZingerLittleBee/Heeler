import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// Input to a Rex terminal (ADR 0052), from the controller the view writes
/// through to a fake server's block: one request at a time and in order, typed
/// text through the terminal's `write`, pastes and events through
/// `block.event`, the gate, and what happens to input whose fate is unknown.
/// Ids, nonces, tokens and the redraw are invented.
@MainActor
@Suite("Rex terminal input", .timeLimit(.minutes(1)))
struct RexTerminalInputTests {
    typealias Rig = RexTerminalAttachTests.Rig
    static let address = RexTerminalAttachTests.address
    static let write = RexInventoryWire.terminalMethod("write")
    static let inputFailed = AttachTerminalStore.message(
        for: TransportError.channelFailed(detail: String(localized: "attach input failed")))

    /// What reached the block, in order: text joined across writes, and events.
    enum Sent: Equatable, CustomStringConvertible {
        case text(String)
        case event(String, JSONValue)

        var description: String {
            switch self {
            case .text(let text): "text \(text.debugDescription)"
            case .event(let type, let payload): "event \(type) \(payload)"
            }
        }
    }

    static func sent(_ requests: [FakeRexServer.Request]) -> [Sent] {
        var sent: [Sent] = []
        for request in requests {
            if request.method == write, let data = request.payload?["args"]?["data"]?.stringValue {
                if case .text(let previous)? = sent.last {
                    sent[sent.count - 1] = .text(previous + data)
                } else {
                    sent.append(.text(data))
                }
            } else if request.method == "block.event", let event = request.payload?["event"],
                let type = event["type"]?.stringValue
            {
                sent.append(.event(type, event["payload"] ?? .null))
            }
        }
        return sent
    }

    private func sent(_ server: FakeRexServer) async -> [Sent] {
        Self.sent(await server.requests)
    }

    private func inputRequests(_ server: FakeRexServer) async -> [FakeRexServer.Request] {
        await server.requests.filter { $0.method == Self.write || $0.method == "block.event" }
    }

    /// The server answers every write and event at once.
    private func answerInput(on server: FakeRexServer) async {
        await server.answer(Self.write, with: .result(["bytes_written": 1]))
        await server.answer("block.event", with: .result([:]))
    }

    private func hostSession(
        _ hosts: [ScriptedRexHost], closeGrace: Duration = .milliseconds(150),
        inputDeadline: Duration = .seconds(10), inputLimit: Duration = .seconds(60)
    ) -> RexHostSession {
        var options = RexTerminalAttach.Options()
        options.stream.link = .testing
        options.stream.startOverDelay = .milliseconds(20)
        options.stream.resumeDelay = .milliseconds(20)
        options.sizeSettle = .milliseconds(40)
        options.closeGrace = closeGrace
        options.inputDeadline = RexDeliveryDeadline(silence: inputDeadline, limit: inputLimit)
        let dialer = RexHostSessionTests.Dialer(hosts)
        return RexHostSession(
            storedSocket: RexSocket(path: RexTerminalAttachTests.socket), connect: { try await dialer.dial($0, $1) },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
            terminalOptions: options)
    }

    private func store(
        _ session: RexHostSession, input: TerminalInputController,
        chunks: RexTerminalAttachTests.Chunks = RexTerminalAttachTests.Chunks()
    ) -> AttachTerminalStore {
        let host = Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: RexTerminalAttachTests.socket))
        let runner = RexConsoleProjection(
            host: host, session: session, pins: PinnedAgentsStore(), onChange: {}
        ).terminalRunner()
        let pin = TerminalCorePin()
        return AttachTerminalStore(
            target: .terminal(Self.address.paneID), input: input, observeOutput: { chunks.append($0) },
            runTerminal: { request, handler in try await runner(request, handler.keeping(to: pin)) })
    }

    private func openPainted(
        _ rig: Rig, session: RexHostSession, input: TerminalInputController, stream: Int = 0,
        chunks: RexTerminalAttachTests.Chunks = RexTerminalAttachTests.Chunks()
    ) async throws -> AttachTerminalStore {
        let store = store(session, input: input, chunks: chunks)
        store.viewDidResize(cols: 80, rows: 24)
        await rig.begin(stream: stream)
        try await waitUntil("the first paint") { store.status == .live }
        return store
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

    private func type(_ text: String, into input: TerminalInputController) {
        #expect(input.send(Data(text.utf8)))
    }

    // MARK: Typing

    /// Typed text, the Keys panel's Ctrl-C and the Esc key go to the block as
    /// text through its `write`; nothing is typed before the first paint.
    @Test func typedKeysLeaveAsText() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = store(session, input: input)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the stream") { await rig.endpoint.streamCount == 1 }
        #expect(!input.send(Data("early\r".utf8)))
        await rig.begin()
        try await waitUntil("the first paint") { store.status == .live }

        type("ls\r", into: input)
        #expect(input.send(Data([0x03])))
        #expect(await input.sendEscapeKeyAcknowledged())
        try await waitUntil("the keys") { await sent(control) == [.text("ls\r\u{03}\u{1B}")] }
        let first = try #require(await inputRequests(control).first)
        #expect(first.payload?["session_id"] == "session:studio")
        #expect(first.payload?["block_id"] == "block:left")
        #expect(first.payload?["args"]?["data"]?.stringValue?.hasPrefix("ls\r") == true)
        await store.stop()
    }

    /// A burst arrives whole and in order, one request out at a time: what
    /// queued while one was out leaves as the next write.
    @Test func aBurstArrivesInOrderOneRequestAtATime() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        let tokens = (1...200).map { String(format: "%04d ", $0) }
        for token in tokens { type(token, into: input) }
        var received = ""
        var answered = 0
        while received.count < tokens.joined().count {
            let request = await control.nextRequest()
            #expect(request.method == Self.write)
            // Nothing else is out while this one waits for its answer.
            if answered < 3 { try await Task.sleep(for: .milliseconds(30)) }
            #expect(await inputRequests(control).count == answered + 1)
            received += request.payload?["args"]?["data"]?.stringValue ?? ""
            await control.respond(to: request, with: ["bytes_written": 1])
            answered += 1
        }
        #expect(received == tokens.joined())
        #expect(answered < tokens.count)
        print("Rex input: \(tokens.count) writes left as \(answered) requests")
        await store.stop()
    }

    /// Keystrokes that queue while a request is out join the next write, but
    /// never across a paste or an event.
    @Test func mergingStopsAtPastesAndEvents() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("a", into: input)
        let held = await control.nextRequest()
        type("x", into: input)
        type("\u{1B}[I", into: input)
        type("y", into: input)
        #expect(input.requestPaste("p", bracketedPaste: true) == .inserted)
        type("z", into: input)
        type("w", into: input)
        try await Task.sleep(for: .milliseconds(30))
        await control.respond(to: held)
        for _ in 0..<5 {
            await control.respond(to: await control.nextRequest())
        }
        #expect(
            await inputRequests(control).map { $0.payload?["args"]?["data"] ?? $0.payload?["event"] ?? .null } == [
                "a", "x", ["type": "focus", "payload": ["action": "in"]], "y",
                ["type": "paste", "payload": ["text": "p"]], "zw",
            ])
        await store.stop()
    }

    /// Answers to a program's queries never leave, while what was typed
    /// around them does.
    @Test func queryAnswersAreDroppedWhileTyping() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("l", into: input)
        for answer in RexTerminalKeyReaderTests.labAnswers { _ = input.send(Data(answer.utf8)) }
        type("s", into: input)
        for answer in RexTerminalKeyReaderTests.otherAnswers { _ = input.send(Data(answer.utf8)) }
        type("\r", into: input)
        try await waitUntil("the keys") { await sent(control) == [.text("ls\r")] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await sent(control) == [.text("ls\r")])
        await store.stop()
    }

    @Test func focusChangesGoAsEvents() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("\u{1B}[O", into: input)
        type("\u{1B}[I", into: input)
        try await waitUntil("the focus events") { await sent(control).count == 2 }
        #expect(await sent(control) == [.event("focus", ["action": "out"]), .event("focus", ["action": "in"])])
        await store.stop()
    }

    /// Under mouse tracking a touch scroll is the program's own wheel report:
    /// text in SGR, and the event it stands for when a legacy report runs
    /// past column 95. With no tracking nothing reaches the block (see
    /// `RexTerminalKeyReaderTests.wheelReportsFollowTheProgramsMouseMode`).
    @Test func wheelReportsLeaveAsTextOrEvents() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        input.scroll(Data("\u{1B}[<64;40;12M".utf8), rows: 2)
        try await waitUntil("the wheel") { await sent(control) == [.text("\u{1B}[<64;40;12M\u{1B}[<64;40;12M")] }
        input.scroll(Data([0x1B, 0x5B, 0x4D, 0x61, 0x84, 0x2C]), rows: 1)
        try await waitUntil("the wide wheel") { await sent(control).count == 2 }
        #expect(await sent(control).last == .event("wheel", ["delta_y": 1, "delta_mode": "line", "x": 99, "y": 11]))
        await store.stop()
    }

    /// Stop's Esc and the Keys panel's keys wait their turn behind what was
    /// typed, and Stop hears it left only once the block answered.
    @Test func stopAndTheKeysPanelGoThroughTheQueue() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("sleep 9\r", into: input)
        let held = await control.nextRequest()
        #expect(input.send(Data([0x03])))
        let stop = Task { await input.sendEscapeKeyAcknowledged() }
        try await Task.sleep(for: .milliseconds(30))
        await control.respond(to: held)
        let interrupt = await control.nextRequest()
        #expect(interrupt.payload?["args"] == ["data": "\u{03}"])
        await control.respond(to: interrupt)
        let escape = await control.nextRequest()
        #expect(escape.payload?["args"] == ["data": "\u{1B}"])
        try await Task.sleep(for: .milliseconds(30))
        #expect(await inputRequests(control).count == 3)
        await control.respond(to: escape)
        #expect(await stop.value)
        await store.stop()
    }

    // MARK: Invalid text

    /// Bytes that are not valid UTF-8 never leave as text: a stray high byte
    /// goes as Meta, and a wide legacy mouse report as its event. Every text
    /// frame the server got is valid UTF-8.
    @Test func invalidUTF8NeverLeaves() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        for bytes: [UInt8] in [
            [0xE1], [0xC3], [0x1B, 0x5B, 0x4D, 0x20, 0xA0, 0x30], [0x1B, 0x5B, 0x4D, 0x23, 0xA0, 0x30],
            Array("é".utf8),
        ] {
            #expect(input.send(Data(bytes)))
        }
        try await waitUntil("the input") { await sent(control).count == 4 }
        #expect(
            await sent(control) == [
                .text("\u{1B}a\u{1B}C"),
                .event("mouse", ["action": "press", "button": "left", "x": 127, "y": 15]),
                .event("mouse", ["action": "release", "button": "left", "x": 127, "y": 15]),
                .text("é"),
            ])
        let frames = await control.channel.frames.filter { $0.opcode == .text }
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { String(data: $0.payload, encoding: .utf8) != nil })
        await store.stop()
    }

    // MARK: Pastes

    /// A paste goes to the block as the server's own paste, framed there as
    /// the terminal's modes say: single lines, reviewed lines and multiline
    /// Snippets alike, and never with bracket markers from here.
    @Test func aPasteGoesAsTheServersOwnNeverBracketed() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        #expect(input.requestPaste("echo one", bracketedPaste: true) == .inserted)
        #expect(input.requestPaste("line one\nline two", bracketedPaste: true).requiresReview)
        #expect(input.confirmPaste())
        #expect(input.insertSnippet("snip\nmore", bracketedPaste: true))
        #expect(input.insertSnippet("single", bracketedPaste: true))
        try await waitUntil("the pastes") { await sent(control).count == 4 }
        #expect(
            await sent(control) == [
                .event("paste", ["text": "echo one"]), .event("paste", ["text": "line one\nline two"]),
                .event("paste", ["text": "snip\nmore"]), .text("single"),
            ])
        #expect(await control.requests.allSatisfy { !$0.text.contains("[200~") && !$0.text.contains("[201~") })
        await store.stop()
    }

    /// A paste too large for one request is refused whole, with a reason the
    /// view shows, and never cut; one that fits goes whole.
    @Test func anOversizedPasteIsRefusedWhole() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        let tooLarge = String(repeating: "x", count: 1_048_576)
        #expect(input.requestPaste(tooLarge) == .rejected)
        #expect(
            input.pasteErrorMessage
                == String(localized:
                    "This paste is too large to send to a Rex terminal in one piece. Paste less at a time."))
        // A multiline one is refused before review, so nothing waits on it.
        #expect(input.requestPaste(tooLarge + "\nmore") == .rejected)
        #expect(input.pendingPaste == nil)
        #expect(!input.insertSnippet(tooLarge + "\nmore", bracketedPaste: true))

        let fits = String(repeating: "y", count: 500_000)
        #expect(input.requestPaste(fits) == .inserted)
        try await waitUntil("the paste") { await sent(control).count == 1 }
        #expect(await sent(control) == [.event("paste", ["text": .string(fits)])])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inputRequests(control).count == 1)
        await store.stop()
    }

    // MARK: The gate

    /// Once the block's close is heard nothing more leaves, though the view
    /// stays up for the block's last output.
    @Test func aClosedBlockTakesNoMoreInput() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])], closeGrace: .seconds(2))
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)
        type("before\r", into: input)
        try await waitUntil("the keys") { await sent(control) == [.text("before\r")] }

        await control.push("block_closed", ["block_id": "block:left"], session: "session:studio")
        try await Task.sleep(for: .milliseconds(200))
        #expect(store.status == .live)
        type("after\r", into: input)
        #expect(input.requestPaste("pasted") == .inserted)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sent(control) == [.text("before\r")])
        await rig.endpoint.close(code: WebSocketCloseCode(rawValue: RexDataEnding.blockClosedCode))
        try await waitUntil("the end") { store.status == .finished }
        #expect(!input.send(Data("late".utf8)))
    }

    /// The program's exit ends input with the terminal.
    @Test func theProgramsExitEndsInput() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        let nonce = await rig.endpoint.nonce(of: 0)
        await rig.endpoint.send(FakeRexStream.childExited(code: 0, nonce: nonce))
        try await waitUntil("the end") { store.status == .finished }
        #expect(!input.send(Data("late".utf8)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inputRequests(control).isEmpty)
    }

    /// Input typed while the control link is down is neither sent nor kept,
    /// and the view stops looking live: it reconnects, and once a link takes
    /// the client back and the terminal paints again, input goes on over it.
    @Test func aDroppedLinkSendsNothingUntilItsClientIsBack() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        await answerInput(on: first)
        await answerInput(on: second)
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        await first.drop()
        await second.acceptUpgrade()
        type("lost\r", into: input)
        try await waitUntil("the reconnect") { store.status == .reconnecting }
        #expect(!input.send(Data("early\r".utf8)))
        _ = await second.nextHello()
        await second.sendWelcome(resumed)
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { store.status == .live }

        type("kept\r", into: input)
        try await waitUntil("the keys") { await sent(second) == [.text("kept\r")] }
        #expect(await sent(first).isEmpty)
        await store.stop()
    }

    /// A stream that starts over leaves the view showing a screen the program
    /// may have moved on from: nothing typed at it is sent, and input goes on
    /// once the new stream paints.
    @Test func aStreamStartingOverTakesNoInputUntilItPaints() async throws {
        let rig = Rig()
        let control = await rig.server()
        await answerInput(on: control)
        let session = hostSession([await rig.host([.server(control)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let chunks = RexTerminalAttachTests.Chunks()
        let store = try await openPainted(rig, session: session, input: input, chunks: chunks)

        await rig.endpoint.script(.refuse(reason: 3))
        await rig.endpoint.drop()
        await rig.endpoint.waitForStreams(2)
        type("stale\r", into: input)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inputRequests(control).isEmpty)
        await rig.begin(stream: 1)
        try await waitUntil("the new paint") { chunks.all.count == 2 }
        #expect(store.status == .live)

        type("fresh\r", into: input)
        try await waitUntil("the keys") { await sent(control) == [.text("fresh\r")] }
        await store.stop()
    }

    /// A control client the server does not know ends the terminal; nothing
    /// typed leaves until it paints afresh, and then it goes to the new link.
    @Test func aNewControlClientTakesInputOnlyAfterItsPaint() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        await answerInput(on: second)
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = "client:00000000-0000-7000-8000-000000000002"
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: fresh)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        await first.drop()
        try await waitUntil("the reattach") { store.status == .reconnecting }
        #expect(!input.send(Data("early\r".utf8)))
        await rig.begin(stream: 1)
        try await waitUntil("the fresh paint") { store.status == .live }
        type("fresh\r", into: input)
        try await waitUntil("the keys") { await sent(second) == [.text("fresh\r")] }
        #expect(await inputRequests(first).isEmpty)
        await store.stop()
    }

    /// Input typed while another server instance takes the socket goes to
    /// neither, and the terminal finishes.
    @Test func anotherInstanceTakesNoInput() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        await answerInput(on: second)
        var fresh = FakeRexServer.Welcome()
        fresh.clientID = "client:00000000-0000-7000-8000-000000000003"
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: nil)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        rig.world.restart(as: "instance-0002")
        await first.close(.goingAway, reason: "shutting down")
        await second.acceptUpgrade()
        type("stray\r", into: input)
        try await Task.sleep(for: .milliseconds(100))
        _ = await second.nextHello()
        await second.sendWelcome(fresh)
        try await waitUntil("the end") { store.status == .finished }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inputRequests(first).isEmpty)
        #expect(await inputRequests(second).isEmpty)
    }

    // MARK: Unknown outcomes

    /// A write with no answer by its deadline is never sent again: what
    /// queued behind it is dropped, and the view says input failed.
    @Test func anUnansweredWriteIsNeverSentAgain() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession([await rig.host([.server(control)])], inputDeadline: .milliseconds(150))
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("first\r", into: input)
        _ = await control.nextRequest()
        type("second\r", into: input)
        #expect(input.requestPaste("third") == .inserted)
        try await waitUntil("the end") { store.status == .ended(Self.inputFailed) }
        #expect(!input.send(Data("after\r".utf8)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sent(control) == [.text("first\r")])
        #expect(await rig.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])
    }

    /// A server that keeps sending events but never answers a write holds
    /// the input queue only until the limit: the write is never sent again,
    /// what queued behind it is dropped, and the view says input failed.
    @Test func aWriteHeardOverByEventsIsNeverSentAgainPastItsLimit() async throws {
        let rig = Rig()
        let control = await rig.server()
        let session = hostSession(
            [await rig.host([.server(control)])], inputDeadline: .milliseconds(150), inputLimit: .milliseconds(500))
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("first\r", into: input)
        _ = await control.nextRequest()
        type("second\r", into: input)
        // Never silent for as long as the input deadline.
        let chatter = Task {
            while !Task.isCancelled {
                await control.push(
                    "block_event", ["block_id": .string(Self.address.blockID), "name": .string("bell")],
                    session: Self.address.sessionID)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        defer { chatter.cancel() }
        try await waitUntil("the end") { store.status == .ended(Self.inputFailed) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sent(control) == [.text("first\r")])
    }

    /// A link that drops with a write out leaves its outcome unknown: even
    /// when the next link takes the client back, the terminal ends rather
    /// than send it, or anything after it, again.
    @Test func aDropWithAWriteOutEndsTheTerminal() async throws {
        let rig = Rig()
        let first = await rig.server()
        let second = await rig.server()
        await answerInput(on: second)
        var resumed = FakeRexServer.Welcome()
        resumed.resumed = true
        let session = hostSession([await rig.host([.server(first), .server(second, welcome: resumed)])])
        defer { Task { await session.end() } }
        await session.resume()
        let input = TerminalInputController()
        let store = try await openPainted(rig, session: session, input: input)

        type("rm -i note\r", into: input)
        _ = await first.nextRequest()
        type("y\r", into: input)
        await first.drop()
        try await waitUntil("the end") { store.status == .ended(Self.inputFailed) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await sent(first) == [.text("rm -i note\r")])
        #expect(await inputRequests(second).isEmpty)
    }

    /// A refused write ends the terminal as an unknown one does; a block the
    /// server no longer has finishes it.
    @Test func aRefusedWriteEndsTheTerminal() async throws {
        for (code, status, ending) in [
            ("invalid_params", 400, AttachTerminalStore.Status.ended(Self.inputFailed)),
            ("not_found", 404, AttachTerminalStore.Status.finished),
        ] {
            let rig = Rig()
            let control = await rig.server()
            let session = hostSession([await rig.host([.server(control)])])
            await session.resume()
            let input = TerminalInputController()
            let store = try await openPainted(rig, session: session, input: input)

            type("one\r", into: input)
            let request = await control.nextRequest()
            type("two\r", into: input)
            await control.fail(request, code: code, message: "refused", status: status)
            try await waitUntil("the end after \(code)") { store.status == ending }
            try await Task.sleep(for: .milliseconds(50))
            #expect(await inputRequests(control).count == 1)
            await session.end()
        }
    }
}
