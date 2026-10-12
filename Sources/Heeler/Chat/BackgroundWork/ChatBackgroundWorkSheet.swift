import SwiftUI

/// Everything Chat lists as Background Work, opened from the strip over
/// the Composer: running work, then what finished since the user's latest
/// message. A Workflow opens to the agents its journal lists. Like the
/// strip, it only shows; nothing here stops work.
struct ChatBackgroundWorkSheet: View {
    let chat: AgentChatStore
    let isHostConnected: Bool
    /// The presenting surface's: inside the sheet, the size class
    /// describes the sheet, not the screen.
    let sheetPresentation: ConsoleSheetPresentation

    /// Workflows open to their agents, starting with the one tapped.
    @State private var expanded: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    init(
        chat: AgentChatStore, isHostConnected: Bool, focus: String?, sheetPresentation: ConsoleSheetPresentation
    ) {
        self.chat = chat
        self.isHostConnected = isHostConnected
        self.sheetPresentation = sheetPresentation
        _expanded = State(initialValue: focus.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack {
            Group {
                if presentation(at: .now).ticks {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        list(presentation(at: context.date))
                    }
                } else {
                    list(presentation(at: .now))
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

    private func list(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        List {
            if !presentation.unfinished.isEmpty {
                Section("Running") {
                    ForEach(presentation.unfinished) { row in
                        item(row)
                    }
                }
            }
            if !presentation.finished.isEmpty {
                Section {
                    ForEach(presentation.finished) { row in
                        item(row)
                    }
                } header: {
                    Text("Finished")
                } footer: {
                    Text("Finished work leaves this list when you send your next message.")
                }
            }
        }
        // Rows start under the title, not a section header's gap below.
        .contentMargins(.top, 4, for: .scrollContent)
        .consoleSheetPage()
    }

    @ViewBuilder
    private func item(_ row: ChatBackgroundWorkPresentation.Row) -> some View {
        if row.agents.isEmpty {
            ChatBackgroundWorkSheetRow(row: row)
        } else {
            DisclosureGroup(isExpanded: isExpanded(row.id)) {
                ForEach(row.agents) { agent in
                    ChatBackgroundWorkAgentRow(agent: agent)
                }
            } label: {
                ChatBackgroundWorkSheetRow(row: row)
            }
        }
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            })
    }
}

/// A Subagent or Workflow in full: what it is, how far along, and what it
/// cost once it ended.
private struct ChatBackgroundWorkSheetRow: View {
    let row: ChatBackgroundWorkPresentation.Row

    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 20

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ChatBackgroundWorkGlyph(status: row.status)
                .frame(width: glyphColumn)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: row.title)
                        .font(.body)
                        .fontDesign(row.kind == .workflow ? .monospaced : nil)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let time = row.time {
                        Text(verbatim: time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                // A note can carry a date: it takes its own line rather
                // than the title's room.
                if let note = row.note {
                    Text(verbatim: note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: row.detail ?? row.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let fraction = row.fraction {
                    progress(fraction)
                }
                if let usage = row.usage {
                    Text(verbatim: usage)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.accessibilityLabel, row.detail, row.usage].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("chat.background-work.sheet.\(row.id)")
    }

    private func progress(_ fraction: ChatBackgroundWorkPresentation.Fraction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !row.status.isFinished {
                ProgressView(value: Double(min(fraction.done, fraction.total)), total: Double(max(fraction.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(.secondary)
            }
            // While it runs, a Workflow can start more agents.
            Text(verbatim: row.status.isFinished
                ? "\(fraction.done) of \(fraction.total) agents done"
                : "\(fraction.done) of \(fraction.total) agents done so far")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// One agent a Workflow ran, by the label its program gave it.
private struct ChatBackgroundWorkAgentRow: View {
    let agent: ChatBackgroundWorkPresentation.Agent

    @ScaledMetric(relativeTo: .body) private var glyphColumn: CGFloat = 20

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ChatBackgroundWorkGlyph(status: agent.status)
                .frame(width: glyphColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: agent.label)
                    .font(.subheadline)
                    .fontDesign(.monospaced)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let phase = agent.phase {
                    Text(verbatim: phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.accessibilityLabel)
    }
}
