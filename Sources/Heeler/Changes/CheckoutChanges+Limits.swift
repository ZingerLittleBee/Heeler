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
            isLowerBound: isStatusTruncated, noun: "changed files")
    }

    /// Shared with untracked-directory listings. A capped status is a lower
    /// bound even when fewer than the display limit's records fit in it.
    static func limitNotice(shown: Int, total: Int, isLowerBound: Bool, noun: String) -> String? {
        guard shown < total || isLowerBound else { return nil }
        if total == 0, isLowerBound {
            return String(localized: "The Host's reply was truncated before any files could be listed.")
        }
        let totalText = isLowerBound ? "more than \(total.formatted())" : total.formatted()
        return String(localized: "Showing \(shown.formatted()) of \(totalText) \(noun).")
    }
}
