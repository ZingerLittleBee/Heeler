import Foundation
import Testing

@testable import Heeler

@Suite("Grok Build transcript reducer")
struct GrokTranscriptReducerTests {
    private static let path =
        "/home/dev/.grok/sessions/%2Fhome%2Fdev%2Fproj/01900000-0000-7000-8000-000000000004/updates.jsonl"

    // MARK: Helpers

    /// Lines `range` of a `grok/` fixture (1-based, inclusive), with their
    /// offsets in the file.
    private static func lines(_ fixture: String, _ range: ClosedRange<Int>? = nil) throws -> [ChatLine] {
        let all = try ChatFixture.lines("grok/\(fixture)")
        guard let range else { return all }
        return Array(all[(range.lowerBound - 1)..<range.upperBound])
    }

    /// The transcript of `lines` read as a window that starts at the first
    /// of them, as a reader whose tail starts there feeds them.
    private static func transcript(
        _ lines: [ChatLine], activity: ChatAgentActivity = .idle, windowStart: UInt64? = nil
    ) -> ChatTranscript {
        var reducer = GrokTranscriptReducer(transcriptPath: path)
        reducer.append(lines)
        return reducer.transcript(
            ChatProjectionContext(windowStart: windowStart ?? lines.first?.offset ?? 0, activity: activity))
    }

    private static func fixture(
        _ name: String, lines range: ClosedRange<Int>? = nil, activity: ChatAgentActivity = .idle
    ) throws -> ChatTranscript {
        transcript(try lines(name, range), activity: activity)
    }

    private static func at(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func ids(_ entries: [ChatEntry]) -> [String] {
        entries.map(\.id.rawValue)
    }

    /// Entries other than tool rows, which `GrokToolActivityTests` cover.
    private static func shown(_ transcript: ChatTranscript) -> [ChatEntry] {
        transcript.entries.filter {
            if case .tool = $0.content { false } else { true }
        }
    }

    private static func users(_ transcript: ChatTranscript) -> [ChatEntry] {
        transcript.entries.filter {
            if case .user = $0.content { true } else { false }
        }
    }

    private static func notices(_ transcript: ChatTranscript) -> [ChatEntry] {
        transcript.entries.filter {
            if case .notice = $0.content { true } else { false }
        }
    }

    // MARK: Synthetic records

    /// GrokTranscriptLocatorTests' test-only session id.
    private static let session = "01900000-0000-7000-8000-000000000010"
    private static let promptID = "01900000-0000-7000-8000-000000000011"
    private static let start: Int64 = 1_792_440_000_000

    /// One `updates.jsonl` line, keys in Grok's order: `update` and `meta`
    /// are the bodies of those objects.
    private static func record(
        _ update: String, meta: String, method: String = "session/update", at milliseconds: Int64
    ) -> String {
        #"{"timestamp":\#(milliseconds / 1_000),"method":"\#(method)","params":{"sessionId":"\#(session)","update":{\#(update)},"_meta":{\#(meta)}}}"#
    }

    private static func json(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    private static func prompt(_ text: String, index: Int?, event: Int, at milliseconds: Int64 = start) throws
        -> String
    {
        let promptIndex = index.map { #","promptIndex":\#($0)"# } ?? ""
        return record(
            #""sessionUpdate":"user_message_chunk","content":{"type":"text","text":\#(try json(text))},"_meta":{"modelId":"grok-4.7-build-fast"\#(promptIndex)}"#,
            meta: #""eventId":"\#(session)-\#(event)","agentTimestampMs":\#(milliseconds)"#, at: milliseconds)
    }

    private static func image(_ data: String, index: Int, event: Int, at milliseconds: Int64 = start) -> String {
        record(
            #""sessionUpdate":"user_message_chunk","content":{"type":"image","data":"\#(data)","mimeType":"image/png"},"_meta":{"modelId":"grok-4.7-build-fast","promptIndex":\#(index)}"#,
            meta: #""eventId":"\#(session)-\#(event)","agentTimestampMs":\#(milliseconds)"#, at: milliseconds)
    }

    private static func reply(_ text: String, event: Int, chunk: Int, at milliseconds: Int64 = start + 1_000) throws
        -> String
    {
        record(
            #""sessionUpdate":"agent_message_chunk","content":{"type":"text","text":\#(try json(text))}"#,
            meta:
                #""eventId":"\#(session)-\#(event)","agentTimestampMs":\#(milliseconds),"promptId":"\#(promptID)","turnStartMs":\#(start),"updateType":"AgentMessageChunk","chunkId":\#(chunk)"#,
            at: milliseconds)
    }

    /// A `turn_completed` without its own clock, so its end is the turn's
    /// start plus `elapsed_ms`.
    private static func completed(_ stopReason: String, event: Int, fields: String = "", meta: String = "")
        -> String
    {
        record(
            #""sessionUpdate":"turn_completed","prompt_id":"\#(promptID)","stop_reason":"\#(stopReason)"\#(fields),"elapsed_ms":2500"#,
            meta: #""eventId":"\#(session)-\#(event)"\#(meta)"#, method: "_x.ai/session/update", at: start + 2_500)
    }

    private static func lines(_ rows: [String]) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: Prompts and replies

    @Test func readsPromptsRepliesAndReasoningInFileOrder() throws {
        let transcript = try Self.fixture("core-turns.jsonl")

        let shown = Self.shown(transcript)
        #expect(
            Self.ids(shown) == [
                "grok:391", "grok:773", "grok:2059", "grok:2478", "grok:3761", "grok:4145", "grok:5430", "grok:5853",
                "grok:10999", "grok:11607",
            ])
        #expect(
            shown.map(\.content) == [
                .user(ChatUserMessage(text: "Reply with exactly the word pong.")),
                .assistant(ChatAssistantMessage(text: "pong")),
                .user(ChatUserMessage(text: "Answer with just the word ok.\nThis is line two.\nThis is line three.")),
                .assistant(ChatAssistantMessage(text: "ok")),
                .user(ChatUserMessage(text: "Reply with exactly the word ping. ")),
                .assistant(ChatAssistantMessage(text: "ping")),
                .user(ChatUserMessage(text: "Run the shell command ls -la here and tell me how many entries there are.")),
                .assistant(ChatAssistantMessage(text: "I'll list this directory and count the entries.")),
                .reasoning(
                    ChatReasoning(
                        text:
                            #"I will run ls -la and count the entries.\#n\#nThere are 4 entries. The `wc -l` output of 5 includes the "total" line."#
                    )),
                .assistant(ChatAssistantMessage(text: "`ls -la` 列出 **4** 个条目：`.`、`..`、`.git`、`README.md`。")),
            ])
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:391"), startedAt: Self.at(1_792_421_808_883),
                    endedAt: Self.at(1_792_421_826_833), ending: .completed),
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:2059"), startedAt: Self.at(1_792_421_870_282),
                    endedAt: Self.at(1_792_421_874_535), ending: .completed),
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:3761"), startedAt: Self.at(1_792_421_887_240),
                    endedAt: Self.at(1_792_421_895_726), ending: .completed),
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:5430"), startedAt: Self.at(1_792_421_901_710),
                    endedAt: Self.at(1_792_421_907_652), ending: .completed),
            ])
        #expect(
            transcript.recordedPrompts == [
                ChatRecordedPrompt(
                    offset: 391, text: "Reply with exactly the word pong.", entryID: ChatEntryID("grok:391")),
                ChatRecordedPrompt(
                    offset: 2059, text: "Answer with just the word ok.\nThis is line two.\nThis is line three.",
                    entryID: ChatEntryID("grok:2059")),
                ChatRecordedPrompt(
                    offset: 3761, text: "Reply with exactly the word ping. ", entryID: ChatEntryID("grok:3761")),
                ChatRecordedPrompt(
                    offset: 5430, text: "Run the shell command ls -la here and tell me how many entries there are.",
                    entryID: ChatEntryID("grok:5430")),
            ])
        #expect(transcript.latestPromptOffset == 5430)
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.precedingTurnEnd == nil)
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test func joinsAPromptSplitAcrossChunks() throws {
        // A prompt of three content blocks: text, an image and text, one
        // chunk each, with consecutive event numbers and one timestamp.
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 5...10)

        let prompt = "Describe this image.\nAnswer in one word."
        #expect(Self.ids(Self.users(transcript)) == ["grok:1779"])
        #expect(Self.users(transcript).first?.content == .user(ChatUserMessage(text: prompt, imageCount: 1)))
        #expect(
            transcript.recordedPrompts == [
                ChatRecordedPrompt(offset: 1779, text: prompt, entryID: ChatEntryID("grok:1779"))
            ])
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("grok:1779")])

        // A gap in the event numbers, or another second, is another prompt
        // with the same index: it takes over the first.
        let gap = Self.lines([
            try Self.prompt("Describe this.", index: 0, event: 4),
            try Self.prompt("Answer in one word.", index: 0, event: 6),
        ])
        let later = Self.lines([
            try Self.prompt("Describe this.", index: 0, event: 4),
            try Self.prompt("Answer in one word.", index: 0, event: 5, at: Self.start + 1_000),
        ])
        for lines in [gap, later] {
            #expect(
                Self.users(Self.transcript(lines)).map(\.content) == [
                    .user(ChatUserMessage(text: "Answer in one word."))
                ])
        }
    }

    @Test func aLaterChunkWithTheSameIndexTakesOverAnUnansweredPrompt() throws {
        // Ctrl+C before the first output put "eight" back in Grok's input
        // box, and the next paste joined the box's text under its index.
        let transcript = try Self.fixture("cancel-takeover.jsonl", lines: 1...6)

        #expect(Self.ids(transcript.entries) == ["grok:1220", "grok:1610"])
        #expect(
            transcript.entries.first?.content
                == .user(ChatUserMessage(text: "Count from 1 to 80, one number per line. ")))
        #expect(transcript.recordedPrompts.map(\.text) == ["Count from 1 to 80, one number per line. "])
        #expect(transcript.latestPromptOffset == 1220)
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:1220"), startedAt: Self.at(1_792_422_666_061),
                    endedAt: Self.at(1_792_422_668_575), ending: .completed)
            ])

        // After a reply, the same index is a new turn; the first ends
        // interrupted, as after a crash.
        let answered = Self.transcript(
            Self.lines([
                try Self.prompt("First.", index: 0, event: 4),
                try Self.reply("Partial", event: 6, chunk: 1),
                try Self.prompt("Second.", index: 0, event: 9, at: Self.start + 5_000),
            ]), activity: .working)
        #expect(Self.users(answered).count == 2)
        #expect(answered.turns.map(\.ending) == [.interrupted, nil])
    }

    @Test func aPromptStoppedBeforeAReplyEndsInterruptedOnceIdle() throws {
        // Up to the orphan, and the hook the next prompt ran.
        let transcript = try Self.fixture("cancel-takeover.jsonl", lines: 1...3, activity: .idle)

        #expect(Self.ids(transcript.entries) == ["grok:391", "grok:391:notice"])
        #expect(
            transcript.entries.last?.content
                == .notice(
                    ChatNotice(
                        kind: .stopped, title: "Stopped before a reply",
                        detail: "Grok Build put the message back in its input box.")))
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:391"), startedAt: Self.at(1_792_422_644_606), ending: .interrupted)
            ])
        // The send it echoed stays recorded.
        #expect(transcript.recordedPrompts.map(\.text) == ["Reply with exactly: eight. "])
    }

    @Test(arguments: [ChatAgentActivity.working, .blocked])
    func anUnansweredPromptStaysOpenWhileWorking(activity: ChatAgentActivity) throws {
        let transcript = try Self.fixture("cancel-takeover.jsonl", lines: 1...3, activity: activity)

        #expect(Self.ids(transcript.entries) == ["grok:391"])
        #expect(transcript.turns.map(\.ending) == [nil])
    }

    @Test func hidesAgentStartedPromptsButKeepsTheirTurns() throws {
        // A background command's completion woke Grok with a hidden prompt.
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 29...31)

        #expect(Self.ids(transcript.entries) == ["grok:13068"])
        #expect(
            transcript.entries.first?.content
                == .assistant(ChatAssistantMessage(text: "The background sleep finished.")))
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:13068"), startedAt: Self.at(1_792_430_090_500),
                    endedAt: Self.at(1_792_430_092_090), ending: .completed)
            ])
        #expect(transcript.recordedPrompts.isEmpty)
        #expect(transcript.latestPromptOffset == nil)

        // Until the turn places an entry, it has none.
        let unanswered = try Self.fixture("agent-turns-and-errors.jsonl", lines: 29...29)
        #expect(unanswered.entries.isEmpty)
        #expect(unanswered.turns.isEmpty)
    }

    @Test func showsSkillsAndInterjectionsByTheirDisplayText() throws {
        let skill = try Self.fixture("agent-turns-and-errors.jsonl", lines: 1...4)
        #expect(
            Self.users(skill).map(\.content) == [
                .user(
                    ChatUserMessage(
                        text: "/probe-hello world", command: ChatCommandInvocation(name: "probe-hello", arguments: "world")
                    ))
            ])
        #expect(skill.recordedPrompts.map(\.text) == ["/probe-hello world"])

        // A message sent while Grok works, in steer mode: no prompt index.
        let steered = try Self.fixture("agent-turns-and-errors.jsonl", lines: 11...16)
        #expect(Self.ids(Self.users(steered)) == ["grok:4056", "grok:5323"])
        #expect(Self.users(steered).last?.content == .user(ChatUserMessage(text: "Also say ready.", wasQueued: true)))
        #expect(steered.turns.map(\.firstEntryID) == [ChatEntryID("grok:4056")])
        #expect(steered.turns.map(\.ending) == [.completed])
        #expect(
            steered.recordedPrompts.map(\.text) == ["Run the shell command sleep 5, then say done.", "Also say ready."])
        #expect(steered.latestPromptOffset == 5323)
    }

    @Test func stripsForkAndResumeContextWrappers() throws {
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 32...37)

        let prompts = ["Reply with the word pear.", "Before we go on: reply with the word plum."]
        #expect(Self.users(transcript).map(\.content) == prompts.map { .user(ChatUserMessage(text: $0)) })
        #expect(transcript.recordedPrompts.map(\.text) == prompts)
    }

    @Test func showsAShellModeCommandAsANotice() throws {
        // `!echo hi` typed in Grok after the "lime" turn failed.
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 22...28)

        let shell = try #require(transcript.entries.first { $0.id.rawValue == "grok:10718:notice" })
        #expect(shell.content == .notice(ChatNotice(kind: .shellCommand, title: "echo hi")))
        #expect(Self.ids(Self.users(transcript)) == ["grok:9552"])
        #expect(transcript.recordedPrompts.map(\.text) == ["Reply with the word lime."])
        #expect(transcript.latestPromptOffset == 9552)
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("grok:9552")])
    }

    @Test func countsImagesWithoutDecodingThem() throws {
        let transcript = Self.transcript(
            Self.lines([
                try Self.prompt("What do these show?", index: 0, event: 4),
                Self.image("not base64 at all", index: 0, event: 5),
                Self.image("iVBORw0KGgo=", index: 0, event: 6),
            ]))

        #expect(
            Self.users(transcript).map(\.content) == [
                .user(ChatUserMessage(text: "What do these show?", imageCount: 2))
            ])
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    // MARK: Turns

    struct Cancel: Sendable, CustomTestStringConvertible {
        var category: String?
        var trigger: String?

        init(_ category: String?, _ trigger: String? = nil) {
            self.category = category
            self.trigger = trigger
        }

        var testDescription: String { [category, trigger].compactMap { $0 }.joined(separator: " ") }
    }

    struct Ending: Sendable, CustomTestStringConvertible {
        var turn: ChatTurn.Ending
        var notice: ChatNotice?

        init(_ turn: ChatTurn.Ending, _ kind: ChatNotice.Kind? = nil, _ title: String = "", detail: String? = nil) {
            self.turn = turn
            notice = kind.map { ChatNotice(kind: $0, title: title, detail: detail) }
        }

        var testDescription: String { [turn.rawValue, notice?.title].compactMap { $0 }.joined(separator: ", ") }
    }

    private static let endings: [(String, Cancel?, Ending)] = [
        ("end_turn", nil, Ending(.completed)),
        ("cancelled", Cancel("MidTurnAbort", "ctrl_c"), Ending(.interrupted, .stopped, "Stopped")),
        ("cancelled", Cancel("MidTurnAbort", "esc"), Ending(.interrupted, .stopped, "Stopped")),
        ("cancelled", Cancel("MidTurnAbort", "mouse"), Ending(.interrupted, .stopped, "Stopped")),
        ("cancelled", Cancel("MidTurnAbort", "dashboard_stop"), Ending(.interrupted, .stopped, "Stopped")),
        ("cancelled", Cancel("MidTurnAbort"), Ending(.interrupted, .stopped, "Stopped")),
        ("cancelled", nil, Ending(.interrupted, .stopped, "Stopped")),
        (
            "cancelled", Cancel("MidTurnAbort", "send_now"),
            Ending(.interrupted, .interrupted, "Interrupted to send the next message")
        ),
        ("cancelled", Cancel("MidTurnAbort", "shutdown"), Ending(.interrupted, .stopped, "Grok Build exited")),
        ("cancelled", Cancel("PermissionRejected"), Ending(.interrupted)),
        (
            "cancelled", Cancel("PermissionCancelled", "ctrl_c"),
            Ending(.interrupted, .stopped, "Stopped at the permission prompt")
        ),
        ("cancelled", Cancel("HookDenied"), Ending(.interrupted, .hook, "A hook stopped the turn")),
        ("cancelled", Cancel("HookStopped"), Ending(.interrupted, .hook, "A hook stopped the turn")),
        ("cancelled", Cancel("SomethingNew", "ctrl_c"), Ending(.interrupted, .stopped, "Stopped")),
        (
            "error", nil,
            Ending(.failed, .error, "Grok Build stopped with an error", detail: "Connection reset by peer")
        ),
        ("max_tokens", nil, Ending(.completed)),
    ]

    @Test(arguments: endings)
    func endsTurnsByTheirStopReason(stopReason: String, category: Cancel?, ending: Ending) throws {
        var meta = ""
        if let trigger = category?.trigger { meta += #","cancelTrigger":"\#(trigger)""# }
        if let category = category?.category { meta += #","cancellationCategory":"\#(category)""# }
        let fields = stopReason == "error" ? #","agent_result":"Connection reset by peer","error_kind":"http""# : ""
        let lines = Self.lines([
            try Self.prompt("Reply with the word fig.", index: 0, event: 4),
            try Self.reply("Fig", event: 6, chunk: 1),
            Self.completed(stopReason, event: 8, fields: fields, meta: meta),
        ])

        let transcript = Self.transcript(lines)

        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:0"), startedAt: Self.at(Self.start),
                    endedAt: Self.at(Self.start + 2_500), ending: ending.turn)
            ])
        let notices = Self.notices(transcript)
        #expect(notices.map(\.content) == (ending.notice.map { [.notice($0)] } ?? []))
        #expect(notices.map(\.id.rawValue) == (ending.notice == nil ? [] : ["grok:\(lines[2].offset):notice"]))
        let known = ["end_turn", "cancelled", "error"].contains(stopReason)
        #expect(transcript.diagnostics.unknownRecordTypes == (known ? [] : ["stop_reason:\(stopReason)"]))
    }

    @Test func aLongErrorKeepsItsWholeTextForCopy() throws {
        let error = (1...50).map { "Line \($0) of the error." }.joined(separator: "\n")
        let transcript = Self.transcript(
            Self.lines([
                try Self.prompt("Reply with the word fig.", index: 0, event: 4),
                Self.completed("error", event: 6, fields: #","agent_result":\#(try Self.json(error))"#),
            ]))

        guard case .notice(let notice) = Self.notices(transcript).first?.content else {
            Issue.record("The error shows no notice")
            return
        }
        #expect(notice.detail == ChatToolPreview(capping: error).text)
        #expect(notice.detail != error)
        #expect(notice.rawDetail == error)
    }

    @Test func leavesATurnOpenThroughSilence() throws {
        // Grok writes a turn's last text with its end; nothing ends it
        // before that, whatever herdr reports.
        for activity in [ChatAgentActivity.idle, .unknown, .working] {
            let transcript = try Self.fixture("core-turns.jsonl", lines: 1...3, activity: activity)

            #expect(Self.ids(transcript.entries) == ["grok:391", "grok:773"])
            #expect(
                transcript.turns == [
                    ChatTurn(firstEntryID: ChatEntryID("grok:391"), startedAt: Self.at(1_792_421_808_883))
                ])
        }
    }

    @Test func lateRecordsStayInTheirClosedTurn() throws {
        // A thought written after the turn's `turn_completed`, then the
        // next prompt, while Grok works on it.
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 11...18, activity: .working)

        #expect(
            Self.ids(Self.shown(transcript)) == ["grok:4056", "grok:5323", "grok:6697", "grok:7551", "grok:8062"])
        #expect(
            Self.shown(transcript)[3].content == .reasoning(ChatReasoning(text: "Both words are sent.")))
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:4056"), startedAt: Self.at(1_792_430_030_015),
                    endedAt: Self.at(1_792_430_039_470), ending: .completed),
                ChatTurn(firstEntryID: ChatEntryID("grok:8062"), startedAt: Self.at(1_792_430_050_005)),
            ])
    }

    @Test func aWindowStartingMidTurnBelongsToTheTurnAboveIt() throws {
        // The tail starts after the `ls -la` prompt.
        let transcript = try Self.fixture("core-turns.jsonl", lines: 12...18)

        #expect(transcript.turns.isEmpty)
        // The turn's end gives how long it ran, which no loaded line starts.
        #expect(
            transcript.precedingTurnEnd
                == ChatTurnEnd(ending: .completed, endedAt: Self.at(1_792_421_907_652), duration: 5.992))
        #expect(Self.ids(Self.shown(transcript)) == ["grok:5853", "grok:10999", "grok:11607"])
        #expect(transcript.recordedPrompts.isEmpty)
        #expect(transcript.needsOlderHistory)
    }

    @Test func aTurnCompletedWithoutAnOpenTurnClosesNothing() throws {
        // The shell command's own `turn_completed` follows the failed turn.
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 22...28)

        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: ChatEntryID("grok:9552"), startedAt: Self.at(1_792_430_070_060),
                    endedAt: Self.at(1_792_430_071_040), ending: .failed)
            ])
        #expect(transcript.precedingTurnEnd == nil)
    }

    // MARK: Rewind

    @Test func rewindHidesTurnsFromTheTargetIndexOn() throws {
        let transcript = try Self.fixture("rewind.jsonl")

        #expect(Self.ids(transcript.entries) == ["grok:391", "grok:765", "grok:4054", "grok:4456"])
        #expect(
            transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "Reply with exactly: one. ")),
                .assistant(ChatAssistantMessage(text: "one")),
                .user(ChatUserMessage(text: "Reply with exactly: three.Reply with exactly: five. ")),
                .assistant(ChatAssistantMessage(text: "five")),
            ])
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("grok:391"), ChatEntryID("grok:4054")])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed])
        #expect(transcript.recordedPrompts.map(\.offset) == [391, 4054])
    }

    @Test func aRewindToTheWindowsFirstTurnKeepsTheTurnBefore() throws {
        // The window starts in turn 0's reply; the rewind targets turn 1.
        let transcript = try Self.fixture("rewind.jsonl", lines: 3...11)

        #expect(Self.ids(transcript.entries) == ["grok:765", "grok:4054", "grok:4456"])
        #expect(
            transcript.precedingTurnEnd
                == ChatTurnEnd(ending: .completed, endedAt: Self.at(1_792_421_803_262), duration: 12.852))
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("grok:4054")])
    }

    @Test func aRewindPastTheWindowHidesTheWindowBeforeIt() throws {
        // The window starts in turn 1's reply, below the target's prompt.
        let inTarget = try Self.fixture("rewind.jsonl", lines: 6...11)
        #expect(Self.ids(inTarget.entries) == ["grok:4054", "grok:4456"])
        #expect(inTarget.precedingTurnEnd == nil)

        // The same marker aimed at turn 0, whose prompt is above a window
        // that starts in its reply: the window's first prompt is turn 1.
        let text = try ChatFixture.text("grok/rewind.jsonl").replacingOccurrences(
            of: #""target_prompt_index":1"#, with: #""target_prompt_index":0"#)
        let retargeted = Array(JSONLLineFramer.lines(in: Data(text.utf8))[2...])
        let above = Self.transcript(retargeted)
        #expect(Self.ids(above.entries) == ["grok:4054", "grok:4456"])
        #expect(above.precedingTurnEnd == nil)
        #expect(above.turns.map(\.firstEntryID) == [ChatEntryID("grok:4054")])
    }

    @Test func needsOlderHistoryWheneverTheWindowStartsLater() throws {
        let lines = try Self.lines("rewind.jsonl")
        for windowStart: UInt64 in [0, 1, 2060] {
            let transcript = Self.transcript(lines.filter { $0.offset >= windowStart }, windowStart: windowStart)
            #expect(transcript.needsOlderHistory == (windowStart > 0))
        }
    }

    @Test func prependedHistoryMakesARewindExact() throws {
        let lines = try Self.lines("rewind.jsonl")
        var reducer = GrokTranscriptReducer(transcriptPath: Self.path)
        reducer.append(Array(lines[5...]))
        let tail = reducer.transcript(ChatProjectionContext(windowStart: lines[5].offset, activity: .idle))
        #expect(Self.ids(tail.entries) == ["grok:4054", "grok:4456"])

        reducer.prepend(Array(lines[..<5]))
        let whole = reducer.transcript(ChatProjectionContext(windowStart: 0, activity: .idle))

        #expect(whole == Self.transcript(lines))
        #expect(Self.ids(whole.entries) == ["grok:391", "grok:765", "grok:4054", "grok:4456"])
    }

    // MARK: Compaction and notices

    enum Compaction: String, CaseIterable, Sendable {
        /// `/compact` after a turn: the checkpoint and its completion.
        case manual
        /// Automatic compaction inside a turn: started, checkpoint, completed.
        case automatic

        var lines: ClosedRange<Int> { self == .manual ? 1...6 : 7...12 }
        var checkpoint: UInt64 { self == .manual ? 2229 : 3805 }
    }

    @Test(arguments: Compaction.allCases)
    func compactionsBecomeOneDivider(fixture: Compaction) throws {
        let transcript = try Self.fixture("compaction.jsonl", lines: fixture.lines)

        let dividers = transcript.entries.filter {
            if case .divider = $0.content { true } else { false }
        }
        #expect(Self.ids(dividers) == ["grok:\(fixture.checkpoint):compaction"])
        #expect(dividers.map(\.content) == [.divider(.compaction(summary: nil))])
        #expect(dividers.map(\.sourceOffset) == [fixture.checkpoint])
        #expect(Self.notices(transcript).isEmpty)
        #expect(transcript.turns.map(\.ending) == [.completed])
    }

    @Test func cancelledAndFailedCompactionsAreNotices() throws {
        let transcript = try Self.fixture("agent-turns-and-errors.jsonl", lines: 39...47)

        let notices = Self.notices(transcript)
        #expect(Self.ids(notices) == ["grok:17593:notice", "grok:17885:notice", "grok:19030:notice"])
        #expect(
            notices.map(\.content) == [
                .notice(ChatNotice(kind: .system, title: "Compaction was cancelled")),
                .notice(ChatNotice(kind: .stopped, title: "Stopped")),
                .notice(ChatNotice(kind: .system, title: "Compaction failed", detail: "The summary request failed.")),
            ])
        #expect(transcript.turns.map(\.ending) == [.interrupted, .completed])
    }

    @Test func retryExhaustionAndDroppedImagesAreNotices() throws {
        let images = try Self.fixture("agent-turns-and-errors.jsonl", lines: 5...10)
        #expect(Self.ids(Self.notices(images)) == ["grok:2894:notice"])
        #expect(
            Self.notices(images).map(\.content) == [
                .notice(
                    ChatNotice(kind: .system, title: "Image not sent", detail: "Image 1 was dropped before send: corrupt."))
            ])

        // A retry in progress shows nothing; giving up shows why, and so
        // does the error that ends the turn.
        let errors = try Self.fixture("agent-turns-and-errors.jsonl", lines: 18...24)
        #expect(
            Self.ids(Self.notices(errors)) == [
                "grok:8793:notice", "grok:9140:notice", "grok:9927:notice", "grok:10281:notice",
            ])
        let expired = "Your session expired. Run /login to sign in again."
        #expect(
            Self.notices(errors).map(\.content) == [
                .notice(
                    ChatNotice(kind: .error, title: "Grok Build gave up after 3 attempts", detail: "Connection reset by peer")
                ),
                .notice(
                    ChatNotice(kind: .error, title: "Grok Build stopped with an error", detail: "Connection reset by peer")),
                .notice(ChatNotice(kind: .error, title: "Grok Build gave up", detail: expired)),
                .notice(ChatNotice(kind: .error, title: "Grok Build stopped with an error", detail: expired)),
            ])
        #expect(errors.turns.map(\.ending) == [.failed, .failed])
    }

    // MARK: Diagnostics and identity

    @Test func unknownKindsAreCountedNotFatal() throws {
        var lines = try Self.lines("agent-turns-and-errors.jsonl", 38...39)
        let end = try #require(lines.last?.end)
        lines.append(ChatLine(offset: end, data: Data("not json".utf8)))
        lines.append(
            ChatLine(
                offset: end + 9,
                data: Data(#"{"timestamp":1792430121,"method":"session/update","params":{"sessionId":"x"}}"#.utf8)))

        let transcript = Self.transcript(lines)

        #expect(
            transcript.diagnostics
                == ChatTranscriptDiagnostics(invalidLines: 2, unknownRecordTypes: ["git_branch_update"]))
        #expect(Self.users(transcript).map(\.content) == [.user(ChatUserMessage(text: "Summarise the plan."))])
    }

    @Test func repairsATruncatedLine() throws {
        // A prompt cut inside its text keeps its kind but loses the text and
        // everything after it, `_meta` included.
        let core = try Self.lines("core-turns.jsonl", 1...4)
        let cut = try #require(core[1].data.range(of: Data("Reply with".utf8)))
        var lines = core
        lines[1] = ChatLine(offset: core[1].offset, length: core[1].length, data: core[1].data[..<cut.upperBound])

        let prompt = Self.transcript(lines)

        #expect(Self.ids(prompt.entries) == ["grok:391", "grok:773"])
        #expect(prompt.entries.first?.content == .notice(ChatNotice(kind: .system, title: "Message exceeds the preview limit")))
        #expect(prompt.turns.map(\.firstEntryID) == [ChatEntryID("grok:391")])
        #expect(prompt.turns.map(\.ending) == [.completed])
        #expect(prompt.recordedPrompts.isEmpty)
        #expect(prompt.latestPromptOffset == 391)
        #expect(prompt.diagnostics == ChatTranscriptDiagnostics(oversizedLines: 1))

        // An image cut inside its data still counts, and joins its prompt.
        let split = try Self.lines("agent-turns-and-errors.jsonl", 5...7)
        let data = try #require(split[1].data.range(of: Data(#""data":"AA"#.utf8)))
        var images = split
        images[1] = ChatLine(offset: split[1].offset, length: split[1].length, data: split[1].data[..<data.upperBound])

        let image = Self.transcript(images)

        let text = "Describe this image.\nAnswer in one word."
        #expect(Self.users(image).map(\.content) == [.user(ChatUserMessage(text: text, imageCount: 1))])
        #expect(image.recordedPrompts.map(\.text) == [text])
        #expect(image.diagnostics == ChatTranscriptDiagnostics(oversizedLines: 1))
    }

    @Test func neverKeysEntriesByEventID() throws {
        // Grok numbers events again after a rewind, so two records can
        // share one id.
        let reused = Self.transcript(
            Self.lines([
                try Self.prompt("One.", index: 0, event: 4),
                try Self.reply("One", event: 6, chunk: 1),
                Self.completed("end_turn", event: 7),
                try Self.prompt("Two.", index: 1, event: 4, at: Self.start + 5_000),
                try Self.reply("Two", event: 6, chunk: 1, at: Self.start + 6_000),
            ]))
        #expect(Set(reused.entries.map(\.id)).count == 4)

        for name in [
            "core-turns.jsonl", "cancel-takeover.jsonl", "rewind.jsonl", "compaction.jsonl", "dispatch-order.jsonl",
            "agent-turns-and-errors.jsonl",
        ] {
            let transcript = try Self.fixture(name)
            for entry in transcript.entries where !entry.id.rawValue.hasPrefix("grok:tool:") {
                let byOffset = "grok:\(entry.sourceOffset)"
                #expect(
                    [byOffset, byOffset + ":notice", byOffset + ":compaction"].contains(entry.id.rawValue),
                    "\(name): \(entry.id)")
            }
            #expect(Set(transcript.entries.map(\.id)).count == transcript.entries.count, "\(name)")
        }
    }

    @Test func echoKeyTrimsTheTrailingSpaceChatAdds() throws {
        #expect(GrokTranscriptReducer.echoKey("Reply with exactly the word ping. ") == "Reply with exactly the word ping.")
        #expect(GrokTranscriptReducer.echoKey("one\r\ntwo\rthree \n") == "one\ntwo\nthree")

        // Grok records the space Chat sends after a prompt.
        let adapter = ChatTranscriptAdapter.grok
        let recorded = try Self.fixture("core-turns.jsonl").recordedPrompts.map { adapter.echoKey($0.text) }
        #expect(recorded.contains(adapter.echoKey("Reply with exactly the word ping. ")))
        #expect(adapter.revision == GrokTranscriptReducer.revision)
        #expect(!adapter.joinsCachedHistory)
        #expect(!adapter.wantsFirstLine)
        #expect(!adapter.echoesByEntry)
    }
}
