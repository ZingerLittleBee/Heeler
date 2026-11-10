import Foundation

/// One tmux command as a control-mode client writes it: one line, its words
/// quoted so that tmux's parser reads each back exactly (ADR 0043).
///
/// A control client matches each reply to the line that asked by order alone,
/// so a command must make exactly one reply: no `;` between commands, and no
/// command that queues others on the client (`if-shell`, `source-file`,
/// `run-shell`). Words are free text.
struct TmuxControlCommand: Equatable, Sendable {
    let words: [String]

    init(_ words: [String]) {
        self.words = words
    }

    /// The line without its newline. It never holds one: every control
    /// character in a word is written as an escape.
    var line: String {
        words.map(Self.quoted).joined(separator: " ")
    }

    /// A word as tmux 3.3a's parser reads it back: as it is when it holds
    /// nothing the parser treats specially, in single quotes when it can be,
    /// and in double quotes with escapes otherwise. Inside double quotes tmux
    /// expands `$` and `~`, and reads `\ooo` octal escapes.
    static func quoted(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(isPlain) { return word }
        if !word.unicodeScalars.contains(where: { $0 == "'" || isControl($0) }) { return "'\(word)'" }
        var quoted = "\""
        for scalar in word.unicodeScalars {
            switch scalar {
            case "\\", "\"", "$", "~":
                quoted += "\\\(scalar)"
            case _ where isControl(scalar):
                let octal = String(scalar.value, radix: 8)
                quoted += "\\" + String(repeating: "0", count: max(0, 3 - octal.count)) + octal
            default:
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-": true
        default: false
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
