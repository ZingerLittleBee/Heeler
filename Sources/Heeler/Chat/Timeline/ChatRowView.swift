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
            .environment(\.chatImageOpener, imageOpener)
    }

    /// Opens a path the message names in the preview an image row's
    /// thumbnail opens.
    private var imageOpener: ChatImageOpener {
        let actions = actions
        return ChatImageOpener { path in actions.previewImage(path, actions.thumbnails?.image(of: path)) }
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
            if let activity = tool.subagentActivity {
                ChatSubagentActivityRow(activity: activity, isExpanded: isExpanded) { actions.toggle(row.id) }
            } else {
                ChatToolRow(
                    tool: tool, isExpanded: isExpanded, expandedFiles: expandedFiles,
                    missingOutputText: actions.missingOutputText, toggle: { actions.toggle(row.id) },
                    files: fileActions, textActions: row.hasInnerControls ? textActions : nil,
                    thumbnails: actions.thumbnails, previewImage: actions.previewImage)
            }
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
            ChatOlderHistoryRow(older: older, pull: actions.olderPull?.phase ?? .idle, loadOlder: actions.loadOlder)
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
    @Environment(\.chatImageOpener) private var imageOpener

    func body(content: Content) -> some View {
        if let text = row.copyText, !row.hasInnerControls {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
                .accessibilityAction(named: "Copy") { actions.copy(text) }
                .accessibilityAction(named: "Select Text") { actions.selectText(text) }
                .accessibilityActions { imageActions }
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
        }
    }

    /// One action per image the message names, as its links open.
    private var imageActions: some View {
        let opener = imageOpener
        return ForEach(row.messageImagePaths, id: \.self) { @Sendable path in
            Button("Preview \(RemoteHostPath.lastComponent(of: path))") { @MainActor in
                opener?.open(path)
            }
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
    @Environment(\.chatImageOpener) private var imageOpener

    var body: some View {
        ChatBubble {
            VStack(alignment: .trailing, spacing: 6) {
                if let command = message.command {
                    (Text("/\(command.name)").fontDesign(.monospaced).foregroundStyle(.tint)
                        + Text(command.arguments.isEmpty ? "" : " \(command.arguments)"))
                        .font(.body)
                } else {
                    // Image paths open as in the Agent's messages, and so do
                    // the placeholders of images pasted from a file.
                    ChatMarkdownView.text(
                        ChatImageLink.marking(message.text, imagePaths: message.imagePaths), in: .body,
                        opensImages: imageOpener != nil)
                        .font(.body)
                        .chatMessageLinks(opener: imageOpener)
                }
                if message.imageCount > 0 || !message.attachmentLabels.isEmpty || message.wasQueued {
                    ChatAttachmentChips(message: message)
                }
            }
            // One element with one label: a label on the stack alone goes
            // to each child, and VoiceOver read the text once per chip.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    /// "You: text", then what the chips say.
    private var accessibilityLabel: String {
        var parts = [String(localized: "You: \(message.displayText)")]
        if message.imageCount > 0 {
            parts.append(message.imageCount == 1 ? String(localized: "1 image") : String(localized: "\(message.imageCount) images"))
        }
        parts += message.attachmentLabels
        if message.wasQueued { parts.append(String(localized: "Sent while working")) }
        return parts.joined(separator: ", ")
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
            ForEach(message.attachmentLabels.indices, id: \.self) { @Sendable index in
                MainActorContent {
                    Label(message.attachmentLabels[index], systemImage: "paperclip")
                        .lineLimit(1)
                }
            }
            if message.wasQueued {
                Label("Sent while working", systemImage: "clock")
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
            (String(localized: "Sending…"), "arrow.up.circle", .secondary)
        case .sent:
            nil
        case .unconfirmed:
            (String(localized: "Sent. It hasn't appeared in the conversation yet."), "clock", .secondary)
        case .outcomeUnknown:
            (String(localized: "May or may not have reached the Agent. Check the terminal."), "exclamationmark.triangle", .orange)
        case .failed(let reason):
            (String(localized: "Not sent. \(reason)"), "exclamationmark.triangle", .red)
        case .notDelivered:
            (String(localized: "Not delivered. The text is still in the Agent's input box."), "exclamationmark.triangle", .orange)
        case .discarded:
            (String(localized: "Not delivered. It's no longer in the Agent's input box."), "exclamationmark.triangle", .orange)
        case .refused(let refusal):
            (refusal, "info.circle", .secondary)
        case .misdirected:
            (String(localized: "Sent, but the Agent recorded it in another session."), "exclamationmark.triangle", .orange)
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
            return String(localized: "Reasoning")
        }
        let duration = Duration.milliseconds(milliseconds)
        return String(localized: "Thought for \(duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
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
                    let interval = context.date.timeIntervalSince(since)
                    Text("Working for \(Self.clock(interval))")
                        .monospacedDigit()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Working")
                        .accessibilityValue(Self.spoken(interval))
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
                .accessibilityLabel(duration.map { String(localized: "Worked for \(Self.spoken($0))") } ?? String(localized: "Details"))
                .accessibilityValue(header.isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
                .accessibilityHint(Self.hint(isOpen: header.isOpen, steps: header.stepCount))
            }
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / 3)
                .accessibilityHidden(true)
        }
    }

    /// "Shows 3 steps": one whole phrase per state and count, so each
    /// language orders its verb and count.
    static func hint(isOpen: Bool, steps: Int) -> String {
        switch (isOpen, steps == 1) {
        case (true, true): String(localized: "Hides 1 step")
        case (true, false): String(localized: "Hides \(steps) steps")
        case (false, true): String(localized: "Shows 1 step")
        case (false, false): String(localized: "Shows \(steps) steps")
        }
    }

    /// "Worked for 35s", or "Details" when the records give no duration.
    static func title(_ duration: TimeInterval?) -> String {
        guard let duration else { return String(localized: "Details") }
        let seconds = max(1, Int(duration.rounded()))
        let formatted = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return String(localized: "Worked for \(formatted)")
    }

    /// "1 minute, 5 seconds": what VoiceOver reads for a duration.
    static func spoken(_ interval: TimeInterval) -> String {
        Duration.seconds(max(1, Int(interval.rounded())))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
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
    @Environment(\.themeColors) private var themeColors
    let group: ChatToolGroup
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ChatToolKindIcon(kind: group.kind)
                Text(verbatim: group.summary)
                    .font(.subheadline)
                    // At accessibility sizes two lines hold a word or two.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Spacer(minLength: 4)
                if let added = group.added, let removed = group.removed {
                    ChatDiffBadge(diff: ChatDiffStats(added: added, removed: removed))
                }
                if group.isRunning {
                    ChatRunningSpinner()
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
            .background(themeColors.raised, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(group.isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    /// "Shows 3 calls": one whole phrase per state and count.
    private var hint: String {
        switch (group.isOpen, group.calls == 1) {
        case (true, true): String(localized: "Hides 1 call")
        case (true, false): String(localized: "Hides \(group.calls) calls")
        case (false, true): String(localized: "Shows 1 call")
        case (false, false): String(localized: "Shows \(group.calls) calls")
        }
    }

    private var accessibilityLabel: String {
        var parts = [group.summary]
        if let added = group.added, let removed = group.removed {
            parts.append(String(localized: "\(added) added, \(removed) removed"))
        }
        if group.isRunning {
            parts.append(String(localized: "Running"))
        } else if group.failed > 0 {
            parts.append(String(localized: "\(group.failed) failed"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Recorded lifecycle events, not successful tool calls or a live worker status.
struct ChatSubagentPresentation {
    static let icon = Image("LucideBot").renderingMode(.template)
    let activity: ChatSubagentActivity

    var name: String {
        activity.agentPath?.split(separator: "/").last.map(String.init) ?? String(localized: "Unnamed subagent")
    }

    var status: String { Self.label(for: activity.events.last ?? "unknown") }
    var eventCount: String {
        activity.events.count == 1
            ? String(localized: "1 event") : String(localized: "\(activity.events.count) events")
    }

    var copyText: String {
        ([String(localized: "Subagent: \(name)"), activity.agentPath].compactMap { $0 }
            + history.map(\.label)).joined(separator: "\n")
    }

    struct EventRun: Identifiable {
        let id: Int
        let kind: String
        var count: Int

        var label: String {
            let label = ChatSubagentPresentation.label(for: kind)
            return count == 1 ? label : "\(label) ×\(count)"
        }
    }

    /// Repeated message exchanges stay available without another wall of rows.
    var history: [EventRun] {
        var runs: [EventRun] = []
        for (index, kind) in activity.events.enumerated() {
            if runs.last?.kind == kind {
                runs[runs.count - 1].count += 1
            } else {
                runs.append(EventRun(id: index, kind: kind, count: 1))
            }
        }
        return runs
    }

    /// What a recorded event says. `kind` is the record's own word, matched
    /// as written; only the label is in the app's language.
    static func label(for kind: String) -> String {
        switch kind {
        case "started": String(localized: "Started")
        case "interacted": String(localized: "Message exchanged")
        case "completed": String(localized: "Completed")
        case "interrupted": String(localized: "Interrupted")
        default: String(localized: "Activity recorded")
        }
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "started": "play.circle"
        case "interacted": "bubble.left.and.bubble.right"
        case "completed": "checkmark.circle"
        case "interrupted": "pause.circle"
        default: "ellipsis.circle"
        }
    }
}

private struct ChatSubagentActivityRow: View {
    @Environment(\.themeColors) private var themeColors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 24
    @ScaledMetric(relativeTo: .subheadline) private var titleCapHeight = UIFont.systemFont(ofSize: 15).capHeight
    let activity: ChatSubagentActivity
    let isExpanded: Bool
    let toggle: () -> Void

    private var presentation: ChatSubagentPresentation { ChatSubagentPresentation(activity: activity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        agentIcon.frame(width: displayedIconWidth, height: displayedIconWidth)
                            .alignmentGuide(.firstTextBaseline) { [titleCapHeight] dimensions in
                                dimensions[VerticalAlignment.center] + titleCapHeight / 2
                            }
                        Text(verbatim: presentation.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(isExpanded ? nil : 2)
                        Spacer(minLength: 4)
                        disclosureIcon
                    }
                    Text("\(presentation.status) · \(presentation.eventCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, detailIndent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Subagent, \(presentation.name)")
            .accessibilityValue(
                [
                    presentation.status, presentation.eventCount,
                    isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"),
                ].joined(separator: ", "))
            .accessibilityHint(isExpanded ? String(localized: "Hides activity history") : String(localized: "Shows activity history"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let path = activity.agentPath, !path.isEmpty {
                        Text(verbatim: path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(presentation.history) { @Sendable event in
                        MainActorContent {
                            Label(event.label, systemImage: ChatSubagentPresentation.symbol(for: event.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, detailIndent)
            }
        }
        .padding(12)
        .background(themeColors.raised, in: .rect(cornerRadius: 12))
    }

    private var agentIcon: some View {
        ChatSubagentPresentation.icon
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var displayedIconWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : iconWidth
    }

    private var detailIndent: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 0 : displayedIconWidth + 10
    }

    private var disclosureIcon: some View {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

}

private struct ChatToolRow: View {
    @Environment(\.themeColors) private var themeColors
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
    let thumbnails: ChatImageThumbnails?
    let previewImage: @MainActor (String, UIImage?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // A read that showed an image reads as one.
                        ChatToolKindIcon(kind: tool.imagePath == nil ? tool.kind : .image)
                        Text(verbatim: tool.title)
                            .font(.subheadline)
                            .modifier(ChatFontDesign(isCode: titleIsCode))
                            .lineLimit(isExpanded ? nil : 2)
                        Spacer(minLength: 4)
                        if let diff = tool.diff {
                            ChatDiffBadge(diff: diff)
                        }
                        ChatToolStatusBadge(
                            status: tool.status, exitCode: tool.exitCode, cardAnswer: tool.cardAnswer,
                            isNotUpdating: tool.isNotUpdating)
                    }
                    if let subtitle = tool.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.caption)
                            .modifier(ChatFontDesign(isCode: subtitleIsCode))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .padding(.leading, 26)
                    }
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
            if let path = tool.imagePath {
                ChatImageThumbnail(path: path, thumbnails: thumbnails) { previewImage(path, $0) }
                    .padding(.leading, 26)
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
        .background(themeColors.raised, in: .rect(cornerRadius: 12))
    }

    /// What an open diff says while its lines were never read; nil for a
    /// row with no record to read them from.
    private var fileMissingOutputText: String? {
        tool.output == nil ? nil : missingOutputText
    }

    /// A call that never ran has no output: expanding it shows the whole
    /// call and any note or questions.
    private var hint: String {
        switch (isExpanded, tool.showsDiffAsOutput, tool.ran) {
        case (true, true, _): String(localized: "Hides the diff")
        case (false, true, _): String(localized: "Shows the diff")
        case (true, false, true): String(localized: "Hides the output")
        case (false, false, true): String(localized: "Shows the output")
        case (true, false, false): String(localized: "Hides the details")
        case (false, false, false): String(localized: "Shows the details")
        }
    }

    /// Commands, paths and patterns read as code. A command row with a
    /// subtitle is titled by its description, and the command moves below.
    private var titleIsCode: Bool {
        switch tool.kind {
        case .command: tool.subtitle?.isEmpty ?? true
        case .fileEdit, .fileWrite, .fileRead, .search, .listing: true
        default: false
        }
    }

    private var subtitleIsCode: Bool {
        switch tool.kind {
        case .command, .fileEdit, .fileWrite, .fileRead, .search, .listing: true
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
                ForEach(changes.files.indices, id: \.self) { @Sendable index in
                    MainActorContent {
                        let file = changes.files[index]
                        if changes.files.count > 1 {
                            ChatFileDiffHeading(file: file, path: changes.displayPath(of: file))
                        }
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
                if let text = Self.missingPreview(read, didRun: tool.ran) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !tool.ran {
                // A call that never ran has no output to speak of.
                EmptyView()
            } else if tool.output != nil {
                Text(missingOutputText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if tool.questions.isEmpty, tool.note == nil {
                Text(Self.noOutputText(for: tool))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What follows a preview: the rest loading, why it could not be read,
    /// or where it goes on. A read starts only for a preview cut short.
    private static func continuation(of preview: ChatToolPreview, read: ChatToolActivity.OutputRead?) -> String? {
        switch read {
        case .loading?: String(localized: "Loading the full output…")
        case .failed(let message)?, .unavailable(let message)?: message
        case .read?, nil: preview.isTruncated ? String(localized: "Output continues in the terminal.") : nil
        }
    }

    /// What a row with nothing to read says: a call running when last seen
    /// may have printed since.
    private static func noOutputText(for tool: ChatToolActivity) -> String {
        guard tool.status == .running else { return String(localized: "No output.") }
        return tool.isNotUpdating ? String(localized: "No output when last seen.") : String(localized: "Running…")
    }

    /// What a row with no preview says about its read; nil when the read
    /// found nothing for a call that never ran.
    private static func missingPreview(_ read: ChatToolActivity.OutputRead, didRun: Bool) -> String? {
        switch read {
        case .loading: String(localized: "Loading output…")
        case .read: didRun ? String(localized: "No output.") : nil
        case .failed(let message), .unavailable(let message): message
        }
    }

    static func icon(for kind: ChatToolActivity.Kind) -> Image {
        switch kind {
        case .command: Image(systemName: "terminal")
        case .fileEdit: Image(systemName: "pencil")
        case .fileWrite: Image(systemName: "doc.badge.plus")
        case .fileRead: Image(systemName: "doc.text")
        case .search, .listing: Image(systemName: "magnifyingglass")
        case .web: Image(systemName: "globe")
        case .agent: ChatSubagentPresentation.icon
        case .question: Image(systemName: "questionmark.bubble")
        case .todo: Image(systemName: "checklist")
        case .mcp: Image(systemName: "puzzlepiece.extension")
        case .image: Image(systemName: "photo")
        case .other: Image(systemName: "wrench.and.screwdriver")
        }
    }
}

/// A tool kind's glyph beside a row title set on its first baseline. A
/// symbol carries its own baseline; the bot is an asset with none, which
/// would rest its bottom edge on the baseline and ride above the text, so
/// it centres on the title's capitals instead.
private struct ChatToolKindIcon: View {
    @ScaledMetric(relativeTo: .subheadline) private var titleCapHeight = UIFont.systemFont(ofSize: 15).capHeight
    let kind: ChatToolActivity.Kind

    var body: some View {
        let icon = ChatToolRow.icon(for: kind)
            .foregroundStyle(.secondary)
            .frame(width: 18)
        if case .agent = kind {
            icon.alignmentGuide(.firstTextBaseline) { [titleCapHeight] dimensions in
                dimensions[VerticalAlignment.center] + titleCapHeight / 2
            }
        } else {
            icon
        }
    }
}

/// A tool's output text: as tall as the text up to a limit, then scrolling
/// inside, so a long output never makes the row a screen tall.
private struct ChatToolOutputText: View {
    @Environment(\.themeColors) private var themeColors
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
        .background(themeColors.background, in: .rect(cornerRadius: 8))
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

/// A spinner over a hidden subheadline glyph, so a first-text-baseline row
/// aligns it with the title's first line. The spinner's own baseline drops
/// it below that line.
private struct ChatRunningSpinner: View {
    var body: some View {
        Text(Image(systemName: "circle"))
            .font(.subheadline)
            .hidden()
            .overlay {
                ProgressView()
                    .controlSize(.mini)
            }
    }
}

private struct ChatToolStatusBadge: View {
    let status: ChatToolActivity.Status
    let exitCode: Int?
    /// Set only where the status agrees: `allowed` on a call that ran,
    /// `stopped` on one that didn't.
    var cardAnswer: ChatToolActivity.CardAnswer? = nil
    /// A running call shown while nothing live backs the timeline.
    var isNotUpdating = false

    var body: some View {
        switch status {
        case .running where isNotUpdating:
            Label("Running when last seen", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .running:
            ChatRunningSpinner()
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
        if cardAnswer == .stopped { return String(localized: "Stopped") }
        switch status {
        case .awaitingApproval: return String(localized: "Waiting")
        case .succeeded: return String(localized: "Allowed")
        case .failed: return exitCode.map { String(localized: "Exit \($0)") } ?? String(localized: "Failed")
        case .declined: return String(localized: "Declined")
        case .interrupted: return String(localized: "Interrupted")
        case .notCompleted: return String(localized: "Not completed")
        case .noResult: return String(localized: "No result")
        case .started: return String(localized: "Started")
        case .chatInstead: return String(localized: "Chat Instead")
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
        case .started: return "arrow.up.forward.circle"
        case .chatInstead: return "bubble.left.and.bubble.right"
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
    @Environment(\.themeColors) private var themeColors
    let plan: ChatPlan
    let blocks: [ChatMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard")
                Text("Plan")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                ChatToolStatusBadge(status: plan.status, exitCode: nil, cardAnswer: plan.cardAnswer)
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
        .background(themeColors.raised, in: .rect(cornerRadius: 12))
    }
}

private struct ChatQuestionsView: View {
    let questions: [ChatQuestion]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(questions.indices, id: \.self) { @Sendable index in
                MainActorContent {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatNoticeRow: View {
    let notice: ChatNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = notice.userCommandText {
                ChatBubble {
                    Text(verbatim: command)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("You: \(command)")
                }
            } else {
                Label {
                    Text(verbatim: notice.title)
                } icon: {
                    Image(systemName: symbol)
                }
                .font(.footnote)
            }
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
        case .pythonCommand: "chevron.left.forwardslash.chevron.right"
        case .taskNotification: "bell"
        case .interrupted: "stop.circle"
        case .stopped: "pause.circle"
        case .error: "exclamationmark.triangle"
        case .modelChange: "cpu"
        case .planMode: "list.bullet.clipboard"
        case .hook: "link"
        case .review: "eye"
        case .answered: "checkmark.bubble"
        case .scheduledTask: "clock.arrow.circlepath"
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
                    .lineLimit(ChatDivider.previewLines)
                    .multilineTextAlignment(.center)
            }
        }
        // The preview's lines, not the whole summary the detail holds.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [title, divider.accessibilityPreview].compactMap { $0 }.joined(separator: ", ")))
    }

    private var line: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / 3)
            .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch divider.kind {
        case .compaction: String(localized: "Context compacted")
        case .historyUnavailable: String(localized: "Earlier messages couldn't be read")
        }
    }
}

private struct ChatOlderHistoryRow: View {
    let older: ChatOlderHistory
    let pull: ChatOlderPull.Phase
    let loadOlder: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch older {
            case .available where pull == .requested, .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading earlier messages")
            case .available where pull != .idle:
                // Pulling flips the arrow once letting go would load.
                Label {
                    Text(pull == .armed ? String(localized: "Release to load earlier messages") : String(localized: "Pull to load earlier messages"))
                } icon: {
                    Image(systemName: "arrow.down")
                        .rotationEffect(.degrees(pull == .armed ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pull)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            case .available:
                Button("Load Earlier Messages", action: loadOlder)
                    .font(.footnote)
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
