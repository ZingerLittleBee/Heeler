import Foundation
import Testing

@testable import Heeler

/// The adapters the app reads transcripts with, run through the engine
/// against captured files.
@Suite("Chat standard adapters")
struct ChatStandardAdapterTests {
    @Test func claudeFollowsACapturedSessionAsTheReducerProjectsIt() async throws {
        let sessionID = "faf3ddf8-b1aa-44b1-8285-b062ad473e0d"
        let cwd = "/private/tmp/heeler-tmp-chat/probe-claude"
        let fixture = "claude/probe1-transcript.jsonl"
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let files = VirtualHostFiles(home: "/Users/developer")
        let path = "/Users/developer/.claude/projects/"
            + "\(ClaudeProjectKey.key(forDirectory: cwd))/\(sessionID).jsonl"
        await files.write(try ChatFixture.data(fixture), at: path)
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .claude, sessionID: sessionID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .claude, conversationID: sessionID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter,
            now: { Date() })

        let snapshot = await engine.open(
            directories: [cwd], context: ChatProjectionContext(activity: .idle))

        var reducer = ClaudeTranscriptReducer(role: .main)
        reducer.append(try ChatFixture.lines(fixture))
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: path))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
    }

    @Test func codexFollowsACapturedRolloutAsTheReducerProjectsIt() async throws {
        let threadID = CodexProbe.probe2ID
        let fixture = "codex/probe2-rollout.jsonl"
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .codex))
        let files = VirtualHostFiles(home: "/Users/developer")
        let path = Self.codexPath(threadID: threadID)
        await files.write(try ChatFixture.data(fixture), at: path)
        let engine = Self.codexEngine(threadID: threadID, files: files, adapter: adapter)

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        var reducer = CodexRolloutReducer(rolloutID: threadID)
        reducer.append(try ChatFixture.lines(fixture))
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: path))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
    }

    @Test func codexExplainsARolloutInAHistoryModeItCannotRead() async throws {
        let threadID = CodexProbe.probe2ID
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .codex))
        let files = VirtualHostFiles(home: "/Users/developer")
        let meta = #"{"timestamp":"2026-10-06T00:00:00.000Z","type":"session_meta","payload":{"id":""#
            + threadID + #"","cwd":"/w","history_mode":"tiered"}}"#
        await files.write(Data((meta + "\n").utf8), at: Self.codexPath(threadID: threadID))
        let engine = Self.codexEngine(threadID: threadID, files: files, adapter: adapter)

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        guard case .unavailable(.unsupportedFormat(let format)) = snapshot.phase else {
            Issue.record("expected an unsupported format, got \(snapshot.phase)")
            return
        }
        #expect(format.contains("history mode"))
    }

    @Test func eachProgramComparesEchoesTheWayItRecordsPrompts() throws {
        let claude = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let codex = try #require(ChatTranscriptAdapter.standard(for: .codex))
        #expect(claude.echoKey("Fix it\r\nplease ") == "Fix it\nplease")
        #expect(codex.echoKey("Fix \u{1B}[31mit\u{1B}[0m\r\nplease ") == "Fix it\nplease")
    }

    private static func codexPath(threadID: String) -> String {
        "/Users/developer/.codex/sessions/2026/10/06/rollout-2026-10-06T05-55-29-\(threadID).jsonl"
    }

    private static func codexEngine(
        threadID: String, files: VirtualHostFiles, adapter: ChatTranscriptAdapter
    ) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .codex, sessionID: threadID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .codex, conversationID: threadID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter,
            now: { Date() })
    }
}
