import Foundation

/// What Grok Build's input box does with `/` beyond Chat's menu (ADR 0024):
/// its built-in commands, which keep their bare names over a skill's, and
/// the commands it reads anywhere in a message.
enum GrokSlashCommands {
    /// Every command and alias Grok Build 1.0.62 reserves, lowercased: those
    /// its slash-command guide lists, and those its pager keeps without
    /// listing them, such as `/help` and `/tasks` (the 1.0.62 binary and the
    /// 1.0.45 source). Grok offers a skill named like one only under a
    /// qualified name such as `/local:plan`, so a bare `/plan` runs the
    /// built-in. Regenerate on version bumps.
    static let builtIns: Set<String> = [
        "agents", "agents-dashboard", "always-approve", "announcements", "auto", "btw", "cd", "changelog",
        "chat", "clear", "cloud", "compact", "compact-mode", "config", "config-agents", "context",
        "context-window", "copy", "cost", "dashboard", "debug", "deep-research", "delete", "density", "docs",
        "doctor", "dream", "edit-prompt", "effort", "exit", "expand", "export", "feedback", "find", "flush",
        "fork", "full", "fullscreen", "gboom", "goal", "guides", "help", "history", "home", "hooks",
        "hooks-add", "hooks-list", "hooks-remove", "hooks-trust", "hooks-untrust", "howto", "imagine",
        "imagine-video", "import-claude", "info", "jump", "log", "login", "logout", "loop", "m",
        "marketplace", "mcps", "mem", "memory", "minimal", "ml", "model", "multiline", "new", "onboarding",
        "personas", "plan", "plan-view", "plugin", "plugins", "preferences", "prefs", "privacy", "queue",
        "quit", "recap", "release-notes", "reload-plugins", "remember", "rename", "resume", "rewind",
        "session-info", "sessions", "settings", "share", "show-plan", "skills", "status", "summarize", "t",
        "tasks", "terminal-check", "terminal-info", "terminal-setup", "theme", "timeline", "timestamps",
        "title", "toggle-mouse-reporting", "tour", "transcript", "tutorial", "undo", "usage", "view-plan",
        "vim-mode", "voice", "welcome", "workflow", "workflows", "yolo",
    ]

    /// What Grok Build's input box reads as more than a message, after the
    /// shared rules and its exit words and before the menu: `/goal` or
    /// `/btw` after the message's start, and `/compact` with a focus.
    static func refusal(_ clean: String, _ trimmed: String) -> ComposerRefusal? {
        let tokens = tokenNamesAfterTheStart(of: clean)
        // Grok checks `/goal` first: it refuses the message and leaves it in
        // its input box (`dispatch/prompt.rs`).
        if tokens.contains("goal") {
            return .unsafeText(
                "Grok Build runs /goal only at the start of a message and wouldn't send this. "
                    + "Set goals in the terminal.")
        }
        // It asks the rest of the message as a side question, which never
        // reaches the conversation (`slash/mid_text_hoist.rs`).
        if tokens.contains("btw") {
            return .unsafeText(
                "Grok Build would treat this as a /btw side question and keep it out of the conversation. "
                    + "Rephrase it, or ask in the terminal.")
        }
        // Grok 1.0.62 answers `/compact` with text after it with the toast
        // "/compact takes no arguments." and keeps the text in its box.
        // Checked before the menu, so a focus is refused while the Agent
        // works too.
        if isCompactWithFocus(trimmed) {
            return .commandUnavailable("Grok Build's /compact takes no focus. Send /compact on its own.")
        }
        return nil
    }

    /// The lowercased names of the `/` tokens in `text` after its start. A
    /// token is `/` at the start or after ASCII whitespace, then everything
    /// up to the next whitespace (`slash/mod.rs`
    /// `scan_inline_slash_tokens`), so `/btw,` names `btw,`. A token with
    /// only whitespace before it leads the message, which the menu reads.
    private static func tokenNamesAfterTheStart(of text: String) -> Set<String> {
        let scalars = Array(text.unicodeScalars)
        let leading = scalars.firstIndex { !$0.properties.isWhitespace }
        var names: Set<String> = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "/", index == 0 || asciiWhitespace.contains(scalars[index - 1]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, !scalars[end].properties.isWhitespace { end += 1 }
            if end > index + 1, index != leading {
                names.insert(String(String.UnicodeScalarView(scalars[(index + 1)..<end])).lowercased())
            }
            index = end
        }
        return names
    }

    /// What Rust's `u8::is_ascii_whitespace` accepts: Grok tests the byte
    /// before a `/` with it.
    private static let asciiWhitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0C}", "\r"]

    /// A leading `/compact` with text after it, read the way the menu reads
    /// a leading command.
    private static func isCompactWithFocus(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("/") else { return false }
        let afterSlash = trimmed.dropFirst()
        let name = afterSlash.prefix { !$0.isWhitespace }
        guard name == "compact" else { return false }
        return !afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
