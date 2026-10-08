import Foundation

/// Ordinal anomalies in a paginated rollout. None of them is fatal; Codex
/// skips the same lines and logs the same counts
/// (`thread_history_materialization.rs`).
struct CodexOrdinalDiagnostics: Equatable, Sendable {
    /// Accepted lines without an ordinal.
    var missing = 0
    /// Lines whose ordinal was already taken: the first line wins.
    var duplicates = 0
    /// Places where ordinals skip ahead.
    var gaps = 0
    /// Lines before `subagent_history_start_ordinal`, the subagent's own
    /// header included: history it inherited from its parent. Accepted,
    /// never shown.
    var inherited = 0
}

/// Rebuilds a paginated rollout's turns the way Codex materializes them.
///
/// Ordinal hygiene mirrors `thread_history_materialization.rs`: a line
/// Codex rejects (torn JSON, an unknown record or item type) takes no
/// ordinal, so a crash fragment and the complete record rewritten after it
/// can share one; a repeated ordinal keeps its first line; a gap is only
/// counted. Projection mirrors `thread_history_projection.rs` and the
/// thread store: a turn sorts by the first line that names it and keeps the
/// first terminal status its segment records; an item keeps the position
/// of its first snapshot and the content of its latest, in the turn its
/// line names, however late it arrives.
///
/// Response items are never rows (their `item_completed` twins are). The
/// exception is the sync `request_user_input` call, which has no turn item:
/// its question row pairs the call with the `verified_answer` or tool
/// output by `call_id`.
struct CodexPaginatedBuilder {
    /// Orders lines across segments: older segments first, then file order.
    private struct Position: Comparable {
        var segment: Int
        var offset: UInt64

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.segment, lhs.offset) < (rhs.segment, rhs.offset)
        }
    }

    private struct Item {
        var position: Position
        var entry: CodexTimelineEntry
        /// Set for a sync question row, whose content is built at the end
        /// from everything that answered it.
        var question: CodexQuestionBuild?
    }

    private struct Turn {
        var id: String
        var position: Position
        var status: CodexTurnStatus?
        /// The segment whose line set `status`: a newer segment's status
        /// replaces an older one's even when that one was terminal.
        var statusSegment = -1
        var ending: CodexTimelineEntry?
        var items: [String: Item] = [:]
        var startedAt: Date?
        var endedAt: Date?
        /// A loaded line started the turn.
        var sawStart = false
    }

    private var turns: [String: Turn] = [:]
    /// Question calls by `call_id`, with the turn holding their row.
    private var questionTurns: [String: String] = [:]
    /// The turn last started, for a question call without a turn id.
    private var currentTurnID: String?
    private var ordinals = CodexOrdinalDiagnostics()

    /// The timeline of `segments`, oldest first, each already cut to the
    /// range it contributes.
    static func build(_ segments: [CodexSegment]) -> (timeline: CodexTimeline, ordinals: CodexOrdinalDiagnostics) {
        var builder = CodexPaginatedBuilder()
        for (index, segment) in segments.enumerated() {
            builder.replay(segment, index: index)
        }
        return (builder.timeline(), builder.ordinals)
    }

    private mutating func replay(_ segment: CodexSegment, index: Int) {
        // A window that does not start at the head has no expected ordinal
        // until its first accepted line sets one.
        var next: UInt64?
        for line in segment.lines {
            guard line.outcome.isAccepted else { continue }
            guard let ordinal = line.ordinal else {
                ordinals.missing += 1
                continue
            }
            if let next, ordinal < next {
                ordinals.duplicates += 1
                continue
            }
            if let next, ordinal > next {
                ordinals.gaps += 1
            }
            next = ordinal < .max ? ordinal + 1 : ordinal
            if let end = segment.endOrdinalExclusive, ordinal >= end {
                continue
            }
            if let start = segment.meta.subagentHistoryStartOrdinal, ordinal < start {
                ordinals.inherited += 1
                continue
            }
            if let record = line.outcome.record {
                apply(record, line: line, segment: segment, at: Position(segment: index, offset: line.offset))
            }
        }
    }

    private mutating func apply(_ record: CodexRecord, line: CodexStoredLine, segment: CodexSegment, at position: Position) {
        switch record {
        case .turnStarted(let turnID, let times):
            touch(turnID, at: position)
            turns[turnID]?.sawStart = true
            note(times, of: turnID)
            setStatus(.inProgress, of: turnID, ending: nil, line: line, segment: segment, at: position)
            currentTurnID = turnID
        case .turnCompleted(let turnID, let error, let times):
            touch(turnID, at: position)
            note(times, of: turnID)
            if let error {
                setStatus(.failed, of: turnID, ending: .failed(error), line: line, segment: segment, at: position)
            } else {
                setStatus(.completed, of: turnID, ending: nil, line: line, segment: segment, at: position)
            }
        case .turnAborted(let turnID?, let reason, let error, let times):
            touch(turnID, at: position)
            note(times, of: turnID)
            let ending: CodexTimelineEntry.Content? =
                reason == .replaced || reason == .reviewEnded ? nil : .stopped(reason, error: error)
            setStatus(.interrupted, of: turnID, ending: ending, line: line, segment: segment, at: position)
        case .item(let turnID, let item):
            touch(turnID, at: position)
            guard var turn = turns[turnID] else { return }
            if var existing = turn.items[item.id] {
                existing.entry.content = .item(item.content)
                turn.items[item.id] = existing
            } else {
                turn.items[item.id] = Item(
                    position: position,
                    entry: entry(item.id, itemID: item.id, in: turnID, content: .item(item.content), line, segment))
            }
            turns[turnID] = turn
        case .questionCall(let call):
            guard let turnID = call.turnID ?? currentTurnID else { return }
            touch(turnID, at: position)
            questionTurns[call.callID] = turnID
            updateQuestion(call.callID, in: turnID, line: line, segment: segment, at: position) {
                $0.questions = call.questions
            }
        case .verifiedAnswer(let answer):
            guard let turnID = questionTurns[answer.callID] ?? answer.turnID ?? currentTurnID else { return }
            touch(turnID, at: position)
            questionTurns[answer.callID] = turnID
            updateQuestion(answer.callID, in: turnID, line: line, segment: segment, at: position) {
                $0.verified = answer.answers
            }
        case .callOutput(let output):
            // Outputs of other calls are not rows in a paginated rollout.
            guard let turnID = questionTurns[output.callID] else { return }
            updateQuestion(output.callID, in: turnID, line: line, segment: segment, at: position) {
                $0.hasOutput = true
                $0.outputAnswers = output.answers
            }
        case .turnAborted(nil, _, _, _), .userMessage, .agentMessage, .reasoning, .contextCompacted, .compacted,
            .rolledBack, .toolCall, .legacyItem:
            // An abort without a turn id names no turn here; the rest are
            // legacy records.
            break
        }
    }

    private mutating func touch(_ turnID: String, at position: Position) {
        if turns[turnID] == nil {
            turns[turnID] = Turn(id: turnID, position: position)
        }
    }

    /// Keeps the first start and the latest end a turn event gives.
    private mutating func note(_ times: CodexTurnTimes, of turnID: String) {
        guard var turn = turns[turnID] else { return }
        if turn.startedAt == nil { turn.startedAt = times.startedAt }
        if let completedAt = times.completedAt { turn.endedAt = completedAt }
        turns[turnID] = turn
    }

    /// Records a lifecycle status unless the turn already ended in this
    /// segment: the first terminal status wins (the thread store only
    /// updates a turn while it is in progress).
    private mutating func setStatus(
        _ status: CodexTurnStatus, of turnID: String, ending: CodexTimelineEntry.Content?, line: CodexStoredLine,
        segment: CodexSegment, at position: Position
    ) {
        guard var turn = turns[turnID] else { return }
        let ended = turn.status.map { $0 != .inProgress } ?? false
        guard !ended || turn.statusSegment < position.segment else { return }
        turn.status = status
        turn.statusSegment = position.segment
        turn.ending = ending.map { content in
            let suffix = if case .failed = content { "~failed" } else { "~stopped" }
            return entry(suffix, itemID: nil, in: turnID, content: content, line, segment)
        }
        turns[turnID] = turn
    }

    /// Updates a question row, creating it at this line's position when no
    /// earlier line placed it.
    private mutating func updateQuestion(
        _ callID: String, in turnID: String, line: CodexStoredLine, segment: CodexSegment, at position: Position,
        _ update: (inout CodexQuestionBuild) -> Void
    ) {
        guard var turn = turns[turnID] else { return }
        var item =
            turn.items[callID]
            ?? Item(
                position: position,
                entry: entry(callID, itemID: nil, in: turnID, content: .item(.compaction), line, segment))
        var question = item.question ?? CodexQuestionBuild()
        update(&question)
        item.question = question
        turn.items[callID] = item
        turns[turnID] = turn
    }

    /// An entry first placed by `line`. Its id and offset never change, so
    /// later snapshots update the same row.
    private func entry(
        _ key: String, itemID: String?, in turnID: String, content: CodexTimelineEntry.Content,
        _ line: CodexStoredLine, _ segment: CodexSegment
    ) -> CodexTimelineEntry {
        CodexTimelineEntry(
            id: ChatEntryID("codex/\(segment.rolloutID)/\(turnID)/\(key)"), sourceOffset: line.offset,
            itemID: itemID, rolloutID: segment.rolloutID, path: segment.path, content: content)
    }

    private func timeline() -> CodexTimeline {
        let ordered = turns.values.sorted { $0.position < $1.position }
        return CodexTimeline(
            turns: ordered.map { turn in
                let items = turn.items.sorted { $0.value.position < $1.value.position }
                return CodexTimelineTurn(
                    id: turn.id, status: turn.status,
                    entries: items.map { key, item in
                        var entry = item.entry
                        if let question = item.question {
                            entry.content = .question(question.state(callID: key))
                        }
                        return entry
                    },
                    ending: turn.ending, startedAt: turn.startedAt, endedAt: turn.endedAt, opensInWindow: turn.sawStart)
            })
    }
}
