import Foundation
import os

/// One viewed Done cycle gets one attempt. Status transitions, re-entry and
/// connection replacement re-arm it; snapshot metadata (notably the stale
/// stateChangeSeq retained by status deltas) is never a completion identifier.
@MainActor
final class AgentFocusCoordinator {
    struct ViewingState: Equatable {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let transportGeneration: UInt64?
        let status: AgentStatus?
        let isHostReady: Bool
        let isSceneActive: Bool
        let isOnStage: Bool
        let showsShellTerminal: Bool

        fileprivate var target: Target? {
            guard status == .done, isHostReady, isSceneActive, isOnStage,
                !showsShellTerminal, let transportGeneration
            else { return nil }
            return Target(
                agentID: agentID, terminalID: terminalID,
                transportGeneration: transportGeneration)
        }
    }

    fileprivate struct Target: Equatable {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let transportGeneration: UInt64
    }

    private static let log = Logger(subsystem: "dev.bybee.heeler", category: "AgentFocus")
    private var target: Target?
    private var generation: UInt64 = 0
    private var attempted = false
    private var task: Task<Void, Never>?
    private var focus: (@MainActor (ConsoleAgent.ID) async throws -> Void)?
    private let onFailure: @MainActor (any Error) -> Void

    var isInFlight: Bool { task != nil }

    init(onFailure: @escaping @MainActor (any Error) -> Void = { error in
        AgentFocusCoordinator.log.error("agent.focus failed: \(String(describing: error), privacy: .private)")
    }) {
        self.onFailure = onFailure
    }

    func update(
        _ state: ViewingState,
        focus: @escaping @MainActor (ConsoleAgent.ID) async throws -> Void
    ) {
        self.focus = focus
        if target != state.target {
            generation &+= 1
            target = state.target
            attempted = false
            task?.cancel()
        }
        startIfNeeded()
    }

    func leave() {
        generation &+= 1
        target = nil
        attempted = false
        focus = nil
        task?.cancel()
    }

    private func startIfNeeded() {
        guard task == nil, !attempted, let target, let focus else { return }
        attempted = true
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await focus(target.agentID)
            } catch {
                if self.generation == generation, !Task.isCancelled,
                    !(error is CancellationError), (error as? TransportError) != .cancelled
                {
                    self.onFailure(error)
                }
            }
            // Keep the cancelled task's slot until it actually returns. Even
            // a cancellation-insensitive transport cannot overlap a new call.
            self.task = nil
            if self.generation != generation {
                self.startIfNeeded()
            }
        }
    }
}
