import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Shared terminal retention budget")
struct TerminalRetentionBudgetTests {
    @Test func threeTerminalsShareTheBudgetAndFourthAwaitsTheLeastRecentlyUsedIdleOwner() async throws {
        let budget = TerminalRetentionBudget()
        let host = UUID()
        let owner = UUID()
        let first = TerminalRetentionBudget.Key(hostID: host, terminalID: "agent-one")
        let second = TerminalRetentionBudget.Key(hostID: host, terminalID: "shell-two")
        let third = TerminalRetentionBudget.Key(hostID: host, terminalID: "agent-three")
        let fourth = TerminalRetentionBudget.Key(hostID: host, terminalID: "shell-four")
        let gate = ScriptedTransportCallGate()
        var evicted: [String] = []
        try await budget.admit(key: first, ownerID: owner, isVisible: { false }) {
            evicted.append("first")
        }
        try await budget.admit(key: second, ownerID: owner, isVisible: { false }) {
            await gate.waitUntilOpen()
            evicted.append("second")
        }
        try await budget.admit(key: third, ownerID: owner, isVisible: { true }) {
            evicted.append("third")
        }
        // Revisiting the first terminal makes the second the oldest idle one.
        budget.touch(key: first, ownerID: owner)
        let next = Task {
            try await budget.admit(key: fourth, ownerID: owner, isVisible: { true }) {
                evicted.append("fourth")
            }
        }
        await gate.waitForEntry()
        #expect(evicted.isEmpty)
        await gate.open()
        try await next.value
        #expect(evicted == ["second"])
    }

    @Test func allVisibleOwnersCannotBeEvictedAndOtherHostsHaveIndependentBudgets() async throws {
        let budget = TerminalRetentionBudget(maximumPerHost: 1)
        let host = UUID()
        let owner = UUID()
        try await budget.admit(key: .init(hostID: host, terminalID: "one"), ownerID: owner,
                               isVisible: { true }, onEvict: { Issue.record("visible owner was evicted") })
        await #expect(throws: TerminalRetentionBudget.Failure.self) {
            try await budget.admit(key: .init(hostID: host, terminalID: "two"), ownerID: owner,
                                   isVisible: { true }, onEvict: {})
        }
        try await budget.admit(key: .init(hostID: UUID(), terminalID: "one"), ownerID: owner,
                               isVisible: { true }, onEvict: {})
    }

    @Test func sameTerminalCannotHaveTwoVisibleOwnersButCanTransferAfterIdleTeardown() async throws {
        let budget = TerminalRetentionBudget()
        let key = TerminalRetentionBudget.Key(hostID: UUID(), terminalID: "one")
        let first = UUID()
        let second = UUID()
        let visibility = TerminalRetentionVisibilityProbe()
        var ended = false
        try await budget.admit(key: key, ownerID: first, isVisible: { visibility.isVisible }) { ended = true }
        await #expect(throws: TerminalRetentionBudget.Failure.self) {
            try await budget.admit(key: key, ownerID: second, isVisible: { true }, onEvict: {})
        }
        #expect(!ended)
        visibility.isVisible = false
        try await budget.admit(key: key, ownerID: second, isVisible: { true }, onEvict: {})
        #expect(ended)
    }

    @Test func cancellingAQueuedAdmissionReturnsDuringEvictionWithoutLettingSuccessorsBypassIt() async throws {
        let budget = TerminalRetentionBudget(maximumPerHost: 1)
        let host = UUID()
        let owner = UUID()
        let gate = ScriptedTransportCallGate()
        var evicted: [String] = []
        try await budget.admit(key: .init(hostID: host, terminalID: "one"), ownerID: owner,
                               isVisible: { false }) {
            await gate.waitUntilOpen()
            evicted.append("one")
        }
        let replacing = Task {
            try await budget.admit(key: .init(hostID: host, terminalID: "two"), ownerID: owner,
                                   isVisible: { false }) { evicted.append("two") }
        }
        await gate.waitForEntry()
        let cancelled = Task {
            try await budget.admit(key: .init(hostID: host, terminalID: "cancelled"), ownerID: owner,
                                   isVisible: { true }, onEvict: {})
        }
        await Task.yield()
        cancelled.cancel()
        var cancellationReturned = false
        let observer = Task {
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            cancellationReturned = true
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !cancellationReturned, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let returnedBeforeTeardown = cancellationReturned
        var successorEntered = false
        let successor = Task {
            try await budget.admit(key: .init(hostID: host, terminalID: "three"), ownerID: owner,
                                   isVisible: { true }, onEvict: {})
            successorEntered = true
        }
        await Task.yield()
        #expect(!successorEntered)
        await gate.open()
        try await replacing.value
        await observer.value
        try await successor.value
        #expect(returnedBeforeTeardown)
        #expect(evicted == ["one", "two"])
    }

}

@MainActor
private final class TerminalRetentionVisibilityProbe {
    var isVisible = true
}
