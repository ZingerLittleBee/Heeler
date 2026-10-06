import Foundation

/// Turns the current branch into Chat entries (brief §3, §4 and §6), plus the
/// requests a Blocked card matches and the prompts pending-echo matching
/// looks for.
///
/// Entries follow the selected records in byte-offset order, one per content
/// block. A tool call's row takes everything from its result (status, note,
/// preview, diff), so a record that only completes an earlier row adds none
/// of its own: tool results, a command's output, the interrupt marker after a
/// decline.
enum ClaudeTranscriptProjection {
    /// Origins whose meta messages the SDK shows as system rows (`$C`).
    static let visibleMetaOrigins: Set<String> = ["channel", "observer", "observer-activity", "slack-ping", "peer"]
    /// `promptSource` values of prompts a person typed. `queued` marks one
    /// typed while a turn was running.
    static let typedPromptSources: Set<String> = ["typed", "queued"]

    static func transcript(
        index: ClaudeTranscriptIndex, chain: ClaudeChain, role: ClaudeTranscriptReducer.Role,
        context: ChatProjectionContext
    ) -> ChatTranscript {
        var builder = Builder(chain: chain, indexed: index.records, role: role, activity: context.activity)
        builder.build()
        return ChatTranscript(
            entries: builder.entries, title: index.title,
            needsOlderHistory: context.windowStart > 0,
            pendingRequests: builder.pendingRequests,
            recordedPrompts: role == .main ? recordedPrompts(index, entryByRecord: builder.entryByRecord) : [],
            links: index.links, diagnostics: index.diagnostics)
    }

    // MARK: - Recorded prompts

    /// Every prompt a person typed, in file order, from all records rather
    /// than only the current branch: an echo is matched by where it lands in
    /// the file. Task notifications and other machine input never count.
    static func recordedPrompts(
        _ index: ClaudeTranscriptIndex, entryByRecord: [String: ChatEntryID]
    ) -> [ChatRecordedPrompt] {
        var prompts: [ChatRecordedPrompt] = []
        for record in index.recordsByPosition where !record.isSidechain && record.teamName == nil {
            guard let text = typedText(of: record, indexed: index.records) else { continue }
            prompts.append(
                ChatRecordedPrompt(offset: record.byteOffset, text: text, entryID: entryByRecord[record.uuid]))
        }
        // A queued prompt is recorded first as an enqueue and later as the
        // record that delivers it; the enqueue points at that record's entry.
        var enqueued: [ChatRecordedPrompt] = []
        for operation in index.queueOperations.values where operation.operation == "enqueue" {
            guard let content = operation.content, let text = promptText(content) else { continue }
            let key = ClaudeTranscriptReducer.echoKey(text)
            let delivery = prompts.first {
                $0.offset > operation.offset && ClaudeTranscriptReducer.echoKey($0.text) == key
            }
            enqueued.append(ChatRecordedPrompt(offset: operation.offset, text: text, entryID: delivery?.entryID))
        }
        return (prompts + enqueued).sorted { $0.offset < $1.offset }
    }

    private static func typedText(of record: ClaudeRecord, indexed: [String: ClaudeRecord]) -> String? {
        switch record.kind {
        case .user:
            guard record.toolResults.isEmpty, !record.isMeta, !record.isCompactSummary,
                record.sourceToolUseID == nil, isHuman(record.originKind),
                record.promptSource.map(typedPromptSources.contains) ?? true
            else { return nil }
            return promptText(record.texts.joined(separator: "\n"))
        case .attachment("queued_command"):
            guard let queued = record.attachment?.queuedCommand, !queued.isMeta,
                queued.commandMode == nil || queued.commandMode == "prompt", isHuman(queued.originKind)
            else { return nil }
            // The user record written for it is recorded instead.
            if let source = queued.sourceUUID, indexed[source] != nil { return nil }
            return promptText(queued.text)
        case .system("local_command"):
            guard case .command(let typed) = ClaudeUserText.classify(record.system?.content ?? "") else { return nil }
            return (record.system?.commandRun ?? typed).displayText
        default:
            return nil
        }
    }

    /// A prompt's text as typed, a command as `/name args`, or a shell-mode
    /// command as `!command`, the way it was typed.
    static func promptText(_ text: String) -> String? {
        guard !ClaudeUserText.isMarker(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        switch ClaudeUserText.classify(text) {
        case .prompt(let prompt): return prompt.isEmpty ? nil : prompt
        case .command(let invocation): return invocation.displayText
        case .bashInput(let command): return command.isEmpty ? nil : "!\(command)"
        default: return nil
        }
    }

    static func isHuman(_ originKind: String?) -> Bool {
        originKind == nil || originKind == "human"
    }

    static func modelChangeTitle(from: String?, to: String?) -> String {
        switch (from, to) {
        case (let from?, let to?): "Switched from \(from) to \(to)"
        case (nil, let to?): "Switched to \(to)"
        default: "Switched model"
        }
    }
}

// MARK: - Entries

private struct Builder {
    /// A tool call's result, and the text blocks after it in the same record
    /// (a note the user added to an approval).
    struct Answer {
        var record: ClaudeRecord
        var result: ClaudeToolResult
        var trailingTexts: [String] = []

        var outcome: ClaudeToolOutcome {
            ClaudeToolOutcome(result: result, details: record.toolResult, trailingTexts: trailingTexts)
        }
    }

    let chain: ClaudeChain
    /// Every indexed record, selected or not.
    let indexed: [String: ClaudeRecord]
    let role: ClaudeTranscriptReducer.Role
    let activity: ChatAgentActivity

    private(set) var entries: [ChatEntry] = []
    private(set) var pendingRequests: [ChatPendingRequest] = []
    /// The first entry each record placed.
    private(set) var entryByRecord: [String: ChatEntryID] = [:]

    private var selected: [String: ClaudeRecord] = [:]
    private var children: [String: [ClaudeRecord]] = [:]
    private var answers: [String: Answer] = [:]
    /// Offsets of records that start a new turn or end one, ascending.
    private var turnBoundaries: [UInt64] = []
    /// The latest notification for each background call.
    private var notifications: [String: ClaudeTaskNotification] = [:]
    /// Notifications shown from user records, so a queued copy is not shown
    /// twice.
    private var notificationKeys: Set<String> = []
    private var agentsKilled: [UInt64] = []
    /// `plan_mode_exit` paths by the record they follow (the approval).
    private var planExitPaths: [String: String] = [:]
    private var entryIDs: Set<ChatEntryID> = []
    /// Records whose content an earlier entry already shows.
    private var consumed: Set<String> = []
    private var compactionEntry: Int?

    init(
        chain: ClaudeChain, indexed: [String: ClaudeRecord], role: ClaudeTranscriptReducer.Role,
        activity: ChatAgentActivity
    ) {
        self.chain = chain
        self.indexed = indexed
        self.role = role
        self.activity = activity
        for record in chain.records {
            selected[record.uuid] = record
            if let parent = chain.parents[record.uuid] {
                children[parent, default: []].append(record)
            }
            collectAnswers(in: record)
            if Self.isTurnBoundary(record) {
                turnBoundaries.append(record.byteOffset)
            }
            switch record.kind {
            case .system("agents_killed"):
                agentsKilled.append(record.byteOffset)
            case .attachment("plan_mode_exit"):
                if let path = record.attachment?.planFilePath, let parent = chain.parents[record.uuid] {
                    planExitPaths[parent] = path
                }
            default:
                break
            }
            if let notification = Self.notification(in: record) {
                if let callID = notification.toolUseID { notifications[callID] = notification }
                if record.kind == .user { notificationKeys.insert(Self.key(of: notification)) }
            }
        }
    }

    mutating func build() {
        for record in chain.records where !consumed.contains(record.uuid) {
            if role == .main, record.isSidechain || record.teamName != nil { continue }
            switch record.kind {
            case .assistant: addAssistant(record)
            case .user: addUser(record)
            case .system(let subtype): addSystem(record, subtype: subtype)
            case .attachment("queued_command"): addQueuedCommand(record)
            case .attachment, .progress, .unknown: break
            }
        }
    }

    // MARK: Assistant

    private mutating func addAssistant(_ record: ClaudeRecord) {
        for (position, block) in record.blocks.enumerated() {
            // One block per record in 2.1.291; older releases wrote several.
            let suffix = position == 0 ? "" : "#\(position)"
            switch block {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if record.isAPIError {
                    let parts = ClaudeText.noticeParts(text)
                    add(
                        "notice:\(record.uuid)\(suffix)", at: record,
                        .notice(ChatNotice(kind: .error, title: parts.title, detail: parts.detail)))
                } else {
                    add("text:\(record.uuid)\(suffix)", at: record, .assistant(ChatAssistantMessage(text: text)))
                }
            case .thinking(let text):
                add(
                    "think:\(record.uuid)\(suffix)", at: record,
                    .reasoning(ChatReasoning(text: text, durationMilliseconds: record.thinkingDurationMilliseconds)))
            case .redactedThinking:
                add(
                    "think:\(record.uuid)\(suffix)", at: record,
                    .reasoning(ChatReasoning(text: "", durationMilliseconds: record.thinkingDurationMilliseconds)))
            case .toolUse(let use):
                addToolUse(use, in: record)
            case .fallback(let from, let to):
                add(
                    "notice:\(record.uuid)\(suffix)", at: record,
                    .notice(
                        ChatNotice(
                            kind: .modelChange, title: ClaudeTranscriptProjection.modelChangeTitle(from: from, to: to))))
            case .toolResult, .image, .other:
                break
            }
        }
    }

    private mutating func addToolUse(_ use: ClaudeToolUse, in record: ClaudeRecord) {
        let callID = use.id.isEmpty ? nil : use.id
        let entryID = "tool:\(callID ?? record.uuid)"
        let answer = callID.flatMap { answers[$0] }
        let outcome = answer?.outcome
        let structured = answer?.record.toolResult?.result
        var status = outcome?.status ?? unansweredStatus(after: record.byteOffset)
        if status == .succeeded, let launch = structured?.status, launch == "async_launched" || launch == "remote_launched" {
            status = backgroundStatus(callID, launchedAt: record.byteOffset)
        }

        let placed: Bool
        switch use.name {
        case "ExitPlanMode":
            let filePath =
                structured?.filePath ?? answer.flatMap { planExitPaths[$0.record.uuid] } ?? use.input.planFilePath
            placed = add(
                entryID, at: record,
                .plan(
                    ChatPlan(
                        text: structured?.plan ?? use.input.plan ?? "", filePath: filePath, status: status,
                        note: outcome?.note, callID: callID)))
        case "EnterPlanMode" where status == .succeeded:
            placed = add(entryID, at: record, .notice(ChatNotice(kind: .planMode, title: "Entered plan mode")))
        default:
            placed = add(entryID, at: record, .tool(toolRow(for: use, status: status, answer: answer)))
        }

        guard placed, answer == nil, !turnEnded(after: record.byteOffset) else { return }
        let summary = ClaudeToolSummary(use)
        pendingRequests.append(
            ChatPendingRequest(
                entryID: ChatEntryID(entryID), callID: callID, kind: summary.kind, toolName: use.name,
                summary: ClaudeToolSummary.pendingSummary(use), detail: ClaudeToolSummary.pendingDetail(use),
                questions: use.input.questions,
                planFilePath: use.name == "ExitPlanMode" ? use.input.planFilePath : nil))
    }

    private func toolRow(for use: ClaudeToolUse, status: ChatToolActivity.Status, answer: Answer?) -> ChatToolActivity {
        let summary = ClaudeToolSummary(use)
        var row = ChatToolActivity(
            kind: summary.kind, name: use.name, title: summary.title, subtitle: summary.subtitle, status: status,
            callID: use.id.isEmpty ? nil : use.id)
        let structured = answer?.record.toolResult?.result
        if let answer {
            let outcome = answer.outcome
            row.note = outcome.note
            row.preview = ClaudeToolSummary.preview(
                for: use, result: answer.result, details: answer.record.toolResult, outcome: outcome)
            row.output = ChatOutputReference(offset: answer.record.byteOffset, length: answer.record.byteLength)
            row.exitCode = ClaudeToolSummary.exitCode(for: use, result: answer.result)
            if case .succeeded = outcome {
                row.diff = structured?.diff
            }
        }
        // A background agent reports through its notification.
        if row.preview == nil, !use.id.isEmpty, let report = notifications[use.id]?.result, !report.isEmpty {
            row.preview = ChatToolPreview(capping: report)
        }
        if use.name == "AskUserQuestion" {
            let given = structured?.answers ?? [:]
            row.questions = use.input.questions.map { question in
                var question = question
                question.answer = given[question.text]
                return question
            }
        }
        return row
    }

    /// A call without a result: still running, waiting on the user, or left
    /// behind by a turn that moved on.
    private func unansweredStatus(after offset: UInt64) -> ChatToolActivity.Status {
        if turnEnded(after: offset) { return .noResult }
        switch activity {
        case .blocked: return .awaitingApproval
        case .idle: return .noResult
        case .working, .unknown: return .running
        }
    }

    /// A background agent runs until its task notification arrives.
    private func backgroundStatus(_ callID: String?, launchedAt offset: UInt64) -> ChatToolActivity.Status {
        if let callID, let notification = notifications[callID] {
            switch notification.status {
            case "failed": return .failed
            case "killed": return .interrupted
            case "blocked": return .awaitingApproval
            default: return .succeeded
            }
        }
        if agentsKilled.contains(where: { $0 > offset }) { return .interrupted }
        return .running
    }

    private func turnEnded(after offset: UInt64) -> Bool {
        guard let last = turnBoundaries.last else { return false }
        return last > offset
    }

    // MARK: User

    private mutating func addUser(_ record: ClaudeRecord) {
        guard record.toolResults.isEmpty else { return }
        if record.isCompactSummary {
            attachCompactionSummary(record)
            return
        }
        // Messages a tool call produced, such as a skill a Skill call loaded.
        guard record.sourceToolUseID == nil else { return }
        let text = record.texts.joined(separator: "\n")
        if record.isMeta {
            guard let origin = record.originKind, ClaudeTranscriptProjection.visibleMetaOrigins.contains(origin) else {
                return
            }
            switch ClaudeUserText.classify(text) {
            case .prompt(let message), .external(let message): addSystemNotice(message, at: record)
            default: break
            }
            return
        }
        if Self.isInterruptMarker(record) {
            addInterruptMarker(record, text: text)
            return
        }
        let wasQueued = record.promptSource == "queued"
        switch ClaudeUserText.classify(text) {
        case .prompt(let prompt):
            guard ClaudeTranscriptProjection.isHuman(record.originKind), record.promptSource != "system" else {
                addSystemNotice(prompt, at: record)
                return
            }
            guard !prompt.isEmpty || record.imageCount > 0 else { return }
            add(
                "user:\(record.uuid)", at: record,
                .user(ChatUserMessage(text: prompt, imageCount: record.imageCount, wasQueued: wasQueued)))
        case .command(let invocation):
            // A local command records its output below it; a skill or prompt
            // command records the expanded prompt, which stays hidden.
            if let output = takeOutput(below: record, as: Self.localCommandOutput) {
                add(
                    "notice:\(record.uuid)", at: record,
                    .notice(ChatNotice(kind: .command, title: invocation.displayText, detail: output.nonEmpty)))
            } else {
                add(
                    "user:\(record.uuid)", at: record,
                    .user(
                        ChatUserMessage(
                            text: invocation.displayText, imageCount: record.imageCount, command: invocation,
                            wasQueued: wasQueued)))
            }
        case .localCommandOutput(let output):
            addOutputNotice(kind: .command, output: output, at: record)
        case .bashInput(let command):
            let output = takeOutput(below: record, as: Self.bashOutput)
            add(
                "notice:\(record.uuid)", at: record,
                .notice(ChatNotice(kind: .shellCommand, title: command, detail: output?.nonEmpty)))
        case .bashOutput(let output):
            addOutputNotice(kind: .shellCommand, output: output, at: record)
        case .taskNotification(let notification):
            add("notice:\(record.uuid)", at: record, .notice(Self.notice(for: notification)))
        case .external(let message):
            addSystemNotice(message, at: record)
        case .skillLoaded, .hidden:
            // A model-loaded skill already shows as its Skill call's row.
            break
        }
    }

    /// An interrupt marker belongs to the declined or interrupted call it
    /// follows; anywhere else it is a row of its own.
    private mutating func addInterruptMarker(_ record: ClaudeRecord, text: String) {
        if let parentID = chain.parents[record.uuid], let parent = selected[parentID],
            parent.toolResults.contains(where: {
                ClaudeToolOutcome(result: $0, details: parent.toolResult, trailingTexts: []).absorbsInterruptMarker
            })
        {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.hasPrefix("[Request interrupted by user") ? "Interrupted" : ClaudeText.noticeParts(trimmed).title
        add("notice:\(record.uuid)", at: record, .notice(ChatNotice(kind: .interrupted, title: title)))
    }

    private mutating func attachCompactionSummary(_ record: ClaudeRecord) {
        guard let index = compactionEntry, case .divider(var divider) = entries[index].content,
            divider.detail == nil
        else { return }
        let summary = record.texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        divider.detail = ChatToolPreview(capping: summary).text
        entries[index].content = .divider(divider)
    }

    // MARK: System and attachments

    private mutating func addSystem(_ record: ClaudeRecord, subtype: String) {
        let content = record.system?.content ?? ""
        switch subtype {
        case "compact_boundary":
            if add("compact:\(record.uuid)", at: record, .divider(ChatDivider(kind: .compaction))) {
                compactionEntry = entries.count - 1
            }
        case "local_command":
            addLocalCommand(record, content: content)
        case "model_refusal_fallback", "model_fallback", "model_consent_fallback":
            var notice = ChatNotice(
                kind: .modelChange,
                title: ClaudeTranscriptProjection.modelChangeTitle(
                    from: record.system?.originalModel, to: record.system?.fallbackModel))
            if !content.isEmpty {
                let parts = ClaudeText.noticeParts(content)
                notice.title = parts.title
                notice.detail = parts.detail
            }
            add("notice:\(record.uuid)", at: record, .notice(notice))
        case "agents_killed":
            add(
                "notice:\(record.uuid)", at: record,
                .notice(ChatNotice(kind: .stopped, title: "All background agents stopped")))
        default:
            // Turn timings, away summaries, informational lines, memory
            // saves and anything unknown stay hidden.
            break
        }
    }

    /// 2.1.291 writes a local command as a `local_command` record and its
    /// output as another below it (CLI `QQ`).
    private mutating func addLocalCommand(_ record: ClaudeRecord, content: String) {
        switch ClaudeUserText.classify(content) {
        case .command(let typed):
            let invocation = record.system?.commandRun ?? typed
            let output = takeOutput(below: record, as: Self.localCommandOutput)
            add(
                "notice:\(record.uuid)", at: record,
                .notice(ChatNotice(kind: .command, title: invocation.displayText, detail: output?.nonEmpty)))
        case .localCommandOutput(let output):
            if let invocation = record.system?.commandRun {
                add(
                    "notice:\(record.uuid)", at: record,
                    .notice(
                        ChatNotice(
                            kind: .command, title: invocation.displayText,
                            detail: ChatToolPreview(capping: output).text.nonEmpty)))
            } else {
                addOutputNotice(kind: .command, output: output, at: record)
            }
        case .prompt(let text):
            addOutputNotice(kind: .command, output: text, at: record)
        default:
            break
        }
    }

    /// A prompt or notification delivered while a turn was running.
    private mutating func addQueuedCommand(_ record: ClaudeRecord) {
        guard let queued = record.attachment?.queuedCommand, !queued.isMeta else { return }
        // A user record written for the same prompt shows it instead (SDK
        // `fCe`).
        if let source = queued.sourceUUID, indexed[source] != nil { return }
        let entryID = "user:\(queued.sourceUUID ?? record.uuid)"
        switch ClaudeUserText.classify(queued.text) {
        case .prompt(let prompt):
            guard ClaudeTranscriptProjection.isHuman(queued.originKind) else {
                addSystemNotice(prompt, at: record)
                return
            }
            guard !prompt.isEmpty || queued.imageCount > 0 else { return }
            add(
                entryID, at: record,
                .user(ChatUserMessage(text: prompt, imageCount: queued.imageCount, wasQueued: true)))
        case .command(let invocation):
            add(
                entryID, at: record,
                .user(
                    ChatUserMessage(
                        text: invocation.displayText, imageCount: queued.imageCount, command: invocation,
                        wasQueued: true)))
        case .taskNotification(let notification):
            guard !notificationKeys.contains(Self.key(of: notification)) else { return }
            add("notice:\(record.uuid)", at: record, .notice(Self.notice(for: notification)))
        case .external(let message):
            addSystemNotice(message, at: record)
        default:
            break
        }
    }

    // MARK: Helpers

    /// Adds an entry unless one with the same id exists; returns whether it
    /// was added.
    @discardableResult
    private mutating func add(_ rawID: String, at record: ClaudeRecord, _ content: ChatEntry.Content) -> Bool {
        let id = ChatEntryID(rawID)
        guard entryIDs.insert(id).inserted else { return false }
        entries.append(ChatEntry(id: id, sourceOffset: record.byteOffset, content: content))
        if entryByRecord[record.uuid] == nil {
            entryByRecord[record.uuid] = id
        }
        return true
    }

    private mutating func addSystemNotice(_ text: String, at record: ClaudeRecord) {
        let parts = ClaudeText.noticeParts(text)
        guard !parts.title.isEmpty else { return }
        add("notice:\(record.uuid)", at: record, .notice(ChatNotice(kind: .system, title: parts.title, detail: parts.detail)))
    }

    /// Output whose command is not on the branch.
    private mutating func addOutputNotice(kind: ChatNotice.Kind, output: String, at record: ClaudeRecord) {
        let parts = ClaudeText.noticeParts(output)
        guard !parts.title.isEmpty else { return }
        add("notice:\(record.uuid)", at: record, .notice(ChatNotice(kind: kind, title: parts.title, detail: parts.detail)))
    }

    /// The capped output a child of `record` holds, marking that child as
    /// shown. Nil when no child holds output; empty when the output is.
    private mutating func takeOutput(
        below record: ClaudeRecord, as extract: (ClaudeUserText) -> String?
    ) -> String? {
        for child in children[record.uuid] ?? [] where !consumed.contains(child.uuid) {
            let text: String
            switch child.kind {
            case .user where child.toolResults.isEmpty: text = child.texts.joined(separator: "\n")
            case .system("local_command"): text = child.system?.content ?? ""
            default: continue
            }
            guard let output = extract(ClaudeUserText.classify(text)) else { continue }
            consumed.insert(child.uuid)
            return ChatToolPreview(capping: output).text
        }
        return nil
    }

    private mutating func collectAnswers(in record: ClaudeRecord) {
        var current: Answer?
        for block in record.blocks {
            switch block {
            case .toolResult(let result):
                if let current { store(current) }
                current = Answer(record: record, result: result)
            case .text(let text):
                current?.trailingTexts.append(text)
            default:
                break
            }
        }
        if let current { store(current) }
    }

    private mutating func store(_ answer: Answer) {
        guard !answer.result.toolUseID.isEmpty else { return }
        answers[answer.result.toolUseID] = answer
    }

    private static func localCommandOutput(_ text: ClaudeUserText) -> String? {
        if case .localCommandOutput(let output) = text { return output }
        return nil
    }

    private static func bashOutput(_ text: ClaudeUserText) -> String? {
        if case .bashOutput(let output) = text { return output }
        return nil
    }

    /// Records that open a turn (prompts, commands, notifications) or close
    /// one (`turn_duration`, interrupt markers). A call without a result
    /// before one of them never gets one.
    private static func isTurnBoundary(_ record: ClaudeRecord) -> Bool {
        switch record.kind {
        case .system("turn_duration"):
            return true
        case .user:
            guard record.toolResults.isEmpty, !record.isMeta, !record.isCompactSummary,
                record.sourceToolUseID == nil
            else { return false }
            if isInterruptMarker(record) { return true }
            switch ClaudeUserText.classify(record.texts.joined(separator: "\n")) {
            case .hidden, .skillLoaded: return false
            default: return true
            }
        default:
            return false
        }
    }

    /// SDK `MI`: every block is text that starts with a marker.
    private static func isInterruptMarker(_ record: ClaudeRecord) -> Bool {
        !record.blocks.isEmpty
            && record.blocks.allSatisfy {
                guard case .text(let text) = $0 else { return false }
                return ClaudeUserText.isMarker(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    private static func notification(in record: ClaudeRecord) -> ClaudeTaskNotification? {
        let text: String
        switch record.kind {
        case .user where record.toolResults.isEmpty && !record.isMeta:
            text = record.texts.joined(separator: "\n")
        case .attachment("queued_command"):
            text = record.attachment?.queuedCommand?.text ?? ""
        default:
            return nil
        }
        guard case .taskNotification(let notification) = ClaudeUserText.classify(text) else { return nil }
        return notification
    }

    private static func key(of notification: ClaudeTaskNotification) -> String {
        [notification.taskID, notification.toolUseID, notification.status, notification.summary]
            .map { $0 ?? "" }.joined(separator: "\u{1F}")
    }

    private static func notice(for notification: ClaudeTaskNotification) -> ChatNotice {
        ChatNotice(
            kind: .taskNotification, title: notification.title,
            detail: notification.result.map { ChatToolPreview(capping: $0).text }?.nonEmpty)
    }
}

extension String {
    /// Nil for an empty string.
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
