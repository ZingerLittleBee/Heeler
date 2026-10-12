import Foundation

@testable import Heeler

/// A JSON value that keeps object keys in the order written, so synthetic
/// lines put `type` first the way Codex does: the classifier reads only a
/// line's first bytes, and a truncated line keeps nothing else.
enum CodexJSON: Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    case string(String)
    case number(Int)
    case bool(Bool)
    case null
    case array([CodexJSON])
    case object([(String, CodexJSON)])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: CodexJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, CodexJSON)...) { self = .object(elements) }
    init(nilLiteral: ()) { self = .null }

    /// Compact JSON, escaped the way `serde_json` writes it.
    var text: String {
        switch self {
        case .string(let value): CodexMessageFormatter.jsonString(value)
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .array(let values): "[" + values.map(\.text).joined(separator: ",") + "]"
        case .object(let members):
            "{" + members.map { CodexMessageFormatter.jsonString($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }
}

/// A captured probe rollout: `probe1` (P1, 65 lines) or `probe2` (P2, 119
/// lines), numbered from 1 as docs/research/codex-rollout-format.md numbers
/// them.
struct CodexProbe {
    /// Neither probe was reverted, so each rollout id is its thread id.
    static let probe1ID = "01a10f87-e025-7fb1-8974-8dd09937767a"
    static let probe2ID = "01a10fc8-07f3-7c90-b745-fa302f852394"

    let rolloutID: String
    let data: Data
    let lines: [ChatLine]

    static func probe1() throws -> CodexProbe {
        try CodexProbe(name: "codex/probe1-rollout.jsonl", rolloutID: probe1ID)
    }

    static func probe2() throws -> CodexProbe {
        try CodexProbe(name: "codex/probe2-rollout.jsonl", rolloutID: probe2ID)
    }

    private init(name: String, rolloutID: String) throws {
        self.rolloutID = rolloutID
        data = try ChatFixture.data(name)
        lines = JSONLLineFramer.lines(in: data)
    }

    /// Line `number`, 1-based.
    func line(_ number: Int) -> ChatLine { lines[number - 1] }

    func offset(_ number: Int) -> UInt64 { line(number).offset }

    /// A reducer fed `lines` (all of them by default) in one batch.
    func reducer(_ lines: [ChatLine]? = nil) -> CodexRolloutReducer {
        var reducer = CodexRolloutReducer(rolloutID: rolloutID)
        reducer.append(lines ?? self.lines)
        return reducer
    }
}

extension CodexProjection {
    /// The entries of turn `index`, 0-based.
    func entries(inTurn index: Int) -> [ChatEntry] {
        let ids = Set(turns[index].entryIDs)
        return transcript.entries.filter { ids.contains($0.id) }
    }
}

extension ChatEntry {
    var tool: ChatToolActivity? {
        if case .tool(let tool) = content { tool } else { nil }
    }

    var notice: ChatNotice? {
        if case .notice(let notice) = content { notice } else { nil }
    }

    var user: ChatUserMessage? {
        if case .user(let message) = content { message } else { nil }
    }

    var assistant: ChatAssistantMessage? {
        if case .assistant(let message) = content { message } else { nil }
    }

    var questionSet: ChatQuestionSet? {
        if case .questions(let set) = content { set } else { nil }
    }

    var divider: ChatDivider? {
        if case .divider(let divider) = content { divider } else { nil }
    }
}

/// Writes synthetic Codex rollouts in the shapes
/// docs/research/codex-rollout-format.md documents: paginated (every line has
/// an ordinal, history is `item_completed` turn items) or legacy (no
/// ordinals, history is events and response items).
struct CodexRolloutBuilder {
    enum Dialect {
        case paginated
        case legacy
    }

    let dialect: Dialect
    private(set) var lines: [String] = []
    /// The ordinal the next paginated line takes.
    var nextOrdinal: UInt64

    /// Starts a rollout with its `session_meta` line. `metaPadding` adds a
    /// base-instructions string of that many bytes, as large real metas
    /// have, ahead of `history_mode`.
    init(
        _ dialect: Dialect = .paginated, threadID: String = "thread-1", cwd: String = "/work",
        historyMode: CodexJSON? = nil, historyBase: (rolloutID: String, endOrdinal: Int, endOffset: Int)? = nil,
        subagentHistoryStartOrdinal: Int? = nil, metaPadding: Int = 0, firstOrdinal: UInt64 = 0
    ) {
        self.dialect = dialect
        nextOrdinal = firstOrdinal
        var payload: [(String, CodexJSON)] = [
            ("session_id", .string(threadID)), ("id", .string(threadID)), ("timestamp", "2026-10-06T00:00:00.000Z"),
            ("cwd", .string(cwd)), ("originator", "codex-tui"), ("cli_version", "0.160.1"), ("source", "cli"),
        ]
        if metaPadding > 0 {
            payload.append(("base_instructions", ["text": .string(String(repeating: "x", count: metaPadding))]))
        }
        if let historyMode {
            payload.append(("history_mode", historyMode))
        } else if dialect == .paginated {
            payload.append(("history_mode", "paginated"))
        }
        if let historyBase {
            payload.append(
                (
                    "history_base",
                    [
                        "thread_id": .string(historyBase.rolloutID),
                        "end_ordinal_exclusive": .number(historyBase.endOrdinal),
                        "end_byte_offset": .number(historyBase.endOffset),
                    ]
                ))
        }
        if let subagentHistoryStartOrdinal {
            payload.append(("subagent_history_start_ordinal", .number(subagentHistoryStartOrdinal)))
        }
        record("session_meta", .object(payload))
    }

    // MARK: Output

    var data: Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    var chatLines: [ChatLine] { JSONLLineFramer.lines(in: data) }

    /// The byte offset where the next line will start.
    var endOffset: Int { data.count }

    /// A reducer for rollout `rolloutID` fed every line in one batch.
    func reducer(rolloutID: String = "r1") -> CodexRolloutReducer {
        var reducer = CodexRolloutReducer(rolloutID: rolloutID)
        reducer.append(chatLines)
        return reducer
    }

    // MARK: Raw lines

    /// One envelope line. Paginated lines take the next ordinal unless
    /// `ordinal` overrides it (`.some(nil)` writes none).
    mutating func record(_ type: String, _ payload: CodexJSON, ordinal: UInt64?? = .none) {
        var members: [(String, CodexJSON)] = [("timestamp", "2026-10-06T00:00:00.000Z")]
        if dialect == .paginated {
            switch ordinal {
            case .none:
                members.append(("ordinal", .number(Int(nextOrdinal))))
                nextOrdinal += 1
            case .some(.some(let value)):
                members.append(("ordinal", .number(Int(value))))
                nextOrdinal = value + 1
            case .some(.none):
                break
            }
        }
        members.append(("type", .string(type)))
        members.append(("payload", payload))
        lines.append(CodexJSON.object(members).text)
    }

    /// A line written as is: a crash fragment, garbage.
    mutating func raw(_ text: String) {
        lines.append(text)
    }

    mutating func event(_ type: String, _ fields: [(String, CodexJSON)] = [], ordinal: UInt64?? = .none) {
        record("event_msg", .object([("type", .string(type))] + fields), ordinal: ordinal)
    }

    mutating func response(_ type: String, _ fields: [(String, CodexJSON)], ordinal: UInt64?? = .none) {
        record("response_item", .object([("type", .string(type))] + fields), ordinal: ordinal)
    }

    // MARK: Paginated records

    mutating func turnStarted(_ turnID: String) {
        event("task_started", [("turn_id", .string(turnID)), ("started_at", 1_791_266_142)])
    }

    mutating func turnComplete(_ turnID: String, error: String? = nil) {
        var fields: [(String, CodexJSON)] = [("turn_id", .string(turnID)), ("last_agent_message", nil)]
        if let error {
            fields.append(("error", ["message": .string(error)]))
        }
        event("task_complete", fields)
    }

    mutating func turnAborted(_ turnID: String?, reason: String = "interrupted") {
        var fields: [(String, CodexJSON)] = []
        if let turnID {
            fields.append(("turn_id", .string(turnID)))
        }
        fields.append(("reason", .string(reason)))
        event("turn_aborted", fields)
    }

    /// `item_completed` with `item` as the turn item.
    mutating func item(_ turnID: String, _ item: CodexJSON, ordinal: UInt64?? = .none) {
        event(
            "item_completed",
            [
                ("thread_id", "thread-1"), ("turn_id", .string(turnID)), ("item", item),
                ("completed_at_ms", 1_791_266_142_000),
            ], ordinal: ordinal)
    }

    mutating func userMessage(_ turnID: String, id: String, text: String, extraParts: [CodexJSON] = []) {
        let parts: [CodexJSON] = [["type": "text", "text": .string(text), "text_elements": []]] + extraParts
        item(turnID, ["type": "UserMessage", "id": .string(id), "content": .array(parts)])
    }

    mutating func agentMessage(
        _ turnID: String, id: String, text: String, phase: String = "final_answer", delivery: String? = nil,
        questions: [(title: String, options: [String])] = []
    ) {
        var members: [(String, CodexJSON)] = [
            ("type", "AgentMessage"), ("id", .string(id)),
            ("content", [["type": "Text", "text": .string(text)]]), ("phase", .string(phase)),
        ]
        if let delivery {
            members.append(("delivery", .string(delivery)))
        }
        if !questions.isEmpty {
            members.append(
                (
                    "questions",
                    .array(
                        questions.map {
                            ["title": .string($0.title), "options": .array($0.options.map { .string($0) })]
                        })
                ))
        }
        item(turnID, .object(members))
    }

    /// A `CommandExecution` item; `output` goes into `aggregated_output`
    /// after every field the row needs, as Codex orders them.
    mutating func command(
        _ turnID: String, id: String, argv: [String], status: String = "completed", exitCode: Int? = 0,
        output: String = "", parsedCommands: [CodexJSON] = []
    ) {
        var members: [(String, CodexJSON)] = [
            ("type", "CommandExecution"), ("id", .string(id)), ("command", .array(argv.map { .string($0) })),
            ("cwd", "file:///work"), ("process_id", nil), ("source", "agent"), ("status", .string(status)),
            ("parsed_cmd", .array(parsedCommands)),
        ]
        members.append(("aggregated_output", .string(output)))
        if let exitCode {
            members.append(("exit_code", .number(exitCode)))
        }
        item(turnID, .object(members))
    }

    mutating func compaction(_ turnID: String, id: String) {
        item(turnID, ["type": "ContextCompaction", "id": .string(id)])
    }

    /// The top-level `compacted` record: model context only.
    mutating func compacted(message: String) {
        record("compacted", ["message": .string(message), "replacement_history": []])
    }

    mutating func tokenUsage() {
        record("token_usage_record", ["total": 1])
    }

    // MARK: Legacy records

    mutating func legacyUser(_ text: String, kind: String? = nil) {
        var fields: [(String, CodexJSON)] = [("message", .string(text))]
        if let kind {
            fields.append(("kind", .string(kind)))
        }
        fields.append(("images", nil))
        event("user_message", fields)
    }

    mutating func legacyAgent(_ text: String) {
        event("agent_message", [("message", .string(text))])
    }

    mutating func legacyReasoning(_ text: String) {
        event("agent_reasoning", [("text", .string(text))])
    }

    mutating func legacyCall(_ name: String, callID: String, arguments: CodexJSON) {
        response(
            "function_call", [("name", .string(name)), ("arguments", .string(arguments.text)), ("call_id", .string(callID))])
    }

    mutating func legacyOutput(callID: String, output: String) {
        response("function_call_output", [("call_id", .string(callID)), ("output", .string(output))])
    }

    mutating func rolledBack(_ turns: Int) {
        event("thread_rolled_back", [("num_turns", .number(turns))])
    }
}
