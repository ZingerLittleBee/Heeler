import CoreGraphics
import Foundation

/// One row's identity in the Chat timeline.
enum ChatRowID: Hashable, Sendable {
    /// A transcript entry.
    case entry(ChatEntryID)
    /// A message sent from Chat that the transcript does not show yet.
    case pending(UUID)
    /// The top row while earlier history can load, is loading, or failed.
    case olderHistory
    /// The running turn's header. Only the newest turn runs.
    case liveTurn
    /// A finished turn's fold, by the first entry of its final answer,
    /// which earlier history arriving above does not move.
    case turn(ChatEntryID)
    /// A settled tool group, by its last call: only earlier history can
    /// add calls to it, and those come before.
    case group(ChatEntryID)
    /// A running tool group, by its first call: it grows at its end. Kept
    /// apart from the settled id, so a group opened while it ran settles
    /// closed.
    case liveGroup(ChatEntryID)

    /// Whether the row folds others away rather than showing an entry.
    var isHeader: Bool {
        switch self {
        case .liveTurn, .turn, .group, .liveGroup: true
        case .entry, .pending, .olderHistory: false
        }
    }
}

/// A message sent from Chat, shown at the end of the timeline until the
/// transcript records it.
struct ChatPendingEcho: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case sending
        case sent
        /// Sent a while ago, and the transcript still does not show it.
        case unconfirmed
        /// A herdr-core step got no answer, so it may or may not have reached
        /// the Agent, and the transcript does not show it.
        case outcomeUnknown
        case failed(String)
        /// The text stayed in the Agent's input box. Never resent.
        case notDelivered
        /// The text went back to the Agent's input box and has left it
        /// since, never delivered.
        case discarded
        /// Delivered, and the program declined it on screen, as given here.
        case refused(String)
        /// Delivered, and the program recorded it in another session.
        case misdirected
    }

    let id: UUID
    let text: String
    var state: State
    var stagedImagePaths: [String] = []
}

/// One row of the timeline, ready to draw. Assistant Markdown is parsed
/// before the row reaches the main actor.
struct ChatRow: Identifiable, Sendable {
    enum Content: Sendable {
        case user(ChatUserMessage)
        case assistant(source: String, blocks: [ChatMarkdownBlock])
        case reasoning(ChatReasoning)
        case tool(ChatToolActivity)
        case plan(ChatPlan, blocks: [ChatMarkdownBlock])
        case questions([ChatQuestion])
        case notice(ChatNotice)
        case divider(ChatDivider)
        case pending(ChatPendingEcho)
        case olderHistory(ChatOlderHistory)
        case turnHeader(ChatTurnHeader)
        case toolGroup(ChatToolGroup)
    }

    let id: ChatRowID
    let content: Content
    /// Changes exactly when `content` does, so a height measured for one
    /// revision is never taken for another.
    let revision: Int
    /// Space above the row: tight within a turn, looser between turns.
    var topSpacing: CGFloat
    /// Shown inside an open tool group, under its header.
    var isNested = false
    /// The model's text inside an open turn fold, which reads as the
    /// process rather than the answer.
    var isMuted = false
    /// Pre-marked `AttributedString` for user and pending bubbles, computed
    /// off `@MainActor` in `ChatRowBuilder`.
    var precomputedMarkedText: AttributedString? = nil
    /// Pre-extracted image/video references, computed off `@MainActor` in
    /// `ChatRowBuilder`.
    var precomputedMessageImages: [ChatImageLink.Reference]? = nil
    /// Pre-built inline file diffs (up to `ChatFileChanges.rowLimits`) keyed
    /// by recorded file path, computed off `@MainActor` in `ChatRowBuilder`.
    var precomputedInlineDiffs: [String: ChatFileDiff] = [:]

    var seed: ChatRowSeed {
        switch content {
        case .user: .user
        case .assistant, .plan, .questions: .assistant
        case .reasoning: .reasoning
        case .tool: .tool
        case .notice, .divider, .turnHeader: .system
        case .pending: .pending
        case .olderHistory: .olderStatus
        case .toolGroup: .tool
        }
    }

    /// The text the row wraps, for the layout's first guess at its height.
    /// Nil for a row whose height does not follow its text: a plain tool call
    /// stays a line or two whatever it ran.
    var extent: ChatRowExtent? {
        switch content {
        case .assistant(let source, let blocks):
            return ChatRowExtent(
                textBytes: source.utf8.count, blocks: blocks.count, chrome: topSpacing,
                minimumLines: Self.minimumLines(in: blocks))
        case .plan(let plan, let blocks):
            // The card's padding and its title line.
            return ChatRowExtent(
                textBytes: plan.text.utf8.count, blocks: blocks.count, chrome: topSpacing + 56, inset: 24,
                minimumLines: Self.minimumLines(in: blocks))
        case .user(let message):
            let chipChrome: CGFloat =
                (message.imageCount > 0 || !message.attachmentLabels.isEmpty || message.delivery == .queued) ? 22 : 0
            if message.command == nil {
                // The bubble's padding, and the room it leaves at the leading edge.
                return ChatRowExtent(
                    textBytes: ChatImageLink.displayedByteCount(of: message.text, imagePaths: message.imagePaths),
                    blocks: 1, chrome: topSpacing + 20 + chipChrome, inset: 76,
                    minimumLines: Self.explicitNewlineLines(in: message.text))
            } else {
                let text = message.displayText
                return ChatRowExtent(
                    textBytes: text.utf8.count, blocks: 1, chrome: topSpacing + 20 + chipChrome, inset: 76,
                    minimumLines: Self.explicitNewlineLines(in: text))
            }
        case .pending(let echo):
            let statusChrome: CGFloat = echo.state == .sent ? 0 : 22
            return ChatRowExtent(
                textBytes: echo.text.utf8.count, blocks: 1, chrome: topSpacing + 20 + statusChrome, inset: 76,
                minimumLines: Self.explicitNewlineLines(in: echo.text))
        case .tool(let tool):
            if tool.subagentActivity != nil {
                return ChatRowExtent(textBytes: 0, blocks: 1, chrome: topSpacing + 46)
            }
            let inlineFileRows: Int
            if let changes = tool.fileChanges, !tool.showsDiffAsOutput {
                inlineFileRows = changes.soleNote != nil ? 1 : (changes.files.count + changes.notes.count)
            } else {
                inlineFileRows = 0
            }
            if tool.imagePath != nil {
                return ChatRowExtent(
                    textBytes: 0, blocks: 1, chrome: topSpacing + 186 + CGFloat(inlineFileRows) * 24)
            }
            if inlineFileRows > 0 {
                return ChatRowExtent(textBytes: 0, blocks: 1, chrome: topSpacing + 6 + CGFloat(inlineFileRows) * 24)
            }
            return nil
        case .questions(let questions) where !questions.isEmpty:
            let bytes = questions.reduce(0) { $0 + $1.text.utf8.count + ($1.answer?.utf8.count ?? 0) }
            return ChatRowExtent(
                textBytes: bytes, blocks: questions.count, chrome: topSpacing + CGFloat(questions.count) * 18)
        case .notice(let notice):
            if let command = notice.userCommandText {
                let detailChrome: CGFloat = (notice.detail?.isEmpty == false) ? 36 : 0
                return ChatRowExtent(
                    textBytes: command.utf8.count, blocks: 1, chrome: topSpacing + 20 + detailChrome, inset: 76)
            }
            if (notice.detail?.isEmpty == false) || !notice.questions.isEmpty {
                let detailBytes = min(notice.detail?.utf8.count ?? 0, 360)
                let questionBytes = notice.questions.reduce(0) { $0 + $1.text.utf8.count }
                return ChatRowExtent(
                    textBytes: detailBytes + questionBytes,
                    blocks: max(1, 1 + notice.questions.count), chrome: topSpacing + 18, inset: 24)
            }
            return nil
        case .divider(let divider):
            if divider.kind == .compaction, let detail = divider.detail, !detail.isEmpty {
                return ChatRowExtent(textBytes: min(detail.utf8.count, 220), blocks: 1, chrome: topSpacing + 20)
            }
            return nil
        default:
            return nil
        }
    }

    private static func minimumLines(in blocks: [ChatMarkdownBlock]) -> Int {
        var sawHardStructure = false
        var total = 0
        for block in blocks {
            switch block.kind {
            case .code, .html:
                sawHardStructure = true
                total += 1 + block.text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            case .table:
                sawHardStructure = true
                total += max(1, (block.table?.rows.count ?? 1) * 2)
            case .thematicBreak:
                total += 1
            case .paragraph, .heading, .listItem:
                let breaks = block.text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                if breaks > 0 { sawHardStructure = true }
                total += 1 + breaks
            }
        }
        return sawHardStructure ? total : 0
    }

    private static func explicitNewlineLines(in text: String) -> Int {
        let breaks = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return breaks >= 2 ? (1 + breaks) : 0
    }

    /// What the timeline lays out: a row placed differently is measured
    /// again, and a cell styled differently is configured again.
    var placement: ChatRowPlacement {
        ChatRowPlacement(topSpacing: topSpacing, isNested: isNested, isMuted: isMuted)
    }

    /// Whether the row holds controls besides its own disclosure, which
    /// VoiceOver must reach one by one rather than as one element: changed
    /// files to open, a diff with View All, or an image to open.
    var hasInnerControls: Bool {
        guard case .tool(let tool) = content else { return false }
        if tool.imagePath != nil { return true }
        guard let changes = tool.fileChanges else { return false }
        return tool.showsDiffAsOutput || !changes.files.isEmpty
    }

    /// Whether a tap shows more of the row.
    var isExpandable: Bool {
        switch content {
        case .tool, .toolGroup: true
        case .reasoning(let reasoning): !reasoning.text.isEmpty
        case .turnHeader(let header): header.isFoldable
        default: false
        }
    }

    /// Whether the row is a message or command the user sent.
    var isUserMessage: Bool {
        switch content {
        case .user, .pending:
            true
        case .notice(let notice):
            notice.userCommandText != nil
        default:
            false
        }
    }

    var imagePath: String? {
        guard case .tool(let tool) = content else { return nil }
        return tool.imagePath
    }

    /// The image files the row's message names by path or carried, each path
    /// once in reading order, with any numbered display title (`ChatImageLink`).
    var messageImages: [ChatImageLink.Reference] {
        if let precomputedMessageImages { return precomputedMessageImages }
        return Self.computeMessageImages(for: content, markedText: precomputedMarkedText)
    }

    static func computeMarkedText(for content: Content) -> AttributedString? {
        switch content {
        case .user(let message):
            if let command = message.command {
                return command.arguments.isEmpty
                    ? AttributedString()
                    : ChatImageLink.marking(command.arguments, imagePaths: message.imagePaths)
            }
            return ChatImageLink.marking(message.text, imagePaths: message.imagePaths)
        case .pending(let echo):
            return ChatImageLink.marking(echo.text, stagedImagePaths: echo.stagedImagePaths)
        default:
            return nil
        }
    }

    static func computeMessageImages(
        for content: Content, markedText: AttributedString? = nil
    ) -> [ChatImageLink.Reference] {
        switch content {
        case .user(let message):
            let sourceText = message.command?.arguments ?? message.text
            let linked: [ChatImageLink.Reference]
            if sourceText.isEmpty {
                linked = []
            } else if let markedText {
                linked = ChatImageLink.references(in: markedText)
            } else {
                linked = ChatImageLink.references(
                    in: ChatImageLink.marking(sourceText, imagePaths: message.imagePaths))
            }
            var seen = Set(linked.map(\.path))
            var nextImageNumber = linked.filter { $0.mediaKind == .image }.count + 1
            var nextVideoNumber = linked.filter { $0.mediaKind == .video }.count + 1
            var extras: [ChatImageLink.Reference] = []
            for path in message.imagePaths where seen.insert(path).inserted {
                let title: String?
                if ChatImageLink.isStagedVideoPath(path) {
                    title = ChatImageLink.stagedVideoLabel(number: nextVideoNumber)
                    nextVideoNumber += 1
                } else if ChatImageLink.isStagedImagePath(path) {
                    title = ChatImageLink.stagedImageLabel(number: nextImageNumber)
                    nextImageNumber += 1
                } else {
                    title = nil
                }
                extras.append(ChatImageLink.Reference(path: path, title: title))
            }
            return linked + extras
        case .pending(let echo):
            let marked = markedText ?? ChatImageLink.marking(echo.text, stagedImagePaths: echo.stagedImagePaths)
            return ChatImageLink.references(in: marked)
        case .assistant(_, let blocks), .plan(_, let blocks):
            guard blocks.contains(where: { $0.hasImageLinks || $0.table?.hasImageLinks == true }) else {
                return []
            }
            var seen: Set<String> = []
            var results: [ChatImageLink.Reference] = []
            for block in blocks {
                if block.hasImageLinks {
                    for ref in ChatImageLink.references(in: block.content) where seen.insert(ref.path).inserted {
                        results.append(ref)
                    }
                }
                if let table = block.table, table.hasImageLinks {
                    for tableRow in table.rows {
                        for cell in tableRow {
                            for ref in ChatImageLink.references(in: cell) where seen.insert(ref.path).inserted {
                                results.append(ref)
                            }
                        }
                    }
                }
            }
            return results
        default:
            return []
        }
    }

    static func computeInlineDiffs(for content: Content) -> [String: ChatFileDiff] {
        guard case .tool(let tool) = content, let changes = tool.fileChanges, !changes.files.isEmpty else {
            return [:]
        }
        var diffs: [String: ChatFileDiff] = [:]
        diffs.reserveCapacity(changes.files.count)
        for file in changes.files where file.lineCount > 0 && !file.hunks.isEmpty {
            diffs[file.path] = ChatFileDiff(file.keeping(ChatFileChanges.rowLimits))
        }
        return diffs
    }

    /// The image files the row's message names by path or carried, as
    /// written and each once (`ChatImageLink`).
    var messageImagePaths: [String] {
        messageImages.map(\.path)
    }

    /// What Copy and Select Text take: the whole message as written, the
    /// Markdown source for the model's text. Nil for rows without text.
    var copyText: String? {
        let text: String? =
            switch content {
            case .user(let message): message.displayText
            case .assistant(let source, _): source
            case .reasoning(let reasoning): reasoning.text
            case .tool(let tool):
                if let activity = tool.subagentActivity {
                    ChatSubagentPresentation(activity: activity).copyText
                } else {
                    [tool.title, tool.subtitle, tool.preview?.text, tool.fileChanges?.copyText]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                }
            case .plan(let plan, _): plan.text
            case .questions(let questions): questions.map(\.text).joined(separator: "\n\n")
            case .notice(let notice):
                [notice.title, notice.rawDetail ?? notice.detail].compactMap { $0 }.joined(separator: "\n")
            case .pending(let echo): echo.text
            case .toolGroup(let group): group.summary
            case .divider, .olderHistory, .turnHeader: nil
            }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

struct ChatRowPlacement: Hashable, Sendable {
    var topSpacing: CGFloat
    var isNested: Bool
    var isMuted: Bool
}

/// The header of a turn: how long the running turn has worked, or the
/// fold over a finished turn's steps above its final answer.
struct ChatTurnHeader: Hashable, Sendable {
    enum State: Hashable, Sendable {
        /// The turn runs; the header counts up from its start.
        case working(since: Date)
        /// The turn finished; nil when its records give no duration.
        case worked(TimeInterval?)
    }

    var state: State
    var isOpen: Bool
    /// The rows the fold holds.
    var stepCount: Int

    var isFoldable: Bool {
        if case .worked = state { true } else { false }
    }
}

/// Consecutive tool calls shown as one summary row (ADR 0024).
struct ChatToolGroup: Hashable, Sendable {
    /// "Ran 2 commands, Edited 2 files".
    var summary: String
    /// The first call's kind, whose symbol the header shows.
    var kind: ChatToolActivity.Kind
    /// Lines added and removed across the calls, nil when none recorded any.
    var added: Int?
    var removed: Int?
    /// Calls that failed, were declined, interrupted or not completed.
    var failed: Int
    var isRunning: Bool
    var calls: Int
    var isOpen: Bool
}

/// What decides how a turn shows: whether the newest one still runs, and
/// whether finished ones fold.
struct ChatTurnSignals: Equatable, Sendable {
    var activity: ChatAgentActivity
    /// Background Work still runs, which keeps the newest turn open.
    var isBackgroundWorkRunning: Bool
    /// The Fold Finished Turns setting.
    var foldsFinishedTurns: Bool
    /// The Host is connected and the rows come from it, not only from the
    /// device. Otherwise they read as last seen: no turn runs, and no call
    /// spins.
    var isLive: Bool
    /// Earlier messages load only when the user asks
    /// (`ChatConversationSnapshot.olderAwaitsUser`), so the turn whose start
    /// they hold reads as finished as far as it is loaded.
    var olderAwaitsUser: Bool

    init(
        activity: ChatAgentActivity = .unknown, isBackgroundWorkRunning: Bool = false, foldsFinishedTurns: Bool = true,
        isLive: Bool = true, olderAwaitsUser: Bool = false
    ) {
        self.activity = activity
        self.isBackgroundWorkRunning = isBackgroundWorkRunning
        self.foldsFinishedTurns = foldsFinishedTurns
        self.isLive = isLive
        self.olderAwaitsUser = olderAwaitsUser
    }

    /// Whether something live backs the rows: the Host is connected and the
    /// conversation came from it on this visit. A failed read alone keeps
    /// them live, so one missed poll doesn't flicker them.
    static func isLive(hostStatus: EventsSessionStatus?, conversation: ChatConversationSnapshot) -> Bool {
        hostStatus == .connected && !conversation.isFromCache
    }
}

/// What the timeline shows. `generation` changes when the conversation does,
/// which reloads the list at its end instead of diffing into it.
struct ChatTimelineState: Sendable {
    var generation: Int
    /// Bumped on every change, so an unchanged state applies as nothing.
    var revision: Int
    /// One row per entry and pending message, before any fold.
    var rows: [ChatRow]
    /// True once the first content (saved or read from the Host) is in.
    var isReady: Bool
    /// The turns the transcript records, oldest first.
    var turns: [ChatTurn] = []
    /// How the turn the rows open inside ended, when they record it.
    var precedingTurnEnd: ChatTurnEnd?
    var signals = ChatTurnSignals()

    static let empty = ChatTimelineState(generation: 0, revision: 0, rows: [], isReady: false)
}
