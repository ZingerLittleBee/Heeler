import Foundation

/// The Host and the "Agent" picker selection the user last launched (#12).
///
/// The new-agent sheet pre-selects both, so opening it again needs no
/// re-picking. Unlike `RecentWorkspaceStore`, these are global rather than
/// per-Host: a Host ID is only valid against the current Host list, which
/// the sheet already filters against, and kind availability is per-Host by
/// nature.
struct RecentSelectionsStore {
    private static let hostKey = "recent-agent-host"
    private static let kindKey = "recent-agent-kind"
    private static let shellSelectionKey = "recent-agent-selection-shell"

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

    /// The launch selection the user last dispatched: the remembered kind
    /// above preselects only when the shell was not the most recent choice.
    var lastSelectionWasShell: Bool {
        defaults.bool(forKey: Self.shellSelectionKey)
    }

    func remember(hostID: Host.ID, kind: SupportedAgentKind) {
        defaults.set(hostID.uuidString, forKey: Self.hostKey)
        defaults.set(kind.rawValue, forKey: Self.kindKey)
        defaults.set(false, forKey: Self.shellSelectionKey)
    }

    func rememberShell(hostID: Host.ID) {
        defaults.set(hostID.uuidString, forKey: Self.hostKey)
        defaults.set(true, forKey: Self.shellSelectionKey)
    }
}
