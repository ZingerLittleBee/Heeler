import SwiftUI
import UIKit

/// Everything Chat lists as Background Work, opened from the strip over
/// the Composer: running work, work no read vouches for, then what finished
/// since the user's latest message, each a group of rows. A Workflow opens
/// to the agents its journal lists, and a Command to its whole command.
/// Like the strip, it only shows; nothing here stops work.
struct ChatBackgroundWorkSheet: View {
    let chat: AgentChatStore
    let isHostConnected: Bool
    /// The presenting surface's: inside the sheet, the size class
    /// describes the sheet, not the screen.
    let sheetPresentation: ConsoleSheetPresentation

    /// Rows opened by the user, plus an initial Workflow `focus` when that
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
                        page(presentation(at: context.date))
                    }
                } else {
                    page(presentation(at: .now))
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

    private func page(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(String(localized: "Running"), rows: presentation.running)
                section(String(localized: "Not updating"), rows: presentation.notUpdating)
                section(
                    String(localized: "Finished"), rows: presentation.finished,
                    footer: String(localized: "Finished work leaves this list when you send your next message."))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .consoleSheetPage()
    }

    @ViewBuilder
    private func section(
        _ title: String, rows: [ChatBackgroundWorkPresentation.Row], footer: String? = nil
    ) -> some View {
        if !rows.isEmpty {
            ChatSheetSection(title: "\(title) · \(rows.count)", footer: footer) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { @Sendable index, row in
                    MainActorContent {
                        card(for: row, isDivided: index > 0)
                    }
                }
            }
        }
    }

    private func card(for row: ChatBackgroundWorkPresentation.Row, isDivided: Bool) -> some View {
        ChatBackgroundWorkActivityCard(row: row, expandedCards: $expandedCards, isDivided: isDivided)
    }
}

/// One piece of Background Work on the sheet: its state as a glyph, what
/// it is, and its kind and time on a line under that; then what it runs in
/// a terminal block, or a Workflow's progress and, once opened, its agents.
/// It shows a chevron and opens on a tap only when that reveals something:
/// a Workflow's agents, a command on several lines, or text cut short.
struct ChatBackgroundWorkActivityCard: View {
    let row: ChatBackgroundWorkPresentation.Row
    @Binding var expandedCards: Set<String>
    /// Whether another row of its group stands over it.
    var isDivided = false

    @State private var headlineIsTruncated = false
    @State private var terminalIsTruncated = false
    @ScaledMetric(relativeTo: .callout) private var glyphColumn: CGFloat = 18

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
        HStack(alignment: .firstTextBaseline, spacing: ChatSheetStyle.glyphSpacing) {
            ChatBackgroundWorkGlyph(status: row.status, size: .large)
                .frame(width: glyphColumn)
            VStack(alignment: .leading, spacing: 0) {
                if isExpandable {
                    header
                        .contentShape(.rect)
                        .onTapGesture(perform: toggleExpand)
                } else {
                    header
                }
                if let preview = row.terminalPreview {
                    terminal(shown: isExpanded ? (row.fullTerminalText ?? preview) : preview, preview: preview)
                        .padding(.top, 8)
                }
                if let fraction = row.fraction {
                    workflowProgress(fraction)
                }
                if isExpanded, !row.agents.isEmpty {
                    agents
                        .padding(.top, 6)
                }
                if let usage = row.usage {
                    Text(verbatim: usage)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, ChatSheetStyle.rowInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatRowDivider(isDivided, inset: ChatSheetStyle.rowInset + glyphColumn + ChatSheetStyle.glyphSpacing)
        .onChange(of: row.terminalPreview == nil) { _, isNil in
            if isNil { terminalIsTruncated = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([row.accessibilityLabel, row.detail, row.usage].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("chat.background-work.sheet.\(row.id)")
    }

    /// A Command with no summary of its own is named by its kind, so its
    /// command shows once, in the terminal block.
    private var headline: String {
        row.cardHeadline ?? row.kindBadge
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: headline)
                    .font(.callout)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(
                        ChatTextTruncationProbe(
                            text: headline, font: .callout, lineLimit: 3, isTruncated: $headlineIsTruncated))
                if let meta {
                    Text(meta)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if isExpandable {
                ChatSheetDisclosureChevron(isExpanded: isExpanded)
            }
        }
    }

    /// The kind, then what the glyph alone leaves open (that it failed or
    /// was stopped, or why it shows no time), then its time, the one part
    /// set in the terminal's face.
    private var meta: AttributedString? {
        var parts: [AttributedString] = []
        if row.cardHeadline != nil {
            parts.append(AttributedString(row.kindBadge))
        }
        switch row.status {
        case .failed:
            var word = AttributedString(row.status.badgeLabel)
            word.swiftUI.foregroundColor = ChatBackgroundWorkPalette.statusInk(.failed)
            parts.append(word)
        case .stopped:
            parts.append(AttributedString(row.status.badgeLabel))
        case .unconfirmed, .quiet:
            if let note = row.note { parts.append(AttributedString(note)) }
        case .running, .completed:
            break
        }
        if let time = row.time {
            var text = AttributedString(time)
            text.swiftUI.font = .system(.caption, design: .monospaced)
            if row.status == .running {
                text.swiftUI.foregroundColor = ChatBackgroundWorkPalette.statusInk(.running)
            }
            parts.append(text)
        }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() {
            line += AttributedString(" · ")
            line += part
        }
        return line
    }

    @ViewBuilder
    private func terminal(shown text: String, preview: String) -> some View {
        let block = ChatTerminalBlock(cornerRadius: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if row.kind == .command {
                    Text(verbatim: "$ ")
                        .foregroundStyle(ChatTerminalBlockStyle.prompt)
                        .accessibilityHidden(true)
                }
                Text(verbatim: Self.unprompted(text))
                    .lineLimit(isExpanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(
                        ChatTextTruncationProbe(
                            text: Self.unprompted(preview), font: .caption, isCode: true, lineLimit: 2,
                            isTruncated: $terminalIsTruncated))
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }

        if !isExpandable || isExpanded {
            block.textSelection(.enabled)
        } else {
            block
                .contentShape(.rect)
                .onTapGesture(perform: toggleExpand)
        }
    }

    /// The command without the prompt its row carries: the block draws one.
    private static func unprompted(_ text: String) -> String {
        text.hasPrefix("$ ") ? String(text.dropFirst(2)) : text
    }

    @ViewBuilder
    private func workflowProgress(_ fraction: ChatBackgroundWorkPresentation.Fraction) -> some View {
        let progress = VStack(alignment: .leading, spacing: 4) {
            if !row.status.isFinished {
                ProgressView(
                    value: Double(min(fraction.done, fraction.total)),
                    total: Double(max(fraction.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(ChatBackgroundWorkPalette.workflowTint)
                    .padding(.top, 8)
            }
            Text(
                verbatim: row.status.isFinished
                    ? String(localized: "\(fraction.done) of \(fraction.total) agents done")
                    : String(localized: "\(fraction.done) of \(fraction.total) agents done so far"))
                .font(row.status.isFinished ? .footnote : .caption)
                .monospacedDigit()
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

    private var agents: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(row.agents) { @Sendable agent in
                MainActorContent {
                    ChatBackgroundWorkAgentRow(agent: agent)
                }
            }
        }
    }
}

/// One agent a Workflow ran, by the label its program gave it, and the
/// phase it ran in.
private struct ChatBackgroundWorkAgentRow: View {
    let agent: ChatBackgroundWorkPresentation.Agent

    @ScaledMetric(relativeTo: .caption) private var glyphColumn: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ChatBackgroundWorkGlyph(status: agent.status)
                .frame(width: glyphColumn)
            Text(verbatim: agent.label)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let phase = agent.phase {
                Text(verbatim: phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 28)
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
