import Foundation

/// What the user last chose or launched, so the new-agent sheet opens on it
/// (#12, #601): launching several agents on the same Host and into the same
/// project, with the same Agent, is the common case, and re-picking them every
/// time is pure tax.
///
/// Hosts are kept in recency order by Server record ID, so both the last Host
/// and the last Server picked on each multi-Server Host are remembered. The
/// Workspace is remembered per Server record because a workspace ID only means
/// something inside one session. Browsed directories belong to the Host's
/// filesystem and are remembered per Host machine across its Servers. The Agent
/// kind and each kind's Launch Preset are device preferences across Hosts: a
/// Host that lacks the kind or a deleted preset falls back cleanly.
struct RecentLaunchStore {
    enum PresetChoice: Equatable, Sendable {
        case noPreset
        case preset(LaunchPreset.ID)
    }

    private struct RememberedDirectory: Codable, Equatable, Sendable {
        var connection: HostMachine.Connection
        var path: String
    }

    private static let hostIDsKey = "recent-host-ids"
    private static let workspaceKey = "recent-workspace-by-host"
    private static let directoryKey = "recent-directory-by-host"
    private static let agentKindKey = "recent-agent-kind"
    private static let presetKey = "recent-preset-by-agent-kind"
    private static let nonePresetValue = "none"

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

    func directory(for connection: HostMachine.Connection) -> String? {
        guard let path = directoriesByHost.first(where: { $0.connection == connection })?.path,
            RemoteHostPath.isAbsolute(path)
        else { return nil }
        return path
    }

    func rememberDirectory(_ path: String, for connection: HostMachine.Connection) {
        guard RemoteHostPath.isAbsolute(path) else { return }
        var updated = directoriesByHost
        if let index = updated.firstIndex(where: { $0.connection == connection }) {
            updated[index].path = path
        } else {
            updated.append(RememberedDirectory(connection: connection, path: path))
        }
        saveDirectories(updated)
    }

    func forgetDirectory(for connection: HostMachine.Connection) {
        var updated = directoriesByHost
        let before = updated.count
        updated.removeAll { $0.connection == connection }
        guard updated.count != before else { return }
        saveDirectories(updated)
    }

    /// Nil until the first successful launch, or when a later version drops
    /// the stored kind.
    var agentKind: SupportedAgentKind? {
        defaults.string(forKey: Self.agentKindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    func rememberAgentKind(_ kind: SupportedAgentKind) {
        defaults.set(kind.rawValue, forKey: Self.agentKindKey)
    }

    func presetChoice(for kind: SupportedAgentKind) -> PresetChoice? {
        guard let raw = presetsByAgentKind[kind.rawValue] else { return nil }
        if raw == Self.nonePresetValue { return .noPreset }
        return UUID(uuidString: raw).map(PresetChoice.preset)
    }

    func rememberPreset(_ presetID: LaunchPreset.ID?, for kind: SupportedAgentKind) {
        var updated = presetsByAgentKind
        updated[kind.rawValue] = presetID?.uuidString ?? Self.nonePresetValue
        defaults.set(updated, forKey: Self.presetKey)
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

    private var directoriesByHost: [RememberedDirectory] {
        guard let data = defaults.data(forKey: Self.directoryKey) else { return [] }
        return (try? JSONDecoder().decode([RememberedDirectory].self, from: data)) ?? []
    }

    private func saveDirectories(_ directories: [RememberedDirectory]) {
        if directories.isEmpty {
            defaults.removeObject(forKey: Self.directoryKey)
        } else if let data = try? JSONEncoder().encode(directories) {
            defaults.set(data, forKey: Self.directoryKey)
        }
    }

    private var presetsByAgentKind: [String: String] {
        defaults.dictionary(forKey: Self.presetKey) as? [String: String] ?? [:]
    }
}
