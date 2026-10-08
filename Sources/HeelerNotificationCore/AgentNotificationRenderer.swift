import Foundation

/// What the Notification Service Extension ends up showing: either decrypted
/// Agent Notification content or the generic fallback banner.
struct AgentNotificationAlert: Sendable, Equatable {
    let title: String
    let body: String
    /// Detailed alerts only (#428): the label of the action that opens the
    /// Agent, naming the destination. Nil for the default alert, which keeps
    /// no custom action.
    let actionTitle: String?

    init(title: String, body: String, actionTitle: String? = nil) {
        self.title = title
        self.body = body
        self.actionTitle = actionTitle
    }
}

/// The service extension's logic as a pure function (#71): take the push's
/// `userInfo` and the registered Notification Keys, select the key by the
/// envelope's kid, decrypt, and phrase the alert as workspace, Agent kind, and
/// status. Anything undecryptable — missing or non-string envelope, unknown
/// kid, any `NotificationEnvelopeError` — degrades to `fallback`, which the
/// extension applies unconditionally so a forged push can never render
/// attacker-chosen text (spec #68, user story 20).
enum AgentNotificationRenderer {
    /// Mirrors the relay's generic wrap copy; deliberately unalarming.
    static let fallback = AgentNotificationAlert(title: "Heeler", body: "Agent update")

    /// `detailed` answers the per-Host Detailed alerts preference (#428) for
    /// the Host whose key opened the envelope; it defaults to off, which is
    /// the #260 wording.
    static func alert(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord],
        detailed: (UUID) -> Bool = { _ in false }
    ) -> AgentNotificationAlert {
        guard let (record, payload) = NotificationEnvelope.open(userInfo: userInfo, keys: keys)
        else { return fallback }
        if detailed(record.hostID) {
            return detailedAlert(
                workspace: payload.project, tab: payload.tab, agentKind: payload.agentKind,
                status: payload.status, directory: payload.directory)
        }
        return alert(
            workspace: payload.project, agentKind: payload.agentKind, status: payload.status)
    }

    /// The opt-in Detailed alert (#428): `workspace · tab` over
    /// `<status> · <Kind> in <directory>`, plus an action label naming the
    /// destination. Every missing field falls back one step; terminal titles
    /// stay out (#260).
    static func detailedAlert(
        workspace: String?, tab: String?, agentKind: String, status: AgentStatus,
        directory: String?
    ) -> AgentNotificationAlert {
        AgentNotificationAlert(
            title: AgentNotificationDetail.title(workspace: workspace, tab: tab, kind: agentKind),
            body: AgentNotificationDetail.body(
                status: status, kind: agentKind, directory: directory),
            actionTitle: AgentNotificationDetail.actionTitle(
                workspace: workspace, tab: tab, kind: agentKind))
    }

    /// The one phrasing of an Agent Notification, shared by the push path
    /// above and the in-app foreground banner (#77) so the wording cannot
    /// drift between them.
    ///
    /// The workspace leads: with several agents running, it is what tells one
    /// notification from another — the agent kind rarely differs. The Host is
    /// deliberately absent: it is the same machine every time and spends the
    /// whole line on an address nobody reads. The encrypted wire still calls
    /// this value `project` for backward compatibility with older plugins.
    static func alert(
        workspace: String?, agentKind: String, status: AgentStatus
    ) -> AgentNotificationAlert {
        return AgentNotificationAlert(
            title: AgentNotificationIdentity.title(workspace: workspace, kind: agentKind),
            body: body(for: status))
    }

    private static func body(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "Blocked — waiting for input"
        case .done: "Done"
        // The status set is open on the wire; render unrecognized values
        // factually instead of guessing at their meaning.
        default: "Status: \(status.rawValue)"
        }
    }
}
