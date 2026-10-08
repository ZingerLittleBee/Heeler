import Foundation

/// One entry of Chat's `/` menu: a skill the Host offers, or the program's
/// `/compact`.
struct ChatCommand: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case compact
        /// A skill, invoked with `prefix`: `/` for Claude Code, `$` for
        /// Codex, whose prompts take skills as `$name`.
        case skill(prefix: String)
    }

    let name: String
    let summary: String?
    let kind: Kind
    /// False when the command needs another state: `/compact` while the
    /// Agent works.
    var isEnabled: Bool

    var id: String { name }
}

/// Chat's `/` menu for both programs (ADR 0021): the Host's skills plus
/// `/compact`. Commands that open pickers or end sessions are left out;
/// the terminal still runs them.
enum ChatCommandMenu {
    static func commands(skills: [AgentSkill], agentIsIdle: Bool) -> [ChatCommand] {
        var commands = [
            ChatCommand(
                name: "compact", summary: "Summarize the conversation to free up context",
                kind: .compact, isEnabled: agentIsIdle)
        ]
        var names: Set<String> = ["compact"]
        for skill in skills where names.insert(skill.name).inserted {
            commands.append(
                ChatCommand(
                    name: skill.name, summary: skill.description,
                    kind: .skill(prefix: skill.commandPrefix), isEnabled: true))
        }
        return commands
    }

    /// The entries to suggest for a draft, or nil when the menu stays
    /// closed: it opens only while a leading `/` is followed by a partial
    /// name, before any space.
    static func suggestions(for draft: String, in commands: [ChatCommand]) -> [ChatCommand]? {
        guard draft.hasPrefix("/") else { return nil }
        let query = draft.dropFirst()
        guard !query.contains(where: \.isWhitespace), !query.contains("/") else { return nil }
        let needle = query.lowercased()
        return commands.filter { needle.isEmpty || $0.name.lowercased().hasPrefix(needle) }
    }
}

extension AgentSkill {
    /// A skill as Chat's Composer takes it: `/name` for both programs,
    /// which the send turns into the program's own form when it leads the
    /// message.
    var chatInsertionText: String { "/\(name) " }
}

/// What a Chat draft sends to the Agent's input box (ADR 0021).
///
/// The text arrives as one bracketed paste and Enter, exactly as if typed,
/// so anything the program's input box would treat as more than a message
/// is refused rather than sent: a `!` shell escape, Claude Code's bare exit
/// words, control bytes, and `/` commands the menu does not offer.
struct ChatSendRules: Sendable {
    let program: ChatProgram
    let commands: [ChatCommand]

    /// Claude Code runs `/exit` for these whole inputs.
    private static let claudeExitWords: Set<String> = ["exit", "quit", ":q", ":q!", ":wq", ":wq!"]

    enum Reading: Equatable {
        case text
        case command(ChatCommand, arguments: String)
        case refused(ComposerRefusal)
    }

    func validate(_ draft: String) -> ComposerRefusal? {
        if case .refused(let refusal) = read(draft) { return refusal }
        return nil
    }

    /// The text to send for a draft `validate` accepted: invisible
    /// characters removed, a menu command in the program's own form, and
    /// exactly one trailing space, which keeps a final `/name` or `@path`
    /// from leaving a completion popup open when Enter arrives.
    func outgoingText(_ draft: String) -> String {
        let clean = TerminalTextSafety.normalizingNewlines(Self.removingInvisibles(draft))
        let body: String
        switch read(draft) {
        case .command(let command, let arguments):
            let prefix =
                switch command.kind {
                case .compact: "/"
                case .skill(let prefix): prefix
                }
            body = arguments.isEmpty ? prefix + command.name : "\(prefix)\(command.name) \(arguments)"
        case .text, .refused:
            body = clean
        }
        return Self.trimmingTrailingWhitespace(body) + " "
    }

    func read(_ draft: String) -> Reading {
        let clean = Self.removingInvisibles(draft)
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalTextSafety.containsOnlySafeScalars(clean) else {
            return .refused(.unsafeText("The message contains terminal control characters."))
        }
        if trimmed.hasPrefix("!") {
            return .refused(
                .unsafeText("A message starting with ! runs a shell command. Open the terminal to run one."))
        }
        if program == .claude, Self.claudeExitWords.contains(trimmed.lowercased()) {
            return .refused(.unsafeText("Sending this would exit Claude Code. Open the terminal to exit."))
        }
        guard trimmed.hasPrefix("/") else { return .text }
        let afterSlash = trimmed.dropFirst()
        let name = String(afterSlash.prefix { !$0.isWhitespace })
        // `/usr/bin/env` is a path in prose, not a command.
        if name.contains("/") { return .text }
        guard let command = commands.first(where: { $0.name == name }) else {
            return .refused(.unknownCommand(name))
        }
        guard command.isEnabled else {
            return .refused(.commandUnavailable("/\(name) is available once the Agent is idle."))
        }
        let arguments = afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return .command(command, arguments: arguments)
    }

    /// Removes the characters Claude Code strips before it submits, where
    /// any removal cancels the submit: tag characters, bidirectional
    /// controls, zero-width characters and variation selectors.
    static func removingInvisibles(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !isInvisible($0) })
        return String(scalars)
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE0000...0xE007F,  // tags
            0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C,  // bidi controls
            0x200B...0x200D, 0x2060, 0xFEFF,  // zero width
            0xFE00...0xFE0F, 0xE0100...0xE01EF:  // variation selectors
            true
        default:
            false
        }
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}
