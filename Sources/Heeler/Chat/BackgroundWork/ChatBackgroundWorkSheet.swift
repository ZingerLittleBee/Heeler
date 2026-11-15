import SwiftUI
import UIKit

/// Everything Chat lists as Background Work, opened from the strip over
/// the Composer: running work, then what finished since the user's latest
/// message, rendered as structured activity cards. A Workflow opens to the
/// agents its journal lists, and tapping a Command card reveals its full
/// multi-line command. Like the strip, it only shows; nothing here stops work.
struct ChatBackgroundWorkSheet: View {
    let chat: AgentChatStore
    let isHostConnected: Bool
    /// The presenting surface's: inside the sheet, the size class
    /// describes the sheet, not the screen.
    let sheetPresentation: ConsoleSheetPresentation

    /// Cards expanded by the user, plus an initial Workflow `focus` when that
    /// Workflow already has agent rows to show.
    @State private var expandedCards: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    init(
        chat: AgentChatStore, isHostConnected: Bool, focus: String?, sheetPresentation: ConsoleSheetPresentation
    ) {
        self.chat = chat
        self.isHostConnected = isHostConnected
        self.sheetPresentation = sheetPresentation
        if let focus,
            chat.backgroundWork.rows.first(where: { $0.item.id == focus })?.progress?.agents.isEmpty == false
        {
            _expandedCards = State(initialValue: [focus])
        } else {
            _expandedCards = State(initialValue: [])
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if presentation(at: .now).ticks {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        cardsPage(presentation(at: context.date))
                    }
                } else {
                    cardsPage(presentation(at: .now))
                }
            }
            .navigationTitle("Background Work")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .modifier(ConsoleStatusSheetPresentationModifier(presentation: sheetPresentation))
        .accessibilityIdentifier("chat.background-work.sheet")
        // A new message, or another conversation, leaves nothing to show.
        .onChange(of: chat.backgroundWork.rows.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private func presentation(at now: Date) -> ChatBackgroundWorkPresentation {
        ChatBackgroundWorkPresentation(
            work: chat.backgroundWork, isHostConnected: isHostConnected, now: now, locale: locale,
            calendar: calendar)
    }

    private func cardsPage(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !presentation.running.isEmpty {
                    cardSection(
                        title: String(localized: "Running"),
                        count: presentation.running.count,
                        highlightsCount: true,
                        rows: presentation.running)
                }
                if !presentation.notUpdating.isEmpty {
                    cardSection(
                        title: String(localized: "Not updating"),
                        count: presentation.notUpdating.count,
                        highlightsCount: false,
                        rows: presentation.notUpdating)
                }
                if !presentation.finished.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        cardSection(
                            title: String(localized: "Finished"),
                            count: presentation.finished.count,
                            highlightsCount: false,
                            rows: presentation.finished)
                        Text("Finished work leaves this list when you send your next message.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .consoleSheetPage()
    }

    private func cardSection(
        title: String, count: Int, highlightsCount: Bool, rows: [ChatBackgroundWorkPresentation.Row]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(verbatim: "\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(
                        highlightsCount
                            ? ChatBackgroundWorkPalette.statusInk(.running)
                            : ChatBackgroundWorkPalette.statusInk(.stopped))
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 1.5)
                    .background(
                        highlightsCount
                            ? ChatBackgroundWorkPalette.statusWash(.running)
                            : ChatBackgroundWorkPalette.statusWash(.stopped),
                        in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            ForEach(rows) { @Sendable row in
                MainActorContent {
                    card(for: row)
                }
            }
        }
    }

    @ViewBuilder
    private func card(for row: ChatBackgroundWorkPresentation.Row) -> some View {
        ChatBackgroundWorkActivityCard(row: row, expandedCards: $expandedCards)
    }
}

/// Option 2 structured activity card: status & kind badges with tabular time
/// in the top bar, human-readable summary in the middle, and a full-width
/// recessed terminal box or Workflow progress bar underneath. Shows a
/// disclosure chevron and responds to tap-to-expand only when the card actually
/// has hidden agents, multi-line command formatting, or truncated text.
struct ChatBackgroundWorkActivityCard: View {
    let row: ChatBackgroundWorkPresentation.Row
    @Binding var expandedCards: Set<String>

    @State private var headlineIsTruncated = false
    @State private var terminalIsTruncated = false

    private static let innerBox = RoundedRectangle(cornerRadius: 10, style: .continuous)

    private var isExpandable: Bool {
        row.hasIntrinsicExpandableContent || headlineIsTruncated || terminalIsTruncated
    }

    private var isExpanded: Bool {
        isExpandable && expandedCards.contains(row.id)
    }

    private func toggleExpand() {
        guard isExpandable else { return }
        withAnimation(.snappy(duration: 0.22)) {
            if expandedCards.contains(row.id) {
                expandedCards.remove(row.id)
            } else {
                expandedCards.insert(row.id)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isExpandable {
                headerSection
                    .contentShape(.rect)
                    .onTapGesture(perform: toggleExpand)
            } else {
                headerSection
            }

            if let preview = row.terminalPreview {
                let shown = isExpanded ? (row.fullTerminalText ?? preview) : preview
                terminalBox(shown: shown, preview: preview)
            }

            if let fraction = row.fraction {
                workflowProgress(fraction)
            }

            if isExpanded, !row.agents.isEmpty {
                agentsBox
            }

            if let usage = row.usage {
                Text(verbatim: usage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ChatBackgroundWorkStyle.card
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay {
                    if row.status == .running {
                        ChatBackgroundWorkStyle.card.fill(
                            LinearGradient(
                                colors: [Color(uiColor: AgentStatusPalette.yellow).opacity(0.07), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
                    }
                }
        }
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(ChatBackgroundWorkPalette.cardBorder(row.status), lineWidth: 1)
        }
        .onChange(of: row.cardHeadline == nil) { _, isNil in
            if isNil { headlineIsTruncated = false }
        }
        .onChange(of: row.terminalPreview == nil) { _, isNil in
            if isNil { terminalIsTruncated = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([row.accessibilityLabel, row.detail, row.usage].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("chat.background-work.sheet.\(row.id)")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ChatBackgroundWorkStatusPill(status: row.status)
                        ChatBackgroundWorkKindChip(kind: row.kind, label: row.kindBadge)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ChatBackgroundWorkStatusPill(status: row.status)
                        ChatBackgroundWorkKindChip(kind: row.kind, label: row.kindBadge)
                    }
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if let time = row.time {
                        Text(verbatim: time)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(
                                row.status == .running
                                    ? ChatBackgroundWorkPalette.statusInk(.running)
                                    : .secondary)
                            .fixedSize()
                    }
                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
            }

            if let headline = row.cardHeadline {
                let headlineFont = Font.subheadline.weight(.semibold)
                Text(verbatim: headline)
                    .font(headlineFont)
                    .foregroundStyle(row.status.isFinished ? Color.primary.opacity(0.88) : .primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(
                        ChatTextTruncationProbe(
                            text: headline, font: headlineFont, lineLimit: 3, isTruncated: $headlineIsTruncated))
            }

            if let note = row.note, note != row.status.badgeLabel {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func terminalBox(shown text: String, preview: String) -> some View {
        let box = Text(verbatim: text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(
                ChatTextTruncationProbe(
                    text: preview, font: .caption, isCode: true, lineLimit: 2, isTruncated: $terminalIsTruncated))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
            .overlay {
                Self.innerBox.stroke(ChatBackgroundWorkPalette.terminalBorder, lineWidth: 1)
            }

        if !isExpandable || isExpanded {
            box.textSelection(.enabled)
        } else {
            box
                .contentShape(.rect)
                .onTapGesture(perform: toggleExpand)
        }
    }

    @ViewBuilder
    private func workflowProgress(_ fraction: ChatBackgroundWorkPresentation.Fraction) -> some View {
        let progress = VStack(alignment: .leading, spacing: 5) {
            if !row.status.isFinished {
                ProgressView(
                    value: Double(min(fraction.done, fraction.total)),
                    total: Double(max(fraction.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(ChatBackgroundWorkPalette.workflowTint)
            }
            Text(
                verbatim: row.status.isFinished
                    ? String(localized: "\(fraction.done) of \(fraction.total) agents done")
                    : String(localized: "\(fraction.done) of \(fraction.total) agents done so far"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        if isExpandable {
            progress
                .contentShape(.rect)
                .onTapGesture(perform: toggleExpand)
        } else {
            progress
        }
    }

    private var agentsBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(row.agents.enumerated()), id: \.element.id) { index, agent in
                MainActorContent {
                    if index > 0 {
                        Divider()
                            .opacity(0.45)
                            .padding(.vertical, 6)
                    }
                    ChatBackgroundWorkAgentRow(agent: agent)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
        .overlay {
            Self.innerBox.stroke(ChatBackgroundWorkPalette.terminalBorder, lineWidth: 1)
        }
    }
}

/// One agent a Workflow ran, by the label its program gave it.
private struct ChatBackgroundWorkAgentRow: View {
    let agent: ChatBackgroundWorkPresentation.Agent

    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 18

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ChatBackgroundWorkGlyph(status: agent.status)
                .frame(width: glyphColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: agent.label)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let phase = agent.phase {
                    Text(verbatim: phase)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.accessibilityLabel)
    }
}

/// Measures whether `text` truncates at `lineLimit` inside the modified view's
/// resolved width, keeping the answer stable even while the visible text is
/// expanded (`lineLimit(nil)`).
struct ChatTextTruncationProbe: ViewModifier {
    let text: String
    let font: Font
    var isCode = false
    let lineLimit: Int
    @Binding var isTruncated: Bool

    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    let probeWidth = max(1, proxy.size.width + 1)
                    ZStack(alignment: .topLeading) {
                        probeText
                            .lineLimit(lineLimit)
                            .frame(width: probeWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                limitedHeight = height
                                recompute()
                            }
                        probeText
                            .lineLimit(nil)
                            .frame(width: probeWidth, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                fullHeight = height
                                recompute()
                            }
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private var probeText: some View {
        Text(verbatim: text)
            .font(font)
            .fontDesign(isCode ? .monospaced : nil)
    }

    private func recompute() {
        guard limitedHeight > 0, fullHeight > 0 else { return }
        let truncated = fullHeight > limitedHeight + 1
        if isTruncated != truncated {
            isTruncated = truncated
        }
    }
}
