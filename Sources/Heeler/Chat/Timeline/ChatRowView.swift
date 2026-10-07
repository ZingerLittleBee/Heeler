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
    /// The changed files whose diffs are open, by recorded path.
    var expandedFiles: Set<String> = []
    let actions: ChatRowActions

    var body: some View {
        content
            // The cell, measured to fit the row, offers exactly that height
            // as a limit. A stack held to a limit shares it out by
            // flexibility and can cut a line from one text even though the
            // total fits, so rows always take their ideal height.
            .fixedSize(horizontal: false, vertical: true)
            // Under its group's header, as its member.
            .padding(.leading, row.isNested ? 12 : 0)
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
            ChatMarkdownView(blocks: blocks, isMuted: row.isMuted)
        case .reasoning(let reasoning):
            ChatReasoningRow(reasoning: reasoning, isExpanded: isExpanded) { actions.toggle(row.id) }
        case .tool(let tool):
            ChatToolRow(
                tool: tool, isExpanded: isExpanded, expandedFiles: expandedFiles,
                missingOutputText: actions.missingOutputText, toggle: { actions.toggle(row.id) },
                files: fileActions, textActions: row.hasInnerControls ? textActions : nil)
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
        case .turnHeader(let header):
            ChatTurnHeaderRow(header: header) { actions.toggle(row.id) }
        case .toolGroup(let group):
            ChatToolGroupRow(group: group) { actions.toggle(row.id) }
        }
    }

    private var fileActions: ChatFileActions {
        let id = row.id
        let actions = actions
        return ChatFileActions(
            toggle: { actions.toggleFile(id, $0) }, showAll: { actions.showFile(id, $0) },
            retry: { actions.retryOutput(id) })
    }

    /// Copy and Select Text for a row VoiceOver can't read as one element.
    private var textActions: ChatToolRow.TextActions? {
        guard let text = row.copyText else { return nil }
        let actions = actions
        return ChatToolRow.TextActions(copy: { actions.copy(text) }, selectText: { actions.selectText(text) })
    }
}

/// Who said it, then what, for VoiceOver; Copy and Select Text mirror the
/// long-press menu. A row with controls of its own keeps them reachable,
/// and its header carries Copy and Select Text instead.
private struct ChatRowAccessibility: ViewModifier {
    let row: ChatRow
    let actions: ChatRowActions

    func body(content: Content) -> some View {
        if let text = row.copyText, !row.hasInnerControls {
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
        case .liveTurn: "chat.turn.live"
        case .turn(let id): "chat.turn.\(id.rawValue)"
        case .group(let id): "chat.group.\(id.rawValue)"
        case .liveGroup(let id): "chat.group.live.\(id.rawValue)"
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

/// A turn's header: "Working for 1:05" while it runs, which ticks inside
/// the cell and never changes the row; "Worked for 35s" over a finished
/// turn's folded steps. A hairline closes it, as the answer follows.
private struct ChatTurnHeaderRow: View {
    let header: ChatTurnHeader
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch header.state {
            case .working(let since):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Self.clock(context.date.timeIntervalSince(since))
                    Text("Working for \(elapsed)")
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Working")
                        .accessibilityValue(elapsed)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            case .worked(let duration):
                Button(action: toggle) {
                    HStack(spacing: 4) {
                        Text(Self.title(duration))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(header.isOpen ? 90 : 0))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: header.isOpen)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(header.isOpen ? "Expanded" : "Collapsed")
                .accessibilityHint(
                    "\(header.isOpen ? "Hides" : "Shows") \(header.stepCount == 1 ? "1 step" : "\(header.stepCount) steps")")
            }
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / 3)
                .accessibilityHidden(true)
        }
    }

    /// "Worked for 35s", or "Details" when the records give no duration.
    static func title(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Details" }
        let seconds = max(1, Int(duration.rounded()))
        let formatted = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return "Worked for \(formatted)"
    }

    /// "0:42", "1:05", "1:02:03".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let (hours, minutes, rest) = (seconds / 3_600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Two or more consecutive tool calls as one card: what they did, their
/// lines changed, and whether any is running or failed. Opening it shows
/// each call's own card below it.
private struct ChatToolGroupRow: View {
    let group: ChatToolGroup
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ChatToolRow.symbol(for: group.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(verbatim: group.summary)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let added = group.added, let removed = group.removed {
                    ChatDiffBadge(diff: ChatDiffStats(added: added, removed: removed))
                }
                if group.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else if group.failed > 0 {
                    Label("\(group.failed) failed", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(group.isOpen ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: group.isOpen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(group.isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("\(group.isOpen ? "Hides" : "Shows") \(group.calls == 1 ? "1 call" : "\(group.calls) calls")")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        var parts = [group.summary]
        if let added = group.added, let removed = group.removed { parts.append("\(added) added, \(removed) removed") }
        if group.isRunning {
            parts.append("Running")
        } else if group.failed > 0 {
            parts.append("\(group.failed) failed")
        }
        return parts.joined(separator: ", ")
    }
}

private struct ChatToolRow: View {
    struct TextActions {
        var copy: () -> Void
        var selectText: () -> Void
    }

    let tool: ChatToolActivity
    let isExpanded: Bool
    let expandedFiles: Set<String>
    let missingOutputText: String
    let toggle: () -> Void
    let files: ChatFileActions
    /// Set when the row's own controls keep VoiceOver from reading it as
    /// one element, so the header carries them.
    let textActions: TextActions?

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
                    ChatToolStatusBadge(status: tool.status, exitCode: tool.exitCode, cardAnswer: tool.cardAnswer)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(hint)
            .accessibilityActions {
                if let textActions {
                    Button("Copy", action: textActions.copy)
                    Button("Select Text", action: textActions.selectText)
                }
            }
            if isExpanded {
                details
                    .padding(.leading, 26)
            }
            if let changes = tool.fileChanges, !tool.showsDiffAsOutput {
                ChatFileChangesList(
                    changes: changes, expandedFiles: expandedFiles, read: tool.outputRead,
                    missingOutputText: fileMissingOutputText, actions: files)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 12))
    }

    /// What an open diff says while its lines were never read; nil for a
    /// row with no record to read them from.
    private var fileMissingOutputText: String? {
        tool.output == nil ? nil : missingOutputText
    }

    private var hint: String {
        switch (isExpanded, tool.showsDiffAsOutput) {
        case (true, true): "Hides the diff"
        case (false, true): "Shows the diff"
        case (true, false): "Hides the output"
        case (false, false): "Shows the output"
        }
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
            if tool.showsDiffAsOutput, let changes = tool.fileChanges {
                ForEach(changes.files.indices, id: \.self) { index in
                    let file = changes.files[index]
                    if file.lineCount > 0 {
                        ChatInlineFileDiff(
                            file: file, read: tool.outputRead, missingOutputText: fileMissingOutputText,
                            actions: files)
                    } else {
                        Text("No lines changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let preview = tool.preview {
                if !preview.text.isEmpty {
                    ChatToolOutputText(text: preview.text)
                }
                if preview.imageCount > 0 {
                    Label(
                        preview.imageCount == 1 ? "1 image" : "\(preview.imageCount) images",
                        systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let continuation = Self.continuation(of: preview, read: tool.outputRead) {
                    Text(continuation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let read = tool.outputRead {
                Text(Self.missingPreview(read))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// What follows a preview: the rest loading, why it could not be read,
    /// or where it goes on. A read starts only for a preview cut short.
    private static func continuation(of preview: ChatToolPreview, read: ChatToolActivity.OutputRead?) -> String? {
        switch read {
        case .loading?: "Loading the full output…"
        case .failed(let message)?, .unavailable(let message)?: message
        case .read?, nil: preview.isTruncated ? "Output continues in the terminal." : nil
        }
    }

    /// What a row with no preview says about its read.
    private static func missingPreview(_ read: ChatToolActivity.OutputRead) -> String {
        switch read {
        case .loading: "Loading output…"
        case .read: "No output."
        case .failed(let message), .unavailable(let message): message
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

/// A tool's output text: as tall as the text up to a limit, then scrolling
/// inside, as T3's work log does, so a long output never makes the row a
/// screen tall.
private struct ChatToolOutputText: View {
    let text: String
    @ScaledMetric(relativeTo: .caption) private var maximumHeight: CGFloat = 240

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(uiColor: .tertiarySystemBackground), in: .rect(cornerRadius: 8))
    }
}

struct ChatDiffBadge: View {
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
    /// Set only where the status agrees: `allowed` on a call that ran,
    /// `stopped` on one that didn't.
    var cardAnswer: ChatToolActivity.CardAnswer? = nil

    var body: some View {
        switch status {
        case .running:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Running")
        case .succeeded where cardAnswer != .allowed:
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

    /// A plain success shows only its checkmark, so `succeeded` gets here
    /// only when it was allowed in Chat.
    private var label: String {
        if cardAnswer == .stopped { return "Stopped" }
        switch status {
        case .awaitingApproval: return "Waiting"
        case .succeeded: return "Allowed"
        case .failed: return exitCode.map { "Exit \($0)" } ?? "Failed"
        case .declined: return "Declined"
        case .interrupted: return "Interrupted"
        case .notCompleted: return "Not completed"
        case .noResult: return "No result"
        case .running: return ""
        }
    }

    private var symbol: String {
        if cardAnswer == .stopped { return "stop.circle" }
        switch status {
        case .awaitingApproval: return "hand.raised"
        case .succeeded: return "checkmark"
        case .failed: return "xmark.circle"
        case .declined: return "nosign"
        case .interrupted: return "stop.circle"
        case .notCompleted, .noResult: return "minus.circle"
        case .running: return ""
        }
    }

    private var color: Color {
        if cardAnswer == .stopped { return .secondary }
        switch status {
        case .awaitingApproval, .declined: return .orange
        case .failed: return .red
        default: return .secondary
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
                    } else if let answer = question.queuedAnswer {
                        Label {
                            Text(verbatim: answer)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.subheadline.weight(.medium))
                        Text("Queued. Codex sends it after its next tool call.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
