import Foundation

/// How a Grok Build tool call reads as a row: its kind, and the command,
/// path, pattern or question it names.
struct GrokToolSummary: Equatable, Sendable {
    let kind: ChatToolActivity.Kind
    let title: String
    let subtitle: String?

    /// Paths read relative to `directory`, the session's directory.
    init(_ call: GrokToolCall, directory: String?) {
        let input = call.input
        let kind = call.rowKind
        func shown(_ path: String?) -> String? {
            path.map { ChatFileChanges.displayPath($0, in: directory) }
        }
        var subtitle: String?
        let title: String?
        switch kind {
        case .command:
            title = input?.command ?? call.output?.command ?? call.taskEnd?.command
            subtitle = input?.description
        case .fileRead:
            title = shown(call.location ?? input?.filePath ?? input?.path)
        case .fileEdit, .fileWrite:
            title = shown(input?.filePath ?? call.location ?? call.output?.path)
        case .listing:
            title = shown(input?.path ?? call.location)
        case .search:
            title = input?.pattern ?? input?.query
        case .web:
            title = input?.url ?? input?.query ?? Self.searched(call.callTitle ?? call.inputTitle)
        case .mcp:
            title = Self.mcpTool(call)
        case .agent:
            title = input?.description ?? call.subagentDescription
            subtitle = call.subagentType ?? input?.subagentType
        case .question:
            let texts = input?.questions.map(\.text) ?? []
            title = texts.isEmpty ? nil : texts.joined(separator: " · ")
        case .todo:
            title = "Update todos"
        case .image, .other:
            title = nil
        }
        let shownTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallback(call)
        self.kind = kind
        self.title = shownTitle
        self.subtitle = subtitle.flatMap { $0.isEmpty || $0 == shownTitle ? nil : $0 }
    }

    /// The input update's readable title, else the call's when it is more
    /// than the tool's name, else the tool's label or name.
    private static func fallback(_ call: GrokToolCall) -> String {
        if let title = call.inputTitle, !title.isEmpty { return title }
        if let title = call.callTitle, !title.isEmpty, title != call.name { return title }
        return call.label ?? call.toolName
    }

    /// What a server-side search looked for: its title after `Web search:`
    /// or `X search:`, without quotes.
    private static func searched(_ title: String?) -> String? {
        guard let title else { return nil }
        for prefix in GrokToolCall.searchTitlePrefixes where title.hasPrefix(prefix) {
            let query = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return query.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        }
        return nil
    }

    /// `<server>.<tool>` for an MCP call, from its input's
    /// `<server>__<tool>` or its result.
    private static func mcpTool(_ call: GrokToolCall) -> String? {
        if let name = call.input?.toolName, !name.isEmpty {
            guard let separator = name.range(of: "__") else { return name }
            return "\(name[..<separator.lowerBound]).\(name[separator.upperBound...])"
        }
        guard let server = call.output?.server, let tool = call.output?.tool else { return nil }
        return "\(server).\(tool)"
    }
}

/// One Grok Build tool call, merged from its records: the call, the input
/// Grok holds back until it runs, the result, and the background task or
/// subagent it started.
struct GrokToolCall: Sendable {
    /// How the turn a call belongs to ended; nil while it is open.
    enum TurnEnd: Sendable {
        case completed
        case cancelled
        /// Rejecting a permission ended it.
        case rejected
        case failed
        /// Another prompt opened a turn before it ended.
        case replaced
    }

    typealias Tool = GrokUpdateRecord.Tool

    let id: String
    let entryID: ChatEntryID
    /// The turn the call was first seen in, as the reducer counts them.
    let turn: Int
    var name: String?
    var toolKind: String?
    var label: String?
    var kind: String?
    /// The call's `title`: the tool's name, or for a command typed in
    /// Grok's shell mode a readable title.
    var callTitle: String?
    /// The input update's readable title: ``Execute `ls` ``.
    var inputTitle: String?
    var location: String?
    var input: Tool.Input?
    /// An input update came, or the call said it runs: it no longer waits
    /// for approval.
    var hasStarted = false
    /// The result's `status`.
    var status: String?
    var notRun: String?
    var output: Tool.Output?
    var outputLine: ChatOutputReference?
    /// The result's line was longer than the reader keeps.
    var outputIsTruncated = false
    var resultChanges: ChatFileChanges?
    var inputChanges: ChatFileChanges?
    /// Grok moved the call's command to the background.
    var sentToBackground = false
    var subagentID: String?
    var subagentType: String?
    var subagentDescription: String?
    var subagentEnd: GrokUpdateRecord.SubagentFinished?
    var subagentEndLine: ChatOutputReference?
    var taskEnd: GrokUpdateRecord.TaskCompleted?
    var taskEndLine: ChatOutputReference?

    init(id: String, entryID: ChatEntryID, turn: Int) {
        self.id = id
        self.entryID = entryID
        self.turn = turn
    }

    /// The titles Grok gives a search its server runs.
    static let searchTitlePrefixes = ["Web search:", "X search:"]

    /// Adds one record of the call, read from `line`.
    mutating func merge(_ tool: Tool, isCall: Bool, line: ChatOutputReference, isTruncated: Bool) {
        name = tool.name ?? name
        toolKind = tool.toolKind ?? toolKind
        label = tool.label ?? label
        kind = tool.kind ?? kind
        location = tool.location ?? location
        if let later = tool.input {
            if input == nil {
                input = later
            } else {
                input?.merge(later)
            }
        }
        if tool.status == "in_progress" || (!isCall && tool.output == nil) {
            hasStarted = true
        }
        // A result's title is Grok's label for its output, which rows leave
        // out.
        if isCall {
            callTitle = tool.title ?? callTitle
        } else if tool.output == nil {
            inputTitle = tool.title ?? inputTitle
        }
        guard let output = tool.output else {
            inputChanges = tool.fileChanges ?? inputChanges
            return
        }
        self.output = output
        status = tool.status
        notRun = tool.notRun
        outputLine = line
        outputIsTruncated = isTruncated
        resultChanges = tool.fileChanges ?? resultChanges
        if output.isBackgrounded || output.type == "BackgroundTaskStarted" {
            sentToBackground = true
        }
    }

    /// Grok's name for the tool. A record without `_meta["x.ai/tool"]`
    /// names it by its input's variant, its result's type, or a call title
    /// that is a tool name.
    var toolName: String {
        if let name { return name }
        if let variant = input?.variant, let name = Self.variantNames[variant] { return name }
        if let type = output?.type, let name = Self.outputNames[type] { return name }
        if let title = callTitle, !title.isEmpty, title.unicodeScalars.allSatisfy(Self.toolNameCharacters.contains) {
            return title
        }
        return "tool"
    }

    private static let toolNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")

    var isSpawn: Bool {
        toolName == "spawn_subagent" || toolKind == "task" || input?.variant == "Task"
    }

    var rowKind: ChatToolActivity.Kind {
        // A command typed in Grok's shell mode.
        if id.hasPrefix("bash-mode-") { return .command }
        if let kind = Self.kinds[toolName] { return kind }
        if let title = callTitle ?? inputTitle, Self.searchTitlePrefixes.contains(where: { title.hasPrefix($0) }) {
            return .web
        }
        if let kind = toolKind.flatMap({ Self.kindsByGrokKind[$0] }) ?? kind.flatMap({ Self.kindsByGrokKind[$0] }) {
            return kind
        }
        return .other
    }

    private static let kinds: [String: ChatToolActivity.Kind] = [
        "run_terminal_command": .command, "read_file": .fileRead, "grep": .search, "search_tool": .search,
        "search_replace": .fileEdit, "write": .fileWrite, "list_dir": .listing, "todo_write": .todo,
        "spawn_subagent": .agent, "ask_user_question": .question, "web_fetch": .web, "web_search": .web,
        "x_search": .web, "use_tool": .mcp, "get_command_or_subagent_output": .other,
        "kill_command_or_subagent": .other, "monitor": .other,
    ]

    /// Grok's own kinds, then the ACP kinds.
    private static let kindsByGrokKind: [String: ChatToolActivity.Kind] = [
        "execute": .command, "read": .fileRead, "edit": .fileEdit, "write": .fileWrite, "search": .search,
        "list": .listing, "fetch": .web, "task": .agent, "ask_user": .question, "plan": .todo, "use_tool": .mcp,
    ]

    private static let variantNames = [
        "Bash": "run_terminal_command", "ReadFile": "read_file", "Grep": "grep", "SearchReplace": "search_replace",
        "Write": "write", "ListDir": "list_dir", "TodoWrite": "todo_write", "Task": "spawn_subagent",
        "AskUserQuestion": "ask_user_question", "WebFetch": "web_fetch", "WebSearch": "web_search",
        "XSearch": "x_search", "UseTool": "use_tool",
    ]

    private static let outputNames = [
        "Bash": "run_terminal_command", "ReadFile": "read_file", "ListDir": "list_dir", "Todo": "todo_write",
        "SubagentCompleted": "spawn_subagent", "AskUserQuestion": "ask_user_question", "MCP": "use_tool",
    ]

    // MARK: Row

    /// The row's status and the note under it. `turnEnd` is how the call's
    /// turn ended; while it is open, a call without a result follows what
    /// herdr reports.
    func outcome(turnEnd: TurnEnd?, activity: ChatAgentActivity) -> (status: ChatToolActivity.Status, note: String?) {
        if let notRun {
            switch notRun {
            case "rejected": return (.declined, turnEnd == .rejected ? "Rejecting ended the turn" : nil)
            case "cancelled": return (.interrupted, nil)
            default: return (.notCompleted, nil)
            }
        }
        if let end = subagentEnd {
            let status: ChatToolActivity.Status =
                switch end.status {
                case "completed": .succeeded
                case "cancelled": .interrupted
                case "failed": .failed
                default: .notCompleted
                }
            return (status, end.error ?? Self.stats(end))
        }
        if let end = taskEnd {
            if end.wasKilled || end.signal != nil { return (.interrupted, "Stopped in the background") }
            return ((end.exitCode ?? 0) == 0 ? .succeeded : .failed, "Finished in the background")
        }
        if status == "failed" { return (.failed, nil) }
        if sentToBackground || (isSpawn && input?.isBackground == true && output != nil) {
            return (.started, "Sent to the background")
        }
        if let output {
            if let code = output.exitCode, code != 0 { return (.failed, nil) }
            return (.succeeded, output.isUnanswered ? "Not answered" : nil)
        }
        switch turnEnd {
        case nil:
            switch activity {
            // Until the user approves it, Grok has written only the call. An
            // approved spawn can show nothing more for as long as its
            // subagent runs, except the `subagent_spawned` Grok writes as it
            // starts, also while the Agent waits on the next card.
            case .blocked: return (hasStarted || subagentID != nil ? .running : .awaitingApproval, nil)
            case .working, .unknown: return (.running, nil)
            case .idle: return (.notCompleted, nil)
            }
        case .cancelled, .rejected: return (.interrupted, nil)
        case .completed: return (.noResult, nil)
        case .failed, .replaced: return (.notCompleted, nil)
        }
    }

    /// The call's row. Paths read relative to `directory`.
    func activity(directory: String?, turnEnd: TurnEnd?, agent: ChatAgentActivity) -> ChatToolActivity {
        let summary = GrokToolSummary(self, directory: directory)
        let (status, note) = outcome(turnEnd: turnEnd, activity: agent)
        var questions = input?.questions ?? []
        if let answers = output?.answers {
            let texts = questions.map(\.text)
            for index in questions.indices {
                questions[index].answer = Self.answer(to: questions[index].text, in: answers, among: texts)
            }
        }
        var tool = ChatToolActivity(
            kind: summary.kind, name: toolName, title: summary.title, subtitle: summary.subtitle, status: status,
            note: note, questions: questions, callID: id)
        // A diff shows what the call changed, or would change while it waits.
        // Once it has a result, only the result's changes show: a write of
        // the text a file already held changed nothing.
        let changes: ChatFileChanges? =
            switch status {
            case .succeeded: output == nil ? previewChanges : resultChanges
            case .running, .awaitingApproval: previewChanges
            default: nil
            }
        if let changes = changes.map({ Self.shown($0, kind: summary.kind, directory: directory) }) {
            tool.fileChanges = changes
            tool.diff = ChatDiffStats(
                added: changes.files.reduce(0) { $0 + $1.added }, removed: changes.files.reduce(0) { $0 + $1.removed },
                files: changes.files.count + changes.moreFiles)
        }
        if notRun == nil, tool.fileChanges == nil {
            tool.preview = preview(kind: summary.kind)
        }
        tool.exitCode = taskEnd != nil ? taskEnd?.exitCode : output?.exitCode
        // A question's answers show in its questions, and its result holds
        // nothing more for an expanded row to read.
        if notRun == nil, summary.kind != .question {
            tool.output = (subagentEnd?.preview != nil ? subagentEndLine : nil) ?? taskEndLine ?? outputLine
        }
        if outputIsTruncated, tool.output != nil, tool.output == outputLine {
            tool.preview?.isTruncated = true
            if tool.note == nil { tool.note = "Output exceeds the preview limit." }
        }
        if summary.kind == .fileRead, status == .succeeded { tool.imagePath = imagePath(directory: directory) }
        return tool
    }

    /// The file a read showed as an image: Grok records the image in the
    /// result's content and the path only in the call (Grok Build 1.0.70).
    /// A result cut short may have lost its content; its path's extension
    /// decides then.
    private func imagePath(directory: String?) -> String? {
        guard let path = ChatImagePath.resolve(location ?? input?.filePath ?? input?.path, cwd: directory) else {
            return nil
        }
        let showedImage = (output?.preview?.imageCount ?? 0) > 0
        return showedImage || (outputIsTruncated && ChatImagePath.hasImageExtension(path)) ? path : nil
    }

    /// The changes the input update previews. A write's preview never
    /// records the file's old text, so only its result tells a new file
    /// from one it replaces: until then the file reads as written.
    private var previewChanges: ChatFileChanges? {
        guard var changes = inputChanges else { return nil }
        if rowKind == .fileWrite {
            for index in changes.files.indices where changes.files[index].kind == .created {
                changes.files[index].kind = .written
            }
        }
        return changes
    }

    /// The output a row of `kind` shows.
    private func preview(kind: ChatToolActivity.Kind) -> ChatToolPreview? {
        switch kind {
        case .question:
            return nil
        case .todo:
            if let preview = output?.preview { return preview }
            guard let todos = input?.todos, !todos.isEmpty else { return nil }
            return ChatToolPreview(capping: GrokUpdateRecord.todoText(todos))
        case .agent:
            if let end = subagentEnd { return end.preview }
            // Work in the background reports when it ends.
            return sentToBackground || input?.isBackground == true ? nil : output?.preview
        default:
            // A command or a monitor in the background shows its output
            // once its task ends.
            if let end = taskEnd { return end.preview }
            return output?.preview
        }
    }

    /// What a Blocked card matches the call on: its command, its file or
    /// its row's title, with the questions it asks.
    func pendingRequest(for tool: ChatToolActivity) -> ChatPendingRequest {
        ChatPendingRequest(
            entryID: entryID, callID: id, kind: tool.kind, toolName: toolName,
            summary: input?.command ?? input?.filePath ?? tool.title, detail: input?.description,
            questions: tool.questions)
    }

    /// `changes` as a row lists them: paths relative to `directory`, and a
    /// write over an existing file as written.
    static func shown(
        _ changes: ChatFileChanges, kind: ChatToolActivity.Kind, directory: String?
    ) -> ChatFileChanges {
        var changes = changes
        changes.directory = directory
        if kind == .fileWrite {
            for index in changes.files.indices where changes.files[index].kind == .updated {
                changes.files[index].kind = .written
            }
        }
        return changes
    }

    /// A finished subagent's work: `2 tool calls · 1 turn · 7s`.
    static func stats(_ end: GrokUpdateRecord.SubagentFinished) -> String? {
        var parts: [String] = []
        if let calls = end.toolCalls { parts.append("\(calls) tool \(calls == 1 ? "call" : "calls")") }
        if let turns = end.turns { parts.append("\(turns) \(turns == 1 ? "turn" : "turns")") }
        if let milliseconds = end.durationMilliseconds { parts.append(duration(milliseconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `38s`, `2m 18s` or `1h 5m`, rounded down.
    static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(milliseconds, 0) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 {
            return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
        }
        let minutes = seconds / 60 % 60
        return minutes == 0 ? "\(seconds / 3_600)h" : "\(seconds / 3_600)h \(minutes)m"
    }

    /// The answer to `question` in Grok's `"<question>"="<answer>", …`
    /// list. The next question's pair ends it, and the preview the user
    /// selected or their notes, which Grok adds after it, are left out.
    static func answer(to question: String, in answers: String, among questions: [String]) -> String? {
        guard let start = answers.range(of: "\"\(question)\"=\"") else { return nil }
        var answer = answers[start.upperBound...]
        for other in questions where other != question {
            if let next = answer.range(of: ", \"\(other)\"=\"") { answer = answer[..<next.lowerBound] }
        }
        for annotation in [" selected preview:", " user notes:"] {
            if let range = answer.range(of: annotation) { answer = answer[..<range.lowerBound] }
        }
        if answer.hasSuffix("\"") { answer = answer.dropLast() }
        return String(answer)
    }
}
