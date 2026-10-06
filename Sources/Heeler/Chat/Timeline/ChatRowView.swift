import SwiftUI

/// The widest the conversation gets on a regular-width screen; the
/// Composer and cards share it.
enum ChatTimelineMetrics {
    static let maximumContentWidth: CGFloat = 960
    static let horizontalPadding: CGFloat = 16
}

extension View {
    /// Chat's centered reading column.
    func chatContentColumn() -> some View {
        padding(.horizontal, ChatTimelineMetrics.horizontalPadding)
            .frame(maxWidth: ChatTimelineMetrics.maximumContentWidth)
            .frame(maxWidth: .infinity)
    }
}

/// One timeline row. The user's messages sit in bubbles; everything the
/// Agent did runs full width.
struct ChatRowView: View {
    let row: ChatRow
    let isExpanded: Bool
    let actions: ChatRowActions

    var body: some View {
        content
            // The cell, measured to fit the row, offers exactly that height
            // as a limit. A stack held to a limit shares it out by
            // flexibility and can cut a line from one text even though the
            // total fits, so rows always take their ideal height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, row.topSpacing)
            .chatContentColumn()
            .modifier(ChatRowAccessibility(row: row, actions: actions))
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case .user(let message):
            ChatUserBubble(message: message)
        case .assistant(_, let blocks):
            ChatMarkdownView(blocks: blocks)
        case .reasoning(let reasoning):
            ChatReasoningRow(reasoning: reasoning, isExpanded: isExpanded) { actions.toggle(row.id) }
        case .tool(let tool):
            ChatToolRow(
                tool: tool, isExpanded: isExpanded, missingOutputText: actions.missingOutputText
            ) { actions.toggle(row.id) }
        case .plan(let plan, let blocks):
            ChatPlanRow(plan: plan, blocks: blocks)
        case .questions(let questions):
            ChatQuestionsView(questions: questions)
        case .notice(let notice):
            ChatNoticeRow(notice: notice)
        case .divider(let divider):
            ChatDividerRow(divider: divider)
        case .pending(let echo):
            ChatPendingBubble(echo: echo)
        case .olderHistory(let older):
            ChatOlderHistoryRow(older: older, loadOlder: actions.loadOlder)
        }
    }
}

/// Who said it, then what, for VoiceOver; Copy and Select Text mirror the
/// long-press menu.
private struct ChatRowAccessibility: ViewModifier {
    let row: ChatRow
    let actions: ChatRowActions

    func body(content: Content) -> some View {
        if let text = row.copyText {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityAction(named: "Copy") { actions.copy(text) }
                .accessibilityAction(named: "Select Text") { actions.selectText(text) }
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        }
    }

    private var identifier: String {
        switch row.id {
        case .entry(let id): "chat.message.\(id.rawValue)"
        case .pending(let id): "chat.pending.\(id.uuidString)"
        case .olderHistory: "chat.older-status"
        }
    }
}

private struct ChatBubble<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemFill), in: .rect(cornerRadius: 18))
        }
    }
}

private struct ChatUserBubble: View {
    let message: ChatUserMessage

    var body: some View {
        ChatBubble {
            VStack(alignment: .trailing, spacing: 6) {
                if let command = message.command {
                    (Text("/\(command.name)").fontDesign(.monospaced).foregroundStyle(.tint)
                        + Text(command.arguments.isEmpty ? "" : " \(command.arguments)"))
                        .font(.body)
                } else {
                    Text(verbatim: message.text)
                        .font(.body)
                }
                if message.imageCount > 0 || !message.attachmentLabels.isEmpty || message.wasQueued {
                    ChatAttachmentChips(message: message)
                }
            }
            .accessibilityLabel(Text("You: ") + Text(verbatim: message.displayText))
        }
    }
}

private struct ChatAttachmentChips: View {
    let message: ChatUserMessage

    var body: some View {
        HStack(spacing: 6) {
            if message.imageCount > 0 {
                Label(
                    message.imageCount == 1 ? "1 image" : "\(message.imageCount) images",
                    systemImage: "photo")
            }
            ForEach(message.attachmentLabels.indices, id: \.self) { index in
                Label(message.attachmentLabels[index], systemImage: "paperclip")
                    .lineLimit(1)
            }
            if message.wasQueued {
                Label("Queued", systemImage: "clock")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ChatPendingBubble: View {
    let echo: ChatPendingEcho

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ChatBubble {
                Text(verbatim: echo.text)
                    .font(.body)
            }
            .opacity(echo.state == .sending ? 0.6 : 1)
            if let status {
                Label(status.text, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(status.color)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private var status: (text: String, symbol: String, color: Color)? {
        switch echo.state {
        case .sending:
            ("Sending…", "arrow.up.circle", .secondary)
        case .sent:
            nil
        case .unconfirmed:
            ("Sent. It hasn't appeared in the conversation yet.", "clock", .secondary)
        case .failed(let reason):
            ("Not sent. \(reason)", "exclamationmark.triangle", .red)
        case .notDelivered:
            ("Not delivered. The text is still in the Agent's input box.", "exclamationmark.triangle", .orange)
        }
    }
}

private struct ChatReasoningRow: View {
    let reasoning: ChatReasoning
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(title)
                    if !reasoning.text.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(reasoning.text.isEmpty)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                Text(verbatim: reasoning.text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var title: String {
        guard let milliseconds = reasoning.durationMilliseconds, milliseconds >= 1_000 else {
            return "Reasoning"
        }
        let duration = Duration.milliseconds(milliseconds)
        return "Thought for \(duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))"
    }
}

private struct ChatToolRow: View {
    let tool: ChatToolActivity
    let isExpanded: Bool
    let missingOutputText: String
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.symbol(for: tool.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: tool.title)
                            .font(.subheadline)
                            .fontDesign(titleIsCode ? .monospaced : nil)
                            .lineLimit(isExpanded ? nil : 2)
                        if let subtitle = tool.subtitle, !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .fontDesign(subtitleIsCode ? .monospaced : nil)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let diff = tool.diff {
                        ChatDiffBadge(diff: diff)
                    }
                    ChatToolStatusBadge(status: tool.status, exitCode: tool.exitCode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the output" : "Shows the output")
            if isExpanded {
                details
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    /// Commands, paths and patterns read as code. A command row with a
    /// subtitle is titled by its description, and the command moves below.
    private var titleIsCode: Bool {
        switch tool.kind {
        case .command: tool.subtitle?.isEmpty ?? true
        case .fileEdit, .fileWrite, .fileRead, .search: true
        default: false
        }
    }

    private var subtitleIsCode: Bool {
        switch tool.kind {
        case .command, .fileEdit, .fileWrite, .fileRead, .search: true
        default: false
        }
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = tool.note, !note.isEmpty {
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if !tool.questions.isEmpty {
                ChatQuestionsView(questions: tool.questions)
            }
            if let preview = tool.preview {
                if !preview.text.isEmpty {
                    Text(verbatim: preview.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
                }
                if preview.imageCount > 0 {
                    Label(
                        preview.imageCount == 1 ? "1 image" : "\(preview.imageCount) images",
                        systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if preview.isTruncated {
                    Text("Output continues in the terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if tool.output != nil {
                Text(missingOutputText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if tool.questions.isEmpty, tool.note == nil {
                Text(tool.status == .running ? "Running…" : "No output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func symbol(for kind: ChatToolActivity.Kind) -> String {
        switch kind {
        case .command: "terminal"
        case .fileEdit: "pencil"
        case .fileWrite: "doc.badge.plus"
        case .fileRead: "doc.text"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .question: "questionmark.bubble"
        case .todo: "checklist"
        case .mcp: "puzzlepiece.extension"
        case .image: "photo"
        case .other: "wrench.and.screwdriver"
        }
    }
}

private struct ChatDiffBadge: View {
    let diff: ChatDiffStats

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(diff.added)").foregroundStyle(.green)
            Text("−\(diff.removed)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diff.added) added, \(diff.removed) removed")
    }
}

private struct ChatToolStatusBadge: View {
    let status: ChatToolActivity.Status
    let exitCode: Int?

    var body: some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Running")
        case .succeeded:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Done")
        default:
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(color)
                .labelStyle(.titleAndIcon)
        }
    }

    private var label: String {
        switch status {
        case .awaitingApproval: "Waiting"
        case .failed: exitCode.map { "Exit \($0)" } ?? "Failed"
        case .declined: "Declined"
        case .interrupted: "Interrupted"
        case .notCompleted: "Not completed"
        case .noResult: "No result"
        case .running, .succeeded: ""
        }
    }

    private var symbol: String {
        switch status {
        case .awaitingApproval: "hand.raised"
        case .failed: "xmark.circle"
        case .declined: "nosign"
        case .interrupted: "stop.circle"
        case .notCompleted, .noResult: "minus.circle"
        case .running, .succeeded: ""
        }
    }

    private var color: Color {
        switch status {
        case .awaitingApproval, .declined: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

private struct ChatPlanRow: View {
    let plan: ChatPlan
    let blocks: [ChatMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                Text("Plan")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                ChatToolStatusBadge(status: plan.status, exitCode: nil)
            }
            .foregroundStyle(.secondary)
            ChatMarkdownView(blocks: blocks)
            if let note = plan.note, !note.isEmpty {
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
}

private struct ChatQuestionsView: View {
    let questions: [ChatQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions.indices, id: \.self) { index in
                let question = questions[index]
                VStack(alignment: .leading, spacing: 2) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: question.text)
                        .font(.subheadline)
                    if let answer = question.answer {
                        Label {
                            Text(verbatim: answer)
                        } icon: {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatNoticeRow: View {
    let notice: ChatNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: notice.kind == .shellCommand ? "! \(notice.title)" : notice.title)
                    .fontDesign(notice.kind == .shellCommand || notice.kind == .command ? .monospaced : nil)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.footnote)
            if let detail = notice.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .lineLimit(6)
            }
            if !notice.questions.isEmpty {
                ChatQuestionsView(questions: notice.questions)
            }
        }
        .foregroundStyle(notice.kind == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch notice.kind {
        case .command: "slash.circle"
        case .shellCommand: "terminal"
        case .taskNotification: "bell"
        case .interrupted: "stop.circle"
        case .stopped: "pause.circle"
        case .error: "exclamationmark.triangle"
        case .modelChange: "cpu"
        case .planMode: "list.bullet.clipboard"
        case .hook: "link"
        case .review: "eye"
        case .answered: "checkmark.bubble"
        case .system: "info.circle"
        }
    }
}

private struct ChatDividerRow: View {
    let divider: ChatDivider

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                line
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                line
            }
            if divider.kind == .compaction, let detail = divider.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / 3)
            .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch divider.kind {
        case .compaction: "Context compacted"
        case .historyUnavailable: "Earlier messages couldn't be read"
        }
    }
}

private struct ChatOlderHistoryRow: View {
    let older: ChatOlderHistory
    let loadOlder: () -> Void

    var body: some View {
        Group {
            switch older {
            case .available:
                Button("Load Earlier Messages", action: loadOlder)
                    .font(.footnote)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading earlier messages…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 6) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: loadOlder)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            case .reachedStart:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}
