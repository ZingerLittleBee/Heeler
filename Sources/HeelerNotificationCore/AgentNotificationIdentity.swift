import Foundation

/// The compact Agent identity shared by alert notifications and Live
/// Activities. Workspace labels distinguish parallel Agents; the friendly
/// kind remains useful context without exposing terminal titles or custom
/// Agent names.
enum AgentNotificationIdentity {
    static func title(workspace: String?, kind: String) -> String {
        let kind = kindLabel(kind)
        guard let workspace = nonEmpty(workspace) else { return kind }
        return "\(workspace) · \(kind)"
    }

    static func kindLabel(_ rawValue: String) -> String {
        let rawValue = nonEmpty(rawValue) ?? "unknown"
        return switch rawValue.lowercased() {
        case "pi": "Pi"
        case "claude": "Claude"
        case "codex": "Codex"
        case "gemini": "Gemini CLI"
        case "cursor": "Cursor Agent"
        case "devin": "Devin CLI"
        case "agy": "Antigravity"
        case "cline": "Cline"
        case "omp": "OMP"
        case "mastracode": "Mastra Code"
        case "opencode": "OpenCode"
        case "copilot": "GitHub Copilot CLI"
        case "kimi": "Kimi CLI"
        case "kiro": "Kiro CLI"
        case "droid": "Droid"
        case "amp": "Amp"
        case "grok": "Grok Build"
        case "hermes": "Hermes Agent"
        case "kilo": "Kilo Code"
        case "qodercli": "Qoder CLI"
        case "maki": "Maki"
        case "muse": "Muse"
        case "qwen": "Qwen Code"
        case "unknown": "Unknown"
        default: rawValue
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Opt-in Detailed alerts (#428): the alert names the Agent the way its Live
/// Activity does, and a notification action says where a tap goes. Off by
/// default, so the default alert stays the #260 wording. Terminal titles are
/// never used here: they are unstable TUI output (#260).
enum AgentNotificationDetail {
    /// The notification action that opens the Agent, same as a tap.
    static let openAgentActionIdentifier = "dev.bybee.heeler.agent.open"
    /// Category prefix for per-notification categories that carry the
    /// destination-named action.
    static let openAgentCategoryPrefix = "dev.bybee.heeler.agent.open."
    /// Categories the extension keeps registered; older ones are dropped.
    static let categoryLimit = 32

    /// `workspace · tab` when both are known; otherwise today's
    /// `workspace · kind` identity.
    static func title(workspace: String?, tab: String?, kind: String) -> String {
        if let workspace = nonEmpty(workspace), let tab = nonEmpty(tab) {
            return "\(workspace) · \(tab)"
        }
        return AgentNotificationIdentity.title(workspace: workspace, kind: kind)
    }

    /// `<status> · <Kind> in <directory>`; the directory part drops out when
    /// the Host did not send one.
    static func body(status: AgentStatus, kind: String, directory: String?) -> String {
        let agent = AgentNotificationIdentity.kindLabel(kind)
        let subject = nonEmpty(directory).map { "\(agent) in \($0)" } ?? agent
        return "\(statusLabel(status)) · \(subject)"
    }

    /// The action label naming the destination, e.g. `Open Github · FIRSTMATE`.
    static func actionTitle(workspace: String?, tab: String?, kind: String) -> String {
        "Open \(title(workspace: workspace, tab: tab, kind: kind))"
    }

    /// One category per destination, so each notification can carry its own
    /// action label. The suffix is the label itself; categories only live
    /// on this device.
    static func categoryIdentifier(actionTitle: String) -> String {
        openAgentCategoryPrefix + actionTitle
    }

    /// Merge one destination category into the registered set: other
    /// categories are kept, the new one moves to the end, and detail
    /// categories beyond `categoryLimit` are dropped from the front. iOS
    /// returns categories as an unordered set, so "front" is only the order
    /// given; a dropped category only removes the button from an older
    /// alert; tapping that alert still opens the Agent.
    static func mergedCategoryIdentifiers(existing: [String], adding identifier: String)
        -> [String]
    {
        let others = existing.filter { !$0.hasPrefix(openAgentCategoryPrefix) }
        var details = existing.filter { $0.hasPrefix(openAgentCategoryPrefix) && $0 != identifier }
        details.append(identifier)
        if details.count > categoryLimit { details.removeFirst(details.count - categoryLimit) }
        return others + details
    }

    private static func statusLabel(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: "Blocked"
        case .done: "Done"
        default: "Status: \(status.rawValue)"
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// The per-Host Detailed alerts preference (#428), stored in the app group
/// shared with the Notification Service Extension so the extension can read
/// it while the app is not running. Absent means off.
struct AgentNotificationDetailPreferences: @unchecked Sendable {
    /// The shared app group (the same id as
    /// `NotificationKeyStore.sharedAccessGroup`).
    static let appGroup = "group.dev.bybee.heeler.shared"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        self.defaults = defaults
    }

    func isEnabled(forHost hostID: UUID) -> Bool {
        defaults?.bool(forKey: Self.key(hostID)) ?? false
    }

    func setEnabled(_ enabled: Bool, forHost hostID: UUID) {
        if enabled {
            defaults?.set(true, forKey: Self.key(hostID))
        } else {
            defaults?.removeObject(forKey: Self.key(hostID))
        }
    }

    private static func key(_ hostID: UUID) -> String {
        "notifications.detailedAlerts.\(hostID.uuidString)"
    }
}
