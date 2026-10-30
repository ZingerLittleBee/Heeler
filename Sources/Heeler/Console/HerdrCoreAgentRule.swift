import Foundation

/// The contributor's harness recognizer, moved verbatim from `HerdrCoreWire`.
/// "Agents and their status on herdr-core" fixes it and gives it its callers.
enum HerdrCoreAgentRule {
    /// Which Agent a Terminal record holds, from the program reporting status,
    /// its foreground and its launch command, or nil for an ordinary program.
    static func kind(of record: JSONValue) -> String? {
        let foreground = record["foreground"]
        let foregroundArguments = strings(foreground?["argv"])
        let foregroundName = foreground?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let launchArguments = strings(record["argv"])
        let processKind: String?
        if !foregroundArguments.isEmpty || foregroundName != nil {
            // Once the foreground is known, a desktop wrapper's original
            // command must not keep an exited Agent in the inventory.
            processKind = kind(in: foregroundArguments)
                ?? recognizedKind(foregroundName)
        } else {
            processKind = kind(in: launchArguments)
        }
        return isPlainShell(foregroundArguments)
            ? nil : recognizedKind(record["status"]?["app"]?.stringValue) ?? processKind
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap(\.stringValue)
    }

    static func recognizedKind(_ value: String?) -> String? {
        guard let value else { return nil }
        let basename = value.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        switch basename {
        case "claude-code", "claude code": return "claude"
        case "pi-cli": return "pi"
        case "cursor-agent": return "cursor"
        case "kiro-cli": return "kiro"
        case "antigravity": return "agy"
        default: return SupportedAgentKind(rawValue: basename)?.rawValue
        }
    }

    /// Inspect command positions, never arbitrary arguments: `echo claude`
    /// and `node server.js claude` are not Agents. These are the POSIX launch
    /// wrappers emitted by herdr-app's `window::agent_argv` and common script
    /// entry points from the programs it starts.
    static func kind(in arguments: [String], depth: Int = 0) -> String? {
        guard depth < 4, let executable = arguments.first else { return nil }
        let program = executable.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh"]
        let wrapperBodies: Set<String> = [
            "\"$@\"; exec \"$0\" -i",
            "\"$@\"; exec \"${SHELL:-sh}\" -i",
        ]
        if shells.contains(program), arguments.count > 4,
            ["-c", "-ic"].contains(arguments[1]), wrapperBodies.contains(arguments[2])
        {
            return kind(in: Array(arguments.dropFirst(4)), depth: depth + 1)
        }
        if let direct = recognizedKind(executable) { return direct }
        guard ["node", "nodejs", "bun", "python", "python3", "ruby"].contains(program) else { return nil }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { index += 1; break }
            if !argument.hasPrefix("-") { break }
            // Evaluated source is not a script name. Refuse unknown switches
            // rather than mistaking their values for an executable.
            if ["--no-warnings", "--enable-source-maps", "--experimental-strip-types", "-u", "-B"].contains(argument) {
                index += 1
            } else if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(argument) {
                index += 2
            } else {
                return nil
            }
        }
        guard index < arguments.count else { return nil }
        return scriptKind(arguments[index])
    }

    static func scriptKind(_ path: String) -> String? {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let basename = components.last else { return nil }
        let entryPoints: [([String], String)] = [
            (["@anthropic-ai", "claude-code", "cli.js"], "claude"),
            (["@google", "gemini-cli", "dist", "index.js"], "gemini"),
            (["@mariozechner", "pi-coding-agent", "dist", "cli.js"], "pi"),
            (["@openai", "codex", "bin", "codex.js"], "codex"),
        ]
        for (suffix, kind) in entryPoints where components.suffix(suffix.count).elementsEqual(suffix) {
            return kind
        }
        let stem = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"]
            .first(where: basename.hasSuffix)
            .map { String(basename.dropLast($0.count)) } ?? basename
        return recognizedKind(stem)
    }

    /// A foreground shell's retained report may belong to the Agent that
    /// just exited. Only veto a positively identified plain shell: a shell
    /// running a command or script can itself be an Agent launcher.
    static func isPlainShell(_ arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        let name = executable.split(separator: "/").last.map(String.init) ?? ""
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh"]
        guard shells.contains(String(name.drop(while: { $0 == "-" })).lowercased()) else { return false }
        return arguments.dropFirst().allSatisfy { option in
            ["--interactive", "--login", "--norc", "--noprofile"].contains(option)
                || (option.hasPrefix("-") && option.count > 1 && option.dropFirst().allSatisfy { "il".contains($0) })
        }
    }
}
