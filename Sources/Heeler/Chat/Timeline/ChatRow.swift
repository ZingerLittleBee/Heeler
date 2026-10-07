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
        case failed(String)
        /// The text stayed in the Agent's input box. Never resent.
        case notDelivered
    }

    let id: UUID
    let text: String
    var state: State
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

    /// What the timeline lays out: a row placed differently is measured
    /// again, and a cell styled differently is configured again.
    var placement: ChatRowPlacement {
        ChatRowPlacement(topSpacing: topSpacing, isNested: isNested, isMuted: isMuted)
    }

    /// Whether the row holds controls besides its own disclosure, which
    /// VoiceOver must reach one by one rather than as one element: changed
    /// files to open, or a diff with View All.
    var hasInnerControls: Bool {
        guard case .tool(let tool) = content, let changes = tool.fileChanges else { return false }
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

    /// What Copy and Select Text take: the whole message as written, the
    /// Markdown source for the model's text. Nil for rows without text.
    var copyText: String? {
        let text: String? =
            switch content {
            case .user(let message): message.displayText
            case .assistant(let source, _): source
            case .reasoning(let reasoning): reasoning.text
            case .tool(let tool):
                [tool.title, tool.subtitle, tool.preview?.text, tool.fileChanges?.copyText]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            case .plan(let plan, _): plan.text
            case .questions(let questions): questions.map(\.text).joined(separator: "\n\n")
            case .notice(let notice): [notice.title, notice.detail].compactMap { $0 }.joined(separator: "\n")
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

/// Consecutive tool calls shown as one summary row (ADR 0021).
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

    init(activity: ChatAgentActivity = .unknown, isBackgroundWorkRunning: Bool = false, foldsFinishedTurns: Bool = true) {
        self.activity = activity
        self.isBackgroundWorkRunning = isBackgroundWorkRunning
        self.foldsFinishedTurns = foldsFinishedTurns
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
    var signals = ChatTurnSignals()

    static let empty = ChatTimelineState(generation: 0, revision: 0, rows: [], isReady: false)
}
