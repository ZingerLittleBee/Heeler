import Foundation

/// What the Notification Service Extension ends up showing: either decrypted
/// Agent Notification content or the generic fallback banner.
struct AgentNotificationAlert: Sendable, Equatable {
    let title: String
    let body: String
}

/// The service extension's logic as a pure function (#71): take the push's
/// `userInfo` and the registered Notification Keys, select the key by the
/// envelope's kid, decrypt, and phrase the alert as Host, agent kind, and
/// status. Anything undecryptable — missing or non-string envelope, unknown
/// kid, any `NotificationEnvelopeError` — degrades to `fallback`, which the
/// extension applies unconditionally so a forged push can never render
/// attacker-chosen text (spec #68, user story 20).
enum AgentNotificationRenderer {
    /// Mirrors the relay's generic wrap copy; deliberately unalarming.
    static let fallback = AgentNotificationAlert(title: "herdr", body: "Agent update")

    static func alert(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord]
    ) -> AgentNotificationAlert {
        guard let (record, payload) = NotificationEnvelope.open(userInfo: userInfo, keys: keys)
        else { return fallback }
        return AgentNotificationAlert(
            title: "\(payload.agentKind) on \(record.hostName)",
            body: body(for: payload.status))
    }

    private static func body(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "Blocked: waiting for your input"
        case .done: "Done: the agent finished"
        // The status set is open on the wire; render unrecognized values
        // factually instead of guessing at their meaning.
        default: "Status: \(status.rawValue)"
        }
    }
}
