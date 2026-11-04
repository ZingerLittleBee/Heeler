import Foundation
import Testing

@Suite("Poll budgets", .timeLimit(.minutes(1)))
@MainActor
struct PollBudgetTests {
    @Test("a main-actor stall longer than the timeout leaves time for work queued behind it")
    func stallLeavesTimeForQueuedWork() async throws {
        let work = QueuedWork()
        // The main queue runs blocks in order: the stall, then the work's
        // first step, then this test once its poll sleep is due. The work
        // needs one more main-actor hop to land, so a wall-clock deadline,
        // spent in the stall, would give up just before it does.
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.3) }
        Task {
            try await Task.sleep(for: .milliseconds(5))
            work.landed = true
        }

        var budget = PollBudget(.milliseconds(200), maxGap: .milliseconds(20))
        while !work.landed, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }

        #expect(work.landed)
    }

    @Test("a condition that never holds still runs the budget out")
    func neverHoldingConditionRunsOut() async throws {
        let started = ContinuousClock.now
        var budget = PollBudget(.milliseconds(50))
        var polls = 0
        while budget.hasTimeLeft, polls < 1_000 {
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
            polls += 1
        }

        #expect(!budget.hasTimeLeft)
        #expect(started.duration(to: .now) >= .milliseconds(50))
    }
}

@MainActor
private final class QueuedWork {
    var landed = false
}
