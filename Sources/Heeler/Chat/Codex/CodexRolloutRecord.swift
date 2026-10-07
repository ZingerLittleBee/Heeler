import Foundation

// MARK: - Open string values

/// A string-backed value that keeps raw values it does not know.
///
/// Codex adds item types, phases and statuses between releases. A closed enum
/// would turn every such line into a decoding error; these keep the raw value
/// so the adapter can ignore it, count it, or render it generically.
protocol CodexOpenValue: RawRepresentable, Hashable, Sendable, Decodable, ExpressibleByStringLiteral
where RawValue == String {
    init(rawValue: String)
}

extension CodexOpenValue {
    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

/// A turn item's `type` (PascalCase in the rollout).
struct CodexItemType: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let userMessage: Self = "UserMessage"
    static let agentMessage: Self = "AgentMessage"
    static let reasoning: Self = "Reasoning"
    static let plan: Self = "Plan"
    static let contextCompaction: Self = "ContextCompaction"
    static let hookPrompt: Self = "HookPrompt"
    static let commandExecution: Self = "CommandExecution"
    static let fileChange: Self = "FileChange"
    static let mcpToolCall: Self = "McpToolCall"
    static let webSearch: Self = "WebSearch"
    static let `extension`: Self = "Extension"
    static let dynamicToolCall: Self = "DynamicToolCall"
    static let functionCallOutput: Self = "FunctionCallOutput"
    static let imageView: Self = "ImageView"
    static let imageGeneration: Self = "ImageGeneration"
    static let collabAgentToolCall: Self = "CollabAgentToolCall"
    static let subAgentActivity: Self = "SubAgentActivity"
    static let enteredReviewMode: Self = "EnteredReviewMode"
    static let exitedReviewMode: Self = "ExitedReviewMode"

    /// Items whose content is the message itself: a prefix of one shows
    /// nothing useful, so a truncated line of these kinds is skipped.
    var isMessage: Bool {
        [Self.userMessage, .agentMessage, .reasoning, .plan, .hookPrompt].contains(self)
    }
}

/// An assistant message's phase. Rendered the same whatever the value;
/// upstream main adds `partial_answer`.
struct CodexMessagePhase: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let commentary: Self = "commentary"
    static let finalAnswer: Self = "final_answer"
    static let partialAnswer: Self = "partial_answer"
}

/// A tool item's status. Most items spell it in snake_case; MCP calls use
/// camelCase (`inProgress`).
struct CodexItemStatus: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let inProgress: Self = "in_progress"
    static let inProgressCamel: Self = "inProgress"
    static let completed: Self = "completed"
    static let failed: Self = "failed"
    static let declined: Self = "declined"
    static let interrupted: Self = "interrupted"

    /// The Chat status this records, or nil while the call has no outcome.
    var chatStatus: ChatToolActivity.Status? {
        switch self {
        case .completed: .succeeded
        case .failed: .failed
        case .declined: .declined
        case .interrupted: .interrupted
        default: nil
        }
    }
}

/// One part of a user message (`UserInput`'s `type`).
struct CodexUserInputType: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let text: Self = "text"
    static let image: Self = "image"
    static let localImage: Self = "local_image"
    static let audio: Self = "audio"
    static let localAudio: Self = "local_audio"
    static let skill: Self = "skill"
    static let mention: Self = "mention"
}

/// Why a turn was aborted.
struct CodexAbortReason: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let interrupted: Self = "interrupted"
    static let replaced: Self = "replaced"
    static let reviewEnded: Self = "review_ended"
    static let budgetLimited: Self = "budget_limited"
}

/// `session_meta.history_mode`.
struct CodexHistoryMode: CodexOpenValue {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let paginated: Self = "paginated"
    static let legacy: Self = "legacy"
}

// MARK: - Lenient decoding

/// Any JSON object key, so payload decoders can name keys inline.
struct CodexKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

extension KeyedDecodingContainer where Key == CodexKey {
    /// The value under `key`, or nil when it is missing, null or another
    /// shape. Rollouts are written by many Codex versions; one odd field must
    /// not cost the whole line.
    func lenient<T: Decodable>(_ key: CodexKey, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Decodes nothing, so skipping a value never materializes it (a base64
/// image, a data URL).
struct CodexSkipped: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// An array that keeps the elements it can decode and drops the rest.
struct CodexLossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(CodexSkipped.self)) == nil {
                break
            }
        }
        self.elements = elements
    }
}

/// A string-keyed object that keeps the entries it can decode.
struct CodexLossyDictionary<Value: Decodable>: Decodable {
    var entries: [String: Value]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        var entries: [String: Value] = [:]
        for key in container.allKeys {
            if let value: Value = container.lenient(key) {
                entries[key.stringValue] = value
            }
        }
        self.entries = entries
    }
}

/// How many elements an array holds, without decoding them.
struct CodexCount: Decodable {
    var count: Int

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var count = 0
        while !container.isAtEnd, (try? container.decode(CodexSkipped.self)) != nil {
            count += 1
        }
        self.count = count
    }
}

// MARK: - Raw payloads

/// A rollout line: `{timestamp, ordinal?, type, payload}`.
struct CodexEnvelope<Payload: Decodable>: Decodable {
    var ordinal: UInt64?
    var type: String?
    var payload: Payload?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        ordinal = container.lenient("ordinal")
        type = container.lenient("type")
        payload = container.lenient("payload")
    }
}

/// `session_meta.payload.history_base`: where a reverted rollout's
/// inherited history ends in its base file.
struct CodexHistoryBase: Equatable, Sendable, Decodable {
    /// The base file's rollout id (`history_base.thread_id`, named before
    /// reverts existed).
    var baseRolloutID: String
    var endOrdinalExclusive: UInt64
    var endByteOffset: UInt64

    init(baseRolloutID: String, endOrdinalExclusive: UInt64, endByteOffset: UInt64) {
        self.baseRolloutID = baseRolloutID
        self.endOrdinalExclusive = endOrdinalExclusive
        self.endByteOffset = endByteOffset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        guard let id: String = container.lenient("thread_id"),
            let end: UInt64 = container.lenient("end_ordinal_exclusive"),
            let offset: UInt64 = container.lenient("end_byte_offset")
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "incomplete history_base"))
        }
        self.init(baseRolloutID: id, endOrdinalExclusive: end, endByteOffset: offset)
    }
}

/// The parts of `session_meta.payload` the adapter uses.
struct CodexSessionMeta: Equatable, Sendable, Decodable {
    var id: String?
    var cwd: String?
    var cliVersion: String?
    /// Nil when the key is absent: rollouts from before paginated history.
    var historyMode: CodexHistoryMode?
    /// True when `history_mode` is present but not a string.
    var hasMalformedHistoryMode: Bool
    var historyBase: CodexHistoryBase?
    /// True when `history_base` is present but unreadable, so the inherited
    /// history cannot be found.
    var hasMalformedHistoryBase: Bool
    var subagentHistoryStartOrdinal: UInt64?

    init(
        id: String? = nil, cwd: String? = nil, cliVersion: String? = nil,
        historyMode: CodexHistoryMode? = nil, historyBase: CodexHistoryBase? = nil,
        subagentHistoryStartOrdinal: UInt64? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.cliVersion = cliVersion
        self.historyMode = historyMode
        hasMalformedHistoryMode = false
        self.historyBase = historyBase
        hasMalformedHistoryBase = false
        self.subagentHistoryStartOrdinal = subagentHistoryStartOrdinal
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        id = container.lenient("id")
        cwd = container.lenient("cwd")
        cliVersion = container.lenient("cli_version")
        historyMode = container.lenient("history_mode")
        hasMalformedHistoryMode = container.contains("history_mode") && historyMode == nil
        historyBase = container.lenient("history_base")
        let baseIsNull = (try? container.decodeNil(forKey: "history_base")) ?? false
        hasMalformedHistoryBase = container.contains("history_base") && historyBase == nil && !baseIsNull
        subagentHistoryStartOrdinal = container.lenient("subagent_history_start_ordinal")
    }
}

/// Line 1 of a rollout, read loosely enough to tell an envelope from the
/// pre-envelope format (≤0.30), whose first line is `{id, instructions}`.
struct CodexFirstLine: Decodable {
    var type: String?
    var payload: CodexSessionMeta?
    var isPreEnvelope: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        payload = container.lenient("payload")
        isPreEnvelope = type == nil && container.contains("id") && container.contains("instructions")
    }
}

/// A content part of any kind: a user input, an assistant text part, a
/// response message part, an MCP content block or a tool output item. Each
/// has `type` and, for text, `text`; nothing else is decoded, so an image's
/// data never is.
struct CodexRawPart: Decodable {
    var type: String?
    var text: String?
    var path: String?
    var name: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        text = container.lenient("text")
        path = container.lenient("path")
        name = container.lenient("name")
    }
}

/// A tool output body: a string, or content items whose non-empty
/// `input_text` parts join with newlines.
struct CodexRawOutputBody: Decodable {
    var text: String
    var imageCount: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.text = text
            imageCount = 0
            return
        }
        let parts = try container.decode(CodexLossyArray<CodexRawPart>.self).elements
        text = parts.compactMap { part in
            part.type == "input_text" ? part.text.flatMap { $0.isEmpty ? nil : $0 } : nil
        }.joined(separator: "\n")
        imageCount = parts.filter { $0.type == "input_image" }.count
    }
}

struct CodexRawAsyncQuestion: Decodable {
    var title: String?
    var options: [String]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        title = container.lenient("title")
        options = container.lenient("options", as: CodexLossyArray<String>.self)?.elements
    }
}

struct CodexRawParsedCommand: Decodable {
    var type: String?
    var cmd: String?
    var name: String?
    var path: String?
    var query: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        cmd = container.lenient("cmd")
        name = container.lenient("name")
        path = container.lenient("path")
        query = container.lenient("query")
    }
}

/// One file of a patch: `add{content}`, `delete{content}` or
/// `update{unified_diff, move_path?}`.
struct CodexRawFileChange: Decodable {
    var type: String?
    var content: String?
    var unifiedDiff: String?
    var movePath: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        content = container.lenient("content")
        unifiedDiff = container.lenient("unified_diff")
        movePath = container.lenient("move_path")
    }
}

/// An MCP `CallToolResult`: content blocks and the error flag.
struct CodexRawMcpResult: Decodable {
    var content: [CodexRawPart]
    var isError: Bool?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        content = container.lenient("content", as: CodexLossyArray<CodexRawPart>.self)?.elements ?? []
        isError = container.lenient("isError") ?? container.lenient("is_error")
    }
}

/// A legacy `mcp_tool_call_end` result: Rust's `Result` as `{"Ok": …}` or
/// `{"Err": "…"}`.
struct CodexRawMcpEndResult: Decodable {
    var ok: CodexRawMcpResult?
    var error: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        ok = container.lenient("Ok")
        error = container.lenient("Err")
    }
}

struct CodexRawWebAction: Decodable {
    var type: String?
    var query: String?
    var queries: [String]?
    var url: String?
    var pattern: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        query = container.lenient("query")
        queries = container.lenient("queries", as: CodexLossyArray<String>.self)?.elements
        url = container.lenient("url")
        pattern = container.lenient("pattern")
    }
}

struct CodexRawHookFragment: Decodable {
    var text: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        text = container.lenient("text")
    }
}

/// One `{secs, nanos}` duration.
struct CodexRawDuration: Decodable {
    var milliseconds: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        guard let seconds: Int = container.lenient("secs") else {
            milliseconds = nil
            return
        }
        let nanos: Int = container.lenient("nanos") ?? 0
        milliseconds = seconds * 1_000 + nanos / 1_000_000
    }
}

/// A `TurnItem`, flattened: every item type's fields, all optional.
struct CodexRawItem: Decodable {
    var type: CodexItemType?
    var id: String?
    var kind: String?
    // UserMessage, AgentMessage.
    var content: [CodexRawPart]?
    var phase: CodexMessagePhase?
    var delivery: String?
    var questions: [CodexRawAsyncQuestion]?
    // Reasoning, Plan, HookPrompt.
    var summaryText: [String]?
    var text: String?
    var fragments: [CodexRawHookFragment]?
    // CommandExecution.
    var command: [String]?
    /// Follows `command`, so its presence shows a truncated prefix kept the
    /// whole argv.
    var cwd: String?
    var parsedCommands: [CodexRawParsedCommand]?
    var source: String?
    var status: CodexItemStatus?
    var aggregatedOutput: String?
    var exitCode: Int?
    // FileChange.
    var changes: [String: CodexRawFileChange]?
    var stdout: String?
    var stderr: String?
    // McpToolCall, DynamicToolCall, CollabAgentToolCall.
    var server: String?
    var tool: String?
    var namespace: String?
    var result: CodexRawMcpResult?
    var errorMessage: String?
    var contentItems: [CodexRawPart]?
    var success: Bool?
    var prompt: String?
    // WebSearch, web.search.
    var query: String?
    var action: CodexRawWebAction?
    // ImageView, ImageGeneration, image_gen.generation, clock.sleep.
    var path: String?
    var revisedPrompt: String?
    var savedPath: String?
    var durationMilliseconds: Int?
    // SubAgentActivity.
    var agentPath: String?
    // Review mode.
    var userFacingHint: String?
    var reviewExplanation: String?
    // FunctionCallOutput.
    var name: String?
    var output: CodexRawOutputBody?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        id = container.lenient("id")
        kind = container.lenient("kind")
        content = container.lenient("content", as: CodexLossyArray<CodexRawPart>.self)?.elements
        phase = container.lenient("phase")
        delivery = container.lenient("delivery")
        questions = container.lenient("questions", as: CodexLossyArray<CodexRawAsyncQuestion>.self)?.elements
        summaryText = container.lenient("summary_text", as: CodexLossyArray<String>.self)?.elements
        text = container.lenient("text")
        fragments = container.lenient("fragments", as: CodexLossyArray<CodexRawHookFragment>.self)?.elements
        command = container.lenient("command", as: CodexLossyArray<String>.self)?.elements
        cwd = container.lenient("cwd")
        parsedCommands = container.lenient("parsed_cmd", as: CodexLossyArray<CodexRawParsedCommand>.self)?.elements
        source = container.lenient("source")
        status = container.lenient("status")
        aggregatedOutput = container.lenient("aggregated_output")
        exitCode = container.lenient("exit_code")
        changes = container.lenient("changes", as: CodexLossyDictionary<CodexRawFileChange>.self)?.entries
        stdout = container.lenient("stdout")
        stderr = container.lenient("stderr")
        server = container.lenient("server")
        tool = container.lenient("tool")
        namespace = container.lenient("namespace")
        result = container.lenient("result")
        // McpToolCall's error is `{message}`; DynamicToolCall's is a string.
        errorMessage =
            container.lenient("error", as: CodexRawError.self)?.message ?? container.lenient("error")
        contentItems = container.lenient("content_items", as: CodexLossyArray<CodexRawPart>.self)?.elements
        success = container.lenient("success")
        prompt = container.lenient("prompt")
        query = container.lenient("query")
        action = container.lenient("action")
        path = container.lenient("path")
        revisedPrompt = container.lenient("revised_prompt") ?? container.lenient("revisedPrompt")
        savedPath = container.lenient("saved_path") ?? container.lenient("savedPath")
        durationMilliseconds = container.lenient("durationMs")
            ?? container.lenient("duration", as: CodexRawDuration.self)?.milliseconds
        agentPath = container.lenient("agent_path")
        userFacingHint = container.lenient("user_facing_hint") ?? container.lenient("review")
        reviewExplanation = container.lenient("review_output", as: CodexRawReviewOutput.self)?.explanation
        name = container.lenient("name")
        output = container.lenient("output")
    }
}

struct CodexRawError: Decodable {
    var message: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        message = container.lenient("message")
    }
}

struct CodexRawReviewOutput: Decodable {
    var explanation: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        explanation = container.lenient("overall_explanation")
    }
}

/// An `event_msg` payload, flattened over the event types the adapter reads.
struct CodexRawEvent: Decodable {
    var type: String?
    var turnID: String?
    var reason: CodexAbortReason?
    var errorMessage: String?
    var item: CodexRawItem?
    var startedAtMilliseconds: Int64?
    var completedAtMilliseconds: Int64?
    /// A turn event's times, in seconds since 1970.
    var turnStartedAt: Double?
    var turnCompletedAt: Double?
    // Legacy messages.
    var message: String?
    var kind: String?
    var imageCount: Int
    var localImages: [String]
    var audioCount: Int
    var phase: CodexMessagePhase?
    var delivery: String?
    var questions: [CodexRawAsyncQuestion]?
    var text: String?
    var numTurns: Int?
    // Legacy tool ends.
    var callID: String?
    var stdout: String?
    var stderr: String?
    var success: Bool?
    var status: CodexItemStatus?
    var changes: [String: CodexRawFileChange]?
    var server: String?
    var tool: String?
    var mcpResult: CodexRawMcpEndResult?
    var query: String?
    var action: CodexRawWebAction?
    var revisedPrompt: String?
    var savedPath: String?
    var eventID: String?
    var agentPath: String?
    var itemID: String?
    var userFacingHint: String?
    var reviewExplanation: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        turnID = container.lenient("turn_id")
        reason = container.lenient("reason")
        errorMessage = container.lenient("error", as: CodexRawError.self)?.message
        item = container.lenient("item")
        startedAtMilliseconds = container.lenient("started_at_ms")
        completedAtMilliseconds = container.lenient("completed_at_ms")
        turnStartedAt = container.lenient("started_at")
        turnCompletedAt = container.lenient("completed_at")
        message = container.lenient("message")
        kind = container.lenient("kind")
        imageCount =
            (container.lenient("images", as: CodexCount.self)?.count ?? 0)
            + (container.lenient("file_ids", as: CodexCount.self)?.count ?? 0)
        localImages = container.lenient("local_images", as: CodexLossyArray<String>.self)?.elements ?? []
        audioCount =
            (container.lenient("audio", as: CodexCount.self)?.count ?? 0)
            + (container.lenient("local_audio", as: CodexCount.self)?.count ?? 0)
        phase = container.lenient("phase")
        delivery = container.lenient("delivery")
        questions = container.lenient("questions", as: CodexLossyArray<CodexRawAsyncQuestion>.self)?.elements
        text = container.lenient("text")
        numTurns = container.lenient("num_turns")
        callID = container.lenient("call_id")
        stdout = container.lenient("stdout")
        stderr = container.lenient("stderr")
        success = container.lenient("success")
        status = container.lenient("status")
        changes = container.lenient("changes", as: CodexLossyDictionary<CodexRawFileChange>.self)?.entries
        let invocation = container.lenient("invocation", as: CodexRawInvocation.self)
        server = invocation?.server
        tool = invocation?.tool
        mcpResult = container.lenient("result")
        query = container.lenient("query")
        action = container.lenient("action")
        revisedPrompt = container.lenient("revised_prompt")
        savedPath = container.lenient("saved_path")
        eventID = container.lenient("event_id")
        agentPath = container.lenient("agent_path")
        itemID = container.lenient("item_id")
        userFacingHint = container.lenient("user_facing_hint")
        reviewExplanation = container.lenient("review_output", as: CodexRawReviewOutput.self)?.explanation
    }
}

struct CodexRawInvocation: Decodable {
    var server: String?
    var tool: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        server = container.lenient("server")
        tool = container.lenient("tool")
    }
}

/// A `response_item` payload, flattened over the types the adapter reads.
struct CodexRawResponse: Decodable {
    var type: String?
    var id: String?
    var role: String?
    var name: String?
    var namespace: String?
    var arguments: String?
    var input: String?
    var callID: String?
    var output: CodexRawOutputBody?
    var command: [String]?
    var content: [CodexRawPart]?
    var turnID: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        id = container.lenient("id")
        role = container.lenient("role")
        name = container.lenient("name")
        namespace = container.lenient("namespace")
        arguments = container.lenient("arguments")
        input = container.lenient("input")
        callID = container.lenient("call_id")
        output = container.lenient("output")
        command = container.lenient("action", as: CodexRawShellAction.self)?.command
        content = container.lenient("content", as: CodexLossyArray<CodexRawPart>.self)?.elements
        turnID = container.lenient("internal_chat_message_metadata_passthrough", as: CodexRawPassthrough.self)?
            .turnID
    }
}

struct CodexRawShellAction: Decodable {
    var command: [String]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        command = container.lenient("command", as: CodexLossyArray<String>.self)?.elements
    }
}

struct CodexRawPassthrough: Decodable {
    var turnID: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        turnID = container.lenient("turn_id")
    }
}

/// `retained_context` payloads; only `verified_answer` is read.
struct CodexRawRetained: Decodable {
    var type: String?
    var turnID: String?
    var callID: String?
    var questions: [CodexRawVerifiedQuestion]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        type = container.lenient("type")
        turnID = container.lenient("turn_id")
        callID = container.lenient("call_id")
        questions = container.lenient("questions", as: CodexLossyArray<CodexRawVerifiedQuestion>.self)?.elements
    }
}

struct CodexRawVerifiedQuestion: Decodable {
    var question: String?
    var answer: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        question = container.lenient("question")
        answer = container.lenient("answer")
    }
}

/// `request_user_input` arguments: `{questions: [{id, header, question, options: [{label}]}]}`.
struct CodexRawQuestionArguments: Decodable {
    var questions: [CodexRawSyncQuestion]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        questions = container.lenient("questions", as: CodexLossyArray<CodexRawSyncQuestion>.self)?.elements ?? []
    }
}

struct CodexRawSyncQuestion: Decodable {
    var id: String?
    var header: String?
    var question: String?
    var options: [ChatQuestion.Option]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        id = container.lenient("id")
        header = container.lenient("header")
        question = container.lenient("question")
        let options = container.lenient("options", as: CodexLossyArray<CodexRawOption>.self)?.elements ?? []
        self.options = options.compactMap { option in
            option.label.map { ChatQuestion.Option(label: $0, detail: option.description) }
        }
    }
}

/// A question option: `{label, description}` or a bare string.
struct CodexRawOption: Decodable {
    var label: String?
    var description: String?

    init(from decoder: any Decoder) throws {
        if let label = try? decoder.singleValueContainer().decode(String.self) {
            self.label = label
            return
        }
        let container = try decoder.container(keyedBy: CodexKey.self)
        label = container.lenient("label")
        description = container.lenient("description")
    }
}

/// `request_user_input` output: `{"answers": {"<id>": {"answers": [...]}}}`.
struct CodexRawAnswerOutput: Decodable {
    var answers: [String: CodexRawAnswerList]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        guard let answers = container.lenient("answers", as: CodexLossyDictionary<CodexRawAnswerList>.self)
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "no answers"))
        }
        self.answers = answers.entries
    }
}

struct CodexRawAnswerList: Decodable {
    var answers: [String]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodexKey.self)
        answers = container.lenient("answers", as: CodexLossyArray<String>.self)?.elements ?? []
    }
}

// MARK: - Records

/// A user prompt as Codex recorded it, before display rules apply.
struct CodexUserContent: Equatable, Sendable {
    /// The text parts joined without a separator, as Codex joins them.
    var text: String
    var imageCount: Int
    /// `local_image` paths, for matching an image-only send.
    var localImagePaths: [String]
    /// Chips for parts that are neither text, images, skills nor mentions.
    var attachmentLabels: [String]
    /// Names of `skill` parts: the skills the TUI recognized.
    var skillNames: [String]

    init(
        text: String, imageCount: Int = 0, localImagePaths: [String] = [],
        attachmentLabels: [String] = [], skillNames: [String] = []
    ) {
        self.text = text
        self.imageCount = imageCount
        self.localImagePaths = localImagePaths
        self.attachmentLabels = attachmentLabels
        self.skillNames = skillNames
    }
}

/// A question Codex asked outside a tool call (`delivery: async`).
struct CodexAsyncQuestion: Equatable, Sendable {
    var title: String
    var options: [String]
}

/// Assistant output: text, or a set of asynchronous questions.
struct CodexAgentContent: Equatable, Sendable {
    var text: String
    var phase: CodexMessagePhase?
    /// Questions asked with `delivery: async`; empty for ordinary text.
    var questions: [CodexAsyncQuestion]

    init(text: String, phase: CodexMessagePhase? = nil, questions: [CodexAsyncQuestion] = []) {
        self.text = text
        self.phase = phase
        self.questions = questions
    }
}

/// A question of a synchronous `request_user_input` call.
struct CodexSyncQuestion: Equatable, Sendable {
    var id: String?
    var header: String?
    var text: String
    var options: [ChatQuestion.Option]
}

/// A tool row as the record that placed it describes it. `status` is nil
/// while Codex has recorded no outcome; the projection decides what an open
/// call shows from the turn and herdr's activity.
struct CodexToolSnapshot: Equatable, Sendable {
    var kind: ChatToolActivity.Kind
    var name: String
    var title: String
    var subtitle: String?
    var status: ChatToolActivity.Status?
    var note: String?
    var diff: ChatDiffStats?
    var exitCode: Int?
    var callID: String?
    var preview: ChatToolPreview?
    var output: ChatOutputReference?

    init(
        kind: ChatToolActivity.Kind, name: String, title: String, subtitle: String? = nil,
        status: ChatToolActivity.Status?, note: String? = nil, diff: ChatDiffStats? = nil,
        exitCode: Int? = nil, callID: String? = nil, preview: ChatToolPreview? = nil,
        output: ChatOutputReference? = nil
    ) {
        self.kind = kind
        self.name = name
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.note = note
        self.diff = diff
        self.exitCode = exitCode
        self.callID = callID
        self.preview = preview
        self.output = output
    }
}

/// One turn item, reduced to what Chat renders.
struct CodexItem: Equatable, Sendable {
    var id: String
    var content: Content

    enum Content: Equatable, Sendable {
        case user(CodexUserContent)
        case agent(CodexAgentContent)
        case reasoning(String, durationMilliseconds: Int?)
        case plan(String)
        case compaction
        case hook(String)
        case review(title: String, detail: String?)
        case tool(CodexToolSnapshot)
    }
}

/// A synchronous `request_user_input` call.
struct CodexQuestionCall: Equatable, Sendable {
    var callID: String
    var turnID: String?
    var questions: [CodexSyncQuestion]
}

/// `retained_context` `verified_answer`: the answers Codex accepted for a
/// question call. A question carries its selected option on later lines.
struct CodexVerifiedAnswer: Equatable, Sendable {
    struct Answer: Equatable, Sendable {
        var question: String
        var answer: String
    }

    var turnID: String?
    var callID: String
    var answers: [Answer]
}

/// A `function_call_output` or `custom_tool_call_output`.
struct CodexCallOutput: Equatable, Sendable {
    var callID: String
    /// A question call's answers by question id, newline-joined; nil when
    /// the output is not an answer object.
    var answers: [String: String]?
    /// Codex closed the question without answers.
    var isCancelled: Bool
    var exitCode: Int?
    var preview: ChatToolPreview?
    var output: ChatOutputReference

    init(
        callID: String, answers: [String: String]? = nil, isCancelled: Bool = false,
        exitCode: Int? = nil, preview: ChatToolPreview? = nil, output: ChatOutputReference
    ) {
        self.callID = callID
        self.answers = answers
        self.isCancelled = isCancelled
        self.exitCode = exitCode
        self.preview = preview
        self.output = output
    }
}

/// A legacy rollout's tool call response item, paired with its output by
/// `call_id` wherever that appears.
struct CodexToolCall: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case tool(CodexToolSnapshot)
        case question([CodexSyncQuestion])
        /// `request_user_input_async`: no row; it names the questions that
        /// the next assistant message asks.
        case asyncQuestions
    }

    var callID: String
    var role: Role
}

/// Where a legacy event places its item (`ThreadHistoryBuilder`).
enum CodexLegacyPlacement: Equatable, Sendable {
    /// `item_completed`: only the named turn; dropped when it is unknown.
    case turn(String)
    /// Ends that carry an optional turn id: that turn, else the current one.
    case turnOrCurrent(String?)
    /// Web search, image generation and subagent events: the current turn.
    case current
    /// Review-mode events open their turn when it is unknown.
    case review(String?)
}

/// When a turn event says its turn started and ended, on the Host's clock.
struct CodexTurnTimes: Equatable, Sendable {
    var startedAt: Date?
    var completedAt: Date?

    init(startedAt: Date? = nil, completedAt: Date? = nil) {
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// What one line contributes to the transcript.
enum CodexRecord: Equatable, Sendable {
    case turnStarted(turnID: String, times: CodexTurnTimes)
    case turnCompleted(turnID: String, error: String?, times: CodexTurnTimes)
    case turnAborted(turnID: String?, reason: CodexAbortReason, error: String?, times: CodexTurnTimes)
    case item(turnID: String, CodexItem)
    case questionCall(CodexQuestionCall)
    case verifiedAnswer(CodexVerifiedAnswer)
    case callOutput(CodexCallOutput)
    // Legacy rollouts.
    case userMessage(CodexUserContent)
    case agentMessage(CodexAgentContent)
    case reasoning(String)
    case contextCompacted
    case compacted
    case rolledBack(turns: Int)
    case toolCall(CodexToolCall)
    case legacyItem(CodexItem, CodexLegacyPlacement)
}
