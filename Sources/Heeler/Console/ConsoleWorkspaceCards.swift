import SwiftUI
import UIKit

/// The Agents list's By Workspace cards: an inset grouped list, one section
/// per card, as the Terminals list's By Workspace cards. The list keeps the
/// other presentations' page, so the cards take a quiet gray.
enum ConsoleWorkspaceCardMetrics {
    /// From the card's edge to its icons.
    static let padding: CGFloat = 16
    /// More room at a card's rounded ends, so the content there clears
    /// the corners' curve.
    static let endPadding: CGFloat = 8
    /// The icon column at the default text size; it grows with the text.
    static let iconWidth: CGFloat = 20
    static let iconSpacing: CGFloat = 10
    /// From the card's right edge to the end of a rule between Agents.
    static let ruleTrailing: CGFloat = 16
    /// Between cards.
    static let gap: CGFloat = 12

    /// A quiet gray card on the list's own background. Beside the sidebar's
    /// glass, the Terminals cards' fill.
    static func fill(inSidebar: Bool) -> Color {
        inSidebar ? ListCard.fill(inSidebar: true) : Color(uiColor: .secondarySystemBackground)
    }
}

extension EnvironmentValues {
    /// The shortest row of the list the cards sit in, which a card's rows
    /// keep themselves (see `ConsoleWorkspaceCardRow`).
    @Entry var workspaceCardMinRowHeight: CGFloat = 44
}

/// The icon column's width, scaled with the text it sits beside.
private struct CardIconWidth: DynamicProperty {
    @ScaledMetric(relativeTo: .subheadline) var value = ConsoleWorkspaceCardMetrics.iconWidth

    /// From the card's edge to its text, past the icon column.
    var textInset: CGFloat {
        ConsoleWorkspaceCardMetrics.padding + value + ConsoleWorkspaceCardMetrics.iconSpacing
    }
}

/// One row of a card. The list rounds the card's ends and clips a swiped
/// row to them; the row draws the card's fill, the selection beside the
/// sidebar, and its rule above.
struct ConsoleWorkspaceCardRow: ViewModifier {
    enum Indent {
        /// The row starts at the icon column.
        case icon
        /// An Agent listed under a header starts at the text column.
        case text
    }

    let placed: ConsoleWorkspaceCard.Placed
    let indent: Indent
    let top: CGFloat
    let bottom: CGFloat
    var isSelected = false
    /// Whether the row is at least the list's shortest row, centered in it
    /// as the list would center it; a summary fits its content instead.
    var fillsShortestRow = true
    private var iconWidth = CardIconWidth()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isSidebarColumn) private var isSidebarColumn
    @Environment(\.workspaceCardMinRowHeight) private var minRowHeight

    init(
        placed: ConsoleWorkspaceCard.Placed, indent: Indent, top: CGFloat, bottom: CGFloat,
        isSelected: Bool = false, fillsShortestRow: Bool = true
    ) {
        self.placed = placed
        self.indent = indent
        self.top = top
        self.bottom = bottom
        self.isSelected = isSelected
        self.fillsShortestRow = fillsShortestRow
    }

    private typealias Metrics = ConsoleWorkspaceCardMetrics

    func body(content: Content) -> some View {
        content
            .frame(minHeight: fillsShortestRow ? max(0, minRowHeight - top - bottom) : nil)
            // A card's ends in the row rather than its insets, which the
            // list applies only after a fold animates.
            .padding(.top, placed.isFirst ? Metrics.endPadding : 0)
            .padding(.bottom, padsBottom ? Metrics.endPadding : 0)
            .listRowInsets(
                EdgeInsets(
                    top: top, leading: indent == .text ? iconWidth.textInset : Metrics.padding,
                    bottom: bottom, trailing: Metrics.padding))
            .listRowSeparator(.hidden)
            // A row opens its Agent; only a header's fold button points.
            .navigationLinkIndicatorVisibility(.hidden)
            .listRowBackground(
                Metrics.fill(inSidebar: isSidebarColumn)
                    // The selection shows only beside the sidebar, where
                    // the detail stays on stage; see `ConsoleRowSelection`.
                    .overlay(isSidebarColumn && isSelected ? ConsoleRowSelection.fill : Color.clear)
                    .overlay(alignment: .top) { rule }
                    .background { if isSidebarColumn { ListRowCellFocusHalo() } })
    }

    /// A card's last row, unless it is a folded worktree's header: that
    /// header ends the card only while folded, and room it gained then
    /// would move it as it folds. It sits clear of the corners as it is.
    private var padsBottom: Bool {
        if case .checkout = placed.row { false } else { placed.isLast }
    }

    @ViewBuilder
    private var rule: some View {
        if placed.rule != .none {
            let isInset = placed.rule == .inset
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / displayScale)
                .padding(.leading, isInset ? iconWidth.textInset : 0)
                .padding(.trailing, isInset ? Metrics.ruleTrailing : 0)
        }
    }
}

/// A row a fold moves. One it is about to take fades first; one it brings
/// in slides down from the row above into place after `delay`, as the list
/// fades it in, so the rows a fold opens follow one another in.
struct ConsoleFoldReveal: ViewModifier {
    let isLeaving: Bool
    let isRevealing: Bool
    let delay: Double
    @State private var isPlaced = false

    func body(content: Content) -> some View {
        let isHidden = isRevealing && !isPlaced
        content
            .opacity(isHidden || isLeaving ? 0 : 1)
            .offset(y: isHidden ? -10 : 0)
            .onAppear {
                guard isRevealing else {
                    isPlaced = true
                    return
                }
                withAnimation(.snappy(duration: 0.35).delay(delay)) { isPlaced = true }
            }
    }
}

/// The card's icon column: a folder for what expands, a closed book for a
/// repository's main checkout, and a branch for a linked worktree.
struct ConsoleWorkspaceCardIcon: View {
    let systemName: String
    private var width = CardIconWidth()

    static let folder = "folder"

    init(systemName: String) {
        self.systemName = systemName
    }

    init(checkout: RepositoryCheckout?) {
        self.init(systemName: Self.systemName(for: checkout))
    }

    static func systemName(for checkout: RepositoryCheckout?) -> String {
        checkout?.isLinkedWorktree == true ? "arrow.triangle.branch" : "book.closed"
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: width.value)
            .accessibilityHidden(true)
    }
}

/// A checkout's title, then its branch or state in a quieter face; the
/// branch truncates first. VoiceOver hears what the icon shows.
struct ConsoleCheckoutTitleText: View {
    let title: ConsoleCheckoutTitle
    let font: Font
    var detailFont: Font = .footnote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: title.title)
                .font(font)
                .foregroundStyle(title.isPending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .layoutPriority(1)
            if let detail = title.detail {
                Text(verbatim: detail)
                    .font(detailFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title.accessibilityLabel))
    }
}

/// One checkout in a collapsed repository's summary.
struct ConsoleCheckoutSummary: Identifiable, Sendable {
    let id: ConsoleWorkspaceSection.ID
    let title: ConsoleCheckoutTitle
    let checkout: RepositoryCheckout?
    let agents: [ConsoleAgent]

    /// "iOS App, worktree, branch attach-polish, 2 Agents, 1 working, 1 done".
    var accessibilityText: String {
        let count = agents.count == 1 ? "1 Agent" : "\(agents.count) Agents"
        return [title.accessibilityLabel, count,
                ConsoleHostSectionHeaderPresentation.statusText(
                    items: ConsoleHostAgentStatusCounts(agents: agents).items)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// A card's header: what it holds, where, how many Agents, and the chevron
/// that collapses it. Collapsed, it says who needs the user and, for a
/// repository, in which checkout.
struct ConsoleWorkspaceCardHeader: View {
    let card: ConsoleWorkspaceCard
    let title: String
    let subtitle: String
    let checkouts: [ConsoleCheckoutSummary]
    let onToggle: () -> Void

    private typealias Metrics = ConsoleWorkspaceCardMetrics

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.iconSpacing) {
                ConsoleWorkspaceCardIcon(systemName: ConsoleWorkspaceCardIcon.folder)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 0)
                ConsoleCardFoldButton(count: card.agents.count, isCollapsed: card.isCollapsed)
            }
            .lineLimit(1)
            .frame(minHeight: 44, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(card.isCollapsed ? "Expands this Workspace." : "Collapses this Workspace.")
        .accessibilityAddTraits(.isHeader)
        .textCase(nil)
    }

    /// Collapsed, the summary's lines as well, which the eye reads off the
    /// row below.
    private var accessibilityValue: String {
        ([card.accessibilityValue] + checkouts.map(\.accessibilityText)).joined(separator: "; ")
    }
}

/// Under a collapsed card's header: who needs the user and, for a
/// repository, in which checkout. It folds the card open like its header,
/// which reads it to VoiceOver.
struct ConsoleWorkspaceCardSummary: View {
    let card: ConsoleWorkspaceCard
    let checkouts: [ConsoleCheckoutSummary]
    let onToggle: () -> Void

    var body: some View {
        let items = ConsoleHostAgentStatusCounts(agents: card.agents).items
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                if !items.isEmpty {
                    ConsoleHostStatusCountPills(items: items, wraps: true)
                }
                ForEach(checkouts) { @Sendable checkout in
                    MainActorContent { ConsoleCheckoutSummaryLine(summary: checkout) }
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

private struct ConsoleCheckoutSummaryLine: View {
    let summary: ConsoleCheckoutSummary
    @ScaledMetric(relativeTo: .caption2) private var iconWidth: CGFloat = 14

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: ConsoleWorkspaceCardIcon.systemName(for: summary.checkout))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: iconWidth)
            ConsoleCheckoutTitleText(title: summary.title, font: .footnote, detailFont: .caption)
            Spacer(minLength: 8)
            ConsoleAgentStatusDots(statuses: summary.agents.map(\.agent.status))
        }
    }
}

/// One dot per Agent in its status's ink, for a checkout whose rows are
/// folded away.
private struct ConsoleAgentStatusDots: View {
    let statuses: [AgentStatus]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { @Sendable _, status in
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// A checkout with several Agents inside a repository's card. A worktree
/// collapses on its own; the main checkout folds with its card.
struct ConsoleCheckoutHeader: View {
    let section: ConsoleWorkspaceSection
    let title: ConsoleCheckoutTitle
    let onToggle: (() -> Void)?

    var body: some View {
        if let onToggle {
            Button(action: onToggle) { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title.accessibilityLabel))
                .accessibilityValue(section.accessibilityValue)
                .accessibilityHint(
                    section.isCollapsed ? "Expands this worktree." : "Collapses this worktree.")
                .accessibilityAddTraits(.isHeader)
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title.accessibilityLabel))
                .accessibilityValue(
                    section.agents.count == 1 ? "1 Agent" : "\(section.agents.count) Agents")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: ConsoleWorkspaceCardMetrics.iconSpacing) {
            ConsoleWorkspaceCardIcon(checkout: section.checkout)
            ConsoleCheckoutTitleText(title: title, font: .subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if section.isCollapsed {
                ConsoleAgentStatusDots(statuses: section.agents.map(\.agent.status))
                    // Centered on the count's digits rather than sitting
                    // on their baseline.
                    .alignmentGuide(.firstTextBaseline) { $0.height + 1 }
            }
            Text("\(section.agents.count)")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            if onToggle != nil {
                ConsoleFoldChevron(isCollapsed: section.isCollapsed)
            }
        }
        // A whole fold target, as a header's tap area should be.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A card header's fold button: the card's Agent count and a chevron on one
/// capsule, which reads as a control where a worktree's bare chevron does
/// not.
private struct ConsoleCardFoldButton: View {
    let count: Int
    let isCollapsed: Bool
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.subheadline)
                .monospacedDigit()
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .modifier(ConsoleFoldTurn(isCollapsed: isCollapsed))
        }
        .foregroundStyle(Color.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(minHeight: height)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

/// A worktree's fold state: a bare chevron, quieter than its card's button,
/// in a column that grows with the text so the count beside it stays put.
private struct ConsoleFoldChevron: View {
    let isCollapsed: Bool
    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 24

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .modifier(ConsoleFoldTurn(isCollapsed: isCollapsed))
            .frame(width: width)
    }
}

/// A fold chevron's turn, animated by its own value: a card header's row
/// stays in place through a fold and does not carry the fold's animation.
private struct ConsoleFoldTurn: ViewModifier {
    let isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            .animation(reduceMotion ? nil : .snappy, value: isCollapsed)
    }
}
