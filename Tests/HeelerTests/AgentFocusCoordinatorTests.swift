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

    @Test func aDetailShowsItsAgentOnlyInFrontOfTheUserWithNoShellOverIt() {
        #expect(state().showsAgent)
        // A Host still connecting takes nothing away from what is on screen.
        #expect(state(status: .working, ready: false, generation: nil).showsAgent)
        #expect(!state(active: false).showsAgent)
        #expect(!state(onStage: false).showsAgent)
        #expect(!state(shell: true).showsAgent)
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

    @Test func spuriousDisappearWhileVisibleKeepsMountAliveAndContinuesObservingFocusState() async throws {
        let model = FocusMountObservationModel()
        let mount = AgentDetailMount()
        let activity = AppActivityCoordinator()
        var updates = 0
        var exits = 0

        mount.appear(
            activity: activity,
            state: {
                AgentFocusCoordinator.ViewingState(
                    agentID: id,
                    terminalID: "terminal-A",
                    transportGeneration: 1,
                    status: model.status,
                    isHostReady: model.isHostReady,
                    isSceneActive: true,
                    isOnStage: mount.hasAppeared && model.isVisible,
                    showsShellTerminal: false)
            },
            onUpdate: { updates += 1 })
        #expect(mount.hasAppeared)

        // Simulate iPhone's unpaired spurious onDisappear while the router still shows the detail.
        mount.scheduleExit(isVisible: { model.isVisible }) { exits += 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(mount.hasAppeared)
        #expect(exits == 0)

        // Even with SwiftUI's .onChange frozen after the unpaired disappear,
        // observable store changes (such as a Host snapshot arriving with Done) still drive focus.
        model.status = .done
        model.isHostReady = true
        try await waitUntil { updates >= 1 }
        #expect(mount.hasAppeared)
        #expect(exits == 0)

        // Real Back navigation updates router visibility without a second SwiftUI onDisappear.
        model.isVisible = false
        try await waitUntil { !mount.hasAppeared && exits == 1 }
    }

    @Test func reappearingAfterSpuriousDisappearCancelsPendingExit() async throws {
        let model = FocusMountObservationModel()
        let mount = AgentDetailMount()
        let activity = AppActivityCoordinator()
        var exits = 0

        let state = {
            AgentFocusCoordinator.ViewingState(
                agentID: id,
                terminalID: "terminal-A",
                transportGeneration: 1,
                status: .done,
                isHostReady: true,
                isSceneActive: true,
                isOnStage: mount.hasAppeared && model.isVisible,
                showsShellTerminal: false)
        }
        mount.appear(activity: activity, state: state, onUpdate: {})
        mount.scheduleExit(isVisible: { model.isVisible }) { exits += 1 }
        mount.appear(activity: activity, state: state, onUpdate: {})
        model.isVisible = false
        try await Task.sleep(for: .milliseconds(30))
        #expect(mount.hasAppeared)
        #expect(exits == 0)
        mount.scheduleExit(isVisible: { false }) {}
        #expect(!mount.hasAppeared)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), "Focus lifecycle did not settle before the deadline")
    }
}

@MainActor
@Observable
fileprivate final class FocusMountObservationModel {
    var status: AgentStatus?
    var isHostReady = false
    var isVisible = true
}
