import Foundation

/// What the user last chose or launched, so the new-agent sheet opens on it
/// (#12, #601): launching several agents on the same Host and into the same
/// project, with the same Agent, is the common case, and re-picking them every
/// time is pure tax.
///
/// Hosts are kept in recency order by Server record ID, so both the last Host
/// and the last Server picked on each multi-Server Host are remembered. The
/// Workspace is remembered per Server record because a workspace ID only means
/// something inside one session. The Agent kind is a single preference across
/// Hosts: a Host that lacks it falls back to its own first kind.
struct RecentLaunchStore {
    private static let hostIDsKey = "recent-host-ids"
    private static let workspaceKey = "recent-workspace-by-host"
    private static let agentKindKey = "recent-agent-kind"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The most recently chosen Server among `hosts`, if any still exists.
    func preferredHostID(in hosts: [Host]) -> Host.ID? {
        let available = Set(hosts.map(\.id))
        return hostIDs.first { available.contains($0) }
    }

    func rememberHost(_ hostID: Host.ID) {
        let key = hostID.uuidString
        var updated = rawHostIDs.filter { $0 != key }
        updated.insert(key, at: 0)
        defaults.set(updated, forKey: Self.hostIDsKey)
    }

    /// Remove Host or turning a Server off forgets its remembered entry.
    func forgetHost(_ hostID: Host.ID) {
        let key = hostID.uuidString
        let current = rawHostIDs
        guard current.contains(key) else { return }
        let updated = current.filter { $0 != key }
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.hostIDsKey)
        } else {
            defaults.set(updated, forKey: Self.hostIDsKey)
        }
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

    private var hostIDs: [Host.ID] {
        rawHostIDs.compactMap(UUID.init(uuidString:))
    }

    private var rawHostIDs: [String] {
        defaults.stringArray(forKey: Self.hostIDsKey) ?? []
    }

    private var workspacesByHost: [String: String] {
        defaults.dictionary(forKey: Self.workspaceKey) as? [String: String] ?? [:]
    }
}
