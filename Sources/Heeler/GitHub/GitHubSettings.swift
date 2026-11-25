import Foundation
import Observation

/// Whether the Console shows the GitHub tab, on by default, which Host it
/// reads, each segment's filters, and Merge's Delete Branch as the user last
/// left it. Off, no gh runs and the device keeps no lists.
@MainActor
@Observable
final class GitHubSettings {
    static let enabledKey = "github.enabled"
    private static let hostKey = "github.host"
    private static let mergeDeletesBranchKey = "github.merge.deletesBranch"
    private static let pullRequestFilterKey = "github.filter.pullRequests"
    private static let issueFilterKey = "github.filter.issues"

    private(set) var isEnabled: Bool
    private(set) var selectedHostID: Host.ID?
    /// Delete Branch in the last Merge the user ran where they could set it,
    /// on until then.
    private(set) var mergeDeletesBranch: Bool
    /// What the filter row shows on each segment, kept across launches.
    private(set) var pullRequestFilter: GitHubListFilter
    private(set) var issueFilter: GitHubListFilter

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        selectedHostID = defaults.string(forKey: Self.hostKey).flatMap(UUID.init(uuidString:))
        mergeDeletesBranch = defaults.object(forKey: Self.mergeDeletesBranchKey) as? Bool ?? true
        pullRequestFilter = Self.filter(defaults.data(forKey: Self.pullRequestFilterKey), for: .pullRequest)
        issueFilter = Self.filter(defaults.data(forKey: Self.issueFilterKey), for: .issue)
    }

    func filter(for kind: GitHubItem.Kind) -> GitHubListFilter {
        switch kind {
        case .pullRequest: pullRequestFilter
        case .issue: issueFilter
        }
    }

    /// Kept when the user picks a filter, never while a view is drawn: a
    /// defaults write during a body pass can loop on iOS 27.3.
    func setFilter(_ filter: GitHubListFilter, for kind: GitHubItem.Kind) {
        let filter = filter.valid(for: kind)
        guard filter != self.filter(for: kind) else { return }
        switch kind {
        case .pullRequest: pullRequestFilter = filter
        case .issue: issueFilter = filter
        }
        let key = kind == .pullRequest ? Self.pullRequestFilterKey : Self.issueFilterKey
        if filter.isDefault {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(filter) {
            defaults.set(data, forKey: key)
        }
    }

    private static func filter(_ data: Data?, for kind: GitHubItem.Kind) -> GitHubListFilter {
        guard let data, let filter = try? JSONDecoder().decode(GitHubListFilter.self, from: data) else {
            return GitHubListFilter()
        }
        return filter.valid(for: kind)
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
