import Foundation
import Testing

@testable import Heeler

@Suite("Chat transcript cache")
struct ChatTranscriptCacheTests {
    private static let hostA = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000A")!
    private static let hostB = UUID(uuidString: "6F1D5C2A-0000-4000-8000-00000000000B")!

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_791_266_400)
    }

    private struct Fixture {
        let root: URL
        let clock = Clock()
        let cache: FileChatTranscriptCache

        init(policy: ChatCachePolicy = ChatCachePolicy()) {
            root = FileManager.default.temporaryDirectory
                .appending(path: "ChatCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            let clock = clock
            cache = FileChatTranscriptCache(root: root, policy: policy, now: { clock.now })
        }

        func fileURL(_ key: ChatCacheKey) -> URL {
            root.appending(path: "v1/\(key.hostID.uuidString.lowercased())/\(key.storageName).json")
        }

        func setModified(_ key: ChatCacheKey, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL(key).path)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func key(_ host: UUID = hostA, _ id: String = "e951205e-24af-4a5e-baa7-3ccbebd2de2c")
        -> ChatCacheKey
    {
        ChatCacheKey(hostID: host, herdrSession: "", program: .claude, conversationID: id)
    }

    private static func document(
        _ key: ChatCacheKey, entries count: Int = 3, text: String = "hello"
    ) -> ChatCacheDocument {
        ChatCacheDocument(
            key: key, adapterRevision: 1, transcriptPath: "/home/dev/.claude/projects/-k/s.jsonl",
            head: Data(#"{"type":"mode"}"#.utf8), coverageStart: 0,
            coverageEnd: UInt64(count * 100), reachedStart: true,
            title: "Fix the build",
            entries: (0..<count).map { index in
                ChatEntry(
                    id: ChatEntryID("e\(index)"), sourceOffset: UInt64(index * 100),
                    content: .assistant(ChatAssistantMessage(text: "\(text) \(index)")))
            },
            savedAt: Date(timeIntervalSince1970: 1_791_266_400))
    }

    @Test func savedDocumentsLoadBackWhole() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let document = Self.document(Self.key())

        #expect(await fixture.cache.load(Self.key()) == .miss)
        await fixture.cache.save(document)

        #expect(await fixture.cache.load(Self.key()) == .hit(document))
        // File protection is requested on write; the Simulator does not
        // report it back, so it is checked on a device only.
    }

    @Test func fileNamesRevealNoIdentifiers() {
        let key = ChatCacheKey(
            hostID: Self.hostA, socketLocation: .namedSession("work"),
            reference: ConversationReference(program: .codex, sessionID: "01a10f87-e025-7fb1-8974-8dd09937767a"))
        #expect(key.herdrSession == "name:work")
        #expect(key.storageName.count == 64)
        #expect(!key.storageName.contains("01a10f87"))
        #expect(key.storageName != Self.key().storageName)
    }

    @Test func undecodableAndMismatchedDocumentsAreDropped() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        try Data("not json".utf8).write(to: fixture.fileURL(Self.key()))

        #expect(await fixture.cache.load(Self.key()) == .miss)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL(Self.key()).path))

        // A document filed under another key's name is not that key's.
        let other = Self.key(Self.hostA, "01a10f87-e025-7fb1-8974-8dd09937767a")
        await fixture.cache.save(Self.document(Self.key()))
        try FileManager.default.moveItem(at: fixture.fileURL(Self.key()), to: fixture.fileURL(other))
        #expect(await fixture.cache.load(other) == .miss)
    }

    @Test func removingAHostDeletesItsDocumentsAndRefusesLateSaves() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key(Self.hostA)))
        await fixture.cache.save(Self.document(Self.key(Self.hostB)))

        await fixture.cache.retainHosts([Self.hostB])
        // A save that raced the removal cannot bring the Host's cache back.
        await fixture.cache.save(Self.document(Self.key(Self.hostA)))

        #expect(await fixture.cache.load(Self.key(Self.hostA)) == .miss)
        #expect(await fixture.cache.load(Self.key(Self.hostB)) != .miss)
        let hosts = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appending(path: "v1").path)
        #expect(hosts == [Self.hostB.uuidString.lowercased()])
    }

    @Test func clearingRemovesEverything() async {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        #expect(await fixture.cache.diskUsage() > 0)

        await fixture.cache.removeAll()

        #expect(await fixture.cache.diskUsage() == 0)
        #expect(await fixture.cache.load(Self.key()) == .miss)
    }

    @Test func documentsExpireAfterThirtyDays() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        await fixture.cache.save(Self.document(Self.key()))
        try fixture.setModified(Self.key(), fixture.clock.now)

        fixture.clock.now = fixture.clock.now.addingTimeInterval(29 * 86_400)
        await fixture.cache.prune()
        #expect(await fixture.cache.load(Self.key()) != .miss)

        // Loading refreshed the date; thirty days on from that, it expires.
        fixture.clock.now = fixture.clock.now.addingTimeInterval(31 * 86_400)
        await fixture.cache.prune()
        #expect(await fixture.cache.load(Self.key()) == .miss)
    }

    @Test func overBudgetEvictsTheLeastRecentlyUsed() async throws {
        let size = try JSONEncoder().encode(Self.document(Self.key())).count
        let fixture = Fixture(
            policy: ChatCachePolicy(
                totalBudget: Int64(size * 3 + size / 2), lowWater: Int64(size * 2 + size / 2)))
        defer { fixture.cleanUp() }
        let keys = (0..<4).map { Self.key(Self.hostA, "0000000\($0)-0000-4000-8000-000000000000") }
        for (index, key) in keys.prefix(3).enumerated() {
            await fixture.cache.save(Self.document(key))
            try fixture.setModified(key, fixture.clock.now.addingTimeInterval(Double(index - 10)))
        }
        // The oldest is read, so the second oldest becomes least recent.
        _ = await fixture.cache.load(keys[0])

        await fixture.cache.save(Self.document(keys[3]))

        #expect(await fixture.cache.load(keys[1]) == .miss)
        #expect(await fixture.cache.load(keys[0]) != .miss)
        #expect(await fixture.cache.load(keys[3]) != .miss)
    }

    @Test func anOversizedDocumentKeepsItsNewestEntries() async throws {
        let full = Self.document(Self.key(), entries: 200, text: String(repeating: "w", count: 200))
        let fullSize = try JSONEncoder().encode(full).count
        let fixture = Fixture(policy: ChatCachePolicy(maxDocumentBytes: fullSize / 2))
        defer { fixture.cleanUp() }

        await fixture.cache.save(full)

        guard case .hit(let saved) = await fixture.cache.load(Self.key()) else {
            Issue.record("expected the trimmed document")
            return
        }
        #expect(saved.entries.count < 200)
        #expect(saved.entries.last == full.entries.last)
        #expect(!saved.reachedStart)
        #expect(saved.coverageStart == saved.entries.first?.sourceOffset)
    }

    @Test func leftoversOutsideTheCurrentVersionArePruned() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let stale = fixture.root.appending(path: "v0/old.json")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: stale)
        let junk = fixture.root.appending(path: "v1/not-a-host/x.json")
        try FileManager.default.createDirectory(
            at: junk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: junk)

        await fixture.cache.prune()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func theVolatileCacheFollowsTheSameHostRule() async {
        let cache = VolatileChatTranscriptCache()
        await cache.save(Self.document(Self.key(Self.hostA)))
        await cache.retainHosts([Self.hostB])
        await cache.save(Self.document(Self.key(Self.hostA)))

        #expect(await cache.load(Self.key(Self.hostA)) == .miss)
        await cache.save(Self.document(Self.key(Self.hostB)))
        #expect(await cache.load(Self.key(Self.hostB)) == .hit(Self.document(Self.key(Self.hostB))))
    }
}
