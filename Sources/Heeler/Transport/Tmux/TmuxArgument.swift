import Foundation

/// One argument of a tmux command, written so that tmux reads back exactly
/// the text it holds (ADR 0045). Pure.
enum TmuxArgument {
    /// tmux's double-quoted form, for a line tmux's command parser reads, such
    /// as a control client's command. `"`, `\`, `$`, `~`, `#`, `{`, `}` and
    /// `;` are escaped, and a control character is written as `\n`, `\r`, `\t`
    /// or `\ooo`, so the line never holds a line break. tmux 3.3a reads each
    /// of these back as the character itself.
    static func quoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"", "\\", "$", "~", "#", "{", "}", ";":
                quoted += "\\\(scalar)"
            case "\n":
                quoted += "\\n"
            case "\r":
                quoted += "\\r"
            case "\t":
                quoted += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                let octal = String(scalar.value, radix: 8)
                quoted += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            default:
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// An argument of a one-shot command, which tmux gets as an argv word and
    /// does not parse: the text as it is, except that a trailing `;` is
    /// escaped. tmux takes an argv word ending in `;` as the end of a command,
    /// drops the `;`, and reads a word ending in `\;` as ending in `;`.
    static func oneShot(_ text: String) -> String {
        guard text.hasSuffix(";") else { return text }
        return String(text.dropLast()) + "\\;"
    }
}
