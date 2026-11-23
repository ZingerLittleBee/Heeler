import Foundation
import Observation

/// Owns the Console's navigation path and lands Agent Notification taps on
/// the right Agent detail (#74, #179). A tap can arrive before the tapped
/// pane is known. While its Host has yet to report, as after a launch or a
/// return from the background, the tap lands on the detail at once, which
/// waits for the Host as a restored one does (#830). When a Host that has
/// reported does not list the pane, the target waits as pending until the
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

    /// Counts taps that land on the Agent the path already shows. The path
    /// does not change for them, so the Console watches this instead to
    /// bring that Agent forward from another tab or from under a sheet.
    private(set) var repeatLandings = 0

    /// Whether the Console's latest Agent list has this row, as last fed
    /// through `agentsDidChange`.
    func isKnownAgent(_ id: ConsoleAgent.ID) -> Bool {
        knownAgentIDs.contains(id)
    }

    /// Whether an Agent the Console does not list is one its Host has yet to
    /// report, rather than one a reporting Host no longer holds. The window
    /// sets it before it registers for links; see
    /// `MissingAgentPresentation.awaitsHost`.
    @ObservationIgnored var awaitsHostReport: @MainActor (ConsoleAgent.ID) -> Bool = { _ in false }

    @ObservationIgnored private var knownAgentIDs: Set<ConsoleAgent.ID> = []
    @ObservationIgnored private var pendingExpiry: Task<Void, Never>?
    @ObservationIgnored private let pendingGrace: Duration

    /// `pendingGrace` bounds how long a tap may wait for a pane its Host has
    /// reported without: long enough for an event still on its way, short
    /// enough that a stale pane cannot yank the user around minutes later.
    init(pendingGrace: Duration = .seconds(15)) {
        self.pendingGrace = pendingGrace
    }

    /// Routes a tapped notification. A known pane opens its detail at once,
    /// and so does one whose Host has yet to report: the detail says where
    /// the connection stands and takes the Agent up when the Host does,
    /// however long that takes. A pane a reporting Host does not list parks
    /// the user on the Console and follows up if the pane arrives within the
    /// grace window; no target at all (unknown key id, undecryptable
    /// envelope) is the Console itself, with no alarming copy.
    func open(_ target: AgentNotificationTarget?) {
        cancelPending()
        guard let target else {
            path = []
            return
        }
        if knownAgentIDs.contains(target.agentID) || awaitsHostReport(target.agentID) {
            if path == [target.agentID] {
                repeatLandings += 1
            } else {
                path = [target.agentID]
            }
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
