import Foundation

/// One line of a Grok Build session's `updates.jsonl`, decoded down to what
/// Chat projects. Each line is an ACP `session/update`, or Grok's own
/// `_x.ai/session/update`: `params.update.sessionUpdate` names its kind, and
/// `params._meta` carries its event id and Grok's clock. Neither the line nor
/// an image's data is kept.
struct GrokUpdateRecord: Sendable {
    /// An `eventId`, `<session>-<n>`: the session that first wrote the
    /// record (a fork keeps its parent's) and its number there. Only split
    /// prompts compare it; Grok numbers events again after a rewind, so it
    /// never identifies a record.
    struct EventNumber: Equatable, Sendable {
        let prefix: String
        let number: Int

        init?(_ eventID: String) {
            guard let dash = eventID.lastIndex(of: "-"), let number = Int(eventID[eventID.index(after: dash)...])
            else { return nil }
            prefix = String(eventID[..<dash])
            self.number = number
        }
    }

    /// One content block of a prompt.
    struct UserChunk: Sendable {
        /// `text`, `image` or another ACP block type.
        let contentType: String?
        let text: String?
        /// What Grok shows instead of `text`: a skill's `/name args`, or an
        /// interjection's own words.
        let displayText: String?
        let displayAsSkill: Bool
        /// The command a `!cmd` typed in Grok's shell mode ran.
        let bashCommand: String?
        /// Counts submitted prompts from 0. Nil for an interjection and a
        /// shell-mode command, and when a cut line lost it.
        let promptIndex: Int?
        /// A prompt Grok wrote for itself (`hideFromScrollback`): a task,
        /// subagent or notification wake-up.
        let isHidden: Bool
    }

    /// A message or thought block, or one part of it.
    struct AgentChunk: Sendable {
        let text: String?
        /// Consecutive within one block.
        let chunkID: Int?
    }

    struct TurnCompleted: Sendable {
        let stopReason: String?
        /// The error's text when `stopReason` is `error`.
        let agentResult: String?
        let elapsedMilliseconds: Int64?
        /// What cancelled the turn (`params._meta`).
        let cancelTrigger: String?
        let cancellationCategory: String?
    }

    enum Retry: Sendable {
        /// Grok tries the request again.
        case retrying
        case exhausted(attempts: Int?, reason: String?)
        /// An error Grok does not retry, such as an expired sign-in.
        case failed(message: String?)
    }

    /// A command or monitor Grok runs in the background
    /// (`task_backgrounded`).
    struct TaskBackgrounded: Sendable {
        let callID: String?
        let taskID: String?
    }

    /// A background command or monitor that ended (`task_completed`).
    struct TaskCompleted: Sendable {
        let taskID: String?
        /// `bash` for a command, `monitor` for a monitor.
        let taskKind: String?
        /// What the user saw run: `display_command`, else `command`.
        let command: String?
        let exitCode: Int?
        let signal: String?
        /// Grok stopped it on request (`explicitly_killed`).
        let wasKilled: Bool
        /// The start of its output.
        let preview: ChatToolPreview?
    }

    struct SubagentSpawned: Sendable {
        let subagentID: String?
        let subagentType: String?
        let description: String?
    }

    struct SubagentFinished: Sendable {
        let subagentID: String?
        /// `completed`, `failed` or `cancelled`.
        let status: String?
        let error: String?
        let toolCalls: Int?
        let turns: Int?
        let durationMilliseconds: Int64?
        /// The start of the subagent's report.
        let preview: ChatToolPreview?
    }

    enum Kind: Sendable {
        case userChunk(UserChunk)
        case agentMessage(AgentChunk)
        case agentThought(AgentChunk)
        /// Nil when the record names no call.
        case toolCall(Tool?)
        case toolUpdate(Tool?)
        case turnCompleted(TurnCompleted)
        case rewind(targetPromptIndex: Int?)
        case compactionCheckpoint
        case compactionCancelled
        case compactionFailed(error: String?)
        case retry(Retry)
        case imageDropped(notes: [String])
        case taskBackgrounded(TaskBackgrounded)
        case taskCompleted(TaskCompleted)
        case subagentSpawned(SubagentSpawned)
        case subagentFinished(SubagentFinished)
        /// A kind Chat shows nothing for.
        case skipped(String)
        /// A kind this build does not know.
        case unknown(String)
    }

    let offset: UInt64
    let length: Int
    /// The line was longer than the reader keeps. Fields after the cut are
    /// missing, `params._meta` among them: it follows the content.
    let isTruncated: Bool
    /// Seconds, on the Host's clock.
    let timestamp: Int?
    let agentTimestampMs: Int64?
    /// When the turn an agent record belongs to started.
    let turnStartMs: Int64?
    /// `params._meta.promptId`, which agent records carry.
    let promptID: String?
    let eventNumber: EventNumber?
    let kind: Kind

    static func decode(_ line: ChatLine) -> GrokUpdateRecord? {
        // A cut line still parses up to its last complete value, which
        // keeps the kind and the fields before a long text or output.
        let data = line.isTruncated ? CodexJSONPrefix.repaired(line.data) : line.data
        guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let update = value["params"]?["update"], let type = update["sessionUpdate"]?.stringValue
        else { return nil }
        let meta = value["params"]?["_meta"]
        return GrokUpdateRecord(
            offset: line.offset, length: line.length, isTruncated: line.isTruncated,
            timestamp: integer(value["timestamp"]).flatMap { Int(exactly: $0) },
            agentTimestampMs: integer(meta?["agentTimestampMs"]), turnStartMs: integer(meta?["turnStartMs"]),
            promptID: meta?["promptId"]?.stringValue, eventNumber: meta?["eventId"]?.stringValue.flatMap(EventNumber.init),
            kind: kind(type, update: update, meta: meta))
    }

    /// Kinds that show nothing: hooks, Grok's bookkeeping, and `plan`, whose
    /// snapshot the `todo_write` row covers.
    private static let skippedKinds: Set<String> = [
        "plan", "hook_execution", "background_tasks", "session_recap", "response_started", "turn_usage",
        "model_changed", "served_model", "available_commands_update", "current_mode_update", "image_compressed",
        "session_start", "auto_compact_started", "auto_compact_completed",
    ]

    private static func kind(_ type: String, update: JSONValue, meta: JSONValue?) -> Kind {
        switch type {
        case "user_message_chunk":
            let content = update["content"]
            return .userChunk(
                UserChunk(
                    contentType: content?["type"]?.stringValue, text: content?["text"]?.stringValue,
                    displayText: content?["_meta"]?["displayText"]?.stringValue,
                    displayAsSkill: content?["_meta"]?["displayAsSkill"] == .bool(true),
                    bashCommand: content?["_meta"]?["bash_command"]?.stringValue,
                    promptIndex: integer(update["_meta"]?["promptIndex"]).flatMap { Int(exactly: $0) },
                    isHidden: update["_meta"]?["hideFromScrollback"] == .bool(true)))
        case "agent_message_chunk":
            return .agentMessage(agentChunk(update, meta))
        case "agent_thought_chunk":
            return .agentThought(agentChunk(update, meta))
        case "tool_call":
            return .toolCall(Tool(update))
        case "tool_call_update":
            return .toolUpdate(Tool(update))
        case "turn_completed":
            return .turnCompleted(
                TurnCompleted(
                    stopReason: update["stop_reason"]?.stringValue, agentResult: update["agent_result"]?.stringValue,
                    elapsedMilliseconds: integer(update["elapsed_ms"]),
                    cancelTrigger: meta?["cancelTrigger"]?.stringValue,
                    cancellationCategory: meta?["cancellationCategory"]?.stringValue))
        case "rewind_marker":
            return .rewind(targetPromptIndex: integer(update["target_prompt_index"]).flatMap { Int(exactly: $0) })
        case "compaction_checkpoint":
            return .compactionCheckpoint
        case "auto_compact_cancelled":
            return .compactionCancelled
        case "auto_compact_failed":
            return .compactionFailed(error: update["error"]?.stringValue)
        case "retry_state":
            switch update["type"]?.stringValue {
            case "exhausted":
                return .retry(
                    .exhausted(
                        attempts: integer(update["attempts"]).flatMap { Int(exactly: $0) },
                        reason: update["reason"]?.stringValue))
            case "failed":
                return .retry(.failed(message: update["message"]?.stringValue))
            default:
                return .retry(.retrying)
            }
        case "image_dropped":
            guard case .array(let notes) = update["notes"] else { return .imageDropped(notes: []) }
            return .imageDropped(notes: notes.compactMap(\.stringValue))
        case "task_backgrounded":
            return .taskBackgrounded(
                TaskBackgrounded(
                    callID: update["tool_call_id"]?.stringValue, taskID: update["task_id"]?.stringValue))
        case "task_completed":
            let task = update["task_snapshot"]
            return .taskCompleted(
                TaskCompleted(
                    taskID: task?["task_id"]?.stringValue, taskKind: task?["kind"]?.stringValue,
                    command: task?["display_command"]?.stringValue ?? task?["command"]?.stringValue,
                    exitCode: integer(task?["exit_code"]).flatMap { Int(exactly: $0) },
                    signal: task?["signal"]?.stringValue, wasKilled: task?["explicitly_killed"] == .bool(true),
                    preview: preview(task?["output"]?.stringValue)))
        case "subagent_spawned":
            return .subagentSpawned(
                SubagentSpawned(
                    subagentID: update["subagent_id"]?.stringValue, subagentType: update["subagent_type"]?.stringValue,
                    description: update["description"]?.stringValue))
        case "subagent_finished":
            return .subagentFinished(
                SubagentFinished(
                    subagentID: update["subagent_id"]?.stringValue, status: update["status"]?.stringValue,
                    error: update["error"]?.stringValue,
                    toolCalls: integer(update["tool_calls"]).flatMap { Int(exactly: $0) },
                    turns: integer(update["turns"]).flatMap { Int(exactly: $0) },
                    durationMilliseconds: integer(update["duration_ms"]),
                    preview: preview(update["output"]?.stringValue)))
        case _ where skippedKinds.contains(type) || type.hasPrefix("memory_dream_"):
            return .skipped(type)
        default:
            return .unknown(type)
        }
    }

    private static func agentChunk(_ update: JSONValue, _ meta: JSONValue?) -> AgentChunk {
        AgentChunk(
            text: update["content"]?["text"]?.stringValue,
            chunkID: integer(meta?["chunkId"]).flatMap { Int(exactly: $0) })
    }

    /// A whole number, which JSON decodes as a double.
    fileprivate static func integer(_ value: JSONValue?) -> Int64? {
        guard case .number(let number)? = value else { return nil }
        return Int64(exactly: number)
    }

    /// `text` capped like a row's output, without the line breaks that end
    /// it: a command's output ends with its last line's, and a cap can fall
    /// right after a line's, either of which the row would show as an empty
    /// line. Nil when nothing is left to show.
    fileprivate static func preview(_ text: String?, imageCount: Int = 0) -> ChatToolPreview? {
        guard let text = text?.withoutTrailingLineBreaks, !text.isEmpty || imageCount > 0 else { return nil }
        var preview = ChatToolPreview(capping: text, imageCount: imageCount)
        preview.text = preview.text.withoutTrailingLineBreaks
        return preview
    }
}

extension StringProtocol {
    /// The text without the `\n` and `\r` that end it.
    var withoutTrailingLineBreaks: String {
        var scalars = String(self).unicodeScalars
        while let last = scalars.last, last == "\n" || last == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}

// MARK: Tools

extension GrokUpdateRecord {
    /// One record of a tool call. Grok writes three for each `toolCallId`:
    /// the call, whose `title` is the tool's name; the input it holds back
    /// until the call runs, with a readable `title`, `locations` and
    /// `rawInput.variant`; and the result, with `status`, `rawOutput` and,
    /// for a call that never ran, `_meta.toolNotRun`.
    struct Tool: Sendable {
        let callID: String
        /// Grok's name for the tool (`_meta["x.ai/tool"].name`):
        /// `run_terminal_command`, `search_replace`.
        let name: String?
        /// Grok's own kind for the tool: `execute`, `task`, `plan`.
        let toolKind: String?
        /// The tool's label: `Run Command`.
        let label: String?
        /// The ACP kind: `execute`, `read`, `edit`, `other`.
        let kind: String?
        let title: String?
        /// The first path the record locates.
        let location: String?
        let input: Input?
        /// `in_progress`, `completed` or `failed`.
        let status: String?
        /// Why the call never ran: `rejected` or `cancelled`.
        let notRun: String?
        /// Nil for a record that is not the call's result.
        let output: Output?
        /// The diff items in `content`, or a result's `EditsApplied` when its
        /// content holds none.
        let fileChanges: ChatFileChanges?

        init?(_ update: JSONValue) {
            guard let callID = update["toolCallId"]?.stringValue, !callID.isEmpty else { return nil }
            let meta = update["_meta"]
            let tool = meta?["x.ai/tool"]
            self.callID = callID
            name = tool?["name"]?.stringValue
            toolKind = tool?["kind"]?.stringValue
            label = tool?["label"]?.stringValue
            kind = update["kind"]?.stringValue
            title = update["title"]?.stringValue
            if case .array(let locations) = update["locations"] {
                location = locations.lazy.compactMap { $0["path"]?.stringValue }.first
            } else {
                location = nil
            }
            input = update["rawInput"].map { Input($0, meta: meta) }
            status = update["status"]?.stringValue
            notRun = meta?["toolNotRun"]?.stringValue
            output = Output(update, status: status, notRun: notRun)
            var changes = GrokFileChanges.changes(content: update["content"])
            if changes == nil, output != nil, let applied = update["rawOutput"]?["EditsApplied"] {
                changes = GrokFileChanges.changes(applied: applied)
            }
            fileChanges = changes
        }

        /// What a call's `rawInput` names. The call holds part of it, the
        /// input update all of it.
        struct Input: Sendable {
            struct Todo: Equatable, Sendable {
                let content: String
                /// `pending`, `in_progress` or `completed`.
                let status: String?
            }

            /// The input update's name for the tool's input: `Bash`,
            /// `SearchReplace`, `Task`.
            var variant: String?
            var command: String?
            var description: String?
            /// The file a read, edit or write names.
            var filePath: String?
            /// The directory a listing or search names.
            var path: String?
            var pattern: String?
            var query: String?
            var url: String?
            /// An MCP tool's `<server>__<tool>`.
            var toolName: String?
            var subagentType: String?
            /// The call starts its command or subagent in the background.
            var isBackground = false
            var questions: [ChatQuestion] = []
            var todos: [Todo] = []

            init(_ raw: JSONValue, meta: JSONValue?) {
                variant = raw["variant"]?.stringValue
                command = raw["command"]?.stringValue
                description = raw["description"]?.stringValue
                filePath = raw["file_path"]?.stringValue ?? raw["target_file"]?.stringValue
                path = raw["target_directory"]?.stringValue ?? raw["path"]?.stringValue
                pattern = raw["pattern"]?.stringValue
                query = raw["query"]?.stringValue ?? raw["search_term"]?.stringValue
                url = raw["url"]?.stringValue
                toolName = raw["tool_name"]?.stringValue
                subagentType = raw["subagent_type"]?.stringValue
                isBackground =
                    ["is_background", "background", "run_in_background"].contains { raw[$0] == .bool(true) }
                    || meta?["subagentBackground"] == .bool(true)
                questions = Self.questions(raw["questions"])
                todos = Self.todos(raw["todos"])
            }

            /// Adds what a later record of the call names.
            mutating func merge(_ later: Input) {
                variant = later.variant ?? variant
                command = later.command ?? command
                description = later.description ?? description
                filePath = later.filePath ?? filePath
                path = later.path ?? path
                pattern = later.pattern ?? pattern
                query = later.query ?? query
                url = later.url ?? url
                toolName = later.toolName ?? toolName
                subagentType = later.subagentType ?? subagentType
                isBackground = isBackground || later.isBackground
                if !later.questions.isEmpty { questions = later.questions }
                if !later.todos.isEmpty { todos = later.todos }
            }

            /// `questions[{question, options[{label, description}]}]`; the
            /// input update adds `multiSelect`.
            private static func questions(_ value: JSONValue?) -> [ChatQuestion] {
                guard case .array(let items) = value else { return [] }
                return items.compactMap { item in
                    guard let text = item["question"]?.stringValue else { return nil }
                    var options: [ChatQuestion.Option] = []
                    if case .array(let listed) = item["options"] {
                        options = listed.compactMap { option in
                            option["label"]?.stringValue.map {
                                ChatQuestion.Option(label: $0, detail: option["description"]?.stringValue)
                            }
                        }
                    }
                    return ChatQuestion(
                        id: item["id"]?.stringValue, header: item["header"]?.stringValue, text: text, options: options,
                        isMultiSelect: item["multiSelect"] == .bool(true) || item["multi_select"] == .bool(true))
                }
            }

            static func todos(_ value: JSONValue?) -> [Todo] {
                guard case .array(let items) = value else { return [] }
                return items.compactMap { item in
                    item["content"]?.stringValue.map { Todo(content: $0, status: item["status"]?.stringValue) }
                }
            }
        }

        /// A call's result.
        struct Output: Sendable {
            /// `rawOutput.type`: `Bash`, `SearchReplace`, `MCP`, `Text`.
            let type: String?
            /// What the row shows; nil when it shows something else, such as
            /// an edit's diff or a question's answers.
            let preview: ChatToolPreview?
            /// A command's exit code, when it ran to its end.
            let exitCode: Int?
            let signal: String?
            /// Grok moved the command to the background before it ended; the
            /// result has no status then.
            let isBackgrounded: Bool
            /// The background task the call started.
            let taskID: String?
            /// A question's answers, as Grok lists them for the model:
            /// `"<question>"="<answer>", …`.
            let answers: String?
            /// The user declined the questions, or no user could answer them.
            let isUnanswered: Bool
            let command: String?
            /// The file an edit changed.
            let path: String?
            /// An MCP call's server and tool.
            let server: String?
            let tool: String?

            static let answeredPrefix = "User has answered your questions: "
            private static let answeredSuffix = ". You can now continue with the user's answers in mind."
            private static let unansweredPrefixes = [
                "User declined to answer the questions", "No user is available to answer questions",
            ]

            init?(_ update: JSONValue, status: String?, notRun: String?) {
                let raw = update["rawOutput"]
                let type = raw?["type"]?.stringValue
                let signal = raw?["signal"]?.stringValue
                let isBackgrounded = type == "Bash" && signal == "backgrounded"
                guard status == "completed" || status == "failed" || notRun != nil || isBackgrounded else {
                    return nil
                }
                self.type = type
                self.signal = signal
                self.isBackgrounded = isBackgrounded
                // A search keeps ripgrep's exit code too, 1 when nothing
                // matched; only a command's says how the call ended.
                exitCode =
                    type == "Bash" && signal == nil
                    ? GrokUpdateRecord.integer(raw?["exit_code"]).flatMap { Int(exactly: $0) } : nil
                taskID = type == "BackgroundTaskStarted" ? raw?["task_id"]?.stringValue : nil
                command = raw?["command"]?.stringValue
                path = raw?["EditsApplied"]?["absolute_path"]?.stringValue
                server = type == "MCP" ? raw?["server_name"]?.stringValue : nil
                tool = type == "MCP" ? raw?["tool_name"]?.stringValue : nil
                let content = Self.content(update["content"])
                let tag = Self.tag(raw)
                let message = content.text ?? tag?.value["message"]?.stringValue ?? ""
                if message.hasPrefix(Self.answeredPrefix) {
                    var answers = message.dropFirst(Self.answeredPrefix.count)
                    if answers.hasSuffix(Self.answeredSuffix) { answers = answers.dropLast(Self.answeredSuffix.count) }
                    self.answers = String(answers)
                } else {
                    answers = nil
                }
                isUnanswered = Self.unansweredPrefixes.contains { message.hasPrefix($0) }
                if notRun == nil {
                    let text = Self.shownText(raw, type: type, tag: tag, content: content.text, failed: status == "failed")
                    preview = GrokUpdateRecord.preview(
                        text ?? (content.images > 0 ? "" : nil), imageCount: content.images)
                } else {
                    // A call that never ran holds only Grok's note to the model.
                    preview = nil
                }
            }

            /// The text a result shows: an error's message, a command's
            /// output, an MCP tool's, a subagent's report, a background
            /// task's output or the todo list, else the content's text, else
            /// a failure's readable name.
            private static func shownText(
                _ raw: JSONValue?, type: String?, tag: (name: String, value: JSONValue)?, content: String?,
                failed: Bool
            ) -> String? {
                if raw?["error"] != nil, let message = raw?["message"]?.stringValue { return message }
                switch type {
                case "Bash":
                    // A command sent to the background shows its output once
                    // its task ends.
                    if raw?["signal"]?.stringValue == "backgrounded" { return nil }
                    return raw?["output_for_prompt"]?.stringValue.map(withoutExitLine) ?? content
                case "MCP":
                    let output = raw?["output"]
                    return output?["OkayOutput"]?.stringValue ?? output?["Error"]?.stringValue ?? content
                case "SubagentCompleted":
                    return raw?["output"]?.stringValue ?? content
                // `get_command_or_subagent_output` and
                // `kill_command_or_subagent`, whose results hold no content:
                // the output read, Grok's word on the kill, or why it found
                // no such task.
                case "TaskOutput":
                    switch tag?.name {
                    case "Result": return tag?.value["output"]?.stringValue ?? content
                    case "MultiResult": return outputs(tag?.value) ?? content
                    case "TaskNotFound": return tag?.value.stringValue ?? content
                    default: break
                    }
                case "KillTask":
                    switch tag?.name {
                    case "Result": return tag?.value["message"]?.stringValue ?? content
                    case "TaskNotFound": return tag?.value.stringValue ?? content
                    default: break
                    }
                case "Todo":
                    let todos = Input.todos(tag?.value["todos"])
                    return todos.isEmpty ? content : GrokUpdateRecord.todoText(todos)
                case "AskUserQuestion", "BackgroundTaskStarted":
                    return nil
                case "SearchReplace" where tag?.name == "EditsApplied":
                    return nil
                case "ListDir" where tag?.name == "Content":
                    return tag?.value["content"]?.stringValue ?? content
                default:
                    break
                }
                if let content { return content }
                if failed, let tag { return readableFailures[tag.name] ?? tag.name }
                return raw?["pre_formatted"]?.stringValue ?? raw?["content"]?.stringValue
                    ?? raw?["text"]?.stringValue
            }

            /// The outputs a read of several tasks found, one after another,
            /// else its summary: `2/2 tasks completed (wait_all)`.
            private static func outputs(_ results: JSONValue?) -> String? {
                var outputs: [String] = []
                if case .array(let items)? = results?["results"] {
                    outputs = items.compactMap { $0["output"]?.stringValue }.filter { !$0.isEmpty }
                }
                return outputs.isEmpty ? results?["summary"]?.stringValue : outputs.joined(separator: "\n")
            }

            /// What a tagged failure reads as when nothing else describes it.
            private static let readableFailures = [
                "FileNotFound": "File not found", "NotADirectory": "Not a directory",
                "MultipleMatchesFound": "Multiple matches", "InvalidInput": "Invalid input",
                "FileTooLarge": "File too large",
            ]

            /// The variant of an externally tagged `rawOutput`, such as
            /// `{type: ReadFile, FileNotFound: "…"}`: its one key besides
            /// `type` that starts with a capital.
            private static func tag(_ raw: JSONValue?) -> (name: String, value: JSONValue)? {
                guard case .object(let fields)? = raw,
                    let name = fields.keys.filter({ $0 != "type" && $0.first?.isUppercase == true }).min(),
                    let value = fields[name]
                else { return nil }
                return (name, value)
            }

            /// The text items of `content`, joined, and its images.
            private static func content(_ value: JSONValue?) -> (text: String?, images: Int) {
                guard case .array(let items) = value else { return (nil, 0) }
                var texts: [String] = []
                var images = 0
                for item in items where item["type"]?.stringValue == "content" {
                    switch item["content"]?["type"]?.stringValue {
                    case "text": if let text = item["content"]?["text"]?.stringValue { texts.append(text) }
                    case "image": images += 1
                    default: break
                    }
                }
                let text = texts.joined(separator: "\n")
                return (text.isEmpty ? nil : text, images)
            }

            /// A command's output without the `exit: <code>` line Grok puts
            /// first for the model.
            private static func withoutExitLine(_ text: String) -> String {
                guard text.hasPrefix("exit: ") else { return text }
                let scalars = text.unicodeScalars
                guard let newline = scalars.firstIndex(of: "\n") else { return "" }
                return String(scalars[scalars.index(after: newline)...])
            }
        }
    }

    /// A todo list as rows show it, one `[x]`, `[~]` or `[ ]` line per item.
    static func todoText(_ todos: [Tool.Input.Todo]) -> String {
        todos.map { todo in
            switch todo.status {
            case "completed": "[x] \(todo.content)"
            case "in_progress": "[~] \(todo.content)"
            default: "[ ] \(todo.content)"
            }
        }.joined(separator: "\n")
    }
}
