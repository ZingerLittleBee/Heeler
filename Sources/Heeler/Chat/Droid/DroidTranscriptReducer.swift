import Foundation

/// Factory's v2 session file wraps Anthropic-style content blocks in message
/// records. Tool replies have the user role too. Only a visible user message
/// opens a turn or acknowledges a Composer send.
struct DroidTranscriptReducer: ChatTranscriptReducer {
    private struct Record: Decodable {
        var type: String
        var id, title, cwd, timestamp, turnId, reason: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var role: String
        var blocks: [ClaudeContentBlock]
        var model, effort: String?

        enum CodingKeys: String, CodingKey {
            case role, visibility, hookEventName, content, modelId, reasoningEffort
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            role = try fields.decode(String.self, forKey: .role)
            // Startup hooks and injected context are separate user-role records.
            guard role == "user" || role == "assistant",
                  try fields.decodeIfPresent(String.self, forKey: .visibility) == nil,
                  !fields.contains(.hookEventName) else {
                blocks = []
                return
            }
            blocks = ClaudeContentBlock.decode(from: fields, forKey: .content)
            model = try? fields.decode(String.self, forKey: .modelId)
            effort = try? fields.decode(String.self, forKey: .reasoningEffort)
        }

        var prompt: ChatUserMessage? {
            guard role == "user" else { return nil }
            var parts: [String] = []
            var images = 0
            for block in blocks {
                switch block {
                case .toolResult: return nil
                case .text(let text) where !text.isEmpty: parts.append(text)
                case .image: images += 1
                default: continue
                }
            }
            guard !parts.isEmpty || images > 0 else { return nil }
            return .init(text: parts.joined(separator: "\n"), imageCount: images)
        }
    }

    private var records: [UInt64: (record: Record, length: Int)] = [:]
    private var title: String?
    private var directory: String?

    init(firstLine: ChatLine? = nil) {
        if let firstLine { append([firstLine]) }
    }

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            guard let record = try? JSONDecoder().decode(Record.self, from: line.data) else { continue }
            switch record.type {
            case "session_start" where line.offset == 0:
                title = record.title
                directory = record.cwd
            case "message" where record.message?.blocks.isEmpty == false,
                 "agent_turn_outcome" where record.turnId != nil:
                records[line.offset] = (record, line.length)
            default: continue
            }
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        var transcript = ChatTranscript(title: title)
        var turns: [String: Int] = [:]
        var calls: [String: (index: Int, turn: String?)] = [:]
        var currentTurn: String?
        var missingCall = false
        for offset in records.keys.sorted() {
            guard let (record, length) = records[offset] else { continue }
            if record.type == "agent_turn_outcome" {
                if let turn = record.turnId, let index = turns[turn] {
                    switch record.reason {
                    case "completed": transcript.turns[index].ending = .completed
                    case "cancelled": transcript.turns[index].ending = .interrupted
                    case "error", "failed": transcript.turns[index].ending = .failed
                    default: break
                    }
                }
                continue
            }
            guard let message = record.message, let id = record.id else { continue }
            if let prompt = message.prompt {
                let userID = ChatEntryID("droid:" + id)
                currentTurn = id
                turns[id] = transcript.turns.count
                transcript.turns.append(.init(firstEntryID: userID, startedAt: ClaudeTranscriptProjection.date(record.timestamp)))
                transcript.entries.append(.init(id: userID, sourceOffset: offset, content: .user(prompt)))
                transcript.recordedPrompts.append(.init(offset: offset, text: prompt.text, entryID: userID))
                transcript.latestPromptOffset = offset
            } else if message.role == "assistant" {
                transcript.model = message.model ?? transcript.model
                transcript.effort = message.effort ?? transcript.effort
            }
            for (index, block) in message.blocks.enumerated() {
                let content: ChatEntry.Content
                switch (message.role, block) {
                case ("assistant", .text(let text)) where !text.isEmpty:
                    content = .assistant(.init(text: text))
                case ("assistant", .thinking(let text)) where !text.isEmpty:
                    content = .reasoning(.init(text: text))
                case ("assistant", .toolUse(let use)) where !use.id.isEmpty && !use.name.isEmpty:
                    let summary = Self.summary(use, directory: directory)
                    content = .tool(.init(kind: summary.kind, name: use.name, title: summary.title,
                                          subtitle: summary.subtitle, status: .running, callID: use.id))
                    calls[use.id] = (transcript.entries.count, currentTurn)
                case ("user", .toolResult(let result)):
                    guard let slot = calls.removeValue(forKey: result.toolUseID)?.index,
                          case .tool(var tool) = transcript.entries[slot].content else {
                        missingCall = true
                        continue
                    }
                    tool.status = result.isError ? .failed : .succeeded
                    tool.preview = result.content
                    tool.output = .init(offset: offset, length: length, callID: result.toolUseID)
                    transcript.entries[slot].content = .tool(tool)
                    continue
                default: continue
                }
                transcript.entries.append(.init(id: ChatEntryID("droid:\(id):\(index)"), sourceOffset: offset, content: content))
            }
        }
        for (index, turn) in calls.values {
            guard case .tool(var tool) = transcript.entries[index].content else { continue }
            let ending = turn.flatMap { turns[$0] }.flatMap { transcript.turns[$0].ending }
            if ending == .interrupted { tool.status = .interrupted }
            else if ending != nil || turn != currentTurn || context.activity == .idle { tool.status = .noResult }
            else if context.activity == .blocked { tool.status = .awaitingApproval }
            transcript.entries[index].content = .tool(tool)
        }
        transcript.needsOlderHistory = context.windowStart > 0 && (transcript.turns.isEmpty || missingCall)
        return transcript
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let call = tool.callID, let record = try? JSONDecoder().decode(Record.self, from: line.data),
              record.type == "message", let message = record.message, message.role == "user" else { return nil }
        for case .toolResult(let result) in message.blocks where result.toolUseID == call { return .preview(result.content) }
        return nil
    }

    private static func summary(_ use: ClaudeToolUse, directory: String?) -> ClaudeToolSummary {
        let name: String
        switch use.name {
        case "Execute": name = "Bash"
        case "Create": name = "Write"
        default: name = use.name
        }
        return ClaudeToolSummary(.init(id: use.id, name: name, input: use.input), directory: directory)
    }
}
