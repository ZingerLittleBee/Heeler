import Foundation

/// What the Notification Service Extension ends up showing: either decrypted
/// Agent Notification content or the generic fallback banner.
struct AgentNotificationAlert: Sendable, Equatable {
    let title: String
    let body: String
}

/// The service extension's logic as a pure function (#71): take the push's
/// `userInfo` and the registered Notification Keys, select the key by the
/// envelope's kid, decrypt, and phrase the alert as project, agent task, and
/// status. Anything undecryptable — missing or non-string envelope, unknown
/// kid, any `NotificationEnvelopeError` — degrades to `fallback`, which the
/// extension applies unconditionally so a forged push can never render
/// attacker-chosen text (spec #68, user story 20).
enum AgentNotificationRenderer {
    /// Mirrors the relay's generic wrap copy; deliberately unalarming.
    static let fallback = AgentNotificationAlert(title: "herdr", body: "Agent update")

    /// Terminal titles are whole task descriptions ("排查修复 split 按钮 UI
    /// 结构问题") and can run to a full line of prose. iOS truncates the banner
    /// itself, but only after the notification has spent its payload budget on
    /// text nobody reads, so the phrasing cuts first.
    static let taskLimit = 80

    static func alert(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord]
    ) -> AgentNotificationAlert {
        guard let (_, payload) = NotificationEnvelope.open(userInfo: userInfo, keys: keys)
        else { return fallback }
        return alert(
            project: payload.project, agentKind: payload.agentKind, task: payload.title,
            status: payload.status)
    }

    /// The one phrasing of an Agent Notification, shared by the push path
    /// above and the in-app foreground banner (#77) so the wording cannot
    /// drift between them.
    ///
    /// The project leads: with several agents running, it is what tells one
    /// notification from another — the agent kind rarely differs. The Host is
    /// deliberately absent: it is the same machine every time and spends the
    /// whole line on an address nobody reads. `project` and `task` are
    /// best-effort (an older plugin sends neither), and the copy degrades one
    /// step at a time rather than all at once.
    static func alert(
        project: String?, agentKind: String, task: String?, status: AgentStatus
    ) -> AgentNotificationAlert {
        let project = trimmedNonEmpty(project)
        let task = trimmedNonEmpty(task)
        return AgentNotificationAlert(
            title: project.map { "\($0) · \(agentKind)" } ?? agentKind,
            body: body(for: status, task: task))
    }

    private static func body(for status: AgentStatus, task: String?) -> String {
        guard let task else { return statusOnlyBody(for: status) }
        return "\(word(for: status)) · \(truncated(task))"
    }

    private static func statusOnlyBody(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "Blocked: waiting for your input"
        case .done: "Done: the agent finished"
        // The status set is open on the wire; render unrecognized values
        // factually instead of guessing at their meaning.
        default: "Status: \(status.rawValue)"
        }
    }

    private static func word(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "Blocked"
        case .done: "Done"
        default: status.rawValue
        }
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > taskLimit else { return text }
        let head = text.prefix(taskLimit - 1)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }

    private static func trimmedNonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
