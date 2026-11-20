import Foundation

// Joining and closing localized text without naming any language's marks, so
// a new language needs catalog values only (ADR 0041).

extension StringProtocol {
    /// Whether the text already closes its sentence in its own script: a full
    /// stop, question or exclamation mark (".", "。", "?", "।"), or an
    /// ellipsis where it was cut short.
    var endsSentence: Bool {
        guard let last = unicodeScalars.last else { return false }
        return last == "…" || last.properties.isSentenceTerminal
    }

    /// The text closed as a sentence with the language's full stop, unless it
    /// already ends one.
    var asSentence: String {
        endsSentence
            ? String(self)
            : String(localized: "\(String(self)).", comment: "Closes a text as a sentence when it has no closing mark yet")
    }

    /// Whether the text ends in a full-width mark ("。", "！"), which is drawn
    /// with its own space after it. Read from the mark's Unicode name.
    var endsInFullWidthMark: Bool {
        guard let name = unicodeScalars.last?.properties.name else { return false }
        return name.hasPrefix("IDEOGRAPHIC") || name.hasPrefix("FULLWIDTH")
    }
}

extension Sequence where Element: StringProtocol {
    /// Short phrases as one inline list in the user's language: “A, B” in
    /// English, “A、B” in Japanese.
    func joinedAsPhrases() -> String {
        joined(
            separator: String(
                localized: ", ",
                comment: "Separates the phrases of a list, as in “Ran 2 commands, Edited 2 files”."))
    }

    /// Whole sentences in a row as one text: a space between two of them,
    /// and none after a full-width mark. Each sentence decides for itself, so
    /// one still in English keeps its space inside a Japanese text.
    func joinedAsSentences() -> String {
        reduce(into: "") { text, sentence in
            if !text.isEmpty, !text.endsInFullWidthMark { text += " " }
            text += sentence
        }
    }
}
