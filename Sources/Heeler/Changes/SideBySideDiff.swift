import Foundation

/// One side-by-side row. `id` is a unified line id: the left line's when
/// that side is present, otherwise the right line's. A context line is the
/// same value on both sides. A nil side is an unpaired line.
struct SideBySideRow: Sendable, Equatable, Identifiable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?

    /// Removed text, then added text. A context row reads its line once.
    var accessibilityLabel: String {
        switch (left, right) {
        case let (left?, right?) where left.id == right.id:
            left.accessibilityLabel
        case let (left?, right?):
            left.accessibilityLabel
                // A localized label may end in a Japanese full stop.
                + (left.accessibilityLabel.hasSuffix(".") || left.accessibilityLabel.hasSuffix("。") ? " " : ". ")
                + right.accessibilityLabel
        case let (left?, nil):
            left.accessibilityLabel
        case let (nil, right?):
            right.accessibilityLabel
        case (nil, nil):
            ""
        }
    }
}

/// Pairs a hunk's unified lines for the side-by-side columns. Views render
/// these rows and keep the line text whole; wrapping is the row's job.
enum SideBySideDiff {
    static func rows(for hunk: DiffHunk) -> [SideBySideRow] {
        var rows: [SideBySideRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        func flush() {
            let count = max(removed.count, added.count)
            for index in 0..<count {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                guard let id = left?.id ?? right?.id else { continue }
                rows.append(SideBySideRow(id: id, left: left, right: right))
            }
            removed.removeAll()
            added.removeAll()
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                flush()
                rows.append(SideBySideRow(id: line.id, left: line, right: line))
            case .removed:
                // An added run followed by a removal is a new block. Git does
                // not emit that order; pairing across it would cross changes.
                if !added.isEmpty { flush() }
                removed.append(line)
            case .added:
                added.append(line)
            }
        }
        flush()
        return rows
    }
}
