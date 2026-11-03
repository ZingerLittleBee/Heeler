import Foundation
import Testing

@testable import Heeler

@Suite("Pi Chat", .timeLimit(.minutes(1)))
struct PiChatTests {
    private static let id = "f3c2a481-54ed-4c7e-a240-6d036157dc80"
    private static let path = "/home/test/.pi/agent/sessions/--project--/2026-10-15_\(id).jsonl"
    private static let header =
        #"{"type":"session","version":3,"id":"f3c2a481-54ed-4c7e-a240-6d036157dc80","cwd":"/project"}"#

    private static func lines(_ rows: [String]) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func resolvesOfficialPathsAndUUIDs(program: ChatProgram) {
        for value in [Self.path, Self.id] {
            let kind: AgentSessionRefKind = value == Self.path ? .path : .id
            #expect(
                ConversationReference.resolve(
                    AgentSessionInfo(
                        agent: program.rawValue, kind: kind,
                        source: "herdr:\(program.rawValue)", value: value))
                    == .bound(ConversationReference(program: program, sessionID: value)))
        }
    }

    @Test(arguments: ["../x.jsonl", "/tmp/../other.jsonl", "/tmp/./x.jsonl", "/tmp/x\n.jsonl", "/tmp/x.txt"])
    func refusesUnsafeSessionPaths(path: String) {
        #expect(
            ConversationReference.resolve(AgentSessionInfo(agent: "pi", kind: .path, source: "herdr:pi", value: path))
                == .unidentified)
    }

    @Test func followsCurrentBranchThroughInvisibleEntries() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"original"}}"#,
                #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"text","text":"abandoned answer"}],"stopReason":"stop"}}"#,
                #"{"type":"custom","id":"branch","parentId":"u1","customType":"switch"}"#,
                #"{"type":"message","id":"a2","parentId":"branch","message":{"role":"assistant","content":[{"type":"text","text":"current answer"}],"stopReason":"stop"}}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 2)
        #expect(transcript.entries.last?.content == .assistant(ChatAssistantMessage(text: "current answer")))
        #expect(!transcript.needsOlderHistory)
    }

    @Test func lateOMPUsageDoesNotRestoreAnAbandonedBranch() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"old"}}"#,
                #"{"type":"message","id":"b","parentId":null,"message":{"role":"user","content":"new"}}"#,
                #"{"type":"model_usage","id":"usage","parentId":"a","activeLeafId":"b"}"#,
            ]))
        #expect(reducer.transcript(.init()).entries.map(\.content) == [.user(ChatUserMessage(text: "new"))])
    }

    @Test func prependAndRepeatedReadsConvergeWithoutDuplicateRows() {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"你好"}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"text","text":"回复"}],"stopReason":"stop"}}"#,
        ])
        var whole = PiTranscriptReducer()
        whole.append(lines)
        var paged = PiTranscriptReducer()
        paged.append(Array(lines.suffix(1)))
        #expect(paged.transcript(.init(windowStart: lines[2].offset)).needsOlderHistory)
        paged.prepend(Array(lines.prefix(2)))
        paged.append(lines)
        #expect(paged.transcript(.init()) == whole.transcript(.init()))
    }

    /// Oh My Pi 18.11.1 names its file finder `glob`; it is a search like
    /// `grep`, not an unnamed tool.
    @Test func ompGlobCallIsASearch() throws {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"use the find tool to list *.txt files"}]}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"glob","arguments":{"i":"Finding text files","path":"**/*.txt","hidden":true}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"glob","content":[{"type":"text","text":"todo.txt\nnotes.txt"}],"isError":false}}"#,
        ])
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.kind == .search)
        #expect(tool.title == "**/*.txt")
    }

    /// A directory listing reads "Listed 1 folder" in a group, as Codex's
    /// does, not "Ran 1 search".
    @Test func lsCallIsAListing() throws {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"list src"}]}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"ls","arguments":{"path":"src"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"ls","content":[{"type":"text","text":"main.swift"}],"isError":false}}"#,
        ])
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.kind == .listing)
        #expect(tool.title == "src")
    }

    @Test func pairsToolsByIDAndReadsFullOutputOnDemand() throws {
        let lines = Self.lines([
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"inspect"},{"type":"image","data":"synthetic"}]}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"thinking","thinking":"read first"},{"type":"toolCall","id":"c","name":"read","arguments":{"path":"file.swift"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"read","content":[{"type":"text","text":"file contents"}],"isError":true}}"#,
        ])
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init(activity: .working))
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .failed)
        #expect(tool.kind == .fileRead)
        #expect(tool.title == "file.swift")
        #expect(tool.preview?.text == "file contents")
        #expect(tool.output?.offset == lines[3].offset)
        #expect(reducer.output(of: lines[3], for: tool) == .preview(ChatToolPreview(capping: "file contents")))
        #expect(transcript.entries.first?.content == .user(ChatUserMessage(text: "inspect", imageCount: 1)))
        #expect(transcript.entries[1].content == .reasoning(ChatReasoning(text: "read first")))
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func compactionKeepsHistoryAndFinishedTurns() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"timestamp":"2026-10-15T00:00:00.000Z","message":{"role":"user","content":"hello"}}"#,
                #"{"type":"message","id":"a","parentId":"u","timestamp":"2026-10-15T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"stop"}}"#,
                #"{"type":"compaction","id":"c","parentId":"a","summary":"summary","firstKeptEntryId":"u"}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 3)
        #expect(transcript.entries.last?.content == .divider(ChatDivider(kind: .compaction, detail: "summary")))
        #expect(transcript.turns.first?.ending == .completed)
        #expect(
            transcript.turns.first?.endedAt?.timeIntervalSince(transcript.turns.first?.startedAt ?? .distantPast) == 3)
    }

    @Test func unknownRecordsRemainTreeLinksAndMalformedLinesAreCounted() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                "{not json}",
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"visible"}}"#,
                #"{"type":"future_state","id":"f","parentId":"u"}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 1)
        #expect(transcript.diagnostics.invalidLines == 1)
        #expect(transcript.diagnostics.unknownRecordTypes == ["future_state"])
    }

    @Test func oversizedImageRecordKeepsBranchAncestry() {
        let header = Self.lines([Self.header])[0]
        let prefix =
            #"{"type":"message","id":"image","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"look"},{"type":"image","data":""#
        let line = ChatLine(offset: header.end, length: 2 << 20, data: Data(prefix.utf8))
        let answer = ChatLine(
            offset: line.end,
            data: Data(
                #"{"type":"message","id":"answer","parentId":"image","message":{"role":"assistant","content":[{"type":"text","text":"visible answer"}],"stopReason":"stop"}}"#
                    .utf8))
        var reducer = PiTranscriptReducer()
        reducer.append([header, line, answer])
        let transcript = reducer.transcript(.init())
        #expect(transcript.entries.count == 2)
        #expect(transcript.diagnostics.oversizedLines == 1)
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.recordedPrompts.isEmpty)
    }

    @Test func priorTailTurnEndDoesNotInterruptTheCurrentTool() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"end","parentId":null,"message":{"role":"assistant","content":[],"stopReason":"stop"}}"#,
                #"{"type":"message","id":"u","parentId":"end","message":{"role":"user","content":"next"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"pwd"}}],"stopReason":"toolUse"}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .running)
    }

    @Test func doesNotJoinCachedPrefixesAcrossPiBranchSwitches() async throws {
        let old = #"{"type":"message","id":"old","parentId":null,"message":{"role":"user","content":"abandoned"}}"#
        let padding =
            #"{"type":"custom","id":"pad","parentId":"old","data":""# + String(repeating: "x", count: 1000) + #""}"#
        let newest = [
            #"{"type":"message","id":"new","parentId":null,"message":{"role":"user","content":"current"}}"#,
            #"{"type":"message","id":"answer","parentId":"new","message":{"role":"assistant","content":[{"type":"text","text":"new answer"}],"stopReason":"stop"}}"#,
        ]
        let data = Data(([Self.header, old, padding] + newest).joined(separator: "\n").appending("\n").utf8)
        let key = ChatCacheKey(hostID: UUID(), herdrSession: "", program: .pi, conversationID: Self.path)
        let cache = VolatileChatTranscriptCache()
        await cache.save(
            ChatCacheDocument(
                key: key, adapterRevision: PiTranscriptReducer.revision,
                transcriptPath: Self.path, head: Data(data.prefix(64)), coverageStart: 0,
                coverageEnd: UInt64(data.count),
                reachedStart: true, title: nil,
                entries: [
                    ChatEntry(
                        id: ChatEntryID("pi:old"), sourceOffset: UInt64(Self.header.utf8.count + 1),
                        content: .user(ChatUserMessage(text: "abandoned")))
                ], savedAt: Date()))
        var adapter = try #require(ChatTranscriptAdapter.standard(for: .pi))
        adapter.limits.tailWindow = newest.joined(separator: "\n").utf8.count + 3
        let engine = ChatConversationEngine(
            reference: .init(program: .pi, sessionID: Self.path), cacheKey: key,
            files: Self.hostFiles([Self.path: data]), cache: cache, adapter: adapter)
        #expect(await engine.restore().isFromCache)
        let live = await engine.open(directories: [], context: .init())
        #expect(live.phase == .following(path: Self.path))
        #expect(live.transcript.entries.map(\.id) == [ChatEntryID("pi:new"), ChatEntryID("pi:answer:0")])
    }

    @Test func verifiesOMPTitleSlotAndSessionHeader() async throws {
        let data = Data((#"{"type":"title","v":1,"title":"sample"}"# + "\n" + Self.header + "\n").utf8)
        let files = Self.hostFiles([Self.path: data])
        let result = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: .omp, sessionID: Self.path), directories: [])
        #expect(result == .success(Self.path))
    }

    @Test func UUIDLookupVerifiesIdentityInsteadOfPickingNewest() async throws {
        let files = Self.hostFiles([Self.path: Data((Self.header + "\n").utf8)])
        let result = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: .pi, sessionID: Self.id), directories: ["/project"])
        #expect(result == .success(Self.path))
        let wrong = Self.header.replacingOccurrences(of: Self.id, with: "11111111-1111-4111-8111-111111111111")
        let mismatch = try await PiTranscriptLocator(files: Self.hostFiles([Self.path: Data((wrong + "\n").utf8)]))
            .locate(reference: .init(program: .pi, sessionID: Self.id), directories: ["/project"])
        #expect(mismatch == .failure(.mismatched))
    }

    @Test func newerSessionVersionsAreNotSilentlyMisread() async throws {
        let header = Self.header.replacingOccurrences(of: "\"version\":3", with: "\"version\":9")
        let result = try await PiTranscriptLocator(files: Self.hostFiles([Self.path: Data((header + "\n").utf8)]))
            .locate(reference: .init(program: .pi, sessionID: Self.path), directories: [])
        #expect(result == .failure(.unsupportedVersion(9)))
        let engine = ChatConversationEngine(
            reference: .init(program: .omp, sessionID: Self.path),
            cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: .omp, conversationID: Self.path),
            files: Self.hostFiles([Self.path: Data((header + "\n").utf8)]), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .omp)))
        #expect(
            await engine.open(directories: [], context: .init()).phase
                == .unavailable(.unsupportedFormat("Oh My Pi session version 9")))
    }

    // MARK: A new conversation's file

    private static let cacheHost = UUID()

    private static func engine(_ program: ChatProgram, files: ChatHostFiles, cache: VolatileChatTranscriptCache)
        throws -> ChatConversationEngine
    {
        ChatConversationEngine(
            reference: .init(program: program, sessionID: Self.path),
            cacheKey: ChatCacheKey(hostID: cacheHost, herdrSession: "", program: program, conversationID: Self.path),
            files: files, cache: cache, adapter: try #require(ChatTranscriptAdapter.standard(for: program)))
    }

    /// Pi and Oh My Pi report a session's path at startup and write the
    /// file with the first reply.
    @Test(arguments: [ChatProgram.pi, .omp])
    func missingReportedPathIsAwaitingFirstMessage(program: ChatProgram) async throws {
        let files = Self.hostFiles([:])
        let result = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: program, sessionID: Self.path), directories: ["/project"])
        #expect(result == .failure(.notWritten))
        let engine = try Self.engine(program, files: files, cache: VolatileChatTranscriptCache())
        #expect(
            await engine.open(directories: ["/project"], context: .init()).phase
                == .unavailable(.awaitingFirstMessage(program)))
    }

    @Test func zeroByteFileIsAwaitingFirstMessage() async throws {
        let files = Self.hostFiles([Self.path: Data()])
        let engine = try Self.engine(.pi, files: files, cache: VolatileChatTranscriptCache())
        #expect(await engine.open(directories: [], context: .init()).phase == .unavailable(.awaitingFirstMessage(.pi)))
        // A UUID names no file to wait for: one not found is missing.
        let byID = try await PiTranscriptLocator(files: files).locate(
            reference: .init(program: .pi, sessionID: Self.id), directories: ["/project"])
        #expect(byID == .failure(.notFound(searchedAll: true)))
    }

    @Test func aFileShownBeforeThatIsGoneIsNotFound() async throws {
        let files = VirtualHostFiles()
        await files.write(
            Self.header + "\n"
                + #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"# + "\n",
            at: Self.path)
        let cache = VolatileChatTranscriptCache()
        let engine = try Self.engine(.pi, files: files.hostFiles(), cache: cache)
        #expect(await engine.open(directories: [], context: .init()).phase == .following(path: Self.path))
        await engine.save(force: true)
        await files.remove(Self.path)
        #expect(await engine.poll(context: .init()).phase == .unavailable(.notFound(searchedAll: true)))

        // Saved on the device, then gone from the Host, on a later visit.
        let later = try Self.engine(.pi, files: files.hostFiles(), cache: cache)
        _ = await later.restore()
        #expect(await later.open(directories: [], context: .init()).phase == .unavailable(.notFound(searchedAll: true)))
    }

    // MARK: Rewrites

    @Test func cacheSurvivesHeaderRewrite() async throws {
        let slot = #"{"type":"title","v":1,"title":"Echo","source":"auto","pad":"          "}"#
        let user = #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"#
        let answer =
            #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"text","text":"a reply long enough to prune"}],"stopReason":"stop"}}"#
        let files = VirtualHostFiles()
        await files.write([slot, Self.header, user, answer].map { $0 + "\n" }.joined(), at: Self.path)
        let cache = VolatileChatTranscriptCache()
        let key = ChatCacheKey(hostID: Self.cacheHost, herdrSession: "", program: .omp, conversationID: Self.path)
        let engine = try Self.engine(.omp, files: files.hostFiles(), cache: cache)
        let opened = await engine.open(directories: [], context: .init())
        await engine.save(force: true)
        #expect(await cache.load(key) != .miss)

        // Oh My Pi's atomic rewrite fills in the header's title and prunes
        // the reply: the head and the end both change, the session does not.
        let titled = Self.header.replacingOccurrences(of: "}", with: #","title":"Echo","titleSource":"auto"}"#)
        let pruned = #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[],"stopReason":"stop"}}"#
        await files.write([slot, titled, user, pruned].map { $0 + "\n" }.joined(), at: Self.path)
        let rewritten = await engine.poll(context: .init())

        #expect(rewritten.phase == .following(path: Self.path))
        #expect(rewritten.layoutGeneration == opened.layoutGeneration + 1)
        #expect(rewritten.transcript.entries.first?.id == ChatEntryID("pi:u1"))
        guard case .hit(let document) = await cache.load(key) else {
            Issue.record("expected the saved conversation to survive the rewrite")
            return
        }
        #expect(document.entries.first?.id == ChatEntryID("pi:u1"))
    }

    // MARK: Skills, approvals and questions

    private static let skillTurn = [
        Self.header,
        #"{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"hello"}}"#,
        #"{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"stopReason":"stop"}}"#,
        #"{"type":"custom_message","customType":"skill-prompt","content":"[IMPORTANT: User invoked the \"probe\" skill]\n\nSKILL BODY","display":true,"details":{"name":"probe","path":"/home/test/.agents/skills/probe/SKILL.md","args":"from chat","prompt":"/skill:probe from chat","lineCount":3},"attribution":"user","id":"s1","parentId":"a1"}"#,
        #"{"type":"message","id":"a2","parentId":"s1","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_1|fc_1","name":"bash","arguments":{"i":"Probing","command":"echo probe"}}],"stopReason":"toolUse"}}"#,
    ]

    @Test func ompSkillPromptOpensTurnAndRecordsPrompt() {
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Self.skillTurn))
        let transcript = reducer.transcript(.init(activity: .working))
        let invocation = ChatCommandInvocation(name: "probe", arguments: "from chat")
        #expect(
            transcript.entries[2].content
                == .user(ChatUserMessage(text: "/probe from chat", command: invocation)))
        #expect(transcript.entries[2].id == ChatEntryID("pi:s1"))
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("pi:u1"), ChatEntryID("pi:s1")])
        #expect(transcript.turns.first?.ending == .completed)
        #expect(transcript.turns.last?.ending == nil)
        #expect(transcript.recordedPrompts.map(\.text) == ["hello", "/skill:probe from chat"])
        #expect(transcript.latestPromptOffset == transcript.entries[2].sourceOffset)
        #expect(!transcript.entries.contains { "\($0.content)".contains("SKILL BODY") })
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .running)
    }

    @Test func ompSkillPromptMidSentenceOrWithoutPromptOrFromTheAgent() {
        func entry(_ fields: String) -> ChatEntry.Content? {
            var reducer = PiTranscriptReducer()
            reducer.append(
                Self.lines([
                    Self.header,
                    #"{"type":"custom_message","customType":"skill-prompt","content":"SKILL BODY","display":true,"id":"s","parentId":null,"#
                        + fields + "}",
                ]))
            return reducer.transcript(.init()).entries.first?.content
        }
        #expect(
            entry(#""attribution":"user","details":{"name":"probe","prompt":"please /skill:probe now"}"#)
                == .user(ChatUserMessage(text: "please /skill:probe now")))
        #expect(
            entry(#""attribution":"user","details":{"name":"probe"}"#)
                == .notice(ChatNotice(kind: .hook, title: "skill-prompt", detail: "SKILL BODY")))
        #expect(
            entry(#""attribution":"agent","details":{"name":"probe","prompt":"/skill:probe"}"#)
                == .notice(ChatNotice(kind: .hook, title: "skill-prompt", detail: "SKILL BODY")))
    }

    @Test func blockedToolInSkillTurnIsPending() {
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Self.skillTurn))
        let transcript = reducer.transcript(.init(activity: .blocked))
        guard case .tool(let tool) = transcript.entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .awaitingApproval)
        #expect(tool.subtitle == nil)
        #expect(
            transcript.pendingRequests
                == [
                    ChatPendingRequest(
                        entryID: ChatEntryID("pi:tool:call_1|fc_1"), callID: "call_1|fc_1", kind: .command,
                        toolName: "bash", summary: "echo probe")
                ])
    }

    @Test func piSkillBlockShowsAsCommandAndEchoes() throws {
        let lines = try ChatFixture.lines("pi/auth-error-skill.jsonl")
        var reducer = PiTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init())
        let skill = try #require(transcript.entries.first { $0.id == ChatEntryID("pi:d3d6363a") })
        let invocation = ChatCommandInvocation(name: "probe-hello", arguments: "world args")
        #expect(skill.content == .user(ChatUserMessage(text: "/probe-hello world args", command: invocation)))
        #expect(transcript.recordedPrompts.last?.text == "/skill:probe-hello world args")
        #expect(transcript.turns.count == 2)

        func content(_ text: String) -> (ChatEntry.Content?, String?) {
            var reducer = PiTranscriptReducer()
            let record: JSONValue = .object([
                "type": .string("message"), "id": .string("u"), "parentId": .null,
                "message": .object(["role": .string("user"), "content": .string(text)]),
            ])
            reducer.append(Self.lines([Self.header, String(decoding: try! JSONEncoder().encode(record), as: UTF8.self)]))
            let transcript = reducer.transcript(.init())
            return (transcript.entries.first?.content, transcript.recordedPrompts.first?.text)
        }
        let block = "<skill name=\"hello\" location=\"/p/SKILL.md\">\nBody line\n</skill>"
        #expect(
            content(block)
                == (.user(ChatUserMessage(text: "/hello", command: ChatCommandInvocation(name: "hello"))), "/skill:hello"))
        let multiline = ChatCommandInvocation(name: "hello", arguments: "first\n\nsecond </skill>")
        #expect(
            content(block + "\n\nfirst\n\nsecond </skill>")
                == (
                    .user(ChatUserMessage(text: multiline.displayText, command: multiline)),
                    "/skill:hello first\n\nsecond </skill>"
                ))
        let unclosed = "<skill name=\"hello\" location=\"/p/SKILL.md\">\nBody line\n\nargs"
        #expect(content(unclosed) == (.user(ChatUserMessage(text: unclosed)), unclosed))
    }

    private static func ompTranscript(through line: Int? = nil, activity: ChatAgentActivity = .idle) throws
        -> ChatTranscript
    {
        let lines = try ChatFixture.lines("omp/approvals-asks-plan.jsonl")
        var reducer = PiTranscriptReducer(program: .omp)
        reducer.append(Array(lines.prefix(line ?? lines.count)))
        return reducer.transcript(.init(activity: activity))
    }

    private static func tool(_ callPrefix: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        for entry in transcript.entries {
            if case .tool(let tool) = entry.content, tool.callID?.hasPrefix(callPrefix) == true { return tool }
        }
        return nil
    }

    @Test func ompAskPendingRequestCarriesQuestions() throws {
        // The two-question ask, Blocked before its result.
        let transcript = try Self.ompTranscript(through: 37, activity: .blocked)
        let request = try #require(transcript.pendingRequests.first)
        #expect(transcript.pendingRequests.count == 1)
        #expect(request.callID?.contains("|") == true)
        #expect(request.kind == .question)
        #expect(request.toolName == "ask")
        #expect(request.summary == "Pick a fruit")
        #expect(
            request.questions
                == [
                    ChatQuestion(id: "fruit", text: "Pick a fruit", options: ["apple", "pear"]),
                    ChatQuestion(id: "size", text: "Pick a size", options: ["small", "large"]),
                ])

        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"ask","arguments":{"questions":[{"id":"q","question":"Which?","header":"Pick","options":[{"label":"one","description":"First"},{"label":"two"}],"multi":true,"recommended":1}]}}],"stopReason":"toolUse"}}"#,
            ]))
        #expect(
            reducer.transcript(.init(activity: .blocked)).pendingRequests.first?.questions
                == [
                    ChatQuestion(
                        id: "q", header: "Pick", text: "Which?",
                        options: [ChatQuestion.Option(label: "one", detail: "First"), "two"], isMultiSelect: true,
                        recommendedIndex: 1)
                ])
    }

    @Test func ompDeniedApprovalIsDeclined() throws {
        let transcript = try Self.ompTranscript(through: 28)
        #expect(Self.tool("call_adb504f6", in: transcript)?.status == .succeeded)
        #expect(Self.tool("call_74e0dc7b", in: transcript)?.status == .declined)
        #expect(Self.tool("call_fd940fe8", in: transcript)?.status == .declined)
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func ompCancelledAskIsDeclined() throws {
        let transcript = try Self.ompTranscript(through: 39)
        let ask = try #require(Self.tool("call_7bfdda8a", in: transcript))
        #expect(ask.status == .declined)
        #expect(ask.questions.allSatisfy { $0.answer == nil })
        #expect(
            transcript.entries.last?.content == .notice(ChatNotice(kind: .interrupted, title: "Interrupted")))
        #expect(transcript.turns.last?.ending == .interrupted)
    }

    @Test func ompAnsweredAskRecordsAnswer() throws {
        let transcript = try Self.ompTranscript()
        #expect(
            Self.tool("call_c20d8fdc", in: transcript)?.questions
                == [ChatQuestion(id: "fruit", text: "Pick a fruit", options: ["apple", "pear", "plum"], answer: "pear")])
        #expect(Self.tool("call_a97f9e92", in: transcript)?.questions.first?.answer == "red")

        // Several questions answer by id.
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"ask","arguments":{"questions":[{"id":"one","question":"First?","options":[{"label":"x"},{"label":"y"}]},{"id":"two","question":"Second?","options":[{"label":"p"},{"label":"q"}],"multi":true}]}}],"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"ask","content":[{"type":"text","text":"User answers:\none: y\ntwo: [p, q]"}],"details":{"results":[{"id":"two","selectedOptions":["p","q"]},{"id":"one","selectedOptions":["y"]}]},"isError":false}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init()).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.questions.map(\.answer) == ["y", "p, q"])
    }

    @Test func toolWithoutATargetIsSubtitledByItsIntent() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"a","parentId":null,"message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"edit","arguments":{"input":"*** Begin Patch","i":"Fixing the typo"}}],"stopReason":"toolUse"}}"#,
            ]))
        guard case .tool(let tool) = reducer.transcript(.init(activity: .working)).entries.last?.content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.title == "edit")
        #expect(tool.subtitle == "Fixing the typo")
    }

    // MARK: Edit diffs

    private static func toolRow(_ transcript: ChatTranscript) -> ChatToolActivity? {
        for entry in transcript.entries.reversed() {
            if case .tool(let tool) = entry.content { return tool }
        }
        return nil
    }

    /// Oh My Pi 18.11.1's free-form edit (live capture 11): the call names
    /// no file, the result's details carry the path and a numbered diff.
    private static let ompEdit = [
        #"{"type":"session","version":3,"id":"01a14045-0053-7439-b93e-c7acce7b7547","timestamp":"2026-10-15T15:53:46.323Z","cwd":"/tmp/heeler-iso-omp2/proj"}"#,
        #"{"type":"message","id":"5a8eaae0","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"In notes.txt change the line beta to BETA using your edit tool. Then reply: done"}],"attribution":"user"}}"#,
        #"{"type":"message","id":"c2ed8e36","parentId":"5a8eaae0","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_41d1f7700efc410888b660d57007fce1|ctc_04f80ff35a26c210016ad0f7caddf88191a9d1288be3fc0f5a","name":"edit","arguments":{"input":"*** Begin Patch\n[notes.txt#B6C1]\nPUT 2.=2:\n+BETA\n*** End Patch\n"},"customWireName":"edit"}],"stopReason":"toolUse"}}"#,
        #"{"type":"custom","customType":"tool_execution_start","data":{"toolCallId":"call_41d1f7700efc410888b660d57007fce1|ctc_04f80ff35a26c210016ad0f7caddf88191a9d1288be3fc0f5a","toolName":"edit"},"id":"7724cd66","parentId":"c2ed8e36"}"#,
        #"{"type":"message","id":"f4717db2","parentId":"7724cd66","message":{"role":"toolResult","toolCallId":"call_41d1f7700efc410888b660d57007fce1|ctc_04f80ff35a26c210016ad0f7caddf88191a9d1288be3fc0f5a","toolName":"edit","content":[{"type":"text","text":"[notes.txt#F1C1]\n1:alpha\n2:BETA\n3:gamma"}],"details":{"diff":" 1|alpha\n-2|beta\n+2|BETA\n 3|gamma","firstChangedLine":2,"op":"update","path":"/tmp/heeler-iso-omp2/proj/notes.txt","oldText":"alpha\nbeta\ngamma\n","newText":"alpha\nBETA\ngamma\n"},"isError":false}}"#,
    ]

    @Test func ompEditDiffBecomesFileChanges() throws {
        var reducer = PiTranscriptReducer()
        let lines = Self.lines(Self.ompEdit)
        reducer.append(lines)
        let tool = try #require(Self.toolRow(reducer.transcript(.init())))

        #expect(tool.kind == .fileEdit)
        #expect(tool.title == "notes.txt")
        #expect(tool.diff == ChatDiffStats(added: 1, removed: 1))
        let changes = try #require(tool.fileChanges)
        #expect(changes.directory == "/tmp/heeler-iso-omp2/proj")
        #expect(changes.files.map { changes.displayPath(of: $0) } == ["notes.txt"])
        #expect(changes.files.first?.kind == .updated)
        #expect(
            changes.files.first?.hunks == [
                ChatDiffHunk(
                    oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" alpha", "-beta", "+BETA", " gamma"])
            ])
        #expect(tool.showsDiffAsOutput)

        // An expanded row decodes the same changes from the result's line.
        let result = try #require(lines.last)
        guard case .preview(_, let expanded)? = reducer.output(of: result, for: tool) else {
            Issue.record("expected the result's output")
            return
        }
        #expect(expanded == changes)
    }

    /// Oh My Pi 18.11.2 refining its plan (V3 OMP-04): the patch names
    /// `local://append-delta-plan.md`, and the result's details resolve it
    /// into the account's session directory. The row keeps the name the
    /// read and write rows beside it show.
    @Test func ompEditOfASessionLocalFileIsTitledByItsLocalPath() throws {
        let resolved =
            "/Users/dev/.omp/agent/sessions/-tmp-proj/2026-10-17T20-32-17-663Z_01a14b90/local/append-delta-plan.md"
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                #"{"type":"session","version":3,"id":"01a14b90","timestamp":"2026-10-17T20:32:17.663Z","cwd":"/tmp/proj"}"#,
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Refine the plan"}],"attribution":"user"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"edit","arguments":{"input":"*** Begin Patch\n[local://append-delta-plan.md#7A3E]\nPUT 1.=1:\n+## Step 1\n*** End Patch\n"}}],"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"edit","content":[{"type":"text","text":"[local://append-delta-plan.md#F075]\n1:## Step 1"}],"details":{"diff":"-1|## Step\n+1|## Step 1","firstChangedLine":1,"op":"update","path":"\#(resolved)"},"isError":false}}"#,
            ]))
        let tool = try #require(Self.toolRow(reducer.transcript(.init())))

        #expect(tool.title == "local://append-delta-plan.md")
        #expect(tool.diff == ChatDiffStats(added: 1, removed: 1))
        #expect(tool.fileChanges?.files.map(\.path) == [resolved])
    }

    /// While Oh My Pi waits for approval, the patch's section header names
    /// the file the result will.
    @Test func ompPendingEditIsTitledByItsPatchHeader() throws {
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Array(Self.ompEdit.prefix(4))))
        let transcript = reducer.transcript(.init(activity: .blocked))
        let tool = try #require(Self.toolRow(transcript))

        #expect(tool.status == .awaitingApproval)
        #expect(tool.title == "notes.txt")
        #expect(transcript.pendingRequests.map(\.summary) == ["notes.txt"])
    }

    /// The E2E session ran in `/private/tmp/...` while Oh My Pi recorded
    /// the edit under `/tmp/...`.
    @Test func ompEditUnderTheTmpAliasReadsRelative() throws {
        var reducer = PiTranscriptReducer()
        var rows = Self.ompEdit
        rows[0] = rows[0].replacingOccurrences(of: #""cwd":"/tmp/"#, with: #""cwd":"/private/tmp/"#)
        reducer.append(Self.lines(rows))
        let tool = try #require(Self.toolRow(reducer.transcript(.init())))

        #expect(tool.title == "notes.txt")
        let changes = try #require(tool.fileChanges)
        #expect(changes.files.map { changes.displayPath(of: $0) } == ["notes.txt"])
    }

    @Test func pathsReadRelativeThroughThePrivateAlias() {
        #expect(ChatFileChanges.displayPath("/tmp/p/a.txt", in: "/private/tmp/p") == "a.txt")
        #expect(ChatFileChanges.displayPath("/private/var/p/a.txt", in: "/var/p/") == "a.txt")
        #expect(ChatFileChanges.displayPath("/private/tmp/p/a.txt", in: "/private/tmp/p") == "a.txt")
        #expect(ChatFileChanges.displayPath("/tmp/q/a.txt", in: "/private/tmp/p") == "/tmp/q/a.txt")
        #expect(ChatFileChanges.displayPath("/tmp/p", in: "/private/tmp/p") == "/tmp/p")
        #expect(ChatFileChanges.displayPath("notes.txt", in: "/tmp/p") == "notes.txt")
        #expect(ChatFileChanges.displayPath("/private/etc/p/a.conf", in: "/etc/p") == "a.conf")
    }

    /// Only macOS's firmlinked roots have a `/private` twin. On a Linux
    /// Host `/private/data` and `/data` are unrelated directories.
    @Test func otherPrivatePathsKeepTheirPrefix() {
        #expect(ChatFileChanges.displayPath("/private/data/p/a.txt", in: "/data/p") == "/private/data/p/a.txt")
        #expect(ChatFileChanges.displayPath("/data/p/a.txt", in: "/private/data/p") == "/data/p/a.txt")
        #expect(ChatFileChanges.displayPath("/private/data/p/a.txt", in: "/private/data/p") == "a.txt")
        #expect(ChatFileChanges.displayPath("/private/tmpfiles/a.txt", in: "/tmpfiles") == "/private/tmpfiles/a.txt")
    }

    @Test func ompPatchNamesItsFilesInEitherHeaderForm() {
        let patch = [
            "*** Begin Patch", "*** Add File: hello.txt", "+Hello world", "*** Update File: src/app.py",
            "*** Move to: src/main.py", "@@ def greet():", "-print(\"Hi\")", "+print(\"Hello\")",
            "*** Delete File: obsolete.txt", "*** End Patch",
        ]
        #expect(PiFileChanges.patchPaths(patch.joined(separator: "\n")) == ["hello.txt", "src/app.py", "obsolete.txt"])
        let hashline = [
            "*** Begin Patch", "[notes.txt#B6C1]", "PUT 2.=2:", "+[fake.txt#AAAA]", "[src/a b.swift#1F]", "CUT 3",
            "[notes.txt#C2D3]", "*** End Patch",
        ]
        #expect(PiFileChanges.patchPaths(hashline.joined(separator: "\n")) == ["notes.txt", "src/a b.swift"])
        #expect(PiFileChanges.patchPaths("*** Begin Patch\n[not a header]\n[x#]\n*** End Patch").isEmpty)
    }

    /// A V4A context line repeats a file line after one space, and that
    /// line may look like a hashline header; headers start at column 0.
    @Test func ompPatchContextLinesAreNeverHeaders() {
        let patch = [
            "*** Begin Patch", "*** Update File: config.ini", "@@ [server]", " [server#1]", "-port = 1",
            "+port = 2", "  *** Delete File: kept.txt", "*** End Patch",
        ]
        #expect(PiFileChanges.patchPaths(patch.joined(separator: "\r\n")) == ["config.ini"])
        #expect(PiFileChanges.patchPaths("[notes.txt#B6C1]  \r\nPUT 2.=2:") == ["notes.txt"])
    }

    @Test func piEditPatchBecomesFileChanges() throws {
        // Pi 0.85.1 (live capture t03): the call names the file, the result
        // records a unified patch beside a display-only diff.
        var reducer = PiTranscriptReducer()
        let lines = Self.lines([
            #"{"type":"session","version":3,"id":"01a140af-4fae-7475-af1c-10e55f811a43","cwd":"/private/tmp/heeler-iso-pi3/proj"}"#,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"Change beta to BETA in notes.txt"}}"#,
            #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-37dafb50-4c0d-467b-8031-c2cbf1eda552-2|fc_2e7392f6-34f5-938f-afc1-7a5117e011f7_0","name":"edit","arguments":{"path":"notes.txt","edits":[{"oldText":"beta","newText":"BETA"}]}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"call-37dafb50-4c0d-467b-8031-c2cbf1eda552-2|fc_2e7392f6-34f5-938f-afc1-7a5117e011f7_0","toolName":"edit","content":[{"type":"text","text":"Successfully replaced 1 block(s) in notes.txt."}],"details":{"diff":" 1 alpha\n-2 beta\n+2 BETA\n 3 gamma","patch":"--- notes.txt\n+++ notes.txt\n@@ -1,3 +1,3 @@\n alpha\n-beta\n+BETA\n gamma\n","firstChangedLine":2},"isError":false}}"#,
        ])
        reducer.append(lines)
        let tool = try #require(Self.toolRow(reducer.transcript(.init())))

        #expect(tool.title == "notes.txt")
        #expect(tool.diff == ChatDiffStats(added: 1, removed: 1))
        let changes = try #require(tool.fileChanges)
        #expect(changes.files.map(\.path) == ["notes.txt"])
        #expect(
            changes.files.first?.hunks == [
                ChatDiffHunk(
                    oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" alpha", "-beta", "+BETA", " gamma"])
            ])
        let result = try #require(lines.last)
        guard case .preview(_, let expanded)? = reducer.output(of: result, for: tool) else {
            Issue.record("expected the result's output")
            return
        }
        #expect(expanded == changes)
    }

    @Test func ompNumberedDiffSplitsIntoHunks() {
        // Two changes far apart, and a blank line before a third: context
        // and removed lines count the old file, added lines the new one.
        let diff = [
            " 1|a", "-2|b", "+2|B", "+3|B2", " 3|c",
            " 40|x", "-41|y", " 42|z",
            "",
            "+60|tail",
        ].joined(separator: "\n")
        #expect(
            PiFileChanges.numberedHunks(diff) == [
                ChatDiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 4, lines: [" a", "-b", "+B", "+B2", " c"]),
                ChatDiffHunk(oldStart: 40, oldLines: 3, newStart: 41, newLines: 2, lines: [" x", "-y", " z"]),
                ChatDiffHunk(oldStart: 59, oldLines: 0, newStart: 60, newLines: 1, lines: ["+tail"]),
            ])
        #expect(PiFileChanges.numberedHunks(" 1|a\n@@ -1 +1 @@") == nil)
    }

    /// Oh My Pi 18.11.1's write (OMP-05): the result records only where it
    /// wrote, and the call holds the text.
    private static let ompWrite = [
        header,
        #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"create todo.txt"}}"#,
        #"{"type":"message","id":"c","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"w1","name":"write","arguments":{"path":"todo.txt","content":"buy milk\n"}}],"stopReason":"toolUse"}}"#,
        #"{"type":"message","id":"r","parentId":"c","message":{"role":"toolResult","toolCallId":"w1","toolName":"write","content":[{"type":"text","text":"Successfully wrote 9 bytes to todo.txt"}],"details":{"resolvedPath":"/project/todo.txt"},"isError":false}}"#,
    ]

    @Test func ompWriteShowsItsTextAsWritten() throws {
        var reducer = PiTranscriptReducer(program: .omp)
        let lines = Self.lines(Self.ompWrite)
        reducer.append(lines)
        let tool = try #require(Self.toolRow(reducer.transcript(.init())))

        #expect(tool.kind == .fileWrite)
        #expect(tool.title == "todo.txt")
        #expect(tool.status == .succeeded)
        #expect(tool.diff == ChatDiffStats(added: 1, removed: 0))
        let changes = try #require(tool.fileChanges)
        #expect(changes.files.map(\.kind) == [.written])
        #expect(changes.files.first?.added == 1)
        #expect(
            changes.files.first?.hunks == [
                ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+buy milk"])
            ])
        #expect(tool.showsDiffAsOutput)
        #expect(ChatTimelineProjection.summary(of: [tool]) == "Wrote 1 file")

        // An expanded row, its lines dropped as the cache drops them, reads
        // them again from the call.
        #expect(tool.output == ChatOutputReference(offset: lines[2].offset, length: lines[2].length))
        var cached = tool
        cached.fileChanges = try JSONDecoder().decode(ChatFileChanges.self, from: JSONEncoder().encode(changes))
        guard case .preview(.none, let expanded)? = reducer.output(of: lines[2], for: cached) else {
            Issue.record("expected the call's text")
            return
        }
        #expect(expanded == changes)
    }

    @Test func failedOrEmptyWriteShowsItsResult() throws {
        var failed = Self.ompWrite
        failed[3] = failed[3].replacingOccurrences(of: #""isError":false"#, with: #""isError":true"#)
        var empty = Self.ompWrite
        empty[2] = empty[2].replacingOccurrences(of: #""buy milk\n""#, with: #""""#)
        for rows in [failed, empty] {
            var reducer = PiTranscriptReducer(program: .omp)
            reducer.append(Self.lines(rows))
            let tool = try #require(Self.toolRow(reducer.transcript(.init())))
            #expect(tool.fileChanges == nil)
            #expect(tool.preview?.text == "Successfully wrote 9 bytes to todo.txt")
        }
    }

    @Test func ompMultiFileEditListsEachFile() throws {
        let details: JSONValue = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(
                #"{"diff":"-1|a\n+1|A\n\n+1|new","firstChangedLine":1,"perFileResults":[{"path":"/p/a.txt","op":"update","diff":"-1|a\n+1|A","firstChangedLine":1},{"path":"/p/b.txt","op":"create","diff":"+1|new","snapshotsPruned":true},{"path":"/p/c.txt","op":"delete","diff":""}]}"#
                    .utf8))
        let changes = try #require(PiFileChanges.changes(details: details, callPath: nil, directory: "/p"))

        #expect(changes.files.map(\.path) == ["/p/a.txt", "/p/b.txt", "/p/c.txt"])
        #expect(changes.files.map(\.kind) == [.updated, .created, .deleted])
        #expect(changes.files.map(\.added) == [1, 1, 0])
        #expect(PiFileChanges.changes(details: .object([:]), callPath: "/p/a.txt", directory: nil) == nil)
    }

    // MARK: Steering

    /// Pi writes a message sent during a turn as a plain prompt the moment
    /// the turn's tool batch ends, before its next reply.
    @Test func piSteerStaysInRunningTurn() {
        let rows = [
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"start"}}"#,
            #"{"type":"message","id":"a1","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"ls"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r1","parentId":"a1","timestamp":"2026-10-15T17:54:17.461Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"a.txt"}],"isError":false}}"#,
            #"{"type":"message","id":"s","parentId":"r1","timestamp":"2026-10-15T17:54:17.462Z","message":{"role":"user","content":"steer"}}"#,
            #"{"type":"message","id":"a2","parentId":"s","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"pwd"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"r2","parentId":"a2","message":{"role":"toolResult","toolCallId":"c2","toolName":"bash","content":[{"type":"text","text":"/p"}],"isError":false}}"#,
            #"{"type":"message","id":"a3","parentId":"r2","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"stop"}}"#,
        ]
        var reducer = PiTranscriptReducer()
        reducer.append(Self.lines(Array(rows.prefix(6))))
        let running = reducer.transcript(.init(activity: .working))
        #expect(running.turns.map(\.firstEntryID) == [ChatEntryID("pi:u")])
        #expect(running.turns.first?.ending == nil)
        #expect(
            running.entries.first { $0.id == ChatEntryID("pi:s") }?.content
                == .user(ChatUserMessage(text: "steer", wasQueued: true)))
        #expect(running.recordedPrompts.map(\.text) == ["start", "steer"])
        #expect(running.latestPromptOffset == running.entries.first?.sourceOffset)
        #expect(Self.tool("c2", in: running)?.status == .running)

        var finished = PiTranscriptReducer()
        finished.append(Self.lines(rows))
        let done = finished.transcript(.init())
        #expect(done.turns.count == 1)
        #expect(done.turns.first?.ending == .completed)

        // A prompt after a reply that broke off unrecorded opens a turn of
        // its own.
        var broken = PiTranscriptReducer()
        broken.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"start"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"text","text":"partial"}]}}"#,
                #"{"type":"message","id":"n","parentId":"a","message":{"role":"user","content":"next"}}"#,
            ]))
        let restarted = broken.transcript(.init(activity: .working))
        #expect(restarted.turns.map(\.ending) == [.interrupted, nil])
        #expect(restarted.entries.last?.content == .user(ChatUserMessage(text: "next")))
    }

    /// A session resumed after its process died mid-tool: the prompt typed
    /// afterwards opens a turn of its own, and the call left without a
    /// result reads as interrupted, not as running or awaiting approval.
    @Test func promptAfterResumedToolTurnOpensTurn() {
        let start = #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"start"}}"#
        let call =
            #"{"type":"message","id":"a","parentId":"u","timestamp":"2026-10-15T17:54:17.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"make"}}],"stopReason":"toolUse"}}"#
        let result =
            #"{"type":"message","id":"r","parentId":"a","timestamp":"2026-10-15T17:54:18.000Z","message":{"role":"toolResult","toolCallId":"c","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false}}"#
        func prompt(after parent: String) -> String {
            #"{"type":"message","id":"n","parentId":""# + parent
                + #"","timestamp":"2026-10-15T17:56:40.000Z","message":{"role":"user","content":"are you there?"}}"#
        }
        for program in [ChatProgram.pi, .omp] {
            var orphaned = PiTranscriptReducer(program: program)
            orphaned.append(Self.lines([Self.header, start, call, prompt(after: "a")]))
            for activity in [ChatAgentActivity.working, .blocked] {
                let transcript = orphaned.transcript(.init(activity: activity))
                #expect(transcript.turns.map(\.ending) == [.interrupted, nil])
                #expect(transcript.entries.last?.content == .user(ChatUserMessage(text: "are you there?")))
                #expect(transcript.latestPromptOffset == transcript.entries.last?.sourceOffset)
                #expect(Self.tool("c", in: transcript)?.status == .interrupted)
                #expect(transcript.pendingRequests.isEmpty)
            }

            var answered = PiTranscriptReducer(program: program)
            answered.append(Self.lines([Self.header, start, call, result, prompt(after: "r")]))
            let resumed = answered.transcript(.init(activity: .working))
            #expect(resumed.turns.map(\.ending) == [.interrupted, nil])
            #expect(resumed.entries.last?.content == .user(ChatUserMessage(text: "are you there?")))
        }

        // Oh My Pi flags its steers, so an unflagged prompt written right
        // after a tool result is not one.
        var omp = PiTranscriptReducer(program: .omp)
        omp.append(
            Self.lines([
                Self.header, start, call, result,
                #"{"type":"message","id":"n","parentId":"r","timestamp":"2026-10-15T17:54:18.001Z","message":{"role":"user","content":"next"}}"#,
            ]))
        #expect(omp.transcript(.init(activity: .working)).turns.map(\.ending) == [.interrupted, nil])
    }

    /// Oh My Pi flags a steer: here the text typed into an approval sent by
    /// "deny and send", and a draft queued behind a question.
    @Test func ompSteeringFlagStaysInTurn() throws {
        let denied = try Self.ompTranscript(through: 18)
        let steer = try #require(denied.entries.first { $0.id == ChatEntryID("pi:9fb8c963") })
        #expect(steer.content == .user(ChatUserMessage(text: "abc", wasQueued: true)))
        #expect(denied.turns.last?.firstEntryID == ChatEntryID("pi:e95de799"))
        #expect(denied.turns.last?.ending == .completed)
        #expect(denied.recordedPrompts.last?.text == "abc")

        let full = try Self.ompTranscript()
        #expect(
            full.entries.first { $0.id == ChatEntryID("pi:62cc28b8") }?.content
                == .user(ChatUserMessage(text: "my draft text", wasQueued: true)))
        #expect(!full.turns.contains { $0.firstEntryID == ChatEntryID("pi:62cc28b8") })
        #expect(full.turns.first { $0.firstEntryID == ChatEntryID("pi:ceec44cf") }?.ending == .completed)

        // A steer that lands while the call before it still runs leaves it
        // running.
        var reducer = PiTranscriptReducer(program: .omp)
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"start"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"sleep 9"}}],"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"s","parentId":"a","message":{"role":"user","content":"hurry","steering":true}}"#,
            ]))
        let running = reducer.transcript(.init(activity: .working))
        #expect(Self.tool("c", in: running)?.status == .running)
        #expect(running.turns.count == 1)
    }

    // MARK: Interruptions, errors and minor records

    @Test func piToolInterruptReadsAsInterrupted() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"sleep"}}"#,
                #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"bash","arguments":{"command":"sleep 60"}}],"stopReason":"toolUse"}}"#,
                #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"bash","content":[{"type":"text","text":"Command aborted"}],"isError":true}}"#,
                #"{"type":"message","id":"e","parentId":"r","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"This operation was aborted"}}"#,
            ]))
        let transcript = reducer.transcript(.init())
        guard case .tool(let tool) = transcript.entries[1].content else {
            Issue.record("Tool missing")
            return
        }
        #expect(tool.status == .interrupted)
        #expect(transcript.entries.last?.content == .notice(ChatNotice(kind: .interrupted, title: "Interrupted")))
        #expect(transcript.turns.last?.ending == .interrupted)
    }

    @Test func providerErrorStillShowsAgentError() throws {
        let lines = try ChatFixture.lines("pi/auth-error-skill.jsonl")
        var reducer = PiTranscriptReducer()
        reducer.append(Array(lines.prefix(5)))
        let transcript = reducer.transcript(.init())
        #expect(
            transcript.entries.last?.content
                == .notice(
                    ChatNotice(
                        kind: .error, title: "Agent error",
                        detail:
                            "OAuth refresh failed for xai: xAI OAuth token refresh failed (HTTP 400): invalid_grant: Invalid or unknown refresh token"
                    )))
        #expect(transcript.turns.last?.ending == .failed)
    }

    /// Pi retries a connection error on its own: the turn keeps running
    /// through the countdown, and the retry's reply ends it. Pi's screen
    /// keeps the error above the answer, and so does Chat.
    @Test func retriedProviderErrorKeepsTurnRunning() throws {
        let lines = try ChatFixture.lines("pi/provider-retry.jsonl")
        let error = ChatNotice(kind: .error, title: "Agent error", detail: "Connection error.")
        var reducer = PiTranscriptReducer()
        reducer.append(Array(lines.prefix(5)))

        let retrying = reducer.transcript(.init(activity: .working))
        #expect(retrying.turns.count == 1)
        #expect(retrying.turns.last?.ending == nil)
        #expect(retrying.entries.last?.content == .notice(error))

        // Esc during the countdown records nothing; the Agent goes idle.
        let cancelled = reducer.transcript(.init(activity: .idle))
        #expect(cancelled.turns.last?.ending == .failed)

        var finished = PiTranscriptReducer()
        finished.append(lines)
        let done = finished.transcript(.init(activity: .idle))
        #expect(done.turns.count == 1)
        #expect(done.turns.last?.ending == .completed)
        #expect(done.entries.contains { $0.content == .notice(error) })
        #expect(
            done.entries.last?.content
                == .assistant(
                    ChatAssistantMessage(
                        text:
                            "Sunlight hits air molecules and shorter blue wavelengths scatter much more than longer red ones. That scattered blue light reaches your eyes from every direction, so the sky looks blue."
                    )))
    }

    @Test func ompPlanProposalShowsPlanReadyNotInterrupted() throws {
        let transcript = try Self.ompTranscript()
        let end = try #require(transcript.entries.first { $0.id == ChatEntryID("pi:c2d14183:end") })
        #expect(end.content == .notice(ChatNotice(kind: .system, title: "Plan ready for review")))
        #expect(transcript.entries.last?.id == end.id)
        #expect(transcript.turns.last?.ending == .completed)
        #expect(transcript.diagnostics.unknownRecordTypes.isEmpty)
        #expect(!transcript.needsOlderHistory)

        // A silent abort without a plan shows nothing.
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":"go"}}"#,
                #"{"type":"message","id":"e","parentId":"u","message":{"role":"assistant","content":[],"stopReason":"aborted","errorMessage":"__omp.silent_abort__"}}"#,
            ]))
        let silent = reducer.transcript(.init())
        #expect(silent.entries.count == 1)
        #expect(silent.turns.last?.ending == .completed)
    }

    @Test func ompPlanHandOffWriteShowsNoRowOrFile() throws {
        let transcript = try Self.ompTranscript()
        let tools = transcript.entries.compactMap { entry -> ChatToolActivity? in
            if case .tool(let tool) = entry.content { tool } else { nil }
        }
        #expect(!tools.contains { $0.title.contains("xd://") })
        #expect(!tools.contains { $0.callID?.hasPrefix("call_98595df0") == true })
        #expect(transcript.entries.contains { $0.content == .notice(ChatNotice(kind: .system, title: "Plan ready for review")) })
        // The plan turn's file is the plan itself.
        let planTurn = tools.filter { $0.kind == .fileWrite }
        #expect(planTurn.map(\.title) == ["local://append-plan-ok-plan.md"])
        #expect(ChatTimelineProjection.summary(of: planTurn) == "Wrote 1 file")

        // The result alone, its call above the lines read, shows nothing either.
        let lines = try ChatFixture.lines("omp/approvals-asks-plan.jsonl")
        var reducer = PiTranscriptReducer(program: .omp)
        reducer.append(Array(lines[54...]))
        #expect(Self.tool("call_98595df0", in: reducer.transcript(.init(windowStart: 1))) == nil)
    }

    /// Oh My Pi 18.11 mounts discoverable tools (MCP tools, generate_image,
    /// report_issue) as `xd://` devices driven by `write`. Only the plan
    /// hand-off hides; any other device is a row for its tool, not a file,
    /// and one waiting on an approval is a pending request.
    @Test func ompDeviceWriteShowsAsItsTool() throws {
        let call = #"{"type":"message","id":"a","parentId":"u","message":{"role":"assistant","content":[{"type":"toolCall","id":"c","name":"write","arguments":{"path":"xd://generate_image","content":"{\"prompt\":\"a red fox\"}"}}],"stopReason":"toolUse"}}"#
        let head = [
            Self.header,
            #"{"type":"message","id":"u","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"draw a fox"}]}}"#,
            call,
        ]
        var waiting = PiTranscriptReducer(program: .omp)
        waiting.append(Self.lines(head))
        let blocked = waiting.transcript(.init(activity: .blocked))
        #expect(blocked.pendingRequests.map(\.toolName) == ["generate_image"])

        let result = #"{"type":"message","id":"r","parentId":"a","message":{"role":"toolResult","toolCallId":"c","toolName":"write","content":[{"type":"text","text":"Image saved"}],"details":{"xdev":{"tool":"generate_image","mode":"execute"}},"isError":false}}"#
        var reducer = PiTranscriptReducer(program: .omp)
        reducer.append(Self.lines(head + [result]))
        let tool = try #require(Self.tool("c", in: reducer.transcript(.init(activity: .idle))))
        #expect(tool.kind == .other)
        #expect(tool.name == "generate_image")
        #expect(tool.title == "generate_image")
        #expect(tool.status == .succeeded)
        #expect(tool.fileChanges == nil)
        #expect(tool.preview?.text == "Image saved")

        // Its result alone, the call above the lines read, still shows.
        var paged = PiTranscriptReducer(program: .omp)
        paged.append(Self.lines([Self.header, result]))
        #expect(Self.tool("c", in: paged.transcript(.init(windowStart: 1)))?.name == "generate_image")
    }

    @Test func summariesPreviewAsPlainLines() throws {
        var reducer = PiTranscriptReducer()
        reducer.append(try ChatFixture.lines("pi/summaries.jsonl"))
        let transcript = reducer.transcript(.init())
        let branch = try #require(
            transcript.entries.lazy.compactMap { entry -> ChatNotice? in
                if case .notice(let notice) = entry.content, notice.title == "Branch summary" { notice } else { nil }
            }.first)
        let compaction = try #require(
            transcript.entries.lazy.compactMap { entry -> ChatDivider? in
                if case .divider(let divider) = entry.content { divider } else { nil }
            }.first)
        for detail in [branch.detail, compaction.detail] {
            let text = try #require(detail)
            #expect(!text.contains("#"))
            #expect(!text.contains("[x]") && !text.contains("[ ]"))
            #expect(!text.contains("read-files>"))
        }
        #expect(
            branch.detail?.hasPrefix(
                "The user explored a different conversation branch before returning here.\nSummary of that exploration:\nGoal\nUser requested the assistant to say “four”.\nConstraints & Preferences\n• (none)"
            ) == true)
        #expect(branch.detail?.contains("• Assistant replied with “four”") == true)
        #expect(compaction.detail?.hasPrefix("Goal\n• Simple reply tasks (trust fixture, say words)\n") == true)
        #expect(compaction.detail?.hasSuffix("build directly on that prompt.") == true)
        #expect(compaction.accessibilityPreview?.split(separator: "\n").count == ChatDivider.previewLines)
        #expect(compaction.accessibilityPreview.map { compaction.detail?.hasPrefix($0) == true } == true)
        // Copy keeps the summary as Pi wrote it.
        #expect(branch.rawDetail?.contains("## Goal\n") == true)
    }

    @Test func discardedBranchSummaryIsHidden() throws {
        let transcript = try Self.ompTranscript()
        #expect(!transcript.entries.contains { $0.id == ChatEntryID("pi:89c4c5bd") })

        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"branch_summary","id":"empty","parentId":null,"fromId":"x","summary":""}"#,
                #"{"type":"branch_summary","id":"kept","parentId":"empty","fromId":"x","summary":"Tried another fix"}"#,
            ]))
        #expect(
            reducer.transcript(.init()).entries.map(\.content)
                == [.notice(ChatNotice(kind: .system, title: "Branch summary", detail: "Tried another fix"))])
    }

    @Test func minorRoles() {
        var reducer = PiTranscriptReducer()
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"session_info","id":"n1","parentId":null,"name":"Named"}"#,
                #"{"type":"message","id":"d","parentId":"n1","message":{"role":"developer","content":"continue"}}"#,
                #"{"type":"message","id":"c","parentId":"d","message":{"role":"custom","customType":"note","content":"shown","display":true}}"#,
                #"{"type":"message","id":"h","parentId":"c","message":{"role":"hookMessage","customType":"hidden","content":"not shown","display":false}}"#,
                #"{"type":"message","id":"h2","parentId":"h","message":{"role":"hookMessage","customType":"hook","content":[{"type":"text","text":"hook output"}],"display":true}}"#,
                #"{"type":"session_info","id":"n2","parentId":"h2","name":""}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(
            transcript.entries.map(\.content) == [
                .notice(ChatNotice(kind: .hook, title: "note", detail: "shown")),
                .notice(ChatNotice(kind: .hook, title: "hook", detail: "hook output")),
            ])
        #expect(transcript.diagnostics.unknownRecordTypes.isEmpty)
        #expect(transcript.title == nil)
    }

    @Test func shellAndPythonRunsShowAsCommandNotices() {
        var reducer = PiTranscriptReducer(program: .omp)
        reducer.append(
            Self.lines([
                Self.header,
                #"{"type":"message","id":"b","parentId":null,"message":{"role":"bashExecution","command":"pwd","output":"/project\n","exitCode":0}}"#,
                #"{"type":"message","id":"p","parentId":"b","message":{"role":"pythonExecution","code":"print(6*7)","output":"42\n","exitCode":0,"cancelled":false,"truncated":false,"excludeFromContext":false}}"#,
            ]))
        let transcript = reducer.transcript(.init())
        #expect(
            transcript.entries.map(\.content) == [
                .notice(ChatNotice(kind: .shellCommand, title: "pwd", detail: "/project\n")),
                .notice(ChatNotice(kind: .pythonCommand, title: "print(6*7)", detail: "42\n")),
            ])
        #expect(transcript.diagnostics.unknownRecordTypes.isEmpty)
    }

    @Test func emptyPiEditorPassesButDraftAndPopupDoNot() {
        let rule = String(repeating: "─", count: 40)
        let footer = "~/project (main)\r\n$0.000 0.0%/200k (auto)"
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .pi)
        }
        #expect(detect("\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n\(footer)") == .empty(placeholder: nil))
        #expect(detect("\(rule)\r\nexisting\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n\(footer)") == .text("existing"))
        #expect(
            detect("\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)\r\n❯ /model\r\n\(footer)") == .overlay("❯ /model"))
        #expect(!detect("\(rule)\r\n\r\n\(rule)\r\n\(footer)").isSendable)
    }

    // MARK: Pi 0.85.1 editor and footer

    private static func piState(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: .pi)
    }

    /// Pi-06 has the Update notice's rules above the editor and its project
    /// outside the home directory, so the pwd row starts with `/`; pi-17's
    /// pwd is cut with `...`; pi-14 compacts while herdr reports idle.
    @Test(arguments: [
        "pi-06-empty-editor-119", "pi-08-auth-error-idle", "pi-13-skill-invoked", "pi-14-compact-0.25s",
        "pi-16-empty-editor-120-attached", "pi-17-empty-editor-40-attached",
    ])
    func piEmptyEditorAnywhereIsEmpty(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .pi) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .pi, activity: .idle) == .send)
    }

    @Test(arguments: [
        ("pi-11-nonempty-after-popup-esc", "/pr"), ("pi-12-nonempty-editor", "hello draft text"),
        ("pi-20-nonempty-40", "a fairly long draft line that will\nwrap at forty columns"),
    ])
    func piDraftsAreText(stem: String, draft: String) throws {
        #expect(try Self.piState(stem) == .text(draft))
    }

    /// The editor holds `/`, so a draft reading would also hold; what
    /// matters is that a completion list never passes.
    @Test(arguments: ["pi-09-slash-popup", "pi-10-slash-pr-popup", "pi-19-slash-popup-40"])
    func piPopupBetweenBorderAndFooterIsOverlay(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .pi)
        switch state {
        case .overlay(let row): #expect(row.hasPrefix("→ "))
        default: Issue.record("\(stem) read as \(state)")
        }
        #expect(PreSendGate.check(screen, program: .pi, activity: .idle) != .send)
    }

    @Test func piTrustSelectorIsUnknown() throws {
        let state = try Self.piState("pi-03-trust-1s")
        guard case .unknown = state else {
            Issue.record("pi-03 read as \(state)")
            return
        }
    }

    @Test func piFooterIsMatchedByStructure() {
        let rule = String(repeating: "─", count: 40)
        let editor = "\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\(rule)"
        func detect(_ below: String...) -> InputBoxState {
            let rows = [editor] + below
            return InputBoxStateDetector.detect(ANSIScreenDecoder.decode(rows.joined(separator: "\r\n")), program: .pi)
        }
        #expect(detect("/srv/app (main)", "↑12k ↓3.4k R120k W12k CH90.0% $0.12...") == .empty(placeholder: nil))
        #expect(detect("~/app", "?/200k (auto)    model", "extension status") == .empty(placeholder: nil))
        #expect(detect("→ compact   Compact the session", "~/app", "$0.000 0.0%/200k") == .overlay("→ compact   Compact the session"))
        #expect(!detect("~/app").isSendable)
        #expect(!detect("~/app (mai...", "grok-4.5 • high").isSendable)
        #expect(detect("~/app", "$0.000 0.0%/200k").isSendable)
        let twoBlankRows = "\(rule)\r\n\u{1B}[7m \u{1B}[0m\r\n\r\n\(rule)\r\n~/app\r\n$0.000 0.0%/200k"
        #expect(!InputBoxStateDetector.detect(ANSIScreenDecoder.decode(twoBlankRows), program: .pi).isSendable)
    }

    /// Live frames with a real model: the editor keeps its cursor cell while
    /// the top rule carries the spinner (pi-31, pi-37), queued steers sit
    /// above it (pi-34, pi-35), and a retry countdown or compaction leaves
    /// a plain rule (pi-33, pi-39). Enter in an empty editor steers the turn.
    @Test(arguments: [
        "pi-31-working-empty-120", "pi-34-steer-queued-empty", "pi-35-steer-queued-tool",
        "pi-37-working-empty-40", "pi-39-compacting-empty",
    ])
    func piLiveWorkingEditorIsEmpty(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .pi) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .pi, activity: .working) == .send)
    }

    /// A draft typed while Pi works, kept through a retry countdown, or put
    /// back by Esc with a queued steer would be joined to a sent prompt.
    @Test(arguments: [
        ("pi-32-working-draft-120", "draft typed while working"),
        ("pi-33-retry-countdown-draft", "draft typed while working"),
        ("pi-36-steer-back-in-editor", "Queued steer: say MANGO."),
        ("pi-38-working-draft-40", "draft at forty cols"),
    ])
    func piLiveDraftsHoldTheSend(stem: String, draft: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .pi) == .text(draft))
        #expect(PreSendGate.check(screen, program: .pi, activity: .working) != .send)
    }

    /// Pi 0.85 sets its spinner into the editor's top rule while a turn
    /// runs (`── ⠸ Working ───`); Enter then steers the turn.
    @Test func piWorkingEditorAcceptsSteer() {
        let rule = String(repeating: "─", count: 40)
        let working = "── \u{2838} Working " + String(repeating: "─", count: 28)
        let footer = "~/app (main)\r\n$0.000 0.3%/200k (auto)"
        func detect(_ rows: String...) -> InputBoxState {
            InputBoxStateDetector.detect(
                ANSIScreenDecoder.decode((rows + [footer]).joined(separator: "\r\n")), program: .pi)
        }
        let cursor = "\u{1B}[7m \u{1B}[0m"
        #expect(detect(working, cursor, rule) == .empty(placeholder: nil))
        #expect(
            detect(" Steering: hi", " ↳ Option+Up to edit all queued messages", working, cursor, rule)
                == .empty(placeholder: nil))
        #expect(detect(working, "more\(cursor)", rule) == .text("more"))
        // An answer's own rule above the editor is not its top border.
        #expect(detect(rule, "answer", working, cursor, rule) == .empty(placeholder: nil))
        // A scrolled editor's rule hides lines of a draft.
        #expect(!detect("─── ↑ 2 more " + String(repeating: "─", count: 27), cursor, rule).isSendable)
        // Oh My Pi draws no such rule.
        #expect(
            !InputBoxStateDetector.detect(
                ANSIScreenDecoder.decode([working, cursor, rule, footer].joined(separator: "\r\n")), program: .omp
            ).isSendable)
    }

    @Test func emptyOMPBoxPassesButMultilineDraftDoesNot() {
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .omp)
        }
        #expect(
            detect("╭── Ready ──────────────────────╮\r\n╰─ ▏                          ─╯") == .empty(placeholder: nil))
        #expect(
            !detect(
                "╭──────────────────────────────╮\r\n│ first line                  │\r\n╰─ second▏                    ─╯"
            ).isSendable)
        #expect(!detect("custom editor without a known border").isSendable)
    }

    @Test(arguments: ["────────────────44%────300K─", "──44%┃300K─"])
    func ompBandWithHardwareCursorIsRecognizedBeforeSending(gauge: String) {
        // OMP 18.10.4 default band composer, read through herdr 0.9.1.
        // agent.read serializes cells, so the hardware cursor is absent.
        let band = "\u{1B}[48;2;15;18;22m π > model > 📁 project \u{1B}[0m\(gauge)"
        let screen = ANSIScreenDecoder.decode("\(band)\r\n\u{1B}[38;2;236;70;140m╰─ \u{1B}[0m          ")
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) == .send)
        #expect(PreSendGate.check(screen, program: .omp, activity: .blocked) == .holdBlocked)
    }

    /// Oh My Pi 18.13.3's unicode band, as recorded in the #541 acceptance:
    /// under profile `hwa` on Windows (`ch-70-ompterm2.png`, where every Send
    /// from Chat said it found no input box), under profile `work` and with
    /// no profile on Linux. Before the first message the prompt carries ⇧⇥
    /// and the italic hint. The runs recorded text and a screenshot, no ANSI:
    /// the band's fill is 18.10.4's, which the screenshot's band shows too
    /// (RGB 14, 18, 22 behind the segments).
    @Test(arguments: [
        (" π-hwa > ◒ GPT-5.6 Luna (ZenMux) > 📁 …s/chat2/omp ", "─4%─┃200K─"),
        (" π-work > ⬢ Fake > 📁 ~/work ▶", "──────────6%──────────┃──────128K─"),
        (" π > ⬢ GPT-5.6 Luna (ZenMux) > 📁 …/projects/omp > ⑂ master ▶", "────4%──────────┃───────200K─"),
    ])
    func ompUnicodeBandIsEmptyBeforeTheFirstMessage(segment: String, gauge: String) {
        let band = "\u{1B}[48;2;15;18;22m\(segment)\u{1B}[0m\(gauge)"
        let hint = "\u{1B}[38;2;0;200;255m\u{21E7}\u{21E5} \u{1B}[0m\(SGR.italic)to change thinking effort\(SGR.reset)"
        func screen(_ prompt: String) -> ANSIScreen { ANSIScreenDecoder.decode("\(band)\r\n\(prompt)") }
        let empty = screen("╰─" + String(repeating: " ", count: 40) + hint)
        #expect(InputBoxStateDetector.detect(empty, program: .omp) == .empty(placeholder: nil))
        #expect(PreSendGate.check(empty, program: .omp, activity: .idle) == .send)
        let draft = screen("╰─ hello" + String(repeating: " ", count: 30) + hint)
        #expect(InputBoxStateDetector.detect(draft, program: .omp) == .text("hello"))
    }

    @Test func ompBandPreservesDraftsAndRefusesMenusAndIncompleteChrome() {
        let band = "\u{1B}[48;2;15;18;22m π > 📁 project \u{1B}[0m────────────────44%────300K─"
        func detect(_ text: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode(text), program: .omp)
        }
        #expect(detect("\(band)\r\n╰─ existing\r\n   second line") == .text("existing\nsecond line"))
        #expect(detect("\(band)\r\n╰─ !pwd") == .shellMode("!pwd"))
        #expect(!detect("\(band)\r\n╰─ \r\n❯ /model").isSendable)
        #expect(!detect("\(band)\r\n╰─ \r\nEsc to cancel").isSendable)
        #expect(!detect("╰─ ").isSendable)
        #expect(!detect("π > 📁 project ────────────\r\n╰─ ").isSendable)
        #expect(!detect("\(band.replacingOccurrences(of: "π >", with: "π N"))\r\n╰─ ").isSendable)
    }

    // MARK: OMP 18.11.1 nerd band composer

    private static func ompState(_ stem: String) throws -> InputBoxState {
        InputBoxStateDetector.detect(try ScreenFixture.screen(stem), program: .omp)
    }

    @Test(arguments: [
        "omp-01-startup-empty-119", "omp-02-empty-120-before-first", "omp-03-empty-40-before-first",
        "omp-07-empty-40-after-first", "omp-08-empty-120-after-first", "omp-19-compact-nospace-1s",
        "omp-26-approval-b-idle", "omp-27-ask-e-idle", "omp-28-ask2-e-after-esc-2s", "omp-29-guard-f-idle",
        "omp-30-plan-mode-on", "omp-32-plan-after-esc",
    ])
    func ompIdleNerdBandIsEmpty(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) == .send)
    }

    @Test(arguments: [
        "omp-01-startup-empty-119", "omp-02-empty-120-before-first", "omp-03-empty-40-before-first",
    ])
    func ompFirstMessageHintIsNotADraft(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let prompt = try #require(screen.rows.last { $0.text.hasPrefix("╰─ ") })
        #expect(prompt.text.contains("to change thinking effort"))
        #expect(InputBoxStateDetector.detect(screen, program: .omp) == .empty(placeholder: nil))
    }

    @Test(arguments: ["omp-05-qa-working-1s", "omp-09-tool-working-3s"])
    func ompWorkingBandHoldsWithReason(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .omp)
        #expect(state == .disabled("Oh My Pi is working. Send once it's idle, or steer from the terminal."))
        #expect(PreSendGate.check(screen, program: .omp, activity: .working) == .hold(state))
    }

    @Test(arguments: [
        ("omp-16-compact-space-after-enter", "/compact soft [focus]"),
        ("omp-29-guard-a-draft-while-working", "my draft text"),
    ])
    func ompDraftsAndGhostTextAreText(stem: String, draft: String) throws {
        #expect(try Self.ompState(stem) == .text(draft))
    }

    @Test(arguments: [
        "omp-14-slash-popup", "omp-17-compact-space-pre-enter-150ms", "omp-18-compact-nospace-150ms",
        "omp-21-after-exit-shell", "omp-33-after-exit-2",
    ])
    func ompPopupsAndShellBelowAreOverlay(stem: String) throws {
        let state = try Self.ompState(stem)
        guard case .overlay = state else {
            Issue.record("\(stem) read as \(state)")
            return
        }
    }

    /// Approval and ask panels keep the band and prompt below them, with or
    /// without a draft in the prompt.
    @Test(arguments: [
        "omp-23-approval-a-ctrlq-early", "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc",
        "omp-29-guard-b-ask-with-draft", "omp-29-guard-c-after-enter",
    ])
    func ompPanelAboveBandIsNotSendable(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        let state = InputBoxStateDetector.detect(screen, program: .omp)
        switch state {
        case .overlay, .dialog: break
        default: Issue.record("\(stem) read as \(state)")
        }
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) != .send)
    }

    @Test func ompPlanReviewIsNotSendable() throws {
        let screen = try ScreenFixture.screen("omp-31-plan-review")
        #expect(PreSendGate.check(screen, program: .omp, activity: .idle) != .send)
    }

    @Test func ompPromptHintsAreDroppedOnlyWhenItalicAndSetApart() {
        let band =
            "\u{1B}[38;2;15;18;22m\u{E0B6}\u{1B}[0m\u{1B}[48;2;15;18;22m \u{F0D57} \u{1B}[0m──3%────272K─"
        func detect(_ prompt: String) -> InputBoxState {
            InputBoxStateDetector.detect(ANSIScreenDecoder.decode("\(band)\r\n\(prompt)"), program: .omp)
        }
        let hint = "to change thinking effort"
        #expect(detect("╰─") == .empty(placeholder: nil))
        #expect(detect("╰─ hello      \(hint)") == .text("hello      \(hint)"))
        #expect(detect("╰─ hello  \(SGR.italic)\(hint)\(SGR.reset)") == .text("hello"))
        #expect(detect("╰─ hello \(SGR.italic)\(hint)\(SGR.reset)") == .text("hello \(hint)"))
        #expect(detect("╰─    \u{F0636} \(SGR.italic)to see 2 running agents\(SGR.reset)") == .empty(placeholder: nil))
        #expect(detect("╰─    \(SGR.italic)something else\(SGR.reset)") == .text("something else"))
    }

    @Test func ompUnknownBandGlyphsStayUnrecognized() {
        func detect(_ segment: String) -> InputBoxState {
            let band = "\u{1B}[48;2;15;18;22m\(segment) project \u{1B}[0m──3%────272K─"
            return InputBoxStateDetector.detect(ANSIScreenDecoder.decode("\(band)\r\n╰─ "), program: .omp)
        }
        #expect(detect("\u{E0B6} \u{2839} 1s") == .disabled("Oh My Pi is working. Send once it's idle, or steer from the terminal."))
        #expect(!detect("pi >").isSendable)
        #expect(!detect("π- >").isSendable)
        #expect(!detect("π-work>").isSendable)
        #expect(!detect("π-my work >").isSendable)
        #expect(!detect("\u{E0B6} @ explore").isSendable)
        #expect(!detect("\u{E0B6} \u{F0D58}").isSendable)
    }

    #if DEBUG && targetEnvironment(simulator)
        @Test(arguments: [ChatProgram.pi, .omp])
        func simulatorSamplesUseProductionLocatorFollowerAndReducer(program: ChatProgram) async throws {
            let path = program == .pi ? DemoPiChatSample.piPath : DemoPiChatSample.ompPath
            let reference = ConversationReference(program: program, sessionID: path)
            let adapter = try #require(ChatTranscriptAdapter.standard(for: program))
            let engine = ChatConversationEngine(
                reference: reference,
                cacheKey: ChatCacheKey(hostID: UUID(), herdrSession: "", program: program, conversationID: path),
                files: DemoChatSample.hostFiles, cache: VolatileChatTranscriptCache(), adapter: adapter)
            let snapshot = await engine.open(directories: [], context: .init(activity: .idle))
            #expect(snapshot.phase == .following(path: path))
            #expect(snapshot.older == .reachedStart)
            #expect(snapshot.transcript.diagnostics == ChatTranscriptDiagnostics())
            #expect(snapshot.transcript.entries.contains { if case .reasoning = $0.content { true } else { false } })
            #expect(
                snapshot.transcript.entries.contains {
                    if case .divider(let d) = $0.content { d.kind == .compaction } else { false }
                })
            #expect(
                snapshot.transcript.entries.contains {
                    if case .tool(let t) = $0.content { t.status == .succeeded } else { false }
                })
            #expect(snapshot.transcript.turns.count == 2)
        }
    #endif

    private static func hostFiles(_ documents: [String: Data]) -> ChatHostFiles {
        ChatHostFiles(
            status: { path in
                documents[path].map { RemoteFileStatus(kind: .regular, size: UInt64($0.count), modificationTime: 1) }
            },
            list: { request in
                let prefix = request.directory + "/"
                let names = documents.keys.filter { $0.hasPrefix(prefix) }.compactMap { path -> String? in
                    let name = String(path.dropFirst(prefix.count))
                    return !name.contains("/") && request.nameSuffixes.contains(where: name.hasSuffix) ? name : nil
                }
                return RemoteFileListing(
                    entries: names.map {
                        RemoteFileEntry(
                            name: $0, status: RemoteFileStatus(kind: .regular, size: 1, modificationTime: 1))
                    })
            },
            read: { range in
                guard let data = documents[range.path] else { return RemoteFileSlice(data: Data(), length: nil) }
                let start = Int(min(range.offset, UInt64(data.count)))
                return RemoteFileSlice(
                    data: data.subdata(in: start..<min(data.count, start + range.maxBytes)), length: UInt64(data.count))
            }, home: { "/home/test" })
    }
}
