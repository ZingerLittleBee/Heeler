import Foundation

/// The YAML-subset frontmatter parser for skill files. Deliberately lenient
/// (the standing rule for remote-authored input): unknown keys are skipped,
/// malformed lines are ignored, and a file without frontmatter parses to
/// empty fields rather than failing the whole probe.
struct SkillFrontmatter: Equatable, Sendable {
    var name: String?
    var description: String?

    /// Parses the frontmatter block of `content`: the lines between the
    /// leading `---` fence and the next `---`/`...` fence. Handles the shapes
    /// real skill files use — plain scalars, quoted scalars, folded (`>`)
    /// and literal (`|`) blocks, and indented plain-scalar continuations.
    static func parse(_ content: String) -> SkillFrontmatter {
        // CRLF first: "\r\n" is a single grapheme cluster in Swift, so a
        // split on "\n" would sail right past every Windows line ending.
        var lines = TerminalTextSafety.normalizingNewlines(content)
            .split(separator: "\n", omittingEmptySubsequences: false)[...]
        // Strip a BOM so the fence check sees the dashes themselves.
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines = [first.dropFirst()] + lines.dropFirst()
        }
        while let first = lines.first, first.trimmed.isEmpty {
            lines = lines.dropFirst()
        }
        guard lines.first?.trimmed == "---" else { return SkillFrontmatter() }
        lines = lines.dropFirst()

        var fields: [String: String] = [:]
        var currentKey: String?
        var blockLines: [String] = []
        var blockStyle: BlockStyle?

        func finalizeCurrent() {
            guard let key = currentKey else { return }
            if let style = blockStyle {
                let joined = blockLines.joined(
                    separator: style == .literal ? "\n" : " ")
                fields[key] = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentKey = nil
            blockLines = []
            blockStyle = nil
        }

        for line in lines {
            let trimmed = line.trimmed
            if trimmed == "---" || trimmed == "..." { break }

            if let (key, rest) = topLevelField(line) {
                finalizeCurrent()
                currentKey = key
                if let style = BlockStyle(indicator: rest) {
                    blockStyle = style
                } else {
                    fields[key] = unquote(rest)
                }
                continue
            }

            // Indented lines continue the current field; without one they are
            // noise (nested mappings, list items) and are skipped.
            guard let key = currentKey, line.first?.isWhitespace == true else {
                continue
            }
            if blockStyle != nil {
                blockLines.append(String(trimmed))
            } else if !trimmed.isEmpty {
                // A wrapped plain scalar: YAML folds it with a space.
                let existing = fields[key] ?? ""
                fields[key] = existing.isEmpty ? String(trimmed) : existing + " " + trimmed
            }
        }
        finalizeCurrent()

        return SkillFrontmatter(
            name: nonEmpty(fields["name"]),
            description: nonEmpty(fields["description"]))
    }

    private enum BlockStyle: Equatable {
        case literal
        case folded

        /// `|`, `>`, and their chomping variants (`|-`, `>+`, …).
        init?(indicator: String) {
            switch indicator.first {
            case "|" where indicator.count <= 2: self = .literal
            case ">" where indicator.count <= 2: self = .folded
            default: return nil
            }
        }
    }

    /// `key: value` at zero indentation; keys are the identifier charset the
    /// skill formats actually use.
    private static func topLevelField(_ line: Substring) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
            return nil
        }
        let key = line[..<colon]
        guard
            key.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
            })
        else { return nil }
        let rest = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return (String(key), rest)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Substring {
    fileprivate var trimmed: Substring {
        var slice = self
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}
