import Foundation
import Testing

@testable import HerdrMobile

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
