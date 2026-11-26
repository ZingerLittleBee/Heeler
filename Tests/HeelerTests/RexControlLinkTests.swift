import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// A control link against a fake Rex server shaped after Rex
/// 0.1.0-preview.14 (API revision 12): the hello, requests matched to
/// responses, events in order, endings, and resuming. Deadlines run on a
/// manual clock. Ids, labels and tokens are invented.
@Suite("Rex control link", .timeLimit(.minutes(1)))
struct RexControlLinkTests {
    private struct Echo: Codable, Sendable, Equatable {
        let text: String
    }

    /// A delivery's deadline in these tests: ten seconds of silence, a
    /// minute in all.
    static let delivery = RexDeliveryDeadline(silence: .seconds(10), limit: .seconds(60))

    private func error(_ operation: () async throws -> some Any) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    // MARK: Opening

    /// Rex drops a client that stays silent, so the hello goes out as soon as
    /// the upgrade is answered, before any time passes.
    @Test func theHelloGoesOutRightAfterTheUpgrade() async throws {
        let clock = ManualClock()
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: clock.parkedSleep(for:)) }
        let upgrade = await server.acceptUpgrade()
        let (hello, text) = await server.helloText()

        #expect(upgrade.requestLine == "GET /api/control HTTP/1.1")
        #expect(upgrade.field("Sec-WebSocket-Protocol") == "rex.control.v1")
        #expect(hello["type"] == .string("hello"))
        #expect(hello["client"]?["kind"] == .string("other"))
        #expect(hello["api_revision"] == .number(19))
        #expect(hello["api_min_revision"] == .number(12))
        #expect(hello["reconnect_token"] == nil)
        #expect(text.utf8.count < 512)
        // The clock never moved, and the welcome's deadline is what waits now.
        #expect(await clock.parks(for: RexControlLink.Options.testing.welcomeDeadline))

        await server.sendWelcome()
        let link = try await opened.value
        #expect(link.clientID == FakeRexServer.Welcome().clientID)
        #expect(link.maxMessageBytes == 1_048_576)
        #expect(!link.resumed)
        #expect(link.apiRevision == 19)
        await link.close()
    }

    /// The server picks the newest revision both sides speak: an older Rex,
    /// such as 0.1.0-preview.14, welcomes at 12, and the link keeps what it
    /// agreed on.
    @Test(arguments: [12, 15, 19])
    func aWelcomeAtAnyRevisionFrom12To19IsAccepted(revision: Int) async throws {
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = revision
        welcome.serverRevision = revision
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        await server.handshake(welcome)

        let link = try await opened.value
        #expect(link.apiRevision == revision)
        #expect(await link.isOpen)
        await link.close()
    }

    @Test func messagesBeforeTheWelcomeAreSkipped() async throws {
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        await server.acceptUpgrade()
        _ = await server.nextHello()
        await server.sendText("not json")
        await server.sendText(#"{"type":"event","seq":1,"payload":{"type":"client_connected","payload":{}}}"#)
        await server.sendWelcome()

        let link = try await opened.value
        #expect(await link.isOpen)
        await link.close()
    }

    /// Only revisions 12 to 19 over `rex.control.v1` are accepted, and the
    /// link then leaves for good, with a close frame.
    @Test(arguments: [(19, "rex.control.v2"), (20, "rex.control.v1"), (11, "rex.control.v1")])
    func aWelcomeForAnotherRevisionIsRefused(revision: Int, protocolName: String) async throws {
        var welcome = FakeRexServer.Welcome()
        welcome.apiRevision = revision
        welcome.serverRevision = revision
        welcome.protocolName = protocolName
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        await server.handshake(welcome)

        let failure = await error { try await opened.value }
        guard case .unsupportedVersion(let offer)? = failure as? RexControlError else {
            Issue.record("Expected an unsupported version, got \(String(describing: failure))")
            return
        }
        #expect(offer.apiRevision == revision)
        #expect(offer.protocolName == protocolName)
        #expect(offer.newestRevision == revision)
        await server.waitUntilClosed()
        #expect(await server.clientClose?.code == .normalClosure)
    }

    /// A server with no revision in common closes before welcoming.
    @Test func aServerThatClosesWithPolicyBeforeTheWelcomeOffersNoCommonRevision() async throws {
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        await server.acceptUpgrade()
        _ = await server.nextHello()
        await server.close(.policyViolation, reason: "no common API revision")

        let failure = await error { try await opened.value }
        guard case .unsupportedVersion(let offer)? = failure as? RexControlError else {
            Issue.record("Expected an unsupported version, got \(String(describing: failure))")
            return
        }
        #expect(offer == .unknown)
    }

    @Test func noWelcomeInTimeEndsTheLink() async throws {
        let clock = ManualClock()
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: clock.parkedSleep(for:)) }
        await server.acceptUpgrade()
        _ = await server.nextHello()
        #expect(await clock.pass(RexControlLink.Options.testing.welcomeDeadline))

        let failure = await error { try await opened.value }
        guard case .welcomeTimedOut? = failure as? RexControlError else {
            Issue.record("Expected the welcome to time out, got \(String(describing: failure))")
            return
        }
        await server.waitUntilClosed()
    }

    /// A connection that fails while the hello is written ends as one that
    /// fails while the welcome is awaited, never as a WebSocket's own error.
    @Test func aHelloThatCannotBeWrittenEndsTheLink() async throws {
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        _ = await server.channel.nextUpgradeRequest()
        await server.channel.failNextWrite()
        await server.channel.acceptUpgrade()

        let failure = await error { try await opened.value }
        guard case .linkEnded(.linkLost)? = failure as? RexControlError else {
            Issue.record("Expected the lost link, got \(String(describing: failure))")
            return
        }
        await server.channel.waitUntilClosed()
    }

    @Test func anUpgradeRefusalKeepsItsStatus() async throws {
        let server = FakeRexServer()
        let opened = Task { try await RexControlLink.open(over: server.channel, options: .testing, sleep: ManualClock().parkedSleep(for:)) }
        await server.refuseUpgrade(status: 403)

        let failure = await error { try await opened.value }
        guard case .upgradeRefused(403)? = failure as? RexControlError else {
            Issue.record("Expected a 403 refusal, got \(String(describing: failure))")
            return
        }
    }

    // MARK: Requests

    @Test func concurrentCallsAreMatchedToResponsesThatArriveOutOfOrder() async throws {
        let (server, link) = try await FakeRexServer.open()
        async let first = link.call("session.view", payload: Echo(text: "first"))
        async let second = link.call("session.view", payload: Echo(text: "second"))
        // The two calls start concurrently, so either may reach the server first;
        // tell them apart by payload, not by arrival order.
        let arrived = [await server.nextRequest(), await server.nextRequest()]
        let one = try #require(arrived.first { $0.payload?["text"]?.stringValue == "first" })
        let two = try #require(arrived.first { $0.payload?["text"]?.stringValue == "second" })
        #expect(one.id != two.id)
        #expect(one.method == "session.view")

        await server.push("session_created", ["session": ["session_id": "session:a", "label": "lab-a"]])
        // The later request is answered first, after the event; the earlier one before it.
        await server.respond(to: two, with: two.payload ?? .null, seq: 1)
        await server.respond(to: one, with: one.payload ?? .null, seq: 0)

        let (firstResponse, secondResponse) = try await (first, second)
        #expect(try firstResponse.result(Echo.self) == Echo(text: "first"))
        #expect(try secondResponse.result(Echo.self) == Echo(text: "second"))
        #expect(firstResponse.seq == 0)
        #expect(secondResponse.seq == 1)
        await link.close()
    }

    @Test func aRequestWithoutAPayloadLeavesItOut() async throws {
        let (server, link) = try await FakeRexServer.open()
        await server.answer("server.status", with: .result(["session_count": 2]))

        let response = try await link.call("server.status")
        struct Status: Decodable { let session_count: Int }
        #expect(try response.result(Status.self).session_count == 2)
        let request = try #require(await server.requests.first)
        #expect(request.payload == nil)
        #expect(!request.text.contains("payload"))
        await link.close()
    }

    @Test func anErrorResponseFailsOnlyItsCall() async throws {
        let (server, link) = try await FakeRexServer.open()
        await server.answer(
            "session.attach", with: .error(code: "session_not_found", message: "no such session", status: 404))
        await server.answer("session.list", with: .result(["sessions": []]))

        let failure = await error { try await link.call("session.attach", payload: ["session_id": "session:gone"]) }
        guard case .server(let serverError)? = failure as? RexControlError else {
            Issue.record("Expected the server's error, got \(String(describing: failure))")
            return
        }
        #expect(serverError.code == "session_not_found")
        #expect(serverError.message == "no such session")
        #expect(serverError.status == 404)
        #expect(serverError.kind == .notFound)
        _ = try await link.call("session.list")
        await link.close()
    }

    @Test func aCallPastItsDeadlineFailsAndItsLateAnswerIsSkipped() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        let late = Task { try await link.call("session.view", deadline: .seconds(5)) }
        let request = await server.nextRequest()
        #expect(await clock.pass(.seconds(5)))

        let failure = await error { try await late.value }
        guard case .deadlineExceeded(method: "session.view")? = failure as? RexControlError else {
            Issue.record("Expected the deadline, got \(String(describing: failure))")
            return
        }
        await server.respond(to: request)
        await server.answer("session.list", with: .result(["sessions": []]))
        _ = try await link.call("session.list")
        #expect(await link.isOpen)
        await link.close()
    }

    /// A call timed by the link's silence waits while other messages keep
    /// arriving, as a redraw's pages do, and fails once the link goes quiet.
    @Test func aCallTimedBySilenceWaitsWhileTheLinkKeepsReceiving() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        var events = link.events.makeAsyncIterator()
        let call = Task { try await link.call("session.view", payload: JSONValue?.none, waiting: Self.delivery) }
        _ = await server.nextRequest()
        for number in 1...3 {
            #expect(await clock.parks(for: .seconds(10)))
            await server.push("session_destroyed", ["session_id": .string("session:\(number)")])
            _ = try await events.next()
            clock.advance(.seconds(10))
        }
        #expect(await clock.parks(for: .seconds(10)))
        clock.advance(.seconds(10))

        let failure = await error { try await call.value }
        guard case .deadlineExceeded(method: "session.view")? = failure as? RexControlError else {
            Issue.record("Expected the deadline after a silence, got \(String(describing: failure))")
            return
        }
        #expect(await link.isOpen)
        await link.close()
    }

    /// A delivery's deadline passes only after that long with nothing at all
    /// arriving: its answer may queue behind long messages while they stream in.
    @Test func aDeliveryWaitsWhileTheLinkKeepsReceiving() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        var events = link.events.makeAsyncIterator()
        let delivery = Task { await link.deliver("block.event", payload: JSONValue.object([:]), deadline: Self.delivery) }
        let request = await server.nextRequest()
        for number in 1...3 {
            #expect(await clock.parks(for: .seconds(10)))
            // Something arrives in each wait, then the wait runs out.
            await server.push("session_destroyed", ["session_id": .string("session:\(number)")])
            _ = try await events.next()
            clock.advance(.seconds(10))
        }
        #expect(await clock.parks(for: .seconds(10)))
        await server.respond(to: request)
        guard case .answered = await delivery.value else {
            Issue.record("Expected an answer")
            return
        }
        await link.close()
    }

    /// A server that keeps sending but never answers holds a delivery no
    /// longer than its limit: the outcome is then unknown, the link stays
    /// open, and the request is never sent again.
    @Test func aDeliveryThatHearsOnlyOtherMessagesEndsAtItsLimit() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        var events = link.events.makeAsyncIterator()
        let delivery = Task { await link.deliver("block.event", payload: JSONValue.object([:]), deadline: Self.delivery) }
        _ = await server.nextRequest()
        // Six silences fill the limit, and something arrives in each.
        for number in 1...6 {
            #expect(await clock.parks(for: .seconds(10)))
            await server.push("session_destroyed", ["session_id": .string("session:\(number)")])
            _ = try await events.next()
            clock.advance(.seconds(10))
        }
        guard case .unknown = await delivery.value else {
            Issue.record("Expected an unknown outcome at the limit")
            return
        }
        #expect(await link.isOpen)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.requests.filter { $0.method == "block.event" }.count == 1)
        await link.close()
    }

    /// A limit that is not a whole number of silences cuts the last one short.
    @Test func aDeliveryLimitShorterThanItsSilenceEndsAtTheLimit() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        let delivery = Task {
            await link.deliver(
                "block.event", payload: JSONValue.object([:]),
                deadline: RexDeliveryDeadline(silence: .seconds(10), limit: .seconds(4)))
        }
        _ = await server.nextRequest()
        #expect(await clock.pass(.seconds(4)))
        guard case .unknown = await delivery.value else {
            Issue.record("Expected an unknown outcome at the limit")
            return
        }
        await link.close()
    }

    /// A delivery written into a silent link has an unknown outcome once the
    /// deadline passes with nothing arriving.
    @Test func aDeliveryMetBySilenceHasAnUnknownOutcome() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        let delivery = Task { await link.deliver("block.event", payload: JSONValue.object([:]), deadline: Self.delivery) }
        _ = await server.nextRequest()
        #expect(await clock.pass(.seconds(10)))
        guard case .unknown = await delivery.value else {
            Issue.record("Expected an unknown outcome")
            return
        }
        #expect(await link.isOpen)
        await link.close()
    }

    /// Time a delivery spends waiting to be written counts toward nothing.
    @Test func aDeliveryWaitsFromWhenItIsWritten() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeRexServer.open(clock: clock)
        let writes = await server.channel.writeCount
        await server.channel.holdWrites()
        let delivery = Task { await link.deliver("block.event", payload: JSONValue.object([:]), deadline: Self.delivery) }
        await server.channel.waitForWrites(writes + 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!clock.isParked(for: .seconds(10)))

        await server.channel.releaseWrites()
        let request = await server.nextRequest()
        #expect(await clock.parks(for: .seconds(10)))
        await server.respond(to: request)
        guard case .answered = await delivery.value else {
            Issue.record("Expected an answer")
            return
        }
        await link.close()
    }

    @Test func aCancelledCallLeavesTheLinkUsable() async throws {
        let (server, link) = try await FakeRexServer.open()
        let task = Task { try await link.call("session.view") }
        let request = await server.nextRequest()
        task.cancel()

        let failure = await error { try await task.value }
        #expect(failure is CancellationError)
        await server.respond(to: request)
        await server.answer("session.list", with: .result(["sessions": []]))
        _ = try await link.call("session.list")
        #expect(await link.isOpen)
        await link.close()
    }

    /// Nothing larger than the welcome's limit is sent.
    @Test func aRequestOverTheServersLimitIsNotSent() async throws {
        var welcome = FakeRexServer.Welcome()
        welcome.maxMessageBytes = 65536
        let (server, link) = try await FakeRexServer.open(welcome: welcome)
        let framesBefore = await server.channel.frames.count

        let failure = await error {
            try await link.call("session.input", payload: Echo(text: String(repeating: "x", count: 70000)))
        }
        guard case .requestTooLarge(let bytes, 65536)? = failure as? RexControlError else {
            Issue.record("Expected the request to be refused, got \(String(describing: failure))")
            return
        }
        #expect(bytes > 70000)
        #expect(await server.channel.frames.count == framesBefore)
        #expect(await link.isOpen)
        await link.close()
    }

    @Test func textGoesOutAsValidUTF8() async throws {
        let (server, link) = try await FakeRexServer.open()
        let text = "日本語 é 🐕 \u{0}"
        async let answered = link.call("session.label", payload: Echo(text: text))
        let request = await server.nextRequest()
        #expect(request.payload?["text"] == .string(text))
        await server.respond(to: request)
        _ = try await answered
        await link.close()
    }

    @Test func aResultOfTheWrongShapeFailsOnlyThatRead() async throws {
        let (server, link) = try await FakeRexServer.open()
        await server.answer("session.list", with: .result(.string("surprise")))

        let response = try await link.call("session.list")
        #expect(throws: RexControlError.self) { try response.result(Echo.self) }
        #expect(await link.isOpen)
        await link.close()
    }

    // MARK: Events

    @Test func eventsArriveInOrderWithTheirSeq() async throws {
        let (server, link) = try await FakeRexServer.open()
        var events = link.events.makeAsyncIterator()

        await server.push("session_created", ["session": ["session_id": "session:a", "label": "lab-a"]])
        await server.push("client_connected", ["client_id": "client:b"])
        await server.push("window_created", ["window_id": "window:w", "label": "one"], session: "session:a")
        await server.push("session_destroyed", ["session_id": "session:a"])

        #expect(
            try await events.next()
                == .event(RexControlEvent(seq: 1, sessionID: nil, body: .sessionCreated(sessionID: "session:a", label: "lab-a"))))
        // An event this build does not know is skipped, and its seq still counts.
        #expect(
            try await events.next()
                == .event(RexControlEvent(seq: 3, sessionID: "session:a", body: .windowCreated(windowID: "window:w", label: "one"))))
        #expect(
            try await events.next()
                == .event(RexControlEvent(seq: 4, sessionID: nil, body: .sessionDestroyed(sessionID: "session:a"))))
        await link.close()
    }

    @Test func aGapARegressionAndAMissingSeqAreReported() async throws {
        let (server, link) = try await FakeRexServer.open()
        var events = link.events.makeAsyncIterator()

        await server.push("block_created", ["block_id": "block:1"], session: "session:a", seq: 1)
        await server.push("block_created", ["block_id": "block:2"], session: "session:a", seq: 3)
        await server.push("block_created", ["block_id": "block:3"], session: "session:a", seq: 2)
        await server.sendText(#"{"type":"event","payload":{"type":"session_destroyed","payload":{"session_id":"session:a"}}}"#)

        #expect(try await events.next() == .event(RexControlEvent(seq: 1, sessionID: "session:a", body: .blockCreated(blockID: "block:1"))))
        #expect(try await events.next() == .sequenceBroken(expected: 2, received: 3))
        #expect(try await events.next() == .event(RexControlEvent(seq: 3, sessionID: "session:a", body: .blockCreated(blockID: "block:2"))))
        #expect(try await events.next() == .sequenceBroken(expected: 4, received: 2))
        #expect(try await events.next() == .event(RexControlEvent(seq: 2, sessionID: "session:a", body: .blockCreated(blockID: "block:3"))))
        #expect(try await events.next() == .sequenceBroken(expected: 3, received: nil))
        await link.close()
    }

    @Test func aMessageOfASurprisingShapeNeverEndsTheLink() async throws {
        let (server, link) = try await FakeRexServer.open()
        var events = link.events.makeAsyncIterator()
        await server.sendText("{")
        await server.sendText(#"{"type":"response","id":"nobody","seq":0,"payload":{}}"#)
        await server.sendText(#"{"type":"event","seq":1,"payload":{"type":"block_closed","payload":{"block_id":[]}}}"#)
        await server.channel.send(binary: Data([1, 2, 3]))
        await server.push("block_closed", ["block_id": "block:1"], seq: 2)

        #expect(try await events.next() == .event(RexControlEvent(seq: 1, sessionID: nil, body: .unreadable(name: "block_closed"))))
        #expect(try await events.next() == .event(RexControlEvent(seq: 2, sessionID: nil, body: .blockClosed(blockID: "block:1"))))
        #expect(await link.isOpen)
        await link.close()
    }

    // MARK: Endings

    @Test(arguments: [
        (UInt16(1000), RexControlEnding.serverWentAway(code: 1000)),
        (1001, .serverWentAway(code: 1001)),
        (1011, .serverWentAway(code: 1011)),
        (1008, .droppedByServer),
        (1002, .protocolFailure),
        (1003, .protocolFailure),
        (1007, .protocolFailure),
        (1009, .messageTooBig),
    ])
    func aServersCloseFrameIsClassified(code: UInt16, ending: RexControlEnding) async throws {
        let (server, link) = try await FakeRexServer.open()
        let pending = Task { try await link.call("session.view") }
        _ = await server.nextRequest()
        await server.close(WebSocketCloseCode(rawValue: code), reason: "bye")

        let failure = await error { try await pending.value }
        guard case .linkEnded(let reason)? = failure as? RexControlError else {
            Issue.record("Expected the link to end, got \(String(describing: failure))")
            return
        }
        #expect(reason == ending)
        // A server that is going away may still keep the client.
        #expect(reason.mayResume == (code == 1001))
        #expect(await link.endingReason == ending)
        await #expect(throws: RexControlError.self) {
            for try await _ in link.events {}
        }
        await server.waitUntilClosed()
    }

    @Test func aDroppedConnectionMayResume() async throws {
        let (server, link) = try await FakeRexServer.open()
        await server.drop()
        await server.waitUntilClosed()

        await #expect(throws: RexControlError.self) {
            for try await _ in link.events {}
        }
        #expect(await link.endingReason == .linkLost)
        #expect(RexControlEnding.linkLost.mayResume)
        let failure = await error { try await link.call("session.list") }
        guard case .linkEnded(.linkLost)? = failure as? RexControlError else {
            Issue.record("Expected the lost link, got \(String(describing: failure))")
            return
        }
    }

    @Test func aMessageLargerThanTheLinkAcceptsEndsIt() async throws {
        var options = RexControlLink.Options.testing
        options.maximumInboundBytes = 1024
        let (server, link) = try await FakeRexServer.open(options: options)
        await server.sendText(String(repeating: "x", count: 2048))
        await server.waitUntilClosed()

        await #expect(throws: RexControlError.self) {
            for try await _ in link.events {}
        }
        #expect(await link.endingReason == .messageTooBig)
    }

    /// Leaving for good sends a close frame; the event sequence just finishes.
    @Test func closingSendsACloseFrame() async throws {
        let (server, link) = try await FakeRexServer.open()
        await link.close()

        #expect(await server.clientClose?.code == .normalClosure)
        #expect(await server.channel.isClosed)
        for try await _ in link.events {}
        #expect(await link.endingReason == .closedHere)
        let failure = await error { try await link.call("session.list") }
        guard case .linkEnded(.closedHere)? = failure as? RexControlError else {
            Issue.record("Expected the closed link, got \(String(describing: failure))")
            return
        }
    }

    @Test func disconnectingSendsNoCloseFrame() async throws {
        let (server, link) = try await FakeRexServer.open()
        await link.disconnect()

        #expect(await server.channel.isClosed)
        #expect(await !server.clientSentCloseFrame)
        #expect(await link.endingReason == .closedHere)
    }

    // MARK: Resuming

    @Test func aResumedClientKeepsItsIdAndTheHelloCarriesTheOldToken() async throws {
        var first = FakeRexServer.Welcome()
        first.reconnectToken = "fake-token-first"
        let (oldServer, old) = try await FakeRexServer.open(welcome: first)

        var again = FakeRexServer.Welcome()
        again.reconnectToken = "fake-token-second"
        again.resumed = true
        let server = FakeRexServer()
        async let opened = RexControlLink.open(
            over: server.channel, resuming: old, options: .testing, sleep: ManualClock().parkedSleep(for:))
        let hello = await server.handshake(again)
        let link = try await opened

        #expect(hello["reconnect_token"] == .string("fake-token-first"))
        // The old connection was dropped, not closed, so the server kept the client.
        #expect(await oldServer.channel.isClosed)
        #expect(await !oldServer.clientSentCloseFrame)
        #expect(link.resumed)
        #expect(link.clientID == old.clientID)
        await link.close()
    }

    @Test func aClientTheServerForgotStartsOver() async throws {
        let (_, old) = try await FakeRexServer.open()
        await old.disconnect()

        var fresh = FakeRexServer.Welcome()
        fresh.clientID = "client:00000000-0000-7000-8000-000000000002"
        let (_, link) = try await FakeRexServer.open(welcome: fresh, resuming: old)

        #expect(!link.resumed)
        #expect(link.clientID != old.clientID)
        await link.close()
    }

    /// A welcome may leave the client out, as a server that cannot resume
    /// clients does: the link opens, and the next one starts a new client.
    @Test func aWelcomeWithoutAClientOpensAndCannotBeResumed() async throws {
        var welcome = FakeRexServer.Welcome()
        welcome.clientID = nil
        let (_, old) = try await FakeRexServer.open(welcome: welcome)
        #expect(old.clientID == nil)
        #expect(!old.resumed)
        #expect(await old.isOpen)

        let server = FakeRexServer()
        async let opened = RexControlLink.open(
            over: server.channel, resuming: old, options: .testing, sleep: ManualClock().parkedSleep(for:))
        let hello = await server.handshake()
        let link = try await opened

        #expect(hello["reconnect_token"] == nil)
        #expect(!link.resumed)
        await link.close()
    }

    @Test func noDescriptionOfALinkShowsItsToken() async throws {
        var welcome = FakeRexServer.Welcome()
        welcome.reconnectToken = "fake-token-secret-91"
        let (_, link) = try await FakeRexServer.open(welcome: welcome)
        await link.close()

        var dumped = ""
        dump(link, to: &dumped)
        for text in [dumped, String(describing: link), String(reflecting: link)] {
            #expect(!text.contains("fake-token-secret-91"))
        }
        let errors: [RexControlError] = [
            .linkEnded(.linkLost), .unsupportedVersion(.unknown), .welcomeTimedOut, .upgradeRefused(status: 403),
        ]
        for error in errors {
            #expect(!String(describing: error).contains("fake-token-secret-91"))
        }
    }
}
