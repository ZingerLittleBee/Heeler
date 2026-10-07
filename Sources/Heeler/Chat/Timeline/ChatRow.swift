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
    }

    let id: ChatRowID
    let content: Content
    /// Changes exactly when `content` does, so a height measured for one
    /// revision is never taken for another.
    let revision: Int
    /// Space above the row: tight within a turn, looser between turns.
    let topSpacing: CGFloat

    var seed: ChatRowSeed {
        switch content {
        case .user: .user
        case .assistant, .plan, .questions: .assistant
        case .reasoning: .reasoning
        case .tool: .tool
        case .notice, .divider: .system
        case .pending: .pending
        case .olderHistory: .olderStatus
        }
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
        case .tool: true
        case .reasoning(let reasoning): !reasoning.text.isEmpty
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
            case .divider, .olderHistory: nil
            }
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

/// What the timeline shows. `generation` changes when the conversation does,
/// which reloads the list at its end instead of diffing into it.
struct ChatTimelineState: Sendable {
    var generation: Int
    /// Bumped on every change, so an unchanged state applies as nothing.
    var revision: Int
    var rows: [ChatRow]
    /// True once the first content (saved or read from the Host) is in.
    var isReady: Bool

    static let empty = ChatTimelineState(generation: 0, revision: 0, rows: [], isReady: false)
}
