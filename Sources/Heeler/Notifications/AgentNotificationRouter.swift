import Foundation
import Observation

/// Owns the Console's navigation path and lands Agent Notification taps on
/// the right Agent detail (#74, #179). A tap can arrive before the tapped
/// pane is known — a killed-state launch routes only once the Host's first sync
/// delivers the pane — so an unresolved target waits as pending until the
/// pane appears, the user navigates somewhere themselves, or a grace window
/// elapses. Falling back always means the Console, quietly: never an alert.
@MainActor
@Observable
final class AgentNotificationRouter {
    /// The Console's NavigationStack path; ConsoleView binds to it, so user
    /// navigation and deep links share one source of truth.
    var path: [ConsoleAgent.ID] = []

    /// A tap still waiting for its pane to appear in the Console.
    private(set) var pendingTarget: AgentNotificationTarget?

    @ObservationIgnored private var knownAgentIDs: Set<ConsoleAgent.ID> = []
    @ObservationIgnored private var pendingExpiry: Task<Void, Never>?
    @ObservationIgnored private let pendingGrace: Duration

    /// `pendingGrace` bounds how long a tap may wait for its pane: long
    /// enough for a cold launch to connect and sync its Hosts, short enough
    /// that a stale pane cannot yank the user around minutes later.
    init(pendingGrace: Duration = .seconds(15)) {
        self.pendingGrace = pendingGrace
    }

    /// Routes a tapped notification. A known pane opens its detail at once;
    /// an unknown one parks the user on the Console and follows up if the
    /// pane arrives within the grace window (killed-state launches); no
    /// target at all (unknown key id, undecryptable envelope) is the Console
    /// itself, with no alarming copy.
    func open(_ target: AgentNotificationTarget?) {
        cancelPending()
        guard let target else {
            path = []
            return
        }
        if knownAgentIDs.contains(target.agentID) {
            path = [target.agentID]
        } else {
            path = []
            pendingTarget = target
            armPendingExpiry()
        }
    }

    /// The Console feed: resolves a pending tap the moment its pane appears.
    /// If the user has navigated somewhere else in the meantime, the deep
    /// link is dropped instead of yanking them away.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        knownAgentIDs = Set(agents.map(\.id))
        guard let pending = pendingTarget, knownAgentIDs.contains(pending.agentID)
        else { return }
        cancelPending()
        if path.isEmpty {
            path = [pending.agentID]
        }
    }

    private func armPendingExpiry() {
        let grace = pendingGrace
        pendingExpiry = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            // Stale pane: it never showed up. Stay on the Console quietly.
            self?.pendingTarget = nil
            self?.pendingExpiry = nil
        }
    }

    private func cancelPending() {
        pendingExpiry?.cancel()
        pendingExpiry = nil
        pendingTarget = nil
    }
}
