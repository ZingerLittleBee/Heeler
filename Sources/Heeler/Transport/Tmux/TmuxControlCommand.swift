import Foundation

/// One tmux command as a control-mode client writes it: one line, its words
/// quoted so that tmux's parser reads each back exactly (ADR 0045).
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

    /// A word as tmux's parser reads it back: as it is when it holds only
    /// letters, digits, `_` and `-`, and in tmux's double-quoted form
    /// (`TmuxArgument.quoted`) otherwise.
    static func quoted(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(isPlain) { return word }
        return TmuxArgument.quoted(word)
    }

    private static func isPlain(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-": true
        default: false
        }
    }
}
