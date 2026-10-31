import Foundation
import Testing

@testable import Heeler

/// A live terminal on a fake core's framed link, checked byte for byte against
/// frames captured from herdr-core 0.1.13.
@Suite("HerdrCoreAttach", .timeLimit(.minutes(1)))
struct HerdrCoreAttachTests {
    /// A link connected to a fake core on a manual clock.
    private struct Harness {
        let socket = FakeCoreSocket()
        let clock = ManualClock()
        let link: HerdrCoreLink

        init() async throws {
            let socket = socket
            let clock = clock
            let connected = Task {
                try await HerdrCoreLink.connect(over: socket, sleep: clock.parkedSleep(for:))
            }
            _ = await socket.nextWrittenLine()
            await socket.deliver(ScriptedCoreHost.helloReply())
            link = try await connected.value.link
        }

        /// Opens an attach whose reply names `channel`.
        func attach(
            _ address: String = "t3", channel: UInt32 = 2, viewer: TerminalViewerRole = .interactive,
            displayFacts: TerminalDisplayFacts? = nil
        ) async throws -> (session: TerminalAttachSession, params: JSONValue) {
            let link = link
            let opened = Task {
                try await HerdrCoreAttach.open(
                    on: link,
                    request: TerminalAttachRequest(
                        target: .terminal(address), viewer: viewer, displayFacts: displayFacts, cols: 80, rows: 24),
                    deadline: .seconds(5))
            }
            let request = await socket.nextRequest()
            #expect(request.method == "terminal.attach")
            try await socket.reply(to: request.id, result: .object(["channel": .number(Double(channel))]))
            return (try await opened.value, request.params)
        }

        /// Returns once everything delivered so far has been ingested and every
        /// frame the client queued because of it has reached the socket.
        func settle() async throws {
            for _ in 0..<2 {
                let done = Task { try await link.call("server.status", deadline: .seconds(5)) }
                let request = await socket.nextRequest()
                try await socket.reply(to: request.id)
                _ = try await done.value
            }
        }
    }

    private static func vector(_ name: String) throws -> Data {
        let vector = try #require(HerdrCoreVectorFile.shared.frames.first { $0.name == name })
        return HerdrCoreVectorFile.bytes(hex: vector.bytes)
    }

    private static func dataFrame(_ channel: UInt32, count: Int) -> HerdrCoreFrame {
        HerdrCoreFrame(channel: channel, kind: .data, payload: Data(repeating: 0x61, count: count))
    }

    // MARK: Opening

    @Test func anInteractiveAttachSendsTheCapturedParamsWithNoTakeOver() async throws {
        let harness = try await Harness()
        let (session, params) = try await harness.attach()
        let captured = try HerdrCoreVectorFile.shared.exchange("terminal-attach").params
        #expect(params["terminal"] == captured["terminal"])
        #expect(params["cols"] == captured["cols"])
        #expect(params["rows"] == captured["rows"])
        #expect(params["observe"] == nil)
        #expect(params["resumed"] == nil)
        #expect(params["takeover"] == nil)
        #expect(params["take_over"] == nil)
        await session.end()
    }

    @Test(arguments: [
        (TerminalViewerRole.resumed, "resumed"), (TerminalViewerRole.observe, "observe"),
    ])
    func aViewerRoleTravelsInTheAttachParams(role: TerminalViewerRole, key: String) async throws {
        let harness = try await Harness()
        let (session, params) = try await harness.attach(viewer: role)
        #expect(params[key] == .bool(true))
        await session.end()
    }

    @Test func anAttachCarriesTheDisplayFactsItWasGiven() async throws {
        let harness = try await Harness()
        let facts = TerminalDisplayFacts(
            foreground: "#ffffff", background: "#000000", cursor: "#ff0000",
            cell: .init(width: 10, height: 20))
        let (session, params) = try await harness.attach(displayFacts: facts)
        #expect(
            params["display"]
                == .object([
                    "fg": .string("#ffffff"), "bg": .string("#000000"), "cursor": .string("#ff0000"),
                    "cell": .array([.number(10), .number(20)]),
                ]))
        await session.end()
    }

    // MARK: Output and input

    @Test func outputReachesTheTerminalUntouched() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        var output = session.output.makeAsyncIterator()
        await harness.socket.deliver(try Self.vector("data-attach-raw-bytes"))
        #expect(try await output.next() == Data("hello\r\n".utf8))
        await session.end()
    }

    @Test func aRepaintAfterABacklogPassesThroughLikeAnyOtherOutput() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        var output = session.output.makeAsyncIterator()
        let repaint = Data("\u{1B}[!p\u{1B}[?2004l\u{1B}[=0;1u\u{1B}[H\u{1B}[2Jscreen\u{1B}[?2004h".utf8)
        try await harness.socket.deliver(HerdrCoreFrame(channel: 2, kind: .data, payload: repaint))
        #expect(try await output.next() == repaint)
        await session.end()
    }

    @Test func typedBytesGoOutUnchangedWithCtrlBackslashAmongThem() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        session.send(Data([0x1C, 0x03, 0x1B, 0x5B, 0x41, 0xC3, 0xA9]))
        let frame = await harness.socket.waitForFrame(channel: 2, kind: .data)
        #expect(
            try frame.encoded()
                == Data([0x02, 0, 0, 0, 0x00, 0x07, 0, 0, 0, 0x1C, 0x03, 0x1B, 0x5B, 0x41, 0xC3, 0xA9]))
        await session.end()
    }

    // MARK: Credit

    @Test func creditLeavesAsTheViewConsumesAndNeverOnReceipt() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        var output = session.output.makeAsyncIterator()
        try await harness.socket.deliver(Self.dataFrame(2, count: 256 * 1024))
        #expect(try await output.next()?.count == 256 * 1024)
        try await harness.settle()
        #expect(await harness.socket.creditTotal(channel: 2) == 0)

        session.outputConsumed(256 * 1024)
        await harness.socket.waitForCredit(channel: 2, total: 256 * 1024)
        let credit = await harness.socket.waitForFrame(channel: 2, kind: .credit)
        #expect(try credit.encoded() == Self.vector("credit-256-kib"))
        await session.end()
    }

    @Test func aStalledViewHoldsUpItsChannelAndNothingElse() async throws {
        let harness = try await Harness()
        let (stalled, _) = try await harness.attach("t3", channel: 2)
        let (other, _) = try await harness.attach("t4", channel: 3)
        let opened = Task {
            try await harness.link.openStream(
                "events.subscribe", params: .object([:]), deadline: .seconds(5))
        }
        let subscribe = await harness.socket.nextRequest()
        try await harness.socket.reply(to: subscribe.id, result: .object(["channel": .number(4)]))
        let events = try await opened.value.stream

        // A whole window for a view that takes nothing.
        for _ in 0..<16 {
            try await harness.socket.deliver(Self.dataFrame(2, count: 16 * 1024))
        }

        var otherOutput = other.output.makeAsyncIterator()
        try await harness.socket.deliver(HerdrCoreFrame(channel: 3, kind: .data, payload: Data("next".utf8)))
        #expect(try await otherOutput.next() == Data("next".utf8))
        other.outputConsumed(4)
        await harness.socket.waitForCredit(channel: 3, total: 4)

        try await harness.socket.deliver(
            HerdrCoreFrame(channel: 4, kind: .data, payload: Data("event\n".utf8)))
        #expect(try await events.read() == Data("event\n".utf8))

        try await harness.settle()
        #expect(await harness.socket.creditTotal(channel: 2) == 0)

        var stalledOutput = stalled.output.makeAsyncIterator()
        #expect(try await stalledOutput.next()?.count == 16 * 1024)
        stalled.outputConsumed(16 * 1024)
        await harness.socket.waitForCredit(channel: 2, total: 16 * 1024)
        await stalled.end()
        await other.end()
    }

    // MARK: Size, focus and facts

    @Test func aResizeCarriesTheGrid() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        session.resize(cols: 80, rows: 24)
        let frame = await harness.socket.waitForFrame(channel: 2, kind: .resize)
        #expect(try frame.encoded() == Self.vector("resize-80x24"))
        await session.end()
    }

    @Test func aViewedAttachSendsFocusThenItsFacts() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        session.setPresence(
            .viewed(
                TerminalDisplayFacts(
                    foreground: "#ffffff", background: "#000000", cursor: "#ff0000",
                    cell: .init(width: 10, height: 20))))
        let facts = await harness.socket.waitForFrame(channel: 2, kind: .facts)
        let focus = await harness.socket.frames(channel: 2, kind: .focus)
        #expect(try focus.map { try $0.encoded() } == [Self.vector("focus-gained")])
        var decoder = HerdrCoreFrameDecoder()
        decoder.append(try Self.vector("facts"))
        let captured = try #require(try decoder.next())
        #expect(
            try JSONDecoder().decode(JSONValue.self, from: facts.payload)
                == JSONDecoder().decode(JSONValue.self, from: captured.payload))
        await session.end()
    }

    @Test func leavingTheViewSendsOneFocusLostAndNoFacts() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        session.setPresence(.hidden)
        let frame = await harness.socket.waitForFrame(channel: 2, kind: .focus)
        #expect(try frame.encoded() == Self.vector("focus-lost"))
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 2, kind: .facts).isEmpty)
        await session.end()
    }

    @Test func aHiddenAttachSendsNeitherFocusNorFactsOfItsOwnAccord() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach(viewer: .resumed)
        session.resize(cols: 100, rows: 30)
        _ = await harness.socket.waitForFrame(channel: 2, kind: .resize)
        try await harness.settle()
        #expect(await harness.socket.frames(channel: 2, kind: .focus).isEmpty)
        #expect(await harness.socket.frames(channel: 2, kind: .facts).isEmpty)
        await session.end()
    }

    // MARK: Ending

    @Test func aServerCloseEndsTheSessionWithoutAnError() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach(channel: 3)
        var output = session.output.makeAsyncIterator()
        await harness.socket.deliver(try Self.vector("close-program-ended"))
        #expect(try await output.next() == nil)
        await session.end()
    }

    @Test func endingTheSessionSendsCloseForItsChannel() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        await session.end()
        let frame = await harness.socket.waitForFrame(channel: 2, kind: .close)
        #expect(try frame.encoded() == Self.vector("close-from-client"))
    }

    @Test func theLinkEndingUnderAnAttachReadsAsALostConnection() async throws {
        let harness = try await Harness()
        let (session, _) = try await harness.attach()
        var output = session.output.makeAsyncIterator()
        await harness.socket.deliverEndOfFile()
        await #expect(throws: TransportError.cancelled) { _ = try await output.next() }
        await session.end()
    }

    @Test func oneLinkCarriesEveryAttachOnAChannelOfItsOwn() async throws {
        let harness = try await Harness()
        let (first, _) = try await harness.attach("t3", channel: 2)
        let (second, _) = try await harness.attach("t4", channel: 3)
        first.send(Data("a".utf8))
        second.send(Data("b".utf8))
        #expect(await harness.socket.waitForFrame(channel: 2, kind: .data).payload == Data("a".utf8))
        #expect(await harness.socket.waitForFrame(channel: 3, kind: .data).payload == Data("b".utf8))
        await first.end()
        await second.end()
    }
}
