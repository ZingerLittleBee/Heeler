import Foundation
import Observation

/// Whether the Console shows the GitHub tab, on by default, and which Host
/// it reads. Off, no gh runs and the device keeps no lists.
@MainActor
@Observable
final class GitHubSettings {
    static let enabledKey = "github.enabled"
    private static let hostKey = "github.host"

    private(set) var isEnabled: Bool
    private(set) var selectedHostID: Host.ID?

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        selectedHostID = defaults.string(forKey: Self.hostKey).flatMap(UUID.init(uuidString:))
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func selectHost(_ id: Host.ID?) {
        guard id != selectedHostID else { return }
        selectedHostID = id
        defaults.set(id?.uuidString, forKey: Self.hostKey)
    }
}
