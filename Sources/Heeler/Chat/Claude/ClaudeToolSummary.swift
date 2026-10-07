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
            // A recorded patch shows as the row's file changes instead.
            return result.isError ? content : nil
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

    /// The files a call changed, as its row lists them. The program records
    /// them only for a call that succeeded.
    static func fileChanges(
        for use: ClaudeToolUse, details: ClaudeToolResultDetails?, outcome: ClaudeToolOutcome
    ) -> ChatFileChanges? {
        guard case .succeeded = outcome, var changes = details?.result?.fileChanges else { return nil }
        if use.name == "Bash", let command = use.input.command {
            changes.movesWorkingTree = movesWorkingTree(command)
        }
        return changes
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

    /// The git steps that can move the working tree (Claude Code 2.1.292).
    static let workingTreeSteps: Set<String> = [
        "checkout", "switch", "stash", "pull", "merge", "rebase", "reset", "restore", "clean",
        "cherry-pick", "revert",
    ]

    /// Whether a Bash command runs a git step that can move the working
    /// tree, so the changes recorded for it may be that step's rather than
    /// edits; Claude Code's terminal then hides the hunks under a note.
    /// Like its check, this reads each simple command past an optional
    /// `sudo`, where `-C` and `-c` take the next word. It also reads
    /// commands that check can pass over, such as those in groups, loops
    /// and substitutions or after `time`, so Chat may note a step the
    /// terminal doesn't.
    static func movesWorkingTree(_ command: String) -> Bool {
        ShellWords.simpleCommands(in: command).contains { words in
            var words = words[...]
            while let first = words.first {
                if first == "function" {
                    // `function NAME`, then its body's words.
                    words = words.dropFirst(2)
                } else if ShellWords.reservedWords.contains(first) || ShellWords.isAssignment(first) {
                    words = words.dropFirst()
                } else {
                    break
                }
            }
            if words.first == "sudo" { words = words.dropFirst() }
            return gitSubcommand(of: words).map(workingTreeSteps.contains) ?? false
        }
    }

    /// The first word after `git` and its options; `-C` and `-c` take the
    /// word after them.
    private static func gitSubcommand(of words: ArraySlice<String>) -> String? {
        guard words.first == "git" else { return nil }
        var index = words.startIndex + 1
        while index < words.endIndex {
            let word = words[index]
            guard word.hasPrefix("-") else { return word }
            index += word == "-C" || word == "-c" ? 2 : 1
        }
        return nil
    }
}

/// A shell command line read as words, well enough to find the commands it
/// runs: quotes, backslashes and comments are honored, here-document
/// bodies and arithmetic skipped, redirections dropped, and the commands
/// inside `$(…)` and backticks read as commands of their own.
private enum ShellWords {
    /// Words that start a compound command rather than name a program.
    static let reservedWords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "time"]

    /// `NAME=value`, which sets a variable for the command after it.
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), let first = word.first, first == "_" || first.isASCII && first.isLetter
        else { return false }
        return word[..<equals].allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The words of each simple command, those inside substitutions
    /// included: the line splits at unquoted `;`, `&`, `|`, newlines and
    /// parentheses.
    static func simpleCommands(in line: String) -> [[String]] {
        let scanner = Scanner(line)
        scanner.readCommands()
        return scanner.commands
    }

    private final class Scanner {
        /// Substitutions nested deeper read as text, so no command can
        /// exhaust the stack.
        static let maximumNesting = 32
        /// Arithmetic that doesn't close within this many characters reads
        /// as a substitution, so a command can't make every `$((` in it
        /// scan to its end.
        static let maximumArithmetic = 1_000

        private let characters: [Character]
        private var index = 0
        private var nesting = 0
        private(set) var commands: [[String]] = []
        /// Here-documents whose bodies start after the next newline.
        private var documents: [(delimiter: String, stripsTabs: Bool)] = []

        init(_ line: String) {
            characters = Array(line)
        }

        /// Reads commands up to an unquoted `close`, or the end.
        func readCommands(closedBy close: Character? = nil) {
            nesting += 1
            defer { nesting -= 1 }
            var words: [String] = []
            var word = ""
            var inWord = false
            // The word after a redirection names its target, not an argument.
            var isTarget = false
            // Subshells opened here, whose `)` doesn't close `$(…)`.
            var depth = 0

            func endWord() {
                guard inWord else { return }
                if isTarget { isTarget = false } else { words.append(word) }
                word = ""
                inWord = false
            }
            func endCommand() {
                endWord()
                isTarget = false
                if !words.isEmpty { commands.append(words) }
                words = []
            }

            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == close, depth == 0 {
                    endCommand()
                    return
                }
                switch character {
                case "\\":
                    // A backslash before a newline continues the line.
                    guard index < characters.count else { break }
                    if !characters[index].isNewline {
                        word.append(characters[index])
                        inWord = true
                    }
                    index += 1
                case "'":
                    word += readSingleQuoted()
                    inWord = true
                case "\"":
                    word += readDoubleQuoted()
                    inWord = true
                case "$" where next(is: "'"):
                    index += 1
                    word += readANSIQuoted()
                    inWord = true
                case "$" where next(is: "("):
                    word += readSubstitution()
                    inWord = true
                case "`" where canNest:
                    readCommands(closedBy: "`")
                    word += "`…`"
                    inWord = true
                case "(":
                    if !inWord, next(is: "("), words.allSatisfy(Self.leadsArithmetic),
                        let end = arithmeticEnd(from: index + 1)
                    {
                        // `(( … ))` is arithmetic.
                        index = end
                    } else {
                        endCommand()
                        depth += 1
                    }
                case ")":
                    endCommand()
                    depth = max(depth - 1, 0)
                case " ", "\t":
                    endWord()
                case "#" where !inWord:
                    while index < characters.count, !characters[index].isNewline { index += 1 }
                case "<" where next(is: "<") && next(is: "<", after: 1):
                    // `<<<word` is a here-string: its word is input.
                    endWord()
                    index += 2
                    isTarget = true
                case "<" where next(is: "<"):
                    endWord()
                    index += 1
                    readDocumentDelimiter()
                case "<", ">":
                    // A descriptor before it, as in `2>`, belongs to it.
                    if inWord, word.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        word = ""
                        inWord = false
                    } else {
                        endWord()
                    }
                    // `>>`, `>|`, `<>`, and `>&` or `<&` duplicating a descriptor.
                    if next(is: ">") || next(is: "|") || next(is: "&") { index += 1 }
                    isTarget = true
                case "&" where next(is: ">"):
                    // `&>file` and `&>>file` redirect both outputs.
                    endWord()
                    index += next(is: ">", after: 1) ? 2 : 1
                    isTarget = true
                case _ where character.isNewline:
                    endCommand()
                    skipDocuments()
                case ";", "&", "|":
                    endCommand()
                default:
                    word.append(character)
                    inWord = true
                }
            }
            endCommand()
        }

        /// Whether `((` after this word starts arithmetic, as it does after
        /// `if`, `while` or `for`.
        private static func leadsArithmetic(_ word: String) -> Bool {
            word == "for" || ShellWords.reservedWords.contains(word)
        }

        private var canNest: Bool {
            nesting < Self.maximumNesting
        }

        private func next(is character: Character, after offset: Int = 0) -> Bool {
            index + offset < characters.count && characters[index + offset] == character
        }

        /// The text up to the closing `'`.
        private func readSingleQuoted() -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "'" { return text }
                text.append(character)
            }
            return text
        }

        /// The text of `$'…'` up to its closing `'`; a backslash escapes
        /// the character after it, `'` included.
        private func readANSIQuoted() -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == "'" { return text }
                if character == "\\", index < characters.count {
                    text.append(characters[index])
                    index += 1
                } else {
                    text.append(character)
                }
            }
            return text
        }

        /// The text up to the closing `"`. The commands inside `$(…)` and
        /// backticks read as commands of their own, with quotes of their
        /// own.
        private func readDoubleQuoted() -> String {
            var text = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                switch character {
                case "\"":
                    return text
                case "\\" where index < characters.count:
                    let escaped = characters[index]
                    index += 1
                    // It escapes only these, and joins a newline's lines.
                    if escaped.isNewline { continue }
                    if !"$`\"\\".contains(escaped) { text.append("\\") }
                    text.append(escaped)
                case "$" where next(is: "("):
                    text += readSubstitution()
                case "`" where canNest:
                    readCommands(closedBy: "`")
                    text += "`…`"
                default:
                    text.append(character)
                }
            }
            return text
        }

        /// Reads on from the `(` after a `$`: past arithmetic, or the
        /// commands of a substitution. Returns what stands for it in the
        /// word.
        private func readSubstitution() -> String {
            if next(is: "(", after: 1), let end = arithmeticEnd(from: index + 2) {
                index = end
                return "$((…))"
            }
            guard canNest else { return "$" }
            index += 1
            readCommands(closedBy: ")")
            return "$(…)"
        }

        /// Where arithmetic from `start`, just past its `((`, ends: past the
        /// `))` that closes it. Nil when a lone `)` closes it first, as in
        /// `$((cd repo) && make)`, a substitution that starts with a subshell.
        private func arithmeticEnd(from start: Int) -> Int? {
            var depth = 0
            var position = start
            let limit = min(characters.count, start + Self.maximumArithmetic)
            while position < limit {
                switch characters[position] {
                case "(":
                    depth += 1
                case ")" where depth > 0:
                    depth -= 1
                case ")":
                    let closes = position + 1 < characters.count && characters[position + 1] == ")"
                    return closes ? position + 2 : nil
                default:
                    break
                }
                position += 1
            }
            return nil
        }

        /// Reads the delimiter after `<<` or `<<-`; the body is skipped at
        /// the next newline.
        private func readDocumentDelimiter() {
            let stripsTabs = next(is: "-")
            if stripsTabs { index += 1 }
            while next(is: " ") || next(is: "\t") { index += 1 }
            var delimiter = ""
            while index < characters.count, !characters[index].isNewline,
                !" \t;&|()<>`".contains(characters[index])
            {
                if !"'\"\\".contains(characters[index]) { delimiter.append(characters[index]) }
                index += 1
            }
            if !delimiter.isEmpty { documents.append((delimiter, stripsTabs)) }
        }

        /// Moves past the bodies of the here-documents the line opened.
        private func skipDocuments() {
            for document in documents {
                index = Self.lineAfter(
                    document: document.delimiter, stripsTabs: document.stripsTabs, in: characters, from: index)
            }
            documents = []
        }

        /// Where the line after a here-document's closing delimiter starts,
        /// or the end when the body never closes.
        private static func lineAfter(
            document delimiter: String, stripsTabs: Bool, in characters: [Character], from start: Int
        ) -> Int {
            var lineStart = start
            while lineStart < characters.count {
                var lineEnd = lineStart
                while lineEnd < characters.count, !characters[lineEnd].isNewline { lineEnd += 1 }
                var line = characters[lineStart..<lineEnd]
                if stripsTabs { line = line.drop { $0 == "\t" } }
                let next = min(lineEnd + 1, characters.count)
                if String(line) == delimiter { return next }
                lineStart = next
            }
            return characters.count
        }
    }
}

/// How a tool call that has a result ended
/// (docs/research/claude-code-transcript-format.md, "Tool pairing and
/// outcomes"; first match wins).
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
