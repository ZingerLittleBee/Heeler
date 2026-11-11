import Foundation

/// How Claude Code takes image paths out of a paste (2.1.319, read in its
/// paste handler and observed live 2026-11-10), so Chat can tell what it
/// records for a send.
///
/// The paste is read a line at a time. A line that splits, at each space
/// before a path, into paths alone gives up each image path as an image
/// and keeps each other path as a line of its own; any other line stays
/// whole, so an image path with words after it on its line stays text.
/// The input box then holds one `[Image #N]` per image, joined by spaces,
/// followed at once by the remaining lines that are not blank, joined by
/// line breaks. A path alone on the line above the words loses the line
/// break between them, and a path below them moves above them.
enum ClaudeImagePaste {
    /// The prompt Claude Code records for a paste of `text`, with each
    /// `[Image #N]` back as the path it came from, as Chat restores a
    /// record; nil when no line gives up an image. It assumes Claude Code
    /// can read every image path, as it can a staged image; one it cannot
    /// read stays text where it was.
    static func recordedText(_ text: String) -> String? {
        var images: [String] = []
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: #/[ ](?=["']?(?:\/|[A-Za-z]:\\))/#).filter { !isBlank($0) }
            if parts.count > 1, !parts.allSatisfy(isPathLike) {
                lines.append(line)
                continue
            }
            for part in parts {
                if let path = imagePath(part) {
                    images.append(path)
                } else {
                    lines.append(part)
                }
            }
        }
        guard !images.isEmpty else { return nil }
        return (images.joined(separator: " ") + lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a piece of a line reads as a path: quoted, or an absolute
    /// path with no unescaped space unless it names an image.
    private static func isPathLike(_ part: Substring) -> Bool {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(#/^(["'])(?:\/[^\/\r]+\/|[A-Za-z]:\\|\\\\)[^\r]*\1$/#) { return true }
        guard trimmed.contains(#/^(?:\/(?!\/)[^ \r\\\/]*(?:\\.[^ \r\\\/]*)*\/|[A-Za-z]:\\|\\\\)[^\r]*$/#) else {
            return false
        }
        return !trimmed.contains(#/[^\\][ ]/#) || imagePath(part) != nil
    }

    /// The image file a piece of a line names, unquoted and unescaped as
    /// Claude Code reads it; nil when it does not end in an image extension.
    private static func imagePath(_ part: Substring) -> String? {
        let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
        var unquoted = Substring(trimmed)
        if let first = trimmed.first, first == "\"" || first == "'", trimmed.last == first {
            unquoted = unquoted.dropFirst().dropLast()
        }
        let path = unescaped(unquoted)
        return path.contains(#/\.(?:png|jpe?g|gif|webp)$/#.ignoresCase()) ? path : nil
    }

    /// `text` with each backslash escape replaced by the character it
    /// escapes; a trailing backslash stays.
    private static func unescaped(_ text: Substring) -> String {
        var result = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            result.append(characters.next() ?? "\\")
        }
        return result
    }

    private static func isBlank(_ text: Substring) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }
}
