import SwiftUI
import UIKit

/// One side-by-side pair. Both cells stretch to the taller side. VoiceOver
/// reads the row as one element: the removed line, then the added line.
struct FileDiffSideBySideRow: View {
    let row: SideBySideRow
    let numberDigits: Int
    /// Changed words per line id, for the whole patch.
    var wordChanges: [Int: [Range<Int>]] = [:]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            FileDiffSideBySideCell(
                line: row.left, number: row.left?.oldNumber, numberDigits: numberDigits,
                wordChanges: row.left.flatMap { wordChanges[$0.id] } ?? [],
                showsContextMenu: showsCellMenu(isLeft: true))
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(width: DiffLayoutPolicy.dividerWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            FileDiffSideBySideCell(
                line: row.right, number: row.right?.newNumber, numberDigits: numberDigits,
                wordChanges: row.right.flatMap { wordChanges[$0.id] } ?? [],
                showsContextMenu: showsCellMenu(isLeft: false))
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .top)
        // One menu for the shared context line, covering both columns.
        .modifier(SideBySideCellLineMenu(line: isContextRow ? row.left : nil))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("file-diff-line-\(row.id)")
        .modifier(SideBySideRowReferenceActions(row: row))
    }

    /// A context row is one line drawn twice. Its menu is installed once, on
    /// the row. Every other non-nil cell gets its own menu.
    private var isContextRow: Bool {
        guard let left = row.left, let right = row.right else { return false }
        return left.id == right.id
    }

    private func showsCellMenu(isLeft: Bool) -> Bool {
        guard !isContextRow else { return false }
        return isLeft ? row.left != nil : row.right != nil
    }
}

/// One column of a side-by-side row. `line` is nil for an unpaired side,
/// which is hatched. `number` is the old number on the left and the new
/// number on the right, including for a context line shown on both sides.
struct FileDiffSideBySideCell: View {
    let line: DiffLine?
    let number: Int?
    let numberDigits: Int
    var wordChanges: [Range<Int>] = []
    var showsContextMenu: Bool

    var body: some View {
        Group {
            if let line {
                DiffLineRow(
                    line: line, numbers: [number], numberDigits: numberDigits,
                    gutterLeading: DiffLayoutPolicy.gutterLeadingPadding,
                    wordChanges: wordChanges, fillsHeight: true)
            } else {
                DiffHatch()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(SideBySideCellLineMenu(line: showsContextMenu ? line : nil))
    }
}

/// Installs a line menu only for a side that owns one. The shared modifier
/// adds nothing when the diff has no reference actions, so an empty menu
/// never lands on a lazy row.
private struct SideBySideCellLineMenu: ViewModifier {
    let line: DiffLine?

    @ViewBuilder func body(content: Content) -> some View {
        if let line {
            content.diffLineContextMenu(line)
        } else {
            content
        }
    }
}

/// Qualified actions on a changed pair. Context and unpaired rows use the
/// unqualified names, and the row stays one accessibility element.
private struct SideBySideRowReferenceActions: ViewModifier {
    let row: SideBySideRow

    @ViewBuilder func body(content: Content) -> some View {
        if let left = row.left, let right = row.right, left.id != right.id {
            content
                .diffLineAccessibilityActions(left, qualifier: .removed)
                .diffLineAccessibilityActions(right, qualifier: .added)
        } else if let left = row.left {
            content.diffLineAccessibilityActions(left)
        } else if let right = row.right {
            content.diffLineAccessibilityActions(right)
        } else {
            content
        }
    }
}
