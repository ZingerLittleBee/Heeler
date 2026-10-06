import CoreGraphics
import Foundation

/// What the timeline is built from.
struct ChatTimelineInput: Sendable {
    var entries: [ChatEntry]
    var pending: [ChatPendingEcho]
    var older: ChatOlderHistory

    init(entries: [ChatEntry] = [], pending: [ChatPendingEcho] = [], older: ChatOlderHistory = .reachedStart) {
        self.entries = entries
        self.pending = pending
        self.older = older
    }
}

/// Turns entries into timeline rows off the main actor.
///
/// Parsing Markdown is the expensive part, so each row keeps what it was
/// built from: an unchanged entry keeps its row, revision and blocks, and an
/// entry whose text did not change keeps its blocks. Revisions come from one
/// counter, so a row that leaves and comes back can never match a height
/// measured for its earlier content.
actor ChatRowBuilder {
    private enum Source: Equatable {
        case entry(ChatEntry.Content)
        case pending(ChatPendingEcho)
        case older(ChatOlderHistory)
    }

    private struct Memo {
        var source: Source
        /// Part of the row's height, so a change is a new revision too.
        var topSpacing: CGFloat
        var revision: Int
        var blocks: [ChatMarkdownBlock]
    }

    private var memos: [ChatRowID: Memo] = [:]
    private var lastRevision = 0

    func rows(for input: ChatTimelineInput) -> [ChatRow] {
        var rows: [ChatRow] = []
        rows.reserveCapacity(input.entries.count + input.pending.count + 1)
        var next: [ChatRowID: Memo] = [:]

        func append(_ id: ChatRowID, _ source: Source) {
            // Diffable data sources raise on duplicate identifiers; the
            // adapters never repeat an id, so a repeat is dropped.
            guard next[id] == nil else {
                assertionFailure("duplicate Chat row \(id)")
                return
            }
            let spacing = Self.spacing(before: Self.content(for: source, blocks: []), after: rows.last?.content)
            let memo: Memo
            if let old = memos[id], old.source == source, old.topSpacing == spacing {
                memo = old
            } else {
                lastRevision += 1
                memo = Memo(
                    source: source, topSpacing: spacing, revision: lastRevision,
                    blocks: Self.blocks(for: source, reusing: memos[id]))
            }
            next[id] = memo
            rows.append(
                ChatRow(
                    id: id, content: Self.content(for: memo.source, blocks: memo.blocks),
                    revision: memo.revision, topSpacing: spacing))
        }

        if input.older != .reachedStart {
            append(.olderHistory, .older(input.older))
        }
        for entry in input.entries {
            append(.entry(entry.id), .entry(entry.content))
        }
        for echo in input.pending {
            append(.pending(echo.id), .pending(echo))
        }
        memos = next
        return rows
    }

    /// Forgets every row, as when the conversation changes.
    func reset() {
        memos = [:]
    }

    private static func markdownSource(of source: Source) -> String? {
        switch source {
        case .entry(.assistant(let message)): message.text
        case .entry(.plan(let plan)): plan.text
        default: nil
        }
    }

    private static func blocks(for source: Source, reusing old: Memo?) -> [ChatMarkdownBlock] {
        guard let text = markdownSource(of: source) else { return [] }
        if let old, markdownSource(of: old.source) == text { return old.blocks }
        return ChatMarkdown.blocks(from: text)
    }

    private static func content(for source: Source, blocks: [ChatMarkdownBlock]) -> ChatRow.Content {
        switch source {
        case .entry(let content):
            switch content {
            case .user(let message): .user(message)
            case .assistant(let message): .assistant(source: message.text, blocks: blocks)
            case .reasoning(let reasoning): .reasoning(reasoning)
            case .tool(let tool): .tool(tool)
            case .plan(let plan): .plan(plan, blocks: blocks)
            case .questions(let set): .questions(set.questions)
            case .notice(let notice): .notice(notice)
            case .divider(let divider): .divider(divider)
            }
        case .pending(let echo): .pending(echo)
        case .older(let older): .olderHistory(older)
        }
    }

    /// A user's message starts a turn and gets the most room; the steps of
    /// one turn (reasoning, tools) sit close together.
    static func spacing(before content: ChatRow.Content, after previous: ChatRow.Content?) -> CGFloat {
        guard let previous else { return 8 }
        switch content {
        case .user, .pending:
            return 24
        case .tool, .reasoning:
            switch previous {
            case .tool, .reasoning: return 4
            default: return 10
            }
        case .divider:
            return 20
        case .olderHistory:
            return 0
        case .assistant, .plan, .questions, .notice:
            return 12
        }
    }
}
