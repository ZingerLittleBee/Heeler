import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Viewed Agent focus")
struct AgentFocusCoordinatorTests {
    private let id = ConsoleAgent.ID(hostID: UUID(), paneID: "opaque:Pane/A")

    private func state(
        status: AgentStatus? = .done, active: Bool = true,
        onStage: Bool = true, shell: Bool = false, ready: Bool = true,
        generation: UInt64? = 1, agentID: ConsoleAgent.ID? = nil,
        terminalID: String = "terminal-A"
    ) -> AgentFocusCoordinator.ViewingState {
        .init(
            agentID: agentID ?? id, terminalID: terminalID,
            transportGeneration: generation, status: status,
            isHostReady: ready, isSceneActive: active, isOnStage: onStage,
            showsShellTerminal: shell)
    }

    @Test func initialDoneCoalescesUntilAnotherCompletion() async throws {
        let coordinator = AgentFocusCoordinator()
        var calls: [ConsoleAgent.ID] = []
        let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { calls.append($0) }
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == [id])
        for _ in 0..<10 { coordinator.update(state(), focus: focus) }
        #expect(!coordinator.isInFlight)
        #expect(calls == [id])

        // A status delta can retain the preceding snapshot's stateChangeSeq.
        // Only the observed status boundary re-arms this coordinator.
        coordinator.update(state(status: .working), focus: focus)
        #expect(!coordinator.isInFlight)
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == [id, id])
    }

    @Test func inactiveInvisibleShellUnavailableAndNonDoneNeverSend() {
        let coordinator = AgentFocusCoordinator()
        let ineligible = [
            state(active: false), state(onStage: false), state(shell: true),
            state(ready: false), state(generation: nil), state(status: nil),
            state(status: .working), state(status: .idle), state(status: .blocked),
        ]
        for state in ineligible {
            coordinator.update(state) { _ in Issue.record("An ineligible detail sent focus") }
            #expect(!coordinator.isInFlight)
        }
    }

    @Test func foregroundWorkingToDoneAndReentryEachAllowOneAttempt() async throws {
        let coordinator = AgentFocusCoordinator()
        var calls = 0
        let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { _ in calls += 1 }
        coordinator.update(state(status: .working), focus: focus)
        #expect(!coordinator.isInFlight)
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        for away in [state(active: false), state(onStage: false), state(shell: true)] {
            coordinator.update(away, focus: focus)
            coordinator.update(state(), focus: focus)
            try await waitUntil { !coordinator.isInFlight }
        }
        #expect(calls == 4)
        coordinator.leave()
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == 5)
    }

    @Test func failureReportsOnceAndRetriesOnlyAfterReentry() async throws {
        var failures = 0
        var calls = 0
        let coordinator = AgentFocusCoordinator { _ in failures += 1 }
        let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { _ in
            calls += 1
            throw TransportError.timedOut
        }
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        for _ in 0..<10 { coordinator.update(state(), focus: focus) }
        #expect(!coordinator.isInFlight)
        #expect(calls == 1)
        #expect(failures == 1)
        coordinator.update(state(onStage: false), focus: focus)
        coordinator.update(state(), focus: focus)
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == 2)
        #expect(failures == 2)
    }

    @Test func cancelledCompletionCannotOverlapOrPoisonReentry() async throws {
        for fails in [false, true] {
            let gate = ScriptedTransportCallGate()
            var calls = 0
            var failures = 0
            var observedCancellation = false
            let coordinator = AgentFocusCoordinator { _ in failures += 1 }
            let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { _ in
                calls += 1
                if calls == 1 {
                    // Intentionally ignores cancellation until the old RPC returns.
                    await gate.waitUntilOpen()
                    observedCancellation = Task.isCancelled
                    if fails { throw TransportError.timedOut }
                }
            }
            coordinator.update(state(), focus: focus)
            try await waitUntil { calls == 1 }
            coordinator.leave()
            coordinator.update(state(), focus: focus)
            #expect(calls == 1)
            #expect(coordinator.isInFlight)
            await gate.open()
            try await waitUntil { calls == 2 && !coordinator.isInFlight }
            #expect(observedCancellation)
            #expect(failures == 0)
            coordinator.update(state(), focus: focus)
            #expect(!coordinator.isInFlight)
        }
    }

    @Test func losingEligibilityCancelsAnAwaitingCallWithoutRetrying() async throws {
        for away in [
            state(active: false), state(onStage: false), state(shell: true),
            state(ready: false), state(status: .working), state(status: nil),
        ] {
            let gate = ScriptedTransportCallGate()
            let coordinator = AgentFocusCoordinator()
            var calls = 0
            var wasCancelled = false
            let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { _ in
                calls += 1
                await gate.waitUntilOpen()
                wasCancelled = Task.isCancelled
            }
            coordinator.update(state(), focus: focus)
            try await waitUntil { calls == 1 }
            for _ in 0..<10 { coordinator.update(state(), focus: focus) }
            #expect(calls == 1)
            coordinator.update(away, focus: focus)
            await gate.open()
            try await waitUntil { !coordinator.isInFlight }
            #expect(wasCancelled)
            #expect(calls == 1)
        }
    }

    @Test func lossOfEligibilityBeforeDispatchCancelsTheQueuedAttempt() async throws {
        let coordinator = AgentFocusCoordinator()
        var calls = 0
        coordinator.update(state()) { _ in calls += 1 }
        coordinator.leave()
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == 0)
    }

    @Test func reconnectAndIdentityReplacementDiscardStaleCompletion() async throws {
        let other = ConsoleAgent.ID(hostID: UUID(), paneID: id.paneID)
        for replacement in [
            state(generation: 2), state(agentID: other), state(terminalID: "terminal-B"),
            state(agentID: .init(hostID: id.hostID, paneID: "new opaque target")),
        ] {
            let coordinator = AgentFocusCoordinator()
            let gate = ScriptedTransportCallGate()
            var calls: [ConsoleAgent.ID] = []
            let focus: @MainActor (ConsoleAgent.ID) async throws -> Void = { id in
                calls.append(id)
                if calls.count == 1 { await gate.waitUntilOpen() }
            }
            coordinator.update(state(), focus: focus)
            try await waitUntil { calls.count == 1 }
            coordinator.update(replacement, focus: focus)
            #expect(calls.count == 1)
            await gate.open()
            try await waitUntil { calls.count == 2 && !coordinator.isInFlight }
            #expect(calls == [id, replacement.agentID])
            coordinator.update(replacement, focus: focus)
            #expect(!coordinator.isInFlight)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), "Focus lifecycle did not settle before the deadline")
    }
}
