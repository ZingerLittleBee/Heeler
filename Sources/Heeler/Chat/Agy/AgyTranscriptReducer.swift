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
    static let revision = 6

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
        var projection = Projection(activity: context.activity, windowStart: context.windowStart)
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
            if let end = Self.taskEnd(in: step) {
                return .preview(AgyToolCall.preview(ofTaskResult: end.result))
            }
            guard tool.kind == .agent else { return nil }
            if let error = Self.subagentError(in: step) {
                return .preview(AgyToolCall.preview(ofSubagentMessage: error.detail))
            }
            guard let text = step.systemMessageText else { return nil }
            return .preview(AgyToolCall.preview(ofSubagentMessage: text))
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

    /// A subagent error from `system`:
    /// `The subagent <role> (<type>) with id "<id>" encountered an error …: <detail>`.
    static func subagentError(in step: AgyStep) -> (subagentID: String, detail: String)? {
        guard let message = step.systemMessage, message.sender == "system" || message.sender == nil else {
            return nil
        }
        let text = message.text
        guard text.hasPrefix("The subagent "),
            let marker = text.range(of: "\" encountered an error", options: .backwards),
            let idPrefix = text[..<marker.lowerBound].range(of: " with id \"", options: .backwards)
        else { return nil }
        let id = String(text[idPrefix.upperBound..<marker.lowerBound])
        guard !id.isEmpty else { return nil }
        let tail = text[marker.upperBound...]
        let detail: String
        if let colon = tail.range(of: ": ") {
            detail = String(tail[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            detail = text
        }
        return (id, detail.isEmpty ? text : detail)
    }

    /// The notice agy adds to a conversation resumed after it restarted.
    static let restartNotice = "[Notice] All your subagents and background tasks have been stopped due to server restart"

    /// `<conv>/task-<step>` in a result agy sent to the background.
    static func backgroundTaskID(in body: String) -> String? {
        guard let start = body.range(of: "background task with task id: ") else { return nil }
        let id = body[start.upperBound...].prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    /// `conversationId` in `invoke_subagent`'s `Created the following subagent:` JSON block.
    static func launchedSubagentID(in body: String) -> String? {
        let normalized = AgyToolCall.normalized(body)
        guard normalized.hasPrefix("Created the following subagent:"),
            let brace = normalized.firstIndex(of: "{"),
            let data = normalized[brace...].data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let id = value["conversationId"]?.stringValue, !id.isEmpty
        else { return nil }
        return id
    }

    /// The JSON array at the end of a `manage_subagents` or `manage_task` `list` result.
    static func jsonArray(in body: String) -> [JSONValue] {
        let normalized = AgyToolCall.normalized(body).trimmingCharacters(in: .whitespacesAndNewlines)
        let start: String.Index
        if normalized.hasPrefix("[") {
            start = normalized.startIndex
        } else if let line = normalized.range(of: "\n[") {
            start = normalized.index(after: line.lowerBound)
        } else {
            return []
        }
        guard let data = normalized[start...].data(using: .utf8),
            case .array(let items) = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [] }
        return items
    }

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
        let windowStart: UInt64
        var transcript = ChatTranscript()
        var open: OpenTurn?
        var calls: [AgyToolCall] = []
        /// The latest planner response's calls still waiting for a result,
        /// first in line first.
        var pending: [Int] = []
        var tasks: [String: Int] = [:]
        var subagents: [String: Int] = [:]
        var backgroundIndexByID: [String: Int] = [:]
        /// Waits sent to the background (`AgyToolCall.waitTools`) no step
        /// has come after yet.
        var waits: [Int] = []
        /// The steps read so far, for a step agy wrote twice.
        var seenSteps: Set<Int> = []

        init(activity: ChatAgentActivity, windowStart: UInt64 = 0) {
            self.activity = activity
            self.windowStart = windowStart
            open = OpenTurn(turn: nil, isAboveWindow: true, startedAt: nil, isCompact: false)
        }

        mutating func placeForkDivider(_ first: AgyStep) {
            transcript.entries.append(
                ChatEntry(
                    id: ChatEntryID("agy:\(first.stepIndex ?? 0):history"), sourceOffset: first.offset,
                    content: .divider(
                        ChatDivider(
                            kind: .historyUnavailable,
                            detail: String(
                                localized: "Earlier messages are in the conversation this one was forked from.",
                                comment: "Under the divider atop a forked Antigravity CLI conversation in Chat")))))
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
            } else if let open {
                // agy writes nothing on Esc, so a turn Stop just ended reads
                // as still open.
                transcript.openTurnBackgroundCommands = open.calls.compactMap { calls[$0].backgroundCommand }
            }
            resolveTools()
            return transcript
        }

        // MARK: Prompts

        private mutating func readPrompt(_ step: AgyStep) {
            closeForNextPrompt()
            if let selection = step.modelSelection {
                transcript.model = selection.model
                transcript.effort = selection.effort
            }
            let request = step.request
            let text = request?.text ?? ""
            let images = step.media.filter { $0.mimeType?.hasPrefix("image/") == true }.count
            open = OpenTurn(turn: nil, isAboveWindow: false, startedAt: step.createdAt, isCompact: text == "/compact")
            let id = Self.id(step)
            let content: ChatEntry.Content =
                text.isEmpty && images == 0
                ? .notice(ChatNotice(kind: .system, title: String(localized: "Message exceeds the preview limit")))
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
                        content: .notice(ChatNotice(kind: .interrupted, title: String(localized: "Interrupted")))))
            }
            if let index = turn.turn {
                transcript.turns[index].ending = ending
            } else if turn.isAboveWindow, turn.hasSteps, transcript.precedingTurnEnd == nil {
                transcript.precedingTurnEnd = ChatTurnEnd(ending: ending)
            }
        }

        // MARK: Agent steps

        private mutating func readResponse(_ step: AgyStep) {
            if let resolved = step.plannerModel {
                transcript.model = resolved.model
                transcript.effort = resolved.effort
            }
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
                calls.append(AgyToolCall(entryID: entryID, call: call, offset: step.offset, createdAt: step.createdAt))
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
            if step.status == .running {
                // A wait gets no task end, so it is no task a restart stops.
                if AgyToolCall.waitTools.contains(calls[index].name) {
                    waits.append(index)
                } else if let taskID = Self.backgroundTaskID(in: step.resultBody) {
                    calls[index].taskID = taskID
                    tasks[taskID] = index
                    // Daemons (`IsDaemon: true`) are meant to outlive turns
                    // indefinitely, so Chat neither lists them as Background
                    // Work nor holds active polling for them.
                    if !calls[index].isDaemon {
                        let kind: ChatBackgroundWorkItem.Kind = calls[index].name == "run_workflow" ? .workflow : .command
                        let (rawTitle, subtitle) = calls[index].titles
                        let fallback = kind == .workflow ? String(localized: "Workflow") : String(localized: "Command")
                        let title = rawTitle == calls[index].name ? fallback : rawTitle
                        addBackgroundWork(
                            ChatBackgroundWorkItem(
                                id: Self.taskWorkID(taskID), kind: kind, title: title, subtitle: subtitle,
                                state: .running, launchOffset: calls[index].callOffset,
                                launchedAt: step.createdAt ?? calls[index].callCreatedAt))
                    }
                }
                return
            }
            guard step.status == .done else { return }
            switch calls[index].name {
            case "invoke_subagent":
                guard let subagentID = Self.launchedSubagentID(in: step.resultBody) else { return }
                calls[index].subagentID = subagentID
                subagents[subagentID] = index
                let role = calls[index].args?["Role"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let typeName = calls[index].args?["TypeName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                let title = role ?? typeName ?? String(localized: "Subagent")
                addBackgroundWork(
                    ChatBackgroundWorkItem(
                        id: Self.subagentWorkID(subagentID), kind: .subagent, title: title,
                        subtitle: typeName == title ? nil : typeName, state: .running,
                        launchOffset: calls[index].callOffset,
                        launchedAt: step.createdAt ?? calls[index].callCreatedAt))
            case "send_message":
                guard let recipient = calls[index].args?["Recipient"]?.stringValue, !recipient.isEmpty else { return }
                let resumedAt = step.createdAt ?? calls[index].callCreatedAt
                if let subCall = subagents[recipient] {
                    calls[subCall].subagentEnd = nil
                    calls[subCall].stoppedByRestart = false
                }
                if let workIndex = backgroundIndexByID[Self.subagentWorkID(recipient)] {
                    if transcript.backgroundWork[workIndex].state != .running {
                        transcript.backgroundWork[workIndex].state = .running
                        transcript.backgroundWork[workIndex].endOffset = nil
                        transcript.backgroundWork[workIndex].endedAt = nil
                        transcript.backgroundWork[workIndex].launchedAt = resumedAt
                    }
                    transcript.backgroundWork[workIndex].lastActivityAt = resumedAt
                }
            case "manage_subagents":
                readManageSubagents(callIndex: index, result: step)
            case "manage_task":
                readManageTask(callIndex: index, result: step)
            default:
                break
            }
        }

        private mutating func readManageSubagents(callIndex: Int, result: AgyStep) {
            let args = calls[callIndex].args
            switch args?["Action"]?.stringValue {
            case "kill":
                guard case .array(let values)? = args?["ConversationIds"] else { return }
                for subagentID in values.compactMap(\.stringValue) where !subagentID.isEmpty {
                    if let subCall = subagents[subagentID], calls[subCall].subagentEnd == nil,
                        !calls[subCall].stoppedByRestart
                    {
                        calls[subCall].subagentEnd = .init(outcome: .killed, text: nil, line: nil)
                    }
                    let workID = Self.subagentWorkID(subagentID)
                    if let workIndex = backgroundIndexByID[workID],
                        transcript.backgroundWork[workIndex].state == .running
                    {
                        endBackgroundWork(
                            id: workID, state: .stopped, offset: result.offset, step: result,
                            fallbackDate: result.createdAt ?? calls[callIndex].callCreatedAt)
                    }
                }
            case "kill_all":
                for subCall in subagents.values
                where calls[subCall].subagentEnd == nil && !calls[subCall].stoppedByRestart {
                    calls[subCall].subagentEnd = .init(outcome: .killed, text: nil, line: nil)
                }
                for workIndex in transcript.backgroundWork.indices
                where transcript.backgroundWork[workIndex].kind == .subagent
                    && transcript.backgroundWork[workIndex].state == .running
                {
                    transcript.backgroundWork[workIndex].state = .stopped
                    transcript.backgroundWork[workIndex].endOffset = result.offset
                    transcript.backgroundWork[workIndex].endedAt = result.createdAt ?? calls[callIndex].callCreatedAt
                }
            case "list":
                for entry in Self.jsonArray(in: result.resultBody) {
                    guard let subagentID = entry["conversationId"]?.stringValue, !subagentID.isEmpty else { continue }
                    let state = entry["state"]?.stringValue
                    let lastStepTime = entry["lastStepTime"]?.stringValue.flatMap(AgyStep.date)
                    let seenAt = [lastStepTime, result.createdAt].compactMap(\.self).max()
                    let workID = Self.subagentWorkID(subagentID)
                    if let workIndex = backgroundIndexByID[workID] {
                        guard transcript.backgroundWork[workIndex].state == .running else { continue }
                        switch state {
                        case "running", "waiting_for_dependents":
                            transcript.backgroundWork[workIndex].lastActivityAt =
                                [transcript.backgroundWork[workIndex].lastActivityAt, seenAt].compactMap(\.self).max()
                        case "idle":
                            endBackgroundWork(
                                id: workID, state: .completed, offset: result.offset, step: result,
                                fallbackDate: lastStepTime ?? result.createdAt)
                            if let subCall = subagents[subagentID], calls[subCall].subagentEnd == nil {
                                calls[subCall].subagentEnd = .init(outcome: .completed, text: nil, line: nil)
                            }
                        case "errored":
                            let detail = entry["stateDetail"]?.stringValue
                            endBackgroundWork(
                                id: workID, state: .failed, offset: result.offset, step: result,
                                fallbackDate: lastStepTime ?? result.createdAt)
                            if let subCall = subagents[subagentID], calls[subCall].subagentEnd == nil {
                                calls[subCall].subagentEnd = .init(outcome: .failed, text: detail, line: nil)
                            }
                        default:
                            break
                        }
                    } else if windowStart > 0, state == "running" || state == "waiting_for_dependents" {
                        let role = entry["role"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let typeName = entry["type"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let title = role ?? typeName ?? String(localized: "Subagent")
                        addBackgroundWork(
                            ChatBackgroundWorkItem(
                                id: workID, kind: .subagent, title: title,
                                subtitle: typeName == title ? nil : typeName, state: .running, launchOffset: 0,
                                launchedAt: lastStepTime ?? result.createdAt, lastActivityAt: seenAt))
                    }
                }
            default:
                break
            }
        }

        private mutating func readManageTask(callIndex: Int, result: AgyStep) {
            let args = calls[callIndex].args
            switch args?["Action"]?.stringValue {
            case "kill":
                guard let taskID = args?["TaskId"]?.stringValue, !taskID.isEmpty else { return }
                if let taskCall = tasks[taskID], calls[taskCall].taskEnd == nil, !calls[taskCall].stoppedByRestart {
                    calls[taskCall].killedByManageTask = true
                }
                let workID = Self.taskWorkID(taskID)
                if let workIndex = backgroundIndexByID[workID], transcript.backgroundWork[workIndex].state == .running {
                    endBackgroundWork(
                        id: workID, state: .stopped, offset: result.offset, step: result,
                        fallbackDate: result.createdAt ?? calls[callIndex].callCreatedAt)
                }
            case "status":
                guard let taskID = args?["TaskId"]?.stringValue, !taskID.isEmpty,
                    result.resultBody.contains("\nStatus: RUNNING") || result.resultBody.hasPrefix("Status: RUNNING"),
                    let workIndex = backgroundIndexByID[Self.taskWorkID(taskID)],
                    transcript.backgroundWork[workIndex].state == .running,
                    let seenAt = result.createdAt
                else { return }
                transcript.backgroundWork[workIndex].lastActivityAt =
                    [transcript.backgroundWork[workIndex].lastActivityAt, seenAt].compactMap(\.self).max()
            case "list":
                for entry in Self.jsonArray(in: result.resultBody) {
                    guard let taskID = entry["taskId"]?.stringValue, !taskID.isEmpty else { continue }
                    let toolName = entry["toolName"]?.stringValue ?? ""
                    guard !AgyToolCall.waitTools.contains(toolName) else { continue }
                    let workID = Self.taskWorkID(taskID)
                    if let workIndex = backgroundIndexByID[workID] {
                        if transcript.backgroundWork[workIndex].state == .running, let seenAt = result.createdAt {
                            transcript.backgroundWork[workIndex].lastActivityAt =
                                [transcript.backgroundWork[workIndex].lastActivityAt, seenAt].compactMap(\.self).max()
                        }
                    } else if windowStart > 0 {
                        let kind: ChatBackgroundWorkItem.Kind = toolName == "run_workflow" ? .workflow : .command
                        let desc = entry["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let summary = entry["toolSummary"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                        let fallback = kind == .workflow ? String(localized: "Workflow") : String(localized: "Command")
                        let title = desc ?? summary ?? fallback
                        let startTime = entry["startTime"]?.stringValue.flatMap(AgyStep.date)
                        addBackgroundWork(
                            ChatBackgroundWorkItem(
                                id: workID, kind: kind, title: title, subtitle: summary == title ? nil : summary,
                                state: .running, launchOffset: 0, launchedAt: startTime ?? result.createdAt,
                                lastActivityAt: result.createdAt))
                    }
                }
            default:
                break
            }
        }

        private mutating func readSystemMessage(_ step: AgyStep) {
            if let end = AgyTranscriptReducer.taskEnd(in: step) {
                readTaskEnd(step, end)
                return
            }
            if let error = AgyTranscriptReducer.subagentError(in: step) {
                let line = ChatOutputReference(offset: step.offset, length: step.length)
                if let subCall = subagents[error.subagentID] {
                    calls[subCall].subagentEnd = .init(outcome: .failed, text: error.detail, line: line)
                }
                endBackgroundWork(
                    id: Self.subagentWorkID(error.subagentID), state: .failed, offset: step.offset, step: step)
                return
            }
            if let message = step.systemMessage, let sender = message.sender {
                let workID = Self.subagentWorkID(sender)
                if subagents[sender] != nil || backgroundIndexByID[workID] != nil {
                    let line = ChatOutputReference(offset: step.offset, length: step.length)
                    if let subCall = subagents[sender] {
                        calls[subCall].subagentEnd = .init(outcome: .completed, text: message.text, line: line)
                    }
                    endBackgroundWork(id: workID, state: .completed, offset: step.offset, step: step)
                    return
                }
            }
            guard let text = step.systemMessageText, text.hasPrefix(AgyTranscriptReducer.restartNotice) else {
                // Messages from other agents and reminders are the agent's
                // context, not the conversation.
                return
            }
            // agy adds the notice to every resumed conversation; it says
            // something only when a task or subagent was still running.
            let stoppedTasks = tasks.values.filter {
                calls[$0].taskEnd == nil && !calls[$0].killedByManageTask && !calls[$0].stoppedByRestart
            }
            let stoppedSubagents = subagents.values.filter {
                calls[$0].subagentEnd == nil && !calls[$0].stoppedByRestart
            }
            var stoppedWork = 0
            for workIndex in transcript.backgroundWork.indices where transcript.backgroundWork[workIndex].state == .running {
                let launchedAt = transcript.backgroundWork[workIndex].launchedAt
                transcript.backgroundWork[workIndex].state = .stopped
                transcript.backgroundWork[workIndex].endOffset = step.offset
                transcript.backgroundWork[workIndex].endedAt = Self.endDate(of: step, launchedAt: launchedAt)
                stoppedWork += 1
            }
            let stoppedCount = max(stoppedTasks.count + stoppedSubagents.count, stoppedWork)
            guard stoppedCount > 0 else { return }
            for index in stoppedTasks {
                calls[index].stoppedByRestart = true
            }
            for index in stoppedSubagents {
                calls[index].stoppedByRestart = true
            }
            ensureOpen()
            note(step)
            addNotice(
                ChatNotice(
                    kind: .system,
                    title: String(
                        localized: "\(stoppedCount) background tasks stopped",
                        comment: "A Chat notice: how many background tasks Antigravity CLI stopped when it restarted"),
                    detail: String(
                        localized: "Antigravity CLI restarted.",
                        comment: "Under a Chat notice that counts the background tasks Antigravity CLI stopped")),
                step)
        }

        /// A background task ended. Its end comes as a system message, and
        /// after the turn's reply it starts a turn of its own: the agent
        /// replies to it. One agy held for the next prompt ends the turn
        /// before that prompt.
        private mutating func readTaskEnd(_ step: AgyStep, _ end: (taskID: String, wasCanceled: Bool, result: String)) {
            var command: String?
            if let index = tasks[end.taskID] {
                calls[index].taskEnd = AgyToolCall.TaskEnd(
                    wasCanceled: end.wasCanceled, result: end.result,
                    line: ChatOutputReference(offset: step.offset, length: step.length))
                command = calls[index].command
            }
            let exitCode = end.wasCanceled ? nil : AgyToolCall.exitCode(in: end.result)
            let workState: ChatBackgroundWorkItem.State =
                end.wasCanceled ? .stopped : ((exitCode ?? 0) == 0 ? .completed : .failed)
            var detail = command.map { [$0] } ?? []
            if let code = exitCode {
                detail.append(String(localized: "Exit code \(code)"))
            }
            let notice = ChatNotice(
                kind: .taskNotification,
                title: end.wasCanceled
                    ? String(
                        localized: "Background command canceled",
                        comment: "Title of a Chat notice when Antigravity CLI cancels a background command")
                    : String(localized: "Background command finished"),
                detail: detail.isEmpty ? nil : detail.joined(separator: " · "))
            // agy holds a task's end until the next prompt and writes a
            // cancel from `/tasks` just after it (1.5.3), though the task
            // ended before that prompt: it shows at the end of the turn
            // before, where a held finish falls. The open turn's latest step
            // stays the prompt, so a second held end follows the first.
            if let open, let turn = open.turn, open.lastStep?.kind == .userInput,
                let prompt = transcript.entries.lastIndex(where: { $0.id == transcript.turns[turn].firstEntryID })
            {
                let promptOffset = transcript.entries[prompt].sourceOffset
                endBackgroundWork(
                    id: Self.taskWorkID(end.taskID), state: workState, offset: promptOffset, step: step)
                transcript.entries.insert(
                    ChatEntry(id: Self.id(step), sourceOffset: step.offset, content: .notice(notice)), at: prompt)
                return
            }
            endBackgroundWork(id: Self.taskWorkID(end.taskID), state: workState, offset: step.offset, step: step)
            if open?.hasReply ?? true {
                if let open { close(open, ending: .completed, interruptedNotice: false) }
                open = OpenTurn(turn: nil, isAboveWindow: false, startedAt: step.createdAt, isCompact: false)
            }
            note(step)
            addNotice(notice, step)
        }

        private mutating func readCheckpoint(_ step: AgyStep) {
            let opensWindow = open.map { $0.isAboveWindow && !$0.hasSteps } ?? false
            ensureOpen()
            note(step)
            place(.divider(.compaction(summary: Self.summary(in: step.content))), id: Self.id(step), step)
            // `/compact` is answered by its checkpoint; one agy makes by
            // itself comes mid-turn, between a result and a planner
            // response (all 10 in the census), and the turn goes on. A
            // checkpoint the window starts at may answer a `/compact` cut
            // off above it, so it counts as the reply too: a planner
            // response after it takes that back, and only a prompt right
            // after it, as `/compact` gets, keeps it.
            if open?.isCompact == true || opensWindow { open?.hasReply = true }
        }

        private mutating func readError(_ step: AgyStep) {
            ensureOpen()
            note(step)
            let text = step.error ?? step.content.map { $0.hasPrefix("Error: ") ? String($0.dropFirst(7)) : $0 }
            addNotice(
                Self.notice(kind: .error, title: String(localized: "Antigravity CLI hit an error"), text: text), step)
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

        static func backgroundTaskID(in body: String) -> String? {
            AgyTranscriptReducer.backgroundTaskID(in: body)
        }

        static func launchedSubagentID(in body: String) -> String? {
            AgyTranscriptReducer.launchedSubagentID(in: body)
        }

        static func jsonArray(in body: String) -> [JSONValue] {
            AgyTranscriptReducer.jsonArray(in: body)
        }

        private static func taskWorkID(_ taskID: String) -> String { "agy:task:\(taskID)" }
        private static func subagentWorkID(_ subagentID: String) -> String { "agy:subagent:\(subagentID)" }

        private mutating func addBackgroundWork(_ item: ChatBackgroundWorkItem) {
            if let existing = backgroundIndexByID[item.id] {
                transcript.backgroundWork[existing] = item
            } else {
                backgroundIndexByID[item.id] = transcript.backgroundWork.count
                transcript.backgroundWork.append(item)
            }
        }

        private mutating func endBackgroundWork(
            id: String, state: ChatBackgroundWorkItem.State, offset: UInt64, step: AgyStep,
            fallbackDate: Date? = nil
        ) {
            guard let index = backgroundIndexByID[id] else { return }
            let launchedAt = transcript.backgroundWork[index].launchedAt
            transcript.backgroundWork[index].state = state
            transcript.backgroundWork[index].endOffset = offset
            transcript.backgroundWork[index].endedAt = fallbackDate ?? Self.endDate(of: step, launchedAt: launchedAt)
        }

        private static func endDate(of step: AgyStep, launchedAt: Date?) -> Date? {
            if let messageDate = step.systemMessage?.timestamp {
                if let launchedAt, messageDate < launchedAt {
                    return step.createdAt ?? messageDate
                }
                return messageDate
            }
            return step.createdAt
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
