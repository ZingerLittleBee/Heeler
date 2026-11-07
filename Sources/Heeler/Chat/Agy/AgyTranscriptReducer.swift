import Foundation

/// Reads an Antigravity CLI conversation's `transcript_full.jsonl`, one line
/// per finished step (agy 1.5.3).
///
/// agy writes a step once it is done and never rewrites it, but nothing in
/// the file says when a turn ends: a planner response without tool calls is
/// the reply, and the next prompt closes the turn. Esc or Ctrl+C writes
/// nothing, so a prompt that follows a turn with no reply means it was
/// interrupted. Every pass therefore projects all the loaded steps again, as
/// Grok Build's reducer does. Tool results carry no call id; they follow
/// their planner response in call order. Entry ids come from `step_index`,
/// which agy numbers once per conversation.
///
/// A step's `created_at` is when it started: a reply's is when the model
/// began it, the same second as the step before. No step says when a turn
/// ended, so turns record when they started only, and Chat shows no time
/// worked rather than one that leaves out the reply.
struct AgyTranscriptReducer: ChatTranscriptReducer {
    static let revision = 1

    private var steps: [UInt64: AgyStep] = [:]
    private var invalid: Set<UInt64> = []
    private var oversized: Set<UInt64> = []

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if line.isTruncated {
                oversized.insert(line.offset)
            }
            guard let step = AgyStep.decode(line) else {
                invalid.insert(line.offset)
                continue
            }
            steps[line.offset] = step
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        let ordered = steps.values.sorted { $0.offset < $1.offset }
        var projection = Projection(activity: context.activity)
        // A fork's file starts where its parent stopped numbering, without
        // the parent's steps.
        if context.windowStart == 0, let first = ordered.first, let index = first.stepIndex, index > 0 {
            projection.placeForkDivider(first)
        }
        for step in ordered {
            projection.read(step)
        }
        var transcript = projection.finish()
        transcript.needsOlderHistory = context.windowStart > 0
        transcript.diagnostics.invalidLines = invalid.count
        transcript.diagnostics.oversizedLines = oversized.count
        return transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard !line.isTruncated, let step = AgyStep.decode(line) else { return nil }
        switch step.kind {
        case .toolResult:
            // A result sent to the background tells the model how to follow
            // its task; it is no output (`AgyToolCall.activity`).
            guard step.status != .running else { return nil }
            return .preview(AgyToolCall.preview(of: step, kind: tool.kind))
        case .systemMessage:
            guard let end = Self.taskEnd(in: step) else { return nil }
            return .preview(AgyToolCall.preview(ofTaskResult: end.result))
        default:
            return nil
        }
    }

    /// What a sent prompt and a recorded one are compared on. agy trims the
    /// space Chat adds after a prompt, and in plan mode records the prompt
    /// after `/plan `.
    static func echoKey(_ text: String) -> String {
        let key = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = "/plan "
        return key.hasPrefix(plan) ? String(key.dropFirst(plan.count)).trimmingCharacters(in: .whitespaces) : key
    }

    // MARK: System messages

    /// A background task's end: `Task id "<task>" finished with result:`
    /// or `… was canceled with result:`, then the result.
    static func taskEnd(in step: AgyStep) -> (taskID: String, wasCanceled: Bool, result: String)? {
        guard let text = step.systemMessageText, text.hasPrefix("Task id \"") else { return nil }
        let rest = text.dropFirst("Task id \"".count)
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        let taskID = String(rest[..<quote])
        let tail = rest[rest.index(after: quote)...]
        for (phrase, wasCanceled) in [(" finished with result:", false), (" was canceled with result:", true)] {
            guard tail.hasPrefix(phrase) else { continue }
            let result = tail.dropFirst(phrase.count).drop { $0 == "\n" }
            return (taskID, wasCanceled, String(result))
        }
        return nil
    }

    /// The notice agy adds to a conversation resumed after it restarted.
    static let restartNotice = "[Notice] All your subagents and background tasks have been stopped due to server restart"

    // MARK: Projection

    /// The turn the latest prompt, or a background task's end, opened.
    private struct OpenTurn {
        /// The turn's position in `turns` once it placed an entry; nil for
        /// the turn opened above the loaded lines.
        var turn: Int?
        let isAboveWindow: Bool
        var startedAt: Date?
        /// A planner response without tool calls, or a `/compact` prompt's
        /// checkpoint, came last.
        var hasReply = false
        let isCompact: Bool
        /// The calls it made, by position in `calls`.
        var calls: [Int] = []
        /// The latest step it holds.
        var lastStep: AgyStep?

        var hasSteps: Bool { lastStep != nil }
    }

    private struct Projection {
        let activity: ChatAgentActivity
        var transcript = ChatTranscript()
        var open: OpenTurn?
        var calls: [AgyToolCall] = []
        /// The latest planner response's calls still waiting for a result,
        /// first in line first.
        var pending: [Int] = []
        var tasks: [String: Int] = [:]
        /// Waits sent to the background (`AgyToolCall.waitTools`) no step
        /// has come after yet.
        var waits: [Int] = []
        /// The steps read so far, for a step agy wrote twice.
        var seenSteps: Set<Int> = []

        init(activity: ChatAgentActivity) {
            self.activity = activity
            open = OpenTurn(turn: nil, isAboveWindow: true, startedAt: nil, isCompact: false)
        }

        mutating func placeForkDivider(_ first: AgyStep) {
            transcript.entries.append(
                ChatEntry(
                    id: ChatEntryID("agy:\(first.stepIndex ?? 0):history"), sourceOffset: first.offset,
                    content: .divider(
                        ChatDivider(
                            kind: .historyUnavailable,
                            detail: "Earlier messages are in the conversation this one was forked from."))))
        }

        mutating func read(_ step: AgyStep) {
            if let index = step.stepIndex {
                guard seenSteps.insert(index).inserted else {
                    // agy 1.5.3 writes each step once. Issue #644 describes a
                    // background result written again once done: the later
                    // line holds the result. Any other repeat would repeat
                    // its entries' ids.
                    if step.kind == .toolResult,
                        let call = calls.firstIndex(where: { $0.result?.stepIndex == index })
                    {
                        calls[call].result = step
                    }
                    return
                }
            }
            switch step.kind {
            case .userInput: readPrompt(step)
            case .plannerResponse: readResponse(step)
            case .toolResult: readResult(step)
            case .systemMessage: readSystemMessage(step)
            case .checkpoint: readCheckpoint(step)
            case .errorMessage: readError(step)
            case .ephemeral: break
            case .unknown(let type):
                transcript.diagnostics.unknownRecordTypes.insert(type)
            }
        }

        mutating func finish() -> ChatTranscript {
            if let open, open.hasReply {
                close(open, ending: .completed, interruptedNotice: false)
            }
            resolveTools()
            return transcript
        }

        // MARK: Prompts

        private mutating func readPrompt(_ step: AgyStep) {
            closeForNextPrompt()
            let request = step.request
            let text = request?.text ?? ""
            let images = step.media.filter { $0.mimeType?.hasPrefix("image/") == true }.count
            open = OpenTurn(turn: nil, isAboveWindow: false, startedAt: step.createdAt, isCompact: text == "/compact")
            let id = Self.id(step)
            let content: ChatEntry.Content =
                text.isEmpty && images == 0
                ? .notice(ChatNotice(kind: .system, title: "Message exceeds the preview limit"))
                : .user(ChatUserMessage(text: text, imageCount: images))
            place(content, id: id, step)
            transcript.latestPromptOffset = step.offset
            if let request, request.isComplete, !request.text.isEmpty {
                transcript.recordedPrompts.append(ChatRecordedPrompt(offset: step.offset, text: request.text, entryID: id))
            }
        }

        /// The next prompt closes the open turn: with its reply it
        /// completed; without one, Esc, Ctrl+C or a declined call ended it.
        private mutating func closeForNextPrompt() {
            guard let open else { return }
            if open.hasReply {
                close(open, ending: .completed, interruptedNotice: false)
            } else if open.hasSteps {
                let declined = open.calls.last.map { calls[$0].isDeclined } ?? false
                close(open, ending: .interrupted, interruptedNotice: !declined)
            }
            self.open = nil
        }

        private mutating func close(_ turn: OpenTurn, ending: ChatTurn.Ending, interruptedNotice: Bool) {
            for index in turn.calls where calls[index].turnEnd == nil {
                calls[index].turnEnd = ending == .interrupted ? .interrupted : .movedOn
            }
            pending.removeAll()
            if interruptedNotice, let last = turn.lastStep {
                transcript.entries.append(
                    ChatEntry(
                        id: ChatEntryID("agy:\(last.stepIndex ?? 0):interrupted"), sourceOffset: last.offset,
                        content: .notice(ChatNotice(kind: .interrupted, title: "Interrupted"))))
            }
            if let index = turn.turn {
                transcript.turns[index].ending = ending
            } else if turn.isAboveWindow, turn.hasSteps, transcript.precedingTurnEnd == nil {
                transcript.precedingTurnEnd = ChatTurnEnd(ending: ending)
            }
        }

        // MARK: Agent steps

        private mutating func readResponse(_ step: AgyStep) {
            ensureOpen()
            note(step)
            // Calls an earlier response left without a result never get one.
            for index in pending where calls[index].turnEnd == nil {
                calls[index].turnEnd = .movedOn
            }
            pending.removeAll()
            if let thinking = step.thinking, !thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                place(.reasoning(ChatReasoning(text: thinking)), id: Self.id(step, "thinking"), step)
            }
            if let text = step.content, !text.isEmpty {
                place(.assistant(ChatAssistantMessage(text: text)), id: Self.id(step, "text"), step)
            }
            for (position, call) in step.calls.enumerated() {
                let entryID = Self.id(step, "tool:\(position)")
                let index = calls.count
                calls.append(AgyToolCall(entryID: entryID, call: call))
                pending.append(index)
                open?.calls.append(index)
                let placeholder = ChatToolActivity(kind: .other, name: call.name, title: call.name, status: .running)
                place(.tool(placeholder), id: entryID, step)
            }
            open?.hasReply = step.calls.isEmpty
        }

        private mutating func readResult(_ step: AgyStep) {
            // A result above the window's first response has no call to
            // show it with.
            guard !pending.isEmpty else { return }
            ensureOpen()
            note(step)
            let index = pending.removeFirst()
            calls[index].result = step
            guard step.status == .running else { return }
            // A wait gets no task end, so it is no task a restart stops.
            if AgyToolCall.waitTools.contains(calls[index].name) {
                waits.append(index)
            } else if let taskID = Self.backgroundTaskID(in: step.resultBody) {
                calls[index].taskID = taskID
                tasks[taskID] = index
            }
        }

        private mutating func readSystemMessage(_ step: AgyStep) {
            if let end = AgyTranscriptReducer.taskEnd(in: step) {
                readTaskEnd(step, end)
                return
            }
            guard let text = step.systemMessageText, text.hasPrefix(AgyTranscriptReducer.restartNotice) else {
                // Messages from other agents and reminders are the agent's
                // context, not the conversation.
                return
            }
            // agy adds the notice to every resumed conversation; it says
            // something only when a task was still running.
            let stopped = tasks.values.filter { calls[$0].taskEnd == nil && !calls[$0].stoppedByRestart }
            guard !stopped.isEmpty else { return }
            for index in stopped {
                calls[index].stoppedByRestart = true
            }
            ensureOpen()
            note(step)
            addNotice(
                ChatNotice(
                    kind: .system, title: stopped.count == 1 ? "Background task stopped" : "Background tasks stopped",
                    detail: "Antigravity CLI restarted."), step)
        }

        /// A background task ended. Its end comes as a system message, and
        /// after the turn's reply it starts a turn of its own: the agent
        /// replies to it.
        private mutating func readTaskEnd(_ step: AgyStep, _ end: (taskID: String, wasCanceled: Bool, result: String)) {
            var command: String?
            if let index = tasks[end.taskID] {
                calls[index].taskEnd = AgyToolCall.TaskEnd(
                    wasCanceled: end.wasCanceled, result: end.result,
                    line: ChatOutputReference(offset: step.offset, length: step.length))
                command = calls[index].command
            }
            if open?.hasReply ?? true {
                if let open { close(open, ending: .completed, interruptedNotice: false) }
                open = OpenTurn(turn: nil, isAboveWindow: false, startedAt: step.createdAt, isCompact: false)
            }
            note(step)
            var detail = command.map { [$0] } ?? []
            if !end.wasCanceled, let code = AgyToolCall.exitCode(in: end.result) {
                detail.append("Exit code \(code)")
            }
            addNotice(
                ChatNotice(
                    kind: .taskNotification,
                    title: end.wasCanceled ? "Background command canceled" : "Background command finished",
                    detail: detail.isEmpty ? nil : detail.joined(separator: " · ")), step)
        }

        private mutating func readCheckpoint(_ step: AgyStep) {
            ensureOpen()
            note(step)
            place(.divider(.compaction(summary: Self.summary(in: step.content))), id: Self.id(step), step)
            // `/compact` is answered by its checkpoint; one agy makes by
            // itself comes mid-turn, and the turn goes on.
            if open?.isCompact == true { open?.hasReply = true }
        }

        private mutating func readError(_ step: AgyStep) {
            ensureOpen()
            note(step)
            let text = step.error ?? step.content.map { $0.hasPrefix("Error: ") ? String($0.dropFirst(7)) : $0 }
            addNotice(Self.notice(kind: .error, title: "Antigravity CLI hit an error", text: text), step)
            // agy carries on after one (1.5.1): only a later reply ends the
            // turn.
            open?.hasReply = false
        }

        // MARK: Tools

        /// Builds each call's row in its placeholder's place, and offers
        /// every open call to the Blocked card, whatever herdr reports: an
        /// idle agy can be asking about a command, whose row reads `no
        /// result`, and a card's answer waits on its call to resolve.
        private mutating func resolveTools() {
            guard !calls.isEmpty else { return }
            var positions: [ChatEntryID: Int] = [:]
            for (index, entry) in transcript.entries.enumerated() {
                positions[entry.id] = index
            }
            for call in calls {
                guard let index = positions[call.entryID] else { continue }
                let tool = call.activity(agent: activity)
                transcript.entries[index].content = .tool(tool)
                if call.isOpen {
                    transcript.pendingRequests.append(call.pendingRequest(for: tool))
                }
            }
        }

        /// `<conv>/task-<step>` in a result agy sent to the background.
        static func backgroundTaskID(in body: String) -> String? {
            guard let start = body.range(of: "background task with task id: ") else { return nil }
            let id = body[start.upperBound...].prefix { !$0.isWhitespace }
            return id.isEmpty ? nil : String(id)
        }

        // MARK: Entries

        /// A step that is not a prompt: it belongs to the open turn, and
        /// after a turn's reply it opens one the agent started.
        private mutating func ensureOpen() {
            guard open == nil else { return }
            open = OpenTurn(turn: nil, isAboveWindow: false, startedAt: nil, isCompact: false)
        }

        /// Notes the open turn's latest step, and its start when nothing
        /// opened it yet. A wait sent to the background before it is then
        /// followed.
        private mutating func note(_ step: AgyStep) {
            for index in waits {
                calls[index].isFollowed = true
            }
            waits.removeAll()
            guard var open else { return }
            open.lastStep = step
            if !open.isAboveWindow, open.startedAt == nil { open.startedAt = step.createdAt }
            self.open = open
        }

        /// Appends an entry; the open turn's first entry starts it.
        private mutating func place(_ content: ChatEntry.Content, id: ChatEntryID, _ step: AgyStep) {
            transcript.entries.append(ChatEntry(id: id, sourceOffset: step.offset, content: content))
            guard var open, open.turn == nil, !open.isAboveWindow else { return }
            open.turn = transcript.turns.count
            transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: open.startedAt ?? step.createdAt))
            if open.lastStep == nil { open.lastStep = step }
            self.open = open
        }

        private mutating func addNotice(_ notice: ChatNotice, _ step: AgyStep) {
            place(.notice(notice), id: Self.id(step), step)
        }

        private static func id(_ step: AgyStep, _ part: String? = nil) -> ChatEntryID {
            let base = step.stepIndex.map { "agy:\($0)" } ?? "agy:@\(step.offset)"
            return ChatEntryID(part.map { "\(base):\($0)" } ?? base)
        }

        /// A notice whose detail is agy's text, capped like a row's output;
        /// Copy gives the whole text.
        private static func notice(kind: ChatNotice.Kind, title: String, text: String?) -> ChatNotice {
            let detail = text.map { ChatToolPreview(capping: $0).text }
            return ChatNotice(kind: kind, title: title, detail: detail, rawDetail: detail == text ? nil : text)
        }

        /// The `<summary>` a checkpoint holds, without the instructions agy
        /// wraps it in for the model.
        private static func summary(in content: String?) -> String? {
            guard let content, let open = content.range(of: "<summary>") else { return nil }
            let body = content[open.upperBound...]
            let end = body.range(of: "</summary>")?.lowerBound ?? body.endIndex
            let text = body[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}

extension ChatTranscriptAdapter {
    /// How Chat reads Antigravity CLI's `transcript_full.jsonl`. A turn's
    /// end is read from the steps after it, so cached entries never join
    /// live ones. agy writes a prompt sent while it works only once the
    /// turn ends, so the echo clock stops while herdr reports it busy. A
    /// turn of large file reads can fill several MB, so the timeline reads
    /// at most 4 MiB of earlier history by itself. agy's prompt log tells a
    /// send another conversation took (`AgyPromptHistoryWitness`).
    static var agy: ChatTranscriptAdapter {
        var limits = TranscriptFollower.Limits()
        limits.automaticOlderSearch = 4 << 20
        return ChatTranscriptAdapter(
            revision: AgyTranscriptReducer.revision,
            limits: limits,
            joinsCachedHistory: false,
            makeReducer: { _ in AgyTranscriptReducer() },
            echoKey: { AgyTranscriptReducer.echoKey($0) },
            echoClockStopsWhileWorking: true,
            sendWitness: AgyPromptHistoryWitness.witness)
    }
}
