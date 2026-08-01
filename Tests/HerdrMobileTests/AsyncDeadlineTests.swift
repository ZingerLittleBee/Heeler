import Foundation
import Testing

@testable import HerdrMobile

@Suite("Async deadline")
struct AsyncDeadlineTests {
    @Test func timeoutReturnsWithoutWaitingForTheOperationToCooperate() async throws {
        let gate = NonCooperativeDeadlineGate()
        let outcome = DeadlineOutcomeProbe()
        let timeoutCleanup = DeadlineCallbackProbe()
        let task = Task {
            do {
                try await AsyncDeadline.run(
                    for: .milliseconds(20),
                    onTimeout: { await timeoutCleanup.recordCall() }
                ) {
                    await gate.waitUntilOpen()
                }
                await outcome.record(.completed)
            } catch AsyncDeadlineError.timedOut {
                await outcome.record(.timedOut)
            } catch {
                await outcome.record(.unexpectedFailure)
            }
        }
        try await waitUntil("the operation should enter before the deadline") {
            await gate.entryCount == 1
        }

        try await Task.sleep(for: .milliseconds(100))
        #expect(
            await outcome.value == .timedOut,
            "the deadline must not wait for an operation that ignores cancellation")
        try await waitUntil("timeout cleanup should run independently") {
            await timeoutCleanup.callCount == 1
        }

        await gate.open()
        await task.value
    }

    @Test func cancellationReturnsWithoutWaitingForTheOperationToCooperate() async throws {
        let gate = NonCooperativeDeadlineGate()
        let outcome = DeadlineOutcomeProbe()
        let cancellationCleanup = DeadlineCallbackProbe()
        let task = Task {
            do {
                try await AsyncDeadline.run(
                    for: .seconds(10),
                    onCancel: { await cancellationCleanup.recordCall() }
                ) {
                    await gate.waitUntilOpen()
                }
                await outcome.record(.completed)
            } catch is CancellationError {
                await outcome.record(.cancelled)
            } catch {
                await outcome.record(.unexpectedFailure)
            }
        }
        try await waitUntil("the operation should enter before cancellation") {
            await gate.entryCount == 1
        }

        task.cancel()
        try await waitUntil("cancellation should return immediately") {
            await outcome.value == .cancelled
        }
        try await waitUntil("cancellation cleanup should run independently") {
            await cancellationCleanup.callCount == 1
        }

        await gate.open()
        await task.value
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

private enum DeadlineOutcome: Sendable {
    case completed
    case timedOut
    case cancelled
    case unexpectedFailure
}

private actor DeadlineOutcomeProbe {
    private(set) var value: DeadlineOutcome?

    func record(_ value: DeadlineOutcome) {
        self.value = value
    }
}

private actor DeadlineCallbackProbe {
    private(set) var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

private actor NonCooperativeDeadlineGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func waitUntilOpen() async {
        entryCount += 1
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
