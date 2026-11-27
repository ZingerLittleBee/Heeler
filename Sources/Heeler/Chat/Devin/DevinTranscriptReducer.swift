import Foundation

struct DevinTranscriptReducer: ChatTranscriptReducer {
    private var rows: [UInt64: DevinSessionPage.Row] = [:]

    mutating func append(_ lines: [ChatLine]) {
        for line in lines {
            if let row = try? JSONDecoder().decode(DevinSessionPage.Row.self, from: line.data) { rows[line.offset] = row }
        }
    }

    mutating func prepend(_ lines: [ChatLine]) { append(lines) }

    func transcript(_ context: ChatProjectionContext) -> ChatTranscript {
        var result = ChatTranscript()
        var slots: [String: Int] = [:]
        var pending: [String: ChatPendingRequest] = [:]
        var seen: Set<String> = []
        var background = DevinBackgroundWork()
        var workRows = rows
        for row in rows.values {
            for earlier in row.earlierWork ?? [] where workRows[earlier.offset] == nil {
                workRows[earlier.offset] = earlier.row
            }
        }
        for offset in workRows.keys.sorted() {
            if let row = workRows[offset] {
                background.observe(row, at: offset, date: ClaudeTranscriptProjection.date(row.timestamp))
            }
        }
        for offset in rows.keys.sorted() {
            guard let row = rows[offset], seen.insert(row.id).inserted else { continue }
            let entry = ChatEntryID("devin:" + row.id)
            result.title = row.title ?? result.title
            result.model = row.model ?? result.model
            let date = ClaudeTranscriptProjection.date(row.timestamp)
            switch row.role {
            case "user":
                result.entries.append(.init(id: entry, sourceOffset: offset, content: .user(.init(text: row.text))))
                if !row.truncated { result.recordedPrompts.append(.init(offset: offset, text: row.text, entryID: entry)) }
                result.latestPromptOffset = offset
                result.turns.append(.init(firstEntryID: entry, startedAt: date))
            case "assistant":
                if !row.text.isEmpty {
                    result.entries.append(.init(id: entry, sourceOffset: offset, content: .assistant(.init(text: row.text))))
                }
                for call in row.calls where slots[call.id] == nil {
                    let id = ChatEntryID("devin:call:" + call.id)
                    let tool = call.activity
                    slots[call.id] = result.entries.count
                    result.entries.append(.init(id: id, sourceOffset: offset, content: .tool(tool)))
                    if call.complete, let summary = call.subject {
                        pending[call.id] = .init(entryID: id, callID: call.id, kind: tool.kind, toolName: call.name,
                                                 summary: summary, questions: call.questions, fileChanges: tool.fileChanges)
                    }
                }
                if row.finish == "stop", let i = result.turns.indices.last {
                    result.turns[i].endedAt = date
                    result.turns[i].ending = .completed
                }
            case "tool":
                guard let call = row.resultFor, let i = slots[call], case .tool(var tool) = result.entries[i].content else {
                    result.needsOlderHistory = true
                    continue
                }
                pending[call] = nil
                if row.text.hasPrefix("Canceled due to user interrupt") || row.text.hasPrefix("Permission denied") || row.text.contains("Tool execution was rejected by the user") {
                    tool.status = .declined
                } else {
                    tool.status = row.success == false ? .failed : .succeeded
                }
                var preview = ChatToolPreview(capping: row.text)
                preview.isTruncated = preview.isTruncated || row.truncated
                tool.preview = preview
                tool.output = .init(offset: offset, length: row.text.utf8.count, callID: call)
                result.entries[i].content = .tool(tool)
            default: continue
            }
        }
        result.backgroundWork = background.items
        result.pendingRequests = pending.values.sorted { $0.entryID.rawValue < $1.entryID.rawValue }
        return result
    }

    func output(of line: ChatLine, for tool: ChatToolActivity) -> ChatToolOutput? {
        guard let row = try? JSONDecoder().decode(DevinSessionPage.Row.self, from: line.data),
              row.role == "tool", let call = tool.callID, row.resultFor == call else { return nil }
        var preview = ChatToolPreview(capping: row.text)
        preview.isTruncated = preview.isTruncated || row.truncated
        return .preview(preview)
    }
}

extension DevinSessionPage.Call {
    var questions: [ChatQuestion] {
        (arguments.questions ?? []).map { question in
            ChatQuestion(header: question.header, text: question.question,
                         options: question.options.map { .init(label: $0.label, detail: $0.description) })
        }
    }

    var subject: String? {
        if name == "exit_plan_mode" { return arguments.plan }
        return arguments.file_path ?? arguments.path ?? arguments.command ?? questions.first?.text ?? arguments.title
    }

    var activity: ChatToolActivity {
        let kind: ChatToolActivity.Kind = switch name {
        case "exec", "bash": .command
        case "write": .fileWrite
        case "edit": .fileEdit
        case "read": .fileRead
        case "grep", "glob": .search
        case "run_subagent", "read_subagent": .agent
        case "ask_user", "ask_user_question": .question
        default: name.hasPrefix("mcp__") ? .mcp : .other
        }
        var tool = ChatToolActivity(kind: kind, name: name, title: subject ?? name, status: .running, callID: id)
        if complete, let file = arguments.file_path, name == "write", let text = arguments.content {
            tool.fileChanges = .init(files: [.allAdded(path: file, content: text, kind: .written)])
        } else if complete, let file = arguments.file_path, name == "edit",
                  let old = arguments.old_string, let new = arguments.new_string {
            let before = old.components(separatedBy: "\n")
            let after = new.components(separatedBy: "\n")
            let hunk = ChatDiffHunk(oldStart: 1, oldLines: before.count, newStart: 1, newLines: after.count,
                                    lines: before.map { "-" + $0 } + after.map { "+" + $0 })
            tool.fileChanges = .init(files: [.init(path: file, kind: .updated, recorded: [hunk])])
        }
        return tool
    }
}
