import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Snippet store")
struct SnippetStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-snippets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func addPersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        try store.add(Snippet.make(title: "Tests", body: "make test"))
        try store.add(Snippet.make(title: "", body: "继续"))

        let reloaded = SnippetStore(defaults: defaults)
        #expect(reloaded.snippets.map(\.body) == ["make test", "继续"])
        #expect(reloaded.catalogLoadError == nil)
    }

    @Test func updateReplacesInPlaceAndKeepsOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        let first = try Snippet.make(title: "One", body: "one")
        try store.add(first)
        try store.add(Snippet.make(title: "Two", body: "two"))

        try store.update(Snippet.make(id: first.id, title: "Uno", body: "uno"))

        #expect(store.snippets.map(\.title) == ["Uno", "Two"])
    }

    @Test func updatingAnUnknownSnippetFails() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        #expect(throws: SnippetStoreError.unknownSnippet) {
            try store.update(Snippet.make(title: "Ghost", body: "boo"))
        }
    }

    @Test func removeDropsOnlyTheAddressedSnippet() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        let doomed = try Snippet.make(title: "", body: "doomed")
        try store.add(Snippet.make(title: "", body: "kept"))
        try store.add(doomed)

        try store.remove(doomed.id)

        #expect(store.snippets.map(\.body) == ["kept"])
        #expect(SnippetStore(defaults: defaults).snippets.map(\.body) == ["kept"])
    }

    @Test func manualOrderSurvivesAReload() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        for body in ["a", "b", "c"] {
            try store.add(Snippet.make(title: "", body: body))
        }

        try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(store.snippets.map(\.body) == ["c", "a", "b"])
        #expect(SnippetStore(defaults: defaults).snippets.map(\.body) == ["c", "a", "b"])
    }

    @Test func searchMatchesTitleAndBodyCaseInsensitively() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = SnippetStore(defaults: defaults)
        try store.add(Snippet.make(title: "Review", body: "have a look"))
        try store.add(Snippet.make(title: "Ship", body: "please REVIEW and merge"))
        try store.add(Snippet.make(title: "", body: "unrelated"))

        #expect(store.matching("review").count == 2)
        #expect(store.matching("  ").count == 3)
        #expect(store.matching("nothing here").isEmpty)
    }

    @Test func unreadableCatalogRefusesWritesRatherThanOverwriting() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "snippets")

        let store = SnippetStore(defaults: defaults)
        #expect(store.catalogLoadError == .catalogUnreadable)
        #expect(store.snippets.isEmpty)

        #expect(throws: SnippetStoreError.catalogUnreadable) {
            try store.add(Snippet.make(title: "", body: "new"))
        }
        // The undecodable bytes are still there: a write would have turned a
        // recoverable catalog into loss.
        #expect(defaults.data(forKey: "snippets") == corrupt)
    }
}
