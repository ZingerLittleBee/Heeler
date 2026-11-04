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
/// line names, however late it arrives. A tool call first recorded after
/// its turn completed (a command Codex 0.163.0 leaves running as a
/// background terminal) joins the turn's steps above its final answer, so
/// the answer stays the last thing the finished turn shows and the turn
/// still folds. A stopped or failed turn does not fold, and keeps such a
/// call where it was recorded, below the commentary before it.
///
/// A turn started under the root of a turn already in the file is that
/// turn's forwarded work: a review's reviewer turn writes its prompt,
/// commands and reasoning into the parent rollout under its own turn id
/// (`codex-rs/core/src/tasks/review.rs`, `process_review_events`). Its items
/// join the root turn, and its prompt, which Codex wrote for the reviewer,
/// is not the user's message.
///
/// Response items are never rows (their `item_completed` twins are). The
/// exceptions have no turn item: the sync `request_user_input` call, whose
/// question row pairs the call with the `verified_answer` or tool output by
/// `call_id`, and a code-mode patch the user aborted, which Codex 0.163.0
/// records only as the `exec` call and its "aborted by user" output. That
/// row yields to a `FileChange` item for the same files, which earlier
/// versions also write.
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
        /// Set for a row derived from an aborted code-mode patch.
        var isCodeModePatch = false
        /// A tool call first recorded after its turn completed.
        var isLate = false
    }

    /// A code-mode patch call waiting for its output.
    private struct PendingPatch {
        var turnID: String
        var position: Position
        var line: CodexStoredLine
        var segment: CodexSegment
        var snapshot: CodexToolSnapshot
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
    /// Code-mode patch calls by `call_id`, until an output aborts them.
    private var pendingPatches: [String: PendingPatch] = [:]
    /// The turn last started, for a question call without a turn id.
    private var currentTurnID: String?
    /// Turns whose items join their root turn, by turn id.
    private var forwardedTurns: [String: String] = [:]
    /// Every turn a loaded line names, so a turn started under a root that
    /// only appears further down still joins it.
    private var namedTurns: Set<String> = []
    private var ordinals = CodexOrdinalDiagnostics()

    /// The timeline of `segments`, oldest first, each already cut to the
    /// range it contributes.
    static func build(_ segments: [CodexSegment]) -> (timeline: CodexTimeline, ordinals: CodexOrdinalDiagnostics) {
        var builder = CodexPaginatedBuilder()
        let accepted = segments.map { builder.accepted($0) }
        builder.namedTurns = Set(accepted.joined().compactMap { Self.turnID(named: $0.record) })
        for (index, segment) in segments.enumerated() {
            for (record, line) in accepted[index] {
                builder.apply(record, line: line, segment: segment, at: Position(segment: index, offset: line.offset))
            }
        }
        return (builder.timeline(), builder.ordinals)
    }

    private static func turnID(named record: CodexRecord) -> String? {
        switch record {
        case .turnStarted(let turnID, _, _), .turnCompleted(let turnID, _, _), .turnAborted(let turnID?, _, _, _),
            .item(let turnID, _):
            turnID
        default:
            nil
        }
    }

    /// The records `segment` contributes, in file order, counting ordinal
    /// problems on the way.
    private mutating func accepted(_ segment: CodexSegment) -> [(record: CodexRecord, line: CodexStoredLine)] {
        var records: [(record: CodexRecord, line: CodexStoredLine)] = []
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
                records.append((record, line))
            }
        }
        return records
    }

    private mutating func apply(_ record: CodexRecord, line: CodexStoredLine, segment: CodexSegment, at position: Position) {
        switch record {
        case .turnStarted(let started, let root, let times):
            var turnID = started
            if let root, namedTurns.contains(root) {
                forwardedTurns[started] = root
                turnID = root
            }
            touch(turnID, at: position)
            // A review turn has no start of its own; its reviewer's stands
            // for it.
            turns[turnID]?.sawStart = true
            note(times, of: turnID)
            setStatus(.inProgress, of: turnID, ending: nil, line: line, segment: segment, at: position)
            currentTurnID = turnID
        case .turnCompleted(let completed, let error, let times):
            let turnID = forwardedTurns[completed] ?? completed
            touch(turnID, at: position)
            note(times, of: turnID)
            if let error {
                setStatus(.failed, of: turnID, ending: .failed(error), line: line, segment: segment, at: position)
            } else {
                setStatus(.completed, of: turnID, ending: nil, line: line, segment: segment, at: position)
            }
        case .turnAborted(let aborted?, let reason, let error, let times):
            let turnID = forwardedTurns[aborted] ?? aborted
            touch(turnID, at: position)
            note(times, of: turnID)
            let ending: CodexTimelineEntry.Content? =
                reason == .replaced || reason == .reviewEnded ? nil : .stopped(reason, error: error)
            setStatus(.interrupted, of: turnID, ending: ending, line: line, segment: segment, at: position)
        case .item(let named, let item):
            let turnID = forwardedTurns[named] ?? named
            if turnID != named, case .user = item.content { return }
            touch(turnID, at: position)
            guard var turn = turns[turnID] else { return }
            if var existing = turn.items[item.id] {
                existing.entry.content = .item(item.content)
                turn.items[item.id] = existing
            } else {
                var isTool = false
                if case .tool = item.content { isTool = true }
                turn.items[item.id] = Item(
                    position: position,
                    entry: entry(item.id, itemID: item.id, in: turnID, content: .item(item.content), line, segment),
                    isLate: isTool && turn.status == .completed)
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
        case .codeModePatch(let call):
            guard let named = call.turnID ?? currentTurnID else { return }
            pendingPatches[call.callID] = PendingPatch(
                turnID: forwardedTurns[named] ?? named, position: position, line: line, segment: segment,
                snapshot: call.snapshot)
        case .callOutput(let output) where output.isAbortedByUser:
            guard let patch = pendingPatches.removeValue(forKey: output.callID) else { return }
            touch(patch.turnID, at: patch.position)
            guard var turn = turns[patch.turnID] else { return }
            var snapshot = patch.snapshot
            snapshot.status = .interrupted
            turn.items[output.callID] = Item(
                position: patch.position,
                entry: entry(
                    output.callID, itemID: nil, in: patch.turnID, content: .item(.tool(snapshot)), patch.line,
                    patch.segment),
                isCodeModePatch: true)
            turns[patch.turnID] = turn
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

    /// `items` in file order, with each late tool call moved above the
    /// final answer: the turn's trailing run of agent messages.
    private static func placingLateItems(_ items: [(key: String, value: Item)]) -> [(key: String, value: Item)] {
        let late = items.filter(\.value.isLate)
        guard !late.isEmpty else { return items }
        var placed = items.filter { !$0.value.isLate }
        var answerStart = placed.endIndex
        while answerStart > placed.startIndex, case .item(.agent) = placed[answerStart - 1].value.entry.content {
            answerStart -= 1
        }
        placed.insert(contentsOf: late, at: answerStart)
        return placed
    }

    /// The files a patch row names, as a set, so one whose patch lists them
    /// in another order still matches.
    private static func patchFiles(of item: Item) -> Set<String>? {
        guard case .item(.tool(let snapshot)) = item.entry.content else { return nil }
        return Set(snapshot.title.components(separatedBy: ", "))
    }

    private static func recordedPatchFiles(in turn: Turn) -> Set<Set<String>> {
        Set(
            turn.items.values.compactMap { item in
                guard case .item(.tool(let snapshot)) = item.entry.content, snapshot.name == "FileChange" else {
                    return nil
                }
                return patchFiles(of: item)
            })
    }

    private func timeline() -> CodexTimeline {
        let ordered = turns.values.sorted { $0.position < $1.position }
        return CodexTimeline(
            turns: ordered.map { turn in
                let recorded = Self.recordedPatchFiles(in: turn)
                let items = Self.placingLateItems(
                    turn.items.filter { _, item in
                        !item.isCodeModePatch || Self.patchFiles(of: item).map { !recorded.contains($0) } ?? true
                    }
                    .sorted { $0.value.position < $1.value.position })
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
