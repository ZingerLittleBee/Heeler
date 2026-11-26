import Foundation

struct AmpTranscriptReducer: ChatTranscriptReducer {
    static let revision = 2
    private var rows: [UInt64: AmpChatPage.Row] = [:]

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            guard var row = try? JSONDecoder().decode(AmpChatPage.Row.self, from: line.data) else { continue }
            if row.role == "assistant" {
                let start = row.blocks.lastIndex(where: { $0.type != "text" }).map { $0 + 1 } ?? 0
                let tail = start..<row.blocks.endIndex
                if let body = Self.replyBody(tail.map { row.blocks[$0].text ?? "" }) {
                    for (index, text) in zip(tail, body) { row.blocks[index].text = text }
                }
            }
            rows[line.offset] = row
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
                case ("text", "assistant"):
                    guard !value.isEmpty else { continue }
                    entry = .assistant(.init(text: value))
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
                    tool.preview = block.outputPreview
                    tool.output = .init(offset: offset, length: 0, callID: call)
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

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let call = tool.callID, let row = try? JSONDecoder().decode(AmpChatPage.Row.self, from: line.data),
            let block = row.blocks.first(where: { $0.type == "tool_result" && $0.call == call })
        else { return nil }
        return .preview(block.outputPreview)
    }

    /// Amp appends suggestions as a standalone HTML block at the end of its
    /// answer. Keep each visible part at its original block index.
    private static func replyBody(_ parts: [String]) -> [String]? {
        let opening = "<suggested-replies>"
        let closing = "</suggested-replies>"
        guard parts.contains(where: { $0.contains(opening) }) else { return nil }
        let separator = "\n\n"
        let text = parts.joined(separator: separator)
        guard let marker = text.range(of: opening, options: .backwards) else { return nil }
        let prefix = text[..<marker.lowerBound]
        let trailer = text[marker.upperBound...]
        guard prefix.last?.isNewline != false, trailer.first?.isNewline != false else { return nil }
        if let end = trailer.range(of: closing) {
            guard trailer[..<end.lowerBound].last?.isNewline == true,
                  trailer[end.upperBound...].allSatisfy(\.isWhitespace) else { return nil }
        }
        // Markdown examples can end with the same literal line, including
        // an unclosed code fence while the assistant is still streaming.
        guard let markdown = try? AttributedString(markdown: prefix + "\n" + opening),
              let run = markdown.runs.last, run.inlinePresentationIntent?.contains(.blockHTML) == true,
              String(markdown[run.range].characters).trimmingCharacters(in: .newlines) == opening
        else { return nil }
        let last = prefix.lastIndex(where: { !$0.isWhitespace })
        var remaining = last.map { text.distance(from: text.startIndex, to: text.index(after: $0)) } ?? 0
        return parts.map { part in
            let visible = String(part.prefix(remaining))
            remaining = max(0, remaining - part.count - separator.count)
            return visible
        }
    }

    /// Saved Chats can be opened offline. Their source offsets still group
    /// the text parts of each Amp message even when the terminal is gone.
    static func migrateCache(_ saved: ChatCacheDocument) -> ChatCacheDocument? {
        guard saved.key.program == .amp, saved.adapterRevision == 1 else { return nil }
        var document = saved
        var hidden = Set<Int>()
        let rows = Dictionary(grouping: saved.entries.indices, by: { saved.entries[$0].sourceOffset })
        for indices in rows.values {
            var parts: [String] = []
            for index in indices.reversed() {
                guard case .assistant(let message) = saved.entries[index].content else { break }
                parts.append(message.text)
            }
            guard let body = replyBody(parts.reversed()) else { continue }
            for (index, text) in zip(indices.suffix(parts.count), body) {
                if text.isEmpty { hidden.insert(index) }
                else { document.entries[index].content = .assistant(.init(text: text)) }
            }
        }
        if !hidden.isEmpty {
            document.entries = document.entries.enumerated().compactMap { hidden.contains($0.offset) ? nil : $0.element }
        }
        document.adapterRevision = 2
        return document
    }
}
