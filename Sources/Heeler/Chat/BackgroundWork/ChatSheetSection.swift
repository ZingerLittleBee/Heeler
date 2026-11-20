import SwiftUI
import UIKit

/// A group of rows on one of Chat's sheets, set out as a grouped list sets
/// one out: a title where it has one, the rows on one rounded ground, and
/// a footnote under them.
struct ChatSheetSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(verbatim: title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ChatSheetStyle.titleInset)
                    .padding(.bottom, 7)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: ChatSheetStyle.group)
            if let footer {
                Text(verbatim: footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ChatSheetStyle.titleInset)
                    .padding(.top, 8)
            }
        }
    }
}

enum ChatSheetStyle {
    static let group = RoundedRectangle(cornerRadius: 14, style: .continuous)
    /// How far a row stands in from its group's edge.
    static let rowInset: CGFloat = 14
    /// Between a row's glyph and its text.
    static let glyphSpacing: CGFloat = 10
    /// A section's title and footnote, in line with its rows' glyphs.
    static let titleInset: CGFloat = 16
}

/// What ends a row that opens in place, turned over while it is open.
struct ChatSheetDisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The row under a hairline that starts `inset` in, where its text
    /// does; a group's first row has none.
    func chatRowDivider(_ shows: Bool, inset: CGFloat) -> some View {
        overlay(alignment: .top) {
            if shows {
                Divider()
                    .padding(.leading, inset)
            }
        }
    }
}
