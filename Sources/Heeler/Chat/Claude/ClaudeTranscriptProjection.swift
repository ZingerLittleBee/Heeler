import Foundation
import os

/// Turns the current branch into Chat entries
/// (docs/research/claude-code-transcript-format.md, "One API message across
/// records", "Tool pairing and outcomes" and "Special flows"), plus the
/// requests a Blocked card matches, the prompts pending-echo matching looks
/// for, and the Background Work Chat lists above its Composer.
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

    /// `transcriptPath` is the file the lines came from, which a Workflow's
    /// journal sits beside; nil lists no journal.
    static func transcript(
        index: ClaudeTranscriptIndex, chain: ClaudeChain, role: ClaudeTranscriptReducer.Role,
        context: ChatProjectionContext, transcriptPath: String? = nil
    ) -> ChatTranscript {
        let sources = imageSources(index.recordsByPosition, indexed: index.records)
        var builder = Builder(
            chain: chain, index: index, role: role, activity: context.activity, windowStart: context.windowStart,
            transcriptPath: transcriptPath, imageSources: sources)
        builder.build()
        let waiting = role == .main ? builder.addWaitingPrompts(waitingEnqueues(index)) : [:]
        var transcript = ChatTranscript(
            entries: builder.entries, title: index.title,
            needsOlderHistory: context.windowStart > 0,
            pendingRequests: builder.pendingRequests,
            recordedPrompts: role == .main
                ? recordedPrompts(
                    index, entryByRecord: builder.entryByRecord, waiting: waiting, imageSources: sources) : [],
            links: index.links, diagnostics: index.diagnostics,
            backgroundWork: role == .main ? builder.backgroundWork : [],
            latestPromptOffset: builder.latestPromptOffset,
            backgroundWorkEnds: role == .main ? builder.backgroundWorkEnds : [:],
            backgroundWorkStop: role == .main ? builder.end(stoppingAfter: context.windowStart) : nil,
            backgroundWorkTurnCaps: role == .main ? builder.backgroundWorkTurnCaps : [],
            turns: role == .main ? builder.turns : [],
            precedingTurnEnd: role == .main ? builder.precedingTurnEnd : nil,
            unrecordedEntryIDs: Set(waiting.values))
        if role == .main {
            transcript.model = index.model
            transcript.effort = index.effort
            transcript.permissionMode = index.permissionMode
            transcript.teammateEvents = builder.teammateEvents
        }
        return transcript
    }

    /// The output `record` holds for the call `use`, as its row's preview
    /// is built. Nil when the record holds no result for it.
    static func output(of use: ClaudeToolUse, in record: ClaudeRecord) -> ChatToolOutput? {
        guard let answer = Builder.answers(in: record).first(where: { $0.result.toolUseID == use.id }) else {
            return nil
        }
        let preview = ClaudeToolSummary.preview(
            for: use, result: answer.result, details: record.toolResult, outcome: answer.outcome)
        let fileChanges = ClaudeToolSummary.fileChanges(
            for: use, details: record.toolResult, outcome: answer.outcome)
        if let path = record.toolResult?.result?.persistedOutputPath {
            return .file(path, fallback: preview, fileChanges: fileChanges)
        }
        return .preview(preview, fileChanges: fileChanges)
    }

    // MARK: - Recorded prompts

    /// Every prompt a person typed, in file order, from all records rather
    /// than only the current branch: an echo is matched by where it lands in
    /// the file. Task notifications and other machine input never count.
    static func recordedPrompts(
        _ index: ClaudeTranscriptIndex, entryByRecord: [String: ChatEntryID],
        waiting: [UInt64: ChatEntryID] = [:], imageSources: [String: [String]]
    ) -> [ChatRecordedPrompt] {
        var prompts: [(prompt: ChatRecordedPrompt, rawKey: String, hasImageSources: Bool)] = []
        var fires: [(offset: UInt64, key: String)] = []
        let byPosition = index.recordsByPosition
        for (position, record) in byPosition.enumerated() where !record.isSidechain && record.teamName == nil {
            if let command = unknownCommand(record) {
                let next = byPosition.indices.contains(position + 1) ? byPosition[position + 1] : nil
                let arguments = next.flatMap { unknownSkillArguments($0, below: record) }
                let text = [command, arguments].compactMap { $0?.nonEmpty }.joined(separator: " ")
                prompts.append(
                    (
                        ChatRecordedPrompt(offset: record.byteOffset, text: text, entryID: entryByRecord[record.uuid]),
                        ClaudeTranscriptReducer.echoKey(text),
                        false
                    ))
                continue
            }
            // A scheduled fire settles its enqueue, but nobody sent it.
            if record.kind == .system("scheduled_task_fire") {
                if let prompt = record.system?.scheduledPrompt.flatMap(promptText) {
                    fires.append((record.byteOffset, ClaudeTranscriptReducer.echoKey(prompt)))
                }
                continue
            }
            guard let raw = typedText(of: record, indexed: index.records) else { continue }
            let sources = resolvedImagePaths(for: record, imageSources: imageSources)
            let text = sources.isEmpty ? raw : ChatRecordedPrompt.replacingImagePlaceholders(in: raw, with: sources)
            let unresolvedPlaceholders =
                record.kind == .attachment("queued_command")
                && sources.isEmpty
                && ChatRecordedPrompt.containsImagePlaceholder(raw)
            prompts.append(
                (
                    ChatRecordedPrompt(
                        offset: record.byteOffset, text: text, entryID: entryByRecord[record.uuid],
                        pastedImagePaths: ChatRecordedPrompt.isImagePlaceholder(raw) ? sources : nil,
                        hasUnresolvedImagePlaceholders: unresolvedPlaceholders),
                    ClaudeTranscriptReducer.echoKey(raw),
                    !sources.isEmpty
                ))
        }
        // A queued prompt is recorded first as an enqueue and later as the
        // record that delivers it; the enqueue points at that record's entry,
        // or at its waiting bubble until then. Both keep `[Image #N]` for a
        // pasted image, and only the delivery has a source below it.
        var enqueued: [ChatRecordedPrompt] = []
        for operation in index.queueOperations.values where operation.operation == "enqueue" {
            guard let content = operation.content, let text = promptText(content) else { continue }
            let key = ClaudeTranscriptReducer.echoKey(text)
            let deliveryMatch = prompts.first { $0.prompt.offset > operation.offset && $0.rawKey == key }
            let delivery = deliveryMatch?.prompt
            // The task's own enqueue, which its fire delivers before any Send could.
            if let fire = fires.first(where: { $0.offset > operation.offset && $0.key == key }),
                fire.offset < delivery?.offset ?? .max
            {
                continue
            }
            let hasSources = deliveryMatch?.hasImageSources ?? false
            enqueued.append(
                ChatRecordedPrompt(
                    offset: operation.offset, text: text, entryID: delivery?.entryID ?? waiting[operation.offset],
                    pastedImagePaths: ChatRecordedPrompt.isImagePlaceholder(text)
                        ? delivery?.pastedImagePaths ?? [] : nil,
                    hasUnresolvedImagePlaceholders: !hasSources && ChatRecordedPrompt.containsImagePlaceholder(text)))
        }
        return (prompts.map(\.prompt) + enqueued).sorted { $0.offset < $1.offset }
    }

    static func resolvedImagePaths(for record: ClaudeRecord, imageSources: [String: [String]]) -> [String] {
        if let sources = imageSources[record.uuid], !sources.isEmpty {
            return sources
        }
        return record.attachment?.queuedCommand?.imagePaths ?? []
    }

    /// The files a prompt's pasted images came from, by the prompt's uuid, in
    /// file order. A paste that is only an image path is recorded as
    /// `[Image #N]` plus an image block; Claude Code then writes a meta
    /// record of `[Image: source: <path>]` (or with resize coordinates, or
    /// `[Image source: <path>]` without dimensions) blocks, one per image,
    /// below it, after however many attachments the prompt carried.
    private static func imageSources(
        _ byPosition: [ClaudeRecord], indexed: [String: ClaudeRecord]
    ) -> [String: [String]] {
        var sources: [String: [String]] = [:]
        for record in byPosition where record.kind == .user && record.isMeta {
            let paths = record.texts.compactMap(imageSourcePath(in:))
            guard !paths.isEmpty else { continue }
            var visited: Set<String> = [record.uuid]
            var parent = record.parentUUID.flatMap { indexed[$0] }
            while let ancestor = parent, skipsBeforeImagePrompt(ancestor, indexed: indexed),
                visited.insert(ancestor.uuid).inserted
            {
                parent = ancestor.parentUUID.flatMap { indexed[$0] }
            }
            guard let prompt = parent, !visited.contains(prompt.uuid),
                carriesPastedImages(prompt, indexed: indexed)
            else { continue }
            sources[prompt.uuid, default: []].append(contentsOf: paths)
        }
        return sources
    }

    private static let imageSourcePrefixes = ["[Image: source: ", "[Image source: "]

    static func imageSourcePath(in text: String) -> String? {
        guard text.hasSuffix("]"),
            let prefix = imageSourcePrefixes.first(where: { text.hasPrefix($0) })
        else { return nil }
        var body = Substring(text.dropFirst(prefix.count).dropLast())
        if let match = body.firstMatch(
            of: #/, original [0-9]+x[0-9]+, displayed at [0-9]+x[0-9]+\. Multiply coordinates by [0-9.]+ to map to original image\.$/#
        ) {
            body = body[..<match.range.lowerBound]
        }
        return body.isEmpty ? nil : String(body)
    }

    private static func skipsBeforeImagePrompt(_ record: ClaudeRecord, indexed: [String: ClaudeRecord]) -> Bool {
        if record.isMeta { return true }
        if record.kind == .attachment("queued_command"),
            let queued = record.attachment?.queuedCommand, !queued.isMeta,
            queued.sourceUUID.flatMap({ indexed[$0] }) == nil
        {
            return false
        }
        return isAttachment(record.kind)
    }

    private static func carriesPastedImages(_ record: ClaudeRecord, indexed: [String: ClaudeRecord]) -> Bool {
        switch record.kind {
        case .user:
            return !record.isMeta && record.imageCount > 0
        case .attachment("queued_command"):
            guard let queued = record.attachment?.queuedCommand, !queued.isMeta,
                queued.sourceUUID.flatMap({ indexed[$0] }) == nil
            else { return false }
            return queued.imageCount > 0
        default:
            return false
        }
    }

    /// Claude Code 2.1.301 answers a `/command` it doesn't know, such as a
    /// skill added after it started, with only these `informational`
    /// records: the command, then the arguments below it.
    static let unknownCommandPrefix = "Unknown command: "
    static let unknownSkillArgumentsPrefix = "Args from unknown skill: "

    /// The `/command` an `informational` record says Claude Code didn't know.
    static func unknownCommand(_ record: ClaudeRecord) -> String? {
        guard record.kind == .system("informational"), let content = record.system?.content,
            content.hasPrefix(unknownCommandPrefix)
        else { return nil }
        return String(content.dropFirst(unknownCommandPrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The arguments `record` says were sent with the unknown command
    /// `parent` names.
    static func unknownSkillArguments(_ record: ClaudeRecord, below parent: ClaudeRecord) -> String? {
        guard record.kind == .system("informational"), record.parentUUID == parent.uuid,
            let content = record.system?.content, content.hasPrefix(unknownSkillArgumentsPrefix)
        else { return nil }
        return String(content.dropFirst(unknownSkillArgumentsPrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func isAttachment(_ kind: ClaudeRecord.Kind) -> Bool {
        if case .attachment = kind { return true }
        return false
    }

    /// Prompts Claude Code queued while a turn runs and has not delivered:
    /// an enqueue with no later prompt of the same text, and no later queue
    /// operation that takes that text back out. Claude Code writes the
    /// delivery only when the turn can take it, which can be minutes later.
    static func waitingEnqueues(_ index: ClaudeTranscriptIndex) -> [(offset: UInt64, text: String)] {
        guard index.queueOperations.values.contains(where: { $0.operation == "enqueue" }) else {
            return []
        }
        var latestTypedOffset: [String: UInt64] = [:]
        for record in index.recordsByPosition {
            guard !record.isSidechain, record.teamName == nil,
                let text = typedText(of: record, indexed: index.records)
            else { continue }
            let key = ClaudeTranscriptReducer.echoKey(text)
            latestTypedOffset[key] = max(latestTypedOffset[key] ?? 0, record.byteOffset)
        }
        let operations = index.queueOperations.values.sorted { $0.offset < $1.offset }
        var latestTakenBackOffset: [String: UInt64] = [:]
        for operation in operations where operation.operation != "enqueue" {
            guard let content = operation.content, let text = promptText(content) else { continue }
            let key = ClaudeTranscriptReducer.echoKey(text)
            latestTakenBackOffset[key] = max(latestTakenBackOffset[key] ?? 0, operation.offset)
        }
        return operations.compactMap { operation in
            guard operation.operation == "enqueue", let content = operation.content, let text = promptText(content)
            else { return nil }
            let enqueued = ClaudeTranscriptReducer.echoKey(text)
            let isDelivered = (latestTypedOffset[enqueued] ?? 0) > operation.offset
            let isTakenBack = (latestTakenBackOffset[enqueued] ?? 0) > operation.offset
            return isDelivered || isTakenBack ? nil : (operation.offset, text)
        }
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
        case .system("scheduled_task_fire"):
            // Delivers the enqueue Claude Code wrote for the task's prompt.
            return record.system?.scheduledPrompt.flatMap(promptText)
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

    private enum CachedDate: Sendable {
        case valid(Date)
        case invalid
    }

    private static let isoFractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlainStyle = Date.ISO8601FormatStyle()
    private static let dateCache = OSAllocatedUnfairLock<[String: CachedDate]>(initialState: [:])

    /// A record's `timestamp`: ISO 8601 with milliseconds, on the Host's
    /// clock. Cached by timestamp string so repeated projections stay O(1)
    /// while matching Foundation's `Date.ISO8601FormatStyle` bit-for-bit.
    static func date(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        if let cached = dateCache.withLock({ $0[timestamp] }) {
            switch cached {
            case .valid(let date): return date
            case .invalid: return nil
            }
        }
        let parsed =
            (try? Date(timestamp, strategy: isoFractionalStyle))
            ?? (try? Date(timestamp, strategy: isoPlainStyle))
        let entry: CachedDate = parsed.map(CachedDate.valid) ?? .invalid
        dateCache.withLock { cache in
            if cache.count >= 4_096 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[timestamp] = entry
        }
        return parsed
    }

    /// Claude Code's fixed opening of a compaction summary (2.1.301), which
    /// would fill the divider's few preview lines. It is matched against the
    /// Agent's own English transcript, so it must stay untranslated.
    static let compactionPreamble =
        "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation."

    /// A summary without its fixed opening, its `Summary:` line and the
    /// first section's heading, so the preview starts with what the
    /// conversation was about. The whole summary when it opens otherwise.
    static func compactionPreview(_ summary: String) -> String {
        guard summary.hasPrefix(compactionPreamble) else { return summary }
        var lines = Array(
            summary.dropFirst(compactionPreamble.count).split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init))
        func dropLeading(_ isDropped: (String) -> Bool) {
            lines = Array(lines.drop { isDropped($0.trimmingCharacters(in: .whitespaces)) })
        }
        dropLeading(\.isEmpty)
        dropLeading { $0 == "Summary:" }
        dropLeading(\.isEmpty)
        // The first heading of Claude Code's own English summary, matched,
        // so it stays untranslated.
        let heading = "1. Primary Request and Intent:"
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix(heading) {
            let rest = first.dropFirst(heading.count).trimmingCharacters(in: .whitespaces)
            lines = (rest.isEmpty ? [] : [rest]) + lines.dropFirst()
            dropLeading(\.isEmpty)
            lines = outdentingFirstSection(lines)
        }
        let remainder = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? summary : remainder
    }

    /// The first section's body moved out by its common indentation, up to
    /// the next unindented line. Without its heading, the body's list items
    /// are top-level; outdenting only the first line would make its siblings
    /// read as nested under it.
    private static func outdentingFirstSection(_ lines: [String]) -> [String] {
        func indentation(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        let end = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty && indentation($0) == 0 }
            ?? lines.endIndex
        let body = lines[..<end]
        let shift = body.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(indentation).min() ?? 0
        guard shift > 0 else { return lines }
        return body.map { String($0.dropFirst(min(shift, indentation($0)))) } + lines[end...]
    }

    static func modelChangeTitle(from: String?, to: String?) -> String {
        switch (from, to) {
        case (let from?, let to?): String(localized: "Switched from \(from) to \(to)")
        case (nil, let to?): String(localized: "Switched to \(to)")
        default: String(localized: "Switched model")
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
        /// An interrupt marker after the result names the call's reply:
        /// Esc stopped the call while it ran. Claude Code 2.1.301 records
        /// that result with the decline text a refused approval gets, whose
        /// marker names no reply.
        var stoppedWhileRunning = false

        var outcome: ClaudeToolOutcome {
            let outcome = ClaudeToolOutcome(result: result, details: record.toolResult, trailingTexts: trailingTexts)
            if stoppedWhileRunning, case .declined(feedback: nil) = outcome { return .interrupted }
            return outcome
        }
    }

    struct TurnDraft {
        var firstEntryID: ChatEntryID?
        var startedAt: Date?
        var endedAt: Date?
        var ending: ChatTurn.Ending?
        /// The newest reply was an API error.
        var failed = false
    }

    /// A task notification and the record that delivered it.
    struct Delivery {
        var notification: ClaudeTaskNotification
        var offset: UInt64
        var timestamp: String?
        /// The earliest record that carried this notification: Claude Code
        /// queues it when the work ends and can deliver it minutes later.
        var firstTimestamp: String?
    }

    struct BackgroundLaunch {
        var callID: String
        var kind: ChatBackgroundWorkItem.Kind
        var launchOffset: UInt64
        var taskID: String?
        /// When the program stops a Monitor that has not ended by itself.
        var monitorDeadline: Date?
    }

    /// What a Monitor's events say about it: when the newest came, and the
    /// first that closed it.
    struct MonitorEvents {
        var lastEventAt: Date?
        var end: ChatBackgroundWorkEnd?
    }

    let chain: ClaudeChain
    /// Every indexed record, selected or not.
    let indexed: [String: ClaudeRecord]
    let role: ClaudeTranscriptReducer.Role
    let activity: ChatAgentActivity
    let transcriptPath: String?
    /// The files each prompt's pasted images came from, by the prompt's uuid.
    let imageSources: [String: [String]]

    private(set) var entries: [ChatEntry] = []
    private(set) var pendingRequests: [ChatPendingRequest] = []
    /// The first entry each record placed.
    private(set) var entryByRecord: [String: ChatEntryID] = [:]
    private(set) var backgroundWork: [ChatBackgroundWorkItem] = []
    /// The newest record that placed a message the user sent.
    private(set) var latestPromptOffset: UInt64?
    private(set) var backgroundWorkTurnCaps: [ChatTurnPendingAllowance] = []
    /// What the loaded records say about teammates, in file order.
    private(set) var teammateEvents: [ChatTeammateEvent] = []

    private var selected: [String: ClaudeRecord] = [:]
    private var children: [String: [ClaudeRecord]] = [:]
    private var answers: [String: Answer] = [:]
    /// The assistant `message.id` each tool call was sent in.
    private var callMessages: [String: String] = [:]
    /// Offsets of records that start a new turn or end one, ascending.
    private var turnBoundaries: [UInt64] = []
    /// The turns opened so far, in chain order. A turn whose opener placed
    /// nothing takes the first entry placed after it.
    private var turnDrafts: [TurnDraft] = []
    private var turnOpen = false
    /// How the turn opened above the loaded lines ended, when they say.
    private(set) var precedingTurnEnd: ChatTurnEnd?
    /// The latest notification for each background call, a Monitor's events
    /// aside.
    private var notifications: [String: Delivery] = [:]
    /// Terminal ends resolved per background call, including `TaskStop`,
    /// `agents_killed`, and `turn_duration` pending-count caps.
    private var resolvedBackgroundEnds: [String: ChatBackgroundWorkEnd] = [:]
    /// Each Monitor's events, by its task id.
    private var monitorEvents: [String: MonitorEvents] = [:]
    /// Successful `TaskStop` calls, by the task each stopped, and which of
    /// those tasks their results call a background command.
    private var taskStops: [String: ChatBackgroundWorkEnd] = [:]
    private var stoppedCommandTasks: Set<String> = []
    /// The background commands and Monitors among the loaded records, by
    /// the call that started each, with its task id.
    private var commandTasks: [String: String] = [:]
    /// The output file each background command's launch or notification
    /// named, by task id, and the directory the first of them is in, which
    /// every task of the session writes to.
    private var taskOutputPaths: [String: String] = [:]
    private var taskOutputDirectory: String?
    /// Notifications shown from user records, so a queued copy is not shown
    /// twice.
    private var notificationKeys: Set<String> = []
    /// `agents_killed` records, in file order.
    private var agentsKilled: [ClaudeRecord] = []
    /// `plan_mode_exit` paths by the record they follow (the approval).
    private var planExitPaths: [String: String] = [:]
    /// The latest content written to each plan file, by path.
    private var planWrites: [String: String] = [:]
    private var entryIDs: Set<ChatEntryID> = []
    /// Records whose content an earlier entry already shows.
    private var consumed: Set<String> = []
    private var compactionEntry: Int?

    init(
        chain: ClaudeChain, index: ClaudeTranscriptIndex, role: ClaudeTranscriptReducer.Role,
        activity: ChatAgentActivity, windowStart: UInt64 = 0, transcriptPath: String?,
        imageSources: [String: [String]]
    ) {
        self.chain = chain
        indexed = index.records
        self.imageSources = imageSources
        self.role = role
        self.activity = activity
        self.transcriptPath = transcriptPath
        for record in chain.records {
            selected[record.uuid] = record
            if let parent = chain.parents[record.uuid] {
                children[parent, default: []].append(record)
            }
            collectAnswers(in: record)
            collectCallMessages(in: record)
            if Self.isTurnBoundary(record) {
                turnBoundaries.append(record.byteOffset)
            }
            if case .attachment("plan_mode_exit") = record.kind,
                let path = record.attachment?.planFilePath, let parent = chain.parents[record.uuid]
            {
                planExitPaths[parent] = path
            }
            if let notification = Self.notification(in: record), record.kind == .user {
                notificationKeys.insert(Self.key(of: notification))
            }
        }
        markStoppedCalls()
        resolveBackgroundWork(index: index, windowStart: windowStart)
    }

    private mutating func resolveBackgroundWork(index: ClaudeTranscriptIndex, windowStart: UInt64) {
        let mainRecords: [ClaudeRecord] =
            role == .main
            ? index.recordsByPosition.filter { !$0.isSidechain && $0.teamName == nil }
            : chain.records
        var allAnswers = answers
        if role == .main {
            for record in mainRecords {
                for answer in Self.answers(in: record)
                where !answer.result.toolUseID.isEmpty && allAnswers[answer.result.toolUseID] == nil {
                    allAnswers[answer.result.toolUseID] = answer
                }
            }
        }

        var callIDByTaskID: [String: String] = [:]
        var monitorDeadlines: [String: Date] = [:]
        var loadedCalls: Set<String> = []
        for record in mainRecords {
            if record.kind == .system("agents_killed") {
                agentsKilled.append(record)
            }
            for use in record.toolUses {
                loadedCalls.insert(use.id)
                if !use.id.isEmpty,
                    let answer = allAnswers[use.id],
                    let result = answer.record.toolResult?.result,
                    let launch = Self.backgroundLaunch(
                        for: use, at: record.byteOffset, result: result, answeredAt: answer.record.timestamp),
                    let taskID = launch.taskID
                {
                    callIDByTaskID[taskID] = use.id
                    if launch.kind == .command {
                        commandTasks[use.id] = taskID
                        noteTaskOutput(
                            Self.taskOutputPath(in: answer.result.content.text, taskID: taskID), taskID: taskID)
                        monitorDeadlines[taskID] = launch.monitorDeadline
                    }
                }
                if (use.name == "TaskStop" || use.name == "KillShell"),
                    !use.id.isEmpty,
                    let answer = allAnswers[use.id],
                    case .succeeded = answer.outcome,
                    let stoppedID = (answer.record.toolResult?.result?.taskID ?? use.input.taskID)?.nonEmpty
                {
                    noteTaskStop(stoppedID, answeredBy: answer.record)
                }
            }
        }
        // A stop's result names the command it stopped by itself, so it
        // counts when the call that sent it lies above the loaded lines.
        for (callID, answer) in allAnswers where !loadedCalls.contains(callID) {
            guard case .succeeded = answer.outcome, let result = answer.record.toolResult?.result,
                result.taskType == Self.commandTaskType, let stoppedID = result.taskID?.nonEmpty
            else { continue }
            noteTaskStop(stoppedID, answeredBy: answer.record)
        }

        func offerNotification(_ notification: ClaudeTaskNotification, offset: UInt64, timestamp: String?) {
            if let taskID = notification.taskID?.nonEmpty {
                noteTaskOutput(notification.outputFile, taskID: taskID)
                if notification.isMonitorEvent {
                    noteMonitorEvent(
                        notification, taskID: taskID, offset: offset, timestamp: timestamp,
                        deadline: monitorDeadlines[taskID])
                    return
                }
            }
            guard
                let callID =
                    notification.toolUseID?.nonEmpty
                    ?? notification.taskID?.nonEmpty.flatMap({ callIDByTaskID[$0] })
            else { return }
            let kept = notifications[callID]
            let carriesKept = kept.map { Self.key(of: $0.notification) == Self.key(of: notification) } ?? false
            if let kept, kept.offset > offset {
                if carriesKept {
                    notifications[callID]?.firstTimestamp = Self.earlier(kept.firstTimestamp, timestamp)
                }
                return
            }
            notifications[callID] = Delivery(
                notification: notification, offset: offset, timestamp: timestamp,
                firstTimestamp: carriesKept ? Self.earlier(kept?.firstTimestamp, timestamp) : timestamp)
        }

        for record in mainRecords {
            if let notification = Self.notification(in: record) {
                offerNotification(notification, offset: record.byteOffset, timestamp: record.timestamp)
            }
        }
        // Selected branch records break equal-offset ties.
        for record in chain.records {
            if let notification = Self.notification(in: record) {
                offerNotification(notification, offset: record.byteOffset, timestamp: record.timestamp)
            }
        }
        // Claude Code queues a notification as soon as the work ends, and
        // delivers it once the session can take it, which can be minutes
        // into a busy turn.
        for operation in index.queueOperations.values.sorted(by: { $0.offset < $1.offset })
        where operation.operation == "enqueue" {
            guard let content = operation.content,
                case .taskNotification(let notification) = ClaudeUserText.classify(content)
            else { continue }
            offerNotification(notification, offset: operation.offset, timestamp: operation.timestamp)
        }

        guard role == .main else { return }

        teammateEvents = Self.teammateEvents(in: mainRecords, answers: allAnswers)

        var chainLaunches: [BackgroundLaunch] = []
        for record in chain.records where !record.isSidechain && record.teamName == nil {
            for use in record.toolUses where !use.id.isEmpty {
                guard let result = answers[use.id]?.record.toolResult?.result,
                    let launch = Self.backgroundLaunch(for: use, at: record.byteOffset, result: result)
                else { continue }
                chainLaunches.append(launch)
            }
        }

        for launch in chainLaunches {
            if let delivery = notifications[launch.callID],
                delivery.offset > launch.launchOffset,
                Self.state(of: delivery.notification) != .running
            {
                resolvedBackgroundEnds[launch.callID] = Self.end(of: delivery, atFirstCarrier: launch.kind == .command)
                continue
            }
            let explicitTaskStop = launch.taskID
                .flatMap { taskStops[$0] }
                .flatMap { $0.offset > launch.launchOffset ? $0 : nil }
            // `agents_killed` reports background agents terminated, and
            // says nothing of a command; a Monitor's own closing event does.
            let otherStop =
                launch.kind == .command
                ? launch.taskID.flatMap { monitorEvents[$0]?.end }.flatMap { $0.offset > launch.launchOffset ? $0 : nil }
                : end(stoppingAfter: launch.launchOffset)
            resolvedBackgroundEnds[launch.callID] =
                [explicitTaskStop, otherStop].compactMap(\.self).min { $0.offset < $1.offset }
        }

        let hasAnyPendingWorkflowCount = mainRecords.contains {
            $0.kind == .system("turn_duration") && $0.system?.pendingWorkflowCount != nil
        }
        let hasAnyPendingBackgroundAgentCount = mainRecords.contains {
            $0.kind == .system("turn_duration") && $0.system?.pendingBackgroundAgentCount != nil
        }

        for record in chain.records
        where record.kind == .system("turn_duration") && !record.isSidechain && record.teamName == nil {
            let turnEnd = ChatBackgroundWorkEnd(
                state: .stopped, offset: record.byteOffset,
                endedAt: ClaudeTranscriptProjection.date(record.timestamp))
            if record.system?.hasTurnMessageCount == true
                || record.system?.pendingWorkflowCount != nil
                || hasAnyPendingWorkflowCount
            {
                applyPendingCap(
                    kind: .workflow, allowed: max(0, record.system?.pendingWorkflowCount ?? 0),
                    end: turnEnd, launches: chainLaunches, windowStart: windowStart)
            }
            if record.system?.hasTurnMessageCount == true
                || record.system?.pendingBackgroundAgentCount != nil
                || hasAnyPendingBackgroundAgentCount
            {
                applyPendingCap(
                    kind: .subagent, allowed: max(0, record.system?.pendingBackgroundAgentCount ?? 0),
                    end: turnEnd, launches: chainLaunches, windowStart: windowStart)
            }
        }
    }

    private mutating func applyPendingCap(
        kind: ChatBackgroundWorkItem.Kind,
        allowed: Int,
        end: ChatBackgroundWorkEnd,
        launches: [BackgroundLaunch],
        windowStart: UInt64
    ) {
        let activeBefore = launches.filter { launch in
            guard launch.kind == kind, launch.launchOffset < end.offset else { return false }
            guard let existing = resolvedBackgroundEnds[launch.callID] else { return true }
            return existing.offset > end.offset
        }
        let excess = activeBefore.count - allowed
        var retired = 0
        if excess > 0 {
            for launch in activeBefore where resolvedBackgroundEnds[launch.callID] == nil {
                resolvedBackgroundEnds[launch.callID] = end
                retired += 1
                if retired == excess { break }
            }
        }
        if windowStart > 0, end.offset >= windowStart {
            let remainingInWindow = activeBefore.count - retired
            backgroundWorkTurnCaps.append(
                ChatTurnPendingAllowance(
                    kind: kind, carriedSlots: max(0, allowed - remainingInWindow), end: end))
        }
    }

    /// What `records` say about teammates (Claude Code 2.1.331): a spawn, a
    /// message the lead sent, what a teammate wrote back (an idle
    /// notification ends its turn), and `agents_killed`, which stops them
    /// all. Teammates write no `turn_duration` and no task notification:
    /// the lead's `turn_duration` waits until none runs.
    private static func teammateEvents(in records: [ClaudeRecord], answers: [String: Answer]) -> [ChatTeammateEvent] {
        var events: [ChatTeammateEvent] = []
        for record in records {
            let at = ClaudeTranscriptProjection.date(record.timestamp)
            if record.kind == .system("agents_killed") {
                events.append(ChatTeammateEvent(name: nil, kind: .stopped, offset: record.byteOffset, at: at))
            }
            for use in record.toolUses where !use.id.isEmpty {
                guard let answer = answers[use.id], case .succeeded = answer.outcome else { continue }
                if let result = answer.record.toolResult?.result, result.status == "teammate_spawned",
                    let name = teammateName(of: use, result: result)
                {
                    events.append(ChatTeammateEvent(name: name, kind: .spawned, offset: record.byteOffset, at: at))
                } else if use.name == "SendMessage", let recipient = use.input.messageRecipient?.nonEmpty {
                    // A name from an agent listing can carry its ` [ref]`.
                    let name = recipient.components(separatedBy: " [").first ?? recipient
                    events.append(
                        ChatTeammateEvent(
                            name: name == "*" ? nil : name, kind: .messaged, offset: answer.record.byteOffset,
                            at: ClaudeTranscriptProjection.date(answer.record.timestamp)))
                }
            }
            guard record.kind == .user else { continue }
            for message in ClaudeTeammateMessage.messages(in: record.texts.joined(separator: "\n")) {
                let kind: ChatTeammateEvent.Kind =
                    switch message.kind {
                    case .message: .wrote
                    case .idle(reason: "failed"?): .idled(.failed)
                    case .idle(reason: "interrupted"?): .idled(.stopped)
                    case .idle: .idled(.completed)
                    case .ended: .stopped
                    }
                events.append(
                    ChatTeammateEvent(
                        name: message.sender, kind: kind, offset: record.byteOffset,
                        at: ClaudeTranscriptProjection.date(message.timestamp) ?? at))
            }
        }
        return events.sorted { $0.offset < $1.offset }
    }

    /// The name a spawn's result says the teammate took, else the one the
    /// call asked for.
    private static func teammateName(of use: ClaudeToolUse, result: ClaudeToolUseResult) -> String? {
        (result.teammateName ?? use.input.teammateName).flatMap(\.nonEmpty)
    }

    /// `answeredAt` is when the call's result was recorded, which a Monitor's
    /// deadline counts from.
    private static func backgroundLaunch(
        for use: ClaudeToolUse, at offset: UInt64, result: ClaudeToolUseResult, answeredAt: String? = nil
    ) -> BackgroundLaunch? {
        guard !use.id.isEmpty else { return nil }
        if let taskID = commandTaskID(for: use, result: result) {
            var launch = BackgroundLaunch(callID: use.id, kind: .command, launchOffset: offset, taskID: taskID)
            if use.name == "Monitor", !result.isPersistentMonitor,
                let timeout = result.monitorTimeoutMilliseconds,
                let started = ClaudeTranscriptProjection.date(answeredAt)
            {
                launch.monitorDeadline = started.addingTimeInterval(
                    TimeInterval(timeout) / 1_000 - monitorDeadlineSlack)
            }
            return launch
        }
        guard result.status == "async_launched" || result.status == "remote_launched" else { return nil }
        if isWorkflow(use, result: result) {
            return BackgroundLaunch(
                callID: use.id, kind: .workflow, launchOffset: offset, taskID: result.taskID?.nonEmpty)
        }
        if use.name == "Agent" || use.name == "Task" {
            return BackgroundLaunch(
                callID: use.id, kind: .subagent, launchOffset: offset,
                taskID: (result.agentID ?? result.taskID)?.nonEmpty)
        }
        return nil
    }

    /// The task a call left running as a background command: the
    /// `backgroundTaskId` of a Bash or PowerShell call that was asked to run
    /// there, timed out, or was moved there, or a Monitor's `taskId`
    /// (Claude Code 2.1.327).
    private static func commandTaskID(for use: ClaudeToolUse, result: ClaudeToolUseResult) -> String? {
        if let taskID = result.backgroundTaskID?.nonEmpty { return taskID }
        return use.name == "Monitor" ? result.taskID?.nonEmpty : nil
    }

    /// What a `TaskStop` result calls a background command or a Monitor
    /// (2.1.327).
    private static let commandTaskType = "local_bash"

    /// Keeps the newest stop of `taskID`, and whether its result says the
    /// task was a command.
    private mutating func noteTaskStop(_ taskID: String, answeredBy record: ClaudeRecord) {
        let stop = ChatBackgroundWorkEnd(
            state: .stopped, offset: record.byteOffset, endedAt: ClaudeTranscriptProjection.date(record.timestamp))
        if taskStops[taskID].map({ $0.offset <= stop.offset }) ?? true {
            taskStops[taskID] = stop
        }
        if record.toolResult?.result?.taskType == Self.commandTaskType {
            stoppedCommandTasks.insert(taskID)
        }
    }

    /// The result record is written just after a Monitor starts, so its
    /// expiry can be stamped a moment before the deadline counted from it.
    private static let monitorDeadlineSlack: TimeInterval = 1

    /// A Monitor's event is a sign it runs, unless it is the program's own
    /// closing note or comes at the deadline, when the Monitor is over:
    /// expiry writes no end with a `<status>`.
    private mutating func noteMonitorEvent(
        _ notification: ClaudeTaskNotification, taskID: String, offset: UInt64, timestamp: String?, deadline: Date?
    ) {
        let date = ClaudeTranscriptProjection.date(timestamp)
        var events = monitorEvents[taskID] ?? MonitorEvents()
        events.lastEventAt = [events.lastEventAt, date].compactMap(\.self).max()
        let note = notification.event ?? ""
        let isClosingNote = note.hasPrefix(ClaudeTaskNotification.monitorClosingPrefix)
        let isPastDeadline = deadline.flatMap { deadline in date.map { $0 >= deadline } } ?? false
        if isClosingNote || isPastDeadline {
            // Each carrier restates the note, as with a notification: the
            // end stands at the newest one, at the first one's time.
            let state: ChatBackgroundWorkItem.State =
                note.hasPrefix(ClaudeTaskNotification.monitorStoppedPrefix) ? .stopped : .completed
            events.end = ChatBackgroundWorkEnd(
                state: events.end?.state ?? state, offset: max(events.end?.offset ?? 0, offset),
                endedAt: [events.end?.endedAt, date].compactMap(\.self).min())
        }
        monitorEvents[taskID] = events
    }

    /// Keeps the output file a launch or notification names for `taskID`,
    /// and the directory every task of the session writes to.
    private mutating func noteTaskOutput(_ path: String?, taskID: String) {
        guard let path, Self.isTaskID(taskID), path.hasSuffix("/tasks/\(taskID).output"),
            RemoteFilePath.isAcceptable(path)
        else { return }
        taskOutputPaths[taskID] = path
        if taskOutputDirectory == nil {
            taskOutputDirectory = String(path.dropLast("/\(taskID).output".count))
        }
    }

    /// Where `taskID` writes its output: the path the transcript names, or
    /// its name in the directory another task's path gave.
    private func taskOutputPath(_ taskID: String) -> String? {
        if let path = taskOutputPaths[taskID] { return path }
        guard let taskOutputDirectory, Self.isTaskID(taskID) else { return nil }
        return RemoteFilePath.join(taskOutputDirectory, "\(taskID).output")
    }

    /// A task id is a kind letter and eight base-36 characters (2.1.292);
    /// anything that could not be one names no file.
    private static func isTaskID(_ taskID: String) -> Bool {
        !taskID.isEmpty && taskID.utf8.count <= 64
            && taskID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The output file a background launch's result text names: `Output is
    /// being written to: <dir>/tasks/<task id>.output`.
    private static func taskOutputPath(in text: String, taskID: String) -> String? {
        guard let marker = text.range(of: "Output is being written to: "),
            let end = text.range(of: "/tasks/\(taskID).output", range: marker.upperBound..<text.endIndex)
        else { return nil }
        return String(text[marker.upperBound..<end.upperBound])
    }

    /// The earlier of two record timestamps, which Claude Code writes in
    /// one fixed-width UTC form.
    private static func earlier(_ first: String?, _ second: String?) -> String? {
        guard let first else { return second }
        guard let second else { return first }
        return min(first, second)
    }

    mutating func build() {
        for record in chain.records where !consumed.contains(record.uuid) {
            if role == .main, record.isSidechain || record.teamName != nil { continue }
            if role == .main { noteTurn(record) }
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
                if Self.isNarration(text, durationMilliseconds: record.thinkingDurationMilliseconds) {
                    add("text:\(record.uuid)\(suffix)", at: record, .assistant(ChatAssistantMessage(text: text)))
                } else {
                    add(
                        "think:\(record.uuid)\(suffix)", at: record,
                        .reasoning(
                            ChatReasoning(text: text, durationMilliseconds: record.thinkingDurationMilliseconds)))
                }
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

    /// Thinking that took less than this is narration. Claude Code 2.1.301
    /// records some of the text it says between calls as a signed thinking
    /// block of 2 ms, and 2.1.291 as unsigned ones of 1-23 ms, which the
    /// terminal draws as ordinary text; real thinking takes longer (647 ms
    /// at the shortest in the probes) and 2.1.301 records it with no text.
    static let narrationThinkingLimit = 200

    /// A thinking block the terminal draws as the model's text: it has text
    /// and took almost no time, or says nothing about how long it took.
    static func isNarration(_ text: String, durationMilliseconds: Int?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return durationMilliseconds.map { $0 < narrationThinkingLimit } ?? true
    }

    private mutating func addToolUse(_ use: ClaudeToolUse, in record: ClaudeRecord) {
        let callID = use.id.isEmpty ? nil : use.id
        let entryID = "tool:\(callID ?? record.uuid)"
        let answer = callID.flatMap { answers[$0] }
        let outcome = answer?.outcome
        let structured = answer?.record.toolResult?.result
        var status = outcome?.status ?? unansweredStatus(of: use, after: record.byteOffset)
        if status == .succeeded, let launch = structured?.status, launch == "async_launched" || launch == "remote_launched" {
            status = backgroundStatus(callID, launchedAt: record.byteOffset)
        } else if status == .succeeded, role == .main, let callID, commandTasks[callID] != nil {
            // A command left in the background runs on past its call's
            // result. Only a session's own transcript resolves how it ended.
            status = backgroundStatus(callID, launchedAt: record.byteOffset)
        } else if status == .succeeded, structured?.status == "teammate_spawned" {
            status = .started
        }

        let placed: Bool
        switch use.name {
        case "ExitPlanMode":
            let filePath =
                structured?.filePath ?? answer.flatMap { planExitPaths[$0.record.uuid] } ?? use.input.planFilePath
            // Claude Code 2.1.301 fills `input.plan` from the plan file as
            // it stood before a Write in the same message; until the result
            // says which plan it was, the latest Write is the plan.
            let written = use.input.planFilePath.flatMap { planWrites[$0] }
            placed = add(
                entryID, at: record,
                .plan(
                    ChatPlan(
                        text: structured?.plan ?? written ?? use.input.plan ?? "", filePath: filePath,
                        status: status, note: outcome?.note, callID: callID)))
        case "Write" where use.input.planContent != nil:
            if let path = use.input.filePath, let content = use.input.planContent,
                status != .failed, status != .declined
            {
                planWrites[path] = content
            }
            placed = add(
                entryID, at: record, .tool(toolRow(for: use, in: record, status: status, answer: answer)))
        case "EnterPlanMode" where status == .succeeded:
            placed = add(entryID, at: record, .notice(ChatNotice(kind: .planMode, title: String(localized: "Entered plan mode"))))
        default:
            placed = add(
                entryID, at: record, .tool(toolRow(for: use, in: record, status: status, answer: answer)))
        }

        if placed, let item = backgroundWorkItem(for: use, in: record, result: structured) {
            backgroundWork.append(item)
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

    private func toolRow(
        for use: ClaudeToolUse, in record: ClaudeRecord, status: ChatToolActivity.Status, answer: Answer?
    ) -> ChatToolActivity {
        let summary = ClaudeToolSummary(use, directory: record.cwd)
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
            row.fileChanges = ClaudeToolSummary.fileChanges(
                for: use, details: answer.record.toolResult, outcome: outcome)
            row.imagePath = ClaudeToolSummary.imagePath(for: use, details: answer.record.toolResult)
        }
        if Self.isWorkflow(use, result: structured), let name = structured?.workflowName, !name.isEmpty {
            row.title = name
            row.subtitle = structured?.workflowSummary
        }
        if structured?.status == "teammate_spawned",
            let name = (use.input.teammateName ?? structured?.teammateName).flatMap(\.nonEmpty)
        {
            row.subtitle = String(localized: "Teammate @\(name)")
        }
        // A background agent reports through its notification.
        if row.preview == nil, !use.id.isEmpty, let report = notifications[use.id]?.notification.result,
            !report.isEmpty
        {
            row.preview = ChatToolPreview(capping: report)
        }
        // A background command's notification names the code it failed with.
        if row.exitCode == nil, status == .failed, commandTasks[use.id] != nil,
            let ended = notifications[use.id]?.notification, ended.status == "failed"
        {
            row.exitCode = ended.exitCode
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
    /// behind by a turn that moved on. herdr reports Claude idle on some
    /// AskUserQuestion screens, so an open question waits like its card
    /// (`BlockedCardStore.readsIdleQuestion`).
    private func unansweredStatus(of use: ClaudeToolUse, after offset: UInt64) -> ChatToolActivity.Status {
        if turnEnded(after: offset) { return .noResult }
        switch activity {
        case .blocked: return .awaitingApproval
        case .idle: return use.name == "AskUserQuestion" ? .awaitingApproval : .noResult
        case .working, .unknown: return .running
        }
    }

    /// A background agent runs until its task notification arrives, or until
    /// `TaskStop`, `agents_killed`, or a `turn_duration` count retires it. A
    /// background command runs until its notification, a `TaskStop`, or a
    /// Monitor's closing event.
    private func backgroundStatus(_ callID: String?, launchedAt offset: UInt64) -> ChatToolActivity.Status {
        let resolvedEnd = callID.flatMap { resolvedBackgroundEnds[$0] }
        if let callID, let delivery = notifications[callID] {
            if delivery.notification.status == "blocked" {
                if let resolvedEnd, resolvedEnd.offset > delivery.offset {
                    return Self.toolStatus(for: resolvedEnd.state)
                }
                return .awaitingApproval
            }
            return Self.toolStatus(for: Self.state(of: delivery.notification))
        }
        if let resolvedEnd {
            return Self.toolStatus(for: resolvedEnd.state)
        }
        let isCommand = callID.map { commandTasks[$0] != nil } ?? false
        if !isCommand, agentsKilled.contains(where: { $0.byteOffset > offset }) { return .interrupted }
        return .running
    }

    private static func toolStatus(for state: ChatBackgroundWorkItem.State) -> ChatToolActivity.Status {
        switch state {
        case .running: .running
        case .completed: .succeeded
        case .failed: .failed
        case .stopped: .interrupted
        }
    }

    private static func isWorkflow(_ use: ClaudeToolUse, result: ClaudeToolUseResult?) -> Bool {
        use.name == "Workflow" || result?.taskType == "local_workflow"
    }

    /// A Subagent, teammate, Workflow, background command or Monitor the
    /// call started in the background, with how it ended once its
    /// notification arrived, or for a teammate, how its latest run went.
    private func backgroundWorkItem(
        for use: ClaudeToolUse, in record: ClaudeRecord, result: ClaudeToolUseResult?
    ) -> ChatBackgroundWorkItem? {
        guard role == .main, !use.id.isEmpty, let result else { return nil }
        var item: ChatBackgroundWorkItem
        if result.status == "teammate_spawned" {
            guard let name = Self.teammateName(of: use, result: result) else { return nil }
            item = ChatBackgroundWorkItem(
                id: use.id, kind: .teammate,
                title: use.input.description.flatMap(\.nonEmpty) ?? String(localized: "Teammate @\(name)"),
                subtitle: name, launchOffset: record.byteOffset,
                launchedAt: ClaudeTranscriptProjection.date(record.timestamp))
            item.taskID = result.agentID?.nonEmpty
            item.follow(teammateEvents)
            return item
        } else if let taskID = commandTasks[use.id] {
            // The command is the row's terminal line and what the model
            // said it does its headline; a Monitor on a WebSocket has only
            // the latter.
            let command = use.input.command.flatMap(\.nonEmpty)
            let description = use.input.description.flatMap(\.nonEmpty)
            item = ChatBackgroundWorkItem(
                id: use.id, kind: .command, title: command ?? description ?? String(localized: "Command"),
                subtitle: command == nil || description == command ? nil : description,
                launchOffset: record.byteOffset)
            item.taskID = taskID
            item.outputPath = taskOutputPath(taskID)
            item.lastActivityAt = monitorEvents[taskID]?.lastEventAt
        } else if result.status != "async_launched", result.status != "remote_launched" {
            return nil
        } else if Self.isWorkflow(use, result: result) {
            item = ChatBackgroundWorkItem(
                id: use.id, kind: .workflow, title: result.workflowName.flatMap(\.nonEmpty) ?? String(localized: "Workflow"),
                subtitle: result.workflowSummary.flatMap(\.nonEmpty), launchOffset: record.byteOffset)
            if let transcriptPath, let runID = result.runID {
                item.journalPath = ClaudeTranscriptLocation.workflowJournalPath(
                    transcriptPath: transcriptPath, runID: runID)
            }
        } else if use.name == "Agent" || use.name == "Task" {
            item = ChatBackgroundWorkItem(
                id: use.id, kind: .subagent, title: use.input.description.flatMap(\.nonEmpty) ?? String(localized: "Subagent"),
                subtitle: use.input.subagentType.flatMap(\.nonEmpty), launchOffset: record.byteOffset)
        } else {
            return nil
        }
        item.launchedAt = ClaudeTranscriptProjection.date(record.timestamp)
        if let end = resolvedBackgroundEnds[use.id] {
            item.apply(end)
        }
        return item
    }

    /// How each background call ended, by its id, as its latest terminal
    /// notification says. A `TaskStop` and a Monitor's closing event name
    /// only the task, so those ends are filed by the task's id, for a
    /// command launched above the loaded lines.
    var backgroundWorkEnds: [String: ChatBackgroundWorkEnd] {
        var ends: [String: ChatBackgroundWorkEnd] = notifications.compactMapValues { delivery in
            let end = Self.end(of: delivery, atFirstCarrier: commandTasks[delivery.notification.toolUseID ?? ""] != nil)
            return end.state == .running ? nil : end
        }
        for (taskID, events) in monitorEvents {
            if let end = events.end { ends[taskID] = end }
        }
        for taskID in stoppedCommandTasks {
            guard let stop = taskStops[taskID], ends[taskID].map({ stop.offset < $0.offset }) ?? true else { continue }
            ends[taskID] = stop
        }
        return ends
    }

    /// `atFirstCarrier` dates the end by the first record that carried the
    /// notification, which is when a command stopped: nothing else in its
    /// notification says how long it ran.
    private static func end(of delivery: Delivery, atFirstCarrier: Bool = false) -> ChatBackgroundWorkEnd {
        let timestamp = atFirstCarrier ? delivery.firstTimestamp ?? delivery.timestamp : delivery.timestamp
        return ChatBackgroundWorkEnd(
            state: state(of: delivery.notification), offset: delivery.offset,
            endedAt: ClaudeTranscriptProjection.date(timestamp), usage: delivery.notification.usage)
    }

    /// The first `agents_killed` record past `offset`, which stops work
    /// launched before it.
    func end(stoppingAfter offset: UInt64) -> ChatBackgroundWorkEnd? {
        agentsKilled.first(where: { $0.byteOffset > offset }).map { killed in
            ChatBackgroundWorkEnd(
                state: .stopped, offset: killed.byteOffset, endedAt: ClaudeTranscriptProjection.date(killed.timestamp))
        }
    }

    /// The same reading `backgroundStatus` gives the call's row.
    private static func state(of notification: ClaudeTaskNotification) -> ChatBackgroundWorkItem.State {
        switch notification.status {
        case "failed": .failed
        case "killed", "stopped": .stopped
        case "blocked": .running
        default: .completed
        }
    }

    /// Turns that placed an entry, oldest first. A turn whose last reply
    /// was an API error failed, unless it was interrupted.
    var turns: [ChatTurn] {
        turnDrafts.compactMap { draft in
            draft.firstEntryID.map {
                let ending = draft.ending == .completed && draft.failed ? .failed : draft.ending
                return ChatTurn(firstEntryID: $0, startedAt: draft.startedAt, endedAt: draft.endedAt, ending: ending)
            }
        }
    }

    /// Opens a turn at a prompt, command or notification, and closes the
    /// open one at `turn_duration` or an interrupt marker. An interrupted
    /// turn keeps that ending through the `turn_duration` after it. A
    /// close before any opener ends the turn opened above the loaded lines.
    private mutating func noteTurn(_ record: ClaudeRecord) {
        if Self.opensTurn(record, whileOpen: turnOpen) {
            turnDrafts.append(TurnDraft(startedAt: ClaudeTranscriptProjection.date(record.timestamp)))
            turnOpen = true
            return
        }
        let closing: ChatTurn.Ending?
        switch record.kind {
        case .system("turn_duration"): closing = .completed
        case .user where Self.isInterruptMarker(record) && record.toolResults.isEmpty: closing = .interrupted
        default: closing = nil
        }
        guard !turnDrafts.isEmpty else {
            guard let closing, precedingTurnEnd.map({ $0.ending == .interrupted }) ?? true else { return }
            let endedAt = ClaudeTranscriptProjection.date(record.timestamp) ?? precedingTurnEnd?.endedAt
            precedingTurnEnd = ChatTurnEnd(ending: precedingTurnEnd?.ending ?? closing, endedAt: endedAt)
            return
        }
        let index = turnDrafts.count - 1
        if turnOpen, case .assistant = record.kind, !record.blocks.isEmpty {
            // Claude Code retries a failed request; a reply after the
            // error clears it.
            turnDrafts[index].failed = record.isAPIError
        }
        // Only the `turn_duration` that follows an interrupt closes a turn
        // already closed.
        guard let closing, turnOpen || turnDrafts[index].ending == .interrupted else { return }
        turnDrafts[index].endedAt = ClaudeTranscriptProjection.date(record.timestamp) ?? turnDrafts[index].endedAt
        if turnDrafts[index].ending != .interrupted { turnDrafts[index].ending = closing }
        turnOpen = false
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
            case .prompt(let message): addSystemNotice(message, at: record)
            case .external(let messages): addSystemNotices(messages, at: record)
            default: break
            }
            return
        }
        if Self.isInterruptMarker(record) {
            addInterruptMarker(record, text: text)
            return
        }
        // A prompt queued during a turn and delivered as a user record
        // (`promptSource` `queued`) opens the next turn, as every user record
        // does, so it reads as sent directly.
        switch ClaudeUserText.classify(text) {
        case .prompt(let prompt):
            guard ClaudeTranscriptProjection.isHuman(record.originKind), record.promptSource != "system" else {
                addSystemNotice(prompt, at: record)
                return
            }
            guard !prompt.isEmpty || record.imageCount > 0 else { return }
            add(
                "user:\(record.uuid)", at: record,
                .user(
                    ChatUserMessage(
                        text: prompt, imageCount: record.imageCount, imagePaths: imageSources[record.uuid] ?? [])))
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
                            text: invocation.displayText, imageCount: record.imageCount,
                            imagePaths: imageSources[record.uuid] ?? [], command: invocation)))
            }
        case .localCommandOutput(let output):
            addOutputNotice(output: output, at: record)
        case .bashInput(let command):
            let output = takeOutput(below: record, as: Self.bashOutput)
            add(
                "notice:\(record.uuid)", at: record,
                .notice(ChatNotice(kind: .shellCommand, title: command, detail: output?.nonEmpty)))
        case .bashOutput(let output):
            addOutputNotice(output: output, at: record)
        case .taskNotification(let notification):
            add("notice:\(record.uuid)", at: record, .notice(Self.notice(for: notification)))
        case .external(let messages):
            addSystemNotices(messages, at: record)
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
        let title =
            trimmed.hasPrefix("[Request interrupted by user")
            ? String(localized: "Interrupted") : ClaudeText.noticeParts(trimmed).title
        add("notice:\(record.uuid)", at: record, .notice(ChatNotice(kind: .interrupted, title: title)))
    }

    private mutating func attachCompactionSummary(_ record: ClaudeRecord) {
        guard let index = compactionEntry, case .divider(var divider) = entries[index].content,
            divider.detail == nil
        else { return }
        let summary = record.texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        divider.detail = ChatDivider.compaction(summary: ClaudeTranscriptProjection.compactionPreview(summary)).detail
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
                .notice(ChatNotice(kind: .stopped, title: String(localized: "All background agents stopped"))))
        case "scheduled_task_fire":
            // Its prompt follows as a meta record; the line stands for both,
            // not a bubble, since nobody typed it.
            add(
                "notice:\(record.uuid)", at: record,
                .notice(
                    ChatNotice(
                        kind: .scheduledTask, title: String(localized: "Scheduled task"),
                        detail: record.system?.scheduledPrompt)))
        case "informational" where ClaudeTranscriptProjection.unknownCommand(record) != nil:
            addUnknownCommand(record, content: content)
        default:
            // Turn timings, away summaries, other informational lines,
            // memory saves and anything unknown stay hidden.
            break
        }
    }

    /// A command Claude Code didn't know, which it ran nothing for, with the
    /// arguments the record below it names.
    private mutating func addUnknownCommand(_ record: ClaudeRecord, content: String) {
        var notice = ChatNotice(kind: .error, title: content)
        if let child = children[record.uuid]?.first(where: {
            !consumed.contains($0.uuid) && ClaudeTranscriptProjection.unknownSkillArguments($0, below: record) != nil
        }) {
            consumed.insert(child.uuid)
            notice.detail = child.system?.content
        }
        add("notice:\(record.uuid)", at: record, .notice(notice))
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
                addOutputNotice(output: output, at: record)
            }
        case .prompt(let text):
            addOutputNotice(output: text, at: record)
        default:
            break
        }
    }

    /// Bubbles for prompts queued in the running turn and not delivered
    /// yet, marked Queued until the bubble their delivery adds replaces
    /// them; returns their entries by enqueue offset. A turn opened above the
    /// loaded lines is running when they neither open nor close one and the
    /// Agent works.
    mutating func addWaitingPrompts(_ waiting: [(offset: UInt64, text: String)]) -> [UInt64: ChatEntryID] {
        let opener: UInt64
        if turnOpen, let last = turnBoundaries.last {
            opener = last
        } else if turnBoundaries.isEmpty, activity == .working || activity == .blocked {
            opener = 0
        } else {
            return [:]
        }
        var added: [UInt64: ChatEntryID] = [:]
        for prompt in waiting where prompt.offset >= opener {
            let id = ChatEntryID("queued:\(prompt.offset)")
            guard entryIDs.insert(id).inserted else { continue }
            entries.append(
                ChatEntry(
                    id: id, sourceOffset: prompt.offset,
                    content: .user(ChatUserMessage(text: prompt.text, delivery: .queued))))
            added[prompt.offset] = id
        }
        return added
    }

    /// A prompt or notification delivered into a running turn.
    private mutating func addQueuedCommand(_ record: ClaudeRecord) {
        guard let queued = record.attachment?.queuedCommand, !queued.isMeta else { return }
        // A user record written for the same prompt shows it instead (SDK
        // `fCe`).
        if let source = queued.sourceUUID, indexed[source] != nil { return }
        let entryID = "user:\(queued.sourceUUID ?? record.uuid)"
        let imagePaths = ClaudeTranscriptProjection.resolvedImagePaths(for: record, imageSources: imageSources)
        switch ClaudeUserText.classify(queued.text) {
        case .prompt(let prompt):
            guard ClaudeTranscriptProjection.isHuman(queued.originKind) else {
                addSystemNotice(prompt, at: record)
                return
            }
            guard !prompt.isEmpty || queued.imageCount > 0 else { return }
            add(
                entryID, at: record,
                .user(
                    ChatUserMessage(
                        text: prompt, imageCount: queued.imageCount, imagePaths: imagePaths, delivery: .steered)))
        case .command(let invocation):
            add(
                entryID, at: record,
                .user(
                    ChatUserMessage(
                        text: invocation.displayText, imageCount: queued.imageCount, imagePaths: imagePaths,
                        command: invocation, delivery: .steered)))
        case .taskNotification(let notification):
            guard !notificationKeys.contains(Self.key(of: notification)) else { return }
            add("notice:\(record.uuid)", at: record, .notice(Self.notice(for: notification)))
        case .external(let messages):
            addSystemNotices(messages, at: record)
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
        if turnOpen, let last = turnDrafts.indices.last, turnDrafts[last].firstEntryID == nil {
            turnDrafts[last].firstEntryID = id
        }
        if case .user = content {
            latestPromptOffset = max(latestPromptOffset ?? 0, record.byteOffset)
        }
        if entryByRecord[record.uuid] == nil {
            entryByRecord[record.uuid] = id
        }
        return true
    }

    private mutating func addSystemNotice(_ text: String, at record: ClaudeRecord, suffix: String = "") {
        let parts = ClaudeText.noticeParts(text)
        guard !parts.title.isEmpty else { return }
        add(
            "notice:\(record.uuid)\(suffix)", at: record,
            .notice(ChatNotice(kind: .system, title: parts.title, detail: parts.detail)))
    }

    /// One notice per message a record from outside holds.
    private mutating func addSystemNotices(_ messages: [String], at record: ClaudeRecord) {
        for (position, message) in messages.enumerated() {
            addSystemNotice(message, at: record, suffix: position == 0 ? "" : "#\(position)")
        }
    }

    /// Output whose command is not on the branch.
    private mutating func addOutputNotice(output: String, at record: ClaudeRecord) {
        let parts = ClaudeText.noticeParts(output)
        guard !parts.title.isEmpty else { return }
        add("notice:\(record.uuid)", at: record, .notice(ChatNotice(kind: .system, title: parts.title, detail: parts.detail)))
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

    /// The results a record carries, each with the text blocks after it.
    static func answers(in record: ClaudeRecord) -> [Answer] {
        var answers: [Answer] = []
        for block in record.blocks {
            switch block {
            case .toolResult(let result):
                answers.append(Answer(record: record, result: result))
            case .text(let text) where !answers.isEmpty:
                answers[answers.count - 1].trailingTexts.append(text)
            default:
                break
            }
        }
        return answers
    }

    private mutating func collectAnswers(in record: ClaudeRecord) {
        for answer in Self.answers(in: record) {
            store(answer)
        }
    }

    private mutating func collectCallMessages(in record: ClaudeRecord) {
        guard let messageID = record.messageID else { return }
        for case .toolUse(let use) in record.blocks where !use.id.isEmpty {
            callMessages[use.id] = messageID
        }
    }

    /// Marks the calls an interrupt marker after their results names the
    /// reply of. Claude Code writes each result of a parallel reply in a
    /// record of its own, so the marker can follow only the last of them.
    private mutating func markStoppedCalls() {
        let stoppedReplies = chain.records.compactMap { record -> (offset: UInt64, messageID: String)? in
            guard let messageID = record.interruptedMessageID, Self.isInterruptMarker(record) else { return nil }
            return (record.byteOffset, messageID)
        }
        guard !stoppedReplies.isEmpty else { return }
        for (callID, answer) in answers {
            guard let messageID = callMessages[callID],
                stoppedReplies.contains(where: {
                    $0.messageID == messageID && $0.offset > answer.record.byteOffset
                })
            else { continue }
            answers[callID]?.stoppedWhileRunning = true
        }
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
        case .system("turn_duration"), .system("scheduled_task_fire"):
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

    /// Records that open a turn: a prompt, a command, `!` shell input, a
    /// notification or a message from outside, as a user record. Between
    /// turns, a local command and a message Chat shows from a visible
    /// origin open one too: what follows them is not the turn before.
    private static func opensTurn(_ record: ClaudeRecord, whileOpen: Bool) -> Bool {
        switch record.kind {
        case .system("scheduled_task_fire"):
            // Fired between turns; its reply is not the turn before's.
            return true
        case .system("local_command"):
            guard !whileOpen, case .command = ClaudeUserText.classify(record.system?.content ?? "") else { return false }
            return true
        case .user:
            break
        default:
            return false
        }
        guard record.toolResults.isEmpty, !record.isCompactSummary, record.sourceToolUseID == nil,
            !isInterruptMarker(record)
        else { return false }
        let text = ClaudeUserText.classify(record.texts.joined(separator: "\n"))
        if record.isMeta {
            guard !whileOpen, let origin = record.originKind,
                ClaudeTranscriptProjection.visibleMetaOrigins.contains(origin)
            else { return false }
            switch text {
            case .prompt, .external: return true
            default: return false
            }
        }
        switch text {
        case .prompt, .command, .bashInput, .taskNotification, .external: return true
        default: return false
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

    /// A Monitor's events share their task, status and summary, and differ
    /// only in what they say.
    private static func key(of notification: ClaudeTaskNotification) -> String {
        [notification.taskID, notification.toolUseID, notification.status, notification.summary, notification.event]
            .map { $0 ?? "" }.joined(separator: "\u{1F}")
    }

    /// The agent's report, or what a Monitor's event said, under the title.
    private static func notice(for notification: ClaudeTaskNotification) -> ChatNotice {
        ChatNotice(
            kind: .taskNotification, title: notification.title,
            detail: (notification.result ?? notification.event).map { ChatToolPreview(capping: $0).text }?.nonEmpty)
    }
}

extension String {
    /// Nil for an empty string.
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
