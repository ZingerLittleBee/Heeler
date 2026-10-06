import Foundation

/// Rebuilds a legacy rollout's turns by replaying its events through the
/// rules of Codex's `ThreadHistoryBuilder` (`thread_history.rs`).
///
/// Legacy rollouts persist events rather than turn items, and turns are
/// implicit unless a `task_started` opened them: a user message closes an
/// implicit turn (unless it holds only a compaction), completion and abort
/// events find their turn by id with fallbacks, and `thread_rolled_back`
/// drops whole turns. Lines have no ordinals, so entries are keyed by byte
/// offset (`codex/<rollout>/@<offset>`).
///
/// Codex's builder ignores tool response items; Heeler pairs them by
/// `call_id` so legacy tool calls show as rows (§6), and merges the
/// `*_end` events that share a call id into the same row.
struct CodexLegacyBuilder {
    private struct Item {
        /// The id rows are upserted by: a call or item id, or the line's
        /// offset for messages.
        var key: String
        var entry: CodexTimelineEntry
        var question: CodexQuestionBuild?
    }

    private struct Turn {
        var id: String
        var isExplicit: Bool
        var sawCompaction = false
        /// Codex gives implicit turns `completed` until something says
        /// otherwise.
        var status: CodexTurnStatus
        var items: [Item] = []
        var ending: CodexTimelineEntry?
        /// `request_user_input_async` calls whose questions the next
        /// assistant message asks.
        var asyncCalls: [String] = []

        func index(of key: String) -> Int? {
            items.lastIndex { $0.key == key }
        }
    }

    private let segment: CodexSegment
    private var turns: [Turn] = []
    private var current: Turn?

    private init(segment: CodexSegment) {
        self.segment = segment
    }

    static func build(_ segment: CodexSegment) -> CodexTimeline {
        var builder = CodexLegacyBuilder(segment: segment)
        for line in segment.lines where line.outcome.isAccepted {
            if let record = line.outcome.record {
                builder.apply(record, line: line)
            }
        }
        return builder.timeline()
    }

    private mutating func apply(_ record: CodexRecord, line: CodexStoredLine) {
        switch record {
        case .turnStarted(let turnID):
            finishCurrent()
            current = Turn(id: turnID, isExplicit: true, status: .inProgress)
        case .turnCompleted(let turnID, let error):
            complete(turnID, error: error, line: line)
        case .turnAborted(let turnID, let reason, let error):
            abort(turnID, reason: reason, error: error, line: line)
        case .userMessage(let content):
            if let turn = current, !turn.isExplicit, !(turn.sawCompaction && turn.items.isEmpty) {
                finishCurrent()
            }
            push(.item(.user(content)), line: line)
        case .agentMessage(let content):
            guard !content.text.isEmpty || !content.questions.isEmpty else { return }
            ensureTurn(line)
            let itemID = content.questions.isEmpty ? nil : current?.asyncCalls.popLast()
            push(.item(.agent(content)), itemID: itemID, line: line)
        case .reasoning(let text):
            guard !text.isEmpty else { return }
            ensureTurn(line)
            if var turn = current, var last = turn.items.last,
                case .item(.reasoning(let existing, let duration)) = last.entry.content
            {
                last.entry.content = .item(.reasoning(existing + "\n\n" + text, durationMilliseconds: duration))
                turn.items[turn.items.count - 1] = last
                current = turn
            } else {
                push(.item(.reasoning(text, durationMilliseconds: nil)), line: line)
            }
        case .contextCompacted:
            push(.item(.compaction), line: line)
        case .compacted:
            ensureTurn(line)
            current?.sawCompaction = true
        case .rolledBack(let count):
            finishCurrent()
            turns.removeLast(min(count, turns.count))
        case .toolCall(let call):
            applyCall(call, line: line)
        case .callOutput(let output):
            update(output.callID) { item in
                if item.question != nil {
                    item.question?.hasOutput = true
                    item.question?.outputAnswers = output.answers
                } else if case .item(.tool(let snapshot)) = item.entry.content {
                    item.entry.content = .item(.tool(snapshot.applying(output)))
                }
            }
        case .verifiedAnswer(let answer):
            update(answer.callID) { item in
                item.question?.verified = answer.answers
            }
        case .legacyItem(let item, let placement):
            if case .tool(let snapshot) = item.content, let callID = snapshot.callID,
                update(callID, { existing in
                    if case .item(.tool(let call)) = existing.entry.content {
                        existing.entry.content = .item(.tool(call.merged(with: snapshot)))
                    }
                })
            {
                return
            }
            place(item, placement, line: line)
        case .item, .questionCall:
            // Paginated records.
            break
        }
    }

    private mutating func applyCall(_ call: CodexToolCall, line: CodexStoredLine) {
        switch call.role {
        case .tool(let snapshot):
            let merged = update(call.callID) { existing in
                if case .item(.tool(let end)) = existing.entry.content {
                    existing.entry.content = .item(.tool(snapshot.merged(with: end)))
                }
            }
            if !merged {
                push(.item(.tool(snapshot)), key: call.callID, line: line)
            }
        case .question(let questions):
            let merged = update(call.callID) { existing in
                existing.question?.questions = questions
            }
            if !merged {
                push(.item(.compaction), key: call.callID, line: line, question: CodexQuestionBuild(questions: questions))
            }
        case .asyncQuestions:
            ensureTurn(line)
            current?.asyncCalls.append(call.callID)
        }
    }

    // MARK: Turn lifecycle

    /// `handle_turn_complete`: the current turn by id, then an earlier turn
    /// by id, else the current turn whatever its id.
    private mutating func complete(_ turnID: String, error: String?, line: CodexStoredLine) {
        let ending = entry(key: "@\(line.offset)", content: .failed(error), line: line)
        func apply(_ turn: inout Turn) {
            if error != nil {
                turn.status = .failed
                turn.ending = ending
            } else if turn.status == .completed || turn.status == .inProgress {
                turn.status = .completed
            }
        }
        if var turn = current, turn.id == turnID {
            apply(&turn)
            current = turn
            finishCurrent()
        } else if let index = turns.firstIndex(where: { $0.id == turnID }) {
            apply(&turns[index])
        } else if var turn = current {
            apply(&turn)
            current = turn
            finishCurrent()
        }
    }

    /// `handle_turn_aborted`: the turn named by id, else the current one.
    /// Unlike completion it does not finish the turn.
    private mutating func abort(_ turnID: String?, reason: CodexAbortReason, error: String?, line: CodexStoredLine) {
        let ending =
            reason == .replaced || reason == .reviewEnded
            ? nil : entry(key: "@\(line.offset)", content: .stopped(reason, error: error), line: line)
        func apply(_ turn: inout Turn) {
            turn.status = .interrupted
            turn.ending = ending
        }
        if let turnID, var turn = current, turn.id == turnID {
            apply(&turn)
            current = turn
        } else if let turnID, let index = turns.firstIndex(where: { $0.id == turnID }) {
            apply(&turns[index])
        } else if var turn = current {
            apply(&turn)
            current = turn
        }
    }

    /// Ends the current turn; an implicit turn with nothing in it vanishes.
    private mutating func finishCurrent() {
        guard let turn = current else { return }
        current = nil
        if turn.items.isEmpty, !turn.isExplicit, !turn.sawCompaction {
            return
        }
        turns.append(turn)
    }

    /// The current turn, opening an implicit one at `line` when there is
    /// none. Codex numbers implicit turns by line index; the byte offset
    /// keeps the id independent of where the window starts.
    private mutating func ensureTurn(_ line: CodexStoredLine) {
        if current == nil {
            current = Turn(id: "legacy@\(line.offset)", isExplicit: false, status: .completed)
        }
    }

    // MARK: Items

    private mutating func push(
        _ content: CodexTimelineEntry.Content, key: String? = nil, itemID: String? = nil, line: CodexStoredLine,
        question: CodexQuestionBuild? = nil
    ) {
        ensureTurn(line)
        var entry = entry(key: "@\(line.offset)", content: content, line: line)
        entry.itemID = itemID
        current?.items.append(Item(key: key ?? "@\(line.offset)", entry: entry, question: question))
    }

    /// `upsert_item_in_turn_id` and friends.
    private mutating func place(_ item: CodexItem, _ placement: CodexLegacyPlacement, line: CodexStoredLine) {
        switch placement {
        case .turn(let turnID), .turnOrCurrent(let turnID?):
            upsert(item, inTurn: turnID, line: line)
        case .turnOrCurrent(nil), .current, .review(nil):
            ensureTurn(line)
            upsert(item, inTurn: nil, line: line)
        case .review(let turnID?):
            // A review item opens its turn when no line has yet.
            if current?.id != turnID, !turns.contains(where: { $0.id == turnID }) {
                finishCurrent()
                current = Turn(id: turnID, isExplicit: false, status: .completed)
            }
            upsert(item, inTurn: turnID, line: line)
        }
    }

    /// Replaces the item with the same id in the turn, or appends it. A nil
    /// `turnID` means the current turn; an unknown id drops the item, as
    /// Codex does.
    private mutating func upsert(_ item: CodexItem, inTurn turnID: String?, line: CodexStoredLine) {
        let content = CodexTimelineEntry.Content.item(item.content)
        let placed = Item(key: item.id, entry: entry(key: "@\(line.offset)", content: content, line: line))
        func upsert(into turn: inout Turn) {
            if let index = turn.index(of: item.id) {
                turn.items[index].entry.content = content
            } else {
                turn.items.append(placed)
            }
        }
        if var turn = current, turnID == nil || turn.id == turnID {
            upsert(into: &turn)
            current = turn
        } else if let turnID, let index = turns.firstIndex(where: { $0.id == turnID }) {
            upsert(into: &turns[index])
        }
    }

    /// Applies `change` to the row keyed `key`, searching the newest turn
    /// first. Returns false when no turn still holds that row (it may have
    /// been rolled back).
    @discardableResult
    private mutating func update(_ key: String, _ change: (inout Item) -> Void) -> Bool {
        if var turn = current, let index = turn.index(of: key) {
            change(&turn.items[index])
            current = turn
            return true
        }
        for turnIndex in turns.indices.reversed() {
            if let index = turns[turnIndex].index(of: key) {
                change(&turns[turnIndex].items[index])
                return true
            }
        }
        return false
    }

    private func entry(key: String, content: CodexTimelineEntry.Content, line: CodexStoredLine) -> CodexTimelineEntry {
        CodexTimelineEntry(
            id: ChatEntryID("codex/\(segment.rolloutID)/\(key)"), sourceOffset: line.offset,
            rolloutID: segment.rolloutID, path: segment.path, content: content)
    }

    private func timeline() -> CodexTimeline {
        var all = turns.map { ($0, Optional($0.status)) }
        if let open = current, !open.items.isEmpty || open.isExplicit || open.sawCompaction {
            // The turn still open at the end: an implicit one has no status
            // of its own until something ends it.
            all.append((open, !open.isExplicit && open.status == .completed ? nil : open.status))
        }
        return CodexTimeline(
            turns: all.map { turn, status in
                CodexTimelineTurn(
                    id: turn.id, status: status,
                    entries: turn.items.map { item in
                        var entry = item.entry
                        if let question = item.question {
                            entry.content = .question(question.state(callID: item.key))
                        }
                        return entry
                    },
                    ending: turn.ending)
            })
    }
}

extension CodexToolSnapshot {
    /// The row once its output arrived: an exit code decides success, and a
    /// call with an output but no exit code finished.
    func applying(_ output: CodexCallOutput) -> CodexToolSnapshot {
        var snapshot = self
        snapshot.exitCode = output.exitCode ?? exitCode
        if snapshot.status == nil {
            snapshot.status = snapshot.exitCode.map { $0 == 0 ? .succeeded : .failed } ?? .succeeded
        }
        snapshot.preview = output.preview ?? preview
        snapshot.output = output.output
        return snapshot
    }

    /// The call's row with an end event's details: the event knows the
    /// outcome and the files or server, the call knows the exit code.
    func merged(with end: CodexToolSnapshot) -> CodexToolSnapshot {
        var snapshot = end
        snapshot.exitCode = end.exitCode ?? exitCode
        snapshot.preview = end.preview ?? preview
        snapshot.status = end.status ?? status
        snapshot.note = end.note ?? note
        return snapshot
    }
}
