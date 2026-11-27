import Foundation

/// Factory's v2 session file wraps Anthropic-style content blocks in message
/// records. Tool replies have the user role too. Only a visible user message
/// opens a turn or acknowledges a Composer send.
struct DroidTranscriptReducer: ChatTranscriptReducer {
    private struct Record: Decodable {
        var type: String
        var id, parentId, title, cwd, timestamp, turnId, reason: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var role: String
        var blocks: [ClaudeContentBlock]
        var model, effort: String?
        var systemNotice: String?
        var background: DroidBackgroundEvent?
        var scriptWork: DroidScriptBackground.Record?
        var arguments: [String: Arguments] = [:]

        struct Arguments: Decodable {
            let type: String
            var id: String?
            var text: String?
            var input: Input?

            struct Input: Decodable {
                var questionnaire, summary, title, plan: String?
                var file_path, content, old_str, new_str: String?
                var fireAndForget: Bool?

                func proposedChange(for tool: String) -> ChatFileChanges? {
                    guard let path = file_path else { return nil }
                    if tool == "Create", let content {
                        return .init(files: [.allAdded(path: path, content: content, kind: .created)])
                    }
                    guard tool == "Edit", let old_str, let new_str else { return nil }
                    let before = old_str.components(separatedBy: "\n")
                    let after = new_str.components(separatedBy: "\n")
                    let lines = before.map { "-" + $0 } + after.map { "+" + $0 }
                    let hunk = ChatDiffHunk(oldStart: 1, oldLines: before.count, newStart: 1,
                                            newLines: after.count, lines: lines)
                    return .init(files: [.init(path: path, kind: .updated, recorded: [hunk])])
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, visibility, hookEventName, content, modelId, reasoningEffort, systemNotice
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            role = try fields.decode(String.self, forKey: .role)
            let visibility = try fields.decodeIfPresent(String.self, forKey: .visibility)
            if role == "user", (try? fields.decode(Bool.self, forKey: .systemNotice)) == true,
               !fields.contains(.hookEventName), visibility == "user_only" || visibility == nil {
                let parts = try fields.decode([Arguments].self, forKey: .content)
                let text = parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
                if !text.isEmpty { systemNotice = text }
                blocks = []
                return
            }
            if role == "user", visibility == "llm_only",
               !fields.contains(.hookEventName), let notes = try? fields.decode([Arguments].self, forKey: .content),
               notes.count == 1, notes[0].type == "text", let note = notes[0].text {
                background = DroidBackgroundEvent(note)
            }
            if visibility == "user_only", !fields.contains(.hookEventName) {
                scriptWork = DroidScriptBackground.Record(decoder, role: role, visibility: visibility)
            }
            // Startup hooks and injected context are separate user-role records.
            guard role == "user" || role == "assistant",
                  visibility == nil,
                  !fields.contains(.hookEventName) else {
                blocks = []
                return
            }
            blocks = ClaudeContentBlock.decode(from: fields, forKey: .content)
            scriptWork = DroidScriptBackground.Record(decoder, role: role, visibility: nil, blocks: blocks)
            if role == "assistant", let raw = try? fields.decode([Arguments].self, forKey: .content) {
                for item in raw where item.type == "tool_use" {
                    if let id = item.id { arguments[id] = item }
                }
            }
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
            case "message" where record.message?.blocks.isEmpty == false || record.message?.background != nil || record.message?.systemNotice != nil || record.message?.scriptWork != nil,
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
        var work: [ChatBackgroundWorkItem] = []
        var launches: [String: (use: ClaudeToolUse, offset: UInt64, date: Date?)] = [:]
        var pending: [String: ChatPendingRequest] = [:]
        var seenMessages: Set<String> = []
        var seenCalls: Set<String> = []
        var scripts = DroidScriptBackground()
        var currentTurn: String?
        var missingCall = false
        for offset in records.keys.sorted() {
            guard let (record, length) = records[offset] else { continue }
            if record.type == "agent_turn_outcome" {
                if let turn = record.turnId, let index = turns[turn] {
                    switch record.reason {
                    case "completed": transcript.turns[index].ending = .completed
                    case "cancelled": transcript.turns[index].ending = .interrupted
                    case "error", "failed", "model_provider_unreachable": transcript.turns[index].ending = .failed
                    default: break
                    }
                }
                continue
            }
            guard let message = record.message, let id = record.id, seenMessages.insert(id).inserted else { continue }
            if let script = message.scriptWork {
                if let item = scripts.read(script, messageID: id, parentID: record.parentId, offset: offset,
                                           date: ClaudeTranscriptProjection.date(record.timestamp), missingCall: &missingCall) {
                    work.append(item)
                }
            }
            if let notice = message.systemNotice {
                transcript.entries.append(.init(id: .init("droid:" + id), sourceOffset: offset,
                                                content: .notice(.init(kind: .system, title: notice))))
                continue
            }
            if let event = message.background {
                let index = work.firstIndex { item in
                    switch event.target {
                    case .call(let id):
                        item.kind == .command && item.id == id && event.matchesOutputFile(of: item)
                    case .task(let id): item.kind == .subagent && item.taskID == id
                    }
                }
                if let index, work[index].endOffset == nil {
                    work[index].state = event.state
                    work[index].endOffset = offset
                    work[index].endedAt = ClaudeTranscriptProjection.date(record.timestamp)
                    work[index].reportedOutput = event.output
                    work[index].exitCode = event.exitCode
                } else if index == nil { missingCall = true }
                continue
            }
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
                    guard seenCalls.insert(use.id).inserted else { continue }
                    let arguments = message.arguments[use.id]?.input
                    let summary = Self.summary(use, directory: directory)
                    let entryID = ChatEntryID("droid:\(id):\(index)")
                    let requestText: String? = switch use.name {
                    case "Execute": use.input.command
                    case "Create", "Edit", "Update": use.input.filePath ?? arguments?.file_path
                    case "AskUser": arguments?.questionnaire
                    case "ExitSpecMode": arguments?.plan
                    default: nil
                    }
                    if let requestText {
                        pending[use.id] = .init(entryID: entryID, callID: use.id, kind: summary.kind, toolName: use.name,
                                                summary: requestText, detail: arguments?.summary ?? arguments?.title,
                                                fileChanges: arguments?.proposedChange(for: use.name))
                    }
                    if (use.name == "Execute" && arguments?.fireAndForget == true) || use.name == "Task" {
                        var launch = use
                        launch.input.description = arguments?.summary ?? use.input.description
                        launches[use.id] = (launch, offset, ClaudeTranscriptProjection.date(record.timestamp))
                    }
                    content = .tool(.init(kind: summary.kind, name: use.name, title: summary.title,
                                          subtitle: summary.subtitle, status: .running, callID: use.id))
                    calls[use.id] = (transcript.entries.count, currentTurn)
                case ("user", .toolResult(let result)):
                    guard let slot = calls.removeValue(forKey: result.toolUseID)?.index,
                          case .tool(var tool) = transcript.entries[slot].content else {
                        missingCall = true
                        continue
                    }
                    pending.removeValue(forKey: result.toolUseID)
                    if let launch = launches.removeValue(forKey: result.toolUseID), !result.isError,
                       let item = DroidBackgroundEvent.launched(launch.use, response: result.content.text,
                                                               offset: launch.offset, at: launch.date) {
                        work.append(item)
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
        transcript.backgroundWork = work
        transcript.pendingRequests = pending.values.filter { request in
            guard let call = request.callID, let slot = calls[call], let turn = slot.turn, turn == currentTurn,
                  turns[turn].map({ transcript.turns[$0].ending == nil }) == true else { return false }
            return true
        }.sorted { (calls[$0.callID ?? ""]?.index ?? 0) < (calls[$1.callID ?? ""]?.index ?? 0) }
        transcript.needsOlderHistory = context.windowStart > 0 && (transcript.turns.isEmpty || missingCall)
        return transcript
    }

    /// Read through the current end from the exact call the card displayed.
    /// An incomplete or too large window cannot authorize terminal input.
    static func stillOpen(call: String, at offset: UInt64, file: String, files: ChatHostFiles) async throws -> Bool {
        let chunk = try await files.read(.init(path: file, offset: offset, maxBytes: 256 << 10))
        guard let length = chunk.length, length == offset + UInt64(chunk.data.count),
              chunk.data.last == 10 else { return false }
        let lines = JSONLLineFramer.lines(in: chunk.data, prefixCap: 256 << 10)
        guard let first = lines.first, let record = try? JSONDecoder().decode(Record.self, from: first.data),
              record.message?.role == "assistant", record.message?.blocks.contains(where: {
                  if case .toolUse(let use) = $0 { return use.id == call }
                  return false
              }) == true else { return false }
        for line in lines.dropFirst() {
            guard let later = try? JSONDecoder().decode(Record.self, from: line.data) else { return false }
            if later.type == "agent_turn_outcome" || later.message?.prompt != nil { return false }
            if later.message?.blocks.contains(where: {
                if case .toolResult(let result) = $0 { return result.toolUseID == call }
                return false
            }) == true { return false }
        }
        return true
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
