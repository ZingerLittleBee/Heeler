import Foundation

/// How a tool call reads as a row: its kind, title and subtitle, from the
/// call's input alone so a row can show before its result arrives.
struct ClaudeToolSummary: Sendable, Equatable {
    var kind: ChatToolActivity.Kind
    var title: String
    var subtitle: String?

    init(kind: ChatToolActivity.Kind, title: String, subtitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }

    init(_ use: ClaudeToolUse) {
        let input = use.input
        switch use.name {
        case "Bash", "PowerShell":
            let command = input.command ?? ""
            if let description = input.description, !description.isEmpty, description != command {
                self.init(kind: .command, title: description, subtitle: command)
            } else {
                self.init(kind: .command, title: command)
            }
        case "Edit", "MultiEdit", "NotebookEdit":
            self.init(kind: .fileEdit, title: input.filePath ?? use.name)
        case "Write":
            self.init(kind: .fileWrite, title: input.filePath ?? use.name)
        case "Read", "NotebookRead":
            self.init(kind: .fileRead, title: input.filePath ?? use.name)
        case "Glob", "Grep":
            self.init(kind: .search, title: input.pattern ?? use.name, subtitle: input.path)
        case "LS":
            self.init(kind: .search, title: input.path ?? use.name)
        case "WebFetch":
            self.init(kind: .web, title: input.url ?? use.name)
        case "WebSearch":
            self.init(kind: .web, title: input.query ?? use.name)
        case "Agent", "Task":
            self.init(kind: .agent, title: input.description ?? use.name, subtitle: input.subagentType)
        case "AskUserQuestion":
            let texts = input.questions.map(\.text)
            self.init(kind: .question, title: texts.isEmpty ? use.name : texts.joined(separator: " · "))
        case "TodoWrite":
            self.init(kind: .todo, title: "Update todos")
        case "TaskCreate", "TaskUpdate", "TaskGet", "TaskList":
            self.init(kind: .todo, title: input.description ?? use.name)
        case "Skill":
            let invocation = ChatCommandInvocation(name: input.skill ?? use.name, arguments: input.arguments ?? "")
            self.init(kind: .other, title: invocation.displayText)
        case "ToolSearch":
            self.init(kind: .other, title: input.query ?? use.name)
        case "EnterPlanMode":
            self.init(kind: .other, title: "Enter plan mode")
        case "ExitPlanMode":
            self.init(kind: .other, title: "Exit plan mode", subtitle: input.planFilePath)
        default:
            if use.name.hasPrefix("mcp__") {
                // `mcp__server__tool` reads as `server.tool`.
                let parts = use.name.split(separator: "__", omittingEmptySubsequences: false).dropFirst()
                self.init(kind: .mcp, title: parts.joined(separator: "."))
            } else {
                let detail = [
                    input.description, input.command, input.filePath, input.url, input.query,
                    input.pattern, input.path,
                ].lazy.compactMap { $0 }.first { !$0.isEmpty }
                self.init(kind: .other, title: use.name, subtitle: detail)
            }
        }
    }

    /// What a Blocked card's screen parse matches a pending call on: the
    /// command, the path, the URL or the questions.
    static func pendingSummary(_ use: ClaudeToolUse) -> String {
        let input = use.input
        switch use.name {
        case "Bash", "PowerShell": return input.command ?? ""
        case "WebFetch": return input.url ?? ""
        case "AskUserQuestion": return input.questions.map(\.text).joined(separator: "\n")
        case "ExitPlanMode": return input.plan ?? ""
        default: return input.filePath ?? ClaudeToolSummary(use).title
        }
    }

    /// The text beside the summary on a Blocked card.
    static func pendingDetail(_ use: ClaudeToolUse) -> String? {
        switch use.name {
        case "Bash", "PowerShell": use.input.description
        case "WebFetch": use.input.prompt
        case "ExitPlanMode": use.input.planFilePath
        default: nil
        }
    }

    /// The capped output a row expands to. Declines carry boilerplate, and
    /// some tools' results are internal metadata, so they show none.
    static func preview(
        for use: ClaudeToolUse, result: ClaudeToolResult, details: ClaudeToolResultDetails?,
        outcome: ClaudeToolOutcome
    ) -> ChatToolPreview? {
        if case .declined = outcome { return nil }
        let structured = details?.result
        let content = result.content.text.isEmpty && result.content.imageCount == 0 ? nil : result.content
        switch use.name {
        case "Bash", "PowerShell":
            return structured?.commandOutput ?? (result.isError ? content : nil)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return structured?.diffPreview ?? (result.isError ? content : nil)
        case "Agent", "Task":
            if structured?.status == "async_launched" || structured?.status == "remote_launched" { return nil }
            return structured?.agentReport ?? content
        case "AskUserQuestion", "ToolSearch", "ExitPlanMode", "EnterPlanMode":
            return nil
        case "TodoWrite":
            guard let todos = structured?.todos ?? use.input.todos, !todos.isEmpty else { return content }
            return ChatToolPreview(capping: todos.map(Self.todoLine).joined(separator: "\n"))
        default:
            return content
        }
    }

    private static func todoLine(_ todo: ClaudeTodo) -> String {
        switch todo.status {
        case "completed": "[x] \(todo.content)"
        case "in_progress": "[~] \(todo.content)"
        default: "[ ] \(todo.content)"
        }
    }

    /// The exit code Bash reports in a failed result's first line.
    static func exitCode(for use: ClaudeToolUse, result: ClaudeToolResult) -> Int? {
        guard use.name == "Bash" || use.name == "PowerShell", result.isError else { return nil }
        let prefix = "Exit code "
        guard result.content.text.hasPrefix(prefix) else { return nil }
        return Int(result.content.text.dropFirst(prefix.count).prefix { $0.isNumber })
    }
}

/// How a tool call that has a result ended (brief §4, first match wins).
enum ClaudeToolOutcome: Sendable, Equatable {
    case succeeded(note: String?)
    case declined(feedback: String?)
    case interrupted
    case notCompleted
    case failed

    /// The decline texts (CLI `lC`/`R0` and `lB`/`JQ`).
    static let userDeclinePrefix = "The user doesn't want to proceed with this tool use."
    static let permissionDeniedPrefix = "Permission for this tool use was denied"

    init(result: ClaudeToolResult, details: ClaudeToolResultDetails?, trailingTexts: [String]) {
        let text = result.content.text
        if details?.isDenialUnanswered == true {
            self = .notCompleted
        } else if details?.denialKind != nil || text.hasPrefix(Self.userDeclinePrefix)
            || text.hasPrefix(Self.permissionDeniedPrefix)
        {
            let feedback = details?.userFeedback ?? Self.feedback(in: text)
            self = .declined(feedback: feedback.flatMap { $0.isEmpty ? nil : $0 })
        } else if text.hasPrefix("The user doesn't want to take this action right now.") {
            self = .declined(feedback: nil)
        } else if text.hasPrefix("[Request interrupted by user") {
            self = .interrupted
        } else if ClaudeUserText.isMarker(text) {
            self = .notCompleted
        } else if result.isError {
            self = .failed
        } else {
            let note = trailingTexts.filter { !ClaudeUserText.isMarker($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            self = .succeeded(note: note.isEmpty ? nil : note)
        }
    }

    /// What the user typed with a decline: the text after `the user said:`.
    static func feedback(in text: String) -> String? {
        guard let range = text.range(of: "user said:\n", options: .caseInsensitive) else { return nil }
        let feedback = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return feedback.isEmpty ? nil : feedback
    }

    var status: ChatToolActivity.Status {
        switch self {
        case .succeeded: .succeeded
        case .declined: .declined
        case .interrupted: .interrupted
        case .notCompleted: .notCompleted
        case .failed: .failed
        }
    }

    /// The user's note: feedback with a decline, or a note added to an
    /// approval.
    var note: String? {
        switch self {
        case .succeeded(let note): note
        case .declined(let feedback): feedback
        default: nil
        }
    }

    /// A decline without feedback, or an interruption, ends the turn and is
    /// followed by an interrupt marker that belongs to this row.
    var absorbsInterruptMarker: Bool {
        switch self {
        case .declined(let feedback): feedback == nil
        case .interrupted: true
        default: false
        }
    }
}
