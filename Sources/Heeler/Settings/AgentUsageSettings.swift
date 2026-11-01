import Foundation
import Observation

/// Whether the Usage feature is on, for every window and across launches.
/// On by default. `ConsoleStore.setUsageEnabled(_:)` is what turns it off, as
/// it also stops the reads this switch governs.
@MainActor
@Observable
final class AgentUsageSettings {
    private static let defaultsKey = "usage.enabled"

    private(set) var isEnabled: Bool
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }
}
