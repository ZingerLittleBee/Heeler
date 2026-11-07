import Foundation

/// A request to list the files inside one untracked directory. The top level
/// is the one from the latest Changes read, and `directory` is that read's
/// status path, trailing slash included.
struct UntrackedDirectoryRequest: Sendable, Equatable {
    /// The Checkout's top level, as raw bytes.
    let topLevel: Data
    /// The directory's path relative to the top level, as raw bytes.
    let directory: Data
}

/// The files inside one untracked directory, display-ready. Entries carry no
/// line counts: a directory listing is not a diff.
struct UntrackedDirectoryListing: Sendable, Equatable {
    /// The directory that was listed.
    let directory: Data
    /// The first entries that fit the display limit, in raw path order.
    let entries: [ChangedFile]
    /// Complete untracked records, before the display limit.
    let total: Int
    /// The status output hit its cap, so `total` is a lower bound.
    let isTruncated: Bool
    /// Git refused to descend: this directory is its own repository.
    let isSeparateRepository: Bool
    /// Nil when every entry fits. Otherwise the display-limit sentence.
    let limitNotice: String?

    /// Shown instead of child rows when git would not descend.
    var repositoryNotice: String? {
        isSeparateRepository ? String(localized: "This directory is a separate Git repository.") : nil
    }
}

extension ChangedFile {
    /// An untracked directory collapsed to one status row. A nested
    /// repository listed inside an expanded directory ends in `/` as well,
    /// and only a top-level row expands.
    var isUntrackedDirectory: Bool {
        kind == .untracked && path.last == UInt8(ascii: "/")
    }
}
