import Foundation

/// One Antigravity CLI tool call, gathered from its planner response, its
/// result and, for a command sent to the background, the system message
/// that ends its task. The projection builds its row once every record is
/// read.
struct AgyToolCall: Sendable {
    /// How a background task ended, from `Task id "<task>" finished with
    /// result:` or `… was canceled with result:`.
    struct TaskEnd: Sendable {
        let wasCanceled: Bool
        let result: String
        let line: ChatOutputReference
    }

    /// How a subagent launched by `invoke_subagent` ended, from its reply,
    /// an error message from `system`, or a `manage_subagents` kill.
    struct SubagentEnd: Sendable {
        enum Outcome: Sendable {
            case completed
            case failed
            case killed
        }

        let outcome: Outcome
        let text: String?
        let line: ChatOutputReference?
    }

    /// How the call's turn ended, as far as the call cares.
    enum TurnEnd: Sendable {
        /// The turn went on past the call without its result, or ended with
        /// a reply.
        case movedOn
        /// The next prompt came before a reply: Esc or Ctrl+C, which agy
        /// does not record.
        case interrupted
    }

    let entryID: ChatEntryID
    let name: String
    let args: JSONValue?
    let callOffset: UInt64
    let callCreatedAt: Date?
    var result: AgyStep?
    var taskID: String?
    var taskEnd: TaskEnd?
    var killedByManageTask = false
    /// A `schedule` timer or bounded cron that fired, reached `MaxIterations`,
    /// or was cancelled early by its `TimerCondition`.
    var scheduleEnded = false
    var subagentID: String?
    var subagentEnd: SubagentEnd?
    /// Antigravity CLI restarted while the task or subagent ran, which stops it.
    var stoppedByRestart = false
    var turnEnd: TurnEnd?
    /// Another step of the call's turn came after its result.
    var isFollowed = false

    init(entryID: ChatEntryID, call: AgyStep.Call, offset: UInt64 = 0, createdAt: Date? = nil) {
        self.entryID = entryID
        name = call.name
        args = call.args
        callOffset = offset
        callCreatedAt = createdAt
    }

    var kind: ChatToolActivity.Kind { Self.kinds[name] ?? .other }

    /// The file-edit tools whose permission dialog herdr 0.9.5 reports as
    /// idle: its hint row lacks the words herdr's Blocked rule looks for.
    var asksInADialogHerdrMisses: Bool { Self.editTools.contains(name) || Self.writeTools.contains(name) }

    /// Tool names across agy's two tool families (1.4 to 1.5.3) and the
    /// ones issue #644 names.
    private static let kinds: [String: ChatToolActivity.Kind] = [
        "view_file": .fileRead, "read_file": .fileRead,
        "run_command": .command,
        "write_file": .fileWrite, "write_to_file": .fileWrite,
        "edit_file": .fileEdit, "replace_file_content": .fileEdit, "multi_replace_file_content": .fileEdit,
        "grep_search": .search, "find_by_name": .search, "codebase_search": .search,
        "list_dir": .listing,
        "search_web": .web, "read_url_content": .web, "read_url": .web,
        "invoke_subagent": .agent, "manage_subagents": .agent, "send_message": .agent, "browser_subagent": .agent,
        "run_workflow": .agent,
        "swarm": .agent, "post_message": .agent, "read_board": .agent, "swarm_wait": .agent,
        "ask_question": .question,
        "generate_image": .image,
    ]

    /// The tools that change part of a file, asked about in agy's `Pending
    /// edit` dialog. No capture shows `multi_replace_file_content`'s; agy
    /// 1.5.3's strings hold only that one edit dialog, so the card answers
    /// it as any edit.
    static let editTools: Set<String> = ["edit_file", "replace_file_content", "multi_replace_file_content"]

    /// The tools that write a whole file, asked about in `Create file` for a
    /// new one.
    static let writeTools: Set<String> = ["write_file", "write_to_file"]

    /// The tools agy asks the user about: it writes the call as its dialog
    /// opens and the result only after the answer, so an open call can
    /// stand in for the Blocked herdr misses. A command agy runs without
    /// asking still writes its call first, but herdr reports it working.
    /// The tools that need no answer are written with their results.
    static let userGatedTools: Set<String> = editTools.union(writeTools).union(["run_command", "ask_question"])

    /// Native Swarm coordination tools (agy 1.5.9).
    static let swarmTools: Set<String> = ["swarm", "post_message", "read_board", "swarm_wait"]

    /// The tools whose tool-row status settles once the agent moves past
    /// launching them in the background: a `schedule` timer or cron keeps
    /// running as Background Work, while the `schedule` call itself finishes
    /// returning once armed.
    static let waitTools: Set<String> = ["schedule"]

    /// A result agy sent to the background: a command's task, workflow, or
    /// scheduled timer/cron.
    var isInTheBackground: Bool { result?.status == .running }

    /// The call as Chat's Stop reads it once agy made it a task. Scheduled
    /// timers carry no shell `CommandLine` and are excluded from command Stop
    /// matching.
    var backgroundCommand: ChatBackgroundCommand? {
        guard taskID != nil, name != "schedule" else { return nil }
        return ChatBackgroundCommand(
            callID: entryID.rawValue, command: command,
            isRunning: taskEnd == nil && !killedByManageTask && !stoppedByRestart,
            isDaemon: isDaemon)
    }

    // MARK: Status

    /// The row's status and the note under it. While the call's turn is
    /// open, a call without a result follows what herdr reports.
    func outcome(activity: ChatAgentActivity) -> (status: ChatToolActivity.Status, note: String?) {
        if let taskEnd {
            if taskEnd.wasCanceled {
                return (
                    .interrupted,
                    String(
                        localized: "Canceled in the background",
                        comment: "Under a Chat tool row: Antigravity CLI canceled the command it sent to the background"))
            }
            let code = Self.exitCode(in: taskEnd.result)
            return ((code ?? 0) == 0 ? .succeeded : .failed, String(localized: "Finished in the background"))
        }
        if killedByManageTask {
            return (.interrupted, String(localized: "Stopped in the background"))
        }
        if let subagentEnd {
            switch subagentEnd.outcome {
            case .completed: return (.succeeded, nil)
            case .failed: return (.failed, nil)
            case .killed: return (.interrupted, String(localized: "Stopped in the background"))
            }
        }
        if stoppedByRestart {
            return (
                .interrupted,
                String(
                    localized: "Stopped when Antigravity CLI restarted",
                    comment: "Under a Chat tool row: the background command stopped when Antigravity CLI restarted"))
        }
        if subagentID != nil {
            return (.running, nil)
        }
        if let result {
            switch result.status {
            case .error:
                // A declined call ends the turn; agy then shows the turn
                // interrupted, which the row says.
                if isDeclined {
                    let note = String(
                        localized: "Declining ended the turn",
                        comment: "Under a Chat tool row the user declined: declining also ended the agent's turn")
                    return (.declined, turnEnd == .interrupted ? note : nil)
                }
                return (.failed, nil)
            case .running:
                // A wait's call is done once agy goes on past it: nothing
                // will end it.
                if Self.waitTools.contains(name), isFollowed || turnEnd != nil {
                    return (.succeeded, String(localized: "Sent to the background"))
                }
                return (.started, String(localized: "Sent to the background"))
            case .done, .other:
                if kind == .command, let code = Self.exitCode(in: result.resultBody), code != 0 { return (.failed, nil) }
                // A skipped question reads `Skipped` under itself, so a
                // call whose questions were all skipped needs no note.
                return (.succeeded, nil)
            }
        }
        switch turnEnd {
        case .interrupted: return (.interrupted, nil)
        case .movedOn: return (.noResult, nil)
        case nil:
            switch activity {
            case .blocked: return (.awaitingApproval, nil)
            case .working, .unknown: return (.running, nil)
            // herdr reports agy idle under its file-edit dialog, so an edit
            // without a result may be waiting there, as Claude Code's
            // question tool may.
            case .idle: return (asksInADialogHerdrMisses ? .awaitingApproval : .noResult, nil)
            }
        }
    }

    /// agy's permission check refused the call because the user declined it.
    var isDeclined: Bool {
        guard let result, result.status == .error else { return false }
        return (result.error ?? result.resultBody).contains("user denied permission")
    }

    // MARK: Row

    func activity(agent: ChatAgentActivity) -> ChatToolActivity {
        let (status, note) = outcome(activity: agent)
        let (title, subtitle) = titles
        var tool = ChatToolActivity(
            kind: kind, name: name, title: title, subtitle: subtitle, status: status, note: note,
            questions: questions, callID: entryID.rawValue)
        // agy's own sentence about the call stands under its command or path.
        if subtitle != nil, subtitle == toolSummary {
            tool.subtitleIsProse = true
        }
        // A diff shows what the call changed, or would change while it waits.
        let changes: ChatFileChanges? =
            switch status {
            case .succeeded, .running, .awaitingApproval: fileChanges(isDone: status == .succeeded)
            default: nil
            }
        if let changes {
            tool.fileChanges = changes
            tool.diff = ChatDiffStats(
                added: changes.files.reduce(0) { $0 + $1.added }, removed: changes.files.reduce(0) { $0 + $1.removed },
                files: changes.files.count + changes.moreFiles)
        }
        guard kind != .question else { return tool }
        if tool.fileChanges == nil || status == .failed {
            tool.preview = preview
        }
        tool.exitCode = taskEnd.flatMap { Self.exitCode(in: $0.result) } ?? result.flatMap { result in
            kind == .command ? Self.exitCode(in: result.resultBody) : nil
        }
        // A result agy sent to the background is its instructions to the
        // model, not output: a command's row reads its task's end instead,
        // a subagent's reads its reply or error, and a wait's reads none.
        if let taskEnd {
            tool.output = taskEnd.line
        } else if let subagentEnd {
            tool.output = subagentEnd.line
        } else if let result, !isInTheBackground, subagentID == nil, !killedByManageTask {
            tool.output = ChatOutputReference(offset: result.offset, length: result.length)
            if result.isTruncated {
                tool.preview?.isTruncated = true
                if tool.note == nil { tool.note = String(localized: "Output exceeds the preview limit.") }
            }
        }
        if kind == .fileRead, status == .succeeded { tool.imagePath = imagePath }
        return tool
    }

    /// The output a row shows: the task's or subagent's result once
    /// background work ends, else the call's result.
    var preview: ChatToolPreview? {
        if let taskEnd { return Self.preview(ofTaskResult: taskEnd.result) }
        if let subagentEnd { return subagentEnd.text.flatMap(Self.preview(ofSubagentMessage:)) }
        if killedByManageTask || subagentID != nil { return nil }
        guard let result, result.status != .running else { return nil }
        return Self.preview(of: result, kind: kind, name: name)
    }

    /// A subagent's reply or system error message as its row shows it.
    static func preview(ofSubagentMessage text: String) -> ChatToolPreview? {
        let trimmed = normalized(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ChatToolPreview(capping: trimmed)
    }

    /// A result's text as a row shows it: an error's message, a command's
    /// output without its exit line, a swarm tool's readable summary, or
    /// anything else as written.
    static func preview(of result: AgyStep, kind: ChatToolActivity.Kind, name: String? = nil) -> ChatToolPreview? {
        let text: String
        if result.status == .error {
            text = result.error ?? Self.dropping("Encountered error in step execution: ", from: result.resultBody)
        } else if kind == .command {
            text = commandOutput(result.resultBody)
        } else if let name, swarmTools.contains(name), let formatted = swarmResultText(result.resultBody, name: name) {
            text = formatted
        } else {
            text = normalized(result.resultBody)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ChatToolPreview(capping: trimmed)
    }

    /// Readable summary of a native Swarm JSON result (`swarm`, `post_message`, `read_board`).
    private static func swarmResultText(_ raw: String, name: String) -> String? {
        let trimmed = normalized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
            let data = trimmed.data(using: .utf8),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        switch name {
        case "post_message":
            if let seq = json["seq"].flatMap({ if case .number(let n) = $0 { Int(exactly: n) } else { nil } }) {
                return String(localized: "Posted as #\(seq)")
            }
        case "read_board":
            if case .array(let messages)? = json["messages"] {
                if messages.isEmpty {
                    return String(localized: "No new board messages.")
                }
                let lines = messages.compactMap { item -> String? in
                    let seq = item["seq"].flatMap { if case .number(let n) = $0 { Int(exactly: n) } else { nil } }
                    let agent = item["agent"]?.stringValue ?? ""
                    let body = firstLine(of: item["text"]?.stringValue) ?? ""
                    guard !agent.isEmpty || !body.isEmpty else { return nil }
                    let prefix = seq.map { "#\($0) " } ?? ""
                    return "\(prefix)\(agent): \(body)"
                }
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            }
        case "swarm":
            if case .array(let members)? = json["members"], !members.isEmpty {
                let lines = members.compactMap { member -> String? in
                    guard let memberName = member["name"]?.stringValue, !memberName.isEmpty else { return nil }
                    let state = member["state"]?.stringValue ?? "unknown"
                    let model = member["model_display_name"]?.stringValue ?? member["model"]?.stringValue
                    return model.map { "@\(memberName) · \(state) (\($0))" } ?? "@\(memberName) · \(state)"
                }
                if !lines.isEmpty { return lines.joined(separator: "\n") }
            }
            if let status = json["status"]?.stringValue {
                if status == "added", let worker = json["name"]?.stringValue {
                    let model = json["model_display_name"]?.stringValue ?? json["model"]?.stringValue
                    return model.map { "@\(worker) (\($0))" } ?? "@\(worker)"
                }
                if status == "titled", let title = json["title"]?.stringValue {
                    return title
                }
                if status == "killed", let worker = json["name"]?.stringValue {
                    return "@\(worker)"
                }
            }
        default:
            break
        }
        return nil
    }

    /// A task's result as a row shows it, without the `Log:` line agy ends
    /// it with.
    static func preview(ofTaskResult result: String) -> ChatToolPreview? {
        var body = result
        if let log = body.range(of: "\nLog: ", options: .backwards) {
            body = String(body[..<log.lowerBound])
        }
        let text = commandOutput(body).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ChatToolPreview(capping: text)
    }

    /// `Command exited with code <n>.` (or `The command exited …` before
    /// 1.5), then the output after `Command output:` or `Output:`.
    static func commandOutput(_ body: String) -> String {
        var text = normalized(body)
        for prefix in ["Command exited with code ", "The command exited with code "] where text.hasPrefix(prefix) {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            } else {
                text = ""
            }
        }
        text = String(text.drop { $0.isNewline })
        for header in ["Command output:\n", "Output:\n"] where text.hasPrefix(header) {
            text = String(text.dropFirst(header.count))
        }
        if text.hasPrefix("No output from the command.") { return "" }
        return text
    }

    /// The exit code a command's result opens with.
    static func exitCode(in body: String) -> Int? {
        for prefix in ["Command exited with code ", "The command exited with code "] {
            guard let start = body.range(of: prefix) else { continue }
            let digits = body[start.upperBound...].prefix { $0 == "-" || $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    /// A terminal's `\r\n` line ends as plain ones.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func dropping(_ prefix: String, from text: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// The image a read showed: agy attaches a copy to the result as media,
    /// a `file:` URL under the conversation's folder or an absolute path.
    private var imagePath: String? {
        guard let media = result?.media.first(where: { $0.mimeType?.hasPrefix("image/") == true }) else { return nil }
        return ChatImagePath.resolve(media.uri, cwd: nil)
    }

    // MARK: Arguments

    private func string(_ key: String) -> String? {
        guard let value = args?[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    private func integer(_ key: String) -> Int? {
        guard case .number(let number)? = args?[key] else { return nil }
        return Int(exactly: number)
    }

    /// The file a read, write or edit names, in either tool family.
    var filePath: String? {
        string("AbsolutePath") ?? string("Path") ?? string("TargetFile")
    }

    /// The command a Blocked card matches on.
    var command: String? { string("CommandLine") }

    var toolSummary: String? { string("toolSummary") }

    var isDaemon: Bool { args?["IsDaemon"] == .bool(true) }

    var isCronSchedule: Bool { string("CronExpression") != nil }

    var scheduleMaxIterations: Int? {
        guard let max = integer("MaxIterations"), max > 0 else { return nil }
        return max
    }

    var timerCondition: String? { string("TimerCondition") }

    /// Title and subtitle for a `schedule` call's Background Work row: the
    /// prompt's first line as the headline, and the concise timer duration
    /// (matching agy's `4m timer` strip) or cron expression as the subtitle.
    func scheduleBackgroundTitles(resultBody: String) -> (title: String, subtitle: String?) {
        let parsed = Self.scheduleDescriptionParts(inResultBody: resultBody)
        let spec: String? =
            if let seconds = integer("DurationSeconds") {
                Self.scheduleDurationLabel(seconds)
            } else if let cron = string("CronExpression") {
                cron
            } else {
                parsed.spec
            }
        let promptLine = Self.firstLine(of: string("Prompt")) ?? Self.firstLine(of: parsed.prompt)
        let fallback = String(localized: "Timer")
        let title = promptLine ?? spec ?? fallback
        let subtitle = spec.flatMap { $0.isEmpty || $0 == title ? nil : $0 }
        return (title, subtitle)
    }

    /// Formats `DurationSeconds` in the compact form agy uses in its terminal
    /// strip (`4m`, `30s`, `1m30s`, `1h`).
    static func scheduleDurationLabel(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let minutes = (clamped % 3_600) / 60
        let secs = clamped % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if secs > 0 || parts.isEmpty { parts.append("\(secs)s") }
        return parts.joined()
    }

    /// Extracts `(isCron, spec, prompt)` from a `Task Description:` line in a
    /// `schedule` tool result body, if present.
    static func scheduleDescriptionParts(inResultBody body: String) -> (isCron: Bool, spec: String?, prompt: String?) {
        for rawLine in normalized(body).split(separator: "\n") {
            guard rawLine.hasPrefix("Task Description: ") else { continue }
            let description = String(rawLine.dropFirst("Task Description: ".count))
                .trimmingCharacters(in: .whitespaces)
            return scheduleDescriptionParts(description)
        }
        return (false, nil, nil)
    }

    /// Parses agy's `Timer: 4m, Prompt: ...` and `Cron: */3 * * * *, Prompt: ...`
    /// task descriptions (from launch results and `manage_task(list)`).
    static func scheduleDescriptionParts(_ description: String) -> (isCron: Bool, spec: String?, prompt: String?) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixAndKind: (String, Bool)? =
            if trimmed.hasPrefix("Timer: ") {
                ("Timer: ", false)
            } else if trimmed.hasPrefix("Cron: ") {
                ("Cron: ", true)
            } else {
                nil
            }
        guard let (prefix, isCron) = prefixAndKind else {
            return (trimmed.localizedCaseInsensitiveContains("cron"), nil, nil)
        }
        let body = trimmed.dropFirst(prefix.count)
        if let marker = body.range(of: ", Prompt: ") {
            let spec = body[..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
            let prompt = body[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (isCron, spec.isEmpty ? nil : spec, prompt.isEmpty ? nil : prompt)
        }
        let spec = body.trimmingCharacters(in: .whitespaces)
        return (isCron, spec.isEmpty ? nil : spec, nil)
    }

    /// The row's title and the line under it.
    var titles: (title: String, subtitle: String?) {
        let summary = toolSummary
        var subtitle: String? = summary
        let title: String?
        switch name {
        case "run_command":
            title = command
        case "grep_search", "codebase_search":
            title = string("Query")
            subtitle = summary ?? string("SearchPath")
        case "find_by_name":
            title = string("Pattern") ?? string("SearchDirectory")
            subtitle = summary ?? (string("Pattern") == nil ? nil : string("SearchDirectory"))
        case "list_dir":
            title = string("DirectoryPath")
        case "search_web":
            title = string("query")
            subtitle = summary ?? string("domain")
        case "read_url_content", "read_url":
            title = string("Url") ?? string("url")
        case "invoke_subagent":
            title = string("Role") ?? string("TypeName")
            subtitle = string("TypeName")
        case "run_workflow":
            let script = string("ScriptPath").map { URL(fileURLWithPath: $0).lastPathComponent }
            title = string("Description") ?? script
            subtitle = summary ?? (string("Description") == nil ? nil : script)
        case "send_message":
            title = string("Recipient").map { recipient in
                String(
                    localized: "Message to \(recipient)",
                    comment: "Title of an Antigravity CLI tool row that sends a message to another agent: its name")
            }
        case "manage_subagents", "manage_task":
            title = [string("Action"), string("TaskId")].compactMap { $0 }.joined(separator: " ")
        case "swarm":
            let swarmTitles = swarmCallTitles
            title = swarmTitles.title
            subtitle = summary ?? swarmTitles.subtitle
        case "post_message":
            let channel = string("channel").flatMap { $0 == "main" ? nil : $0 }
            title = channel.map { String(localized: "Post to #\($0)") } ?? String(localized: "Post to swarm board")
            subtitle = summary ?? Self.firstLine(of: string("text"))
        case "read_board":
            title =
                integer("since").map { String(localized: "Read swarm board since #\($0)") }
                ?? String(localized: "Read swarm board")
            let channel = string("channel").flatMap { $0 == "*" || $0 == "main" ? nil : "#\($0)" }
            subtitle = summary ?? channel
        case "swarm_wait":
            title =
                integer("since").map { String(localized: "Wait on swarm board after #\($0)") }
                ?? String(localized: "Wait on swarm board")
        case "schedule":
            if let seconds = integer("DurationSeconds") {
                let duration = Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow))
                title = String(
                    localized: "Wait up to \(duration)",
                    comment: "Title of an Antigravity CLI tool row that waits: the longest wait, such as 30s")
            } else if let cron = string("CronExpression") {
                title = cron
                subtitle = summary ?? Self.firstLine(of: string("Prompt"))
            } else {
                title = nil
            }
        case "ask_question":
            let texts = questions.map(\.text)
            title = texts.isEmpty ? nil : texts.joined(separator: " · ")
            subtitle = nil
        case "generate_image":
            title = string("Prompt")
        default:
            title = filePath ?? Self.firstString(in: args)
        }
        let shown = title.flatMap { $0.isEmpty ? nil : $0 } ?? name
        return (shown, subtitle.flatMap { $0.isEmpty || $0 == shown ? nil : $0 })
    }

    /// The first short string argument, for a tool Chat does not know.
    private static func firstString(in args: JSONValue?) -> String? {
        guard case .object(let fields)? = args else { return nil }
        for key in fields.keys.sorted() where !["toolAction", "toolSummary"].contains(key) {
            if let value = fields[key]?.stringValue, !value.isEmpty, !value.contains("\n"), value.count <= 200 {
                return value
            }
        }
        return nil
    }

    static func firstLine(of text: String?, maxLength: Int = 140) -> String? {
        guard let text else { return nil }
        let line = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
    }

    private var swarmCallTitles: (title: String?, subtitle: String?) {
        switch string("action") {
        case "title":
            let swarmTitle = string("title")
            return (
                swarmTitle.map { String(localized: "Title swarm \u{201C}\($0)\u{201D}") }
                    ?? String(localized: "Title swarm"),
                nil
            )
        case "add":
            let worker = string("name")
            return (
                worker.map { String(localized: "Add worker @\($0)") } ?? String(localized: "Add swarm worker"),
                Self.firstLine(of: string("brief"))
            )
        case "kill":
            let worker = string("name")
            return (
                worker.map { String(localized: "Stop worker @\($0)") } ?? String(localized: "Stop swarm worker"),
                nil
            )
        case "status":
            return (String(localized: "Check swarm status"), nil)
        case "model":
            let worker = string("name")
            return (
                worker.map { String(localized: "Switch model for @\($0)") } ?? String(localized: "Switch swarm model"),
                string("model")
            )
        case "models":
            return (String(localized: "List swarm models"), nil)
        case "channel":
            let channel = string("channel")
            switch string("op") {
            case "create":
                return (
                    channel.map { String(localized: "Create channel #\($0)") } ?? String(localized: "Create swarm channel"),
                    string("topic")
                )
            case "archive":
                return (
                    channel.map { String(localized: "Archive channel #\($0)") }
                        ?? String(localized: "Archive swarm channel"),
                    nil
                )
            case "subscribe":
                return (
                    channel.map { String(localized: "Subscribe to #\($0)") }
                        ?? String(localized: "Subscribe to channel"),
                    string("name").map { "@\($0)" }
                )
            case "unsubscribe":
                return (
                    channel.map { String(localized: "Unsubscribe from #\($0)") }
                        ?? String(localized: "Unsubscribe from channel"),
                    string("name").map { "@\($0)" }
                )
            case "list":
                return (String(localized: "List swarm channels"), nil)
            default:
                let raw = [string("op"), channel].compactMap { $0 }.joined(separator: " ")
                return (raw.isEmpty ? String(localized: "Manage swarm channels") : raw, nil)
            }
        case let other?:
            return ("swarm \(other)", string("name"))
        case nil:
            return (nil, nil)
        }
    }

    // MARK: Questions

    /// `ask_question`'s questions, answered from its result's `A<n>: …`
    /// lines; `User Skipped` marks a question skipped, with no answer. A
    /// `(Recommended) ` prefix marks the option the agent recommends.
    var questions: [ChatQuestion] {
        guard name == "ask_question", case .array(let items)? = args?["questions"] else { return [] }
        let answers = result.map { Self.answers(in: $0.resultBody) } ?? (given: [:], skipped: [])
        var questions: [ChatQuestion] = []
        for (index, item) in items.enumerated() {
            guard let text = item["question"]?.stringValue else { continue }
            var options: [ChatQuestion.Option] = []
            var recommended: Int?
            if case .array(let labels)? = item["options"] {
                for label in labels.compactMap(\.stringValue) {
                    let marker = "(Recommended) "
                    if label.hasPrefix(marker) {
                        recommended = recommended ?? options.count
                        options.append(ChatQuestion.Option(label: String(label.dropFirst(marker.count))))
                    } else {
                        options.append(ChatQuestion.Option(label: label))
                    }
                }
            }
            let isMultiSelect = item["is_multi_select"] == .bool(true)
            questions.append(
                ChatQuestion(
                    text: text, options: options, isMultiSelect: isMultiSelect, recommendedIndex: recommended,
                    answer: answers.given[index + 1], isSkipped: answers.skipped.contains(index + 1)))
        }
        return questions
    }

    /// The answers by question number, from lines `A1: banana`, and the
    /// questions skipped, whose line reads `User Skipped`.
    static func answers(in body: String) -> (given: [Int: String], skipped: Set<Int>) {
        var answers: [Int: String] = [:]
        var skipped: Set<Int> = []
        var current: Int?
        for line in normalized(body).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("A"), let colon = line.firstIndex(of: ":"),
                let number = Int(line[line.index(after: line.startIndex)..<colon])
            {
                let answer = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = number
                answers[number] = answer == "User Skipped" ? nil : answer
                if answer == "User Skipped" { skipped.insert(number) }
            } else if let current, let answer = answers[current] {
                // A written-in answer can run over several lines.
                answers[current] = answer + "\n" + line
            }
        }
        let given = answers.compactMapValues { answer in
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (given, skipped)
    }

    // MARK: File changes

    /// What a write or an edit changes: a write's whole content as added
    /// lines, an edit's target and replacement diffed from the line its
    /// result names.
    func fileChanges(isDone: Bool) -> ChatFileChanges? {
        guard let path = filePath else { return nil }
        switch name {
        case "write_file", "write_to_file":
            guard let content = args?["Content"]?.stringValue ?? args?["CodeContent"]?.stringValue else { return nil }
            // Only the result tells a new file from one written over.
            let created = isDone && result.map { $0.resultBody.hasPrefix("Created file") } == true
            let kind: ChatFileChange.Kind = created && args?["Overwrite"] != .bool(true) ? .created : .written
            return ChatFileChanges(files: [ChatFileChange.allAdded(path: path, content: content, kind: kind)])
        case "edit_file", "replace_file_content":
            guard let target = string("Target") ?? string("TargetContent"),
                let replacement = args?["Replacement"]?.stringValue ?? args?["ReplacementContent"]?.stringValue
            else { return nil }
            let line = result.flatMap { Self.startLine(in: $0.resultBody) } ?? integer("StartLine") ?? 1
            // The target is text in the file, which usually ends mid-line,
            // the rest of that line after it. A line end on both sides keeps
            // that line from reading as changed, so the counts match agy's
            // `(+1/-0 lines)`.
            var old = target
            var new = replacement
            if !old.hasSuffix("\n"), !new.hasSuffix("\n") {
                old += "\n"
                new += "\n"
            }
            let item: JSONValue = .object([
                "type": .string("diff"), "path": .string(path), "oldText": .string(old),
                "newText": .string(new), "_meta": .object(["new_line": .number(Double(line))]),
            ])
            return GrokFileChanges.changes(content: .array([item]))
        default:
            return nil
        }
    }

    /// `N` in an edit's `Made 1 replacement in <path> starting at line N`.
    static func startLine(in body: String) -> Int? {
        guard let start = body.range(of: " starting at line ") else { return nil }
        return Int(body[start.upperBound...].prefix { $0.isNumber })
    }

    // MARK: Blocked card

    /// Whether the call may still be waiting on a dialog or running: no
    /// result, no end of its task, and its turn still open. A command sent
    /// to the background has its result.
    var isOpen: Bool { result == nil && taskEnd == nil && !stoppedByRestart && turnEnd == nil }

    /// What a Blocked card matches the call on: its command, its file or
    /// its row's title, with the questions it asks and the change a file
    /// call would make.
    func pendingRequest(for tool: ChatToolActivity) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: entryID, callID: entryID.rawValue, kind: tool.kind, toolName: name,
            summary: command ?? filePath ?? tool.title, detail: string("toolSummary"), questions: tool.questions,
            fileChanges: fileChanges(isDone: false))
    }
}
