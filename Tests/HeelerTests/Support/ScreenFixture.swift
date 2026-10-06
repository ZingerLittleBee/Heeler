import Foundation

@testable import Heeler

/// Captured Agent screens under `ChatFixtures/screens/`, addressed by stem:
/// `claude-27-n1-narrow-bash` reads `screens/claude/claude-27-n1-narrow-bash.ansi`.
enum ScreenFixture {
    static let claude = [
        "claude-00-trust", "claude-01-ready", "claude-02-c1-bash-blocked", "claude-03-c1-focus-no",
        "claude-03-bash-touch-permission", "claude-04-c1-tab-on-no", "claude-05-c1-pasted-feedback",
        "claude-06-c2-tab-on-yes", "claude-07-c2-pasted", "claude-08-c4-auq-q1",
        "claude-09-c4-toggled", "claude-10-c4-focus-next", "claude-11-c4-q2",
        "claude-12-c4-q2-digit3", "claude-13-c4-q2-pasted", "claude-14-c4-review",
        "claude-15-c9-enterplanmode", "claude-16-c6-exitplan-1", "claude-17-c6-digit3",
        "claude-18-c6-pasted", "claude-19-c6-exitplan-2", "claude-20-c6-pasted-2",
        "claude-21-c6-after", "claude-22-c7-edit", "claude-23-c7-after-esc",
        "claude-24-c8-webfetch", "claude-25-c8-after-digit3", "claude-26-c10-subagent-ask",
        "claude-27-n1-narrow-bash", "claude-28-n1-narrow-bash-later", "claude-29-c3-after-immediate",
        "claude-30-par-first", "claude-31-par-second",
    ]

    static let codex = [
        "codex-00-ready", "codex-01-x1-exec", "codex-02-x2-patch", "codex-03-x2-after-esc",
        "codex-04-x3-q1", "codex-05-x3-q2", "codex-06-x3-q2-up", "codex-07-x3-q2-pasted",
        "codex-08-x4-async-collapsed", "codex-09-x4-expanded", "codex-10-x4-after-digit",
        "codex-11-x4-after-skip", "codex-12-x5-narrow-exec", "codex-13-par-first",
        "codex-14-par-second",
    ]

    static let all = claude + codex

    static func path(_ stem: String) -> String {
        let program = stem.hasPrefix("codex-") ? "codex" : "claude"
        return "screens/\(program)/\(stem).ansi"
    }

    static func text(_ stem: String) throws -> String {
        try ChatFixture.text(path(stem))
    }

    static func screen(_ stem: String) throws -> ANSIScreen {
        ANSIScreenDecoder.decode(try text(stem))
    }

    /// The program that drew a capture.
    static func program(_ stem: String) -> ChatProgram {
        stem.hasPrefix("codex-") ? .codex : .claude
    }

    /// A screen built from raw ANSI rows, for states no capture shows yet.
    static func synthetic(_ rows: [String]) -> ANSIScreen {
        ANSIScreenDecoder.decode(rows.joined(separator: "\r\n"))
    }
}

/// SGR spellings for synthetic rows, matching what the captures use.
enum SGR {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let italic = "\u{1B}[3m"
    static let reverse = "\u{1B}[7m"

    static func fg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[38;2;\(red);\(green);\(blue)m"
    }

    static func bg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[48;2;\(red);\(green);\(blue)m"
    }

    /// Claude's dark-theme roles.
    static let claudeInactive = fg(153, 153, 153)
    static let claudeAccent = fg(177, 185, 249)
    static let claudePromptBorder = fg(136, 136, 136)

    /// A Claude input-box rule `width` cells wide.
    static func claudeRule(_ width: Int) -> String {
        reset + claudePromptBorder + String(repeating: "─", count: width) + reset
    }
}
