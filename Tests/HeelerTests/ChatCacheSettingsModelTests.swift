import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Chat cache settings")
struct ChatCacheSettingsModelTests {
    private static func makeCache() -> (FileChatTranscriptCache, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ChatCacheSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (FileChatTranscriptCache(root: root), { try? FileManager.default.removeItem(at: root) })
    }

    private static func document() -> ChatCacheDocument {
        ChatCacheDocument(
            key: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .claude,
                conversationID: "e951205e-24af-4a5e-baa7-3ccbebd2de2c"),
            adapterRevision: 1, transcriptPath: "/home/dev/.claude/projects/-k/s.jsonl",
            head: Data("{}".utf8), coverageStart: 0, coverageEnd: 10, reachedStart: true,
            title: nil,
            entries: [
                ChatEntry(
                    id: ChatEntryID("e0"), sourceOffset: 0,
                    content: .assistant(ChatAssistantMessage(text: "hello")))
            ],
            // Whole seconds: the cache stores seconds since 1970, which about
            // half of all `Date()` values do not survive bit for bit.
            savedAt: Date(timeIntervalSince1970: 1_791_266_400))
    }

    @Test func measuresWhatIsSavedAndClearsIt() async {
        let (cache, cleanup) = Self.makeCache()
        defer { cleanup() }
        let document = Self.document()
        await cache.save(document)
        #expect(await cache.load(document.key) == .hit(document))
        let model = ChatCacheSettingsModel(cache: cache)

        #expect(model.state == .measuring)
        #expect(!model.canClear)

        await model.refresh()

        guard case .measured(let bytes) = model.state else {
            Issue.record("expected a measurement, got \(model.state)")
            return
        }
        #expect(bytes > 0)
        #expect(model.canClear)

        await model.clear()

        #expect(model.state == .measured(0))
        #expect(!model.canClear)
        #expect(await cache.load(document.key) == .miss)
    }

    @Test func anEmptyCacheCannotBeCleared() async {
        let model = ChatCacheSettingsModel(cache: VolatileChatTranscriptCache())

        await model.refresh()

        #expect(model.state == .measured(0))
        #expect(!model.canClear)
    }
}
