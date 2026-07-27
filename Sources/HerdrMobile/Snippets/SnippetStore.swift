import Foundation
import Observation

enum SnippetStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Snippet id the catalog does not contain.
    case unknownSnippet
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
}

/// Owns the Snippet catalog: add/edit/remove/reorder plus persistence. One
/// global set, deliberately not scoped to a Host or an Agent — these describe
/// how the user talks, not what they are talking to.
///
/// Order is the user's, never usage-derived: the value of a Snippet is that
/// your thumb knows where it is, and a list that re-sorts itself destroys
/// exactly that.
@MainActor
@Observable
final class SnippetStore {
    private static let defaultsKey = "snippets"
    private static let catalogVersion = 1

    private struct PersistedCatalog: Codable {
        let version: Int
        let snippets: [Snippet]
    }

    private(set) var snippets: [Snippet]
    private(set) var catalogLoadError: SnippetStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            snippets = []
            return
        }
        do {
            let catalog = try JSONDecoder().decode(PersistedCatalog.self, from: data)
            guard catalog.version == Self.catalogVersion else {
                throw SnippetStoreError.catalogUnreadable
            }
            snippets = catalog.snippets
        } catch {
            snippets = []
            catalogLoadError = .catalogUnreadable
        }
    }

    func add(_ snippet: Snippet) throws {
        try ensureCatalogIsWritable()
        snippets.append(snippet)
        try persist()
    }

    func update(_ snippet: Snippet) throws {
        try ensureCatalogIsWritable()
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            throw SnippetStoreError.unknownSnippet
        }
        snippets[index] = snippet
        try persist()
    }

    func remove(_ id: Snippet.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = snippets.firstIndex(where: { $0.id == id }) else {
            throw SnippetStoreError.unknownSnippet
        }
        snippets.remove(at: index)
        try persist()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try ensureCatalogIsWritable()
        snippets.move(fromOffsets: source, toOffset: destination)
        try persist()
    }

    /// Case- and diacritic-insensitive match over both the Title and the body,
    /// because a user searching for "review" may have written it in either.
    func matching(_ query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        return snippets.filter { snippet in
            snippet.title.localizedStandardContains(trimmed)
                || snippet.body.localizedStandardContains(trimmed)
        }
    }

    private func ensureCatalogIsWritable() throws {
        if catalogLoadError != nil {
            throw SnippetStoreError.catalogUnreadable
        }
    }

    private func persist() throws {
        let encoded = try JSONEncoder().encode(
            PersistedCatalog(version: Self.catalogVersion, snippets: snippets))
        defaults.set(encoded, forKey: Self.defaultsKey)
    }
}
