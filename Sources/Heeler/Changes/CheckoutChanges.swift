import Foundation

/// A request to read the Changes of the Checkout containing `directory`.
/// The Checkout is resolved on the Host by git itself, never from herdr's
/// repository metadata, so an Agent in a subdirectory or a linked Worktree
/// gets its own Checkout's Changes (#382).
struct ChangesReadRequest: Sendable, Equatable {
    /// The Agent's current directory on the Host.
    let directory: String
}

/// One read of a Checkout's Changes, as the Transport returns it.
struct CheckoutChangesRead: Sendable, Equatable {
    /// Owned by the Checkout: every directory inside it reads the same value.
    let changes: CheckoutChanges
    /// Where the requested directory sits inside the Checkout (git's
    /// `--show-prefix`, raw bytes, empty at the top level). Directory-specific,
    /// so it stays outside `changes`.
    let directoryPrefix: Data
}

/// A Checkout's uncommitted difference against its HEAD, display-ready.
/// Views render this and hold no git knowledge.
struct CheckoutChanges: Sendable, Equatable {
    let checkout: CheckoutLocation
    let head: CheckoutHead
    /// Conflicted files first, then everything else by raw path bytes.
    let files: [ChangedFile]
    var totals = ChangesTotals()

    var isClean: Bool { files.isEmpty && !isStatusTruncated }
    /// The Host's status output was capped, so files.count is a lower bound.
    var isStatusTruncated = false
    /// Counts or latest-commit output exceeded its Host-side cap.
    var isMetadataTruncated = false
}

/// Where the Changes list puts a file, as VS Code's Source Control groups
/// them: conflicts first, then staged, then the working tree's changes, a
/// partly staged file among them, then untracked files.
enum ChangesFileGroup: CaseIterable, Sendable {
    case conflicts
    case staged
    case changes
    case untracked

    init(_ file: ChangedFile) {
        switch (file.kind, file.staging) {
        case (.conflicted, _): self = .conflicts
        case (.untracked, _): self = .untracked
        case (_, .staged?): self = .staged
        default: self = .changes
        }
    }

    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .staged: "Staged"
        case .changes: "Changes"
        case .untracked: "Untracked"
        }
    }
}

/// One group of the Changes list and its files, in list order.
struct ChangesFileSection: Sendable, Equatable, Identifiable {
    let group: ChangesFileGroup
    let files: [ChangedFile]

    var id: ChangesFileGroup { group }
}

/// A git working tree as git resolved it on the Host.
struct CheckoutLocation: Sendable, Equatable, Hashable {
    /// `--show-toplevel`: the working tree's real path, as raw bytes.
    let topLevel: Data
    /// A linked Worktree rather than a repository's main checkout.
    let isLinkedWorktree: Bool
    /// The top level with the Host's home directory shortened to `~`.
    let displayPath: String

    /// The top level's last path component, as "storefront".
    var name: String {
        let component = displayPath.split(separator: "/").last.map(String.init) ?? ""
        return component.isEmpty ? displayPath : component
    }
}

/// What HEAD points at, and the latest commit's subject and time.
struct CheckoutHead: Sendable, Equatable {
    enum Branch: Codable, Sendable, Equatable {
        case named(String)
        case detached
    }

    let branch: Branch
    /// The full object id HEAD points at; nil while HEAD is unborn.
    let commit: String?
    /// Nil while HEAD is unborn, or when git could not read the commit.
    let latestCommit: LatestCommit?
    var upstream: CheckoutUpstream? = nil
    var isUnborn = false

    /// "main", or "Detached at 1a2b3c4".
    var branchTitle: String {
        switch branch {
        case .named(let name):
            name
        case .detached:
            "Detached at \(commit.map { String($0.prefix(7)) } ?? "unknown commit")"
        }
    }
}

struct LatestCommit: Sendable, Equatable {
    let subject: String
    /// The committer timestamp.
    let committedAt: Date

    /// A relative age computed on the device. A timestamp ahead of the
    /// device clock reads as "just now" rather than as a future time.
    func age(relativeTo now: Date, locale: Locale = .current) -> String {
        guard committedAt < now.addingTimeInterval(-59) else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: committedAt, relativeTo: now)
    }
}

/// One uncommitted file, keyed by the raw bytes of its status record.
struct ChangedFile: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case modified
        case added
        case deleted
        /// A staged rename; an unstaged move reads as a deletion plus an
        /// untracked file, or plus an added file when the new path was
        /// marked with `git add -N`.
        case renamed
        case untracked
        case conflicted

        var title: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .untracked: "Untracked"
            case .conflicted: "Conflicted"
            }
        }

        /// One monospaced letter for the row's badge: Tide's ? and ~ for
        /// untracked and conflicted files, as the Tide git item counts them,
        /// and git's letter for the kinds Tide does not mark.
        var symbol: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "?"
            case .conflicted: "~"
            }
        }
    }

    /// Whether the change is in the index, the working tree, or both.
    /// Untracked and conflicted files have no staging.
    enum Staging: Sendable, Equatable {
        case staged
        case unstaged
        case both

        var title: String {
            switch self {
            case .staged: "Staged"
            case .unstaged: "Unstaged"
            case .both: "Staged and unstaged"
            }
        }
    }

    /// The path relative to the Checkout's top level, as raw bytes.
    let path: Data
    /// A staged rename's previous path, as raw bytes.
    let originalPath: Data?
    let kind: Kind
    let staging: Staging?
    var lineCounts: LineCounts? = nil

    var id: Data { path }

    /// The path decoded for display: lossy UTF-8, with control characters
    /// shown as visible symbols so a newline or tab in a name stays on one
    /// row and remains identifiable.
    var displayPath: String { ChangedFile.displayText(path) }
    var displayOriginalPath: String? { originalPath.map(ChangedFile.displayText) }

    /// "Modified · Staged", "Renamed from old.txt · Staged", "Untracked".
    var detail: String {
        var parts: [String] = []
        if let displayOriginalPath {
            parts.append("\(kind.title) from \(displayOriginalPath)")
        } else {
            parts.append(kind.title)
        }
        if let staging { parts.append(staging.title) }
        return parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the row: its path and change kind.
    var accessibilityLabel: String {
        var parts = [displayPath]
        if let displayOriginalPath {
            parts.append("\(kind.title.lowercased()) from \(displayOriginalPath)")
        } else {
            parts.append(kind.title.lowercased())
        }
        if let staging { parts.append(staging.title.lowercased()) }
        return parts.joined(separator: ", ")
    }

    /// Kept separate from the path/kind label used by other Changes surfaces.
    var rowAccessibilityLabel: String {
        guard kind != .untracked, let lineCounts else { return accessibilityLabel }
        return accessibilityLabel + ", " + lineCounts.accessibilityLabel
    }

    /// The last path component. A directory keeps its trailing slash.
    var fileName: String { Self.split(displayPath).name }

    /// The path's directory, empty at the top level.
    var directory: String { Self.split(displayPath).directory }

    /// Beside the row's name: where a rename came from, then the directory,
    /// as "From CartError.swift · Sources/Checkout", so a short row keeps
    /// the rename. The list's group carries staging and the change letter
    /// the kind. Nil for a file at the top level that was not renamed.
    var rowDetail: String? {
        guard let displayOriginalPath else { return directory.isEmpty ? nil : directory }
        let original = Self.split(displayOriginalPath)
        if original.name == fileName, !original.directory.isEmpty, !directory.isEmpty {
            return "\(original.directory) → \(directory)"
        }
        let source = original.directory == directory ? original.name : displayOriginalPath
        return (["From \(source)"] + (directory.isEmpty ? [] : [directory]))
            .joined(separator: " · ")
    }

    /// Staged with further unstaged changes on top; listed under Changes.
    var isPartlyStaged: Bool { staging == .both }

    private static func split(_ path: String) -> (directory: String, name: String) {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return ("", path) }
        let name = String(path[path.index(after: slash)...])
        return (String(trimmed[..<slash]), name)
    }

    static func displayText(_ bytes: Data) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F:
                // Control Pictures: U+2400 plus the C0 code point.
                scalars.append(Unicode.Scalar(0x2400 + scalar.value) ?? scalar)
            case 0x7F:
                scalars.append(Unicode.Scalar(0x2421) ?? scalar)
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// Git-level outcomes of a Changes read. Transport failures, including the
/// git deadline (`TransportError.gitTimedOut`), stay `TransportError`s.
enum ChangesReadError: Error, Sendable, Equatable {
    /// The Transport cannot run git on a Host.
    case unavailable
    /// The directory is not inside a git working tree.
    case notAGitWorkingTree
    /// The output lacks a framed exit status or the final marker, so it
    /// cannot be trusted as complete, whatever the channel's status said.
    case incomplete
    /// Git failed; carries git's first framed error line.
    case gitFailed(String)
    case gitMissing
    case gitTooOld(String)
    case notOwnedByAccount
    case directoryMissing

    var message: String {
        switch self {
        case .unavailable:
            "This connection can't read Changes."
        case .notAGitWorkingTree:
            "This directory isn't inside a git working tree."
        case .incomplete:
            "The Host's reply ended early, so these Changes may be incomplete."
        case .gitFailed(let line):
            line
        case .gitMissing:
            "Git couldn't be run on this Host. Install git and make it available to the SSH account."
        case .gitTooOld(let version):
            "This Host has git \(version). Changes requires git 2.17 or later."
        case .notOwnedByAccount:
            "Git's ownership protection refused this Checkout because it belongs to another user account on the Host. Heeler doesn't bypass that protection."
        case .directoryMissing:
            "This directory no longer exists on the Host."
        }
    }
}

extension CheckoutChanges {
    /// What VoiceOver reads for the header, as one element: the Checkout,
    /// its linked Worktree marker, the branch or detached commit, and the
    /// latest commit with its age. It names the Checkout and never an
    /// Agent, so every Agent inside one Checkout hears the same summary.
    func accessibilitySummary(relativeTo now: Date, locale: Locale = .current) -> String {
        var sentences = [
            checkout.isLinkedWorktree
                ? "Checkout \(checkout.displayPath), linked Worktree"
                : "Checkout \(checkout.displayPath)"
        ]
        switch head.branch {
        case .named(let name):
            sentences.append("Branch \(name)")
        case .detached:
            sentences.append(head.branchTitle)
        }
        if let latest = head.latestCommit {
            sentences.append(
                "Latest commit: \(latest.subject), \(latest.age(relativeTo: now, locale: locale))")
        }
        if head.isUnborn { sentences.append("No commits yet") }
        if let upstream = head.upstream { sentences.append(upstream.accessibilitySummary) }
        sentences.append(totals.accessibilitySummary(statusTruncated: isStatusTruncated))
        return sentences.map { "\($0)." }.joined(separator: " ")
    }
}

/// Tracked text counts against HEAD, or a binary change without line counts.
enum LineCounts: Sendable, Equatable {
    case lines(added: Int, removed: Int)
    case binary

    /// Also used by the too-large diff state, without depending on a diff model.
    var summary: String {
        switch self {
        case .lines(let added, let removed): "+\(added.formatted()) −\(removed.formatted()) lines"
        case .binary: "Binary"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .lines(let added, let removed):
            "\(added.formatted()) \(added == 1 ? "line" : "lines") added, "
                + "\(removed.formatted()) \(removed == 1 ? "line" : "lines") removed"
        case .binary: "binary"
        }
    }
}

/// Computed before any display limit. Untracked directories count as one item.
struct ChangesTotals: Sendable, Equatable {
    var trackedFiles = 0
    var untrackedItems = 0
    var added = 0
    var removed = 0
    var linesAreComplete = true
    var linesAreAvailable = true

    var filesSummary: String {
        "\(trackedFiles.formatted()) \(trackedFiles == 1 ? "file" : "files") changed"
    }

    var untrackedSummary: String {
        "\(untrackedItems.formatted()) untracked \(untrackedItems == 1 ? "item" : "items")"
    }

    var accessibilitySummary: String { accessibilitySummary(statusTruncated: false) }

    /// `statusTruncated`: the Host capped its status output.
    func accessibilitySummary(statusTruncated: Bool) -> String {
        let lines = linesAreAvailable
            ? (linesAreComplete ? "" : "At least ")
                + LineCounts.lines(added: added, removed: removed).accessibilityLabel + " in tracked files"
            : "Line counts unavailable"
        return "\(spokenFiles(statusTruncated: statusTruncated)). \(lines). "
            + spokenUntracked(statusTruncated: statusTruncated)
    }

    /// Git lists every tracked entry before the untracked ones, so a capped
    /// status loses untracked items first. Once one untracked item is
    /// listed, the tracked count is whole and the untracked count a lower
    /// bound; with none listed, the tracked count is the lower bound and the
    /// untracked items were never reached.
    func spokenFiles(statusTruncated: Bool) -> String {
        (statusTruncated && untrackedItems == 0 ? "more than " : "") + filesSummary
    }

    func spokenUntracked(statusTruncated: Bool) -> String {
        guard statusTruncated else { return untrackedSummary }
        return untrackedItems > 0 ? "more than " + untrackedSummary : "untracked items not counted"
    }
}

/// A named upstream with divergence, or one git can no longer resolve.
struct CheckoutUpstream: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case tracking(ahead: Int, behind: Int)
        case deleted
        case unknown
    }

    let name: String
    var state: State = .deleted

    var summary: String {
        switch state {
        case .tracking(let ahead, let behind):
            "\(name): \(ahead.formatted()) ahead, \(behind.formatted()) behind"
        case .deleted: "Upstream \(name) was deleted"
        case .unknown: "Upstream \(name), comparison unavailable"
        }
    }

    var accessibilitySummary: String {
        if case .tracking(let ahead, let behind) = state {
            "\(ahead.formatted()) \(ahead == 1 ? "commit" : "commits") ahead and "
                + "\(behind.formatted()) \(behind == 1 ? "commit" : "commits") behind \(name)"
        } else {
            summary
        }
    }
}
