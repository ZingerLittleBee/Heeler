import SwiftUI

/// "+4 −8" in the diff's inks, or "Binary". A side with no lines is left
/// out, and a change without line changes shows nothing.
struct ChangesLineCounts: View {
    let counts: LineCounts
    var font: Font = .footnote.weight(.semibold)
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.diffSurface) private var surface

    /// The visible text of each side, nil for a side left out. The minus
    /// sign is U+2212.
    static func texts(added: Int, removed: Int) -> (added: String?, removed: String?) {
        (
            added > 0 ? "+\(added.formatted())" : nil,
            removed > 0 ? "\u{2212}\(removed.formatted())" : nil
        )
    }

    var body: some View {
        let palette = DiffPalette.current(
            differentiatingWithoutColor: differentiateWithoutColor, on: surface)
        Group {
            switch counts {
            case .lines(let added, let removed) where added > 0 || removed > 0:
                let texts = Self.texts(added: added, removed: removed)
                HStack(spacing: 4) {
                    if let added = texts.added {
                        Text(verbatim: added)
                            .foregroundStyle(Color(uiColor: palette.added.ink))
                    }
                    if let removed = texts.removed {
                        Text(verbatim: removed)
                            .foregroundStyle(Color(uiColor: palette.removed.ink))
                    }
                }
            case .lines:
                EmptyView()
            case .binary:
                Text("Binary")
                    .foregroundStyle(.secondary)
            }
        }
        .font(font)
        .monospacedDigit()
        .fixedSize()
    }
}

/// The branch or detached commit, then how far it has moved from its
/// upstream as the Tide git item writes it, "⇣1 ⇡2", each only when
/// nonzero. An upstream that is gone says so, moving under the branch when
/// the row is short of room. The upstream's name is left to VoiceOver.
struct ChangesBranchRow: View {
    let head: CheckoutHead

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                branch
                upstream
            }
            VStack(alignment: .leading, spacing: 2) {
                branch
                upstream
            }
        }
    }

    private var branch: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ChangesHeaderIcon(
                systemName: head.branch == .detached
                    ? "smallcircle.filled.circle" : "arrow.triangle.branch")
            Text(head.branchTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var upstream: some View {
        if let upstream = head.upstream {
            switch upstream.state {
            case .tracking(let ahead, let behind):
                let counts = [behind > 0 ? "⇣\(behind.formatted())" : nil,
                              ahead > 0 ? "⇡\(ahead.formatted())" : nil].compactMap(\.self)
                if !counts.isEmpty {
                    Text(verbatim: counts.joined(separator: " "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            case .deleted, .unknown:
                Text(upstream.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A header row's leading symbol, one width for every row so their text
/// lines up.
struct ChangesHeaderIcon: View {
    let systemName: String
    @ScaledMetric(relativeTo: .subheadline) private var width: CGFloat = 18

    var body: some View {
        Image(systemName: systemName)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}
