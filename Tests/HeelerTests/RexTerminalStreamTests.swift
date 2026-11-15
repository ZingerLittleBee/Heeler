import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// A Rex terminal's stream from ticket to instructions, against a fake
/// control server that answers the block's reads and a fake data endpoint:
/// the first paint, resuming a dropped connection, starting over, and the
/// ways it ends. Waits run on a manual clock. Ids, nonces and the redraw are
/// invented.
@Suite("Rex terminal stream", .timeLimit(.minutes(1)))
struct RexTerminalStreamTests {
    static let redraw = "\u{1B}[H\u{1B}[2Jprompt$ "

    struct Fixture {
        let control: FakeRexServer
        let endpoint: FakeRexDataEndpoint
        let reads: FakeRexTerminalReads
        let clock: ManualClock
        let stream: RexTerminalStream

        /// Writes the start of stream `index`: a stand-in snapshot, then its
        /// first resize, cut in a few places.
        func begin(stream index: Int = 0, columns: Int = 80, rows: Int = 24) async {
            await endpoint.waitForStreams(index + 1)
            let nonce = await endpoint.nonce(of: index)
            let snapshot = FakeRexStream.snapshot(byteCount: 400, decoys: nonce)
            let start = snapshot + FakeRexStream.resize(columns: columns, rows: rows, nonce: nonce)
            await endpoint.send(start, on: index, cuts: [5, snapshot.count - 2, snapshot.count + 4])
        }

        func write(_ text: String, on index: Int = 0) async {
            await endpoint.send(Data(text.utf8), on: index)
        }

        /// The instructions of a first paint once its settle passes: the
        /// paint and its title.
        func paint() async -> [RexTerminalInstruction?] {
            #expect(await clock.pass(.milliseconds(60)))
            return [await stream.next(), await stream.next()]
        }
    }

    static func fixture(
        redraw: String = RexTerminalStreamTests.redraw,
        configure: (inout RexTerminalStream.Options) -> Void = { _ in }
    ) async throws -> Fixture {
        let clock = ManualClock()
        let (control, link) = try await FakeRexServer.open(clock: clock)
        let endpoint = FakeRexDataEndpoint(nonces: [0x1111_2222_3333_4444, 0x5555_6666_7777_8888])
        await endpoint.tickets.install(on: control)
        let reads = FakeRexTerminalReads(redraw: redraw, title: "lab")
        await reads.install(on: control)
        var options = RexTerminalStream.Options()
        options.link = .testing
        configure(&options)
        let stream = RexTerminalStream(
            session: RexDataLinkTests.session, block: RexDataLinkTests.block, route: endpoint.route(control: link),
            options: options, sleep: clock.parkedSleep(for:))
        return Fixture(control: control, endpoint: endpoint, reads: reads, clock: clock, stream: stream)
    }

    static let grid = RexTerminalGrid(columns: 80, rows: 24, cellWidth: 9, cellHeight: 18, owner: "client:fake-owner")

    static func painted(_ redraw: String = RexTerminalStreamTests.redraw) -> RexTerminalInstruction {
        .paint(RexTerminalPaint.reset + Data(redraw.utf8), exact: true)
    }

    // MARK: Painting

    @Test func aQuietTerminalPaintsOnceThenFeedsItsOutput() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()

        #expect(await fixture.stream.next() == .grid(Self.grid))
        #expect(await fixture.paint() == [Self.painted(), .title("lab")])
        // The redraw and the title are asked for together.
        #expect(fixture.reads.methods.first == "modes")
        #expect(fixture.reads.methods.sorted() == ["format", "modes", "title"])

        await fixture.write("hello\r\n")
        #expect(await fixture.stream.next() == .feed(Data("hello\r\n".utf8)))
        let status = await fixture.stream.status
        #expect(status.isPainted)
        #expect(!status.isDirty)
        #expect(status.exactPaintCount == 1)
        #expect(status.streamsOpened == 1)
        #expect(status.skippedSnapshotBytes == 400)
        await fixture.stream.stop()
    }

    @Test func aLongRedrawIsReadInPages() async throws {
        let long = String(repeating: "0123456789abcdef", count: 200)
        let fixture = try await Self.fixture(redraw: long) { $0.paint.pageBytes = 1024 }
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        #expect(await fixture.paint() == [Self.painted(long), .title("lab")])
        #expect(fixture.reads.methods.filter { $0 == "blob_read" }.count == 3)
        await fixture.stream.stop()
    }

    // MARK: Resuming and starting over

    /// A dropped connection is resumed with every byte counted, and the
    /// stream goes on with no new paint.
    @Test func aDroppedConnectionIsResumed() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()
        await fixture.write("one")
        _ = await fixture.stream.next()

        await fixture.endpoint.drop()
        await fixture.endpoint.waitForHandshakes(2)
        let sent = await fixture.endpoint.sentByteCount(of: 0)
        #expect(
            await fixture.endpoint.handshakes.last
                == .init(kind: .resume(count: sent), byteCount: 25, outcome: .welcomed(stream: 0)))
        await fixture.write("two")
        #expect(await fixture.stream.next() == .feed(Data("two".utf8)))
        let status = await fixture.stream.status
        #expect(status.resumes == 1)
        #expect(status.streamsOpened == 1)
        #expect(status.paintCount == 1)
        await fixture.stream.stop()
    }

    /// A refused resume leaves only a new stream: a new ticket, a HELLO, and
    /// a new first paint that resets the view.
    @Test func aRefusedResumeStartsANewStream() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()

        await fixture.endpoint.script(.refuse(reason: 3))
        await fixture.endpoint.drop()
        #expect(await fixture.clock.pass(RexTerminalStream.Options().startOverDelay))
        fixture.reads.set(redraw: "again")
        await fixture.begin(stream: 1)
        #expect(await fixture.stream.next() == .grid(Self.grid))
        #expect(await fixture.paint() == [Self.painted("again"), .title("lab")])
        await fixture.write("after", on: 1)
        #expect(await fixture.stream.next() == .feed(Data("after".utf8)))
        let status = await fixture.stream.status
        #expect(status.streamsOpened == 2)
        #expect(status.resumes == 0)
        #expect(fixture.endpoint.tickets.ticketTexts.count == 2)
        await fixture.stream.stop()
    }

    @Test func aCanceledProviderStartsANewStream() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()

        await fixture.endpoint.close(code: .goingAway, reason: RexDataEnding.providerCanceledReason)
        #expect(await fixture.clock.pass(.seconds(1)))
        await fixture.begin(stream: 1)
        #expect(await fixture.stream.next() == .grid(Self.grid))
        #expect(await fixture.stream.status.resumes == 0)
        await fixture.stream.stop()
    }

    // MARK: Endings

    @Test func aClosedBlockEndsTheStream() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()

        await fixture.endpoint.close(code: WebSocketCloseCode(rawValue: 4000))
        #expect(await fixture.stream.next() == .ended(.blockClosed))
        #expect(await fixture.stream.next() == nil)
    }

    @Test func aBlockThatIsGoneEndsTheStreamAtOnce() async throws {
        let fixture = try await Self.fixture()
        fixture.endpoint.tickets.fail(with: [.error(code: "not_found", message: "no block", status: 404)])
        #expect(await fixture.stream.next() == .ended(.blockClosed))
        #expect(await fixture.endpoint.channels.isEmpty)
    }

    /// Tickets refused for want of an attach are tried again, in case the
    /// attach is on its way, then the stream says what is missing.
    @Test func aSessionThatIsNotAttachedEndsTheStream() async throws {
        let fixture = try await Self.fixture()
        let conflict = FakeRexServer.Answer.error(code: "conflict", message: "attach first", status: 409)
        fixture.endpoint.tickets.fail(with: Array(repeating: conflict, count: 4))
        await fixture.stream.start()
        for _ in 0..<3 {
            #expect(await fixture.clock.pass(.seconds(1)))
        }
        #expect(await fixture.stream.next() == .ended(.notAttached))
        #expect(fixture.endpoint.tickets.requests.count == 4)
    }

    /// Stopping ends the stream on the server with 1000, and says so last.
    @Test func stoppingClosesTheConnection() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()
        await fixture.write("unread")

        await fixture.stream.stop()
        #expect(await fixture.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])
        var last: RexTerminalInstruction?
        while let next = await fixture.stream.next() { last = next }
        #expect(last == .ended(.closedHere))
    }

    @Test func theProgramsExitIsPassedOn() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        await fixture.begin()
        _ = await fixture.stream.next()
        _ = await fixture.paint()
        let nonce = await fixture.endpoint.nonce(of: 0)
        await fixture.endpoint.send(Data("bye\r\n".utf8) + FakeRexStream.childExited(code: 0, nonce: nonce))
        #expect(await fixture.stream.next() == .feed(Data("bye\r\n".utf8)))
        #expect(await fixture.stream.next() == .exited(code: 0))
        await fixture.stream.stop()
    }

    @Test func aCancelledWaitForTheNextInstructionReturnsNil() async throws {
        let fixture = try await Self.fixture()
        await fixture.stream.start()
        let waiting = Task { await fixture.stream.next() }
        await fixture.endpoint.waitForStreams(1)
        waiting.cancel()
        #expect(await waiting.value == nil)
        await fixture.stream.stop()
    }
}
