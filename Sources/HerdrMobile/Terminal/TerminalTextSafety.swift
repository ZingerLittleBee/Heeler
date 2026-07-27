import Foundation

/// The one place that decides what arbitrary text may look like before it is
/// allowed to reach a pane, and how it is framed on the wire. Terminal Paste
/// and Snippets both go through here so they cannot drift into different
/// answers to the same question.
enum TerminalTextSafety {
    /// Tab, line feed, and carriage return are the only control characters
    /// text may carry. Everything else — escapes above all — would be read as
    /// a command by the remote terminal rather than as content.
    static func containsOnlySafeScalars(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                true
            default:
                scalar.properties.generalCategory != .control
            }
        }
    }

    /// Collapses CRLF and lone CR to LF.
    ///
    /// This is the difference that matters for Snippets: the Enter key sends
    /// CR (0x0D), so a carriage return that came in with text pasted from
    /// elsewhere is a submit byte in disguise. LF is not.
    static func normalizingNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func isMultiline(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }
}

/// DECSET 2004 framing. Wrapping text tells the remote application it was
/// pasted, so a TUI can take it as one block instead of interpreting each
/// newline as its own key event — and agents that collapse large pastes get
/// the chance to do so.
enum TerminalBracketedPaste {
    static let start = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
    static let end = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])

    /// The bytes to write for `text`, framed only when the remote application
    /// asked for framing. Without DECSET 2004 the markers would be echoed as
    /// literal garbage, which is worse than the problem they solve.
    static func encode(_ text: String, bracketed: Bool) -> Data {
        let body = Data(text.utf8)
        guard bracketed else { return body }
        return start + body + end
    }
}
