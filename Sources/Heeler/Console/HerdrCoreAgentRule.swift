import Foundation

/// The Agent a herdr-core Terminal holds right now.
struct HerdrCoreAgent: Equatable, Sendable {
    /// A kind Heeler knows, or for any other program a sanitized word to show,
    /// which no table kept by program takes for a program it knows.
    let kind: String
    let isKnownProgram: Bool
    let status: AgentStatus
}

/// Which Terminal is an Agent (ADR 0032). A Terminal is one while a known agent
/// program holds its foreground, or while any program but a shell does and it
/// has a Program Status whose `app` is missing or unknown here. A known `app`
/// counts only while it names the foreground: nothing ties a report to a process,
/// and the core keeps the report after its program left. The foreground is read
/// after unwrapping launch wrappers, `sh -c` lines and interpreters.
///
/// `plugin/test-vectors/herdr-core-agent-rule-v1.json` holds this rule's cases, so
/// a change here changes that file and the Helper's reading of it in one commit.
enum HerdrCoreAgentRule {
    /// What a harness calls itself in a Program Status, to the kind Heeler calls it.
    static let reportedApps = [
        "claude-code": "claude",
        "codex": "codex",
        "opencode": "opencode",
        "pi": "pi",
        "omp": "omp",
        "grok-build": "grok",
    ]

    static func agent(in record: HerdrCoreTerminalRecord) -> HerdrCoreAgent? {
        guard !record.hasFinished, !record.isRestarting else { return nil }
        switch program(of: record) {
        case .shell:
            return nil
        case .known(let kind):
            return HerdrCoreAgent(
                kind: kind, isKnownProgram: true, status: status(of: record, heldBy: kind))
        case .other(let name):
            guard let report = record.status else { return nil }
            let app = report.app.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reportedApps[app.lowercased()] == nil else { return nil }
            return HerdrCoreAgent(
                kind: genericKind(app: app, program: name), isKnownProgram: false,
                status: agentStatus(report.state))
        }
    }

    // MARK: Status

    /// The report only if nothing says it came from another known program.
    private static func status(
        of record: HerdrCoreTerminalRecord, heldBy kind: String
    ) -> AgentStatus {
        guard let report = record.status else { return .unknown }
        let app = report.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let reported = reportedApps[app], reported != kind { return .unknown }
        return agentStatus(report.state)
    }

    /// Done on herdr-core is per device. Until that arrives a reported done reads Idle.
    private static func agentStatus(_ state: String) -> AgentStatus {
        switch state {
        case "idle", "done": .idle
        case "working": .working
        case "blocked": .blocked
        case "error": .error
        default: .unknown
        }
    }

    // MARK: The foreground

    private enum Program: Equatable {
        case shell
        case known(String)
        case other(String)
    }

    /// The foreground, or until one arrives what the Terminal launched. A
    /// process whose arguments say nothing known can still be known by its OS
    /// name, as a native install running from a versioned path is.
    private static func program(of record: HerdrCoreTerminalRecord) -> Program {
        guard let foreground = record.foreground else { return read(record.argv) }
        guard !foreground.argv.isEmpty else {
            return foreground.name.isEmpty ? read(record.argv) : read([foreground.name])
        }
        let program = read(foreground.argv)
        if case .other = program, let kind = knownKind(baseName(foreground.name)) {
            return .known(kind)
        }
        return program
    }

    private static let maximumDepth = 8

    private static func read(_ arguments: [String], depth: Int = 0) -> Program {
        guard depth < maximumDepth, let executable = arguments.first else { return .shell }
        let name = baseName(executable)
        if shells.contains(name) { return readShell(arguments, name: name, depth: depth) }
        if interpreters.contains(name) { return readInterpreter(arguments, name: name) }
        if let kind = knownKind(name) { return .known(kind) }
        return .other(name)
    }

    /// The last path component, in lower case, with a login shell's `-` and a
    /// Windows executable's extension gone.
    private static func baseName(_ path: String) -> String {
        var name = String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
        name = String(name.drop { $0 == "-" }).lowercased()
        for suffix in [".exe", ".cmd"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    private static func knownKind(_ name: String) -> String? {
        aliases[name] ?? SupportedAgentKind(rawValue: name)?.rawValue
    }

    private static let aliases = [
        "claude-code": "claude",
        "claude code": "claude",
        "pi-cli": "pi",
        "cursor-agent": "cursor",
        "kiro-cli": "kiro",
        "antigravity": "agy",
        "github-copilot": "copilot",
        "grok-build": "grok",
    ]

    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh", "ion",
        "pwsh", "powershell", "cmd",
    ]

    private static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "python", "python3", "ruby",
    ]

    // MARK: Shells

    /// The bodies whose arguments are the command to run: the desktop app's
    /// `"$@"; exec "$0" -i`, its remote and fish forms, and Heeler's own, which
    /// exec the agent and leave no shell behind.
    private static let wrapperBodies: Set<String> = [
        "\"$@\"; exec \"$0\" -i",
        "\"$@\"; exec \"${SHELL:-sh}\" -i",
        "command $argv[2..]; exec $argv[1] -i",
        "exec \"$@\"",
        "exec $argv[2..]",
    ]

    /// Options of a shell that take the next argument, which is no script.
    private static let shellValueOptions: Set<String> = [
        "--rcfile", "--init-file", "--init-command", "-C", "-o", "+o", "-O", "+O",
    ]

    /// A wrapper, a line or a script is what the shell runs. A shell with
    /// options alone is the prompt, which ends the Agent.
    private static func readShell(_ arguments: [String], name: String, depth: Int) -> Program {
        if name == "pwsh" || name == "powershell" {
            return readPowerShell(arguments, name: name, depth: depth)
        }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if name == "cmd", argument.lowercased() == "/c" || argument.lowercased() == "/k" {
                return read(Array(arguments.dropFirst(index + 1)), depth: depth + 1)
            }
            if isCommandOption(argument) {
                guard index + 1 < arguments.count else { return .shell }
                let body = arguments[index + 1]
                if wrapperBodies.contains(body) {
                    // After the body comes `$0`, then the command.
                    return read(Array(arguments.dropFirst(index + 3)), depth: depth + 1)
                }
                return readLine(body, depth: depth + 1)
            }
            if shellValueOptions.contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") || argument.hasPrefix("+") {
                index += 1
            } else {
                return scriptProgram(argument)
            }
        }
        return .shell
    }

    /// `-c`, or several short options ending in it, as `-ic` and `-lc`.
    private static func isCommandOption(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.contains("c") else {
            return false
        }
        return argument.dropFirst().allSatisfy(\.isLetter)
    }

    /// `pwsh -NoExit -Command "& 'prog' 'arg'"`, as the desktop app runs it, and
    /// `-Command "& 'prog' 'arg'; exit $LASTEXITCODE"`, as Heeler does.
    private static func readPowerShell(_ arguments: [String], name: String, depth: Int) -> Program {
        guard
            let option = arguments.firstIndex(where: {
                let option = $0.lowercased()
                return option == "-command" || option == "-c"
            })
        else {
            return arguments.dropFirst().contains { !$0.hasPrefix("-") } ? .other(name) : .shell
        }
        guard option + 1 < arguments.count else { return .shell }
        var line = arguments[option + 1]
        let exit = "; exit $LASTEXITCODE"
        if line.hasSuffix(exit) { line.removeLast(exit.count) }
        guard let words = powerShellWords(line) else { return .other(name) }
        return read(words, depth: depth + 1)
    }

    private static let powerShellQuotes: Set<Character> = [
        "'", "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}",
    ]

    /// The desktop app's `powershell_line` read back: each word quoted, a
    /// quote inside one doubled.
    private static func powerShellWords(_ line: String) -> [String]? {
        guard line.hasPrefix("& ") else { return nil }
        let characters = Array(line.dropFirst(2))
        var words: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == " " {
                index += 1
                continue
            }
            guard powerShellQuotes.contains(characters[index]) else { return nil }
            index += 1
            var word = ""
            while index < characters.count {
                let character = characters[index]
                if powerShellQuotes.contains(character) {
                    guard index + 1 < characters.count, powerShellQuotes.contains(characters[index + 1])
                    else { break }
                    index += 1
                }
                word.append(characters[index])
                index += 1
            }
            index += 1
            words.append(word)
        }
        return words
    }

    // MARK: Lines

    /// What leads a command and is not the program.
    private static let commandPrefixes: Set<String> = [
        "exec", "command", "builtin", "nohup", "noglob",
    ]

    /// Commands that set a line up for the one after them.
    private static let setupCommands: Set<String> = [
        "cd", "pushd", "export", "unset", "set", "source", ".", ":", "true", "umask", "ulimit", "trap",
    ]

    /// The program of a `sh -c` line: its first command past any setup. Only
    /// command positions count: `echo claude` is `echo`.
    private static func readLine(_ line: String, depth: Int) -> Program {
        let commands = shellCommands(in: line).map(commandWords).filter { !$0.isEmpty }
        for (position, words) in commands.enumerated() {
            if setupCommands.contains(words[0]), position < commands.count - 1 { continue }
            return read(words, depth: depth)
        }
        return .shell
    }

    /// One command's words without assignments, prefixes and `env`'s own.
    private static func commandWords(_ words: [String]) -> [String] {
        var rest = words[...]
        while let word = rest.first {
            if isAssignment(word) || commandPrefixes.contains(word) {
                rest = rest.dropFirst()
            } else if word == "env" {
                rest = rest.dropFirst().drop { $0.hasPrefix("-") }
            } else {
                break
            }
        }
        return Array(rest)
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A shell line's commands as words, quotes resolved and cut at each
    /// operator. Reads enough of the grammar to find a command's program.
    private static func shellCommands(in line: String) -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var isInWord = false
        var quote: Character?
        var isEscaped = false

        func endWord() {
            if isInWord { words.append(word) }
            word = ""
            isInWord = false
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }

        for character in line {
            if isEscaped {
                word.append(character)
                isEscaped = false
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    isEscaped = true
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                isInWord = true
            case "\\":
                isEscaped = true
                isInWord = true
            case " ", "\t":
                endWord()
            case "\n", ";", "&", "|", "(", ")":
                endCommand()
            default:
                word.append(character)
                isInWord = true
            }
        }
        endCommand()
        return commands
    }

    // MARK: Interpreters

    /// Script entry points named for their package, not for the program.
    private static let entryPoints: [([String], String)] = [
        (["@anthropic-ai", "claude-code", "cli.js"], "claude"),
        (["@google", "gemini-cli", "dist", "index.js"], "gemini"),
        (["@mariozechner", "pi-coding-agent", "dist", "cli.js"], "pi"),
        (["@earendil-works", "pi-coding-agent", "dist", "cli.js"], "pi"),
        (["@openai", "codex", "bin", "codex.js"], "codex"),
    ]

    private static let interpreterFlags: Set<String> = [
        "--no-warnings", "--enable-source-maps", "--experimental-strip-types", "-u", "-B",
    ]

    private static let interpreterValueOptions: Set<String> = [
        "-r", "--require", "--import", "--loader", "--experimental-loader",
    ]

    /// Only the script position counts: `node server.js claude` is `server`.
    /// An option this does not know may take a value, and evaluated source is
    /// no script's name, so either leaves the interpreter as the program.
    private static func readInterpreter(_ arguments: [String], name: String) -> Program {
        var index = 1
        if name == "bun" || name == "deno", arguments.count > 1, arguments[1] == "run" { index = 2 }
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            if !argument.hasPrefix("-") { break }
            if interpreterFlags.contains(argument) {
                index += 1
            } else if interpreterValueOptions.contains(argument) {
                index += 2
            } else {
                return .other(name)
            }
        }
        guard index < arguments.count else { return .other(name) }
        return scriptProgram(arguments[index])
    }

    private static func scriptProgram(_ path: String) -> Program {
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { $0.lowercased() }
        guard let baseName = components.last else { return .other(path) }
        for (suffix, kind) in entryPoints where components.suffix(suffix.count).elementsEqual(suffix) {
            return .known(kind)
        }
        let stem = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".sh"]
            .first(where: baseName.hasSuffix)
            .map { String(baseName.dropLast($0.count)) } ?? baseName
        return knownKind(stem).map(Program.known) ?? .other(stem)
    }

    // MARK: Generic kinds

    private static let maximumKindLength = 32

    /// Every word a table kept by program could take for one it knows. A generic
    /// kind spelled like one keeps a prefix, so it stays a word to show.
    private static let reservedKinds: Set<String> = Set(
        SupportedAgentKind.allCases.flatMap { [$0.rawValue, $0.executable] }
            + ChatProgram.allCases.map(\.rawValue)
            + Array(reportedApps.keys) + Array(aliases.keys) + ["unknown"])

    /// The reported name when it has anything to keep, else the program's.
    private static func genericKind(app: String, program: String) -> String {
        let kind = sanitized(app) ?? sanitized(program) ?? "program"
        return reservedKinds.contains(kind) ? "other-\(kind)" : kind
    }

    /// Lower-case ASCII letters and digits, `_` and single `-`, at most 32. Any
    /// process on the core can report any `app`, and this is what the row shows.
    private static func sanitized(_ text: String) -> String? {
        var kept = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                kept.unicodeScalars.append(scalar)
            } else if !kept.isEmpty, !kept.hasSuffix("-") {
                kept.append("-")
            }
        }
        var kind = String(kept.prefix(maximumKindLength))
        while kind.hasSuffix("-") { kind.removeLast() }
        return kind.isEmpty ? nil : kind
    }
}
