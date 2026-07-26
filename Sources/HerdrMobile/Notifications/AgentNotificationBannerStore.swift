import AudioToolbox
import Foundation
import Observation

/// One in-app Agent Notification banner ready to display (#77): where a tap
/// lands and the exact push-renderer copy, so in-app and APNs wording cannot
/// drift.
struct AgentNotificationBanner: Equatable, Sendable {
    let target: AgentNotificationTarget
    let alert: AgentNotificationAlert
}

/// Announces foreground Blocked/Done Agent transitions from the Console's
/// live Agent list (#77), replacing system push banners while the app is
/// foregrounded (`willPresent` is always `[]`).
///
/// The gates mirror the plugin's pipeline, app-side: a transition must hold
/// `holdDuration` before announcing (herdr's status detection flaps), an
/// unchanged status never repeats, the presented Agent stays silent (spec
/// #68, story 8, decided at fire time like the push path), and a Host whose
/// confirmed notify flags are unknown fails closed — exactly like the
/// plugin's missing-flag semantics.
@MainActor
@Observable
final class AgentNotificationBannerStore {
    private(set) var banner: AgentNotificationBanner?

    /// Last observed status per pane; a banner candidate is a change of it.
    @ObservationIgnored private var statuses: [ConsoleAgent.ID: AgentStatus] = [:]
    /// In-flight anti-flap holds, cancelled when the status moves on.
    @ObservationIgnored private var holds: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private let holdDuration: Duration
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private let presentedAgent: @MainActor () -> ConsoleAgent.ID?
    @ObservationIgnored private let triggers:
        @MainActor (Host.ID) -> NotificationTriggerPreferences?
    @ObservationIgnored private let playSound: @MainActor () -> Void

    /// - Parameters:
    ///   - holdDuration: how long a transition must hold before announcing.
    ///   - dismissDelay: how long a shown banner stays before auto-dismissing.
    ///   - presentedAgent: the Agent currently on screen (the router's
    ///     `path.last`), read at fire time.
    ///   - triggers: the Host's *confirmed* notify flags; nil (unregistered,
    ///     unreachable, still loading) means no banner.
    ///   - playSound: the banner's sound; 1007 is the system SMS-alert tone,
    ///     played through the alert route so the ringer switch is honored.
    init(
        holdDuration: Duration = .seconds(3),
        dismissDelay: Duration = .seconds(5),
        presentedAgent: @escaping @MainActor () -> ConsoleAgent.ID?,
        triggers: @escaping @MainActor (Host.ID) -> NotificationTriggerPreferences?,
        playSound: @escaping @MainActor () -> Void = { AudioServicesPlayAlertSound(1007) }
    ) {
        self.holdDuration = holdDuration
        self.dismissDelay = dismissDelay
        self.presentedAgent = presentedAgent
        self.triggers = triggers
        self.playSound = playSound
    }

    /// The Console feed, same as the router's: diff each pane's status
    /// against the last observed one. First sight is baseline, never a
    /// transition — a killed-state launch must not banner every Agent that
    /// was already Blocked when it synced.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        let current = Dictionary(agents.map { ($0.id, $0) }) { _, last in last }
        for id in statuses.keys where current[id] == nil {
            statuses[id] = nil
            cancelHold(for: id)
        }
        for (id, agent) in current {
            let previous = statuses[id]
            let status = agent.agent.status
            guard status != previous else { continue }
            statuses[id] = status
            cancelHold(for: id)
            guard previous != nil, status == .blocked || status == .done else { continue }
            scheduleHold(for: agent, status: status)
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        banner = nil
    }

    private func scheduleHold(for agent: ConsoleAgent, status: AgentStatus) {
        let hold = holdDuration
        holds[agent.id] = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            self?.holds[agent.id] = nil
            self?.present(agent, status: status)
        }
    }

    private func cancelHold(for id: ConsoleAgent.ID) {
        holds[id]?.cancel()
        holds[id] = nil
    }

    /// The held transition fires: apply the presentation-time gates, then
    /// show the banner with the push renderer's exact copy.
    private func present(_ agent: ConsoleAgent, status: AgentStatus) {
        let target = AgentNotificationTarget(hostID: agent.hostID, paneID: agent.agent.paneID)
        guard
            !AgentNotificationRouting.shouldSuppressBanner(
                target: target, presentedAgent: presentedAgent())
        else { return }
        guard let notify = triggers(agent.hostID),
            status == .done ? notify.done : notify.blocked
        else { return }
        banner = AgentNotificationBanner(
            target: target,
            alert: AgentNotificationRenderer.alert(
                project: agent.workspaceLabel ?? agent.repoName, agentKind: agent.agent.kind,
                hostName: agent.hostName, task: agent.agent.title, status: status))
        playSound()
        armDismissal()
    }

    private func armDismissal() {
        dismissal?.cancel()
        let delay = dismissDelay
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismissal = nil
            self?.banner = nil
        }
    }
}
