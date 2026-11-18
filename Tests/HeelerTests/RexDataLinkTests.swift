import Foundation
import HeelerSSH
import Testing

@testable import Heeler

/// The data link of a Rex terminal against a fake data endpoint shaped after
/// Rex 0.1.0-preview.14 (API revision 12): the handshake's bytes, counting,
/// resuming once, refusals, and how a link ends. Deadlines run on a manual
/// clock. Ids, tickets, tokens and nonces are invented.
@Suite("Rex data link", .timeLimit(.minutes(1)))
struct RexDataLinkTests {
    static let session = "session:00000000-0000-7000-8000-00000000000a"
    static let block = "block:00000000-0000-7000-8000-00000000000b"
    static let nonce: UInt64 = 0x1D2C_3B4A_5968_7786

    struct Fixture {
        let control: FakeRexServer
        let link: RexControlLink
        let endpoint: FakeRexDataEndpoint
        let clock: ManualClock

        var route: RexDataRoute { endpoint.route(control: link) }

        func open(block: String = RexDataLinkTests.block) async throws -> RexDataLink {
            try await RexDataLink.open(
                session: RexDataLinkTests.session, block: block, route: route, options: .testing,
                sleep: clock.parkedSleep(for:))
        }
    }

    static func fixture() async throws -> Fixture {
        let clock = ManualClock()
        let (control, link) = try await FakeRexServer.open(clock: clock)
        let endpoint = FakeRexDataEndpoint()
        await endpoint.tickets.install(on: control)
        return Fixture(control: control, link: link, endpoint: endpoint, clock: clock)
    }

    private func error(_ operation: () async throws -> some Any) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func receive(_ count: Int, from link: RexDataLink) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes += try await link.receive() }
        return bytes
    }

    private func ending(of failure: (any Error)?) -> RexDataEnding? {
        guard case .ended(let ending)? = failure as? RexDataLinkError else { return nil }
        return ending
    }

    // MARK: The handshake's bytes

    @Test func aHelloIsTheTypeByteAndTheTicket() throws {
        let bytes = (0..<16).map { UInt8($0 * 9 + 1) }
        let ticket = try #require(RexDataTicket(text: FakeRexTicketBook.text(bytes)))
        #expect(RexDataHandshake.hello(ticket) == Data([0x01] + bytes))
    }

    /// A ticket is 16 bytes of base64url with no padding: 22 characters.
    @Test(arguments: ["AAAAAAAAAAAAAAAAAAAAAA==", "AAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAAAAAAAA!A", ""])
    func aTicketOfAnotherShapeIsNotOne(text: String) {
        #expect(RexDataTicket(text: text) == nil)
    }

    @Test func aTicketReadsBase64URL() throws {
        let bytes: [UInt8] = [0xFB, 0xFF, 0xBF] + Array(repeating: 0xFE, count: 13)
        let text = FakeRexTicketBook.text(bytes)
        #expect(text.contains("-") || text.contains("_"))
        let ticket = try #require(RexDataTicket(text: text))
        #expect(RexDataHandshake.hello(ticket).dropFirst() == Data(bytes))
    }

    @Test func aResumeIsTheTypeByteTheTokenAndTheCount() throws {
        let tokenBytes = (0..<16).map { UInt8(0xF0 - $0) }
        let token = try #require(RexDataResumeToken(bytes: tokenBytes))
        let resume = RexDataHandshake.resume(token, receivedByteCount: 0x0102_0304_0506_0708)
        #expect(resume == Data([0x02] + tokenBytes + [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]))
        #expect(resume.count == 25)
    }

    @Test func aWelcomeCarriesTheTokenTheRetentionAndTheNonce() throws {
        let tokenBytes = (0..<16).map { UInt8($0 + 0x20) }
        var message: [UInt8] = [0x81] + tokenBytes + [0, 0, 0]
        message += [0x60, 0xEA, 0x00, 0x00]  // 60000
        message += [0x86, 0x77, 0x68, 0x59, 0x4A, 0x3B, 0x2C, 0x1D]
        let expected = RexDataWelcome(
            resumeToken: try #require(RexDataResumeToken(bytes: tokenBytes)), retention: .seconds(60),
            nonce: Self.nonce)
        #expect(RexDataHandshake.answer(Data(message)) == .welcome(expected))
        #expect(RexDataHandshake.answer(Data(message.dropLast())) == .unreadable)
        #expect(RexDataHandshake.answer(Data(message + [0])) == .unreadable)
    }

    @Test(arguments: [
        (UInt8(1), RexDataRefusal.unknownCredential), (2, .alreadyConnected), (3, .streamUnavailable),
        (4, .limitReached), (5, .malformedHandshake), (6, .serverFailed), (7, .wrongSubprotocol), (42, .other(42)),
    ])
    func aRejectNamesItsReason(reason: UInt8, refusal: RexDataRefusal) {
        #expect(RexDataHandshake.answer(Data([0x82, reason])) == .refused(refusal))
        #expect(refusal.reason == reason)
    }

    @Test func aRejectOfAnotherSizeIsUnreadable() {
        #expect(RexDataHandshake.answer(Data([0x82])) == .unreadable)
        #expect(RexDataHandshake.answer(Data([0x82, 1, 0])) == .unreadable)
        #expect(RexDataHandshake.answer(Data()) == .unreadable)
        #expect(RexDataHandshake.answer(Data([0x01] + Array(repeating: 0, count: 31))) == .unreadable)
    }

    // MARK: Opening

    /// The ticket comes from `data.connect` for the terminal's data source, and
    /// the HELLO goes out as soon as the upgrade is answered.
    @Test func openingAsksForATicketAndSaysHello() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()

        let request = try #require(fixture.endpoint.tickets.requests.first)
        #expect(request["session_id"] == .string(Self.session))
        #expect(request["block_id"] == .string(Self.block))
        #expect(request["data_ref_id"] == "terminal")
        #expect(request["subprotocol"] == "rex.data.terminal.v1")

        let channel = try #require(await fixture.endpoint.channels.first)
        let upgrade = await channel.upgradeRequest
        #expect(upgrade?.requestLine == "GET /api/data HTTP/1.1")
        #expect(upgrade?.field("Sec-WebSocket-Protocol") == "rex.data.terminal.v1")
        let hello = await channel.frames.first
        #expect(hello?.opcode == .binary)
        let ticketText = try #require(fixture.endpoint.tickets.ticketTexts.first)
        let ticket = try #require(RexDataTicket(text: ticketText))
        #expect(hello?.payload == RexDataHandshake.hello(ticket))
        #expect(await fixture.endpoint.handshakes == [.init(kind: .hello, byteCount: 17, outcome: .welcomed(stream: 0))])

        #expect(link.nonce == Self.nonce)
        #expect(link.retention == .seconds(60))
        #expect(!link.resumed)
        #expect(await link.receivedByteCount == 0)
        await link.close()
    }

    @Test func aRefusedTicketSaysWhy() async throws {
        let fixture = try await Self.fixture()
        fixture.endpoint.tickets.fail(with: [.error(code: "conflict", message: "not attached", status: 409)])
        let failure = await error { try await fixture.open() }
        guard case .ticketUnavailable(.server(let server))? = failure as? RexDataLinkError else {
            Issue.record("Expected a refused ticket, got \(String(describing: failure))")
            return
        }
        #expect(server.kind == .conflict)
        // The channel opened for it is closed, never upgraded.
        let channel = try #require(await fixture.endpoint.channels.first)
        await channel.waitUntilClosed()
        #expect(await channel.upgradeRequest == nil)
        #expect(await fixture.endpoint.handshakes.isEmpty)
    }

    /// Waiting for an attach slot can outlast a ticket, which is good for one
    /// minute: the ticket is asked for only once the channel is in hand.
    @Test func theTicketIsAskedForOnlyOnceTheChannelIsInHand() async throws {
        let fixture = try await Self.fixture()
        let slot = AsyncStream.makeStream(of: Void.self)
        let route = RexDataRoute(
            control: { fixture.link },
            openChannel: {
                for await _ in slot.stream { break }
                return await fixture.endpoint.connect()
            })
        let opening = Task {
            try await RexDataLink.open(
                session: Self.session, block: Self.block, route: route, options: .testing,
                sleep: fixture.clock.parkedSleep(for:))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.endpoint.tickets.requests.isEmpty)

        slot.continuation.yield()
        let link = try await opening.value
        #expect(fixture.endpoint.tickets.requests.count == 1)
        #expect(await fixture.endpoint.handshakes == [.init(kind: .hello, byteCount: 17, outcome: .welcomed(stream: 0))])
        await link.close()
    }

    /// A data link cancelled while its ticket is on the way closes the
    /// channel it opened, and says no HELLO.
    @Test func cancellingWhileTheTicketIsOnItsWayClosesTheChannel() async throws {
        let fixture = try await Self.fixture()
        await fixture.control.stopAnswering("data.connect")
        let opening = Task { try await fixture.open() }
        _ = await fixture.control.nextRequest()
        opening.cancel()

        let failure = await error { try await opening.value }
        #expect(failure is CancellationError)
        let channel = try #require(await fixture.endpoint.channels.first)
        await channel.waitUntilClosed()
        #expect(await channel.upgradeRequest == nil)
    }

    /// Rex ends a connection that stays silent too long before its upgrade,
    /// which a slow ticket can outlast: the unused ticket goes once more on a
    /// new channel, and a second such ending is the link's.
    @Test func aChannelEndedBeforeItsUpgradeIsOpenedOnceMore() async throws {
        let fixture = try await Self.fixture()
        await fixture.endpoint.script(.closeBeforeUpgrade)
        let link = try await fixture.open()
        #expect(await fixture.endpoint.channels.count == 2)
        #expect(fixture.endpoint.tickets.requests.count == 1)
        #expect(await fixture.endpoint.handshakes == [.init(kind: .hello, byteCount: 17, outcome: .welcomed(stream: 0))])
        await link.close()

        let again = try await Self.fixture()
        await again.endpoint.script(.closeBeforeUpgrade, .closeBeforeUpgrade)
        let failure = await error { try await again.open() }
        #expect(ending(of: failure) == .linkLost)
        #expect(await again.endpoint.channels.count == 2)
        #expect(again.endpoint.tickets.requests.count == 1)
    }

    @Test func aRefusedUpgradeSaysItsStatus() async throws {
        let fixture = try await Self.fixture()
        await fixture.endpoint.script(.refuseUpgrade(status: 404))
        let failure = await error { try await fixture.open() }
        guard case .upgradeRefused(let status)? = failure as? RexDataLinkError else {
            Issue.record("Expected a refused upgrade, got \(String(describing: failure))")
            return
        }
        #expect(status == 404)
    }

    @Test(arguments: [UInt8(1), 2, 3, 4, 5, 6, 7])
    func aRefusedHelloSaysWhy(reason: UInt8) async throws {
        let fixture = try await Self.fixture()
        await fixture.endpoint.script(.refuse(reason: reason))
        let failure = await error { try await fixture.open() }
        #expect(ending(of: failure) == .refused(RexDataRefusal(reason: reason)))
        #expect(ending(of: failure)?.recovery == .startOver)
        #expect(await fixture.endpoint.channels.first?.isClosed == true)
    }

    @Test func aHelloThatGoesUnansweredTimesOut() async throws {
        let fixture = try await Self.fixture()
        await fixture.endpoint.script(.stayQuiet)
        let opening = Task { try await fixture.open() }
        await fixture.endpoint.waitForHandshakes(1)
        #expect(await fixture.clock.pass(RexDataLink.Options.testing.answerDeadline))
        let failure = await error { try await opening.value }
        guard case .answerTimedOut? = failure as? RexDataLinkError else {
            Issue.record("Expected a timeout, got \(String(describing: failure))")
            return
        }
        let channel = try #require(await fixture.endpoint.channels.first)
        await channel.waitUntilClosed()
        #expect(await !channel.frames.contains { $0.opcode == .close })
    }

    /// A second HELLO while the first connection is live is refused; once that
    /// one is dropped, a new ticket opens a new stream.
    @Test func aSecondConnectionWaitsForTheFirstToGo() async throws {
        let fixture = try await Self.fixture()
        let first = try await fixture.open()
        let refused = await error { try await fixture.open() }
        #expect(ending(of: refused) == .refused(.alreadyConnected))

        await first.disconnect()
        let fresh = try await fixture.open()
        #expect(await fixture.endpoint.streamCount == 2)
        #expect(fresh.nonce != first.nonce)
        await fresh.close()
    }

    // MARK: Counting and resuming

    @Test func bytesAreCountedHoweverTheyAreSplit() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        let bytes = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        await fixture.endpoint.send(bytes, cuts: [1, 7, 300, 999])

        #expect(try await receive(1000, from: link) == bytes)
        #expect(await link.receivedByteCount == 1000)
        await link.close()
    }

    @Test func aResumeCarriesTheCountAndKeepsTheStream() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await fixture.endpoint.send(Data(repeating: 0x41, count: 300), cuts: [100])
        _ = try await receive(300, from: link)
        await fixture.endpoint.drop()

        let failure = await error { try await link.receive() }
        #expect(ending(of: failure) == .linkLost)
        let resumed = try await link.resume(over: fixture.route)

        let handshakes = await fixture.endpoint.handshakes
        #expect(handshakes.last == .init(kind: .resume(count: 300), byteCount: 25, outcome: .welcomed(stream: 0)))
        let resume = try #require(await fixture.endpoint.channels.last?.frames.first)
        #expect(resume.opcode == .binary)
        #expect(resume.payload.prefix(1) == Data([0x02]))
        #expect(resume.payload.suffix(8) == Data([0x2C, 0x01, 0, 0, 0, 0, 0, 0]))
        #expect(resumed.nonce == link.nonce)
        #expect(resumed.resumed)
        #expect(await resumed.receivedByteCount == 300)

        await fixture.endpoint.send(Data(repeating: 0x42, count: 50))
        #expect(try await receive(50, from: resumed) == Data(repeating: 0x42, count: 50))
        #expect(await resumed.receivedByteCount == 350)
        // The dropped link is done: more from it would be counted twice.
        #expect(ending(of: await error { try await link.receive() }) != nil)

        // Each WELCOME's token replaces the last: a second drop resumes with the new one.
        await fixture.endpoint.drop()
        _ = await error { try await resumed.receive() }
        let again = try await resumed.resume(over: fixture.route)
        #expect(await fixture.endpoint.handshakes.last?.outcome == .welcomed(stream: 0))
        await again.close()
    }

    /// Bytes the server wrote that no receive returned make the count too
    /// low, and Rex refuses that. After one refusal the link may not try again,
    /// and only a new stream goes on.
    @Test func aRefusedResumeIsTheLinksLastTry() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await fixture.endpoint.send(Data(repeating: 0x43, count: 100))
        await link.disconnect()

        let refused = await error { try await link.resume(over: fixture.route) }
        #expect(ending(of: refused) == .refused(.streamUnavailable))
        #expect(await fixture.endpoint.handshakes.last?.kind == .resume(count: 0))
        let channels = await fixture.endpoint.channels.count

        let again = await error { try await link.resume(over: fixture.route) }
        guard case .notResumable(nil)? = again as? RexDataLinkError else {
            Issue.record("Expected no second resume, got \(String(describing: again))")
            return
        }
        #expect(await fixture.endpoint.channels.count == channels)

        let fresh = try await fixture.open()
        #expect(await fixture.endpoint.handshakes.last?.outcome == .welcomed(stream: 1))
        await fresh.close()
    }

    /// A RESUME whose channel could not be opened never went out, so the link
    /// may still try it.
    @Test func aResumeWhoseChannelFailedMayBeTriedAgain() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await link.disconnect()
        let failing = RexDataRoute(control: { fixture.link }, openChannel: { throw SSHError.channelFailed })
        #expect(await error { try await link.resume(over: failing) } is SSHError)

        let resumed = try await link.resume(over: fixture.route)
        #expect(resumed.resumed)
        await resumed.close()
    }

    @Test func aClosedLinkIsNotResumed() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await link.close()
        await fixture.endpoint.waitForClientCloses(1)
        #expect(await fixture.endpoint.clientCloses == [WebSocketClose(code: .normalClosure)])

        let failure = await error { try await link.resume(over: fixture.route) }
        guard case .notResumable(.closedHere?)? = failure as? RexDataLinkError else {
            Issue.record("Expected no resume after close, got \(String(describing: failure))")
            return
        }
    }

    /// A link that may be resumed is dropped, never closed: the server keeps
    /// its stream.
    @Test func disconnectingSendsNoCloseFrame() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await link.disconnect()
        let channel = try #require(await fixture.endpoint.channels.first)
        await channel.waitUntilClosed()
        #expect(await !channel.frames.contains { $0.opcode == .close })
        #expect(await link.endingReason == .disconnectedHere)
    }

    // MARK: Endings

    @Test(arguments: [
        (UInt16(4000), "", RexDataEnding.blockClosed, RexDataEnding.Recovery.stop),
        (1001, "data provider canceled", .providerCanceled, .startOver),
        (1001, "keepalive timeout", .serverWentAway(code: 1001), .resume),
        (1013, "", .tryAgainLater, .startOver),
        (1008, "", .serverWentAway(code: 1008), .startOver),
        (1011, "", .serverWentAway(code: 1011), .startOver),
        (1000, "", .serverWentAway(code: 1000), .startOver),
        (1002, "", .protocolFailure, .startOver),
    ])
    func aCloseFrameSaysHowTheStreamEnded(
        code: UInt16, reason: String, expected: RexDataEnding, recovery: RexDataEnding.Recovery
    ) async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await fixture.endpoint.close(code: WebSocketCloseCode(rawValue: code), reason: reason)
        let failure = await error { try await link.receive() }
        #expect(ending(of: failure) == expected)
        #expect(expected.recovery == recovery)
        #expect(await link.endingReason == expected)
    }

    @Test func aConnectionThatEndsWithoutACloseFrameIsLost() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await fixture.endpoint.drop()
        let failure = await error { try await link.receive() }
        #expect(ending(of: failure) == .linkLost)
        #expect(RexDataEnding.linkLost.recovery == .resume)
    }

    @Test func socketFailuresReadAsTheirEndings() {
        #expect(RexDataEnding(.pongTimedOut) == .linkLost)
        #expect(RexDataEnding(.sendInterrupted) == .linkLost)
        #expect(RexDataEnding(.connectionLost(nil)) == .linkLost)
        #expect(RexDataEnding(.closedLocally) == .disconnectedHere)
        #expect(RexDataEnding(.protocolViolation(.maskedServerFrame)) == .protocolFailure)
        #expect(RexDataEnding.disconnectedHere.recovery == .resume)
        #expect(RexDataEnding.closedHere.recovery == .stop)
    }

    // MARK: Secrecy

    /// Tickets and tokens never show in a description, a dump, or an error.
    @Test func credentialsNeverShow() async throws {
        let fixture = try await Self.fixture()
        let link = try await fixture.open()
        await link.disconnect()
        await fixture.endpoint.script(.refuse(reason: 3))
        let failure = try #require(await error { try await link.resume(over: fixture.route) })
        let second = try #require(await error { try await link.resume(over: fixture.route) })

        let ticketText = try #require(fixture.endpoint.tickets.ticketTexts.first)
        let ticket = try #require(RexDataTicket(text: ticketText))
        let token = try #require(RexDataResumeToken(bytes: Array(repeating: 0x5A, count: 16)))
        var dumped = ""
        dump(ticket, to: &dumped)
        dump(token, to: &dumped)
        let shown = [
            String(describing: ticket), String(reflecting: ticket), "\(ticket)", String(describing: token),
            String(reflecting: token), dumped, String(describing: failure), String(reflecting: failure),
            String(describing: second), String(describing: link),
        ]
        let ticketHex = Data(RexDataHandshake.hello(ticket).dropFirst()).map { String(format: "%02x", $0) }.joined()
        for text in shown {
            #expect(!text.contains(ticketText))
            #expect(!text.lowercased().contains(ticketHex))
            #expect(!text.contains("90, 90, 90"))
        }
        #expect(Mirror(reflecting: ticket).children.isEmpty)
        #expect(Mirror(reflecting: token).children.isEmpty)
        let upgrade = await fixture.endpoint.channels.first?.upgradeRequest
        #expect(upgrade?.fields.values.joined().joined().contains(ticketText) == false)
    }
}

extension RexDataLink.Options {
    /// No client pings, so only the test moves the clock.
    static var testing: RexDataLink.Options {
        var options = RexDataLink.Options()
        options.keepalive = nil
        return options
    }
}
