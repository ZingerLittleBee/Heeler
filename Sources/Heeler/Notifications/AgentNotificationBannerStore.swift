import AudioToolbox
import Foundation
import Observation

/// One in-app Agent Notification banner ready to display (#77): where a tap
/// lands and the exact push-renderer copy, so in-app and APNs wording cannot
/// drift.
struct AgentNotificationBanner: Equatable, Sendable {
    let target: AgentNotificationTarget
    let alert: AgentNotificationAlert
    var rexRecipient: RexBannerRecipient? = nil
}

/// A restored session can reuse its block address. Bind a local Rex banner
/// to the answering server, the connection and the foreground that reported.
struct RexBannerRecipient: Equatable, Sendable {
    let instanceID: String
    let connectionGeneration: UInt64
    let followID: UUID
    let pid: Int
    let kind: String

    static func isSupported(on host: Host, kernel: String?) -> Bool {
        host.serverKind == .rex && host.rexSocket?.isWindowsPipe != true &&
            (kernel == HerdrCoreLocator.macOSKernel || kernel == HerdrCoreLocator.linuxKernel)
    }
}

/// Announces foreground Blocked/Error/Done Agent transitions from the Console's
/// live Agent list (#77), replacing system push banners while the app is
/// foregrounded (`willPresent` is always `[]`). Error
/// goes under the Blocked trigger in its own word, and a core
/// Host's Done is already this device's Done in the list.
///
/// The gates mirror the plugin's pipeline, app-side: a transition must hold
/// `holdDuration` before announcing (herdr's status detection flaps), an
/// unchanged status never repeats, the presented Agent stays silent (spec
/// #68, story 8, decided at fire time like the push path), and the Host's
/// trigger must be enabled. A Rex Host uses this device's foreground opt-in.
@MainActor
@Observable
final class AgentNotificationBannerStore {
    private(set) var banner: AgentNotificationBanner?

    /// Last observed status per pane; a banner candidate is a change of it.
    @ObservationIgnored private var statuses: [ConsoleAgent.ID: AgentStatus] = [:]
    @ObservationIgnored private var rexRecipients: [ConsoleAgent.ID: RexBannerRecipient] = [:]
    @ObservationIgnored private var isRexForeground = false
    /// In-flight anti-flap holds, cancelled when the status moves on.
    @ObservationIgnored private var holds: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private let holdDuration: Duration
    @ObservationIgnored private let dismissDelay: Duration
    @ObservationIgnored private let presentedAgent: @MainActor () -> ConsoleAgent.ID?
    @ObservationIgnored private let triggers:
        @MainActor (Host.ID) -> NotificationTriggerPreferences?
    @ObservationIgnored private let playSound: @MainActor () -> Void
    @ObservationIgnored private let rexRecipient: @MainActor (ConsoleAgent.ID) -> RexBannerRecipient?
    @ObservationIgnored private let verifyRexRecipient: @MainActor (ConsoleAgent.ID, RexBannerRecipient) async -> Bool

    /// - Parameters:
    ///   - holdDuration: how long a transition must hold before announcing.
    ///   - dismissDelay: how long a shown banner stays before auto-dismissing.
    ///   - presentedAgent: the Agent currently on screen (the router's
    ///     `path.last`), read at fire time.
    ///   - triggers: the Host's confirmed flags, or the local Rex choice;
    ///     nil means no banner.
    ///   - playSound: the banner's sound; 1007 is the system SMS-alert tone,
    ///     played through the alert route so the ringer switch is honored.
    init(
        holdDuration: Duration = .seconds(3),
        dismissDelay: Duration = .seconds(5),
        presentedAgent: @escaping @MainActor () -> ConsoleAgent.ID?,
        triggers: @escaping @MainActor (Host.ID) -> NotificationTriggerPreferences?,
        playSound: @escaping @MainActor () -> Void = { AudioServicesPlayAlertSound(1007) },
        rexRecipient: @escaping @MainActor (ConsoleAgent.ID) -> RexBannerRecipient? = { _ in nil },
        verifyRexRecipient: @escaping @MainActor (ConsoleAgent.ID, RexBannerRecipient) async -> Bool = { _, _ in false }
    ) {
        self.holdDuration = holdDuration
        self.dismissDelay = dismissDelay
        self.presentedAgent = presentedAgent
        self.triggers = triggers
        self.playSound = playSound
        self.rexRecipient = rexRecipient
        self.verifyRexRecipient = verifyRexRecipient
    }

    /// The Console feed, same as the router's: diff each pane's status
    /// against the last observed one. First sight is baseline, never a
    /// transition — a killed-state launch must not banner every Agent that
    /// was already Blocked when it synced.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        let current = Dictionary(agents.map { ($0.id, $0) }) { _, last in last }
        for id in statuses.keys where current[id] == nil {
            forget(id)
        }
        for (id, agent) in current {
            if agent.backend == .rex {
                guard isRexForeground, triggers(id.hostID) != nil, let recipient = rexRecipient(id) else {
                    forget(id)
                    continue
                }
                if rexRecipients[id] != recipient {
                    forget(id)
                    rexRecipients[id] = recipient
                }
            } else if rexRecipients[id] != nil {
                forget(id)
            }
            let previous = statuses[id]
            let status = agent.agent.status
            guard status != previous else { continue }
            statuses[id] = status
            cancelHold(for: id)
            guard previous != nil, status == .blocked || status == .error || status == .done else {
                continue
            }
            if agent.backend == .rex, status == .done, triggers(id.hostID)?.done != true { continue }
            scheduleHold(for: agent, status: status)
        }
    }

    func setRexForeground(_ active: Bool, agents: [ConsoleAgent]) {
        guard isRexForeground != active else { return }
        isRexForeground = active
        for id in rexRecipients.keys { forget(id) }
        if active { agentsDidChange(agents) }
    }

    func rexPreferencesDidChange(for hostID: Host.ID, agents: [ConsoleAgent]) {
        for id in rexRecipients.keys where id.hostID == hostID { forget(id) }
        agentsDidChange(agents)
    }

    private func forget(_ id: ConsoleAgent.ID) {
        statuses[id] = nil
        rexRecipients[id] = nil
        cancelHold(for: id)
        if let banner, banner.rexRecipient != nil, banner.target.agentID == id { dismiss() }
    }

    /// A Rex block can change hands while a banner is visible. Re-read its
    /// foreground before handing its ordinary Host and pane address to the router.
    func open(_ tapped: AgentNotificationBanner, route: @MainActor (AgentNotificationTarget) -> Void) async {
        guard banner == tapped else { return }
        if let recipient = tapped.rexRecipient {
            let id = tapped.target.agentID
            let verified = await verifyRexRecipient(id, recipient)
            guard banner == tapped else { return }
            guard verified, isRexForeground, triggers(id.hostID) != nil, rexRecipient(id) == recipient else {
                dismiss()
                return
            }
        }
        dismiss()
        route(tapped.target)
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
        let recipient = rexRecipients[agent.id]
        if agent.backend == .rex {
            guard isRexForeground, let recipient, rexRecipient(agent.id) == recipient else { return }
        }
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
                workspace: agent.workspaceLabel, agentKind: agent.agent.kind, status: status),
            rexRecipient: recipient)
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
