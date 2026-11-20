import Foundation
import HeelerSSH
import Testing

@testable import Heeler

@Suite(.timeLimit(.minutes(1)))
struct WebSocketLinkTests {
    private static func eventually(_ condition: () async -> Bool) async -> Bool {
        var budget = PollBudget(.seconds(10))
        while !(await condition()) {
            guard budget.hasTimeLeft else { return false }
            try? await Task.sleep(for: .milliseconds(1))
            budget.charge()
        }
        return true
    }

    private static func close(in frame: WebSocketFrame) throws -> WebSocketClose {
        #expect(frame.opcode == .close)
        return try WebSocketClose(payload: frame.payload)
    }

    // MARK: Opening

    @Test func upgradesAndKeepsTheBytesThatFollowTheAnswer() async throws {
        let server = FakeWebSocketServer()
        async let connecting = WebSocketLink.connect(
            over: server, path: "/api/control", subprotocol: "rex.control.v1", sleep: ManualClock().parkedSleep(for:))
        let request = await server.nextUpgradeRequest()
        #expect(request.requestLine == "GET /api/control HTTP/1.1")
        #expect(request.field("Host") == "localhost")
        #expect(request.field("Upgrade") == "websocket")
        #expect(request.field("Connection") == "Upgrade")
        #expect(request.field("Sec-WebSocket-Version") == "13")
        #expect(request.field("Sec-WebSocket-Protocol") == "rex.control.v1")
        #expect(request.fields["sec-websocket-extensions"] == nil)
        let key = try #require(request.field("Sec-WebSocket-Key"))
        #expect(Data(base64Encoded: key)?.count == 16)

        // The first message rides in the same read as the 101.
        await server.acceptUpgrade(
            trailing: WebSocketFrame(opcode: .text, payload: Data("welcome".utf8)).encoded(maskKey: nil))
        let link = try await connecting
        #expect(try await link.receive() == .text("welcome"))
        #expect(await link.isOpen)
    }

    @Test func surfacesARefusedUpgradeAndClosesTheChannel() async throws {
        let server = FakeWebSocketServer()
        async let connecting = WebSocketLink.connect(
            over: server, path: "/api/control", subprotocol: "rex.control.v1", sleep: ManualClock().parkedSleep(for:))
        _ = await server.nextUpgradeRequest()
        await server.deliver(Data(
            "HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{\"error\":\"not allowed\"}".utf8))
        do {
            _ = try await connecting
            Issue.record("A 403 answer opened the link")
        } catch WebSocketError.upgradeRefused(let status) {
            #expect(status == 403)
        }
        await server.waitUntilClosed()
        #expect(await server.frames.isEmpty)
    }

    @Test func failsAnUpgradeToAnotherSubprotocol() async throws {
        let server = FakeWebSocketServer()
        async let connecting = WebSocketLink.connect(
            over: server, path: "/api/data", subprotocol: "rex.data.terminal.v1", sleep: ManualClock().parkedSleep(for:))
        await server.acceptUpgrade(subprotocol: "rex.control.v1")
        do {
            _ = try await connecting
            Issue.record("Another subprotocol opened the link")
        } catch WebSocketError.upgradeInvalid(.wrongSubprotocol) {}
        await server.waitUntilClosed()
    }

    @Test func givesUpOnAnUpgradeThatNeverCompletes() async throws {
        let clock = ManualClock()
        let server = FakeWebSocketServer()
        async let connecting = WebSocketLink.connect(
            over: server, path: "/api/control", subprotocol: "rex.control.v1", sleep: clock.parkedSleep(for:))
        _ = await server.nextUpgradeRequest()
        await server.deliver(Data("HTTP/1.1 101 Switching Protocols\r\n".utf8))
        #expect(await clock.pass(.seconds(10)))
        do {
            _ = try await connecting
            Issue.record("A half answer opened the link")
        } catch WebSocketError.handshakeTimedOut {}
        await server.waitUntilClosed()
    }

    @Test func aCancelledUpgradeClosesTheChannel() async throws {
        let server = FakeWebSocketServer()
        let connecting = Task {
            try await WebSocketLink.connect(
                over: server, path: "/api/control", subprotocol: "rex.control.v1",
                sleep: ManualClock().parkedSleep(for:))
        }
        _ = await server.nextUpgradeRequest()
        connecting.cancel()
        do {
            _ = try await connecting.value
            Issue.record("A cancelled upgrade opened the link")
        } catch is CancellationError {}
        await server.waitUntilClosed()
    }

    /// A task cancelled before it connects closes the channel at once,
    /// rather than wait out the handshake deadline for an answer.
    @Test func anUpgradeCancelledBeforeItBeginsClosesTheChannel() async throws {
        let server = FakeWebSocketServer()
        let connecting = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await WebSocketLink.connect(
                over: server, path: "/api/control", subprotocol: "rex.control.v1",
                sleep: ManualClock().parkedSleep(for:))
        }
        connecting.cancel()
        do {
            _ = try await connecting.value
            Issue.record("A cancelled upgrade opened the link")
        } catch is CancellationError {}
        await server.waitUntilClosed()
    }

    // MARK: Messages

    @Test func masksEveryFrameWithAFreshKey() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        try await link.send(text: "one")
        try await link.send(binary: Data([1, 2, 3]))
        let text = await server.nextFrame()
        let binary = await server.nextFrame()
        #expect(text.opcode == .text && text.payload == Data("one".utf8) && text.isFinal)
        #expect(binary.opcode == .binary && binary.payload == Data([1, 2, 3]))
        #expect(text.maskKey != nil && binary.maskKey != nil)
        #expect(text.maskKey != binary.maskKey)
        #expect(await server.clientViolation == nil)
    }

    @Test func answersAPingBetweenTheFragmentsOfAMessage() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        await server.send(WebSocketFrame(opcode: .text, payload: Data("Hel".utf8), isFinal: false))
        await server.deliverReadTimeout()
        await server.send(WebSocketFrame(opcode: .ping, payload: Data("still there?".utf8)))
        // Nothing has called receive: the pong goes out on its own.
        let pong = await server.nextFrame()
        #expect(pong.opcode == .pong)
        #expect(pong.payload == Data("still there?".utf8))
        #expect(pong.maskKey != nil)
        await server.send(WebSocketFrame(opcode: .continuation, payload: Data("lo".utf8)))
        #expect(try await link.receive() == .text("Hello"))
    }

    // MARK: Closing

    @Test func reportsThePeersCloseAfterTheMessagesBeforeIt() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        let blockClosed = WebSocketClose(code: WebSocketCloseCode(rawValue: 4000), reason: "block closed")
        await server.send(text: "last words")
        await server.sendClose(blockClosed.code, reason: blockClosed.reason)
        // The answer echoes the code.
        #expect(try Self.close(in: await server.nextFrame()).code == blockClosed.code)
        await server.waitUntilClosed()

        #expect(try await link.receive() == .text("last words"))
        do {
            _ = try await link.receive()
            Issue.record("A closed link received a message")
        } catch WebSocketError.closedByPeer(let close) {
            #expect(close == blockClosed)
        }
        do {
            try await link.send(text: "too late")
            Issue.record("A closed link sent a message")
        } catch WebSocketError.closedByPeer {}
        #expect(await link.close() == blockClosed)
    }

    @Test func closesWithACodeAndReasonAndWaitsForTheAnswer() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        async let answer = link.close(.normalClosure, reason: "bye")
        #expect(try Self.close(in: await server.nextFrame()) == WebSocketClose(code: .normalClosure, reason: "bye"))
        await server.sendClose(.normalClosure)
        #expect(await answer == WebSocketClose(code: .normalClosure))
        #expect(await server.isClosed)
        #expect(await !link.isOpen)
        do {
            try await link.send(text: "after close")
            Issue.record("A closed link sent a message")
        } catch WebSocketError.closedLocally {}
    }

    @Test func closeStopsWaitingForAnAnswerAtItsDeadline() async throws {
        let clock = ManualClock()
        let (server, link) = try await FakeWebSocketServer.open(clock: clock)
        async let answer = link.close(.goingAway)
        #expect(try Self.close(in: await server.nextFrame()).code == .goingAway)
        #expect(await clock.pass(.seconds(2)))
        #expect(await answer == nil)
        #expect(await server.isClosed)
    }

    @Test func failsTheConnectionOnAMaskedServerFrame() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        await server.deliver(WebSocketFrame(opcode: .text, payload: Data("x".utf8)).encoded(maskKey: 7))
        #expect(try Self.close(in: await server.nextFrame()).code == .protocolError)
        await server.waitUntilClosed()
        do {
            _ = try await link.receive()
            Issue.record("A broken link received a message")
        } catch WebSocketError.protocolViolation(let violation) {
            #expect(violation == .maskedServerFrame)
        }
    }

    @Test func closesWith1009ForAnOversizedMessage() async throws {
        var options = WebSocketLink.Options()
        options.maximumMessageBytes = 100
        let (server, link) = try await FakeWebSocketServer.open(options: options)
        await server.send(binary: Data(count: 101))
        #expect(try Self.close(in: await server.nextFrame()).code == .messageTooBig)
        do {
            _ = try await link.receive()
            Issue.record("An oversized message arrived")
        } catch WebSocketError.protocolViolation(.messageTooBig) {}
    }

    @Test func endOfFileWithoutACloseFrameIsALostConnection() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        await server.deliverEndOfFile()
        do {
            _ = try await link.receive()
            Issue.record("A link at end of file received a message")
        } catch WebSocketError.connectionLost(let underlying) {
            #expect(underlying == nil)
        }
        await server.waitUntilClosed()
    }

    // MARK: Failure and cancellation

    @Test func aFailedWriteEndsTheLinkAndNothingMoreIsWritten() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        await server.failNextWrite()
        do {
            try await link.send(text: "half of this leaves")
            Issue.record("A failed write reported success")
        } catch WebSocketError.sendInterrupted {}
        await server.waitUntilClosed()
        let writes = await server.writeCount
        do {
            try await link.send(text: "after the failure")
            Issue.record("A failed link sent a message")
        } catch WebSocketError.connectionLost(let underlying) {
            #expect(underlying as? SSHError == .channelFailed)
        }
        do {
            _ = try await link.receive()
            Issue.record("A failed link received a message")
        } catch WebSocketError.connectionLost {}
        #expect(await link.close() == nil)
        #expect(await server.writeCount == writes)
    }

    @Test func aCancelledReceiveEndsTheLinkWithoutACloseFrame() async throws {
        let (server, link) = try await FakeWebSocketServer.open()
        let receiving = Task { try await link.receive() }
        receiving.cancel()
        do {
            _ = try await receiving.value
            Issue.record("A cancelled receive returned a message")
        } catch is CancellationError {}
        await server.waitUntilClosed()
        #expect(await server.frames.isEmpty)
        do {
            try await link.send(text: "after cancel")
            Issue.record("A cancelled link sent a message")
        } catch WebSocketError.closedLocally {}
    }

    // MARK: Read-ahead

    @Test func readAheadStopsAtItsLimitAndResumesWhenConsumed() async throws {
        var options = WebSocketLink.Options()
        options.readAheadBytes = 10
        let (server, link) = try await FakeWebSocketServer.open(options: options)
        let payloads = (1...3).map { Data(repeating: UInt8($0), count: 8) }
        for payload in payloads { await server.send(binary: payload) }

        // Two unclaimed messages reach the limit; the third stays in the channel.
        #expect(await Self.eventually { await link.isReadAheadFull })
        #expect(await server.unreadByteCount == 10)

        #expect(try await link.receive() == .binary(payloads[0]))
        #expect(await Self.eventually { await server.unreadByteCount == 0 })
        #expect(await Self.eventually { await link.isReadAheadFull })

        #expect(try await link.receive() == .binary(payloads[1]))
        #expect(try await link.receive() == .binary(payloads[2]))
        await server.waitForPendingRead()
        #expect(await !link.isReadAheadFull)
    }

    // MARK: Keepalive

    @Test func keepalivePingsAndNoticesASilentServer() async throws {
        let clock = ManualClock()
        var options = WebSocketLink.Options()
        options.keepalive = .init(interval: .seconds(120), pongDeadline: .seconds(60))
        let (server, link) = try await FakeWebSocketServer.open(options: options, clock: clock)

        #expect(await clock.pass(.seconds(120)))
        let ping = await server.nextFrame()
        #expect(ping.opcode == .ping)
        await server.send(WebSocketFrame(opcode: .pong, payload: ping.payload))
        await server.waitForPendingRead()
        #expect(await clock.pass(.seconds(60)))
        #expect(await link.isOpen)

        #expect(await clock.pass(.seconds(120)))
        #expect(await server.nextFrame().opcode == .ping)
        #expect(await clock.pass(.seconds(60)))
        await server.waitUntilClosed()
        do {
            _ = try await link.receive()
            Issue.record("A silent server's link received a message")
        } catch WebSocketError.pongTimedOut {}
    }
}
