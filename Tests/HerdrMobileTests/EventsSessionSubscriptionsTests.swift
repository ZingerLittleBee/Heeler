import Foundation
import Synchronization
import Testing

@testable import HerdrMobile

/// `EventsSession.updateSubscriptions` (#8): pane-scoped subscriptions come
/// and go with panes, so a live session must be able to swap its set without
/// tearing the SSH connection down or paying reconnect backoff.
@Suite("EventsSession subscription updates")
struct EventsSessionSubscriptionsTests {
    private let initial: [EventSubscription] = [.global(.paneAgentDetected)]
    private let updated: [EventSubscription] = [
        .global(.paneAgentDetected),
        .pane(.agentStatusChanged, paneID: "w1:p1"),
    ]

    private func makeSession(transport: ScriptedTransport) -> EventsSession {
        EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
    }

    @Test func liveUpdateResubscribesOnTheSameConnectionWithoutReconnecting() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connected))
        #expect(await session.transportGeneration == 0)

        await session.updateSubscriptions(updated)

        // A fresh `.connected` follows with no `.reconnecting` in between:
        // the teardown was deliberate, not a failure.
        #expect(await updates.next() == .status(.connected))
        #expect(await session.transportGeneration == 0)
        #expect(await transport.capturedSubscriptions == [initial, updated])
        #expect(await !transport.isClosed, "resubscribe must reuse the SSH connection")

        // The new pane subscription is live: events flow on the new stream.
        let emitted = await transport.emit(
            .agentStatusChanged(paneID: "w1:p1", status: .blocked))
        #expect(emitted)
        #expect(
            await updates.next()
                == .event(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))

        await session.end()
    }

    @Test func unchangedSetIsANoOp() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connected))

        await session.updateSubscriptions(initial)

        #expect(await transport.capturedSubscriptions == [initial])
        await session.end()
    }

    @Test func updateWhileSuspendedTakesEffectOnResume() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.updateSubscriptions(updated)
        await session.resume()

        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [updated])
        await session.end()
    }

    @Test func permanentFailureStopsTheReconnectLoop() async throws {
        let connectionAttempts = Mutex(0)
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                connectionAttempts.withLock { $0 += 1 }
                throw TransportError.authenticationFailed
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1), multiplier: 1, maxDelay: .milliseconds(1)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.failed(.authenticationFailed)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connectionAttempts.withLock { $0 } == 1)

        await session.end()
    }

    @Test func corruptDeviceKeyStopsWithActionRequiredInsteadOfReconnecting() async throws {
        let connectionAttempts = Mutex(0)
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                connectionAttempts.withLock { $0 += 1 }
                throw DeviceKeyStoreError.storedKeyCorrupt
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1), multiplier: 1, maxDelay: .milliseconds(1)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.failed(.deviceKeyCorrupt)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connectionAttempts.withLock { $0 } == 1)

        await session.end()
    }
}
