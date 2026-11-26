import Foundation

struct AmpTranscriptReducer: ChatTranscriptReducer {
    private var rows: [UInt64: AmpChatPage.Row] = [:]

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if let row = try? JSONDecoder().decode(AmpChatPage.Row.self, from: line.data) { rows[line.offset] = row }
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        var transcript = ChatTranscript()
        var calls: [String: Int] = [:]
        var missingToolCall = false
        for offset in rows.keys.sorted() {
            guard let row = rows[offset] else { continue }
            var openedTurn = false
            for (index, block) in row.blocks.enumerated() {
                let id = ChatEntryID("amp:\(row.id):\(index)")
                let value = block.text ?? ""
                let entry: ChatEntry.Content
                switch (block.type, row.role) {
                case ("text", "user"):
                    guard !value.isEmpty else { continue }
                    entry = .user(ChatUserMessage(text: value))
                    transcript.latestPromptOffset = offset
                    transcript.recordedPrompts.append(.init(offset: offset, text: value, entryID: id))
                    if transcript.title == nil { transcript.title = String(value.prefix(120)) }
                    if !openedTurn {
                        let date = row.createdAt.flatMap {
                            (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                                ?? (try? Date($0, strategy: .iso8601))
                        }
                        transcript.turns.append(ChatTurn(firstEntryID: id, startedAt: date))
                        openedTurn = true
                    }
                case ("text", "assistant"): entry = .assistant(.init(text: value))
                case ("text", "info"): entry = .notice(.init(kind: .system, title: value))
                case ("thinking", _): entry = .reasoning(.init(text: value))
                case ("tool_use", _):
                    guard let call = block.call, let name = block.name else { continue }
                    calls[call] = transcript.entries.count
                    entry = .tool(.init(kind: .other, name: name, title: name, subtitle: value,
                                        status: .running, callID: call))
                case ("tool_result", _):
                    guard let call = block.call else { continue }
                    guard let position = calls[call], case .tool(var tool) = transcript.entries[position].content else {
                        missingToolCall = true
                        continue
                    }
                    switch block.status {
                    case "done": tool.status = .succeeded
                    case "error": tool.status = .failed
                    case "cancelled": tool.status = .interrupted
                    default: tool.status = .running
                    }
                    tool.preview = .init(capping: value)
                    transcript.entries[position].content = .tool(tool)
                    continue
                default: continue
                }
                transcript.entries.append(.init(id: id, sourceOffset: offset, content: entry))
            }
            if row.role == "assistant", let end = row.end, end != "tool_use", !transcript.turns.isEmpty {
                transcript.turns[transcript.turns.count - 1].ending = end == "cancelled" ? .interrupted : .completed
            }
        }
        transcript.needsOlderHistory = context.windowStart != 0 && (transcript.turns.isEmpty || missingToolCall)
        return transcript
    }
}
