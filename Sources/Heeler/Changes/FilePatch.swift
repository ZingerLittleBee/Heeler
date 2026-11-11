import Foundation

/// One lazy read, keyed by the Checkout and the status record's raw paths.
struct FilePatchRequest: Sendable, Equatable {
    enum Limit: Sendable, Equatable {
        case initial
        case extended

        var byteCount: Int {
            switch self {
            case .initial: GitProbe.Cap.patch
            case .extended: GitProbe.Cap.patchExtended
            }
        }
    }

    let topLevel: Data
    let path: Data
    let originalPath: Data?
    let isUntracked: Bool
    let limit: Limit

    init(
        topLevel: Data, path: Data, originalPath: Data? = nil,
        isUntracked: Bool, limit: Limit = .initial
    ) {
        self.topLevel = topLevel
        self.path = path
        self.originalPath = originalPath
        self.isUntracked = isUntracked
        self.limit = limit
    }

    /// Status collapses untracked directories. They must be expanded before
    /// an individual file can be read against the empty file.
    init?(file: ChangedFile, checkout: CheckoutLocation, limit: Limit = .initial) {
        guard !(file.kind == .untracked && file.path.last == UInt8(ascii: "/")) else {
            return nil
        }
        self.init(
            topLevel: checkout.topLevel, path: file.path, originalPath: file.originalPath,
            isUntracked: file.kind == .untracked, limit: limit)
    }
}

/// A single request can contain two file sections when an edited rename no
/// longer meets git's similarity threshold. IDs are stable prefix ordinals
/// at each level, so extending the read preserves existing row identities.
struct FilePatch: Sendable, Equatable {
    let files: [DiffFile]
    let isTruncated: Bool
}

struct DiffFile: Sendable, Equatable, Identifiable {
    let id: Int
    let oldPath: String?
    let newPath: String?
    let summary: String?
    let isBinary: Bool
    let hunks: [DiffHunk]

    /// Unchanged lines between the previous hunk, or the file's start, and
    /// the hunk at `index`, from the hunk headers; nil when there are none.
    /// A zero-count side names the line before the change, not its first.
    func unchangedLinesBefore(hunkAt index: Int) -> Int? {
        guard hunks.indices.contains(index) else { return nil }
        let hunk = hunks[index]
        let lastUnchanged = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
        let previousEnd: Int
        if index == 0 {
            previousEnd = 0
        } else {
            let previous = hunks[index - 1]
            previousEnd = previous.oldCount == 0
                ? previous.oldStart : previous.oldStart + previous.oldCount - 1
        }
        let count = lastUnchanged - previousEnd
        return count > 0 ? count : nil
    }

    /// Counted from the lines this read holds.
    var lineCounts: LineCounts {
        var added = 0
        var removed = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        return .lines(added: added, removed: removed)
    }
}

struct DiffHunk: Sendable, Equatable, Identifiable {
    let id: Int
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let section: String
    var lines: [DiffLine]

    var range: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }

    var title: String { section.isEmpty ? range : range + " " + section }
}

struct DiffLine: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case added
        case removed
        case context
    }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    var missingNewline = false

    var glyph: String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    var accessibilityLabel: String {
        let label = switch (kind, kind == .removed ? oldNumber : newNumber) {
        case (.added, let line?): String(localized: "Added, line \(line): \(text)")
        case (.added, nil): String(localized: "Added: \(text)")
        case (.removed, let line?): String(localized: "Removed, line \(line): \(text)")
        case (.removed, nil): String(localized: "Removed: \(text)")
        case (.context, let line?): String(localized: "Unchanged, line \(line): \(text)")
        case (.context, nil): String(localized: "Unchanged: \(text)")
        }
        return missingNewline ? String(localized: "\(label). No newline at end of file.") : label
    }
}
