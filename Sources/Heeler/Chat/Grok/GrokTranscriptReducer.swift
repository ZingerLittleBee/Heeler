import Foundation

/// Reads a Grok Build session's `updates.jsonl`, which Grok appends one ACP
/// update per line as the session runs.
///
/// Every pass projects all the loaded records again, as Pi's reducer does: a
/// `rewind_marker` hides turns above it, and a prompt Grok put back in its
/// input box is taken over by the next one, so no entry is final when its
/// line is read. Entry ids come from byte offsets, never from `eventId`,
/// which Grok numbers again after a rewind.
struct GrokTranscriptReducer: ChatTranscriptReducer {
    static let revision = 8

    /// The session's file on the Host.
    let transcriptPath: String
    /// The directory the session started in, which paths read relative to.
    let directory: String?
    private var records: [UInt64: GrokUpdateRecord] = [:]
    private var invalid: Set<UInt64> = []
    private var oversized: Set<UInt64> = []

    init(transcriptPath: String) {
        self.transcriptPath = transcriptPath
        directory = Self.directory(ofTranscript: transcriptPath)
    }

    /// The directory a session's group names: the directory
    /// percent-encoded. A long directory's group is a slug, which names none.
    static func directory(ofTranscript path: String) -> String? {
        let group = GrokTranscriptLocator.groupDirectory(ofTranscript: path)
        guard let name = group.split(separator: "/").last, let directory = String(name).removingPercentEncoding,
            RemoteHostPath.isAbsolute(directory)
        else { return nil }
        return directory
    }

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if line.isTruncated {
                oversized.insert(line.offset)
            }
            guard let record = GrokUpdateRecord.decode(line) else {
                invalid.insert(line.offset)
                continue
            }
            records[line.offset] = record
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        let ordered = records.values.sorted { $0.offset < $1.offset }
        let rewound = Self.rewound(ordered, windowStart: context.windowStart)
        var projection = Projection(activity: context.activity, directory: directory)
        for (index, record) in ordered.enumerated() where !rewound.contains(index) {
            projection.read(record)
        }
        var transcript = projection.finish()
        transcript.needsOlderHistory = context.windowStart > 0
        transcript.diagnostics.invalidLines = invalid.count
        transcript.diagnostics.oversizedLines = oversized.count
        return transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard !line.isTruncated, let record = GrokUpdateRecord.decode(line) else { return nil }
        switch record.kind {
        case .toolUpdate(let update?) where update.callID == tool.callID:
            guard let output = update.output else { return nil }
            // A row that shows a diff reads its changes, not the result's text.
            if tool.fileChanges != nil, let changes = update.fileChanges {
                let shown = GrokToolCall.shown(changes, kind: tool.kind, directory: tool.fileChanges?.directory)
                return .preview(nil, fileChanges: shown)
            }
            return .preview(output.preview)
        case .taskCompleted(let end):
            // A background command's or monitor's row points at its task's
            // end.
            return .preview(end.preview)
        case .subagentFinished(let finished) where tool.kind == .agent:
            return .preview(finished.preview)
        default:
            return nil
        }
    }

    /// What a sent prompt and a recorded one are compared on. Grok records
    /// the space Chat adds after a prompt, and a paste's line ends as typed.
    static func echoKey(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The positions in `ordered` that rewinds hide. A `rewind_marker`
    /// hides everything from the first prompt before it whose index is at
    /// or above its target, up to the marker. Prompt indexes count from the
    /// file's head, so the rule holds in a window that starts later; when
    /// the window's first prompt comes after the target, or it has none, the
    /// target's prompt is above the window, and the marker hides the window
    /// up to it.
    private static func rewound(_ ordered: [GrokUpdateRecord], windowStart: UInt64) -> Set<Int> {
        var hidden = Set<Int>()
        for (marker, record) in ordered.enumerated() {
            guard case .rewind(let target?) = record.kind else { continue }
            var first: Int?
            var from: Int?
            for index in 0..<marker where !hidden.contains(index) {
                guard case .userChunk(let chunk) = ordered[index].kind, let promptIndex = chunk.promptIndex else {
                    continue
                }
                if first == nil { first = promptIndex }
                if promptIndex >= target {
                    from = index
                    break
                }
            }
            if windowStart > 0, first.map({ $0 > target }) ?? true { from = 0 }
            if let from { hidden.formUnion(from..<marker) }
        }
        return hidden
    }

    // MARK: Projection

    /// The turn the latest counted prompt opened, until it ends.
    private struct OpenTurn {
        let promptIndex: Int?
        let openerOffset: UInt64
        /// The entry that shows the prompt; nil for one Grok wrote for
        /// itself, and until the prompt has something to show.
        var opener: ChatEntryID?
        /// The turn's position in `turns` once it placed an entry.
        var turn: Int?
        let promptMilliseconds: Int64?
        let promptSeconds: Int?
        var firstTurnStartMs: Int64?
        /// A message, thought or tool record came after the prompt.
        var hasOutput = false

        /// The prompt's own clock, then the first agent record's
        /// `turnStartMs`, then the prompt's `timestamp`.
        var startMs: Int64? {
            promptMilliseconds ?? firstTurnStartMs ?? promptSeconds.map { Int64($0) * 1_000 }
        }
    }

    /// One prompt's chunks, while the next chunk may still join them.
    private struct UserRun {
        var last: GrokUpdateRecord
        var lastChunk: GrokUpdateRecord.UserChunk
        let offset: UInt64
        let isHidden: Bool
        /// The run opened the open turn.
        let opensTurn: Bool
        let command: ChatCommandInvocation?
        let wasQueued: Bool
        var text = ""
        var images = 0
        /// A cut line lost some of its text.
        var lostText = false
        var entry: Int?

        var content: ChatEntry.Content? {
            if !text.isEmpty || images > 0 {
                return .user(ChatUserMessage(text: text, imageCount: images, command: command, wasQueued: wasQueued))
            }
            return lostText ? .notice(ChatNotice(kind: .system, title: "Message exceeds the preview limit")) : nil
        }

        /// Whether `chunk` continues this prompt: Grok writes a prompt of
        /// several content blocks as consecutive chunks, numbered one after
        /// another, in one second.
        func isContinued(by record: GrokUpdateRecord, _ chunk: GrokUpdateRecord.UserChunk) -> Bool {
            guard chunk.bashCommand == nil, lastChunk.bashCommand == nil, let timestamp = record.timestamp,
                timestamp == last.timestamp
            else { return false }
            // A cut line lost its event id and index.
            if record.isTruncated || last.isTruncated { return true }
            guard chunk.promptIndex == lastChunk.promptIndex, chunk.isHidden == lastChunk.isHidden,
                let event = record.eventNumber, let previous = last.eventNumber
            else { return false }
            return event.prefix == previous.prefix && event.number == previous.number + 1
        }
    }

    private struct Projection {
        let activity: ChatAgentActivity
        let directory: String?
        var transcript = ChatTranscript()
        var open: OpenTurn?
        /// Records before the first counted prompt belong to a turn opened
        /// above the loaded lines.
        var sawCountedPrompt = false
        var run: UserRun?
        /// The entry the previous record's message or thought placed, which
        /// the next part of the same block extends.
        var lastChunk: (entry: Int, isReasoning: Bool, chunkID: Int, promptID: String?)?
        /// Each tool call by id, in the order first seen. Its entry holds a
        /// placeholder until `finish()` builds the row from every record.
        var calls: [String: GrokToolCall] = [:]
        var callOrder: [String] = []
        /// How each turn ended, in the order counted prompts opened them; the
        /// first is the turn above the loaded lines.
        var turnEnds: [GrokToolCall.TurnEnd?] = [nil]
        /// The call that started each background task, and each subagent.
        var taskCalls: [String: String] = [:]
        var subagentCalls: [String: String] = [:]

        init(activity: ChatAgentActivity, directory: String?) {
            self.activity = activity
            self.directory = directory
        }

        mutating func read(_ record: GrokUpdateRecord) {
            // A prompt's chunks, and a block's parts, are consecutive records.
            switch record.kind {
            case .userChunk:
                lastChunk = nil
            case .agentMessage, .agentThought:
                run = nil
            default:
                run = nil
                lastChunk = nil
            }
            switch record.kind {
            case .userChunk(let chunk):
                readPrompt(record, chunk)
            case .agentMessage(let chunk):
                readChunk(record, chunk, isReasoning: false)
            case .agentThought(let chunk):
                readChunk(record, chunk, isReasoning: true)
            case .toolCall(let tool):
                noteOutput(record)
                if let tool { readTool(record, tool, isCall: true) }
            case .toolUpdate(let tool):
                noteOutput(record)
                if let tool { readTool(record, tool, isCall: false) }
            case .taskBackgrounded(let task):
                if let callID = task.callID, calls[callID] != nil {
                    if let taskID = task.taskID { taskCalls[taskID] = callID }
                    calls[callID]?.sentToBackground = true
                }
            case .taskCompleted(let end):
                readTaskEnd(record, end)
            case .subagentSpawned(let spawned):
                readSpawn(spawned)
            case .subagentFinished(let finished):
                if let id = finished.subagentID, let callID = subagentCalls[id] {
                    calls[callID]?.subagentEnd = finished
                    calls[callID]?.subagentEndLine = Self.line(record)
                }
            case .turnCompleted(let end):
                readEnd(record, end)
            case .compactionCheckpoint:
                // `summary_preview` is always null.
                let id = ChatEntryID("grok:\(record.offset):compaction")
                place(.divider(.compaction(summary: nil)), id: id, record)
            case .compactionCancelled:
                addNotice(ChatNotice(kind: .system, title: "Compaction was cancelled"), record)
            case .compactionFailed(let error):
                addNotice(Self.notice(kind: .system, title: "Compaction failed", text: error), record)
            case .retry(.retrying):
                break
            case .retry(.exhausted(let attempts, let reason)):
                let title = attempts.map { "Grok Build gave up after \($0) \($0 == 1 ? "attempt" : "attempts")" }
                addNotice(Self.notice(kind: .error, title: title ?? "Grok Build gave up", text: reason), record)
            case .retry(.failed(let message)):
                addNotice(Self.notice(kind: .error, title: "Grok Build gave up", text: message), record)
            case .imageDropped(let notes):
                // Grok drops an image that fails its checks before sending.
                let notice = ChatNotice(
                    kind: .system, title: notes.count > 1 ? "Images not sent" : "Image not sent",
                    detail: notes.isEmpty ? nil : notes.joined(separator: "\n"))
                addNotice(notice, record)
            case .rewind, .skipped:
                break
            case .unknown(let type):
                transcript.diagnostics.unknownRecordTypes.insert(type)
            }
        }

        mutating func finish() -> ChatTranscript {
            resolveTools()
            // Ctrl+C before the first output takes the prompt out of Grok's
            // conversation and puts its text back in the input box; Grok
            // writes no end for the turn. Working, the reply may still come.
            if let open, activity == .idle, !open.hasOutput, let opener = open.opener, let turn = open.turn {
                transcript.turns[turn].ending = .interrupted
                transcript.entries.append(
                    ChatEntry(
                        id: ChatEntryID("\(opener.rawValue):notice"), sourceOffset: open.openerOffset,
                        content: .notice(
                            ChatNotice(
                                kind: .stopped, title: "Stopped before a reply",
                                detail: "Grok Build put the message back in its input box."))))
            }
            return transcript
        }

        // MARK: Prompts

        private mutating func readPrompt(_ record: GrokUpdateRecord, _ chunk: GrokUpdateRecord.UserChunk) {
            if var run, run.isContinued(by: record, chunk) {
                run.last = record
                run.lastChunk = chunk
                add(record, chunk, to: &run)
                self.run = run
                return
            }
            run = nil
            if let command = chunk.bashCommand {
                // `!cmd` typed in Grok runs the command without the model.
                addNotice(ChatNotice(kind: .shellCommand, title: command), record)
                return
            }
            // A cut line lost the prompt's index: it is most likely a prompt
            // of its own, too long for the reader, such as a large image.
            let isCounted = chunk.promptIndex != nil || record.isTruncated
            if isCounted {
                sawCountedPrompt = true
                if let open {
                    if !chunk.isHidden, !open.hasOutput, let index = chunk.promptIndex, index == open.promptIndex {
                        // The prompt Ctrl+C put back in the input box, sent
                        // again with whatever was typed after it.
                        takeOver(open)
                    } else if let turn = open.turn {
                        // Grok crashed or was killed during the turn.
                        transcript.turns[turn].ending = .interrupted
                    }
                }
                endTurn(.replaced)
                turnEnds.append(nil)
                open = OpenTurn(
                    promptIndex: chunk.promptIndex, openerOffset: record.offset, opener: nil, turn: nil,
                    promptMilliseconds: record.agentTimestampMs, promptSeconds: record.timestamp)
            }
            var run = UserRun(
                last: record, lastChunk: chunk, offset: record.offset, isHidden: chunk.isHidden, opensTurn: isCounted,
                command: chunk.displayAsSkill ? chunk.displayText.flatMap(Self.skill) : nil,
                wasQueued: !isCounted)
            if !chunk.isHidden {
                transcript.latestPromptOffset = record.offset
            }
            add(record, chunk, to: &run)
            self.run = run
        }

        /// Adds one chunk to its prompt's entry, placing the entry once it
        /// has something to show, and keeps the recorded prompt in step.
        private mutating func add(
            _ record: GrokUpdateRecord, _ chunk: GrokUpdateRecord.UserChunk, to run: inout UserRun
        ) {
            guard !run.isHidden else { return }
            let text = Self.shownText(chunk)
            if !text.isEmpty {
                run.text = run.text.isEmpty ? text : run.text + "\n" + text
            }
            if chunk.contentType == "image" {
                run.images += 1
            } else if record.isTruncated {
                run.lostText = true
            }
            guard let content = run.content else { return }
            let id = ChatEntryID("grok:\(run.offset)")
            if let entry = run.entry {
                transcript.entries[entry].content = content
            } else {
                run.entry = place(content, id: id, offset: run.offset)
                if run.opensTurn { open?.opener = id }
            }
            if transcript.recordedPrompts.last?.entryID == id {
                transcript.recordedPrompts.removeLast()
            }
            if !run.lostText, !run.text.isEmpty {
                transcript.recordedPrompts.append(ChatRecordedPrompt(offset: run.offset, text: run.text, entryID: id))
            }
        }

        /// Drops the open turn's prompt for the one that takes it over.
        private mutating func takeOver(_ open: OpenTurn) {
            if let opener = open.opener {
                transcript.entries.removeAll { $0.id == opener }
                transcript.recordedPrompts.removeAll { $0.entryID == opener }
            }
            if let turn = open.turn {
                transcript.turns.remove(at: turn)
            }
        }

        // MARK: Agent records

        private mutating func readChunk(
            _ record: GrokUpdateRecord, _ chunk: GrokUpdateRecord.AgentChunk, isReasoning: Bool
        ) {
            noteOutput(record)
            let text = chunk.text ?? ""
            if let last = lastChunk, last.isReasoning == isReasoning, last.promptID == record.promptID,
                let chunkID = chunk.chunkID, chunkID == last.chunkID + 1
            {
                // The next part of the same block.
                switch transcript.entries[last.entry].content {
                case .assistant(var message):
                    message.text += text
                    transcript.entries[last.entry].content = .assistant(message)
                case .reasoning(var reasoning):
                    reasoning.text += text
                    transcript.entries[last.entry].content = .reasoning(reasoning)
                default: break
                }
                lastChunk?.chunkID = chunkID
                return
            }
            guard !text.isEmpty else {
                lastChunk = nil
                return
            }
            let content: ChatEntry.Content =
                isReasoning ? .reasoning(ChatReasoning(text: text)) : .assistant(ChatAssistantMessage(text: text))
            let entry = place(content, id: ChatEntryID("grok:\(record.offset)"), offset: record.offset)
            lastChunk = chunk.chunkID.map {
                (entry: entry, isReasoning: isReasoning, chunkID: $0, promptID: record.promptID)
            }
        }

        /// A message, thought or tool record: the open turn has output.
        private mutating func noteOutput(_ record: GrokUpdateRecord) {
            guard var open else { return }
            open.hasOutput = true
            if open.promptMilliseconds == nil, open.firstTurnStartMs == nil, let start = record.turnStartMs {
                open.firstTurnStartMs = start
                if let turn = open.turn {
                    transcript.turns[turn].startedAt = Self.date(start)
                }
            }
            self.open = open
        }

        private mutating func readEnd(_ record: GrokUpdateRecord, _ end: GrokUpdateRecord.TurnCompleted) {
            let ending: ChatTurn.Ending
            switch end.stopReason {
            case "end_turn":
                ending = .completed
            case "cancelled":
                ending = .interrupted
                if let notice = Self.cancelNotice(category: end.cancellationCategory, trigger: end.cancelTrigger) {
                    addNotice(notice, record)
                }
            case "error":
                ending = .failed
                addNotice(
                    Self.notice(kind: .error, title: "Grok Build stopped with an error", text: end.agentResult), record)
            default:
                ending = .completed
                transcript.diagnostics.unknownRecordTypes.insert("stop_reason:\(end.stopReason ?? "none")")
            }
            if let open {
                // Records after the end stay in this turn's range.
                if let turn = open.turn {
                    let endMs =
                        record.agentTimestampMs
                        ?? end.elapsedMilliseconds.flatMap { elapsed in open.startMs.map { $0 + elapsed } }
                    transcript.turns[turn].ending = ending
                    transcript.turns[turn].endedAt = endMs.map(Self.date)
                }
                self.open = nil
            } else if !sawCountedPrompt, transcript.precedingTurnEnd == nil {
                transcript.precedingTurnEnd = ChatTurnEnd(
                    ending: ending, endedAt: record.agentTimestampMs.map(Self.date),
                    duration: end.elapsedMilliseconds.map { TimeInterval($0) / 1_000 })
            }
            switch end.stopReason {
            case "cancelled": endTurn(end.cancellationCategory == "PermissionRejected" ? .rejected : .cancelled)
            case "error": endTurn(.failed)
            default: endTurn(.completed)
            }
        }

        /// Records how the latest turn ended, unless it already had.
        private mutating func endTurn(_ end: GrokToolCall.TurnEnd) {
            guard let last = turnEnds.indices.last, turnEnds[last] == nil else { return }
            turnEnds[last] = end
        }

        // MARK: Tools

        /// One record of a tool call. The call's row shows from its first
        /// record on; `finish()` builds it.
        private mutating func readTool(_ record: GrokUpdateRecord, _ tool: GrokUpdateRecord.Tool, isCall: Bool) {
            let id = tool.callID
            if calls[id] == nil {
                let entryID = ChatEntryID("grok:tool:\(id)")
                calls[id] = GrokToolCall(id: id, entryID: entryID, turn: turnEnds.count - 1)
                callOrder.append(id)
                let placeholder = ChatToolActivity(kind: .other, name: "", title: "", status: .running, callID: id)
                place(.tool(placeholder), id: entryID, record)
            }
            calls[id]?.merge(tool, isCall: isCall, line: Self.line(record), isTruncated: record.isTruncated)
            if let taskID = tool.output?.taskID { taskCalls[taskID] = id }
        }

        /// A background task ended: its call's row says how, and a notice
        /// marks when.
        private mutating func readTaskEnd(_ record: GrokUpdateRecord, _ end: GrokUpdateRecord.TaskCompleted) {
            if let taskID = end.taskID, let callID = taskCalls[taskID] ?? (calls[taskID] == nil ? nil : taskID) {
                calls[callID]?.taskEnd = end
                calls[callID]?.taskEndLine = Self.line(record)
            }
            var detail = end.command.map { [$0] } ?? []
            if end.wasKilled || end.signal == "killed" {
                detail.append("Killed")
            } else if let signal = end.signal {
                detail.append("Signal \(signal)")
            } else if let code = end.exitCode {
                detail.append("Exit code \(code)")
            }
            let isCommand = end.taskKind == nil || end.taskKind == "bash"
            addNotice(
                ChatNotice(
                    kind: .taskNotification,
                    title: isCommand ? "Background command finished" : "Background task finished",
                    detail: detail.isEmpty ? nil : detail.joined(separator: " · ")), record)
        }

        /// A subagent started: it belongs to the open spawn call that
        /// describes it the same way, else to the first open one. A spawn is
        /// open while it is in the latest turn and has neither a subagent nor
        /// a result. Grok writes the record before the spawn's result, and
        /// can write it before the spawn's input update, so a spawn that
        /// failed, or one from an earlier turn, did not start it.
        private mutating func readSpawn(_ spawned: GrokUpdateRecord.SubagentSpawned) {
            guard let subagentID = spawned.subagentID, subagentCalls[subagentID] == nil else { return }
            let turn = turnEnds.count - 1
            let open = callOrder.filter { id in
                guard let call = calls[id] else { return false }
                return call.isSpawn && call.subagentID == nil && call.output == nil && call.turn == turn
            }
            let described = spawned.description.flatMap { description in
                open.first { calls[$0]?.input?.description == description }
            }
            guard let callID = described ?? open.first else { return }
            subagentCalls[subagentID] = callID
            calls[callID]?.subagentID = subagentID
            calls[callID]?.subagentType = spawned.subagentType
            calls[callID]?.subagentDescription = spawned.description
        }

        /// Builds each call's row in its placeholder's place, and offers a
        /// call that waits for approval to the Blocked card.
        private mutating func resolveTools() {
            guard !callOrder.isEmpty else { return }
            var positions: [ChatEntryID: Int] = [:]
            for (index, entry) in transcript.entries.enumerated() {
                positions[entry.id] = index
            }
            for id in callOrder {
                guard let call = calls[id], let index = positions[call.entryID] else { continue }
                let turnEnd = turnEnds.indices.contains(call.turn) ? turnEnds[call.turn] : nil
                let tool = call.activity(directory: directory, turnEnd: turnEnd, agent: activity)
                transcript.entries[index].content = .tool(tool)
                if tool.status == .awaitingApproval {
                    transcript.pendingRequests.append(call.pendingRequest(for: tool))
                }
            }
        }

        private static func line(_ record: GrokUpdateRecord) -> ChatOutputReference {
            ChatOutputReference(offset: record.offset, length: record.length)
        }

        // MARK: Entries

        /// Appends an entry; the open turn's first entry starts it.
        @discardableResult
        private mutating func place(_ content: ChatEntry.Content, id: ChatEntryID, offset: UInt64) -> Int {
            transcript.entries.append(ChatEntry(id: id, sourceOffset: offset, content: content))
            if var open, open.turn == nil {
                open.turn = transcript.turns.count
                transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: open.startMs.map(Self.date)))
                self.open = open
            }
            return transcript.entries.count - 1
        }

        private mutating func place(_ content: ChatEntry.Content, id: ChatEntryID, _ record: GrokUpdateRecord) {
            place(content, id: id, offset: record.offset)
        }

        private mutating func addNotice(_ notice: ChatNotice, _ record: GrokUpdateRecord) {
            place(.notice(notice), id: ChatEntryID("grok:\(record.offset):notice"), record)
        }

        /// A notice whose detail is Grok's text, capped like a row's
        /// output; Copy gives the whole text.
        private static func notice(kind: ChatNotice.Kind, title: String, text: String?) -> ChatNotice {
            let detail = text.map { ChatToolPreview(capping: $0).text }
            return ChatNotice(kind: kind, title: title, detail: detail, rawDetail: detail == text ? nil : text)
        }

        /// The notice a cancelled turn ends with. A rejected permission
        /// ends the turn too, and its declined call says so.
        private static func cancelNotice(category: String?, trigger: String?) -> ChatNotice? {
            switch category {
            case "PermissionRejected":
                return nil
            case "PermissionCancelled":
                return ChatNotice(kind: .stopped, title: "Stopped at the permission prompt")
            // Grok 1.0.62 holds both spellings.
            case "HookDenied", "HookStopped":
                return ChatNotice(kind: .hook, title: "A hook stopped the turn")
            case "MidTurnAbort", nil:
                switch trigger {
                case "send_now": return ChatNotice(kind: .interrupted, title: "Interrupted to send the next message")
                case "shutdown": return ChatNotice(kind: .stopped, title: "Grok Build exited")
                default: return ChatNotice(kind: .stopped, title: "Stopped")
                }
            default:
                return ChatNotice(kind: .stopped, title: "Stopped")
            }
        }

        /// What Grok shows for a prompt: a skill's or interjection's display
        /// text, else the text without the context Grok adds to the first
        /// prompt of a fork or a resumed session.
        private static func shownText(_ chunk: GrokUpdateRecord.UserChunk) -> String {
            var text = chunk.displayText ?? chunk.text ?? ""
            // Grok's `strip_context_wrappers`: each wrapper's first
            // occurrence, and the whitespace after it.
            for tag in ["fork-context", "resume-context"] {
                guard let open = text.range(of: "<\(tag)>"),
                    let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
                else { continue }
                text = String(text[..<open.lowerBound]) + String(text[close.upperBound...].drop(while: \.isWhitespace))
            }
            return text
        }

        /// A skill's `/name arguments`.
        private static func skill(_ displayText: String) -> ChatCommandInvocation? {
            guard displayText.hasPrefix("/") else { return nil }
            let name = displayText.dropFirst().prefix { !$0.isWhitespace }
            guard !name.isEmpty else { return nil }
            return ChatCommandInvocation(
                name: String(name),
                arguments: displayText.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        private static func date(_ milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
        }
    }
}

extension ChatTranscriptAdapter {
    /// How Chat reads Grok Build's `updates.jsonl`. A `rewind_marker` in
    /// the tail can hide turns above it, so cached entries never join live
    /// ones, as for Pi. Grok writes a prompt sent while it works only once
    /// that prompt's turn starts (27 s later in one capture), and keeps
    /// herdr reporting Working through a `/compact` until it writes the
    /// compaction, so its echo clock stops while herdr reports it busy.
    /// herdr keeps the old session after `/resume`, `/fork` and going back
    /// from the dashboard, so a send first reads the screen for another
    /// session, then the folder's prompt history for the session that took it.
    /// One turn's `read_file` results can fill tens of MB, so the timeline
    /// reads at most 4 MiB of earlier history by itself.
    static var grok: ChatTranscriptAdapter {
        var limits = TranscriptFollower.Limits()
        limits.automaticOlderSearch = 4 << 20
        return ChatTranscriptAdapter(
            revision: GrokTranscriptReducer.revision,
            limits: limits,
            joinsCachedHistory: false,
            makeReducer: { GrokTranscriptReducer(transcriptPath: $0.path) },
            echoKey: { GrokTranscriptReducer.echoKey($0) },
            echoClockStopsWhileWorking: true,
            sessionCheck: { GrokSessionCheck.verdict($0, $1) },
            sendWitness: GrokPromptHistoryWitness.witness)
    }
}
