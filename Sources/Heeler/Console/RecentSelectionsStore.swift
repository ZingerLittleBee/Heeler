import Foundation

/// The Host and Agent kind the user last started an agent with (#12).
///
/// The new-agent sheet pre-selects both, so opening it again to start another
/// agent needs no re-picking. Unlike `RecentWorkspaceStore`, these are global
/// rather than per-Host: a Host ID is only valid against the current Host
/// list, which the sheet already filters against, and kind availability is
/// per-Host by nature.
struct RecentSelectionsStore {
    private static let hostKey = "recent-agent-host"
    private static let kindKey = "recent-agent-kind"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastHostID: Host.ID? {
        guard let uuidString = defaults.string(forKey: Self.hostKey) else { return nil }
        return UUID(uuidString: uuidString)
    }

    var lastAgentKind: SupportedAgentKind? {
        defaults.string(forKey: Self.kindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    func remember(hostID: Host.ID, kind: SupportedAgentKind) {
        defaults.set(hostID.uuidString, forKey: Self.hostKey)
        defaults.set(kind.rawValue, forKey: Self.kindKey)
    }
}
