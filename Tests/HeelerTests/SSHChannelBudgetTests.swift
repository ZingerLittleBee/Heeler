import Foundation
import Testing

@testable import Heeler

@Suite("SSH channel budget")
struct SSHChannelBudgetTests {
    @Test func boundsConcurrentChannelLifetimes() async throws {
        let budget = SSHChannelBudget(capacity: 2)
        let gate = ChannelBudgetGate()
        let probe = ChannelBudgetProbe()
        let tasks = (0..<5).map { id in
            Task {
                try await budget.withChannel {
                    await probe.enter(id)
                    await gate.waitUntilOpen()
                    await probe.leave()
                }
            }
        }

        try await waitUntil("two channel operations should enter") {
            await probe.activeCount == 2
        }
        #expect(await probe.maximumActiveCount == 2)

        await gate.open()
        for task in tasks {
            try await task.value
        }
        #expect(await probe.maximumActiveCount == 2)
        #expect(await probe.enteredIDs.count == 5)
    }

    @Test func queuedCancellationDoesNotConsumeCapacity() async throws {
        let budget = SSHChannelBudget(capacity: 1)
        let holderGate = ChannelBudgetGate()
        let holderEntered = ChannelBudgetGate()
        let holder = Task {
            try await budget.withChannel {
                await holderEntered.open()
                await holderGate.waitUntilOpen()
            }
        }
        await holderEntered.waitUntilOpen()

        let cancelledOperationRan = ChannelBudgetProbe()
        let cancelled = Task {
            try await budget.withChannel {
                await cancelledOperationRan.enter(1)
            }
        }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        let successorEntered = ChannelBudgetGate()
        let successor = Task {
            try await budget.withChannel {
                await successorEntered.open()
            }
        }
        await holderGate.open()
        try await holder.value
        await successorEntered.waitUntilOpen()
        try await successor.value
        #expect(await cancelledOperationRan.enteredIDs.isEmpty)
    }

    @Test func thrownOperationReleasesCapacityExactlyOnce() async throws {
        let budget = SSHChannelBudget(capacity: 1)

        await #expect(throws: ChannelBudgetTestError.expected) {
            try await budget.withChannel {
                throw ChannelBudgetTestError.expected
            }
        }

        let entries = ChannelBudgetProbe()
        try await budget.withChannel {
            await entries.enter(1)
            await entries.leave()
        }
        #expect(await entries.enteredIDs == [1])
        #expect(await entries.maximumActiveCount == 1)
    }

    @Test func alreadyCancelledRequestNeverRunsItsOperation() async throws {
        let budget = SSHChannelBudget(capacity: 1)
        let entries = ChannelBudgetProbe()
        let start = ChannelBudgetGate()
        let task = Task {
            await start.waitUntilOpen()
            try await budget.withChannel {
                await entries.enter(1)
            }
        }
        task.cancel()
        await start.open()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await entries.enteredIDs.isEmpty)

        try await budget.withChannel {}
    }

    private func waitUntil(
        _ message: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(Comment(rawValue: message))
    }
}

@Suite("SSH channel admission")
struct SSHChannelAdmissionTests {
    @Test func productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling() async throws {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.ordinaryForwarding == 8)
        #expect(limits.events == 1)
        #expect(limits.ordinarySession == 8)
        #expect(limits.attach == 1)
        #expect(limits.connection == 18)
        #expect(limits.ordinarySession + limits.attach < 10)

        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<limits.ordinarySession {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let attach = try await admission.acquire(.attach)
        #expect(await admission.snapshot().ordinarySession == 8)
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().connection == 9)
        await attach.release()
        for session in sessions {
            await session.release()
        }
    }

    @Test func sessionSaturationDoesNotBlockForwardingAdmission() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 4))
        let session = try await admission.acquire(.ordinarySession)
        let forwarding = try await admission.acquire(.ordinaryForwarding)

        #expect(await admission.snapshot() == .init(
            ordinaryForwarding: 1,
            events: 0,
            ordinarySession: 1,
            attach: 0,
            connection: 2))
        await forwarding.release()
        await session.release()
    }

    @Test func connectionCeilingBoundsForwardingAndSessionTogether() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 2,
                events: 1,
                ordinarySession: 2,
                attach: 1,
                connection: 2))
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        let session = try await admission.acquire(.ordinarySession)
        let entered = ChannelBudgetGate()
        let waiting = Task {
            let events = try await admission.acquire(.events)
            await entered.open()
            await events.release()
        }

        await Task.yield()
        #expect(await admission.snapshot().connection == 2)
        await forwarding.release()
        await entered.waitUntilOpen()
        try await waiting.value
        await session.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func cancelledWaiterDoesNotLeakConnectionCapacity() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 1))
        let session = try await admission.acquire(.ordinarySession)
        let waiting = Task { try await admission.acquire(.ordinaryForwarding) }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiting.value
        }

        await session.release()
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        #expect(await admission.snapshot().connection == 1)
        await forwarding.release()
        #expect(await admission.snapshot().connection == 0)
    }
}

private enum ChannelBudgetTestError: Error {
    case expected
}

private actor ChannelBudgetGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }
}

private actor ChannelBudgetProbe {
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var enteredIDs: [Int] = []

    func enter(_ id: Int) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        enteredIDs.append(id)
    }

    func leave() {
        activeCount -= 1
    }
}
