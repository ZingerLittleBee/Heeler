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
    var result: AgyStep?
    var taskID: String?
    var taskEnd: TaskEnd?
    /// Antigravity CLI restarted while the task ran, which stops it.
    var stoppedByRestart = false
    var turnEnd: TurnEnd?
    /// Another step of the call's turn came after its result.
    var isFollowed = false

    init(entryID: ChatEntryID, call: AgyStep.Call) {
        self.entryID = entryID
        name = call.name
        args = call.args
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

    /// The tools that wait in the background without a task of their own
    /// to follow: a `schedule` wait's result reads as sent to the
    /// background, but no end of its task ever comes (13 of 13 in the
    /// census, where all 44 commands sent there got one). agy writes the
    /// wait's prompt to the agent when it fires, which Chat can't tell
    /// from other context.
    static let waitTools: Set<String> = ["schedule"]

    /// A result agy sent to the background: a command's task, which ends
    /// with a system message, or a wait (`waitTools`), which never does.
    var isInTheBackground: Bool { result?.status == .running }

    /// The call as Chat's Stop reads it once agy made it a task.
    var backgroundCommand: ChatBackgroundCommand? {
        guard taskID != nil else { return nil }
        return ChatBackgroundCommand(
            callID: entryID.rawValue, command: command, isRunning: taskEnd == nil && !stoppedByRestart,
            isDaemon: args?["IsDaemon"] == .bool(true))
    }

    // MARK: Status

    /// The row's status and the note under it. While the call's turn is
    /// open, a call without a result follows what herdr reports.
    func outcome(activity: ChatAgentActivity) -> (status: ChatToolActivity.Status, note: String?) {
        if let taskEnd {
            if taskEnd.wasCanceled { return (.interrupted, String(localized: "Canceled in the background")) }
            let code = Self.exitCode(in: taskEnd.result)
            return ((code ?? 0) == 0 ? .succeeded : .failed, String(localized: "Finished in the background"))
        }
        if stoppedByRestart { return (.interrupted, String(localized: "Stopped when Antigravity CLI restarted")) }
        if let result {
            switch result.status {
            case .error:
                // A declined call ends the turn; agy then shows the turn
                // interrupted, which the row says.
                if isDeclined {
                    return (.declined, turnEnd == .interrupted ? String(localized: "Declining ended the turn") : nil)
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
        // and a wait's reads none.
        if let taskEnd {
            tool.output = taskEnd.line
        } else if let result, !isInTheBackground {
            tool.output = ChatOutputReference(offset: result.offset, length: result.length)
            if result.isTruncated {
                tool.preview?.isTruncated = true
                if tool.note == nil { tool.note = String(localized: "Output exceeds the preview limit.") }
            }
        }
        if kind == .fileRead, status == .succeeded { tool.imagePath = imagePath }
        return tool
    }

    /// The output a row shows: the task's result once a background task
    /// ends, else the call's result.
    var preview: ChatToolPreview? {
        if let taskEnd { return Self.preview(ofTaskResult: taskEnd.result) }
        guard let result, result.status != .running else { return nil }
        return Self.preview(of: result, kind: kind)
    }

    /// A result's text as a row shows it: an error's message, a command's
    /// output without its exit line, anything else as written.
    static func preview(of result: AgyStep, kind: ChatToolActivity.Kind) -> ChatToolPreview? {
        let text: String
        if result.status == .error {
            text = result.error ?? Self.dropping("Encountered error in step execution: ", from: result.resultBody)
        } else if kind == .command {
            text = commandOutput(result.resultBody)
        } else {
            text = normalized(result.resultBody)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ChatToolPreview(capping: trimmed)
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

    /// The row's title and the line under it.
    var titles: (title: String, subtitle: String?) {
        let summary = string("toolSummary")
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
        case "send_message":
            title = string("Recipient").map { recipient in
                String(
                    localized: "Message to \(recipient)",
                    comment: "Title of an Antigravity CLI tool row that sends a message to another agent: its name")
            }
        case "manage_subagents", "manage_task":
            title = [string("Action"), string("TaskId")].compactMap { $0 }.joined(separator: " ")
        case "schedule":
            title = integer("DurationSeconds").map { seconds in
                let duration = Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow))
                return String(
                    localized: "Wait up to \(duration)",
                    comment: "Title of an Antigravity CLI tool row that waits: the longest wait, such as 30s")
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
