import Foundation

/// The workspace the user last started an agent in, remembered per Host (#12).
///
/// The new-agent sheet pre-selects it: launching several agents into the same
/// project is the common case, and re-picking the workspace every time is pure
/// tax. Keyed by Host because a workspace ID only means something inside one
/// herdr session.
struct RecentWorkspaceStore {
    private static let defaultsKey = "recent-workspace-by-host"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workspaceID(for hostID: Host.ID) -> String? {
        byHost[hostID.uuidString]
    }

    func remember(_ workspaceID: String, for hostID: Host.ID) {
        var updated = byHost
        updated[hostID.uuidString] = workspaceID
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    /// Remove Host forgets its entry. Entries left by Hosts removed before it
    /// did stay, since nothing here knows which Hosts exist.
    func forget(_ hostID: Host.ID) {
        var updated = byHost
        guard updated.removeValue(forKey: hostID.uuidString) != nil else { return }
        if updated.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(updated, forKey: Self.defaultsKey)
        }
    }

    private var byHost: [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
