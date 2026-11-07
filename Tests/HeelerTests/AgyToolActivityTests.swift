import Foundation
import Testing

@testable import Heeler

@Suite("Antigravity CLI tool rows")
struct AgyToolActivityTests {
    static func tool(_ id: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        for entry in transcript.entries where entry.id.rawValue == id {
            if case .tool(let tool) = entry.content { return tool }
        }
        return nil
    }

    private static func fixture(
        _ name: String, steps: ClosedRange<Int>? = nil, activity: ChatAgentActivity = .idle, windowStart: UInt64 = 0
    ) throws -> ChatTranscript {
        try AgyTranscriptReducerTests.fixture(name, steps: steps, activity: activity, windowStart: windowStart)
    }

    // MARK: Reads and commands

    @Test func aReadShowsItsFileAndLines() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 8...13)

        let read = try #require(Self.tool("agy:9:tool:0", in: transcript))
        #expect(read.kind == .fileRead)
        #expect(read.name == "read_file")
        #expect(read.title == "/Users/developer/projects/demo/README.md")
        #expect(read.status == .succeeded)
        #expect(read.preview?.text == "Showing lines 1-3 of 3\n1: # Probe A\n2: \n3: A tiny scratch repo for agy research.")
        #expect(read.imagePath == nil)
        let lines = try AgyTranscriptReducerTests.lines("core-turns.jsonl", steps: 10...10)
        #expect(read.output == ChatOutputReference(offset: lines[0].offset, length: lines[0].length))
    }

    /// A command's row shows its output without agy's exit line, and its
    /// line ends as plain ones.
    @Test func aCommandShowsItsOutputAndExitCode() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 8...13)

        let command = try #require(Self.tool("agy:11:tool:0", in: transcript))
        #expect(command.kind == .command)
        #expect(command.title == "ls -la")
        #expect(command.subtitle == "List directory contents")
        #expect(command.status == .succeeded)
        #expect(command.exitCode == 0)
        let preview = try #require(command.preview?.text)
        #expect(preview.hasPrefix("total 24\ndrwxr-xr-x@  6 developer  wheel"))
        #expect(!preview.contains("\r"))
        #expect(!preview.contains("Command exited"))
    }

    @Test func aFailedCommandShowsItsExitCode() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl")

        let command = try #require(Self.tool("agy:20:tool:0", in: transcript))
        #expect(command.status == .failed)
        #expect(command.exitCode == 1)
        #expect(command.preview?.text == "FAIL math\n  expected 4, got 5")
    }

    /// An expanded row reads its result's line again.
    @Test func anExpandedRowReadsItsLineAgain() throws {
        let lines = try AgyTranscriptReducerTests.lines("core-turns.jsonl", steps: 8...13)
        let transcript = AgyTranscriptReducerTests.transcript(lines)
        let command = try #require(Self.tool("agy:11:tool:0", in: transcript))
        let line = try #require(lines.first { $0.offset == command.output?.offset })

        let output = AgyTranscriptReducer().output(of: line, for: command)
        #expect(output == .preview(command.preview))
    }

    /// A line cut short still says which step it was and how it ended;
    /// its text is lost, which the row says.
    @Test func aCutResultSaysItIsIncomplete() throws {
        var lines = try AgyTranscriptReducerTests.lines("tasks-question-compact.jsonl", steps: 51...53)
        let full = lines[2]
        lines[2] = ChatLine(offset: full.offset, length: full.length, data: full.data.prefix(600))
        let transcript = AgyTranscriptReducerTests.transcript(lines, windowStart: 1)

        let read = try #require(Self.tool("agy:52:tool:0", in: transcript))
        #expect(read.status == .succeeded)
        #expect(read.note == "Output exceeds the preview limit.")
        #expect(read.output == ChatOutputReference(offset: full.offset, length: full.length))
        #expect(AgyTranscriptReducer().output(of: lines[2], for: read) == nil)
        #expect(transcript.diagnostics.oversizedLines == 1)
        #expect(transcript.diagnostics.invalidLines == 0)
    }

    /// A long result is capped like any row's output.
    @Test func aLongResultIsCapped() throws {
        let transcript = try Self.fixture("tasks-question-compact.jsonl", steps: 51...53, windowStart: 1)

        let read = try #require(Self.tool("agy:52:tool:0", in: transcript))
        #expect(read.preview?.isTruncated == true)
        #expect(read.preview?.text.hasPrefix("Showing lines 1-300 of 300") == true)
        #expect(read.note == nil)
    }

    // MARK: Writes and edits

    @Test func aWriteShowsTheFileItCreated() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 14...17)

        let write = try #require(Self.tool("agy:15:tool:0", in: transcript))
        #expect(write.kind == .fileWrite)
        #expect(write.status == .succeeded)
        let file = try #require(write.fileChanges?.files.first)
        #expect(file.path == "/Users/developer/projects/demo/notes.txt")
        #expect(file.kind == .created)
        #expect(file.added == 1)
        #expect(write.diff == ChatDiffStats(added: 1, removed: 0))
        #expect(write.preview == nil)
    }

    /// A write with `Overwrite` reads as written, as the plan agy wrote in
    /// plan mode does.
    @Test func anOverwriteReadsAsWritten() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 58...63)

        let write = try #require(Self.tool("agy:61:tool:0", in: transcript))
        #expect(write.status == .succeeded)
        #expect(write.fileChanges?.files.first?.kind == .written)
        #expect(write.title.hasSuffix("/implementation_plan.md"))
    }

    /// An edit's diff starts at the line its result names, and counts the
    /// lines agy's result does: replacing `cherry` with `cherry\ndate`
    /// adds one line (`+1/-0 lines`).
    @Test func anEditShowsItsDiffFromTheLineItNames() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 21...57)

        let edit = try #require(Self.tool("agy:24:tool:0", in: transcript))
        #expect(edit.kind == .fileEdit)
        #expect(edit.status == .succeeded)
        #expect(edit.diff == ChatDiffStats(added: 1, removed: 0))
        let file = try #require(edit.fileChanges?.files.first)
        #expect(file.kind == .updated)
        #expect(file.path == "/Users/developer/projects/fruits/fruits.txt")
        #expect(file.hunks.first?.newStart == 3)
        #expect(file.hunks.first?.lines == [" cherry", "+date"])

        // Whole lines, each ending in a line end.
        let lines = try #require(Self.tool("agy:55:tool:0", in: transcript))
        #expect(lines.diff == ChatDiffStats(added: 1, removed: 0))

        let replaced = try #require(Self.tool("agy:19:tool:0", in: try Self.fixture("core-turns.jsonl", steps: 18...21)))
        #expect(replaced.diff == ChatDiffStats(added: 1, removed: 1))
        #expect(replaced.fileChanges?.files.first?.hunks.first?.lines == ["-hello notes", "+hello edited notes"])
    }

    /// A failed edit shows agy's error instead of a diff.
    @Test func aFailedEditShowsTheError() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 0...4)

        let edit = try #require(Self.tool("agy:1:tool:1", in: transcript))
        #expect(edit.name == "replace_file_content")
        #expect(edit.title == "/Users/developer/projects/demo/config.toml")
        #expect(edit.status == .failed)
        #expect(edit.fileChanges == nil)
        #expect(edit.preview?.text.hasPrefix("Could not successfully apply any edits.") == true)
    }

    // MARK: Images and other tools

    /// agy attaches a copy of an image it read to the result.
    @Test func anImageReadShowsTheImage() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 0...4)

        let view = try #require(Self.tool("agy:1:tool:0", in: transcript))
        #expect(view.kind == .fileRead)
        #expect(view.title == "/Users/developer/projects/demo/shot.png")
        #expect(view.subtitle == "View screenshot")
        #expect(
            view.imagePath
                == "/Users/developer/.gemini/antigravity-cli/brain/00000000-0000-4000-8000-000000000004/.tempmediaStorage/media_1793000000000_0a1b2c3d.png"
        )
    }

    @Test func aToolChatDoesNotKnowShowsItsNameAndFirstArgument() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 0...11)

        let tool = try #require(Self.tool("agy:5:tool:1", in: transcript))
        #expect(tool.kind == .other)
        #expect(tool.name == "frobnicate")
        #expect(tool.title == "alpha")
        #expect(tool.subtitle == "Frobnicate alpha")
        #expect(tool.status == .succeeded)
        #expect(tool.preview?.text == "Done.")
    }

    // MARK: Questions

    @Test func aQuestionShowsItsAnswer() throws {
        let transcript = try Self.fixture("tasks-question-compact.jsonl", steps: 45...48, windowStart: 1)

        let ask = try #require(Self.tool("agy:46:tool:0", in: transcript))
        #expect(ask.kind == .question)
        #expect(ask.title == "Which fruit do you prefer?")
        #expect(ask.status == .succeeded)
        #expect(ask.questions.map(\.options.count) == [3])
        #expect(ask.questions.first?.answer == "banana")
        #expect(ask.preview == nil)
        #expect(ask.output == nil)
    }

    /// `(Recommended) ` marks an option, and `User Skipped` leaves a
    /// question unanswered.
    @Test func recommendedOptionsAndSkippedQuestions() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 13...20)

        let one = try #require(Self.tool("agy:14:tool:0", in: transcript))
        #expect(one.questions.first?.options.map(\.label) == ["Apple", "Banana"])
        #expect(one.questions.first?.recommendedIndex == 0)
        #expect(one.questions.first?.answer == "Banana")

        let two = try #require(Self.tool("agy:18:tool:0", in: transcript))
        #expect(two.questions.map(\.answer) == ["Blue", nil])
        #expect(two.title == "What is your favorite color? · What is your favorite season?")
        #expect(two.note == nil)
    }

    @Test func answersReadAcrossLines() {
        #expect(AgyToolCall.answers(in: "A1: banana\nA2: User Skipped\nA3: line one\nline two") == [1: "banana", 3: "line one\nline two"])
    }

    // MARK: Background commands

    /// A command sent to the background shows its task's result once the
    /// task's end comes.
    @Test func aBackgroundCommandShowsItsTasksEnd() throws {
        let lines = try AgyTranscriptReducerTests.lines("tasks-question-compact.jsonl", steps: 32...38)
        let started = AgyTranscriptReducerTests.transcript(Array(lines.prefix(3)), activity: .working, windowStart: 1)
        let running = try #require(Self.tool("agy:33:tool:0", in: started))
        #expect(running.status == .started)
        #expect(running.note == "Sent to the background")
        #expect(running.preview == nil)

        let transcript = AgyTranscriptReducerTests.transcript(lines, windowStart: 1)
        let ended = try #require(Self.tool("agy:33:tool:0", in: transcript))
        #expect(ended.status == .succeeded)
        #expect(ended.note == "Finished in the background")
        #expect(ended.exitCode == 0)
        #expect(ended.preview?.text == "done")
        let notification = try #require(lines.first { AgyStep.decode($0)?.stepIndex == 37 })
        #expect(ended.output == ChatOutputReference(offset: notification.offset, length: notification.length))
        #expect(AgyTranscriptReducer().output(of: notification, for: ended) == .preview(ended.preview))
    }

    @Test func aCanceledTaskReadsAsInterrupted() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 13...18)

        let tool = try #require(Self.tool("agy:14:tool:0", in: transcript))
        #expect(tool.status == .interrupted)
        #expect(tool.note == "Canceled in the background")
        #expect(tool.preview?.text == "Command was canceled.")
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["agy:13", "agy:17"])
    }

    @Test func aRestartStopsARunningTask() throws {
        let transcript = try Self.fixture("written-for-tests.jsonl", steps: 0...12)

        let tool = try #require(Self.tool("agy:5:tool:0", in: transcript))
        #expect(tool.status == .interrupted)
        #expect(tool.note == "Stopped when Antigravity CLI restarted")
    }

    // MARK: Calls without a result

    /// A call without a result follows what herdr reports while its turn
    /// is open, and offers the Blocked card its command.
    @Test(arguments: [
        (ChatAgentActivity.blocked, ChatToolActivity.Status.awaitingApproval),
        (.working, .running),
        (.unknown, .running),
        (.idle, .noResult),
    ])
    func aPendingCommandFollowsTheAgent(activity: ChatAgentActivity, status: ChatToolActivity.Status) throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 67...68, activity: activity)

        let tool = try #require(Self.tool("agy:68:tool:0", in: transcript))
        #expect(tool.status == status)
        #expect(transcript.turns.first?.ending == nil)
        if status == .awaitingApproval {
            #expect(transcript.pendingRequests.map(\.summary) == ["echo probe-cc"])
            #expect(transcript.pendingRequests.first?.entryID.rawValue == "agy:68:tool:0")
        } else {
            #expect(transcript.pendingRequests.isEmpty)
        }
    }

    /// herdr 0.9.5 reports agy idle under its file-edit dialog, so an edit
    /// without a result waits for approval there, its diff shown.
    @Test func aPendingEditWaitsForApprovalWhileIdle() throws {
        let transcript = try Self.fixture("core-turns.jsonl", steps: 18...19, activity: .idle)

        let edit = try #require(Self.tool("agy:19:tool:0", in: transcript))
        #expect(edit.status == .awaitingApproval)
        #expect(edit.fileChanges?.files.first?.kind == .updated)
        #expect(transcript.pendingRequests.map(\.summary) == ["/Users/developer/projects/demo/notes.txt"])
    }

    /// The edit declined after the plan ends its turn.
    @Test func aDeclinedEditSaysItEndedTheTurn() throws {
        let transcript = try Self.fixture("approvals.jsonl", steps: 64...68)

        let edit = try #require(Self.tool("agy:65:tool:0", in: transcript))
        #expect(edit.status == .declined)
        #expect(edit.note == "Declining ended the turn")
        #expect(edit.fileChanges == nil)
        #expect(edit.preview?.text.contains("user denied permission") == true)
    }
}
