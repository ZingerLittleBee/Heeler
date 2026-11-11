import Foundation

/// The Agent a herdr-core Terminal holds right now.
struct HerdrCoreAgent: Equatable, Sendable {
    /// A kind Heeler knows, or for any other program a sanitized word to show,
    /// which no table kept by program takes for a program it knows.
    let kind: String
    let isKnownProgram: Bool
    let status: AgentStatus

    /// This Agent if it finished a turn this device has not seen. Only one that
    /// reads idle, which a report of idle or done does, can still be Done.
    var markedDone: HerdrCoreAgent {
        guard status == .idle else { return self }
        return HerdrCoreAgent(kind: kind, isKnownProgram: isKnownProgram, status: .done)
    }
}

/// Which Terminal is an Agent (ADR 0032). A Terminal is one while a known agent
/// program holds its foreground, or while any program but a shell does and it
/// has a Program Status whose `app` is missing or unknown here. A known `app`
/// counts only while it names the foreground: nothing ties a report to a process,
/// and the core keeps the report after its program left. The foreground is read
/// after unwrapping launch wrappers, `sh -c` lines, interpreters and `npx` or
/// `npm exec`, and a cleared one leaves the last sample standing
/// (`HerdrCoreTerminalRecord.noteForeground`). A `-NoExit` PowerShell, whose
/// foreground never changes, is its shell while the Terminal's title is that
/// PowerShell's own path.
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

    /// Done on herdr-core is per device (`HerdrCoreTurnState`), so a report of
    /// done reads Idle here.
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

    enum Program: Equatable, Sendable {
        case shell
        case known(String)
        case other(String)
    }

    /// What a command line comes to: its program, and the arguments that program got.
    private struct Reading {
        let program: Program
        var arguments: [String] = []
    }

    /// The arguments of the program `kind` this foreground runs, once its wrappers,
    /// `sh -c` line or interpreter are read away. Nil when its words name no such
    /// program, which a process's own name can still make it.
    static func arguments(of foreground: HerdrCoreForeground, runningKind kind: String) -> [String]? {
        let reading = read(foreground.argv)
        return reading.program == .known(kind) ? reading.arguments : nil
    }

    /// The shell a foreground names, as its program's own word. Read it only of
    /// one the rule reads as `.shell`.
    static func shellName(of foreground: HerdrCoreForeground) -> String {
        shellName(arguments: foreground.argv, name: foreground.name)
    }

    /// The shell a foreground's arguments or OS name come to, as its program's
    /// own word. Read it only of one the rule reads as `.shell`.
    static func shellName(arguments: [String], name: String) -> String {
        baseName(arguments.first ?? name)
    }

    /// The foreground, or without one what the Terminal launched. A process
    /// whose arguments say nothing known can still be known by its OS name, as
    /// a native install running from a versioned path is.
    static func program(of record: HerdrCoreTerminalRecord) -> Program {
        guard let foreground = record.foreground else { return readLaunch(record.argv) }
        if foreground.argv.isEmpty, foreground.name.isEmpty { return readLaunch(record.argv) }
        if showsPowerShellPrompt(foreground.argv, title: record.title) { return .shell }
        return program(arguments: foreground.argv, name: foreground.name)
    }

    /// What a foreground process comes to, by its arguments and its OS name.
    /// The name speaks where the arguments are missing or say nothing known.
    /// This is all a tmux Pane's foreground is read by (`TmuxAgentRule`).
    static func program(arguments: [String], name: String) -> Program {
        guard !arguments.isEmpty else { return name.isEmpty ? .shell : read([name]).program }
        let program = read(arguments).program
        if case .other = program, let kind = knownKind(baseName(name)) {
            return .known(kind)
        }
        return program
    }

    /// A launch stands in for a foreground not sampled yet, and a record omits a
    /// cleared one, so this can also be long after the launch. One that continues
    /// as a shell may have outlived its command, so only a sample can name it.
    private static func readLaunch(_ arguments: [String]) -> Program {
        continuesAsShell(arguments) ? .shell : read(arguments).program
    }

    private static func continuesAsShell(_ arguments: [String]) -> Bool {
        guard let executable = arguments.first, shells.contains(baseName(executable)) else {
            return false
        }
        return arguments.dropFirst().contains {
            continuingWrapperBodies.contains($0) || ["-noexit", "/k"].contains($0.lowercased())
        }
    }

    private static let maximumDepth = 8

    private static func read(_ arguments: [String], depth: Int = 0) -> Reading {
        guard depth < maximumDepth, let executable = arguments.first else { return Reading(program: .shell) }
        if arguments.dropFirst().allSatisfy(\.isEmpty), let title = packageRunnerTitle(executable) {
            return read(title, depth: depth + 1)
        }
        let name = baseName(executable)
        if shells.contains(name) { return readShell(arguments, name: name, depth: depth) }
        if interpreters.contains(name) { return readInterpreter(arguments, name: name) }
        if name == "npx" { return readPackageRunner(Array(arguments.dropFirst()), name: name, depth: depth) }
        if name == "npm", arguments.count > 1, packageRunnerCommands.contains(arguments[1]) {
            return readPackageRunner(Array(arguments.dropFirst(2)), name: name, depth: depth)
        }
        let rest = Array(arguments.dropFirst())
        if let kind = knownKind(name) { return Reading(program: .known(kind), arguments: rest) }
        return Reading(program: .other(name), arguments: rest)
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

    /// The desktop app's `"$@"; exec "$0" -i`, and its remote and fish forms.
    private static let continuingWrapperBodies: Set<String> = [
        "\"$@\"; exec \"$0\" -i",
        "\"$@\"; exec \"${SHELL:-sh}\" -i",
        "command $argv[2..]; exec $argv[1] -i",
    ]

    /// The bodies whose arguments are the command to run: the desktop app's, and
    /// Heeler's own, which exec the agent and leave no shell behind.
    private static let wrapperBodies = continuingWrapperBodies.union([
        "exec \"$@\"",
        "exec $argv[2..]",
    ])

    /// Options of a shell that take the next argument, which is no script.
    private static let shellValueOptions: Set<String> = [
        "--rcfile", "--init-file", "--init-command", "-C", "-o", "+o", "-O", "+O",
    ]

    /// A wrapper, a line or a script is what the shell runs. A shell with
    /// options alone is the prompt, which ends the Agent.
    private static func readShell(_ arguments: [String], name: String, depth: Int) -> Reading {
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
                guard index + 1 < arguments.count else { return Reading(program: .shell) }
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
                return Reading(program: scriptProgram(argument), arguments: Array(arguments.dropFirst(index + 1)))
            }
        }
        return Reading(program: .shell)
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
    private static func readPowerShell(_ arguments: [String], name: String, depth: Int) -> Reading {
        guard
            let option = arguments.firstIndex(where: {
                let option = $0.lowercased()
                return option == "-command" || option == "-c"
            })
        else {
            return Reading(program: arguments.dropFirst().contains { !$0.hasPrefix("-") } ? .other(name) : .shell)
        }
        guard option + 1 < arguments.count else { return Reading(program: .shell) }
        var line = arguments[option + 1]
        if line.hasSuffix(powerShellExit) { line.removeLast(powerShellExit.count) }
        guard let words = powerShellWords(line) else { return Reading(program: .other(name)) }
        return read(words, depth: depth + 1)
    }

    /// A pseudo console's foreground stays the desktop app's `-NoExit` PowerShell
    /// after its program exits, so only the console's title shows the exit: it goes
    /// back to that PowerShell's own path (ADR 0032). A console nothing has titled
    /// reads an empty title instead, which keeps the foreground's reading.
    private static func showsPowerShellPrompt(_ arguments: [String], title: String) -> Bool {
        guard let executable = arguments.first else { return false }
        let name = baseName(executable)
        guard name == "powershell" || name == "pwsh", arguments.dropFirst().contains(where: isNoExitOption)
        else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.contains(where: { $0 == "\\" || $0 == "/" }) && baseName(title) == name
    }

    /// `-NoExit` as PowerShell takes it: any case, `-`, `--` or `/`, and cut short
    /// as far as `-NoE`.
    private static func isNoExitOption(_ argument: String) -> Bool {
        let option = argument.lowercased()
        guard let prefix = ["--", "-", "/"].first(where: option.hasPrefix) else { return false }
        let name = option.dropFirst(prefix.count)
        return name.count >= 3 && "noexit".hasPrefix(name)
    }

    /// Whether a Terminal holding this foreground on native Windows ends when its
    /// program does. A pseudo console's foreground is the Terminal's first process
    /// for its whole life, so a shell that outlives its program looks the same before
    /// and after (ADR 0035). A first process that is the program itself ends with it,
    /// as Heeler's form does, whose PowerShell has nothing left to run but its `exit`.
    /// Any other shell's line or options could keep it at a prompt, and so could a
    /// shell as that form's program, as `& 'cmd' '/k' 'claude'` would.
    static func windowsTerminalEndsWithItsProgram(_ foreground: HerdrCoreForeground) -> Bool {
        let arguments = foreground.argv.isEmpty ? [foreground.name] : foreground.argv
        guard let executable = arguments.first else { return false }
        let name = baseName(executable)
        guard shells.contains(name) else { return true }
        guard name == "powershell" || name == "pwsh", arguments.count == 3,
            arguments[1].lowercased() == "-command", arguments[2].hasSuffix(powerShellExit)
        else { return false }
        guard let program = powerShellWords(String(arguments[2].dropLast(powerShellExit.count)))?.first
        else { return false }
        return !shells.contains(baseName(program))
    }

    private static let powerShellExit = "; exit $LASTEXITCODE"

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
    private static func readLine(_ line: String, depth: Int) -> Reading {
        let commands = shellCommands(in: line).map(commandWords).filter { !$0.isEmpty }
        for (position, words) in commands.enumerated() {
            if setupCommands.contains(words[0]), position < commands.count - 1 { continue }
            return read(words, depth: depth)
        }
        return Reading(program: .shell)
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

    // MARK: Package runners

    /// `npm exec` and its alias `npm x`, which `npx` runs.
    private static let packageRunnerCommands: Set<String> = ["exec", "x"]

    /// npm sets its process title to `npm` and its positional arguments (npm 11
    /// `lib/npm.js`), so on Linux the process reads as `npm exec claude` (hc-lab,
    /// `npx claude`, 2026-11-02), which the arguments hold as one word, and a
    /// scoped package keeps its `/` there. Its words, when it is one: the first
    /// word is `npx` or `npm` itself, so a path never reads as one.
    private static func packageRunnerTitle(_ word: String) -> [String]? {
        let words = word.split(separator: " ").map(String.init)
        guard words.count > 1 else { return nil }
        let isRunner = words[0] == "npx" || (words[0] == "npm" && packageRunnerCommands.contains(words[1]))
        return isRunner ? words : nil
    }

    /// Options of `npx` and `npm exec` that take no value.
    private static let packageRunnerFlags: Set<String> = [
        "-y", "--yes", "--no", "--prefer-offline", "--prefer-online", "--offline", "-q", "--quiet", "--silent",
    ]

    /// Options that name the package whose command runs.
    private static let packageOptions: Set<String> = ["-p", "--package"]

    /// npm packages whose name is not their program's.
    private static let packages = [
        "@anthropic-ai/claude-code": "claude",
        "@google/gemini-cli": "gemini",
        "@mariozechner/pi-coding-agent": "pi",
        "@earendil-works/pi-coding-agent": "pi",
        "@openai/codex": "codex",
        "opencode-ai": "opencode",
        "@opencode/cli": "opencode",
    ]

    /// `npx [options] <package or command> [arguments]`: the agent the package or
    /// command names, with the arguments after it. With `--package` the word is the
    /// package's command. An option this does not know may take a value, and
    /// `--call` runs a line, so either leaves the runner as the program.
    private static func readPackageRunner(_ arguments: [String], name: String, depth: Int) -> Reading {
        var index = 0
        var namesACommand = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            if !argument.hasPrefix("-") { break }
            if packageRunnerFlags.contains(argument) {
                index += 1
            } else if packageOptions.contains(argument) {
                namesACommand = true
                index += 2
            } else if argument.hasPrefix("--package=") {
                namesACommand = true
                index += 1
            } else {
                return Reading(program: .other(name))
            }
        }
        guard index < arguments.count else { return Reading(program: .other(name)) }
        let word = arguments[index]
        let rest = Array(arguments.dropFirst(index + 1))
        if namesACommand || (word.contains("/") && !word.hasPrefix("@")) || word.contains("\\") {
            let program = read([word], depth: depth + 1).program
            return Reading(program: program, arguments: rest)
        }
        let package = packageName(word)
        let command = String(package.split(separator: "/").last ?? "")
        guard let kind = packages[package] ?? knownKind(command) else {
            return Reading(program: .other(command.isEmpty ? name : command), arguments: rest)
        }
        return Reading(program: .known(kind), arguments: rest)
    }

    /// A package spec's name, without its version: `@scope/name@1.2.3` is
    /// `@scope/name`.
    private static func packageName(_ spec: String) -> String {
        let lowered = spec.lowercased()
        let start = lowered.hasPrefix("@") ? lowered.index(after: lowered.startIndex) : lowered.startIndex
        guard let at = lowered[start...].firstIndex(of: "@") else { return lowered }
        return String(lowered[..<at])
    }

    // MARK: Interpreters

    /// Script entry points named for their package, not for the program.
    private static let entryPoints: [([String], String)] = [
        (["@anthropic-ai", "claude-code", "cli.js"], "claude"),
        (["@google", "gemini-cli", "dist", "index.js"], "gemini"),
        (["@mariozechner", "pi-coding-agent", "dist", "cli.js"], "pi"),
        (["@earendil-works", "pi-coding-agent", "dist", "cli.js"], "pi"),
        (["@earendil-works", "pi-coding-agent", "dist", "bundle", "cli.js"], "pi"),
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
    private static func readInterpreter(_ arguments: [String], name: String) -> Reading {
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
                return Reading(program: .other(name))
            }
        }
        guard index < arguments.count else { return Reading(program: .other(name)) }
        return Reading(program: scriptProgram(arguments[index]), arguments: Array(arguments.dropFirst(index + 1)))
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
