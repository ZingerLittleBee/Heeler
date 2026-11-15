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
        AgyToolActivityTests.lines(stopProbeSteps())
    }

    private static func stopProbeSteps() -> [JSONValue] {
        let conversation = "00000000-0000-4000-8000-000000000010"
        let prompt = "<USER_REQUEST>\nRun the shell command sleep 40 in the foreground and wait until it exits\n</USER_REQUEST>"
        let sleep: KeyValuePairs<String, JSONValue> = [
            "run_command": .object([
                "CommandLine": .string("sleep 40"), "WaitMsBeforeAsync": .number(10000),
                "toolSummary": .string("Run sleep 40 command"),
            ])
        ]
        return [
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
        ]
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

    /// agy writes the cancel `k` sends just after the next prompt, though
    /// the task ended before it: the old row reads canceled, and the notice
    /// ends the stopped turn, after its `Interrupted`, as the finish agy
    /// writes before a prompt does, rather than opening the new turn.
    @Test func aCancelHeldForTheNextPromptEndsTheStoppedTurn() throws {
        let transcript = Self.transcript(Array(Self.stopProbe().prefix(5)))

        let canceled = try #require(AgyToolActivityTests.tool("agy:6:tool:0", in: transcript))
        #expect(canceled.status == .interrupted)
        #expect(canceled.note == "Canceled in the background")
        #expect(canceled.preview?.text == "Tool execution was canceled")
        // The probe starts at step 5, which reads as a fork's head.
        #expect(
            Self.ids(transcript.entries) == [
                "agy:5:history", "agy:5", "agy:6:tool:0", "agy:7:interrupted", "agy:9", "agy:8",
            ])
        let notice = try #require(Self.notices(transcript).first { $0.notice.kind == .taskNotification })
        #expect(notice.id == "agy:9")
        #expect(notice.notice.title == "Background command canceled")
        #expect(notice.notice.detail == "sleep 40")
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:5", "agy:8"])
        #expect(transcript.turns.map(\.ending) == [.interrupted, nil])

        let both = Self.transcript(Self.stopProbe())
        #expect(
            Self.ids(both.entries) == [
                "agy:5:history", "agy:5", "agy:6:tool:0", "agy:7:interrupted", "agy:9", "agy:8", "agy:10:tool:0",
                "agy:12", "agy:12:interrupted", "agy:13",
            ])
        #expect(both.turns.map(\.firstEntryID.rawValue) == ["agy:5", "agy:8", "agy:13"])
    }

    /// Stop's follow-through cancels each command the stopped turn sent to the
    /// background, and agy writes every cancel after the next prompt. Each one
    /// ends the stopped turn, in the order agy wrote them, and none opens the
    /// new turn.
    @Test func severalCancelsHeldForTheNextPromptAllEndTheStoppedTurn() throws {
        let conversation = "00000000-0000-4000-8000-000000000013"
        let prompt = "<USER_REQUEST>\nRun sleep 60 and sleep 90 in the background\n</USER_REQUEST>"
        func command(_ line: String) -> JSONValue {
            .object(["CommandLine": .string(line), "WaitMsBeforeAsync": .number(500)])
        }
        func cancel(_ step: Int, task: Int) -> JSONValue {
            AgyToolActivityTests.step(
                step, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: AgyToolActivityTests.system(
                    "Task id \"\(conversation)/task-\(task)\" was canceled with result:\nTool execution was canceled"))
        }
        let transcript = Self.transcript(
            AgyToolActivityTests.lines([
                AgyToolActivityTests.step(0, "USER_EXPLICIT", "USER_INPUT", content: prompt),
                AgyToolActivityTests.step(
                    1, "MODEL", "PLANNER_RESPONSE",
                    calls: ["run_command": command("sleep 60"), "run_command": command("sleep 90")]),
                AgyToolActivityTests.step(
                    2, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 2, "sleep 60")),
                AgyToolActivityTests.step(
                    3, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 3, "sleep 90")),
                AgyToolActivityTests.step(4, "USER_EXPLICIT", "USER_INPUT", content: prompt),
                cancel(5, task: 2),
                cancel(6, task: 3),
            ]))

        #expect(
            Self.ids(transcript.entries) == [
                "agy:0", "agy:1:tool:0", "agy:1:tool:1", "agy:3:interrupted", "agy:5", "agy:6", "agy:4",
            ])
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:0", "agy:4"])
        #expect(transcript.turns.map(\.ending) == [.interrupted, nil])
        for id in ["agy:1:tool:0", "agy:1:tool:1"] {
            let tool = try #require(AgyToolActivityTests.tool(id, in: transcript))
            #expect(tool.status == .interrupted)
            #expect(tool.note == "Canceled in the background")
        }
        let ends = Self.notices(transcript).filter { $0.notice.kind == .taskNotification }
        #expect(ends.map(\.notice.title) == ["Background command canceled", "Background command canceled"])
        #expect(ends.map(\.notice.detail) == ["sleep 60", "sleep 90"])
    }

    /// On herdr-core agy wrote its restart notice after the held cancel and
    /// before the new turn's first response (2026-11-09). The cancel still
    /// ends the stopped turn, and the notice, with no task left to stop,
    /// shows nothing.
    @Test func aHeldCancelBeforeARestartNoticeStillEndsTheStoppedTurn() {
        let transcript = Self.transcript(
            AgyToolActivityTests.lines(
                Array(Self.stopProbeSteps().prefix(5)) + [
                    AgyToolActivityTests.step(
                        10, "SYSTEM", "SYSTEM_MESSAGE",
                        content: AgyToolActivityTests.system(AgyTranscriptReducer.restartNotice + ".")),
                    AgyToolActivityTests.step(11, "MODEL", "PLANNER_RESPONSE", content: "Done."),
                ]))

        #expect(
            Self.ids(transcript.entries) == [
                "agy:5:history", "agy:5", "agy:6:tool:0", "agy:7:interrupted", "agy:9", "agy:8", "agy:11:text",
            ])
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:5", "agy:8"])
        #expect(transcript.turns.map(\.ending) == [.interrupted, .completed])
    }

    /// Only an end that comes straight after a prompt moves, whichever
    /// turn started its task: one an earlier turn left running that ends
    /// during a later turn's work shows there, after its rows.
    @Test func aTaskEndingDuringALaterTurnShowsInThatTurn() throws {
        let conversation = "00000000-0000-4000-8000-000000000012"
        let transcript = Self.transcript(
            AgyToolActivityTests.lines([
                AgyToolActivityTests.step(
                    0, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nServe it\n</USER_REQUEST>"),
                AgyToolActivityTests.step(
                    1, "MODEL", "PLANNER_RESPONSE",
                    calls: ["run_command": .object(["CommandLine": .string("npm run dev")])]),
                AgyToolActivityTests.step(
                    2, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 2, "npm run dev")),
                AgyToolActivityTests.step(3, "MODEL", "PLANNER_RESPONSE", content: "Serving."),
                AgyToolActivityTests.step(
                    4, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nRead the config\n</USER_REQUEST>"),
                AgyToolActivityTests.step(
                    5, "MODEL", "PLANNER_RESPONSE",
                    calls: ["view_file": .object(["AbsolutePath": .string("/work/app/config.json")])]),
                AgyToolActivityTests.step(6, "MODEL", "GENERIC", content: "{}"),
                AgyToolActivityTests.step(
                    7, "SYSTEM", "SYSTEM_MESSAGE",
                    content: AgyToolActivityTests.system(
                        "Task id \"\(conversation)/task-2\" finished with result:\nCommand exited with code 0.")),
            ]), activity: .working)

        #expect(
            Self.ids(transcript.entries) == ["agy:0", "agy:1:tool:0", "agy:3:text", "agy:4", "agy:5:tool:0", "agy:7"])
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:0", "agy:4"])
        let server = try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: transcript))
        #expect(server.note == "Finished in the background")
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

    // MARK: Background Work and Subagents

    static func systemMessage(
        timestamp: String, sender: String, priority: String = "MESSAGE_PRIORITY_HIGH", content: String
    ) -> String {
        "The following is a <SYSTEM_MESSAGE> not actually sent by the user.\n\n<SYSTEM_MESSAGE>\n"
            + "[Message] timestamp=\(timestamp) sender=\(sender) priority=\(priority) content="
            + content + "\n</SYSTEM_MESSAGE>"
    }

    static func launchedSubagentResult(_ id: String, type: String = "research", role: String = "Codebase Researcher") -> String {
        """
        Created At: 2026-11-08T00:22:00+08:00
        Completed At: 2026-11-08T00:22:01+08:00
        Created the following subagent:
        {
          "conversationId": "\(id)",
          "description": "Read-only codebase research",
          "role": "\(role)",
          "type": "\(type)"
        }
        """
    }

    /// A Subagent launched by `invoke_subagent` runs in Background Work
    /// (holding active pace while the Agent itself is idle) until its
    /// `<SYSTEM_MESSAGE>` reply arrives, ignores a trailing `list` that
    /// catches its closing turn still winding down, resumes on `send_message`,
    /// and clears from `listedBackgroundWork` after the user's next prompt.
    @Test func aSubagentRunsInBackgroundWorkUntilItRepliesAndClearsOnTheNextPrompt() throws {
        let subID = "11111111-1111-4000-8000-000000000001"
        let workID = "agy:subagent:\(subID)"
        let allLines = AgyToolActivityTests.lines([
            AgyToolActivityTests.step(
                0, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nAudit the router in the background\n</USER_REQUEST>"),
            AgyToolActivityTests.step(
                1, "MODEL", "PLANNER_RESPONSE",
                calls: [
                    "invoke_subagent": .object([
                        "TypeName": .string("research"),
                        "Role": .string("Codebase Researcher"),
                        "Prompt": .string("Inspect Router.swift"),
                    ])
                ]),
            AgyToolActivityTests.step(
                2, "MODEL", "GENERIC", content: Self.launchedSubagentResult(subID)),
            AgyToolActivityTests.step(
                3, "MODEL", "PLANNER_RESPONSE", content: "I launched a subagent and will report back when it finishes."),
            AgyToolActivityTests.step(
                4, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: Self.systemMessage(
                    timestamp: "2026-11-07T16:23:45Z", sender: subID,
                    content: "Found 3 callers in Router.swift.")),
            AgyToolActivityTests.step(
                5, "MODEL", "PLANNER_RESPONSE",
                calls: ["manage_subagents": .object(["Action": .string("list")])]),
            AgyToolActivityTests.step(
                6, "MODEL", "GENERIC",
                content: """
                    Created At: 2026-11-08T00:26:00+08:00
                    Completed At: 2026-11-08T00:26:00+08:00
                    Active direct subagents (1):
                    [
                      {"conversationId": "\(subID)", "type": "research", "role": "Codebase Researcher", "state": "running", "lastStepTime": "2026-11-07T16:23:46Z"}
                    ]
                    """),
            AgyToolActivityTests.step(
                7, "MODEL", "PLANNER_RESPONSE",
                calls: [
                    "send_message": .object([
                        "Recipient": .string(subID),
                        "Message": .string("Also check AuthRouter.swift"),
                    ])
                ]),
            AgyToolActivityTests.step(8, "MODEL", "GENERIC", content: "Message queued."),
            AgyToolActivityTests.step(
                9, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: Self.systemMessage(
                    timestamp: "2026-11-07T16:28:30Z", sender: subID,
                    content: "AuthRouter.swift has 1 caller.")),
            AgyToolActivityTests.step(10, "MODEL", "PLANNER_RESPONSE", content: "All 4 callers checked."),
            AgyToolActivityTests.step(
                11, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nThanks\n</USER_REQUEST>"),
        ])

        let running = Self.transcript(Array(allLines.prefix(4)), activity: .idle)
        #expect(running.backgroundWork.count == 1)
        let launched = try #require(running.backgroundWork.first)
        #expect(launched.id == workID)
        #expect(launched.kind == .subagent)
        #expect(launched.title == "Codebase Researcher")
        #expect(launched.subtitle == "research")
        #expect(launched.state == .running)
        #expect(launched.launchedAt == (try Self.date("2026-11-07T16:22:00Z")))
        let activeWork = ChatBackgroundWork(
            transcript: running, progress: [:], isLive: true, now: try Self.date("2026-11-07T16:23:30Z"))
        #expect(activeWork.holdsActivePace)
        let runningTool = try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: running))
        #expect(runningTool.kind == .agent)
        #expect(runningTool.status == .running)
        #expect(runningTool.preview == nil)
        #expect(runningTool.output == nil)

        let replied = Self.transcript(Array(allLines.prefix(5)), activity: .idle)
        let finished = try #require(replied.backgroundWork.first)
        #expect(finished.state == .completed)
        #expect(finished.endedAt == (try Self.date("2026-11-07T16:23:45Z")))
        #expect(replied.listedBackgroundWork.map(\.id) == [workID])
        #expect(
            !ChatBackgroundWork(
                transcript: replied, progress: [:], isLive: true, now: try Self.date("2026-11-07T16:24:00Z")
            ).holdsActivePace)
        let doneTool = try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: replied))
        #expect(doneTool.status == .succeeded)
        #expect(doneTool.preview?.text == "Found 3 callers in Router.swift.")
        #expect(doneTool.output == ChatOutputReference(offset: allLines[4].offset, length: allLines[4].length))
        #expect(AgyTranscriptReducer().output(of: allLines[4], for: doneTool) == .preview(doneTool.preview))

        // A `list` right after the reply can briefly still report `"running"` while the subagent's closing LLM step finishes.
        let afterLaggingList = Self.transcript(Array(allLines.prefix(7)), activity: .idle)
        #expect(afterLaggingList.backgroundWork.map(\.state) == [.completed])

        // Sending a follow-up message revives the subagent in Background Work.
        let revived = Self.transcript(Array(allLines.prefix(9)), activity: .idle)
        #expect(revived.backgroundWork.map(\.state) == [.running])
        #expect(revived.backgroundWork.first?.launchedAt == (try Self.date("2026-11-07T16:28:00Z")))
        #expect(try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: revived)).status == .running)

        // After the second reply and the user's next prompt, finished work leaves `listedBackgroundWork`.
        let cleared = Self.transcript(allLines, activity: .idle)
        #expect(cleared.backgroundWork.map(\.state) == [.completed])
        #expect(cleared.listedBackgroundWork.isEmpty)
    }

    /// System errors, `manage_subagents` kills, and server restarts end
    /// running Subagents in both Background Work and their tool rows.
    @Test func subagentErrorsKillsAndRestartsUpdateBackgroundWorkAndToolRows() throws {
        let firstID = "22222222-2222-4000-8000-000000000002"
        let secondID = "33333333-3333-4000-8000-000000000003"
        let thirdID = "44444444-4444-4000-8000-000000000004"

        let errorSteps: [JSONValue] = [
            AgyToolActivityTests.step(0, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nDebug DB\n</USER_REQUEST>"),
            AgyToolActivityTests.step(
                1, "MODEL", "PLANNER_RESPONSE",
                calls: [
                    "invoke_subagent": .object(["TypeName": .string("self"), "Role": .string("Database Debugger")]),
                    "invoke_subagent": .object(["TypeName": .string("research"), "Role": .string("Log Reader")]),
                    "invoke_subagent": .object(["TypeName": .string("research"), "Role": .string("Schema Checker")]),
                ]),
            AgyToolActivityTests.step(
                2, "MODEL", "GENERIC", content: Self.launchedSubagentResult(firstID, type: "self", role: "Database Debugger")),
            AgyToolActivityTests.step(
                3, "MODEL", "GENERIC", content: Self.launchedSubagentResult(secondID, type: "research", role: "Log Reader")),
            AgyToolActivityTests.step(
                4, "MODEL", "GENERIC", content: Self.launchedSubagentResult(thirdID, type: "research", role: "Schema Checker")),
            AgyToolActivityTests.step(
                5, "SYSTEM_SDK", "SYSTEM_MESSAGE",
                content: Self.systemMessage(
                    timestamp: "2026-11-07T16:24:30Z", sender: "system",
                    content:
                        "The subagent Database Debugger (self) with id \"\(firstID)\" encountered an error and has either stopped or failed to start execution: Context deadline exceeded")),
            AgyToolActivityTests.step(
                6, "MODEL", "PLANNER_RESPONSE",
                calls: [
                    "manage_subagents": .object([
                        "Action": .string("kill"),
                        "ConversationIds": .array([.string(secondID)]),
                    ])
                ]),
            AgyToolActivityTests.step(7, "MODEL", "GENERIC", content: "Killed 1 subagent."),
            AgyToolActivityTests.step(
                8, "MODEL", "PLANNER_RESPONSE",
                calls: ["manage_subagents": .object(["Action": .string("kill_all")])]),
            AgyToolActivityTests.step(9, "MODEL", "GENERIC", content: "Killed all subagents."),
        ]
        let errorLines = AgyToolActivityTests.lines(errorSteps)

        let transcript = Self.transcript(errorLines)
        #expect(transcript.backgroundWork.map(\.state) == [.failed, .stopped, .stopped])
        let failedTool = try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: transcript))
        #expect(failedTool.status == .failed)
        #expect(failedTool.preview?.text == "Context deadline exceeded")
        #expect(AgyTranscriptReducer().output(of: errorLines[5], for: failedTool) == .preview(failedTool.preview))
        for id in ["agy:1:tool:1", "agy:1:tool:2"] {
            let killedTool = try #require(AgyToolActivityTests.tool(id, in: transcript))
            #expect(killedTool.status == .interrupted)
            #expect(killedTool.note == "Stopped in the background")
            #expect(killedTool.preview == nil)
            #expect(killedTool.output == nil)
        }

        // Restart notice stops a running Subagent even with no background `run_command`.
        let restartLines = AgyToolActivityTests.lines(
            Array(errorSteps.prefix(3)) + [
                AgyToolActivityTests.step(
                    10, "SYSTEM", "SYSTEM_MESSAGE",
                    content: Self.systemMessage(
                        timestamp: "2026-11-07T16:30:00Z", sender: "system",
                        content: AgyTranscriptReducer.restartNotice + "."))
            ])
        let restarted = Self.transcript(restartLines)
        #expect(restarted.backgroundWork.map(\.state) == [.stopped])
        let restartedTool = try #require(AgyToolActivityTests.tool("agy:1:tool:0", in: restarted))
        #expect(restartedTool.status == .interrupted)
        #expect(restartedTool.note == "Stopped when Antigravity CLI restarted")
        let restartNotice = try #require(Self.notices(restarted).first { $0.id == "agy:10" })
        #expect(restartNotice.notice.title == "Background task stopped")
    }

    /// Non-daemon background commands and `run_workflow` calls populate
    /// Background Work, while `IsDaemon: true` servers, `schedule` waits,
    /// and held cancels before a new prompt do not linger.
    @Test func backgroundCommandsAndWorkflowsReportBackgroundWorkAndSkipDaemonsAndWaits() throws {
        let taskLines = try Self.lines("tasks-question-compact.jsonl", steps: 39...45)
        let whileRunning = Self.transcript(Array(taskLines.prefix(4)), windowStart: 1)
        #expect(whileRunning.backgroundWork.map(\.kind) == [.command])
        #expect(whileRunning.backgroundWork.map(\.title) == ["sleep 20; echo bgtwo"])
        #expect(whileRunning.backgroundWork.map(\.state) == [.running])

        let finished = Self.transcript(Array(taskLines.prefix(6)), windowStart: 1)
        #expect(finished.backgroundWork.map(\.state) == [.completed])
        #expect(finished.listedBackgroundWork.count == 1)

        let afterNextPrompt = Self.transcript(taskLines, windowStart: 1)
        #expect(afterNextPrompt.listedBackgroundWork.isEmpty)

        // Held cancel in `stopProbe` ended before step 8's prompt, so it does not stay listed after step 8.
        let heldCancel = Self.transcript(Array(Self.stopProbe().prefix(5)))
        #expect(heldCancel.backgroundWork.map(\.state) == [.stopped])
        #expect(heldCancel.listedBackgroundWork.isEmpty)

        let conversation = "00000000-0000-4000-8000-000000000099"
        let mixed = Self.transcript(
            AgyToolActivityTests.lines([
                AgyToolActivityTests.step(0, "USER_EXPLICIT", "USER_INPUT", content: "<USER_REQUEST>\nRun everything\n</USER_REQUEST>"),
                AgyToolActivityTests.step(
                    1, "MODEL", "PLANNER_RESPONSE",
                    calls: [
                        "run_command": .object(["CommandLine": .string("npm run dev"), "IsDaemon": .bool(true)]),
                        "schedule": .object(["DurationSeconds": .number(30), "Prompt": .string("check")]),
                        "run_workflow": .object([
                            "ScriptPath": .string("/work/scripts/audit.py"),
                            "Description": .string("Audit modules"),
                        ]),
                        "run_command": .object([
                            "CommandLine": .string("pytest -q"),
                            "toolSummary": .string("Run unit tests"),
                        ]),
                        "run_command": .object(["CommandLine": .string("sleep 120")]),
                    ]),
                AgyToolActivityTests.step(
                    2, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 2, "npm run dev")),
                AgyToolActivityTests.step(
                    3, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 3, "Timer")),
                AgyToolActivityTests.step(
                    4, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 4, "Audit modules")),
                AgyToolActivityTests.step(
                    5, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 5, "pytest -q")),
                AgyToolActivityTests.step(
                    6, "MODEL", "GENERIC", status: "RUNNING",
                    content: AgyToolActivityTests.background(conversation, task: 6, "sleep 120")),
                AgyToolActivityTests.step(
                    7, "SYSTEM", "SYSTEM_MESSAGE",
                    content: Self.systemMessage(
                        timestamp: "2026-11-07T16:27:30Z", sender: "\(conversation)/task-5",
                        content: "Task id \"\(conversation)/task-5\" finished with result:\nCommand exited with code 2.\n\nOutput:\n1 failed")),
                AgyToolActivityTests.step(
                    8, "MODEL", "PLANNER_RESPONSE",
                    calls: [
                        "manage_task": .object([
                            "Action": .string("kill"),
                            "TaskId": .string("\(conversation)/task-6"),
                        ])
                    ]),
                AgyToolActivityTests.step(9, "MODEL", "GENERIC", content: "Killed task."),
            ]))

        #expect(mixed.backgroundWork.map(\.kind) == [.workflow, .command, .command])
        #expect(mixed.backgroundWork.map(\.title) == ["Audit modules", "pytest -q", "sleep 120"])
        #expect(mixed.backgroundWork.map(\.subtitle) == ["audit.py", "Run unit tests", nil])
        #expect(mixed.backgroundWork.map(\.state) == [.running, .failed, .stopped])
        let workflowTool = try #require(AgyToolActivityTests.tool("agy:1:tool:2", in: mixed))
        #expect(workflowTool.kind == .agent)
        #expect(workflowTool.title == "Audit modules")
        #expect(workflowTool.subtitle == "audit.py")
        let killedCommand = try #require(AgyToolActivityTests.tool("agy:1:tool:4", in: mixed))
        #expect(killedCommand.status == .interrupted)
        #expect(killedCommand.note == "Stopped in the background")
    }

    /// In a tail window (`windowStart > 0`), `manage_subagents(list)` and
    /// `manage_task(list)` discover running work launched above the window,
    /// and `manage_task(status)` refreshes `lastActivityAt`.
    @Test func listAndStatusCallsDiscoverAndRefreshBackgroundWorkInATailWindow() throws {
        let subID = "55555555-5555-4000-8000-000000000005"
        let conversation = "00000000-0000-4000-8000-000000000088"
        let lines = AgyToolActivityTests.lines([
            AgyToolActivityTests.step(
                10, "MODEL", "PLANNER_RESPONSE",
                calls: [
                    "manage_subagents": .object(["Action": .string("list")]),
                    "manage_task": .object(["Action": .string("list")]),
                    "manage_task": .object([
                        "Action": .string("status"),
                        "TaskId": .string("\(conversation)/task-3"),
                    ]),
                ]),
            AgyToolActivityTests.step(
                11, "MODEL", "GENERIC",
                content: """
                    Created At: 2026-11-08T00:31:00+08:00
                    Completed At: 2026-11-08T00:31:00+08:00
                    Active direct subagents [1]:
                    [
                      {"conversationId": "\(subID)", "type": "self", "role": "API Auditor", "state": "waiting_for_dependents", "lastStepTime": "2026-11-07T16:30:30Z"}
                    ]
                    """),
            AgyToolActivityTests.step(
                12, "MODEL", "GENERIC",
                content: """
                    Created At: 2026-11-08T00:32:00+08:00
                    Completed At: 2026-11-08T00:32:00+08:00
                    Running tasks [3]:
                    [
                      {"taskId": "\(conversation)/task-2", "toolName": "schedule", "description": "Timer"},
                      {"taskId": "\(conversation)/task-3", "toolName": "run_command", "description": "cargo test", "toolSummary": "Run cargo test", "startTime": "2026-11-07T16:21:00Z"},
                      {"taskId": "\(conversation)/task-4", "toolName": "run_workflow", "description": "Fan-out review", "startTime": "2026-11-07T16:22:00Z"}
                    ]
                    """),
            AgyToolActivityTests.step(
                13, "MODEL", "GENERIC",
                content: "Created At: 2026-11-08T00:33:00+08:00\nCompleted At: 2026-11-08T00:33:00+08:00\nStatus: RUNNING\nOutput: testing...\n"),
        ])

        let transcript = Self.transcript(lines, windowStart: 4_096)
        #expect(transcript.backgroundWork.map(\.kind) == [.subagent, .command, .workflow])
        #expect(transcript.backgroundWork.map(\.title) == ["API Auditor", "cargo test", "Fan-out review"])
        #expect(transcript.backgroundWork.map(\.subtitle) == ["self", "Run cargo test", nil])
        #expect(transcript.backgroundWork.map(\.state) == [.running, .running, .running])
        #expect(transcript.backgroundWork[0].lastActivityAt == (try Self.date("2026-11-07T16:31:00Z")))
        #expect(transcript.backgroundWork[1].launchedAt == (try Self.date("2026-11-07T16:21:00Z")))
        #expect(transcript.backgroundWork[1].lastActivityAt == (try Self.date("2026-11-07T16:33:00Z")))
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
