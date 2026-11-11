import Foundation

extension CheckoutChanges {
    static let displayLimit = 2_000

    /// The model retains every complete record for totals and later reads.
    /// Only the displayed list is limited; its raw path identities are intact.
    var listedFiles: ArraySlice<ChangedFile> { files.prefix(Self.displayLimit) }

    /// The listed files in VS Code's Source Control groups, each keeping
    /// the files' order; a group with no files is left out.
    var listedSections: [ChangesFileSection] {
        let grouped = Dictionary(grouping: listedFiles, by: ChangesFileGroup.init)
        return ChangesFileGroup.allCases.compactMap { group in
            grouped[group].map { ChangesFileSection(group: group, files: $0) }
        }
    }

    var listLimitNotice: String? {
        Self.limitNotice(
            shown: listedFiles.count, total: files.count,
            isLowerBound: isStatusTruncated, noun: .changedFiles)
    }

    /// What a limit notice counts: the Changes list's files, or the files
    /// inside an untracked directory.
    enum LimitNoun: Sendable {
        case changedFiles
        case files
    }

    /// Shared with untracked-directory listings. A capped status is a lower
    /// bound even when fewer than the display limit's records fit in it.
    static func limitNotice(shown: Int, total: Int, isLowerBound: Bool, noun: LimitNoun) -> String? {
        guard shown < total || isLowerBound else { return nil }
        if total == 0, isLowerBound {
            return String(localized: "The Host's reply was truncated before any files could be listed.")
        }
        let shownText = shown.formatted()
        let totalText = total.formatted()
        return switch (noun, isLowerBound) {
        case (.changedFiles, false): String(localized: "Showing \(shownText) of \(totalText) changed files.")
        case (.changedFiles, true): String(localized: "Showing \(shownText) of more than \(totalText) changed files.")
        case (.files, false): String(localized: "Showing \(shownText) of \(totalText) files.")
        case (.files, true): String(localized: "Showing \(shownText) of more than \(totalText) files.")
        }
    }
}
