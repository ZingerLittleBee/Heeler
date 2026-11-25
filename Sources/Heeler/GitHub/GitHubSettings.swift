import Foundation
import Observation

/// Whether the Console shows the GitHub tab, on by default, which Host it
/// reads, and Merge's Delete Branch as the user last left it. Off, no gh runs
/// and the device keeps no lists.
@MainActor
@Observable
final class GitHubSettings {
    static let enabledKey = "github.enabled"
    private static let hostKey = "github.host"
    private static let mergeDeletesBranchKey = "github.merge.deletesBranch"

    private(set) var isEnabled: Bool
    private(set) var selectedHostID: Host.ID?
    /// Delete Branch in the last Merge the user ran where they could set it,
    /// on until then.
    private(set) var mergeDeletesBranch: Bool

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        selectedHostID = defaults.string(forKey: Self.hostKey).flatMap(UUID.init(uuidString:))
        mergeDeletesBranch = defaults.object(forKey: Self.mergeDeletesBranchKey) as? Bool ?? true
    }

    /// Kept when a Merge runs, not as the switch moves: one write per Merge.
    func rememberMergeDeletesBranch(_ deletes: Bool) {
        guard deletes != mergeDeletesBranch else { return }
        mergeDeletesBranch = deletes
        defaults.set(deletes, forKey: Self.mergeDeletesBranchKey)
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
