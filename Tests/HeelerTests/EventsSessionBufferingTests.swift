import Foundation
import Testing

@testable import Heeler

/// Bounded buffering on the events path (#22): `EventsSession.updates` sheds
/// the oldest updates under overflow, and every shed update is covered by an
/// `.event(.eventsDropped)` marker so the consumer knows to resync — the
/// snapshot-then-delta contract makes dropping safe exactly when the
/// consumer learns about it.
@Suite("Events session buffering")
struct EventsSessionBufferingTests {
    private func makeSession(transport: ScriptedTransport, bufferLimit: Int) -> EventsSession {
        EventsSession(
            subscriptions: [.global(.paneAgentDetected)],
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            updatesBufferLimit: bufferLimit)
    }

    /// Polls until `condition` holds, yielding so the session's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    private func workingEvent(_ index: Int) -> HerdrEvent {
        .agentStatusChanged(paneID: "w1:p\(index)", status: .working)
    }

    @Test func overflowShedsTheOldestAndSurfacesTheDropMarker() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport, bufferLimit: 3)
        await session.resume()
        try await waitUntil("the events channel should come up") {
            await transport.capturedSubscriptions.count == 1
        }

        // Nobody consumes `updates` yet: connecting, connected, and 10
        // events into a 3-slot buffer must shed the oldest statuses.
        for index in 1...10 {
            await transport.emit(workingEvent(index))
        }
        try await waitUntil("the bounded buffer should shed updates") {
            await session.droppedUpdateCount > 0
        }

        let collector = UpdateCollector()
        let consumeTask = Task {
            for await update in session.updates {
                await collector.append(update)
            }
        }
        try await waitUntil("the newest event and the drop marker should be delivered") {
            let sawMarker = await collector.contains(.event(.eventsDropped))
            let sawNewest = await collector.contains(.event(workingEvent(10)))
            return sawMarker && sawNewest
        }
        // The shed `.connected` is gone for good; the marker stands in for
        // it, telling the consumer to resync instead of trusting the deltas.
        #expect(await !collector.contains(.status(.connected)))

        await session.end()
        await consumeTask.value
    }

    @Test func underTheLimitEveryUpdateArrivesInOrderWithNoMarker() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport, bufferLimit: 8)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        for index in 1...3 {
            await transport.emit(workingEvent(index))
        }
        for index in 1...3 {
            #expect(await updates.next() == .event(workingEvent(index)))
        }
        #expect(await session.droppedUpdateCount == 0)

        await session.end()
    }

    /// A backlog the session's run loop cannot possibly drain before
    /// `suspend()` lands. Teardown cancels that loop but deliberately does
    /// not await it, and a channel closed with events still buffered delivers
    /// them before finishing — so the loop keeps yielding while the terminal
    /// status is being emitted. Ten events left the outcome to the scheduler;
    /// this makes the interleaving certain in both directions.
    private static let undrainableBacklog = 5000

    @Test func suspendedStatusSurvivesAnOverflowingBuffer() async throws {
        // Lifecycle statuses are yielded last on their transitions, and
        // bufferingNewest keeps the newest: an overflow must never eat the
        // `.suspended` the consumer's state machine depends on — not even
        // when the torn-down run loop still has events in hand.
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport, bufferLimit: 2)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        try await waitUntil("the events channel should come up") {
            await transport.capturedSubscriptions.count == 1
        }

        for index in 1...Self.undrainableBacklog {
            await transport.emit(workingEvent(index))
        }
        try await waitUntil("the bounded buffer should shed updates") {
            await session.droppedUpdateCount > 0
        }
        await session.suspend()

        // `suspend()` returns only once `.suspended` has been yielded, and a
        // shed update always re-arms the marker behind it, so the two slots
        // now hold exactly this pair. Asserting on them directly — rather
        // than polling a collector — makes a lost `.suspended` fail on the
        // spot instead of on a deadline.
        #expect(await updates.next() == .status(.suspended))
        #expect(await updates.next() == .event(.eventsDropped))

        await session.end()
    }
}

/// Collects a session's updates so tests can poll for delivery.
private actor UpdateCollector {
    private var updates: [EventsSessionUpdate] = []

    func append(_ update: EventsSessionUpdate) {
        updates.append(update)
    }

    func contains(_ update: EventsSessionUpdate) -> Bool {
        updates.contains(update)
    }
}

