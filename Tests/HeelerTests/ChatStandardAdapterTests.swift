import Foundation
import Testing

@testable import Heeler

/// The adapters the app reads transcripts with, run through the engine
/// against captured files and an OpenCode store.
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

    /// Claude Code's list loads earlier history by itself as Load Earlier
    /// Messages does: it reads on to the prompt of a turn that opens more
    /// than 4 MiB above the tail window, and leaves nothing to the user.
    @Test func claudeLoadsALongTurnsPromptByItselfAsTheUserWould() async throws {
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let session = LongClaudeTurn()
        let cwd = "/home/dev/proj"
        let path = "/Users/developer/.claude/projects/"
            + "\(ClaudeProjectKey.key(forDirectory: cwd))/\(LongClaudeTurn.sessionID).jsonl"
        func engine(_ files: VirtualHostFiles) -> ChatConversationEngine {
            ChatConversationEngine(
                reference: ConversationReference(program: .claude, sessionID: LongClaudeTurn.sessionID),
                cacheKey: ChatCacheKey(
                    hostID: UUID(), herdrSession: "", program: .claude, conversationID: LongClaudeTurn.sessionID),
                files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter, now: { Date() })
        }
        let automaticFiles = VirtualHostFiles(home: "/Users/developer")
        let userFiles = VirtualHostFiles(home: "/Users/developer")
        await automaticFiles.write(session.text, at: path)
        await userFiles.write(session.text, at: path)
        let byItself = engine(automaticFiles)
        let asked = engine(userFiles)
        let context = ChatProjectionContext(activity: .idle)
        let opened = await byItself.open(directories: [cwd], context: context)
        _ = await asked.open(directories: [cwd], context: context)
        try #require(opened.transcript.turns.isEmpty)
        let windowStart = try #require(opened.transcript.entries.map(\.sourceOffset).min())
        try #require(windowStart - session.promptOffset > 4 << 20)
        await automaticFiles.clearRecords()
        await userFiles.clearRecords()

        var automatic = await byItself.loadOlder(context: context, automatic: true)
        while automatic.older == .loading {
            automatic = await byItself.loadOlder(context: context, automatic: true)
        }
        var user = await asked.loadOlder(context: context)
        while user.older == .loading {
            user = await asked.loadOlder(context: context)
        }

        #expect(automatic.transcript.turns.map(\.firstEntryID).contains(LongClaudeTurn.prompt))
        #expect(automatic.transcript.turns == user.transcript.turns)
        #expect(automatic.transcript.entries == user.transcript.entries)
        #expect(!automatic.olderAwaitsUser)
        let userReads = await userFiles.reads
        #expect(await automaticFiles.reads == userReads)
    }

    /// OpenCode writes no file: Chat follows the session by querying its
    /// database, and shows the rows the query prints as the reducer
    /// projects them (ADR 0025).
    @Test func openCodeFollowsACapturedStore() async throws {
        let scenario = "patch"
        let store = try OpenCodeStore(scenario: scenario)
        let sessionID = try #require(try OpenCodeStoreFixture.named(scenario).sessionID).rawValue
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .opencode))
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .opencode, sessionID: sessionID),
            cacheKey: ChatCacheKey(
                hostID: UUID(), herdrSession: "", program: .opencode, conversationID: sessionID),
            files: store.files, cache: VolatileChatTranscriptCache(), adapter: adapter, now: { Date() })

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        // The probe's lines, each row at its `seq` as the record source
        // hands them on.
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(
            try ChatFixture.lines("opencode/rows-\(scenario).jsonl").map { line in
                guard case .row(let row) = OpenCodeLine(line.data) else { return line }
                return ChatLine(offset: UInt64(row.seq), data: line.data)
            })
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: "opencode:\(sessionID)"))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
        #expect(snapshot.transcript.turns == expected.turns)
        // One query read the whole session.
        #expect(await store.queries.count == 1)
    }

    @Test func antigravityFollowsACapturedConversationAsTheReducerProjectsIt() async throws {
        let conversationID = "00000000-0000-4000-8000-000000000002"
        let fixture = "agy/approvals.jsonl"
        let adapter = try #require(ChatTranscriptAdapter.standard(for: .agy))
        let files = VirtualHostFiles(home: "/Users/developer")
        let path = "/Users/developer/.gemini/antigravity-cli/brain/\(conversationID)/.system_generated/logs/transcript_full.jsonl"
        await files.write(try ChatFixture.data(fixture), at: path)
        let engine = ChatConversationEngine(
            reference: ConversationReference(program: .agy, sessionID: conversationID),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .agy, conversationID: conversationID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: adapter, now: { Date() })

        let snapshot = await engine.open(directories: [], context: ChatProjectionContext(activity: .idle))

        var reducer = AgyTranscriptReducer()
        reducer.append(try ChatFixture.lines(fixture))
        let expected = reducer.transcript(ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: path))
        #expect(snapshot.older == .reachedStart)
        #expect(!expected.entries.isEmpty)
        #expect(snapshot.transcript.entries == expected.entries)
        #expect(snapshot.transcript.turns == expected.turns)
    }

    @Test func eachProgramComparesEchoesTheWayItRecordsPrompts() throws {
        let claude = try #require(ChatTranscriptAdapter.standard(for: .claude))
        let codex = try #require(ChatTranscriptAdapter.standard(for: .codex))
        let grok = try #require(ChatTranscriptAdapter.standard(for: .grok))
        let agy = try #require(ChatTranscriptAdapter.standard(for: .agy))
        // Antigravity CLI trims the space Chat adds, and in plan mode
        // records the prompt after `/plan `.
        #expect(agy.echoKey("Fix it\r\nplease ") == agy.echoKey("/plan Fix it\nplease"))
        #expect(agy.echoClockStopsWhileWorking)
        #expect(claude.echoKey("Fix it\r\nplease ") == "Fix it\nplease")
        #expect(codex.echoKey("Fix \u{1B}[31mit\u{1B}[0m\r\nplease ") == "Fix it\nplease")
        // Grok Build records the space Chat adds, and a prompt sent while it
        // works only once that prompt's turn starts.
        #expect(grok.echoKey("Fix it\r\nplease ") == "Fix it\nplease")
        #expect(grok.echoClockStopsWhileWorking)
        #expect(!claude.echoClockStopsWhileWorking && !codex.echoClockStopsWhileWorking)
    }

    /// A Claude Code session in the compact JSON it writes: one short turn,
    /// then one whose 32 Bash calls each returned 200 KB, still running.
    /// The long turn's prompt starts 6.4 MB from the end of the file.
    private struct LongClaudeTurn {
        static let sessionID = "0b7c8d2e-5f41-4a6b-9c3d-2e1f0a9b8c7d"
        static let prompt = ChatEntryID("user:p1")

        private(set) var text = ""
        /// Where the long turn's prompt line starts.
        private(set) var promptOffset: UInt64 = 0
        private var parent = "null"

        init() {
            record("user", "p0", #""message":{"role":"user","content":"Hello"},"promptSource":"typed","origin":{"kind":"human"}"#)
            record("assistant", "a0", #""message":{"id":"m0","role":"assistant","content":[{"type":"text","text":"Hi."}]},"apiBlockIndex":0"#)
            record("system", "t0", #""subtype":"turn_duration","durationMs":900"#)
            promptOffset = UInt64(text.utf8.count)
            record(
                "user", "p1",
                #""message":{"role":"user","content":"Print every log in full"},"promptSource":"typed","origin":{"kind":"human"}"#)
            let output = String(repeating: "=", count: 200_000)
            for call in 0..<32 {
                record(
                    "assistant", "c\(call)",
                    #""message":{"id":"m\#(call + 1)","role":"assistant","content":[{"type":"tool_use","id":"toolu_\#(call)","name":"Bash","input":{"command":"cat log\#(call).txt"}}]},"apiBlockIndex":0"#)
                record(
                    "user", "r\(call)",
                    #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_\#(call)","content":"\#(output)"}]},"toolUseResult":{"stdout":"","stderr":"","interrupted":false}"#)
            }
        }

        private mutating func record(_ type: String, _ uuid: String, _ fields: String) {
            text += #"{"type":"\#(type)","uuid":"\#(uuid)","parentUuid":\#(parent),\#(fields)}"# + "\n"
            parent = #""\#(uuid)""#
        }
    }

    /// A scratch OpenCode store built from a captured one, queried the way a
    /// Host's is. Only queries reach it: there are no files to read.
    private actor OpenCodeStore {
        private let harness: OpenCodeSQLiteHarness
        private(set) var queries: [OpenCodeQuery] = []

        init(scenario: String) throws {
            harness = try OpenCodeSQLiteHarness(scenario: scenario)
        }

        func response(_ query: OpenCodeQuery) throws -> OpenCodeQueryResponse {
            queries.append(query)
            return try harness.response(query)
        }

        nonisolated var files: ChatHostFiles {
            let none = TransportError.hostFeatureUnavailable(feature: "Files")
            return ChatHostFiles(
                status: { _ in throw none }, list: { _ in throw none }, read: { _ in throw none },
                home: { throw none }, queryOpenCode: { try await self.response($0) })
        }
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
