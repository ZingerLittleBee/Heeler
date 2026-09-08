import Foundation
import Synchronization
import Testing

@testable import Heeler

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
        #expect(await updates.next() == .status(.connecting))
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

    @Test func reconnectDropsProtocolDependentSubscriptionUntilFreshSnapshot() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(subscriptions: initial, connect: { try await connector.connect() }, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated + [.global(.workspaceReordered)])
        #expect(await updates.next() == .status(.connected))
        #expect(await first.capturedSubscriptions.last == updated + [.global(.workspaceReordered)])
        await session.suspend()
        #expect(await updates.next() == .status(.suspended))
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await replacement.capturedSubscriptions == [initial])
        await session.end()
    }

    @Test func successfulConnectPingPublishesRoundTripLatency() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()
        var latencyUpdates = session.latencyUpdates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let latency = await latencyUpdates.next()
        #expect(latency != nil)
        if let latency {
            #expect(latency >= .zero)
        }

        await session.end()
    }

    @Test func terminalStartsBeforeEventSubscriptionIsReady() async throws {
        let first = ScriptedTransport(snapshot: .fixture())
        let replacement = ScriptedTransport(snapshot: .fixture())
        let firstSnapshotGate = ScriptedTransportCallGate()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await first.gateNextSnapshot(using: firstSnapshotGate)
        await replacement.gateNextSubscription(using: subscriptionGate)
        await replacement.gateNextAttach(using: attachGate)
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        let (projection, generationBarrier) = await MainActor.run {
            let barrier = ProjectionGenerationBarrier()
            let projection = HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) { [barrier] in
                barrier.record()
            }
            barrier.projection = projection
            return (projection, barrier)
        }
        await MainActor.run { projection.start(isActive: true) }
        await firstSnapshotGate.waitForEntry()
        let snapshotsBeforeRecovery = await first.snapshotFetchCount
        await firstSnapshotGate.open()
        await projection.suspend()

        let terminal = Task { @MainActor in
            try await projection.terminalRunner()(
                Self.attachRequest,
                TerminalSessionHandler { attached in
                    await attached.end()
                })
        }
        await projection.resume()
        await subscriptionGate.waitForEntry()
        await attachGate.waitForEntry()
        await generationBarrier.wait(for: 1)

        #expect(await replacement.attachRequests == [Self.attachRequest])
        #expect(await replacement.snapshotFetchCount == 0)
        #expect(await first.snapshotFetchCount == snapshotsBeforeRecovery)
        #expect(await MainActor.run { projection.transportGeneration == 1 })
        await attachGate.open()
        try await terminal.value

        await subscriptionGate.open()
        await MainActor.run { projection.end() }
    }

    @Test func terminalStartsWhileProjectionSnapshotIsStillGated() async throws {
        let transport = ScriptedTransport(snapshot: .fixture())
        let snapshotGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await transport.gateNextAttach(using: attachGate)
        let session = makeSession(transport: transport)
        let projection = await MainActor.run {
            HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) {}
        }
        await MainActor.run { projection.start(isActive: true) }

        await snapshotGate.waitForEntry()
        let terminal = Task { @MainActor in
            try await projection.terminalRunner()(
                Self.attachRequest,
                TerminalSessionHandler { attached in
                    await attached.end()
                })
        }
        await attachGate.waitForEntry()

        #expect(await transport.attachRequests == [Self.attachRequest])
        #expect(await snapshotGate.entryCount == 1)
        await attachGate.open()
        try await terminal.value

        await snapshotGate.open()
        await MainActor.run { projection.end() }
    }

    @Test func terminalWaitsForThePingProvenTransportInstalledAfterItsRequest() async throws {
        let transport = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachSessionGate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: pingGate)
        await transport.gateNextSubscription(using: subscriptionGate)
        await transport.gateNextAttachSession(using: attachSessionGate)
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })
        let projection = await MainActor.run {
            HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) {}
        }
        let terminal = await MainActor.run {
            AttachTerminalStore(
                target: "w1:p1",
                takeover: true,
                transportGeneration: 0,
                runTerminal: projection.terminalRunner())
        }
        await MainActor.run { terminal.viewDidResize(cols: 80, rows: 24) }
        _ = await registrationIterator.next()
        #expect(await transport.attachRequests.isEmpty)
        #expect(await MainActor.run { terminal.status == .connecting })

        await session.resume()
        await pingGate.waitForEntry()
        #expect(await transport.attachRequests.isEmpty)
        await pingGate.open()
        await subscriptionGate.waitForEntry()
        await attachSessionGate.waitForEntry()

        #expect(await transport.attachRequests == [Self.attachRequest])
        #expect(await MainActor.run { terminal.status == .connecting })
        await attachSessionGate.open()
        #expect(await transport.emitAttachOutput(Data("ready".utf8)))
        await terminal.stop()
        #expect(await MainActor.run { terminal.status == .stopped })

        await subscriptionGate.open()
        await MainActor.run { projection.end() }
        registrationContinuation.finish()
    }

    @Test func cancellationRemovesAReadinessWaiterAndReleasesTheTerminalPermit() async throws {
        let transport = ScriptedTransport()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: subscriptionGate)
        await transport.gateNextAttach(using: attachGate)
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })
        let cancelled = Task {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a cancelled readiness waiter reached its operation")
            }
        }

        _ = await registrationIterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await session.resume()
        await subscriptionGate.waitForEntry()
        let replacement = Task {
            try await session.withTerminalTransport { transport, generation in
                let attached = try await transport.attachTerminal(Self.attachRequest)
                await attached.end()
                return generation
            }
        }
        await attachGate.waitForEntry()
        await attachGate.open()
        #expect(try await replacement.value == 0)
        #expect(await transport.attachRequests == [Self.attachRequest])

        await subscriptionGate.open()
        await session.end()
        registrationContinuation.finish()
    }

    @Test func aRequestAfterConnectionFailureReceivesTheRealFailure() async throws {
        let transport = ScriptedTransport()
        let failure = TransportError.socketNotFound(path: "/remote/herdr.sock")
        await transport.failPing(atCall: 1, with: failure)
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(failure)))

        do {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a failed session handed out a terminal Transport")
            }
        } catch let error as TransportError {
            #expect(error == failure)
        } catch {
            Issue.record("expected \(failure), got \(error)")
        }

        await session.end()
    }

    @Test func aNewActivationInvalidatesTheOldReadinessWaiter() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let firstPingGate = ScriptedTransportCallGate()
        let secondSubscriptionGate = ScriptedTransportCallGate()
        let secondAttachGate = ScriptedTransportCallGate()
        await first.gateNextPing(using: firstPingGate)
        await second.gateNextSubscription(using: secondSubscriptionGate)
        await second.gateNextAttach(using: secondAttachGate)
        let connector = SequencedTransportConnector([first, second])
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })

        await session.resume()
        await firstPingGate.waitForEntry()
        let stale = Task {
            try await session.withTerminalTransport { transport, _ in
                _ = try await transport.attachTerminal(Self.attachRequest)
                Issue.record("an older activation handed out its Transport")
            }
        }
        _ = await registrationIterator.next()

        await session.retry()
        await #expect(throws: TransportError.cancelled) {
            try await stale.value
        }
        await secondSubscriptionGate.waitForEntry()

        let current = Task {
            try await session.withTerminalTransport { transport, generation in
                let attached = try await transport.attachTerminal(Self.attachRequest)
                await attached.end()
                return generation
            }
        }
        await secondAttachGate.waitForEntry()
        await secondAttachGate.open()
        #expect(try await current.value == 0)
        #expect(await first.attachRequests.isEmpty)
        #expect(await second.attachRequests == [Self.attachRequest])

        await firstPingGate.open()
        await secondSubscriptionGate.open()
        await session.end()
        registrationContinuation.finish()
    }

    @Test func unchangedSetIsANoOp() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await session.updateSubscriptions(initial)

        #expect(await transport.capturedSubscriptions == [initial])
        await session.end()
    }

    private static let attachRequest = TerminalAttachRequest(
        target: "w1:p1", takeover: true, cols: 80, rows: 24)

    @Test func updateWhileSuspendedTakesEffectOnResume() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.updateSubscriptions(updated)
        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [updated])
        await session.end()
    }

    /// A pane can exit between the snapshot that produced a subscription set
    /// and the subscribe that carries it. herdr rejects the whole request for
    /// that one entry, which used to fail the connection outright.
    @Test func aPaneThatExitedDuringSubscribeRetriesWithoutSurfacingAFailure() async throws {
        let transport = ScriptedTransport()
        await transport.setMissingPanes(["w1:p1"])
        let session = EventsSession(
            subscriptions: updated,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        // Straight to `.connected` after the activation's `.connecting`: the
        // missing-pane retry is immediate and the user never sees a reconnect
        // for what is an ordinary race.
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [updated, initial])
        #expect(await !transport.isClosed, "the SSH connection must survive the rejection")

        await session.end()
    }

    /// The pane set is snapshot-derived, so it cannot outlive the connection
    /// it was taken on: a pane that dies while the Host is offline would
    /// otherwise wedge every reconnect forever.
    @Test func aDroppedConnectionDiscardsThePaneSubscriptions() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated)
        #expect(await updates.next() == .status(.connected))

        // The pane exits while the events channel is down.
        await transport.setMissingPanes(["w1:p1"])
        await transport.failEventStream(.channelFailed(detail: "remote closed"))

        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("a dropped stream should reconnect")
            return
        }
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated, initial])

        await session.end()
    }

    /// The same guarantee for the explicit Reconnect button, which winds the
    /// session down rather than reconnecting in place.
    @Test func retryAfterADeadPaneDiscardsThePaneSubscriptions() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated)
        #expect(await updates.next() == .status(.connected))

        await transport.setMissingPanes(["w1:p1"])
        await session.retry()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated, initial])

        await session.end()
    }

    @Test func retryAnnouncesConnectingBeforeTeardownClosesTheTransport() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let closeGate = ScriptedTransportCallGate()
        await first.gateNextClose(using: closeGate)
        let retrying = Task { await session.retry() }
        try await waitUntil("teardown should reach the installed transport") {
            await closeGate.entryCount == 1
        }
        #expect(await updates.next() == .status(.connecting))
        #expect(await !first.isClosed)
        await closeGate.open()
        await retrying.value
        #expect(await updates.next() == .status(.connected))
        #expect(await first.isClosed)
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

        #expect(await updates.next() == .status(.connecting))
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

        #expect(await updates.next() == .status(.connecting))
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
        #expect(await updates.next() == .status(.connecting))
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
        #expect(await updates.next() == .status(.connecting))
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

    /// The opposite race, and the routine one on iOS: a quick
    /// background→foreground bounce lands `resume()` while `suspend()`'s
    /// teardown is still mid-flight. The session serializes lifecycle
    /// transitions itself, so the teardown completes fully before the new
    /// activation dials and the app layer never has to serialize its own
    /// calls. The interleaving is deterministic because the transport's
    /// `close()` is gated by the test, pinning `suspend()` inside its
    /// teardown when `resume()` is issued.
    @Test func resumeRacingIntoSuspendTeardownWaitsForTeardownToFinish() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let closeGate = ScriptedTransportCallGate()
        await first.gateNextClose(using: closeGate)
        let connector = SequencedTransportConnector([first, second])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let suspending = Task { await session.suspend() }
        try await waitUntil("the teardown should park inside the transport close") {
            await closeGate.entryCount == 1
        }
        let resuming = Task { await session.resume() }
        // The bounce must not jump the queue: no new dial while the teardown
        // is parked at the gated close.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await connector.connectCount == 1)

        await closeGate.open()
        await suspending.value
        await resuming.value

        #expect(await updates.next() == .status(.suspended))
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)
        #expect(await first.isClosed)
        #expect(await !second.isClosed)

        // The run loop reference survived the bounce: end() still tears the
        // second transport down — nothing leaks.
        await session.end()
        #expect(await updates.next() == .status(.ended))
        #expect(await updates.next() == nil)
        #expect(await second.isClosed)
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

@MainActor
private final class ProjectionGenerationBarrier {
    weak var projection: HostConsoleProjection?
    private var waiters: [
        (generation: UInt64, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func record() {
        guard let generation = projection?.transportGeneration else { return }
        let reached = waiters.filter { generation >= $0.generation }
        waiters.removeAll { generation >= $0.generation }
        for waiter in reached {
            waiter.continuation.resume()
        }
    }

    func wait(for generation: UInt64) async {
        guard let current = projection?.transportGeneration, current < generation else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((generation, continuation))
        }
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
