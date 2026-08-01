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

    @Test func successfulConnectPingPublishesRoundTripLatency() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()
        var latencyUpdates = session.latencyUpdates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connected))
        let latency = await latencyUpdates.next()
        #expect(latency != nil)
        if let latency {
            #expect(latency >= .zero)
        }

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

    @Test func suspendDoesNotWaitForAStalledConnectionAttempt() async throws {
        let firstTransport = ScriptedTransport()
        let resumedTransport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        let connector = StalledFirstConnection(
            gate: gate, first: firstTransport, resumed: resumedTransport)
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        try await waitUntil("the first connection should be in flight") {
            await gate.entryCount == 1
        }

        let completion = LifecycleCompletionProbe()
        let suspending = Task {
            await session.suspend()
            await completion.finish()
        }
        try await Task.sleep(for: .milliseconds(100))
        let suspendedPromptly = await completion.isFinished
        #expect(
            suspendedPromptly,
            "suspend must not inherit an unbounded wait from the SSH connection task")
        guard suspendedPromptly else {
            await gate.open()
            await suspending.value
            await session.end()
            return
        }
        await suspending.value
        #expect(await updates.next() == .status(.suspended))

        // A new activation can connect while the abandoned first attempt is
        // still parked. Releasing that stale attempt later only closes its
        // Transport; it cannot replace the current one or emit connected.
        await session.resume()
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.attemptCount == 2)
        #expect(await !resumedTransport.isClosed)

        await gate.open()
        try await waitUntil("the stale connection should be discarded") {
            await firstTransport.isClosed
        }
        #expect(await !resumedTransport.isClosed)

        await session.end()
    }

    private func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record(Comment(rawValue: message))
    }
}

private actor LifecycleCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor StalledFirstConnection {
    private let gate: ScriptedTransportCallGate
    private let first: ScriptedTransport
    private let resumed: ScriptedTransport
    private(set) var attemptCount = 0

    init(
        gate: ScriptedTransportCallGate,
        first: ScriptedTransport,
        resumed: ScriptedTransport
    ) {
        self.gate = gate
        self.first = first
        self.resumed = resumed
    }

    func connect() async throws -> any Transport {
        attemptCount += 1
        if attemptCount == 1 {
            await gate.waitUntilOpen()
            return first
        }
        return resumed
    }
}
