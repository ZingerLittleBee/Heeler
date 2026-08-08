import Foundation
import Testing

@testable import Heeler

/// The events session's application-level keepalive (#18): the herdr ping is
/// the authoritative health check, so an idle stream keeps generating one, an
/// active stream suppresses it, and a ping the connection never answers means
/// the whole connection is dead rather than healthy. The Transport seam is
/// scripted here because the loop under test is the session's, not the SSH
/// backend's — a real Transport contributes only the `.timedOut` it raises at
/// its own request deadline.
/// A session whose keepalive stopped working simply never emits again, so the
/// suite is bounded: a dead loop must fail these tests rather than block the
/// run waiting for a status that will not arrive.
@Suite("EventsSession keepalive", .timeLimit(.minutes(1)))
struct EventsSessionKeepaliveTests {
    private let subscriptions: [EventSubscription] = [.global(.paneAgentDetected)]

    private func makeSession(
        connector: SequencedTransportConnector,
        keepalive: KeepalivePolicy
    ) -> EventsSession {
        EventsSession(
            subscriptions: subscriptions,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: keepalive)
    }

    @Test func keepalivePingsFlowWhileIdleAndAPingTimeoutForcesReconnect() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        // Ping 1 is the connect path and ping 2 the first keepalive; the
        // second keepalive is the one the connection swallows whole.
        await first.failPing(atCall: 3, with: .timedOut)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(
            connector: connector,
            keepalive: KeepalivePolicy(interval: .milliseconds(50)))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connected))

        guard case .status(.reconnecting(let attempt, _, let failure)) = await updates.next()
        else {
            Issue.record("expected a .reconnecting transition after the unanswered ping")
            await session.end()
            return
        }
        #expect(attempt == 1)
        #expect(failure == .timedOut)
        #expect(await updates.next() == .status(.connected))

        // The idle stream generated its own liveness traffic: the connect
        // ping, one answered keepalive, then the unanswered one.
        #expect(await first.pingCount == 3)
        // A hung ping distrusts the whole connection, not just the channel:
        // the old transport is closed and a fresh one is dialed and pinged
        // before the resubscribe.
        #expect(await connector.connectCount == 2)
        #expect(await first.isClosed)
        #expect(await second.pingCount >= 1)
        #expect(await second.capturedSubscriptions == [subscriptions])

        await session.end()
    }

    @Test func keepaliveSkipsPingsWhileEventsProveTheConnectionAlive() async throws {
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = makeSession(
            connector: connector,
            keepalive: KeepalivePolicy(interval: .milliseconds(200)))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connected))

        // ~500ms of continuous events straddles two keepalive wakeups.
        for index in 1...10 {
            try await Task.sleep(for: .milliseconds(50))
            let emitted = await transport.emit(
                .agentStatusChanged(paneID: "w1:p\(index)", status: .working))
            #expect(emitted)
            guard case .event = await updates.next() else {
                Issue.record("expected an event")
                await session.end()
                return
            }
        }

        // Arriving events already do the ping's two jobs (liveness proof,
        // NAT-mapping refresh), so the only ping on record is the connect
        // path's.
        #expect(await transport.pingCount == 1)

        // The stream is quiet now: the next wakeup finds the connection idle
        // and pings again — on the same connection, with no reconnect.
        try await waitUntil("an idle stream should resume keepalive pings") {
            await transport.pingCount >= 2
        }
        #expect(await connector.connectCount == 1)
        #expect(await !transport.isClosed)

        await session.end()
    }

    private func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(3),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(Comment(rawValue: message))
    }
}
