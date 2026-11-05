import Foundation

/// What the user last launched, so the new-agent sheet opens on it (#12,
/// #601): launching several agents into the same project, with the same
/// Agent, is the common case, and re-picking either every time is pure tax.
///
/// The Workspace is remembered per Host because a workspace ID only means
/// something inside one herdr session. The Agent kind is a single preference
/// across Hosts: a Host that lacks it falls back to its own first kind.
struct RecentLaunchStore {
    private static let workspaceKey = "recent-workspace-by-host"
    private static let agentKindKey = "recent-agent-kind"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workspaceID(for hostID: Host.ID) -> String? {
        workspacesByHost[hostID.uuidString]
    }

    func rememberWorkspace(_ workspaceID: String, for hostID: Host.ID) {
        var updated = workspacesByHost
        updated[hostID.uuidString] = workspaceID
        defaults.set(updated, forKey: Self.workspaceKey)
    }

    /// Nil until the first successful launch, or when a later version drops
    /// the stored kind.
    var agentKind: SupportedAgentKind? {
        defaults.string(forKey: Self.agentKindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    func rememberAgentKind(_ kind: SupportedAgentKind) {
        defaults.set(kind.rawValue, forKey: Self.agentKindKey)
    }

    /// Remove Host forgets its workspace. Entries left by Hosts removed before it
    /// did stay, since nothing here knows which Hosts exist.
    func forgetWorkspace(for hostID: Host.ID) {
        var updated = workspacesByHost
        guard updated.removeValue(forKey: hostID.uuidString) != nil else { return }
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.workspaceKey)
        } else {
            defaults.set(updated, forKey: Self.workspaceKey)
        }
    }

    private var workspacesByHost: [String: String] {
        defaults.dictionary(forKey: Self.workspaceKey) as? [String: String] ?? [:]
    }
}
