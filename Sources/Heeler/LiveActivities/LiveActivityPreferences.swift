import Foundation
import Observation

/// Per-Host Live Activity opt-in, persisted in UserDefaults. Missing Hosts
/// read as off — fail closed, same as a missing notify flag.
@MainActor
@Observable
final class LiveActivityPreferences {
    private static let defaultsKey = "live-activity.enabled-hosts"

    private var enabledIDs: Set<UUID>
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        enabledIDs = Set(stored.compactMap(UUID.init(uuidString:)))
    }

    func isEnabled(for hostID: Host.ID) -> Bool {
        enabledIDs.contains(hostID)
    }

    func setEnabled(_ enabled: Bool, for hostID: Host.ID) {
        if enabled {
            enabledIDs.insert(hostID)
        } else {
            enabledIDs.remove(hostID)
        }
        defaults.set(enabledIDs.map(\.uuidString).sorted(), forKey: Self.defaultsKey)
    }
}
