import Foundation

/// One line of a Claude Code transcript after decoding.
///
/// The entry format is internal to Claude Code and changes between releases,
/// so decoding is lenient: every field is optional, a field of an unexpected
/// type reads as absent, and only a line that is not a JSON object with a
/// string `type` is invalid. Payloads that can be huge (tool output, written
/// files, images) are reduced here to capped previews and counts, so a
/// decoded record never holds more than a row can show.
enum ClaudeLine: Sendable, Equatable {
    /// A record on the `parentUuid` tree.
    case record(ClaudeRecord)
    /// A record off the tree: titles, modes, queue operations, links.
    case metadata(ClaudeMetadata)
    case invalid

    /// The record types that carry `uuid`/`parentUuid` (SDK `Lve`).
    static let chainTypes: Set<String> = ["user", "assistant", "system", "attachment", "progress"]

    static func decode(_ line: ChatLine) -> ClaudeLine {
        guard !line.isTruncated,
            let raw = try? JSONDecoder().decode(RawLine.self, from: line.data),
            let type = raw.type
        else { return .invalid }
        if chainTypes.contains(type) {
            guard let uuid = raw.uuid else { return .invalid }
            return .record(ClaudeRecord(raw, type: type, uuid: uuid, line: line))
        }
        // A type this adapter has never seen that still sits on the tree is
        // kept as an opaque link, so the records below it stay reachable.
        if let uuid = raw.uuid, raw.hasParentKey, !ClaudeMetadata.knownTypes.contains(type) {
            return .record(
                ClaudeRecord(
                    uuid: uuid, parentUUID: raw.parentUUID, kind: .unknown(type),
                    byteOffset: line.offset, byteLength: line.length,
                    isSidechain: raw.isSidechain ?? false, agentID: raw.agentID,
                    sessionID: raw.sessionID))
        }
        return .metadata(ClaudeMetadata(raw, type: type))
    }
}

/// A record on the conversation tree: a message, a tool result, a system
/// event or an attachment.
struct ClaudeRecord: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case user
        case assistant
        /// A `system` record and its `subtype`.
        case system(String)
        /// An `attachment` record and its `attachment.type`.
        case attachment(String)
        /// Written by older releases; never shown and never a leaf.
        case progress
        /// A record type this adapter does not know.
        case unknown(String)
    }

    let uuid: String
    let parentUUID: String?
    let kind: Kind
    /// Where the record's line starts: the only ordering key. Timestamps are
    /// not monotonic in file order.
    let byteOffset: UInt64
    let byteLength: Int
    var isSidechain = false
    var isMeta = false
    var teamName: String?
    var agentID: String?
    var sessionID: String?

    /// The message content of a user or assistant record. A string content
    /// is one text block.
    var blocks: [ClaudeContentBlock] = []
    /// The API message an assistant block belongs to. Claude Code writes
    /// each block of one response as its own record.
    var messageID: String?
    var apiBlockIndex: Int?
    var thinkingDurationMilliseconds: Int?
    var isAPIError = false

    var promptSource: String?
    var originKind: String?
    /// Set on messages a tool call produced, such as the skill a Skill call
    /// loaded. They read like user text but nobody typed them.
    var sourceToolUseID: String?
    var isCompactSummary = false
    /// On an interrupt marker: the assistant `message.id` it cut short.
    var interruptedMessageID: String?
    /// On a tool-result record: the denial fields and the reduced
    /// `toolUseResult`.
    var toolResult: ClaudeToolResultDetails?

    var system: ClaudeSystemDetails?
    var attachment: ClaudeAttachmentDetails?

    var isUserOrAssistant: Bool {
        switch kind {
        case .user, .assistant: true
        default: false
        }
    }

    var isCompactBoundary: Bool { kind == .system("compact_boundary") }

    /// The tool results this record carries.
    var toolResults: [ClaudeToolResult] {
        blocks.compactMap {
            if case .toolResult(let result) = $0 { return result }
            return nil
        }
    }

    /// The tool calls this record carries.
    var toolUses: [ClaudeToolUse] {
        blocks.compactMap {
            if case .toolUse(let use) = $0 { return use }
            return nil
        }
    }

    /// The text blocks, in order.
    var texts: [String] {
        blocks.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }
    }

    var imageCount: Int {
        blocks.reduce(0) { count, block in block == .image ? count + 1 : count }
    }
}

/// One content block of a message.
enum ClaudeContentBlock: Sendable, Equatable {
    case text(String)
    /// The reasoning text, often empty: recent models record a signature
    /// only.
    case thinking(String)
    case redactedThinking
    case toolUse(ClaudeToolUse)
    case toolResult(ClaudeToolResult)
    /// An image. Only its presence is kept, never its data.
    case image
    /// The request fell back to another model.
    case fallback(from: String?, to: String?)
    /// A block type with nothing to show (`tool_reference`, `document`, or
    /// one this adapter does not know).
    case other(String)
}

struct ClaudeToolUse: Sendable, Equatable {
    let id: String
    let name: String
    var input: ClaudeToolInput
}

/// The fields of a tool call's input that rows and Blocked cards use. Large
/// inputs (a written file, an edit's strings) are not kept.
struct ClaudeToolInput: Sendable, Equatable {
    var command: String?
    var description: String?
    /// `file_path`, or `notebook_path` for notebook tools.
    var filePath: String?
    var path: String?
    var pattern: String?
    var url: String?
    var query: String?
    var prompt: String?
    var subagentType: String?
    var plan: String?
    var planFilePath: String?
    var questions: [ChatQuestion] = []
    var todos: [ClaudeTodo]?
    var skill: String?
    var arguments: String?
}

struct ClaudeTodo: Sendable, Equatable {
    var content: String
    var status: String?
}

/// One `tool_result` block.
struct ClaudeToolResult: Sendable, Equatable {
    let toolUseID: String
    var isError: Bool
    /// The result's text capped to a preview, with its image count.
    var content: ChatToolPreview
}

/// The fields beside a tool result that say how the call ended.
struct ClaudeToolResultDetails: Sendable, Equatable {
    /// `user-rejected`, `permission-rule`, `automode-blocked`, …
    var denialKind: String?
    var userFeedback: String?
    /// The approval request expired or was closed unanswered.
    var isDenialUnanswered = false
    var result: ClaudeToolUseResult?
}

/// `toolUseResult`, reduced to what a row shows. The full output stays in
/// the file and is re-read on demand.
struct ClaudeToolUseResult: Sendable, Equatable {
    /// Bash `stdout`, then `stderr`, capped.
    var commandOutput: ChatToolPreview?
    var isInterrupted = false
    var backgroundTaskID: String?
    var persistedOutputPath: String?
    /// Write `create`/`update`; Read `text`/`image`/…
    var type: String?
    var filePath: String?
    /// Line counts from `structuredPatch`, or a created file's lines.
    var diff: ChatDiffStats?
    /// The patch as unified-diff hunks, or a created file's start, capped.
    var diffPreview: ChatToolPreview?
    /// Agent: `completed`, `async_launched`, `remote_launched`.
    var status: String?
    var agentID: String?
    /// A completed Agent's final report, capped.
    var agentReport: ChatToolPreview?
    /// AskUserQuestion answers by question text.
    var answers: [String: String] = [:]
    /// ExitPlanMode: the plan as approved, which can differ from the input.
    var plan: String?
    var todos: [ClaudeTodo]?
}

struct ClaudeSystemDetails: Sendable, Equatable {
    /// `content`, capped: local command input and output, notices.
    var content: String?
    var logicalParentUUID: String?
    var compaction: ClaudeCompaction?
    var retractedMessageUUIDs: [String] = []
    var originalModel: String?
    var fallbackModel: String?
    /// `commandRun` on a local command record.
    var commandRun: ChatCommandInvocation?
}

/// `compactMetadata` of a `compact_boundary`.
struct ClaudeCompaction: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        var headUUID: String
        var anchorUUID: String
        var tailUUID: String
    }

    struct PreservedMessages: Sendable, Equatable {
        var anchorUUID: String
        var uuids: [String]
    }

    var trigger: String?
    var preTokens: Int?
    var preservedSegment: Segment?
    var preservedMessages: PreservedMessages?
}

struct ClaudeAttachmentDetails: Sendable, Equatable {
    var queuedCommand: ClaudeQueuedCommand?
    /// `plan_mode` and `plan_mode_exit`.
    var planFilePath: String?
}

/// A `queued_command` attachment: a prompt or notification delivered while
/// a turn was running.
struct ClaudeQueuedCommand: Sendable, Equatable {
    var text: String
    var imageCount: Int
    var sourceUUID: String?
    /// `prompt` or `task-notification`.
    var commandMode: String?
    var originKind: String?
    var isMeta: Bool
}

/// A record off the conversation tree. Most are re-appended in blocks so
/// the file's tail holds current values: the last one wins.
enum ClaudeMetadata: Sendable, Equatable {
    case customTitle(String)
    case aiTitle(String)
    /// The legacy title source.
    case summary(String)
    case permissionMode(String)
    case relocated(cwd: String)
    case continuedIn(sessionID: String)
    case queueOperation(operation: String, content: String?)
    /// A type with nothing Chat uses.
    case other(String)

    /// Types the CLI writes off the tree (`cli@77766524` and the re-append
    /// list). Anything else is reported as unknown.
    static let knownTypes: Set<String> = [
        "last-prompt", "custom-title", "ai-title", "tag", "relocated", "agent-name",
        "agent-color", "agent-setting", "mode", "permission-mode", "isolation-latch",
        "dev-mods", "memory-mode", "atis-latch", "worktree-state", "pr-link", "frame-link",
        "file-history-snapshot", "file-history-delta", "continued-in", "content-replacement",
        "api-request-shape", "api-request-blob", "fork-context-ref", "ended-by-model",
        "history-suppression", "attribution-snapshot", "cost-state", "queue-operation",
        "observer-ref", "summary",
    ]

    fileprivate init(_ raw: RawLine, type: String) {
        switch type {
        case "custom-title":
            self = raw.customTitle.map(Self.customTitle) ?? .other(type)
        case "ai-title":
            self = raw.aiTitle.map(Self.aiTitle) ?? .other(type)
        case "summary":
            self = raw.summary.map(Self.summary) ?? .other(type)
        case "permission-mode":
            self = raw.permissionMode.map(Self.permissionMode) ?? .other(type)
        case "relocated":
            self = raw.relocatedCwd.map { .relocated(cwd: $0) } ?? .other(type)
        case "continued-in":
            self = raw.continuedInSessionID.map { .continuedIn(sessionID: $0) } ?? .other(type)
        case "queue-operation":
            self = raw.operation.map { .queueOperation(operation: $0, content: raw.content) } ?? .other(type)
        default:
            self = .other(type)
        }
    }
}

// MARK: - Reduction

extension ClaudeRecord {
    /// The most `content` a system record keeps. Local command output can be
    /// long; a notice shows a capped part of it.
    static let systemContentCap = 16 * 1_024

    fileprivate init(_ raw: RawLine, type: String, uuid: String, line: ChatLine) {
        let kind: Kind =
            switch type {
            case "user": .user
            case "assistant": .assistant
            case "system": .system(raw.subtype ?? "")
            case "attachment": .attachment(raw.attachment?.type ?? "")
            default: .progress
            }
        self.init(
            uuid: uuid, parentUUID: raw.parentUUID, kind: kind,
            byteOffset: line.offset, byteLength: line.length,
            isSidechain: raw.isSidechain ?? false, isMeta: raw.isMeta ?? false,
            teamName: raw.teamName, agentID: raw.agentID, sessionID: raw.sessionID)
        switch kind {
        case .user, .assistant:
            blocks = raw.message?.content.map(ClaudeContentBlock.init) ?? []
            messageID = raw.message?.id
            apiBlockIndex = raw.apiBlockIndex
            thinkingDurationMilliseconds = raw.thinkingDurationMs
            isAPIError = raw.isApiErrorMessage ?? false
            promptSource = raw.promptSource
            originKind = raw.origin?.kind
            sourceToolUseID = raw.sourceToolUseID
            isCompactSummary = (raw.isCompactSummary ?? false) || (raw.isVisibleInTranscriptOnly ?? false)
            interruptedMessageID = raw.interruptedMessageId
            if blocks.contains(where: { if case .toolResult = $0 { true } else { false } }) {
                toolResult = ClaudeToolResultDetails(
                    denialKind: raw.toolDenialKind, userFeedback: raw.userFeedback,
                    isDenialUnanswered: raw.toolDenialUnanswered,
                    result: raw.toolUseResult.map(ClaudeToolUseResult.init))
            }
        case .system:
            system = ClaudeSystemDetails(
                content: raw.content.map { String($0.prefix(Self.systemContentCap)) },
                logicalParentUUID: raw.logicalParentUUID,
                compaction: raw.compactMetadata.map(ClaudeCompaction.init),
                retractedMessageUUIDs: raw.retractedMessageUuids ?? [],
                originalModel: raw.originalModel, fallbackModel: raw.fallbackModel,
                commandRun: raw.commandRun.flatMap { run in
                    run.command.map {
                        ChatCommandInvocation(
                            name: $0.hasPrefix("/") ? String($0.dropFirst()) : $0, arguments: run.args ?? "")
                    }
                })
        case .attachment(let attachmentType):
            guard let rawAttachment = raw.attachment else { break }
            var details = ClaudeAttachmentDetails(planFilePath: rawAttachment.planFilePath)
            if attachmentType == "queued_command" {
                let blocks = rawAttachment.prompt ?? []
                details.queuedCommand = ClaudeQueuedCommand(
                    text: blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n"),
                    imageCount: blocks.filter { $0.type == "image" }.count,
                    sourceUUID: rawAttachment.sourceUUID.flatMap { $0.isEmpty ? nil : $0 },
                    commandMode: rawAttachment.commandMode,
                    originKind: rawAttachment.origin?.kind, isMeta: rawAttachment.isMeta ?? false)
            }
            attachment = details
        case .progress, .unknown:
            break
        }
    }
}

extension ClaudeContentBlock {
    fileprivate init(_ raw: RawBlock) {
        switch raw.type {
        case "text":
            self = .text(raw.text ?? "")
        case "thinking":
            self = .thinking(raw.thinking ?? "")
        case "redacted_thinking":
            self = .redactedThinking
        case "tool_use", "server_tool_use":
            self = .toolUse(
                ClaudeToolUse(
                    id: raw.id ?? "", name: raw.name ?? "",
                    input: raw.input.map(ClaudeToolInput.init) ?? ClaudeToolInput()))
        case "tool_result":
            let parts = raw.content ?? []
            let text = parts.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            self = .toolResult(
                ClaudeToolResult(
                    toolUseID: raw.toolUseID ?? "", isError: raw.isError ?? false,
                    content: ChatToolPreview(
                        capping: text, imageCount: parts.filter { $0.type == "image" }.count)))
        case "image":
            self = .image
        case "fallback":
            self = .fallback(from: raw.from?.model, to: raw.to?.model)
        default:
            self = .other(raw.type ?? "")
        }
    }
}

extension ClaudeToolInput {
    fileprivate init(_ raw: RawToolInput) {
        self.init(
            command: raw.command, description: raw.description,
            filePath: raw.filePath ?? raw.notebookPath, path: raw.path, pattern: raw.pattern,
            url: raw.url, query: raw.query, prompt: raw.prompt, subagentType: raw.subagentType,
            plan: raw.plan, planFilePath: raw.planFilePath,
            questions: (raw.questions ?? []).compactMap { question in
                guard let text = question.question else { return nil }
                return ChatQuestion(
                    header: question.header, text: text,
                    options: (question.options ?? []).compactMap(\.label))
            },
            todos: raw.todos?.compactMap(ClaudeTodo.init), skill: raw.skill, arguments: raw.args)
    }
}

extension ClaudeTodo {
    fileprivate init?(_ raw: RawTodo) {
        guard let content = raw.content else { return nil }
        self.init(content: content, status: raw.status)
    }
}

extension ClaudeToolUseResult {
    fileprivate init(_ raw: RawToolUseResult) {
        self.init()
        let output = [raw.stdout, raw.stderr].compactMap { $0 }.filter { !$0.isEmpty }
        if !output.isEmpty {
            commandOutput = ClaudeText.preview(joining: output)
        }
        isInterrupted = raw.interrupted ?? false
        backgroundTaskID = raw.backgroundTaskId
        persistedOutputPath = raw.persistedOutputPath
        type = raw.type
        filePath = raw.filePath
        if let hunks = raw.structuredPatch, !hunks.isEmpty {
            var added = 0
            var removed = 0
            var lines: [String] = []
            for hunk in hunks {
                lines.append(
                    "@@ -\(hunk.oldStart ?? 0),\(hunk.oldLines ?? 0) +\(hunk.newStart ?? 0),\(hunk.newLines ?? 0) @@")
                for line in hunk.lines ?? [] {
                    if line.hasPrefix("+") { added += 1 }
                    if line.hasPrefix("-") { removed += 1 }
                    lines.append(line)
                }
            }
            diff = ChatDiffStats(added: added, removed: removed)
            diffPreview = ChatToolPreview(capping: lines.joined(separator: "\n"))
        } else if raw.type == "create", let content = raw.contentText {
            diff = ChatDiffStats(added: Self.lineCount(content), removed: 0)
            diffPreview = ChatToolPreview(capping: content)
        }
        status = raw.status
        agentID = raw.agentId
        if let report = raw.contentBlocks?.compactMap({ $0.type == "text" ? $0.text : nil }), !report.isEmpty {
            agentReport = ChatToolPreview(capping: report.joined(separator: "\n"))
        }
        answers = raw.answers ?? [:]
        plan = raw.plan
        todos = raw.newTodos?.compactMap(ClaudeTodo.init)
    }

    /// Lines in a file's text: a final newline ends the last line rather
    /// than starting another.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return text.utf8.last == 0x0A ? newlines : newlines + 1
    }
}

extension ClaudeCompaction {
    fileprivate init(_ raw: RawCompactMetadata) {
        self.init(trigger: raw.trigger, preTokens: raw.preTokens)
        if let segment = raw.preservedSegment, let head = segment.headUuid, let anchor = segment.anchorUuid,
            let tail = segment.tailUuid
        {
            preservedSegment = Segment(headUUID: head, anchorUUID: anchor, tailUUID: tail)
        }
        if let messages = raw.preservedMessages, let anchor = messages.anchorUuid, let uuids = messages.uuids {
            preservedMessages = PreservedMessages(anchorUUID: anchor, uuids: uuids)
        }
    }
}

// MARK: - Wire shapes

extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is absent, null or of another
    /// type: one odd field never costs the whole record.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

private struct RawLine: Decodable {
    var type: String?
    var subtype: String?
    var uuid: String?
    var parentUUID: String?
    var hasParentKey = false
    var logicalParentUUID: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var teamName: String?
    var agentID: String?
    var sessionID: String?
    var message: RawMessage?
    var apiBlockIndex: Int?
    var thinkingDurationMs: Int?
    var isApiErrorMessage: Bool?
    var promptSource: String?
    var origin: RawOrigin?
    var sourceToolUseID: String?
    var isCompactSummary: Bool?
    var isVisibleInTranscriptOnly: Bool?
    var interruptedMessageId: String?
    var toolUseResult: RawToolUseResult?
    var toolDenialKind: String?
    var userFeedback: String?
    var toolDenialUnanswered = false
    var content: String?
    var compactMetadata: RawCompactMetadata?
    var retractedMessageUuids: [String]?
    var originalModel: String?
    var fallbackModel: String?
    var commandRun: RawCommandRun?
    var attachment: RawAttachment?
    var customTitle: String?
    var aiTitle: String?
    var summary: String?
    var permissionMode: String?
    var relocatedCwd: String?
    var continuedInSessionID: String?
    var operation: String?

    private enum CodingKeys: String, CodingKey {
        case type, subtype, uuid, parentUuid, logicalParentUuid, isSidechain, isMeta, teamName
        case agentId, sessionId, message, apiBlockIndex, thinkingDurationMs, isApiErrorMessage
        case promptSource, origin, sourceToolUseID, isCompactSummary, isVisibleInTranscriptOnly
        case interruptedMessageId
        case toolUseResult, toolDenialKind, userFeedback, toolDenialUnanswered, content
        case compactMetadata, retractedMessageUuids, originalModel, fallbackModel, commandRun
        case attachment, customTitle, aiTitle, summary, permissionMode, relocatedCwd
        case continuedInSessionId, operation
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        subtype = c.lenient(String.self, .subtype)
        uuid = c.lenient(String.self, .uuid)
        parentUUID = c.lenient(String.self, .parentUuid)
        hasParentKey = c.contains(.parentUuid)
        logicalParentUUID = c.lenient(String.self, .logicalParentUuid)
        isSidechain = c.lenient(Bool.self, .isSidechain)
        isMeta = c.lenient(Bool.self, .isMeta)
        teamName = c.lenient(String.self, .teamName)
        agentID = c.lenient(String.self, .agentId)
        sessionID = c.lenient(String.self, .sessionId)
        message = c.lenient(RawMessage.self, .message)
        apiBlockIndex = c.lenient(Int.self, .apiBlockIndex)
        thinkingDurationMs = c.lenient(Int.self, .thinkingDurationMs)
        isApiErrorMessage = c.lenient(Bool.self, .isApiErrorMessage)
        promptSource = c.lenient(String.self, .promptSource)
        origin = c.lenient(RawOrigin.self, .origin)
        sourceToolUseID = c.lenient(String.self, .sourceToolUseID)
        isCompactSummary = c.lenient(Bool.self, .isCompactSummary)
        isVisibleInTranscriptOnly = c.lenient(Bool.self, .isVisibleInTranscriptOnly)
        interruptedMessageId = c.lenient(String.self, .interruptedMessageId)
        toolUseResult = c.lenient(RawToolUseResult.self, .toolUseResult)
        toolDenialKind = c.lenient(String.self, .toolDenialKind)
        userFeedback = c.lenient(String.self, .userFeedback)
        // A reason string in 2.1.291 (`stream-closed`); a flag is accepted too.
        toolDenialUnanswered =
            c.lenient(Bool.self, .toolDenialUnanswered)
            ?? c.lenient(String.self, .toolDenialUnanswered).map { !$0.isEmpty } ?? false
        content = c.lenient(String.self, .content)
        compactMetadata = c.lenient(RawCompactMetadata.self, .compactMetadata)
        retractedMessageUuids = c.lenient([String].self, .retractedMessageUuids)
        originalModel = c.lenient(String.self, .originalModel)
        fallbackModel = c.lenient(String.self, .fallbackModel)
        commandRun = c.lenient(RawCommandRun.self, .commandRun)
        attachment = c.lenient(RawAttachment.self, .attachment)
        customTitle = c.lenient(String.self, .customTitle)
        aiTitle = c.lenient(String.self, .aiTitle)
        summary = c.lenient(String.self, .summary)
        permissionMode = c.lenient(String.self, .permissionMode)
        relocatedCwd = c.lenient(String.self, .relocatedCwd)
        continuedInSessionID = c.lenient(String.self, .continuedInSessionId)
        operation = c.lenient(String.self, .operation)
    }
}

private struct RawOrigin: Decodable {
    var kind: String?

    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: any Decoder) throws {
        kind = try? decoder.container(keyedBy: CodingKeys.self).lenient(String.self, .kind)
    }
}

/// A message's content: a string, or an array of blocks.
private struct RawMessage: Decodable {
    var id: String?
    var content: [RawBlock] = []

    private enum CodingKeys: String, CodingKey { case id, content }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenient(String.self, .id)
        content = RawBlock.blocks(in: c, .content) ?? []
    }
}

/// Any content block. Every field any block type uses is optional, and an
/// element that is not an object decodes as a block without a type, so one
/// odd element never fails its array.
private struct RawBlock: Decodable {
    struct Model: Decodable {
        var model: String?
    }

    var type: String?
    var text: String?
    var thinking: String?
    var id: String?
    var name: String?
    var input: RawToolInput?
    var toolUseID: String?
    var content: [RawBlock]?
    var isError: Bool?
    var from: Model?
    var to: Model?

    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, id, name, input, content, from, to
        case toolUseID = "tool_use_id"
        case isError = "is_error"
    }

    init(text: String) {
        type = "text"
        self.text = text
    }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        type = c.lenient(String.self, .type)
        text = c.lenient(String.self, .text)
        thinking = c.lenient(String.self, .thinking)
        id = c.lenient(String.self, .id)
        name = c.lenient(String.self, .name)
        input = c.lenient(RawToolInput.self, .input)
        toolUseID = c.lenient(String.self, .toolUseID)
        content = Self.blocks(in: c, .content)
        isError = c.lenient(Bool.self, .isError)
        from = c.lenient(Model.self, .from)
        to = c.lenient(Model.self, .to)
    }

    /// A string reads as one text block.
    static func blocks<Key: CodingKey>(in container: KeyedDecodingContainer<Key>, _ key: Key) -> [RawBlock]? {
        if let text = container.lenient(String.self, key) {
            return [RawBlock(text: text)]
        }
        return container.lenient([RawBlock].self, key)
    }
}

private struct RawToolInput: Decodable {
    struct Question: Decodable {
        struct Option: Decodable {
            var label: String?

            private enum CodingKeys: String, CodingKey { case label }

            init(from decoder: any Decoder) throws {
                if let c = try? decoder.container(keyedBy: CodingKeys.self) {
                    label = c.lenient(String.self, .label)
                } else {
                    label = try? decoder.singleValueContainer().decode(String.self)
                }
            }
        }

        var question: String?
        var header: String?
        var options: [Option]?

        private enum CodingKeys: String, CodingKey { case question, header, options }

        init(from decoder: any Decoder) throws {
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            question = c.lenient(String.self, .question)
            header = c.lenient(String.self, .header)
            options = c.lenient([Option].self, .options)
        }
    }

    var command: String?
    var description: String?
    var filePath: String?
    var notebookPath: String?
    var path: String?
    var pattern: String?
    var url: String?
    var query: String?
    var prompt: String?
    var subagentType: String?
    var plan: String?
    var planFilePath: String?
    var questions: [Question]?
    var todos: [RawTodo]?
    var skill: String?
    var args: String?

    private enum CodingKeys: String, CodingKey {
        case command, description, path, pattern, url, query, prompt, plan, planFilePath
        case questions, todos, skill, args
        case filePath = "file_path"
        case notebookPath = "notebook_path"
        case subagentType = "subagent_type"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.lenient(String.self, .command)
        description = c.lenient(String.self, .description)
        filePath = c.lenient(String.self, .filePath)
        notebookPath = c.lenient(String.self, .notebookPath)
        path = c.lenient(String.self, .path)
        pattern = c.lenient(String.self, .pattern)
        url = c.lenient(String.self, .url)
        query = c.lenient(String.self, .query)
        prompt = c.lenient(String.self, .prompt)
        subagentType = c.lenient(String.self, .subagentType)
        plan = c.lenient(String.self, .plan)
        planFilePath = c.lenient(String.self, .planFilePath)
        questions = c.lenient([Question].self, .questions)
        todos = c.lenient([RawTodo].self, .todos)
        skill = c.lenient(String.self, .skill)
        args = c.lenient(String.self, .args)
    }
}

private struct RawTodo: Decodable {
    var content: String?
    var status: String?

    private enum CodingKeys: String, CodingKey { case content, status }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        content = c.lenient(String.self, .content)
        status = c.lenient(String.self, .status)
    }
}

/// `toolUseResult`: an object for most tools, a string for errors.
private struct RawToolUseResult: Decodable {
    struct Hunk: Decodable {
        var oldStart: Int?
        var oldLines: Int?
        var newStart: Int?
        var newLines: Int?
        var lines: [String]?
    }

    var stdout: String?
    var stderr: String?
    var interrupted: Bool?
    var backgroundTaskId: String?
    var persistedOutputPath: String?
    var type: String?
    var filePath: String?
    var contentText: String?
    var contentBlocks: [RawBlock]?
    var structuredPatch: [Hunk]?
    var status: String?
    var agentId: String?
    var answers: [String: String]?
    var plan: String?
    var newTodos: [RawTodo]?

    private enum CodingKeys: String, CodingKey {
        case stdout, stderr, interrupted, backgroundTaskId, persistedOutputPath, type, filePath
        case content, structuredPatch, status, agentId, answers, plan, newTodos
    }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        stdout = c.lenient(String.self, .stdout)
        stderr = c.lenient(String.self, .stderr)
        interrupted = c.lenient(Bool.self, .interrupted)
        backgroundTaskId = c.lenient(String.self, .backgroundTaskId)
        persistedOutputPath = c.lenient(String.self, .persistedOutputPath)
        type = c.lenient(String.self, .type)
        filePath = c.lenient(String.self, .filePath)
        contentText = c.lenient(String.self, .content)
        if contentText == nil {
            contentBlocks = c.lenient([RawBlock].self, .content)
        }
        structuredPatch = c.lenient([Hunk].self, .structuredPatch)
        status = c.lenient(String.self, .status)
        agentId = c.lenient(String.self, .agentId)
        answers = c.lenient([String: String].self, .answers)
        plan = c.lenient(String.self, .plan)
        newTodos = c.lenient([RawTodo].self, .newTodos)
    }
}

private struct RawCompactMetadata: Decodable {
    struct Segment: Decodable {
        var headUuid: String?
        var anchorUuid: String?
        var tailUuid: String?
    }

    struct Messages: Decodable {
        var anchorUuid: String?
        var uuids: [String]?
    }

    var trigger: String?
    var preTokens: Int?
    var preservedSegment: Segment?
    var preservedMessages: Messages?

    private enum CodingKeys: String, CodingKey { case trigger, preTokens, preservedSegment, preservedMessages }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = c.lenient(String.self, .trigger)
        preTokens = c.lenient(Int.self, .preTokens)
        preservedSegment = c.lenient(Segment.self, .preservedSegment)
        preservedMessages = c.lenient(Messages.self, .preservedMessages)
    }
}

private struct RawCommandRun: Decodable {
    var command: String?
    var args: String?

    private enum CodingKeys: String, CodingKey { case command, args }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = c.lenient(String.self, .command)
        args = c.lenient(String.self, .args)
    }
}

private struct RawAttachment: Decodable {
    var type: String?
    var prompt: [RawBlock]?
    var sourceUUID: String?
    var commandMode: String?
    var origin: RawOrigin?
    var isMeta: Bool?
    var planFilePath: String?

    private enum CodingKeys: String, CodingKey {
        case type, prompt, commandMode, origin, isMeta, planFilePath
        case sourceUUID = "source_uuid"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lenient(String.self, .type)
        prompt = RawBlock.blocks(in: c, .prompt)
        sourceUUID = c.lenient(String.self, .sourceUUID)
        commandMode = c.lenient(String.self, .commandMode)
        origin = c.lenient(RawOrigin.self, .origin)
        isMeta = c.lenient(Bool.self, .isMeta)
        planFilePath = c.lenient(String.self, .planFilePath)
    }
}
