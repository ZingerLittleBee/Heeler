import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Project files store")
struct ProjectFilesStoreTests {
    @Test func lazyExpansionFetchesEachDirectoryOnlyOnce() async throws {
        let root = "/workspace"
        let sources = entry(name: "Sources", path: "\(root)/Sources", kind: .directory)
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [.success([sources])],
                sources.path: [.success([entry(name: "main.swift", path: "\(sources.path)/main.swift")])],
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        await store.setDirectoryExpanded(sources.path, isExpanded: false)
        await store.setDirectoryExpanded(sources.path, isExpanded: true)

        #expect(await recorder.listCount(for: root) == 1)
        #expect(await recorder.listCount(for: sources.path) == 1)
        #expect(store.node(at: sources.path)?.state == .loaded)
    }

    @Test func refreshRefetchesTheRootAndExpandedDirectories() async throws {
        let root = "/workspace"
        let sources = entry(name: "Sources", path: "\(root)/Sources", kind: .directory)
        let refreshedSources = entry(name: "Sources", path: sources.path, kind: .directory)
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [.success([sources]), .success([refreshedSources])],
                sources.path: [
                    .success([entry(name: "old.swift", path: "\(sources.path)/old.swift")]),
                    .success([entry(name: "new.swift", path: "\(sources.path)/new.swift")]),
                ],
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        await store.refresh()

        #expect(await recorder.listCount(for: root) == 2)
        #expect(await recorder.listCount(for: sources.path) == 2)
        #expect(store.visibleChildren(of: sources.path).map(\.entry.name) == ["new.swift"])
    }

    @Test func refreshingTheRootRetainsCollapsedDirectoryCaches() async throws {
        let root = "/workspace"
        let sources = entry(name: "Sources", path: "\(root)/Sources", kind: .directory)
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [.success([sources]), .success([sources])],
                sources.path: [.success([entry(name: "main.swift", path: "\(sources.path)/main.swift")])],
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        await store.setDirectoryExpanded(sources.path, isExpanded: false)
        await store.refresh()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)

        #expect(await recorder.listCount(for: root) == 2)
        #expect(await recorder.listCount(for: sources.path) == 1)
        #expect(store.visibleChildren(of: sources.path).map(\.entry.name) == ["main.swift"])
    }

    @Test func failedListingCanBeRetried() async throws {
        let root = "/workspace"
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [
                    .failure(RemoteFileError.failure(message: "SFTP dropped")),
                    .success([entry(name: "README.md", path: "\(root)/README.md")]),
                ]
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        #expect(store.rootNode.state == .failed(message: "SFTP dropped"))

        await store.retryDirectory(at: root)
        #expect(store.rootNode.state == .loaded)
        #expect(store.visibleChildren(of: root).map(\.entry.name) == ["README.md"])
    }

    @Test func collapsingADirectoryAlsoCollapsesItsExpandedDescendants() async throws {
        let root = "/workspace"
        let sources = entry(name: "Sources", path: "\(root)/Sources", kind: .directory)
        let generated = entry(
            name: "Generated",
            path: "\(sources.path)/Generated",
            kind: .directory)
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [.success([sources])],
                sources.path: [.success([generated])],
                generated.path: [.success([entry(name: "wire.swift", path: "\(generated.path)/wire.swift")])],
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        await store.setDirectoryExpanded(generated.path, isExpanded: true)
        await store.setDirectoryExpanded(sources.path, isExpanded: false)

        #expect(!store.isDirectoryExpanded(sources.path))
        #expect(!store.isDirectoryExpanded(generated.path))

        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        // The descendant's cache is deliberately retained — reopening must be
        // instant and channel-free — but its disclosure must come back
        // collapsed rather than resurrect as a stuck, never-loading branch.
        #expect(store.node(at: generated.path)?.state == .loaded)
        #expect(!store.isDirectoryExpanded(generated.path))
    }

    @Test func refreshedRemovalClearsExpansionForADirectoryThatReturnsLater() async throws {
        let root = "/workspace"
        let sources = entry(name: "Sources", path: "\(root)/Sources", kind: .directory)
        let generated = entry(
            name: "Generated",
            path: "\(sources.path)/Generated",
            kind: .directory)
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [.success([sources])],
                sources.path: [.success([generated]), .success([]), .success([generated])],
                generated.path: [.success([entry(name: "wire.swift", path: "\(generated.path)/wire.swift")])],
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        await store.setDirectoryExpanded(sources.path, isExpanded: true)
        await store.setDirectoryExpanded(generated.path, isExpanded: true)
        await store.retryDirectory(at: sources.path)

        #expect(!store.isDirectoryExpanded(generated.path))

        await store.retryDirectory(at: sources.path)
        #expect(store.node(at: generated.path)?.state == .unloaded)
        #expect(!store.isDirectoryExpanded(generated.path))
    }

    @Test func hiddenFilesStayOutOfTheVisibleTreeUntilEnabled() async throws {
        let root = "/workspace"
        let recorder = ProjectFilesRecorder(
            listings: [
                root: [
                    .success([
                        entry(name: ".env", path: "\(root)/.env"),
                        entry(name: "Package.swift", path: "\(root)/Package.swift"),
                    ])
                ]
            ])
        let store = ProjectFilesStore(root: root, hostName: "Mac", access: access(recorder))

        await store.load()
        #expect(store.visibleChildren(of: root).map(\.entry.name) == ["Package.swift"])

        store.showsHiddenFiles = true
        #expect(store.visibleChildren(of: root).map(\.entry.name) == [".env", "Package.swift"])
    }

    private func access(_ recorder: ProjectFilesRecorder) -> RemoteFileAccess {
        RemoteFileAccess(
            listDirectory: { path in try await recorder.list(path) },
            readFile: { _, _ in throw RemoteFileError.failure(message: "Unused in this test.") },
            writeFile: { _, _ in throw RemoteFileError.failure(message: "Unused in this test.") },
            statFile: { _ in nil })
    }

    private func entry(
        name: String,
        path: String,
        kind: RemoteFileEntry.Kind = .file
    ) -> RemoteFileEntry {
        RemoteFileEntry(name: name, path: path, kind: kind, sizeBytes: nil, modified: nil)
    }
}

private actor ProjectFilesRecorder {
    private var listings: [String: [Result<[RemoteFileEntry], Error>]]
    private var counts: [String: Int] = [:]

    init(listings: [String: [Result<[RemoteFileEntry], Error>]]) {
        self.listings = listings
    }

    func list(_ path: String) throws -> [RemoteFileEntry] {
        counts[path, default: 0] += 1
        guard var plans = listings[path], !plans.isEmpty else { return [] }
        let plan = plans.removeFirst()
        listings[path] = plans
        return try plan.get()
    }

    func listCount(for path: String) -> Int {
        counts[path, default: 0]
    }
}
