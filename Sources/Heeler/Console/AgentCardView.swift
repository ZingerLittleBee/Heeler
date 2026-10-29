import SwiftUI
import UIKit

/// The shared Agent Row Layout leads each card, after the Agent's program
/// mark in the list's row style; status and Heeler Pin end Row 1, the Host
/// name ends the first additional row, and the Checkout's Changes totals end
/// the last one, after the Host when that is the same row (both share a line
/// of their own when Row 1 is the only row and either shows). The Status
/// Ring style's ring stands in for the status capsule, which stays where
/// Differentiate Without Color is on or the ring cannot draw the status.
/// Fields retain their
/// emphasis using accessible semantic colors; plugin colors and weights do
/// not replace app typography.
struct AgentCardView: View {
    let agent: ConsoleAgent
    var layout: AgentRowLayout = .heelerDefault
    var isPinned: Bool = false
    /// The Agents list's read of this Agent's Checkout; nil where the card
    /// is only a preview.
    var changes: ChangesStore? = nil
    /// Totals shown in place of a read, for the Agent List Fields preview.
    var sampleChanges: ChangesBadge? = nil
    /// The program name after Row 1 when another row reads the same; see
    /// `AgentTitleQualifier`.
    var qualifier: String? = nil
    /// Set for a saved Chat entry point, which lists in an unproven Host's
    /// place: its Host's readiness, since the entry has no status of its own.
    var saved: HostReadiness? = nil
    /// Fields the surrounding card already shows.
    var hiddenTokens: Set<AgentRowToken> = []
    /// Where the card stands for its checkout or Workspace: Row 1 gives way
    /// to that title, and every row of the layout follows it.
    var heading: AgentCardHeading? = nil
    /// False where a header above the card names the Host.
    var showsHost = true
    /// Where the Agent's mark goes.
    var lead = AgentCardLead.row

    @Environment(\.agentListRowStyle) private var style
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor
    private var cardColumn = CardIconWidth()

    /// A list row's lead and the gap after it, as a Terminals row's tile.
    private static let rowTileSide: CGFloat = 30
    private static let rowAvatarDiameter: CGFloat = 34
    private static let rowLeadSpacing: CGFloat = 12

    /// From a list row's leading edge to its text, past the mark, where the
    /// Agents list starts its rules.
    static func rowTextOffset(_ style: AgentListRowStyle) -> CGFloat {
        (style == .tile ? rowTileSide : rowAvatarDiameter) + rowLeadSpacing
    }

    private var totalsSource: ChangesRowTotals.Source? {
        if let changes { .store(changes) } else { sampleChanges.map { .sample($0) } }
    }

    private var presentation: AgentCardPresentation {
        AgentCardPresentation(agent: agent, layout: layout, hiding: hiddenTokens, leadsWithMark: true)
    }

    private var mark: AgentKindMark { AgentKindMark(kind: agent.agent.kind) }

    /// The ring stands in for the capsule, except where color alone would
    /// carry it or the ring cannot draw the status.
    private var showsStatusBadge: Bool {
        style == .tile || differentiatesWithoutColor || !AgentStatusAvatar.drawsStatus(agent.agent.status)
    }

    /// The Tile style centers its tile on the title's line; the ring style,
    /// its avatar on the rows beside it.
    private var markAlignment: VerticalAlignment { style == .tile ? .agentMarkLine : .center }

    var body: some View {
        let presentation = presentation
        let additionalRows = heading == nil ? Array(presentation.rows.dropFirst()) : presentation.rows
        Group {
            if let heading, lead == .card {
                // A card of its own: its checkout's symbol on the heading's
                // line, and the mark beside the Agent's own lines below it.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: cardColumn.spacing) {
                        ConsoleWorkspaceCardIcon(systemName: heading.systemImage)
                        titleLine(presentation)
                    }
                    HStack(alignment: markAlignment, spacing: cardColumn.spacing) {
                        markView(side: cardColumn.value)
                        VStack(alignment: .leading, spacing: 6) {
                            additionalRowViews(additionalRows, marksFirstRow: true)
                        }
                    }
                }
            } else {
                HStack(alignment: markAlignment, spacing: lead == .card ? cardColumn.spacing : Self.rowLeadSpacing) {
                    markView(side: leadSide)
                    VStack(alignment: .leading, spacing: 6) {
                        titleLine(presentation)
                            .alignmentGuide(.agentMarkLine) { $0[VerticalAlignment.center] }
                        additionalRowViews(additionalRows)
                        if additionalRows.isEmpty, showsHostText || showsTotals {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Spacer(minLength: 0)
                                if showsHostText { hostText }
                                if let totalsSource {
                                    ChangesRowTotals(source: totalsSource).layoutPriority(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // Terminal blank rows become bounded extra card spacing on a phone.
        .padding(.bottom, CGFloat(min(layout.rowGap, 3)) * 8)
    }

    private var leadSide: CGFloat {
        switch lead {
        case .row: Self.rowTextOffset(style) - Self.rowLeadSpacing
        case .card: cardColumn.value
        }
    }

    /// The tile or avatar, which VoiceOver reads first as the program and,
    /// where the ring carries it, the status.
    private func markView(side: CGFloat) -> some View {
        let mark = mark
        let status = saved == nil ? agent.agent.status : .unknown
        let spoken = showsStatusBadge ? nil : status.displayTitle
        return Group {
            switch style {
            case .tile: AgentKindTile(mark: mark, side: side)
            case .statusRing: AgentStatusAvatar(mark: mark, status: status, diameter: side)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [mark.label, spoken].compactMap { $0 }.joined(separator: ", ")))
    }

    /// Row 1, or the heading in its place, with the pin and status after it.
    private func titleLine(_ presentation: AgentCardPresentation) -> some View {
        // Centered, not baseline-aligned: the status capsule is smaller
        // type with padding, so baseline alignment drops it below Row 1.
        HStack(alignment: .center) {
            if let heading {
                ConsoleCheckoutTitleText(title: heading.title, font: heading.font)
            } else {
                AgentCardTitle(
                    tokens: presentation.rows.first ?? [], qualifier: qualifier, isSaved: saved != nil)
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
                    .accessibilityLabel("Pinned")
            }
            Spacer(minLength: 8)
            // Whole at any text size; the title truncates instead.
            Group {
                if saved != nil {
                    SavedChatBadge()
                } else if showsStatusBadge, agent.agent.status.displayTitle != nil {
                    AgentStatusBadge(status: agent.agent.status)
                }
            }
            .fixedSize()
        }
    }

    /// Whether the totals have anything to show; a card whose rows end with
    /// Row 1 gives them a line only then.
    private var showsTotals: Bool {
        totalsSource.map { ChangesRowTotals(source: $0).hasTotals } ?? false
    }

    /// The rows after Row 1: the Host ends the first and the totals the last.
    /// `marksFirstRow` centers the Tile style's tile on the first, as a card
    /// of its own shows it beside the Agent's own title.
    ///
    /// SwiftUI can build these rows on its async render thread, as it built
    /// the file counts in `ChangesRowTotals.fileCounts(_:style:)` (#471), so
    /// the content is `@Sendable` and builds each row in `MainActorContent`.
    func additionalRowViews(
        _ rows: [[RenderedToken]], marksFirstRow: Bool = false
    ) -> ForEach<[(offset: Int, element: [RenderedToken])], Int, some View> {
        ForEach(Array(rows.enumerated()), id: \.offset) { @Sendable index, row in
            let isLast = index == rows.count - 1
            MainActorContent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AgentRowText(tokens: row, isSecondary: true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // The Host and the totals keep their width; the row's
                    // fields truncate first.
                    if index == 0 || isLast {
                        Spacer(minLength: 8)
                    }
                    if index == 0, showsHostText {
                        hostText.layoutPriority(1)
                    }
                    if isLast, let totalsSource {
                        ChangesRowTotals(source: totalsSource).layoutPriority(1)
                    }
                }
                .modifier(AgentMarkLine(isMarked: marksFirstRow && index == 0))
            }
        }
    }

    /// A saved entry keeps its Host, whose tone stands in for a status.
    private var showsHostText: Bool { showsHost || saved != nil }

    @ViewBuilder
    private var hostText: some View {
        if let saved {
            // The Host's state beside its name, in its tone, so a saved row
            // says which machine it waits for and how that is going.
            HStack(spacing: 4) {
                HostToneBadge(tone: saved.tone)
                    .frame(width: 7, height: 7)
                Text(verbatim: agent.hostName)
                    .foregroundStyle(saved.tone.tint)
            }
            .font(.caption)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(agent.hostName), \(saved.text)"))
        } else {
            Text(verbatim: agent.hostName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Row 1 of a card, with the program name after it when one is needed. The
/// title truncates first: the name is the part that tells the rows apart.
private struct AgentCardTitle: View {
    let tokens: [RenderedToken]
    let qualifier: String?
    /// A saved entry's title recedes, so it never reads as a running Agent.
    var isSaved = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            AgentRowText(tokens: tokens, isSecondary: isSaved)
                .lineLimit(1)
            if let qualifier {
                Text(verbatim: "· \(qualifier)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityLabel(Text(verbatim: qualifier))
            }
        }
        .font(isSaved ? .body.weight(.medium) : .headline)
    }
}

/// Keep per-field emphasis through the final Text instead of flattening the
/// rendered tokens into a String. Separators retain the row's base emphasis.
struct AgentRowText: View {
    let tokens: [RenderedToken]
    var isSecondary = false

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var span = AttributedString(token.text)
            let color: UIColor = if token.dim == true {
                isSecondary ? .tertiaryLabel : .secondaryLabel
            } else {
                isSecondary ? .secondaryLabel : .label
            }
            span.foregroundColor = Color(uiColor: color)
            result.append(span)
        }
        return result
    }
}

/// The title a card takes in Row 1's place, as `AgentCardView.heading`.
struct AgentCardHeading {
    let title: ConsoleCheckoutTitle
    /// A card of its own reads as an Agent's title; a checkout inside a
    /// repository's card, a size down.
    var isProminent = false
    /// The checkout's symbol, in the card's icon column beside the title.
    let systemImage: String

    var font: Font { isProminent ? .headline : .subheadline.weight(.semibold) }
}

/// Where an Agent card puts its program mark.
enum AgentCardLead: Equatable {
    /// Before the card's rows, as an Agents list row leads.
    case row
    /// In a Workspace card's icon column, which a heading's symbol shares.
    case card
}

extension VerticalAlignment {
    private enum AgentMarkLineID: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    /// The line the Tile style centers an Agent's tile on: the title's.
    static let agentMarkLine = VerticalAlignment(AgentMarkLineID.self)
}

/// Marks the row the Tile style's tile centers on, when it is not Row 1.
private struct AgentMarkLine: ViewModifier {
    let isMarked: Bool

    func body(content: Content) -> some View {
        if isMarked {
            content.alignmentGuide(.agentMarkLine) { $0[VerticalAlignment.center] }
        } else {
            content
        }
    }
}

struct AgentCardPresentation: Equatable, Sendable {
    let rows: [[RenderedToken]]
    /// Whether the row's lead is the program's own mark, which names the
    /// Agent as its kind word would.
    let isMarked: Bool

    var headline: String { rows.first?.map(\.text).joined() ?? "Agent" }
    var additionalRows: [String] { rows.dropFirst().map { $0.map(\.text).joined() } }

    /// `leadsWithMark` for an Agents list row, which leads with the
    /// program's mark: the kind word leaves rows it would only repeat (see
    /// `AgentRowRenderer.render`).
    init(
        agent: ConsoleAgent, layout: AgentRowLayout = .heelerDefault, hiding: Set<AgentRowToken> = [],
        leadsWithMark: Bool = false
    ) {
        isMarked = leadsWithMark && AgentKindMark.names(kind: agent.agent.kind)
        var rendered = AgentRowRenderer.render(
            layout: layout, agent: agent, hiding: hiding, omittingMarkedKind: leadsWithMark)
        // Where the card shows every other field, the kind word keeps its
        // configured style in place of the bare name.
        if rendered.isEmpty, leadsWithMark {
            rendered = AgentRowRenderer.render(layout: layout, agent: agent, hiding: hiding)
        }
        if rendered.isEmpty {
            let name = agent.agent.displayName
            rows = [[RenderedToken(
                token: .agent,
                text: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name,
                fg: nil, bold: nil, dim: nil)]]
        } else {
            rows = rendered
        }
    }

    /// Bound by graphemes, preserving literal plugin text and whole emoji.
    var switcherTitle: String {
        let singleLine = headline.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.count > 48 ? String(singleLine.prefix(47)) + "…" : singleLine
    }

    /// Whether the mark or the first `rowCount` rows already name the
    /// Agent itself, so two Agents sharing a title are told apart without
    /// help.
    func namesAgent(inFirst rowCount: Int) -> Bool {
        isMarked || rows.prefix(rowCount).contains { row in row.contains { $0.token == .agent } }
    }
}

/// The program name that follows an Agent's title when another Agent on
/// screen reads the same: two programs in one workspace, under a layout that
/// leads with the workspace, are otherwise told apart only by position. The
/// name is the one notifications use ("proj · Pi"), and only titles that
/// collide get one, and only when the program actually separates them.
enum AgentTitleQualifier {
    /// Each Agent's title as shown, and whether what is shown already names
    /// the Agent.
    struct Shown {
        let title: String
        let namesAgent: Bool
    }

    static func qualifiers(
        for agents: [ConsoleAgent], shown: (ConsoleAgent) -> Shown
    ) -> [ConsoleAgent.ID: String] {
        let entries = agents.map {
            (id: $0.id, shown: shown($0), program: AgentNotificationIdentity.kindLabel($0.agent.kind))
        }
        let programsByTitle = Dictionary(grouping: entries, by: \.shown.title)
            .mapValues { Set($0.map(\.program)) }
        var qualifiers: [ConsoleAgent.ID: String] = [:]
        for entry in entries where !entry.shown.namesAgent {
            guard let programs = programsByTitle[entry.shown.title], programs.count > 1 else {
                continue
            }
            qualifiers[entry.id] = entry.program
        }
        return qualifiers
    }
}

/// In the status capsule's place on a saved Chat entry: outlined where every
/// status is filled, so it never reads as one.
private struct SavedChatBadge: View {
    var body: some View {
        Text("Saved")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 1))
    }
}

/// Status rendered as a tinted capsule; Blocked gets the loudest color
/// because it is the one asking for the user. Working keeps a live solving
/// orb inside the capsule — a still badge cannot tell a busy Agent from a
/// finished one at a glance.
struct AgentStatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 12)
                    .accessibilityHidden(true)
            }
            Text(status.displayTitle ?? "")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(status.tintUIColor).opacity(0.15), in: Capsule())
        .foregroundStyle(Color(status.inkUIColor))
    }
}

#Preview {
    List {
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
                    status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                    cwd: "/work/proj", revision: 3),
                workspaceLabel: "proj",
                repositoryCheckout: RepositoryCheckout(
                    repoKey: "/work/proj/.git",
                    repoName: "proj",
                    repoRoot: "/work/proj",
                    checkoutPath: "/work/proj-wt",
                    isLinkedWorktree: true),
                lastOutputSnippet: "Allow Claude to run rm -rf? 1. Yes 2. No"))
        // No workspace in the snapshot: the Agent's own name takes the lead.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "claude", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repositoryCheckout: nil,
                lastOutputSnippet: nil))
    }
}
