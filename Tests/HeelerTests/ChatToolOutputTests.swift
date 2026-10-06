import Foundation
import Testing

@testable import Heeler

/// A tool's output read again when its row expands: the line the row came
/// from, decoded with room for more than the row keeps, or the file Claude
/// Code spilled a long output to.
@Suite("Chat tool output")
struct ChatToolOutputTests {
    private static let sessionID = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let cwd = "/home/dev/proj"
    private static let claudePath = "/home/dev/.claude/projects/-home-dev-proj/\(sessionID).jsonl"
    private static let spillDirectory = "/home/dev/.claude/projects/-home-dev-proj/\(sessionID)/tool-results/"

    /// `line 1` to `line <count>`, one per line.
    private static func numbered(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n")
    }

    private static func json(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }

    /// A Bash call whose result holds `output`, spilled to `path` when one
    /// is given.
    private static func bashTranscript(output: String, spilledTo path: String? = nil, callID: String = "toolu_seq")
        -> String
    {
        let spill = path.map { #","persistedOutputPath":\#(json($0)),"persistedOutputSize":200000"# } ?? ""
        return #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Count"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_seq","name":"Bash","input":{"command":"seq 100","description":"Count"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(callID)","content":\#(json(output))}]},"toolUseResult":{"stdout":\#(json(output)),"stderr":"","interrupted":false\#(spill)}}
            """#
    }

    private static func tool(_ id: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        guard case .tool(let row) = ClaudeSample.entry(id, in: transcript) else { return nil }
        return row
    }

    private static func firstTool(in transcript: ChatTranscript) -> ChatToolActivity? {
        transcript.entries.lazy.compactMap { entry -> ChatToolActivity? in
            guard case .tool(let row) = entry.content else { return nil }
            return row
        }.first
    }

    private static func expanded<Value>(_ read: () -> Value) -> Value {
        ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits, operation: read)
    }

    // MARK: Claude

    @Test func aClaudeRowKeepsItsStartAndAReadKeepsTheRest() throws {
        let lines = ClaudeSample.lines(Self.bashTranscript(output: Self.numbered(100)))
        let reducer = ClaudeSample.reducer(lines)
        let row = try #require(
            Self.tool("tool:toolu_seq", in: reducer.transcript(ChatProjectionContext(activity: .idle))))
        #expect(row.preview == ChatToolPreview(text: Self.numbered(40), isTruncated: true))
        #expect(row.output == ChatOutputReference(offset: lines[2].offset, length: lines[2].length))

        let output = Self.expanded { reducer.output(of: lines[2], for: row) }

        #expect(output == .preview(ChatToolPreview(text: Self.numbered(100), isTruncated: false)))
    }

    @Test func aCallWhoseRecordIsNotLoadedIsReadByItsToolsName() {
        let lines = ClaudeSample.lines(Self.bashTranscript(output: Self.numbered(100)))
        // The page holding the call has not been read.
        let reducer = ClaudeSample.reducer([lines[2]])
        let row = ChatToolActivity(kind: .command, name: "Bash", title: "Count", status: .succeeded, callID: "toolu_seq")

        let output = Self.expanded { reducer.output(of: lines[2], for: row) }

        #expect(output == .preview(ChatToolPreview(text: Self.numbered(100), isTruncated: false)))
    }

    @Test func aLineThatHoldsNoResultForTheCallReadsAsNothing() {
        let lines = ClaudeSample.lines(Self.bashTranscript(output: "done"))
        let reducer = ClaudeSample.reducer(lines)
        var row = ChatToolActivity(kind: .command, name: "Bash", title: "Count", status: .succeeded, callID: "toolu_seq")

        #expect(reducer.output(of: lines[0], for: row) == nil)
        row.callID = "toolu_other"
        #expect(reducer.output(of: lines[2], for: row) == nil)
    }

    @Test func onlyAnOutputSpilledBesideTheTranscriptIsNamed() {
        let row = ChatToolActivity(kind: .command, name: "Bash", title: "Count", status: .succeeded, callID: "toolu_seq")
        let start = ChatToolPreview(text: "line 1", isTruncated: false)
        func output(spilledTo path: String, transcriptPath: String?) -> ChatToolOutput? {
            let lines = ClaudeSample.lines(Self.bashTranscript(output: "line 1", spilledTo: path))
            var reducer = ClaudeTranscriptReducer(role: .main, transcriptPath: transcriptPath)
            reducer.append(lines)
            return reducer.output(of: lines[2], for: row)
        }
        let inside = Self.spillDirectory + "b1.txt"

        #expect(output(spilledTo: inside, transcriptPath: Self.claudePath) == .file(inside, fallback: start))
        // Anywhere else, the line's own copy shows.
        #expect(output(spilledTo: "/home/dev/.ssh/id_ed25519", transcriptPath: Self.claudePath) == .preview(start))
        #expect(output(spilledTo: Self.spillDirectory + "../../notes.txt", transcriptPath: Self.claudePath) == .preview(start))
        #expect(output(spilledTo: inside, transcriptPath: nil) == .preview(start))
    }

    // MARK: Codex

    @Test func aCodexCommandKeepsItsStartAndAReadKeepsTheRest() throws {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("turn-1")
        builder.command("turn-1", id: "exec-1", argv: ["/bin/zsh", "-lc", "seq 100"], output: Self.numbered(100))
        builder.turnComplete("turn-1")
        let reducer = builder.reducer()
        let row = try #require(Self.firstTool(in: reducer.transcript(ChatProjectionContext(activity: .idle))))
        #expect(row.preview == ChatToolPreview(text: Self.numbered(40), isTruncated: true))
        let line = try #require(builder.chatLines.first { $0.offset == row.output?.offset })

        let output = Self.expanded { reducer.output(of: line, for: row) }

        #expect(output == .preview(ChatToolPreview(text: Self.numbered(100), isTruncated: false)))
    }

    @Test func aLegacyCodexOutputTooLongToDecodeWhileFollowingIsReadWhenExpanded() throws {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("Count")
        builder.legacyCall("shell", callID: "call_1", arguments: ["command": ["seq", "40000"]])
        builder.legacyOutput(callID: "call_1", output: Self.numbered(40_000))
        let line = try #require(builder.chatLines.last)
        #expect(line.length > CodexRecordDecoder.outputDecodeLimit)
        let reducer = builder.reducer()
        let row = try #require(Self.firstTool(in: reducer.transcript(ChatProjectionContext(activity: .idle))))
        #expect(row.preview == nil)
        #expect(row.output?.offset == line.offset)

        let output = Self.expanded { reducer.output(of: line, for: row) }

        #expect(output == .preview(ChatToolPreview(text: Self.numbered(1_000), isTruncated: true)))
    }

    // MARK: Engine

    private static func claudeEngine(_ files: VirtualHostFiles) throws -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .claude, sessionID: sessionID),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .claude, conversationID: sessionID),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .claude)), now: { Date() })
    }

    /// Opens `jsonl` as the session's transcript, returning the engine and
    /// the Bash call's row.
    private static func openClaude(
        _ jsonl: String, files: VirtualHostFiles
    ) async throws -> (ChatConversationEngine, ChatToolActivity) {
        await files.write(jsonl + "\n", at: claudePath)
        let engine = try claudeEngine(files)
        let snapshot = await engine.open(directories: [cwd], context: ChatProjectionContext(activity: .idle))
        #expect(snapshot.phase == .following(path: claudePath))
        return (engine, try #require(tool("tool:toolu_seq", in: snapshot.transcript)))
    }

    @Test func anExpandedRowReadsItsLineAgain() async throws {
        let files = VirtualHostFiles()
        let (engine, row) = try await Self.openClaude(Self.bashTranscript(output: Self.numbered(100)), files: files)
        #expect(row.preview?.isTruncated == true)

        let result = await engine.output(of: row)

        #expect(result == .success(ChatToolPreview(text: Self.numbered(100), isTruncated: false)))
    }

    @Test func aSpilledOutputIsReadFromTheSessionsToolResults() async throws {
        let files = VirtualHostFiles()
        let spilled = Self.spillDirectory + "b1.txt"
        await files.write(Self.numbered(2_000), at: spilled)
        let (engine, row) = try await Self.openClaude(
            Self.bashTranscript(output: "line 1", spilledTo: spilled), files: files)

        let result = await engine.output(of: row)

        #expect(result == .success(ChatToolPreview(text: Self.numbered(1_000), isTruncated: true)))
    }

    @Test func aSpilledFileThatIsGoneLeavesTheLinesOwnCopy() async throws {
        let files = VirtualHostFiles()
        let (engine, row) = try await Self.openClaude(
            Self.bashTranscript(output: "line 1", spilledTo: Self.spillDirectory + "b1.txt"), files: files)

        let result = await engine.output(of: row)

        #expect(result == .success(ChatToolPreview(text: "line 1", isTruncated: false)))
    }

    @Test func anOutputSpilledOutsideTheSessionIsNeverRead() async throws {
        let files = VirtualHostFiles()
        let elsewhere = "/home/dev/notes.txt"
        await files.write("private", at: elsewhere)
        let (engine, row) = try await Self.openClaude(
            Self.bashTranscript(output: "line 1", spilledTo: elsewhere), files: files)

        let result = await engine.output(of: row)

        #expect(result == .success(ChatToolPreview(text: "line 1", isTruncated: false)))
        #expect(await !files.reads.contains { $0.path == elsewhere })
    }

    @Test func aLineThatChangedIsNoLongerAvailable() async throws {
        let files = VirtualHostFiles()
        let transcript = Self.bashTranscript(output: Self.numbered(100))
        let (engine, row) = try await Self.openClaude(transcript, files: files)

        // Rewritten with another call's result in the same bytes.
        let other = Self.bashTranscript(output: Self.numbered(100), callID: "toolu_abc")
        await files.replaceKeepingTime(Data((other + "\n").utf8), at: Self.claudePath)
        #expect(await engine.output(of: row) == .failure(.gone))

        // Cut short.
        await files.replaceKeepingTime(Data(transcript.prefix(100).utf8), at: Self.claudePath)
        #expect(await engine.output(of: row) == .failure(.gone))
    }

    @Test func aLineLongerThanTheFetchCapIsNotRead() async throws {
        let files = VirtualHostFiles()
        let (engine, row) = try await Self.openClaude(Self.bashTranscript(output: Self.numbered(100)), files: files)
        var long = row
        long.output?.length = ChatToolPreview.maximumFetchBytes + 1
        await files.clearRecords()

        #expect(await engine.output(of: long) == .failure(.tooLong))
        #expect(await files.reads.isEmpty)
    }

    @Test func aFailedReadSaysWhy() async throws {
        let files = VirtualHostFiles()
        let (engine, row) = try await Self.openClaude(Self.bashTranscript(output: Self.numbered(100)), files: files)
        await files.failNext(.read, with: TransportError.hostFileTimedOut)

        let result = await engine.output(of: row)

        #expect(result == .failure(.unreadable(TransportError.hostFileTimedOut.presentation.summary)))
    }

    @Test func nothingIsReadBeforeTheTranscriptOpens() async throws {
        let files = VirtualHostFiles()
        let engine = try Self.claudeEngine(files)
        let row = ChatToolActivity(
            kind: .command, name: "Bash", title: "Count", status: .succeeded, callID: "toolu_seq",
            output: ChatOutputReference(offset: 0, length: 10))

        #expect(await engine.output(of: row) == .failure(.notFollowing))
        #expect(await files.reads.isEmpty)
    }

    // MARK: Overlay

    private static let reference = ChatOutputReference(offset: 10, length: 20)
    private static let start = ChatToolPreview(text: "line 1", isTruncated: true)

    private static func entry(preview: ChatToolPreview?, output: ChatOutputReference? = reference) -> ChatEntry {
        ChatEntry(
            id: ChatEntryID("tool:toolu_seq"), sourceOffset: 0,
            content: .tool(
                ChatToolActivity(
                    kind: .command, name: "Bash", title: "Count", status: .succeeded, callID: "toolu_seq",
                    preview: preview, output: output)))
    }

    private static func marked(_ outputs: ChatToolOutputs, _ entry: ChatEntry) -> ChatToolActivity? {
        guard case .tool(let row) = outputs.marking([entry]).first?.content else { return nil }
        return row
    }

    @Test func aReadShowsOnItsRowWhileTheRowReferencesItsLine() {
        let entry = Self.entry(preview: Self.start)
        var outputs = ChatToolOutputs()
        #expect(outputs.needsRead(entry.id, at: Self.reference))

        outputs.begin(entry.id, at: Self.reference)
        #expect(!outputs.needsRead(entry.id, at: Self.reference))
        #expect(Self.marked(outputs, entry)?.outputRead == .loading)
        #expect(Self.marked(outputs, entry)?.preview == Self.start)

        let whole = ChatToolPreview(text: Self.numbered(2), isTruncated: false)
        outputs.finish(entry.id, at: Self.reference, with: .success(whole))
        #expect(Self.marked(outputs, entry)?.outputRead == .read)
        #expect(Self.marked(outputs, entry)?.preview == whole)
        #expect(!outputs.needsRead(entry.id, at: Self.reference))

        // The row moved on to another line: the read was for the old one.
        let elsewhere = ChatOutputReference(offset: 40, length: 20)
        let moved = Self.entry(preview: Self.start, output: elsewhere)
        #expect(outputs.marking([moved]) == [moved])
        #expect(outputs.needsRead(entry.id, at: elsewhere))
    }

    @Test func aReadThatFoundNothingKeepsTheRowsOwnPreview() {
        var outputs = ChatToolOutputs()
        outputs.begin(ChatEntryID("tool:toolu_seq"), at: Self.reference)
        outputs.finish(ChatEntryID("tool:toolu_seq"), at: Self.reference, with: .success(nil))

        let kept = Self.marked(outputs, Self.entry(preview: Self.start))
        #expect(kept?.preview == Self.start)
        #expect(kept?.outputRead == .read)
        let empty = Self.marked(outputs, Self.entry(preview: nil))
        #expect(empty?.preview == nil)
        #expect(empty?.outputRead == .read)
    }

    @Test func aFailedReadSaysWhyOnItsRowAndMayBeTriedAgain() {
        let id = ChatEntryID("tool:toolu_seq")
        var outputs = ChatToolOutputs()
        outputs.begin(id, at: Self.reference)
        outputs.finish(id, at: Self.reference, with: .failure(.gone))

        #expect(Self.marked(outputs, Self.entry(preview: nil))?.outputRead == .failed("Output is no longer available."))
        #expect(outputs.needsRead(id, at: Self.reference))

        outputs.begin(id, at: Self.reference)
        outputs.finish(id, at: Self.reference, with: .failure(.tooLong))
        // A row showing the start already says where the rest is.
        #expect(Self.marked(outputs, Self.entry(preview: Self.start))?.outputRead == .read)
        #expect(
            Self.marked(outputs, Self.entry(preview: nil))?.outputRead
                == .failed("This output is too long to show here."))
    }
}
