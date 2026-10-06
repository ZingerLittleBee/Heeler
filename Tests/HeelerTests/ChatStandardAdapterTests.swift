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
}
