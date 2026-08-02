import Foundation

enum SnippetValidationError: Error, Equatable {
    case emptyBody
    case bodyTooLong(limit: Int)
    case unsupportedControlCharacters
}

/// A phrase the user writes once and reuses. `title` is optional: most
/// Snippets are short enough to be their own name, and only long templates
/// need one.
struct Snippet: Identifiable, Hashable, Codable, Sendable {
    static let bodyCharacterLimit = 4_000

    let id: UUID
    var title: String
    var body: String

    private init(id: UUID, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// The only way to build a Snippet. Normalisation and the character
    /// policy live here rather than at send time, so a Snippet that exists is
    /// a Snippet that is safe to send — the user finds out at the editor,
    /// where they can still fix it, not at the moment they tap it.
    static func make(id: UUID = UUID(), title: String, body: String) throws -> Snippet {
        let normalizedBody = TerminalTextSafety.normalizingNewlines(body)
        guard !normalizedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SnippetValidationError.emptyBody
        }
        guard normalizedBody.count <= bodyCharacterLimit else {
            throw SnippetValidationError.bodyTooLong(limit: bodyCharacterLimit)
        }
        guard TerminalTextSafety.containsOnlySafeScalars(normalizedBody) else {
            throw SnippetValidationError.unsupportedControlCharacters
        }
        return Snippet(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: normalizedBody)
    }

    /// What the row's first line shows. A Snippet without a Title has nothing
    /// to put there, so its body takes the place instead of a blank.
    var displayTitle: String {
        title.isEmpty ? body : title
    }

    /// What the row's second line shows, or nil when the first line is
    /// already the body and repeating it would say nothing.
    var displaySubtitle: String? {
        title.isEmpty ? nil : body
    }
}
