import Foundation
import Testing

@testable import Heeler

@Suite("Antigravity CLI transcript reducer")
struct AgyTranscriptReducerTests {
    // MARK: Helpers

    /// A fixture's lines whose `step_index` is in `steps`, or all of them,
    /// with their offsets in the file.
    static func lines(_ fixture: String, steps: ClosedRange<Int>? = nil) throws -> [ChatLine] {
        let all = try ChatFixture.lines("agy/\(fixture)")
        guard let steps else { return all }
        return all.filter { line in
            guard let step = AgyStep.decode(line)?.stepIndex else { return false }
            return steps.contains(step)
        }
    }

    /// The transcript of `lines` read as a window that starts at
    /// `windowStart`: the file's head unless given.
    static func transcript(
        _ lines: [ChatLine], activity: ChatAgentActivity = .idle, windowStart: UInt64 = 0
    ) -> ChatTranscript {
        var reducer = AgyTranscriptReducer()
        reducer.append(lines)
        return reducer.transcript(ChatProjectionContext(windowStart: windowStart, activity: activity))
    }

    static func fixture(
        _ name: String, steps: ClosedRange<Int>? = nil, activity: ChatAgentActivity = .idle, windowStart: UInt64 = 0
    ) throws -> ChatTranscript {
        transcript(try lines(name, steps: steps), activity: activity, windowStart: windowStart)
    }

    private static func ids(_ entries: [ChatEntry]) -> [String] {
        entries.map(\.id.rawValue)
    }

    private static func users(_ transcript: ChatTranscript) -> [String] {
        transcript.entries.compactMap {
            if case .user(let message) = $0.content { message.text } else { nil }
        }
    }

    private static func notices(_ transcript: ChatTranscript) -> [(id: String, notice: ChatNotice)] {
        transcript.entries.compactMap {
            if case .notice(let notice) = $0.content { ($0.id.rawValue, notice) } else { nil }
        }
    }

    private static func date(_ text: String) throws -> Date {
        try Date(text, strategy: .iso8601)
    }

    // MARK: Prompts and replies

    /// Captured turns: a prompt, a reply; reasoning before a reply; a
    /// prompt of two lines; and agy's trimming of the space Chat adds.
    @Test func promptsAndRepliesReadInOrder() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 0...7)

        #expect(
            Self.ids(transcript.entries) == [
                "agy:0", "agy:1:text", "agy:2", "agy:3:thinking", "agy:3:text", "agy:4", "agy:5:thinking",
                "agy:5:text", "agy:6", "agy:7:text",
            ])
        #expect(
            Self.users(transcript) == [
                "Reply with the word lemon",
                "Without using any tools, write a numbered list of 20 fruits, one per line, each followed by one short sentence about it.",
                "Line one: reply with the word pear.\nLine two: then also the word plum.",
                "Reply with the word kiwi",
            ])
        guard case .assistant(let reply) = transcript.entries[9].content else {
            Issue.record("Expected the reply, got \(transcript.entries[9].content)")
            return
        }
        #expect(reply.text == "kiwi")
        #expect(transcript.recordedPrompts.map(\.text) == Self.users(transcript))
        #expect(transcript.recordedPrompts.map(\.entryID?.rawValue) == ["agy:0", "agy:2", "agy:4", "agy:6"])
        let lines = try Self.lines("core-turns.jsonl", steps: 0...7)
        #expect(transcript.latestPromptOffset == lines[6].offset)
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    /// A reply ends its turn, the last turn's included. A step's
    /// `created_at` is when it started, the reply's the same second as the
    /// prompt's here, so no turn records when it ended.
    @Test func turnsEndWithTheirReplies() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 0...7)

        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:0", "agy:2", "agy:4", "agy:6"])
        #expect(transcript.turns.allSatisfy { $0.ending == .completed })
        #expect(transcript.turns[0].startedAt == (try Self.date("2026-11-07T15:52:19Z")))
        #expect(transcript.turns.allSatisfy { $0.endedAt == nil })
    }

    /// Esc and Ctrl+C write nothing: the next prompt shows the turn
    /// interrupted, its call without a result.
    @Test func aPromptAfterATurnWithoutAReplyShowsItInterrupted() throws {
        let transcript = try Self.fixture("core-turns.jsonl")

        #expect(transcript.turns.count == 11)
        #expect(
            transcript.turns.map(\.ending) == [
                .completed, .completed, .completed, .completed, .completed, .completed, .completed, .interrupted,
                .interrupted, .completed, .completed,
            ])
        let interrupted = Self.notices(transcript).filter { $0.notice.kind == .interrupted }
        #expect(interrupted.map(\.id) == ["agy:23:interrupted", "agy:26:interrupted"])
        let ids = Self.ids(transcript.entries)
        #expect(ids.firstIndex(of: "agy:23:interrupted").map { ids[$0 + 1] } == "agy:25")
        for id in ["agy:23:tool:0", "agy:26:tool:0"] {
            let tool = try #require(AgyToolActivityTests.tool(id, in: transcript))
            #expect(tool.status == .interrupted)
        }
    }

    /// Prompts with nothing between them were each stopped before any
    /// output.
    @Test func consecutivePromptsWereEachStopped() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 11...16)

        #expect(transcript.turns.map(\.ending) == [.interrupted, .interrupted, .completed])
        #expect(
            Self.notices(transcript).map(\.id) == ["agy:11:interrupted", "agy:12:interrupted"])
        #expect(transcript.recordedPrompts.count == 3)
    }

    /// A declined call ends its turn, and the row says so rather than a
    /// notice.
    @Test func aDeclinedCallEndsItsTurnWithoutANotice() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 33...36)

        #expect(transcript.turns.first?.ending == .interrupted)
        #expect(Self.notices(transcript).isEmpty)
        let tool = try #require(AgyToolActivityTests.tool("agy:34:tool:0", in: transcript))
        #expect(tool.status == .declined)
        #expect(tool.note == "Declining ended the turn")
    }

    // MARK: Background tasks

    /// A task that ends while its turn still runs adds a notice there.
    @Test func aTaskEndingMidTurnStaysInItsTurn() throws {
        let transcript = try Self.fixture("tasks-question-compact.jsonl", steps: 32...38, windowStart: 1)

        #expect(transcript.turns.count == 1)
        let notice = try #require(Self.notices(transcript).first)
        #expect(notice.id == "agy:37")
        #expect(notice.notice.kind == .taskNotification)
        #expect(notice.notice.title == "Background command finished")
        #expect(notice.notice.detail == "sleep 15; echo done · Exit code 0")
    }

    /// A task that ends after the turn's reply starts a turn the agent
    /// opened, its notice first.
    @Test func aTaskEndingAfterTheReplyOpensATurn() throws {
        let transcript = try Self.fixture("tasks-question-compact.jsonl", steps: 39...45, windowStart: 1)

        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:39", "agy:43", "agy:45"])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed, nil])
        #expect(transcript.turns[1].startedAt == (try Self.date("2026-11-07T16:04:08Z")))
        #expect(transcript.recordedPrompts.map(\.entryID?.rawValue) == ["agy:39", "agy:45"])
    }

    /// agy adds its restart notice to every resumed conversation; it shows
    /// only when it stopped a task that was still running.
    @Test func theRestartNoticeShowsOnlyForATaskItStopped() throws {
        let quiet = try Self.fixture("tasks-question-compact.jsonl", steps: 55...60, windowStart: 1)
        #expect(Self.notices(quiet).isEmpty)
        #expect(quiet.turns.count == 2)

        let stopped = try Self.fixture("written-for-tests.jsonl", steps: 0...12)
        let notice = try #require(Self.notices(stopped).first { $0.id == "agy:12" })
        #expect(notice.notice.kind == .system)
        #expect(notice.notice.title == "Background task stopped")
        #expect(notice.notice.detail == "Antigravity CLI restarted.")
    }

    // MARK: What Stop ends

    /// Steps 5 to 13 of the #644 Stop probe's conversation (2026-11-09), in
    /// the order agy wrote them: a command sent to the background after
    /// 10 s, a Stop that wrote nothing, the next prompt, and the task's end,
    /// which agy holds until that prompt: a cancel from `/tasks` (low
    /// priority) after the prompt, a finish (high) before it.
    private static func stopProbe() -> [ChatLine] {
        let conversation = "00000000-0000-4000-8000-000000000010"
        let prompt = "<USER_REQUEST>\nRun the shell command sleep 40 in the foreground and wait until it exits\n</USER_REQUEST>"
        let sleep: KeyValuePairs<String, JSONValue> = [
            "run_command": .object([
                "CommandLine": .string("sleep 40"), "WaitMsBeforeAsync": .number(10000),
                "toolSummary": .string("Run sleep 40 command"),
            ])
        ]
        return AgyToolActivityTests.lines([
            AgyToolActivityTests.step(5, "USER_EXPLICIT", "USER_INPUT", content: prompt),
            AgyToolActivityTests.step(6, "MODEL", "PLANNER_RESPONSE", calls: sleep),
            AgyToolActivityTests.step(
                7, "MODEL", "GENERIC", status: "RUNNING",
                content: AgyToolActivityTests.background(conversation, task: 7, "sleep 40")),
            AgyToolActivityTests.step(8, "USER_EXPLICIT", "USER_INPUT", content: prompt),
            AgyToolActivityTests.step(
                9, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: AgyToolActivityTests.system(
                    "Task id \"\(conversation)/task-7\" was canceled with result:\nTool execution was canceled\nLog: "
                        + "file:///home/developer/.gemini/antigravity-cli/brain/\(conversation)/.system_generated/tasks/task-7.log"
                )),
            AgyToolActivityTests.step(10, "MODEL", "PLANNER_RESPONSE", calls: sleep),
            AgyToolActivityTests.step(
                11, "MODEL", "GENERIC", status: "RUNNING",
                content: AgyToolActivityTests.background(conversation, task: 11, "sleep 40")),
            AgyToolActivityTests.step(
                12, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: AgyToolActivityTests.system(
                    "Task id \"\(conversation)/task-11\" finished with result:\nCommand exited with code 0.\n\n"
                        + "No output from the command.")),
            AgyToolActivityTests.step(13, "USER_EXPLICIT", "USER_INPUT", content: prompt),
        ])
    }

    /// The turn Stop ended still reads open, since agy writes nothing on
    /// Esc: its command sent to the background is what Stop ends, until the
    /// next prompt closes the turn.
    @Test func theOpenTurnListsTheCommandItSentToTheBackground() throws {
        let lines = Self.stopProbe()

        let stopped = Self.transcript(Array(lines.prefix(3)))
        #expect(
            stopped.openTurnBackgroundCommands == [
                ChatBackgroundCommand(callID: "agy:6:tool:0", command: "sleep 40", isRunning: true, isDaemon: false)
            ])
        #expect(stopped.openTurnBackgroundCommands.allSatisfy { $0.isStoppable })
        let started = try #require(AgyToolActivityTests.tool("agy:6:tool:0", in: stopped))
        #expect(started.status == .started)
        #expect(started.note == "Sent to the background")

        let next = Self.transcript(Array(lines.prefix(4)))
        #expect(next.openTurnBackgroundCommands.isEmpty, "the next prompt closes the turn")
        #expect(next.turns.map(\.ending) == [.interrupted, nil])
    }

    /// The cancel `k` sends comes after the next prompt, so the old row
    /// reads canceled and the notice falls in the new turn.
    @Test func aCancelFromTasksComesAfterTheNextPrompt() throws {
        let transcript = Self.transcript(Array(Self.stopProbe().prefix(5)))

        let canceled = try #require(AgyToolActivityTests.tool("agy:6:tool:0", in: transcript))
        #expect(canceled.status == .interrupted)
        #expect(canceled.note == "Canceled in the background")
        #expect(canceled.preview?.text == "Tool execution was canceled")
        let notice = try #require(Self.notices(transcript).first { $0.notice.kind == .taskNotification })
        #expect(notice.id == "agy:9")
        #expect(notice.notice.title == "Background command canceled")
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:5", "agy:8"])
        #expect(transcript.turns.map(\.ending) == [.interrupted, nil])
    }

    /// A finish agy held is written before the next prompt: the stopped
    /// turn's command then reads ended, so Stop has nothing to end.
    @Test func aFinishHeldUntilTheNextPromptEndsTheCommandInItsTurn() throws {
        let lines = Self.stopProbe()

        let held = Self.transcript(Array(lines.prefix(8)))
        #expect(
            held.openTurnBackgroundCommands == [
                ChatBackgroundCommand(callID: "agy:10:tool:0", command: "sleep 40", isRunning: false, isDaemon: false)
            ])
        #expect(!held.openTurnBackgroundCommands.contains { $0.isStoppable })

        let transcript = Self.transcript(lines)
        let finished = try #require(AgyToolActivityTests.tool("agy:10:tool:0", in: transcript))
        #expect(finished.status == .succeeded)
        #expect(finished.note == "Finished in the background")
        #expect(transcript.turns.map(\.ending) == [.interrupted, .interrupted, nil])
        #expect(transcript.openTurnBackgroundCommands.isEmpty)
    }

    /// Only the open turn's commands are listed: one an earlier turn left
    /// running stays out, a daemon is listed as one, and a turn that
    /// replied lists nothing.
    @Test func onlyTheOpenTurnsCommandsAreListed() {
        let conversation = "00000000-0000-4000-8000-000000000011"
        let command = { (line: String, daemon: Bool) -> KeyValuePairs<String, JSONValue> in
            ["run_command": .object(["CommandLine": .string(line), "IsDaemon": .bool(daemon)])]
        }
        let lines = AgyToolActivityTests.lines([
            AgyToolActivityTests.step(0, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nTest\n</USER_REQUEST>"),
            AgyToolActivityTests.step(1, "MODEL", "PLANNER_RESPONSE", calls: command("npm test", false)),
            AgyToolActivityTests.step(
                2, "MODEL", "GENERIC", status: "RUNNING",
                content: AgyToolActivityTests.background(conversation, task: 2, "npm test")),
            AgyToolActivityTests.step(3, "MODEL", "PLANNER_RESPONSE", content: "The tests run in the background."),
            AgyToolActivityTests.step(4, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nServe it\n</USER_REQUEST>"),
            AgyToolActivityTests.step(5, "MODEL", "PLANNER_RESPONSE", calls: command("npm run dev", true)),
            AgyToolActivityTests.step(
                6, "MODEL", "GENERIC", status: "RUNNING",
                content: AgyToolActivityTests.background(conversation, task: 6, "npm run dev")),
            AgyToolActivityTests.step(7, "MODEL", "PLANNER_RESPONSE", calls: command("sleep 40", false)),
            AgyToolActivityTests.step(
                8, "MODEL", "GENERIC", status: "RUNNING",
                content: AgyToolActivityTests.background(conversation, task: 8, "sleep 40")),
            AgyToolActivityTests.step(9, "MODEL", "PLANNER_RESPONSE", content: "Serving."),
        ])

        let working = Self.transcript(Array(lines.prefix(9)), activity: .working)
        #expect(
            working.openTurnBackgroundCommands == [
                ChatBackgroundCommand(callID: "agy:5:tool:0", command: "npm run dev", isRunning: true, isDaemon: true),
                ChatBackgroundCommand(callID: "agy:7:tool:0", command: "sleep 40", isRunning: true, isDaemon: false),
            ])
        #expect(working.openTurnBackgroundCommands.map(\.isStoppable) == [false, true])

        #expect(Self.transcript(lines).openTurnBackgroundCommands.isEmpty, "a turn that replied is over")
    }

    // MARK: Compaction, errors and other steps

    /// `/compact` is a prompt answered by its checkpoint, which shows as a
    /// divider with the summary.
    @Test func compactionShowsItsSummaryAndEndsTheTurn() throws {
        let transcript = try Self.fixture("tasks-question-compact.jsonl", steps: 49...54, windowStart: 1)

        #expect(Self.users(transcript).first == "/compact")
        guard case .divider(let divider) = transcript.entries[1].content else {
            Issue.record("Expected the compaction divider, got \(transcript.entries[1].content)")
            return
        }
        #expect(transcript.entries[1].id.rawValue == "agy:50")
        #expect(divider.kind == .compaction)
        #expect(divider.detail?.contains("Task Overview") == true)
        #expect(transcript.turns.map(\.ending) == [.completed, .completed])
    }

    /// A tail window can start at `/compact`'s checkpoint, its prompt cut
    /// off above. The checkpoint answers that turn, so the next prompt
    /// doesn't close it as interrupted, as when the window starts at the
    /// prompt.
    @Test(arguments: [("approvals.jsonl", 47), ("tasks-question-compact.jsonl", 50)])
    func aWindowStartingAtACompactCheckpointAddsNoInterruption(_ name: String, checkpoint: Int) throws {
        let all = try Self.lines(name)
        let start = try #require(all.firstIndex { AgyStep.decode($0)?.stepIndex == checkpoint })
        try #require(start > 0)
        let window = Array(all[start...])
        let transcript = Self.transcript(window, windowStart: window[0].offset)

        #expect(transcript.entries.first?.id.rawValue == "agy:\(checkpoint)")
        #expect(!Self.notices(transcript).contains { $0.id == "agy:\(checkpoint):interrupted" })
        #expect(transcript.precedingTurnEnd?.ending == .completed)
        let fromPrompt = Self.transcript(Array(all[(start - 1)...]), windowStart: all[start - 1].offset)
        #expect(Self.notices(transcript).map(\.id) == Self.notices(fromPrompt).map(\.id))
    }

    /// An error message is a notice inside a turn that goes on. Reminders,
    /// ephemeral messages and other agents' messages show nothing, and a
    /// type Chat does not know is counted.
    @Test func errorsShowAndBookkeepingStaysHidden() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 0...12)

        let error = try #require(Self.notices(transcript).first { $0.id == "agy:4" })
        #expect(error.notice.kind == .error)
        #expect(error.notice.title == "Antigravity CLI hit an error")
        #expect(error.notice.detail == "The stream was interrupted. Please continue the task you were working on.")
        #expect(Self.notices(transcript).map(\.id) == ["agy:4", "agy:12"])
        #expect(transcript.diagnostics.unknownRecordTypes == ["MYSTERY_STEP"])
        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].ending == .completed)
    }

    /// Plan mode records the prompt after `/plan `; the echo matches the
    /// message as sent, with or without it.
    @Test func echoKeyMatchesPlanModeAndTheTrailingSpace() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 58...63)
        let recorded = try #require(transcript.recordedPrompts.first)
        #expect(recorded.text.hasPrefix("/plan Plan a tiny change"))

        let adapter = try #require(ChatTranscriptAdapter.standard(for: .agy))
        let sent = "Plan a tiny change: add a function multiply(a, b) to calc.py. Keep the plan very short (3 bullet points max). "
        #expect(adapter.echoKey(recorded.text) == adapter.echoKey(sent))
        #expect(AgyTranscriptReducer.echoKey("one\r\ntwo\rthree \n") == "one\ntwo\nthree")
        #expect(adapter.revision == AgyTranscriptReducer.revision)
        #expect(!adapter.joinsCachedHistory)
        #expect(!adapter.wantsFirstLine)
        #expect(!adapter.echoesByEntry)
        #expect(adapter.echoClockStopsWhileWorking)
        #expect(adapter.sessionCheck == nil)
        #expect(adapter.limits.automaticOlderSearch == 4 << 20)
    }

    // MARK: Windows and forks

    /// A fork's file starts at the step its parent stopped at, without the
    /// parent's steps, which Chat says.
    @Test func aForkSaysItsEarlierHistoryIsElsewhere() throws {
        let transcript = try Self.fixture("fork-head.jsonl")

        #expect(Self.ids(transcript.entries) == ["agy:2:history", "agy:2", "agy:3:text"])
        guard case .divider(let divider) = transcript.entries[0].content else {
            Issue.record("Expected a divider")
            return
        }
        #expect(divider.kind == .historyUnavailable)
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:2"])

        let window = try Self.fixture("fork-head.jsonl", windowStart: 1)
        #expect(Self.ids(window.entries) == ["agy:2", "agy:3:text"])
    }

    /// A window that starts inside a turn: its steps belong to a turn above
    /// the window, and a result whose call is above shows nothing.
    @Test func aWindowInsideATurnClosesTheTurnAbove() throws {
        let lines = try Self.lines("core-turns.jsonl", steps: 10...14)
        let transcript = Self.transcript(lines, windowStart: lines[0].offset)

        #expect(Self.ids(transcript.entries) == ["agy:11:tool:0", "agy:13:text", "agy:14"])
        #expect(transcript.precedingTurnEnd?.ending == .completed)
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:14"])
        #expect(transcript.needsOlderHistory)
    }

    /// Older history read later joins the same steps under the same ids.
    @Test func prependedHistoryKeepsIDs() throws {
        let all = try Self.lines("core-turns.jsonl")
        var reducer = AgyTranscriptReducer()
        reducer.append(Array(all[10...]))
        reducer.prepend(Array(all[..<10]))

        let joined = reducer.transcript(ChatProjectionContext(windowStart: 0, activity: .idle))
        #expect(joined == Self.transcript(all))
    }

    /// A line that is not JSON is counted and skipped.
    @Test func invalidLinesAreCounted() throws {
        var lines = try Self.lines("core-turns.jsonl", steps: 0...1)
        let end = lines[1].offset + UInt64(lines[1].length) + 1
        lines.append(ChatLine(offset: end, data: Data("not json".utf8)))
        let transcript = Self.transcript(lines)

        #expect(transcript.diagnostics.invalidLines == 1)
        #expect(transcript.entries.count == 2)
    }
}
