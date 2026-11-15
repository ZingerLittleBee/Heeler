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

    /// Workflows open to their agents (starting with `focus`), and Command
    /// cards expand to their full un-truncated command when tapped.
    @State private var expandedWorkflows: Set<String>
    @State private var expandedCommands: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    init(
        chat: AgentChatStore, isHostConnected: Bool, focus: String?, sheetPresentation: ConsoleSheetPresentation
    ) {
        self.chat = chat
        self.isHostConnected = isHostConnected
        self.sheetPresentation = sheetPresentation
        _expandedWorkflows = State(initialValue: focus.map { [$0] } ?? [])
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
                if !presentation.unfinished.isEmpty {
                    cardSection(
                        title: String(localized: "Running"),
                        count: presentation.unfinished.count,
                        highlightsCount: presentation.hasRunning,
                        rows: presentation.unfinished)
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
        let canExpandAgents = !row.agents.isEmpty
        let canExpandCommand = row.kind == .command && row.fullTerminalText != nil
        let isExpanded =
            canExpandAgents
            ? expandedWorkflows.contains(row.id)
            : (canExpandCommand && expandedCommands.contains(row.id))

        ChatBackgroundWorkActivityCard(
            row: row,
            isExpandable: canExpandAgents || canExpandCommand,
            isExpanded: isExpanded,
            onToggleExpand: (canExpandAgents || canExpandCommand)
                ? {
                    withAnimation(.snappy(duration: 0.22)) {
                        if canExpandAgents {
                            if expandedWorkflows.contains(row.id) {
                                expandedWorkflows.remove(row.id)
                            } else {
                                expandedWorkflows.insert(row.id)
                            }
                        } else if canExpandCommand {
                            if expandedCommands.contains(row.id) {
                                expandedCommands.remove(row.id)
                            } else {
                                expandedCommands.insert(row.id)
                            }
                        }
                    }
                }
                : nil)
    }
}

/// Option 2 structured activity card: status & kind badges with tabular time
/// in the top bar, human-readable summary in the middle, and a full-width
/// recessed terminal box or Workflow progress bar underneath.
private struct ChatBackgroundWorkActivityCard: View {
    let row: ChatBackgroundWorkPresentation.Row
    let isExpandable: Bool
    let isExpanded: Bool
    let onToggleExpand: (() -> Void)?

    private static let innerBox = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerSection
                .contentShape(.rect)
                .onTapGesture {
                    onToggleExpand?()
                }

            if let terminalText = isExpanded ? (row.fullTerminalText ?? row.terminalPreview) : row.terminalPreview {
                terminalBox(terminalText)
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
                Text(verbatim: headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.status.isFinished ? Color.primary.opacity(0.88) : .primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = row.note, note != row.status.badgeLabel {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func terminalBox(_ text: String) -> some View {
        let box = Text(verbatim: text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(isExpanded ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(ChatBackgroundWorkPalette.terminalBackground, in: Self.innerBox)
            .overlay {
                Self.innerBox.stroke(ChatBackgroundWorkPalette.terminalBorder, lineWidth: 1)
            }

        if isExpanded {
            box.textSelection(.enabled)
        } else {
            box
                .contentShape(.rect)
                .onTapGesture {
                    onToggleExpand?()
                }
        }
    }

    private func workflowProgress(_ fraction: ChatBackgroundWorkPresentation.Fraction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
        .contentShape(.rect)
        .onTapGesture {
            onToggleExpand?()
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
