import SwiftUI
import UIKit

/// The git item of fish's Tide prompt, drawn from a Changes read: the
/// branch, or `@` and the short commit while detached, then how far it is
/// behind and ahead of its upstream and how many files are conflicted,
/// staged, modified, and untracked, each only when nonzero, as
/// "main ⇣1 ⇡2 ~1 +3 !4 ?2". Changes reads neither Tide's stash count nor
/// an operation in progress, so those never show.
struct TideGitItem: Equatable {
    /// Tide's default `tide_git_truncation_length`.
    static let truncationLength = 24

    /// The branch, shortened as Tide shortens it, or the short commit.
    let location: String
    let isDetached: Bool
    /// Each nonzero count with its symbol, as "⇣1" or "+3".
    let counts: [String]
    let accessibilityValue: String

    /// Nil whenever the Agents list row would show no totals for the same
    /// read, except that a clean Checkout still shows its branch.
    init?(phase: ChangesStore.Phase, timedOutKeepingContent: Bool) {
        guard case .loaded(let changes) = phase, !timedOutKeepingContent else { return nil }
        self.init(changes)
    }

    init(_ changes: CheckoutChanges) {
        var spoken: [String] = []
        switch changes.head.branch {
        case .named(let name):
            location = Self.shortened(name)
            isDetached = false
            spoken.append("Branch \(name)")
        case .detached:
            location = changes.head.commit.map { String($0.prefix(7)) } ?? "HEAD"
            isDetached = true
            spoken.append(changes.head.branchTitle)
        }

        var ahead = 0
        var behind = 0
        if case .tracking(let a, let b) = changes.head.upstream?.state {
            ahead = a
            behind = b
        }
        let files = Self.fileCounts(changes)

        var counts: [String] = []
        func add(_ value: Int, _ symbol: String, _ phrase: String) {
            guard value > 0 else { return }
            counts.append(symbol + value.formatted())
            spoken.append("\(value.formatted()) \(phrase)")
        }
        add(behind, "⇣", behind == 1 ? "commit behind" : "commits behind")
        add(ahead, "⇡", ahead == 1 ? "commit ahead" : "commits ahead")
        for file in files { add(file.count, file.symbol, file.phrase) }
        self.counts = counts
        // The Host capped its status output, so the file counts are lower
        // bounds; Tide has no mark for that, so only VoiceOver says so.
        if changes.isStatusTruncated, !files.isEmpty {
            spoken.append("file counts incomplete")
        }
        accessibilityValue = spoken.joined(separator: ", ")
    }

    /// One of Tide's file counts: conflicted, staged, modified, or untracked.
    struct FileCount: Equatable {
        let symbol: String
        let count: Int
        /// What VoiceOver says after the count.
        let phrase: String
    }

    /// Tide's nonzero file counts, in its order, as "~1 +3 !4 ?2". A file
    /// both staged and modified counts once in each, as Tide counts it.
    static func fileCounts(_ changes: CheckoutChanges) -> [FileCount] {
        var conflicted = 0
        var staged = 0
        var dirty = 0
        for file in changes.files {
            if file.kind == .conflicted {
                conflicted += 1
                continue
            }
            switch file.staging {
            case .staged: staged += 1
            case .unstaged: dirty += 1
            case .both:
                staged += 1
                dirty += 1
            case nil: break
            }
        }
        return [
            FileCount(symbol: "~", count: conflicted, phrase: "conflicted"),
            FileCount(symbol: "+", count: staged, phrase: "staged"),
            FileCount(symbol: "!", count: dirty, phrase: "modified"),
            FileCount(symbol: "?", count: changes.totals.untrackedItems, phrase: "untracked"),
        ].filter { $0.count > 0 }
    }

    /// What the prompt reads, as "main ⇣1 ⇡2 +3".
    var text: String {
        ([(isDetached ? "@" : "") + location] + counts).joined(separator: " ")
    }

    /// Tide's `string shorten -m24`: the first 23 characters and an ellipsis.
    static func shortened(_ name: String) -> String {
        name.count > truncationLength
            ? String(name.prefix(truncationLength - 1)) + "…" : name
    }
}

/// Catppuccin Mauve, Mocha on dark and Latte on light, from the flavours
/// that color Agent Status. Not Tide's green: beside it, the added-lines
/// total and Done already mean green. Latte Mauve reads at 5.4:1 on white.
enum TideGitPalette {
    static let branch = DiffPalette.adaptive(light: 0x8839EF, dark: 0xCBA6F7)
}

/// The Tide git item in Agent detail's status line, at that line's size.
/// Only the branch takes a color; the counts stay secondary, so the
/// line's colors are the branch and the Checkout totals beside it, which
/// the staged count's "+" would otherwise echo. Only the branch gives way
/// when the line is short of room.
struct TideGitPrompt: View {
    let store: ChangesStore
    var font: Font = .caption2.weight(.medium)

    var body: some View {
        if let item = TideGitItem(
            phase: store.phase, timedOutKeepingContent: store.timedOutKeepingContent)
        {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.small)
                        .foregroundStyle(Color(uiColor: TideGitPalette.branch))
                    if item.isDetached {
                        Text(verbatim: "@").foregroundStyle(.primary)
                    }
                    Text(verbatim: item.location)
                        .foregroundStyle(Color(uiColor: TideGitPalette.branch))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Sendable for SwiftUI's async render thread, as in
                // ChangesRowTotals.fileCounts(_:style:) (#471).
                ForEach(Array(item.counts.enumerated()), id: \.offset) { @Sendable _, count in
                    Text(verbatim: count)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .font(font)
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Git")
            .accessibilityValue(item.accessibilityValue)
            .accessibilityIdentifier("agent-status-git")
        }
    }
}
