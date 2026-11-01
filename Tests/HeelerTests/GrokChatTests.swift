import Foundation
import Testing

@testable import Heeler

/// Grok Build's Chat end to end: the engine, and the store above it, with
/// `ChatTranscriptAdapter.grok` over a Host's files.
@Suite("Grok Build Chat", .timeLimit(.minutes(1)))
struct GrokChatTests {
    private static let cwd = "/home/dev/proj"
    private static let host = UUID()
    /// The sessions in `grok/core-turns.jsonl`, `grok/rewind.jsonl` and
    /// `grok/dispatch-order.jsonl`.
    private static let coreTurns = "01900000-0000-7000-8000-000000000004"
    private static let rewind = "01900000-0000-7000-8000-000000000014"
    private static let dispatched = "01900000-0000-7000-8000-000000000018"

    private static func path(_ session: String) -> String {
        "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/\(session)/updates.jsonl"
    }

    /// Lines `range` of a `grok/` fixture (1-based, inclusive), as written.
    private static func text(_ fixture: String, lines range: ClosedRange<Int>) throws -> String {
        let rows = try ChatFixture.text("grok/\(fixture)").split(separator: "\n", omittingEmptySubsequences: false)
        return rows[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n") + "\n"
    }

    private static func engine(_ session: String, files: VirtualHostFiles) -> ChatConversationEngine {
        ChatConversationEngine(
            reference: ConversationReference(program: .grok, sessionID: session),
            cacheKey: ChatCacheKey(hostID: host, herdrSession: "", program: .grok, conversationID: session),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(), adapter: .grok)
    }

    @Test func opensTheBoundSessionAndFollowsAppendedLines() async throws {
        let files = VirtualHostFiles()
        let path = Self.path(Self.coreTurns)
        await files.write(try Self.text("core-turns.jsonl", lines: 1...4), at: path)
        let engine = Self.engine(Self.coreTurns, files: files)

        let opened = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .idle))

        #expect(opened.phase == .following(path: path))
        #expect(opened.transcript.entries.map(\.id.rawValue) == ["grok:391", "grok:773"])
        #expect(opened.transcript.turns.map(\.ending) == [.completed])

        await files.append(try Self.text("core-turns.jsonl", lines: 5...7), to: path)
        let polled = await engine.poll(context: ChatProjectionContext(activity: .idle))

        #expect(polled.transcript.entries.map(\.id.rawValue) == ["grok:391", "grok:773", "grok:2059", "grok:2478"])
        #expect(polled.transcript.turns.map(\.ending) == [.completed, .completed])
        #expect(polled.transcript.latestPromptOffset == 2059)
        #expect(!polled.transcript.needsOlderHistory)
    }

    // MARK: Rebinding

    /// What `agent.get` answers.
    private actor AgentRecord {
        var agent: Agent

        init(_ agent: Agent) {
            self.agent = agent
        }

        func set(_ agent: Agent) {
            self.agent = agent
        }
    }

    private static func agent(session: String, status: AgentStatus = .idle) -> Agent {
        Agent(
            terminalID: "term-1", kind: "grok", title: "", status: status, workspaceID: "w1", tabID: "t1",
            paneID: "w1:p1", cwd: cwd, revision: 1,
            agentSession: AgentSessionInfo(agent: "grok", kind: .id, source: "herdr:grok", value: session))
    }

    @MainActor
    @Test func aNewSessionReportRebindsChat() async throws {
        let files = VirtualHostFiles()
        await files.write(try ChatFixture.text("grok/core-turns.jsonl"), at: Self.path(Self.coreTurns))
        await files.write(try ChatFixture.text("grok/rewind.jsonl"), at: Self.path(Self.rewind))
        let record = AgentRecord(Self.agent(session: Self.coreTurns))
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: "w1:p1"),
            agent: Self.agent(session: Self.coreTurns), program: .grok,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { await record.agent }, cache: VolatileChatTranscriptCache(), adapter: .grok),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)))
        await store.step()
        #expect(store.conversation.phase == .following(path: Self.path(Self.coreTurns)))

        // `/new` or `/resume` in Grok moves the Agent to another session,
        // which herdr reports with the Agent.
        await record.set(Self.agent(session: Self.rewind))
        store.agentDidChange(Self.agent(session: Self.rewind))
        await store.step()

        #expect(store.conversation.phase == .following(path: Self.path(Self.rewind)))
        #expect(
            store.conversation.transcript.entries.map(\.id.rawValue) == [
                "grok:391", "grok:765", "grok:4054", "grok:4456",
            ])
    }

    @Test func waitsForUpdatesThatAreNotWrittenYet() async throws {
        let files = VirtualHostFiles()
        let path = Self.path(Self.dispatched)
        // A session dispatched from Grok's dashboard has its folder before
        // its first record.
        await files.makeDirectory((path as NSString).deletingLastPathComponent)
        let engine = Self.engine(Self.dispatched, files: files)

        let early = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .working))
        #expect(early.phase == .unavailable(.notFound(searchedAll: false)))

        // Its prompt comes before herdr's `session_start` hook record.
        await files.write(try ChatFixture.text("grok/dispatch-order.jsonl"), at: path)
        let found = await engine.open(directories: [Self.cwd], context: ChatProjectionContext(activity: .idle))

        #expect(found.phase == .following(path: path))
        #expect(
            found.transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "Reply with the word pear.")),
                .assistant(ChatAssistantMessage(text: "pear")),
            ])
        #expect(found.transcript.turns.map(\.ending) == [.completed])
    }

    // MARK: Older history above a long turn

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_792_440_000)
    }

    /// The bytes read from `path` since the records were cleared. Older
    /// history lies inside the file, so each read returns what it asked for.
    private static func bytesRead(_ files: VirtualHostFiles, from path: String) async -> Int {
        await files.reads.filter { $0.path == path }.reduce(0) { $0 + $1.maxBytes }
    }

    /// The request the timeline makes on its own while its rows fit within
    /// a screen (`ChatTimelineController.requestOlderIfShort`).
    @MainActor
    private static func requestOlderAutomatically(_ store: AgentChatStore) async {
        store.loadOlder(automatic: true)
        await finishOlderRequest(store)
    }

    /// A tap on Load Earlier Messages.
    @MainActor
    private static func tapLoadEarlierMessages(_ store: AgentChatStore) async {
        store.loadOlder()
        await finishOlderRequest(store)
    }

    /// Runs the loop's turns until the request has read its last page.
    @MainActor
    private static func finishOlderRequest(_ store: AgentChatStore) async {
        repeat {
            await store.step()
        } while store.conversation.older == .loading
    }

    /// A send from Chat as the Chat surface makes it: registered as its
    /// check starts, which takes the prompt history witness's mark, the
    /// screen read for the session check, the text typed (Grok Build logs
    /// it in the folder's prompt history), and the screen read again for
    /// the delivery check.
    @MainActor
    private static func sendFromChat(
        _ text: String, store: AgentChatStore, files: VirtualHostFiles, screen: ANSIScreen
    ) async throws -> UUID {
        let id = UUID()
        let rules = ChatSendRules(program: .grok, commands: [])
        let typed = rules.outgoingText(text)
        let policy = ComposerDeliveryPolicy.chat(
            rules: rules, activity: { .idle },
            readScreen: {
                // `agent.read` takes longer than the mark's stat.
                await store.witnessMarksSettled()
                return screen
            },
            sendConcern: { store.sendConcern(for: $0, after: $1) },
            willReadScreen: {
                store.updateSends([AgentChatStore.SentMessage(id: id, text: typed, isDelivered: false)])
            },
            pause: { _ in })
        let preflight = try #require(policy.preflight)
        let verify = try #require(policy.verify)

        #expect(await preflight(text) == nil)
        await files.append(LongTurnSession.historyLine(text), to: LongTurnSession.historyPath)
        store.updateSends([AgentChatStore.SentMessage(id: id, text: typed, isDelivered: true)])
        #expect(await verify(typed))
        return id
    }

    /// Chat opens on the end of a turn whose `read_file` results filled
    /// 34 MB, with the turn's prompt 33 MB above. The timeline's automatic
    /// request reads 4 MiB and leaves the rest behind Load Earlier Messages;
    /// a send and its checks read nothing above the tail; the automatic
    /// request the send's rows make again reads nothing; and a tap reads on
    /// to the prompt.
    @MainActor
    @Test func automaticRequestsLeaveALongTurnsPromptToLoadEarlierMessages() async throws {
        var session = LongTurnSession()
        let path = LongTurnSession.path
        let files = VirtualHostFiles()
        await files.write(session.text, at: path)
        await files.write(session.history, at: LongTurnSession.historyPath)
        let tailStart = UInt64(session.text.utf8.count - ChatTranscriptAdapter.grok.limits.tailWindow)
        let bound = try #require(ChatTranscriptAdapter.grok.limits.automaticOlderSearch)
        let clock = Clock()
        let record = AgentRecord(Self.agent(session: LongTurnSession.id))
        let store = AgentChatStore(
            agentID: ConsoleAgent.ID(hostID: Self.host, paneID: "w1:p1"),
            agent: Self.agent(session: LongTurnSession.id), program: .grok,
            source: AgentChatSource(
                hostID: Self.host, socketLocation: .defaultSession, files: files.hostFiles(),
                agentInfo: { await record.agent }, cache: VolatileChatTranscriptCache(), adapter: .grok),
            timing: AgentChatStore.Timing(activeInterval: .milliseconds(5), idleInterval: .milliseconds(5)),
            now: { clock.now })
        await store.step()
        #expect(store.conversation.phase == .following(path: path))
        try #require(store.conversation.transcript.turns.isEmpty)
        try #require(store.conversation.older == .available)

        // The few rows of the turn's end fit within a screen.
        await files.clearRecords()
        await Self.requestOlderAutomatically(store)
        let automatic = await Self.bytesRead(files, from: path)
        #expect(automatic > 0)
        #expect(automatic <= bound)
        #expect(store.conversation.older == .available)
        #expect(store.conversation.olderAwaitsUser)
        // The turn folds behind the time its end record gives.
        #expect(store.conversation.transcript.precedingTurnEnd?.duration == 136.363)

        await files.clearRecords()
        let screen = GrokScreenBuilder(scrollback: ["done", "", "Worked for 2m16s"]).screen
        let id = try await Self.sendFromChat("Reply with the word plum", store: store, files: files, screen: screen)
        #expect(await Self.bytesRead(files, from: path) == 0)
        // Grok Build has not written the prompt when the witness first reads
        // the prompt history, then writes it, the reply and the turn's end.
        let written = session.sent("Reply with the word plum", reply: "plum")
        await record.set(Self.agent(session: LongTurnSession.id, status: .working))
        store.agentDidChange(Self.agent(session: LongTurnSession.id, status: .working))
        clock.now = clock.now.addingTimeInterval(2)
        await store.step()
        #expect(await files.reads.contains { $0.path == LongTurnSession.historyPath })
        await files.append(written.prompt, to: path)
        clock.now = clock.now.addingTimeInterval(1)
        await store.step()
        await files.append(written.rest, to: path)
        await record.set(Self.agent(session: LongTurnSession.id))
        store.agentDidChange(Self.agent(session: LongTurnSession.id))
        clock.now = clock.now.addingTimeInterval(4)
        await store.step()
        #expect(store.sendStatuses[id] == .recorded)
        #expect(await files.reads.contains { $0.path == path && $0.offset < tailStart } == false)

        // The send's rows make the timeline ask again.
        await files.clearRecords()
        store.loadOlder(automatic: true)
        #expect(store.conversation.older == .available)
        await store.step()
        #expect(await Self.bytesRead(files, from: path) == 0)

        await Self.tapLoadEarlierMessages(store)
        let prompt = ChatEntryID("grok:\(session.promptOffset)")
        let turn = store.conversation.transcript.turns.first { $0.firstEntryID == prompt }
        #expect(turn?.ending == .completed)
        #expect(!store.conversation.olderAwaitsUser)
    }

    /// A Grok Build session shaped like the live turn in
    /// docs/research/grok-build-transcript-format.md (automatic
    /// compaction): 12 short turns, then one that read 21 files of 99,000
    /// bytes in four rounds, each whole file's `read_file` result a line of
    /// about 402 KB, with three automatic compactions and a failed fourth.
    /// The file is 34.2 MB, and the long turn's prompt starts 61.5 KB in.
    private struct LongTurnSession {
        static let id = "01900000-0000-7000-8000-0000000000c1"
        static let path = GrokChatTests.path(id)
        static let historyPath = "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/prompt_history.jsonl"
        static let longPrompt =
            "Use read_file to read every file in big/ in full (part01.txt to part21.txt, 21 files), in parallel if you can. Do not summarize them. Then reply with the word done."

        private(set) var text = ""
        private(set) var history = ""
        /// Where the long turn's prompt line starts.
        private(set) var promptOffset = 0
        private var event = 1
        private var clock: Int64 = 1_792_440_000_000
        private var turnStart: Int64 = 0
        private var prompts = 0
        private var calls = 0

        init() {
            line(
                "_x.ai/session/update",
                #""sessionUpdate":"hook_execution","event_name":"session_start","runs":[{"name":"global/herdr:session_start[0].hooks[0]","status":{"status":"success","elapsed_ms":46}}]"#,
                size: 0)
            let fruits = [
                "kiwi", "apple", "pear", "fig", "lime", "plum", "date", "lemon", "mango", "grape", "melon", "peach",
            ]
            for fruit in fruits {
                prompt("Reply with the word \(fruit)", size: 390)
                agent("message", fruit, size: 3_900)
                end(elapsed: 4_000, size: 800)
            }
            promptOffset = text.utf8.count
            prompt(Self.longPrompt, size: 516)
            let start = turnStart
            agent("thought", "Reading all 21 files in big/ from part01.txt to part21.txt.", size: 708)
            agent("message", "I'll check the lengths first, then read every file in full.", size: 564)
            command(call: 897, input: 1_123, result: 3_952)
            agent("thought", "Each file in big/ is exactly 1000 lines.", size: 532)
            reads(21, call: 833, input: 1_008, size: 402_669, compacts: true)
            agent("thought", "Reading all 21 files in big/ in parallel.", size: 4_154)
            agent("message", "I'll check the lengths again, then read them in parallel.", size: 544)
            command(call: 1_204, input: 2_048, result: 5_138)
            agent("thought", "Each file is 1000 lines and 99000 bytes.", size: 532)
            reads(21, call: 856, input: 1_064, size: 402_679, compacts: true)
            agent("thought", "Reading all 21 files in big/ via read_file, in chunks.", size: 2_518)
            agent("message", "I'll read all 21 files in parallel chunks.", size: 596)
            reads(63, call: 857, input: 1_066, size: 134_717, last: 141_494, compacts: true)
            agent("thought", "Reading all 21 files in big/ via read_file.", size: 1_359)
            agent("message", "I'll check the lengths, then read them in parallel.", size: 541)
            command(call: 901, input: 1_137, result: 3_955)
            agent("thought", "Each file in big/ is exactly 1000 lines.", size: 711)
            agent("message", "Every file is exactly 1000 lines. Reading all 21 now.", size: 538)
            reads(21, call: 857, input: 1_065, size: 402_680, compacts: false)
            agent("message", "done", size: 498)
            clock = start + 136_335
            end(elapsed: 136_363, size: 814)
        }

        /// One line of the folder's prompt history.
        static func historyLine(_ message: String) -> String {
            #"{"timestamp":"2026-10-20T12:50:00.000Z","session_id":"\#(id)","prompt":"\#(GrokTranscriptReducer.echoKey(message))","is_bash":false}"#
                + "\n"
        }

        /// What Grok Build writes for a message sent from Chat: its prompt
        /// line, then the reply and the turn's end.
        mutating func sent(_ message: String, reply: String) -> (prompt: String, rest: String) {
            let prompt = prompt(message, size: 378)
            let rest = agent("message", reply, size: 498) + end(elapsed: 4_517, size: 800)
            return (prompt, rest)
        }

        /// Writes a record, padded to `size` bytes with a field Chat ignores.
        @discardableResult
        private mutating func line(_ method: String, _ update: String, meta: String = "", size: Int) -> String {
            event += 1
            clock += 13
            var json =
                #"{"timestamp":\#(clock / 1_000),"method":"\#(method)","params":{"sessionId":"\#(Self.id)","update":{\#(update)},"_meta":{"eventId":"\#(Self.id)-\#(event)","agentTimestampMs":\#(clock)\#(meta)}}}"#
            let padding = size - json.utf8.count - 10
            if padding > 0 {
                json = String(json.dropLast()) + #","_pad":""# + String(repeating: "x", count: padding) + #""}"#
            }
            text += json + "\n"
            return json + "\n"
        }

        @discardableResult
        private mutating func prompt(_ message: String, size: Int) -> String {
            let written = line(
                "session/update",
                #""sessionUpdate":"user_message_chunk","content":{"type":"text","text":"\#(message)"},"_meta":{"modelId":"grok-4.7-build-fast","promptIndex":\#(prompts)}"#,
                size: size)
            prompts += 1
            turnStart = clock
            history += Self.historyLine(message)
            return written
        }

        private var turnMeta: String {
            #","promptId":"prompt-\#(prompts)","turnStartMs":\#(turnStart)"#
        }

        @discardableResult
        private mutating func agent(_ kind: String, _ message: String, size: Int) -> String {
            line(
                "session/update",
                #""sessionUpdate":"agent_\#(kind)_chunk","content":{"type":"text","text":"\#(message)"}"#,
                meta: turnMeta + #","chunkId":\#(event * 10)"#, size: size)
        }

        @discardableResult
        private mutating func end(elapsed: Int, size: Int) -> String {
            line(
                "_x.ai/session/update",
                #""sessionUpdate":"turn_completed","prompt_id":"prompt-\#(prompts)","stop_reason":"end_turn","elapsed_ms":\#(elapsed)"#,
                size: size)
        }

        private mutating func command(call callSize: Int, input: Int, result: Int) {
            calls += 1
            let id = "call-cmd-\(calls)"
            line(
                "session/update",
                #""sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"run_terminal_command","rawInput":{"command":"wc -l big/part*.txt","description":"Count lines"},"_meta":{"x.ai/tool":{"version":1,"name":"run_terminal_command","kind":"execute","namespace":"grok_build","label":"Run Command","read_only":false}}"#,
                meta: turnMeta, size: callSize)
            line(
                "session/update",
                #""sessionUpdate":"tool_call_update","toolCallId":"\#(id)","kind":"execute","title":"Execute `wc -l big/part*.txt`","rawInput":{"variant":"Bash","command":"wc -l big/part*.txt","description":"Count lines","is_background":false}"#,
                meta: turnMeta, size: input)
            line(
                "session/update",
                #""sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"completed","content":[{"type":"content","content":{"type":"text","text":"  21000 total\n"}}],"rawOutput":{"type":"Bash","exit_code":0}"#,
                meta: turnMeta, size: result)
        }

        /// `count` `read_file` calls, all but the last one's results, an
        /// automatic compaction (or a failed one), and the last result.
        private mutating func reads(
            _ count: Int, call callSize: Int, input: Int, size: Int, last: Int? = nil, compacts: Bool
        ) {
            var ids: [String] = []
            for file in 0..<count {
                calls += 1
                let id = "call-read-\(calls)"
                ids.append(id)
                let target = "/home/dev/proj/big/part\(String(format: "%02d", file % 21 + 1)).txt"
                line(
                    "session/update",
                    #""sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"read_file","rawInput":{"target_file":"\#(target)"},"_meta":{"x.ai/tool":{"version":1,"name":"read_file","kind":"read","namespace":"grok_build","label":"Read","read_only":true}}"#,
                    meta: turnMeta, size: callSize)
                line(
                    "session/update",
                    #""sessionUpdate":"tool_call_update","toolCallId":"\#(id)","kind":"read","title":"Read","locations":[{"path":"\#(target)"}],"rawInput":{"variant":"ReadFile","target_file":"\#(target)"}"#,
                    meta: turnMeta, size: input)
            }
            for id in ids.dropLast() {
                result(id, size: size)
            }
            if compacts {
                line(
                    "_x.ai/session/update",
                    #""sessionUpdate":"auto_compact_started","tokens_used":549100,"context_window":500000,"percentage":100,"reason":"Context window 100% full""#,
                    size: 363)
                line(
                    "_x.ai/session/update",
                    #""sessionUpdate":"compaction_checkpoint","checkpoint_id":"checkpoint-\#(event)","prompt_index_at_compaction":12,"checkpoint_file":"compaction_checkpoints/checkpoint-\#(event).json","schema_version":1"#,
                    size: 505)
                line(
                    "_x.ai/session/update",
                    #""sessionUpdate":"auto_compact_completed","tokens_before":549100,"tokens_after":23700,"summary_preview":null"#,
                    size: 352)
            } else {
                line(
                    "_x.ai/session/update",
                    #""sessionUpdate":"auto_compact_failed","error":"the context refilled to the limit right after each of the last 3 compactions. Auto-compaction is off for the rest of this turn. Read large files in smaller pieces, or start a new session using /new.""#,
                    size: 474)
            }
            result(ids[count - 1], size: last ?? size)
        }

        /// A whole file's `read_file` result: 1,000 rows of 99 bytes.
        private mutating func result(_ id: String, size: Int) {
            let content = String(repeating: String(repeating: "=", count: 98) + "\\n", count: 1_000)
            line(
                "session/update",
                #""sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"completed","content":[{"type":"content","content":{"type":"text","text":"\#(content)"}}],"rawOutput":{"type":"ReadFile"}"#,
                meta: turnMeta, size: size)
        }
    }
}
