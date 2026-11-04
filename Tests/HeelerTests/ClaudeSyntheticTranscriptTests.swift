import Foundation
import Testing

@testable import Heeler

/// Flows the probe captures do not hold, written by hand in the compact
/// JSON Claude Code writes. Shapes
/// docs/research/claude-code-transcript-format.md marks "Not verified" follow
/// the CLI source they cite.
@Suite("Claude synthetic transcripts")
struct ClaudeSyntheticTranscriptTests {
    /// The transcript and the lines it came from, for offsets.
    private static func read(_ jsonl: String, activity: ChatAgentActivity = .idle) -> (ChatTranscript, [ChatLine]) {
        let lines = ClaudeSample.lines(jsonl)
        return (ClaudeSample.reducer(lines).transcript(ChatProjectionContext(activity: activity)), lines)
    }

    private static func tool(_ id: String, in transcript: ChatTranscript) -> ChatToolActivity? {
        guard case .tool(let row) = ClaudeSample.entry(id, in: transcript) else { return nil }
        return row
    }

    /// A finished first turn that later records hang off (`t1`).
    private static let firstTurn = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Hello"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hi."}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
        """#

    /// A Bash call that is still running when a prompt is queued.
    private static let busyTurn = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Run the tests"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_test","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]},"apiBlockIndex":0}
        {"type":"queue-operation","operation":"enqueue","content":"Also check the README","sessionId":"s1"}
        {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_test","content":"ok"}]},"toolUseResult":{"stdout":"ok","stderr":"","interrupted":false}}
        {"type":"queue-operation","operation":"remove","sessionId":"s1"}
        """#

    // MARK: - Queued prompts

    @Test("A prompt queued mid-turn shows where it was delivered, under its source uuid")
    func queuedCommand() {
        let (transcript, lines) = Self.read(
            Self.busyTurn + "\n"
                + #"""
                {"type":"attachment","uuid":"q1","parentUuid":"r1","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"Also check the README"}],"source_uuid":"src1","commandMode":"prompt","origin":{"kind":"human"}}}
                {"type":"assistant","uuid":"a2","parentUuid":"q1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Tests pass and the README is current."}]},"apiBlockIndex":0}
                {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a2","durationMs":900}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_test", "user:src1", "text:a2"])
        #expect(
            transcript.entries.first { $0.id.rawValue == "user:src1" }
                == ChatEntry(
                    id: ChatEntryID("user:src1"), sourceOffset: lines[5].offset,
                    content: .user(ChatUserMessage(text: "Also check the README", wasQueued: true))))
        // The enqueue points at the bubble its delivery produced.
        #expect(transcript.recordedPrompts == [
            ChatRecordedPrompt(offset: lines[0].offset, text: "Run the tests", entryID: ChatEntryID("user:p1")),
            ChatRecordedPrompt(offset: lines[2].offset, text: "Also check the README", entryID: ChatEntryID("user:src1")),
            ChatRecordedPrompt(offset: lines[5].offset, text: "Also check the README", entryID: ChatEntryID("user:src1")),
        ])
    }

    @Test("A prompt queued in the running turn shows Queued until Claude Code delivers it")
    func waitingQueuedPrompt() {
        // Claude Code 2.1.301 writes the enqueue at once and the delivery
        // only when the turn can take it.
        let running = #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Run the tests"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_test","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]},"apiBlockIndex":0}
            {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-16T15:39:24.530Z","content":"Also check the README","sessionId":"s1"}
            """#
        let (waiting, lines) = Self.read(running, activity: .working)
        let bubble = ChatEntryID("queued:\(lines[2].offset)")
        #expect(waiting.entries.map(\.id) == [ChatEntryID("user:p1"), ChatEntryID("tool:toolu_test"), bubble])
        #expect(
            waiting.entries.last
                == ChatEntry(
                    id: bubble, sourceOffset: lines[2].offset,
                    content: .user(ChatUserMessage(text: "Also check the README", wasQueued: true))))
        #expect(waiting.recordedPrompts.last == ChatRecordedPrompt(
            offset: lines[2].offset, text: "Also check the README", entryID: bubble))
        // The delivery shows it under another id, so it is never saved.
        #expect(waiting.unrecordedEntryIDs == [bubble])

        // Delivered: the bubble its delivery adds replaces it.
        let delivered = running + "\n" + #"""
            {"type":"queue-operation","operation":"remove","timestamp":"2026-10-16T15:39:53.049Z","content":"Also check the README","sessionId":"s1"}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_test","content":"ok"}]},"toolUseResult":{"stdout":"ok","stderr":"","interrupted":false}}
            {"type":"attachment","uuid":"q1","parentUuid":"r1","attachment":{"type":"queued_command","prompt":"Also check the README","source_uuid":"src1","commandMode":"prompt","origin":{"kind":"human"}}}
            """#
        let (deliveredTranscript, _) = Self.read(delivered, activity: .working)
        #expect(deliveredTranscript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_test", "user:src1"])
        #expect(deliveredTranscript.unrecordedEntryIDs.isEmpty)

        // Taken back into the input box: no bubble.
        let takenBack = running + "\n" + #"""
            {"type":"queue-operation","operation":"remove","timestamp":"2026-10-16T15:39:30.000Z","content":"Also check the README","sessionId":"s1"}
            """#
        #expect(Self.read(takenBack, activity: .working).0.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_test"])

        // A turn that ended without delivering it shows none either.
        let ended = running + "\n" + #"""
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_test","content":"ok"}]},"toolUseResult":{"stdout":"ok","stderr":"","interrupted":false}}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"r1","durationMs":900}
            """#
        #expect(Self.read(ended).0.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_test"])
    }

    @Test("A prompt queued in a turn that opened above the loaded lines shows Queued while the Agent works")
    func waitingQueuedPromptBelowTheWindowStart() {
        // The tail window starts after the turn's prompt.
        let running = #"""
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_test","name":"Bash","input":{"command":"make test","description":"Run the tests"}}]},"apiBlockIndex":0}
            {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-16T15:39:24.530Z","content":"Also check the README","sessionId":"s1"}
            """#
        let lines = ClaudeSample.lines(running)
        let reducer = ClaudeSample.reducer(lines)
        let working = reducer.transcript(ChatProjectionContext(windowStart: 4_096, activity: .working))
        let bubble = ChatEntryID("queued:\(lines[1].offset)")
        #expect(working.entries.map(\.id) == [ChatEntryID("tool:toolu_test"), bubble])
        #expect(working.recordedPrompts.last?.entryID == bubble)

        // Idle, nothing says the turn still runs.
        let idle = reducer.transcript(ChatProjectionContext(windowStart: 4_096, activity: .idle))
        #expect(idle.entries.map(\.id) == [ChatEntryID("tool:toolu_test")])

        // A turn the loaded lines close holds no waiting prompt either.
        let closed = ClaudeSample.reducer(
            ClaudeSample.lines(
                running + "\n"
                    + #"{"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}"#))
        #expect(
            closed.transcript(ChatProjectionContext(windowStart: 4_096, activity: .working)).entries.map(\.id)
                == [ChatEntryID("tool:toolu_test")])
    }

    @Test("A queued prompt recorded as a user record shows once")
    func queuedUserRecord() {
        let (transcript, lines) = Self.read(
            Self.busyTurn + "\n"
                + #"""
                {"type":"user","uuid":"u2","parentUuid":"r1","message":{"role":"user","content":"Also check the README"},"promptSource":"queued","origin":{"kind":"human"}}
                {"type":"attachment","uuid":"q1","parentUuid":"u2","attachment":{"type":"queued_command","prompt":"Also check the README","source_uuid":"u2","commandMode":"prompt","origin":{"kind":"human"}}}
                {"type":"assistant","uuid":"a2","parentUuid":"q1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Tests pass and the README is current."}]},"apiBlockIndex":0}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_test", "user:u2", "text:a2"])
        #expect(
            ClaudeSample.entry("user:u2", in: transcript)
                == .user(ChatUserMessage(text: "Also check the README", wasQueued: true)))
        #expect(transcript.recordedPrompts == [
            ChatRecordedPrompt(offset: lines[0].offset, text: "Run the tests", entryID: ChatEntryID("user:p1")),
            ChatRecordedPrompt(offset: lines[2].offset, text: "Also check the README", entryID: ChatEntryID("user:u2")),
            ChatRecordedPrompt(offset: lines[5].offset, text: "Also check the README", entryID: ChatEntryID("user:u2")),
        ])
    }

    // MARK: - Background agents

    private static let backgroundAgent = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Look for the bug in the background"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"Find the bug","subagent_type":"general-purpose","prompt":"Find it.","run_in_background":true}}]},"apiBlockIndex":0}
        {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_agent","content":[{"type":"text","text":"Async agent launched successfully."}]}]},"toolUseResult":{"status":"async_launched","agentId":"ag1","description":"Find the bug"}}
        {"type":"assistant","uuid":"a2","parentUuid":"r1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"It runs in the background."}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a2","durationMs":900}
        """#

    private static let failedNotification =
        #"<task-notification>\n<task-id>ag1</task-id>\n<tool-use-id>toolu_agent</tool-use-id>\n<status>failed</status>\n<summary>Agent \"Find the bug\" failed</summary>\n<result>Could not reproduce.</result>\n</task-notification>"#

    @Test("A notification delivered as a queued command finishes its Agent row, and shows once")
    func queuedNotification() {
        let queued = #"{"type":"attachment","uuid":"q1","parentUuid":"t1","attachment":{"type":"queued_command","prompt":"\#(Self.failedNotification)","commandMode":"task-notification","origin":{"kind":"task-notification"}}}"#
        let reply = #"{"type":"assistant","uuid":"a3","parentUuid":"q1","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"The search failed."}]},"apiBlockIndex":0}"#
        let (transcript, lines) = Self.read([Self.backgroundAgent, queued, reply].joined(separator: "\n"))
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_agent", "text:a2", "notice:q1", "text:a3"])
        #expect(
            Self.tool("tool:toolu_agent", in: transcript)
                == ChatToolActivity(
                    kind: .agent, name: "Agent", title: "Find the bug", subtitle: "general-purpose", status: .failed,
                    callID: "toolu_agent", preview: ChatToolPreview(text: "Could not reproduce.", isTruncated: false),
                    output: ChatOutputReference(offset: lines[2].offset, length: lines[2].length)))
        let notice = ChatEntry.Content.notice(
            ChatNotice(kind: .taskNotification, title: "Agent \"Find the bug\" failed", detail: "Could not reproduce."))
        #expect(ClaudeSample.entry("notice:q1", in: transcript) == notice)
        #expect(transcript.recordedPrompts.map(\.text) == ["Look for the bug in the background"])

        // The same notification as a user record as well: the record shows it.
        let record = #"{"type":"user","uuid":"n1","parentUuid":"q1","message":{"role":"user","content":"\#(Self.failedNotification)"},"promptSource":"system","origin":{"kind":"task-notification"}}"#
        let both = Self.read(
            [Self.backgroundAgent, queued, record, reply.replacingOccurrences(of: #""parentUuid":"q1""#, with: #""parentUuid":"n1""#)]
                .joined(separator: "\n")
        ).0
        #expect(both.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_agent", "text:a2", "notice:n1", "text:a3"])
        #expect(ClaudeSample.entry("notice:n1", in: both) == notice)
        #expect(both.recordedPrompts.map(\.text) == ["Look for the bug in the background"])
    }

    @Test("Stopping all background agents interrupts the ones still running")
    func agentsKilled() {
        let (transcript, _) = Self.read(
            Self.backgroundAgent + "\n"
                + #"{"type":"system","subtype":"agents_killed","uuid":"k1","parentUuid":"t1","level":"info"}"#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_agent", "text:a2", "notice:k1"])
        #expect(Self.tool("tool:toolu_agent", in: transcript)?.status == .interrupted)
        #expect(transcript.backgroundWork.map(\.state) == [.stopped])
        #expect(transcript.backgroundWork.first?.endOffset == transcript.entries.last?.sourceOffset)
        #expect(
            ClaudeSample.entry("notice:k1", in: transcript)
                == .notice(ChatNotice(kind: .stopped, title: "All background agents stopped")))

        // Without it the agent is still running, whatever herdr reports.
        let running = Self.read(Self.backgroundAgent, activity: .idle).0
        #expect(Self.tool("tool:toolu_agent", in: running)?.status == .running)
        #expect(running.pendingRequests.isEmpty)
    }

    // MARK: - Background work

    private static let transcriptPath = "/home/dev/.claude/projects/-home-dev-docs/s1.jsonl"

    /// A turn that starts a Workflow, written as 2.1.291 writes one.
    private static let workflowTurn = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"timestamp":"2026-10-07T10:00:00.000Z","message":{"role":"user","content":"Audit the guides"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","timestamp":"2026-10-07T10:00:05.000Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_wf","name":"Workflow","input":{"script":"export const meta = { name: 'docs-audit' }"}}]},"apiBlockIndex":0}
        {"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-10-07T10:00:05.200Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_wf","content":[{"type":"text","text":"Workflow launched in background. Task ID: w1abcdefg"}]}]},"toolUseResult":{"status":"async_launched","taskId":"w1abcdefg","taskType":"local_workflow","workflowName":"docs-audit","runId":"wf_0a1b2c3d-4e5","summary":"Check every guide against the new flow","transcriptDir":"/tmp/elsewhere","scriptPath":"/tmp/elsewhere/docs-audit.js"}}
        {"type":"assistant","uuid":"a2","parentUuid":"r1","timestamp":"2026-10-07T10:00:09.000Z","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"The audit runs in the background."}]},"apiBlockIndex":0}
        {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a2","timestamp":"2026-10-07T10:00:09.010Z","durationMs":9000,"pendingWorkflowCount":1}
        """#

    private static func workflowNotification(status: String) -> String {
        #"<task-notification>\n<task-id>w1abcdefg</task-id>\n<tool-use-id>toolu_wf</tool-use-id>\n<status>\#(status)</status>\n<summary>Dynamic workflow \"Check every guide against the new flow\" \#(status)</summary>\n<result>Every guide matches.</result>\n<usage><agent_count>3</agent_count><agents_done>2</agents_done><agents_error>1</agents_error><agents_skipped>0</agents_skipped><agents_empty_result>0</agents_empty_result><subagent_tokens>120000</subagent_tokens><tool_uses>40</tool_uses><duration_ms>1795000</duration_ms></usage>\n</task-notification>"#
    }

    private static func readWorkflow(_ jsonl: String) -> (ChatTranscript, [ChatLine]) {
        let lines = ClaudeSample.lines(jsonl)
        var reducer = ClaudeTranscriptReducer(role: .main, transcriptPath: transcriptPath)
        reducer.append(lines)
        return (reducer.transcript(ChatProjectionContext(activity: .idle)), lines)
    }

    private static func date(_ text: String) -> Date? {
        ClaudeTranscriptProjection.date(text)
    }

    @Test("A Workflow runs under its name, its journal beside the transcript, never where the result says")
    func workflowLaunch() throws {
        let (transcript, lines) = Self.readWorkflow(Self.workflowTurn)
        #expect(
            Self.tool("tool:toolu_wf", in: transcript)
                == ChatToolActivity(
                    kind: .agent, name: "Workflow", title: "docs-audit", subtitle: "Check every guide against the new flow",
                    status: .running, callID: "toolu_wf",
                    output: ChatOutputReference(offset: lines[2].offset, length: lines[2].length)))
        let work = ChatBackgroundWorkItem(
            id: "toolu_wf", kind: .workflow, title: "docs-audit", subtitle: "Check every guide against the new flow",
            journalPath: "/home/dev/.claude/projects/-home-dev-docs/s1/subagents/workflows/wf_0a1b2c3d-4e5/journal.jsonl",
            launchOffset: lines[1].offset, launchedAt: Self.date("2026-10-07T10:00:05.000Z"))
        #expect(transcript.backgroundWork == [work])
        #expect(transcript.listedBackgroundWork == [work])
        #expect(transcript.latestPromptOffset == lines[0].offset)
        #expect(transcript.pendingRequests.isEmpty)
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("A queued notification ends a Workflow at once; its delivery adds the row")
    func workflowNotificationQueuedFirst() throws {
        let notification = Self.workflowNotification(status: "completed")
        let enqueue = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-07T10:30:00.000Z","content":"\#(notification)","sessionId":"s1"}"#
        let (queued, queuedLines) = Self.readWorkflow([Self.workflowTurn, enqueue].joined(separator: "\n"))
        #expect(Self.tool("tool:toolu_wf", in: queued)?.status == .succeeded)
        #expect(Self.tool("tool:toolu_wf", in: queued)?.preview == ChatToolPreview(text: "Every guide matches.", isTruncated: false))
        #expect(!queued.entries.contains { $0.id.rawValue.hasPrefix("notice:") })
        let usage = ChatBackgroundWorkItem.Usage(
            tokens: 120000, toolUses: 40, durationMilliseconds: 1_795_000, agents: 3, agentsDone: 2, agentsFailed: 1)
        #expect(queued.backgroundWork.map(\.state) == [.completed])
        #expect(queued.backgroundWork.first?.usage == usage)
        #expect(queued.backgroundWork.first?.endOffset == queuedLines[5].offset)
        #expect(queued.backgroundWork.first?.endedAt == Self.date("2026-10-07T10:30:00.000Z"))

        let delivery = #"""
            {"type":"queue-operation","operation":"dequeue","timestamp":"2026-10-07T10:30:00.010Z","sessionId":"s1"}
            {"type":"user","uuid":"n1","parentUuid":"t1","timestamp":"2026-10-07T10:30:00.020Z","message":{"role":"user","content":"\#(notification)"},"promptSource":"system","origin":{"kind":"task-notification"}}
            """#
        let (delivered, lines) = Self.readWorkflow([Self.workflowTurn, enqueue, delivery].joined(separator: "\n"))
        #expect(
            ClaudeSample.entry("notice:n1", in: delivered)
                == .notice(
                    ChatNotice(
                        kind: .taskNotification, title: "Dynamic workflow \"Check every guide against the new flow\" completed",
                        detail: "Every guide matches.")))
        #expect(delivered.backgroundWork.first?.endOffset == lines[7].offset)
        // A notification is not the user's message: the finished Workflow
        // stays listed.
        #expect(delivered.latestPromptOffset == lines[0].offset)
        #expect(delivered.listedBackgroundWork.map(\.id) == ["toolu_wf"])

        // The user's next message, queued mid-turn or typed, clears it.
        let next = #"{"type":"attachment","uuid":"q2","parentUuid":"n1","attachment":{"type":"queued_command","prompt":"Thanks","commandMode":"prompt","origin":{"kind":"human"}}}"#
        let (cleared, clearedLines) = Self.readWorkflow([Self.workflowTurn, enqueue, delivery, next].joined(separator: "\n"))
        #expect(cleared.latestPromptOffset == clearedLines[8].offset)
        #expect(cleared.backgroundWork.map(\.state) == [.completed])
        #expect(cleared.listedBackgroundWork.isEmpty)
    }

    @Test("A window holding only work's end still says how it ended, for work launched above it")
    func endsBelowTheirLaunch() {
        let enqueue = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-07T10:30:00.000Z","content":"\#(Self.workflowNotification(status: "completed"))","sessionId":"s1"}"#
        let killed = #"{"type":"system","subtype":"agents_killed","uuid":"k1","parentUuid":"t9","timestamp":"2026-10-07T10:40:00.000Z","level":"info"}"#
        let windowStart: UInt64 = 4_096
        let after = #"{"type":"assistant","uuid":"a9","parentUuid":"k1","timestamp":"2026-10-07T10:40:01.000Z","message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"Stopped."}]},"apiBlockIndex":0}"#
        let lines = ClaudeSample.lines([enqueue, killed, after].joined(separator: "\n")).map {
            ChatLine(offset: $0.offset + windowStart, data: $0.data)
        }
        var reducer = ClaudeTranscriptReducer(role: .main, transcriptPath: Self.transcriptPath)
        reducer.append(lines)
        let transcript = reducer.transcript(ChatProjectionContext(windowStart: windowStart, activity: .idle))

        #expect(transcript.backgroundWork.isEmpty)
        #expect(
            transcript.backgroundWorkEnds == [
                "toolu_wf": ChatBackgroundWorkEnd(
                    state: .completed, offset: lines[0].offset, endedAt: Self.date("2026-10-07T10:30:00.000Z"),
                    usage: ChatBackgroundWorkItem.Usage(
                        tokens: 120000, toolUses: 40, durationMilliseconds: 1_795_000, agents: 3, agentsDone: 2,
                        agentsFailed: 1))
            ])
        #expect(
            transcript.backgroundWorkStop
                == ChatBackgroundWorkEnd(
                    state: .stopped, offset: lines[1].offset, endedAt: Self.date("2026-10-07T10:40:00.000Z")))
    }

    @Test("A stopped Workflow is stopped, not done", arguments: ["stopped", "killed"])
    func stoppedWorkflow(_ status: String) throws {
        let queued = #"{"type":"attachment","uuid":"q1","parentUuid":"t1","attachment":{"type":"queued_command","prompt":"\#(Self.workflowNotification(status: status))","commandMode":"task-notification","origin":{"kind":"task-notification"}}}"#
        let (transcript, _) = Self.readWorkflow([Self.workflowTurn, queued].joined(separator: "\n"))
        #expect(Self.tool("tool:toolu_wf", in: transcript)?.status == .interrupted)
        #expect(transcript.backgroundWork.map(\.state) == [.stopped])
    }

    @Test("A run id that could leave the session's directory names no journal", arguments: [
        "../../../../etc/passwd", "wf_", "wf_a/b", "wf_a.b", "wf_..", "wf_ä1", "wf_" + String(repeating: "a", count: 62), "w7au92383",
    ])
    func unsafeRunID(_ runID: String) throws {
        let turn = Self.workflowTurn.replacingOccurrences(of: "wf_0a1b2c3d-4e5", with: runID)
        let (transcript, _) = Self.readWorkflow(turn)
        #expect(transcript.backgroundWork.map(\.kind) == [.workflow])
        #expect(transcript.backgroundWork.first?.journalPath == nil)
    }

    @Test("A background Subagent lists under its description, and ends with its notification")
    func backgroundSubagent() {
        let (running, lines) = Self.read(Self.backgroundAgent)
        #expect(
            running.backgroundWork == [
                ChatBackgroundWorkItem(
                    id: "toolu_agent", kind: .subagent, title: "Find the bug", subtitle: "general-purpose",
                    launchOffset: lines[1].offset)
            ])
        let queued = #"{"type":"attachment","uuid":"q1","parentUuid":"t1","attachment":{"type":"queued_command","prompt":"\#(Self.failedNotification)","commandMode":"task-notification","origin":{"kind":"task-notification"}}}"#
        let (failed, failedLines) = Self.read([Self.backgroundAgent, queued].joined(separator: "\n"))
        #expect(failed.backgroundWork.map(\.state) == [.failed])
        #expect(failed.backgroundWork.first?.endOffset == failedLines[5].offset)
        #expect(failed.listedBackgroundWork.count == 1)
    }

    @Test("A teammate reads as Started and is never listed: nothing in the transcript says when one is done")
    func teammateNotListed() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Split the work"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_mate","name":"Agent","input":{"description":"Review the parser","name":"parser","subagent_type":"general-purpose","prompt":"Review it.","run_in_background":true}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_mate","content":[{"type":"text","text":"Spawned successfully."}]}]},"toolUseResult":{"status":"teammate_spawned","agent_id":"parser@team","name":"parser","team_name":"team"}}
            """#)
        // Claude Code 2.1.301 (CL-42) spawns a teammate for an Agent call
        // with `name`; the pane still lists it running.
        let row = Self.tool("tool:toolu_mate", in: transcript)
        #expect(row?.status == .started)
        #expect(row?.title == "Review the parser")
        #expect(row?.subtitle == "Teammate @parser")
        #expect(transcript.backgroundWork.isEmpty)
    }

    // MARK: - Commands

    @Test("A local command is one row with its output (2.1.291 system records)")
    func localCommand() {
        let (transcript, lines) = Self.read(
            Self.firstTurn + "\n"
                + #"""
                {"type":"system","subtype":"local_command","uuid":"c1","parentUuid":"t1","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>","level":"info","commandRun":{"command":"/model","args":"opus"}}
                {"type":"system","subtype":"local_command","uuid":"c2","parentUuid":"c1","content":"<local-command-stdout>Set model to \u001b[1mopus\u001b[22m</local-command-stdout>","level":"info"}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:c1"])
        #expect(
            ClaudeSample.entry("notice:c1", in: transcript)
                == .notice(ChatNotice(kind: .command, title: "/model opus", detail: "Set model to opus")))
        #expect(transcript.recordedPrompts == [
            ChatRecordedPrompt(offset: lines[0].offset, text: "Hello", entryID: ChatEntryID("user:p1")),
            ChatRecordedPrompt(offset: lines[3].offset, text: "/model opus", entryID: ChatEntryID("notice:c1")),
        ])
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
        // Between turns, the command opens one: it is not the answer's.
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["user:p1", "notice:c1"])
    }

    @Test("A local command in older releases' user records reads the same")
    func legacyLocalCommand() {
        let (transcript, lines) = Self.read(
            Self.firstTurn + "\n"
                + #"""
                {"type":"user","uuid":"k0","parentUuid":"t1","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"}}
                {"type":"user","uuid":"k1","parentUuid":"k0","message":{"role":"user","content":"<command-name>/cost</command-name>\n            <command-message>cost</command-message>\n            <command-args></command-args>"}}
                {"type":"user","uuid":"k2","parentUuid":"k1","message":{"role":"user","content":"<local-command-stdout>Total cost: $0.12</local-command-stdout>"}}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:k1"])
        #expect(
            ClaudeSample.entry("notice:k1", in: transcript)
                == .notice(ChatNotice(kind: .command, title: "/cost", detail: "Total cost: $0.12")))
        #expect(transcript.recordedPrompts.map(\.offset) == [lines[0].offset, lines[4].offset])
        #expect(transcript.recordedPrompts.map(\.text) == ["Hello", "/cost"])
    }

    @Test("A skill the user typed is a command bubble; its expanded body stays hidden")
    func typedSkill() {
        let (transcript, lines) = Self.read(
            #"""
            {"type":"user","uuid":"s1","parentUuid":null,"message":{"role":"user","content":"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>PR 12</command-args>"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"user","uuid":"s2","parentUuid":"s1","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Review the pull request the user named. Read the diff first."}]}}
            {"type":"assistant","uuid":"a1","parentUuid":"s2","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"PR 12 looks good."}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:s1", "text:a1"])
        #expect(
            ClaudeSample.entry("user:s1", in: transcript)
                == .user(
                    ChatUserMessage(
                        text: "/review PR 12", command: ChatCommandInvocation(name: "review", arguments: "PR 12"))))
        #expect(transcript.recordedPrompts == [
            ChatRecordedPrompt(offset: lines[0].offset, text: "/review PR 12", entryID: ChatEntryID("user:s1"))
        ])
    }

    @Test("A skill the model invoked is its Skill row; the records it loaded stay hidden")
    func modelSkill() {
        let (transcript, lines) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Clean up the code"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_skill","name":"Skill","input":{"skill":"lint","args":"--fix"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_skill","content":"Launching skill: lint"}]},"toolUseResult":{"success":true,"commandName":"lint"}}
            {"type":"user","uuid":"s1","parentUuid":"r1","sourceToolUseID":"toolu_skill","message":{"role":"user","content":"<command-message>lint</command-message>\n<command-name>lint</command-name>\n<command-args>--fix</command-args>\n<skill-format>true</skill-format>"}}
            {"type":"user","uuid":"s2","parentUuid":"s1","isMeta":true,"sourceToolUseID":"toolu_skill","message":{"role":"user","content":[{"type":"text","text":"Run the linter with fixes applied."}]}}
            {"type":"assistant","uuid":"a2","parentUuid":"s2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Lint is clean."}]},"apiBlockIndex":0}
            """#, activity: .working)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_skill", "text:a2"])
        #expect(
            Self.tool("tool:toolu_skill", in: transcript)
                == ChatToolActivity(
                    kind: .other, name: "Skill", title: "/lint --fix", status: .succeeded, callID: "toolu_skill",
                    preview: ChatToolPreview(text: "Launching skill: lint", isTruncated: false),
                    output: ChatOutputReference(offset: lines[2].offset, length: lines[2].length)))
        #expect(transcript.recordedPrompts.map(\.text) == ["Clean up the code"])
    }

    @Test("A shell-mode command is one row with its unescaped output, recorded as typed")
    func shellCommand() {
        let (transcript, lines) = Self.read(
            Self.firstTurn + "\n"
                + #"""
                {"type":"user","uuid":"b1","parentUuid":"t1","message":{"role":"user","content":"<bash-input>ls -a</bash-input>"},"promptSource":"typed","origin":{"kind":"human"}}
                {"type":"user","uuid":"b2","parentUuid":"b1","message":{"role":"user","content":"<bash-stdout>.\n..\nnotes &amp; todo.txt</bash-stdout><bash-stderr></bash-stderr>"}}
                {"type":"assistant","uuid":"a2","parentUuid":"b2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"One file: notes & todo.txt."}]},"apiBlockIndex":0}
                {"type":"system","subtype":"turn_duration","uuid":"t2","parentUuid":"a2","durationMs":900}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:b1", "text:a2"])
        #expect(
            ClaudeSample.entry("notice:b1", in: transcript)
                == .notice(ChatNotice(kind: .shellCommand, title: "ls -a", detail: ".\n..\nnotes & todo.txt")))
        #expect(transcript.recordedPrompts == [
            ChatRecordedPrompt(offset: lines[0].offset, text: "Hello", entryID: ChatEntryID("user:p1")),
            ChatRecordedPrompt(offset: lines[3].offset, text: "!ls -a", entryID: ChatEntryID("notice:b1")),
        ])
    }

    // MARK: - Errors and interruptions

    @Test("An API error is an error notice, not assistant text")
    func apiError() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Summarize the log"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"e1","parentUuid":"p1","isApiErrorMessage":true,"message":{"id":"e-1","role":"assistant","content":[{"type":"text","text":"API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}]}}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"e1","durationMs":900}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "notice:e1"])
        #expect(
            ClaudeSample.entry("notice:e1", in: transcript)
                == .notice(
                    ChatNotice(
                        kind: .error,
                        title: #"API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)))
        #expect(transcript.turns.map(\.ending) == [.failed])
    }

    @Test("A reply after an API error, as Claude Code retries, completes the turn")
    func apiErrorRetried() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Summarize the log"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"e1","parentUuid":"p1","isApiErrorMessage":true,"message":{"id":"e-1","role":"assistant","content":[{"type":"text","text":"API Error: 529 Overloaded"}]}}
            {"type":"assistant","uuid":"a1","parentUuid":"e1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"The log is clean."}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
            """#)
        #expect(transcript.turns.map(\.ending) == [.completed])
    }

    private static let abortedStream = #"""
        {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Write a poem"},"promptSource":"typed","origin":{"kind":"human"}}
        {"type":"assistant","uuid":"a1","parentUuid":"p1","isAbortedMidStream":true,"message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Roses are"}]},"apiBlockIndex":0}
        {"type":"user","uuid":"i1","parentUuid":"p1","interruptedMessageId":"m1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        """#

    @Test("Text cut short by an interrupt stays, through the marker's interruptedMessageId")
    func abortedMidStream() {
        let (transcript, _) = Self.read(Self.abortedStream)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:i1"])
        #expect(ClaudeSample.entry("text:a1", in: transcript) == .assistant(ChatAssistantMessage(text: "Roses are")))
        #expect(
            ClaudeSample.entry("notice:i1", in: transcript)
                == .notice(ChatNotice(kind: .interrupted, title: "Interrupted")))
        #expect(transcript.recordedPrompts.map(\.text) == ["Write a poem"])

        // Without the id the partial text is a dead end the walk never sees.
        let (unlinked, _) = Self.read(Self.abortedStream.replacingOccurrences(of: #""interruptedMessageId":"m1","#, with: ""))
        #expect(unlinked.entries.map(\.id.rawValue) == ["user:p1", "notice:i1"])
    }

    @Test("An interrupted call keeps the marker after it; a call cut off without a result shows none")
    func interruptedCalls() {
        let (interrupted, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Run the long build"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_build","name":"Bash","input":{"command":"make build"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_build","content":"[Request interrupted by user for tool use]","is_error":true}]},"toolUseResult":"Error: [Request interrupted by user for tool use]"}
            {"type":"user","uuid":"i1","parentUuid":"r1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """#, activity: .blocked)
        #expect(interrupted.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_build"])
        #expect(Self.tool("tool:toolu_build", in: interrupted)?.status == .interrupted)
        #expect(interrupted.pendingRequests.isEmpty)

        let (cutOff, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Wait a while"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_sleep","name":"Bash","input":{"command":"sleep 100"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"i1","parentUuid":"a1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}
            """#, activity: .blocked)
        #expect(cutOff.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_sleep", "notice:i1"])
        #expect(Self.tool("tool:toolu_sleep", in: cutOff)?.status == .noResult)
        #expect(cutOff.pendingRequests.isEmpty)
    }

    /// A running call stopped with Esc, as Claude Code 2.1.301 records it:
    /// the result is the decline text, and only the marker after it names
    /// the interrupted reply's `message.id`.
    private static func stoppedCall(markerNamesReply: Bool) -> String {
        let marker = markerNamesReply ? #""interruptedMessageId":"m1","# : ""
        return #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Wait a while"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_sleep","name":"Bash","input":{"command":"sleep 30"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_sleep","content":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.","is_error":true}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}
            {"type":"user","uuid":"i1","parentUuid":"r1",\#(marker)"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """#
    }

    @Test("A call stopped while it ran is interrupted, though its result reads as a decline")
    func stoppedWhileRunning() {
        let (stopped, _) = Self.read(Self.stoppedCall(markerNamesReply: true))
        #expect(stopped.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_sleep"])
        #expect(Self.tool("tool:toolu_sleep", in: stopped)?.status == .interrupted)
        #expect(Self.tool("tool:toolu_sleep", in: stopped)?.preview == nil)

        let (declined, _) = Self.read(Self.stoppedCall(markerNamesReply: false))
        #expect(declined.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_sleep"])
        #expect(Self.tool("tool:toolu_sleep", in: declined)?.status == .declined)
    }

    /// Each result hangs off its own call's record, as
    /// probe2-transcript.jsonl:160-163 records parallel calls.
    @Test("Parallel calls stopped together are all interrupted, though the marker follows only the last result")
    func parallelCallsStoppedWhileRunning() {
        let decline =
            "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Wait twice"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_a","name":"Bash","input":{"command":"sleep 30"}}]},"apiBlockIndex":0}
            {"type":"assistant","uuid":"a2","parentUuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_b","name":"Bash","input":{"command":"sleep 40"}}]},"apiBlockIndex":1}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_a","content":"\#(decline)","is_error":true}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}
            {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_b","content":"\#(decline)","is_error":true}]},"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"}
            {"type":"user","uuid":"i1","parentUuid":"r2","interruptedMessageId":"m1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_a", "tool:toolu_b"])
        #expect(Self.tool("tool:toolu_a", in: transcript)?.status == .interrupted)
        #expect(Self.tool("tool:toolu_b", in: transcript)?.status == .interrupted)
    }

    @Test("An approval closed unanswered did not complete")
    func unansweredApproval() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Remove the build folder"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_rm","name":"Bash","input":{"command":"rm -rf build","description":"Remove the build folder"}}]},"apiBlockIndex":0}
            {"type":"user","uuid":"r1","parentUuid":"a1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_rm","content":"[Tool call not completed: the approval request was closed]","is_error":true}]},"toolDenialUnanswered":"stream-closed"}
            """#)
        let row = Self.tool("tool:toolu_rm", in: transcript)
        #expect(row?.status == .notCompleted)
        #expect(row?.note == nil)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "tool:toolu_rm"])
    }

    // MARK: - Prompts

    @Test("A wrapped paste shows, and is recorded, as the user sent it")
    func pastedContent() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Fix this: \n\n<pasted_content id=\"ab12\">\nTypeError: x is undefined\n    at main.js:3\n</pasted_content id=\"ab12\">"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"x is never assigned."}]},"apiBlockIndex":0}
            """#)
        let sent = "Fix this: TypeError: x is undefined\n    at main.js:3"
        #expect(ClaudeSample.entry("user:p1", in: transcript) == .user(ChatUserMessage(text: sent)))
        #expect(transcript.recordedPrompts.map(\.text) == [sent])
        #expect(ClaudeTranscriptReducer.echoKey(sent + " ") == ClaudeTranscriptReducer.echoKey(transcript.recordedPrompts[0].text))
    }

    @Test("Images become counts; an image-only prompt still shows but has no text to match")
    func imagePrompt() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":[{"type":"text","text":"What is in [Image #1]?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"A cat."}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a1","durationMs":900}
            {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9j/4AAQ"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"/9j/4AAQ"}}]},"promptSource":"typed","origin":{"kind":"human"}}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "user:p2"])
        #expect(ClaudeSample.entry("user:p1", in: transcript) == .user(ChatUserMessage(text: "What is in [Image #1]?", imageCount: 1)))
        #expect(ClaudeSample.entry("user:p2", in: transcript) == .user(ChatUserMessage(text: "", imageCount: 2)))
        #expect(transcript.recordedPrompts.map(\.text) == ["What is in [Image #1]?"])
    }

    @Test("Messages from outside the conversation are system rows, never prompts")
    func outsideMessages() {
        let (transcript, _) = Self.read(
            Self.firstTurn + "\n"
                + #"""
                {"type":"user","uuid":"e1","parentUuid":"t1","isMeta":true,"origin":{"kind":"peer"},"message":{"role":"user","content":"<teammate-message teammate_id=\"lead\">Ship it after the tests pass.</teammate-message>"}}
                {"type":"assistant","uuid":"a2","parentUuid":"e1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Will do."}]},"apiBlockIndex":0}
                {"type":"user","uuid":"e2","parentUuid":"a2","origin":{"kind":"auto-continuation"},"promptSource":"system","message":{"role":"user","content":"Continue from where you left off."}}
                {"type":"user","uuid":"e3","parentUuid":"e2","isMeta":true,"message":{"role":"user","content":"<system-reminder>The tests are slow.</system-reminder>"}}
                {"type":"assistant","uuid":"a3","parentUuid":"e3","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Continuing."}]},"apiBlockIndex":0}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:e1", "text:a2", "notice:e2", "text:a3"])
        #expect(
            ClaudeSample.entry("notice:e1", in: transcript)
                == .notice(ChatNotice(kind: .system, title: "Message from @lead", detail: "Ship it after the tests pass.")))
        #expect(
            ClaudeSample.entry("notice:e2", in: transcript)
                == .notice(ChatNotice(kind: .system, title: "Continue from where you left off.")))
        #expect(transcript.recordedPrompts.map(\.text) == ["Hello"])
        // A message between turns opens one; the reminder inside it does not.
        #expect(transcript.turns.map(\.firstEntryID.rawValue) == ["user:p1", "notice:e1", "notice:e2"])
    }

    @Test("A peer record holding several messages shows one notice each, titled by its sender")
    func peerMessages() {
        let text =
            #"Another Claude session sent a message:\n<teammate-message teammate_id=\"w2\">\nDONE\n</teammate-message>\n\n<teammate-message teammate_id=\"w4\">\n{\"type\":\"idle_notification\",\"from\":\"w4\",\"result\":\"All four passed\"}\n</teammate-message>\n\nThis came from another Claude session."#
        let (transcript, _) = Self.read(
            Self.firstTurn + "\n"
                + #"{"type":"user","uuid":"e1","parentUuid":"t1","message":{"role":"user","content":"\#(text)"},"promptSource":"typed","origin":{"kind":"human"}}"#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:e1", "notice:e1#1"])
        #expect(
            ClaudeSample.entry("notice:e1", in: transcript)
                == .notice(ChatNotice(kind: .system, title: "Message from @w2", detail: "DONE")))
        #expect(
            ClaudeSample.entry("notice:e1#1", in: transcript)
                == .notice(ChatNotice(kind: .system, title: "Teammate @w4 finished", detail: "All four passed")))
        #expect(transcript.recordedPrompts.map(\.text) == ["Hello"])
    }

    // MARK: - Model changes and reasoning

    @Test("A refusal fallback retracts the refused text; a fallback block names the models")
    func modelFallback() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Draft the release notes"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a1","parentUuid":"p1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"I can't help with that."}]},"apiBlockIndex":0}
            {"type":"system","subtype":"model_refusal_fallback","uuid":"f1","parentUuid":"a1","retractedMessageUuids":["a1"],"originalModel":"claude-opus-5-5","fallbackModel":"claude-sonnet-5-5","level":"info"}
            {"type":"assistant","uuid":"a2","parentUuid":"f1","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Here are the release notes."}]},"apiBlockIndex":0}
            {"type":"system","subtype":"turn_duration","uuid":"t1","parentUuid":"a2","durationMs":900}
            {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Shorter, please"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a3","parentUuid":"p2","message":{"id":"m3","role":"assistant","content":[{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-sonnet-5-5"}}]},"apiBlockIndex":0}
            {"type":"assistant","uuid":"a4","parentUuid":"a3","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Short notes."}]},"apiBlockIndex":1}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "notice:f1", "text:a2", "user:p2", "notice:a3", "text:a4"])
        let switched = ChatEntry.Content.notice(
            ChatNotice(kind: .modelChange, title: "Switched from claude-opus-5-5 to claude-sonnet-5-5"))
        #expect(ClaudeSample.entry("notice:f1", in: transcript) == switched)
        #expect(ClaudeSample.entry("notice:a3", in: transcript) == switched)
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("Redacted reasoning keeps its duration and no text")
    func redactedThinking() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Think it over"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"r1","parentUuid":"p1","thinkingDurationMs":1200,"message":{"id":"m1","role":"assistant","content":[{"type":"redacted_thinking","data":"EuYBCkQIBxgCKkA"}]},"apiBlockIndex":0}
            {"type":"assistant","uuid":"r2","parentUuid":"r1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Done thinking."}]},"apiBlockIndex":1}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "think:r1", "text:r2"])
        #expect(
            ClaudeSample.entry("think:r1", in: transcript)
                == .reasoning(ChatReasoning(text: "", durationMilliseconds: 1_200)))
    }

    @Test(
        "Thinking with text that took almost no time is narration the terminal draws as text",
        arguments: [
            (#","thinkingDurationMs":2"#, true), (#","thinkingDurationMs":4000"#, false), ("", true),
        ])
    func narrationThinking(duration: String, isNarration: Bool) {
        // Claude Code 2.1.301 (CL-08): a signed thinking block of 2 ms.
        let narration = "README.md is short; next I'll read notes.txt."
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Explain before each call"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"r1","parentUuid":"p1"\#(duration),"message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"\#(narration)","signature":"EuYBCkQIBxgCKkA"}]},"apiBlockIndex":0}
            {"type":"assistant","uuid":"r2","parentUuid":"r1","thinkingDurationMs":3,"message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"EuYBCkQIBxgCKkA"}]},"apiBlockIndex":1}
            """#)
        if isNarration {
            #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:r1", "think:r2"])
            #expect(ClaudeSample.entry("text:r1", in: transcript) == .assistant(ChatAssistantMessage(text: narration)))
        } else {
            #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "think:r1", "think:r2"])
            #expect(
                ClaudeSample.entry("think:r1", in: transcript)
                    == .reasoning(ChatReasoning(text: narration, durationMilliseconds: 4_000)))
        }
        // Empty thinking stays Reasoning however short.
        #expect(
            ClaudeSample.entry("think:r2", in: transcript) == .reasoning(ChatReasoning(text: "", durationMilliseconds: 3)))
    }

    @Test("A command the running Claude Code doesn't know shows why and records the send")
    func unknownCommand() {
        // Claude Code 2.1.301 (CL-38): a skill added after it started.
        let (transcript, lines) = Self.read(
            Self.firstTurn + "\n" + #"""
                {"parentUuid":"t1","isSidechain":false,"type":"system","subtype":"informational","content":"Unknown command: /e2e-hello","isMeta":false,"timestamp":"2026-10-16T15:33:48.638Z","uuid":"u1","level":"warning"}
                {"parentUuid":"u1","isSidechain":false,"type":"system","subtype":"informational","content":"Args from unknown skill: please","isMeta":false,"timestamp":"2026-10-16T15:33:48.638Z","uuid":"u2","level":"warning"}
                {"parentUuid":"u2","isSidechain":false,"type":"system","subtype":"informational","content":"Auto-update available","isMeta":false,"uuid":"u3","level":"info"}
                """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1", "notice:u1"])
        #expect(
            ClaudeSample.entry("notice:u1", in: transcript)
                == .notice(
                    ChatNotice(
                        kind: .error, title: "Unknown command: /e2e-hello", detail: "Args from unknown skill: please")))
        #expect(transcript.recordedPrompts.last == ChatRecordedPrompt(
            offset: lines[3].offset, text: "/e2e-hello please", entryID: ChatEntryID("notice:u1")))
    }

    @Test("A compaction's preview skips Claude Code's fixed opening and starts with the summary")
    func compactionPreview() {
        // Claude Code 2.1.301 (CL-22).
        let summary = ClaudeTranscriptProjection.compactionPreamble + """


            Summary:
            1. Primary Request and Intent:
               The user asked to add a retry to the payment sheet.

            2. Key Technical Concepts:
               - SwiftUI sheets
            """
        #expect(
            ClaudeTranscriptProjection.compactionPreview(summary)
                == "The user asked to add a retry to the payment sheet.\n\n2. Key Technical Concepts:\n   - SwiftUI sheets")
        let inline = ClaudeTranscriptProjection.compactionPreamble
            + "\nSummary:\n1. Primary Request and Intent: Add a retry.\n2. Files: Pay.swift"
        #expect(ClaudeTranscriptProjection.compactionPreview(inline) == "Add a retry.\n2. Files: Pay.swift")
        // Another opening, or nothing after this one, keeps the whole text.
        #expect(ClaudeTranscriptProjection.compactionPreview("Summary: two questions were answered.")
            == "Summary: two questions were answered.")
        let bare = ClaudeTranscriptProjection.compactionPreamble + "\n\nSummary:\n"
        #expect(ClaudeTranscriptProjection.compactionPreview(bare) == bare)
    }

    @Test("A compaction's preview keeps the first section's items at one level")
    func compactionPreviewFirstSectionLevel() {
        // Claude Code 2.1.302 (verify2 D-V1-02): several items under the
        // dropped heading previewed as "• first" then "◦ second".
        let summary = ClaudeTranscriptProjection.compactionPreamble + """


            Summary:
            1. Primary Request and Intent:
               - Reply with the word "ok".
               - Create `v4.txt`, then edit it.
                  - nested detail

            2. Key Technical Concepts:
               - SwiftUI sheets
            """
        let preview = ClaudeTranscriptProjection.compactionPreview(summary)
        #expect(preview == """
            - Reply with the word "ok".
            - Create `v4.txt`, then edit it.
               - nested detail

            2. Key Technical Concepts:
               - SwiftUI sheets
            """)
        #expect(
            ChatDivider.compaction(summary: preview).accessibilityPreview
                == "• Reply with the word \"ok\".\n• Create v4.txt, then edit it.\n◦ nested detail")
    }

    @Test("A compaction's divider previews Claude Code's Markdown summary as plain lines")
    func compactionDividerPlainText() throws {
        // Claude Code 2.1.302 (V1 CL-22): the summary is Markdown lists.
        let summary = ClaudeTranscriptProjection.compactionPreamble + """


            Summary:
            1. Primary Request and Intent:
               - 用户要求在 `README.md` 末尾加一行

            2. Key Technical Concepts:
               - **SwiftUI** sheets

            3. Files and Code Sections:
               - README.md
            """
        let content = try #require(String(data: try JSONEncoder().encode(summary), encoding: .utf8))
        let (transcript, _) = Self.read(
            Self.firstTurn + "\n" + #"""
                {"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"t1","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":5200}}
                """# + "\n"
                + #"{"type":"user","uuid":"s1","parentUuid":"b1","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"#
                + content + "}}")
        guard case .divider(let divider) = ClaudeSample.entry("compact:b1", in: transcript) else {
            Issue.record("no compaction divider")
            return
        }
        let detail = try #require(divider.detail)
        #expect(detail.hasPrefix("• 用户要求在 README.md 末尾加一行\n"))
        #expect(!detail.contains("`") && !detail.contains("**") && !detail.contains("- "))
        #expect(detail.contains("◦ SwiftUI sheets"))
        // VoiceOver reads the lines the divider shows, not every section.
        #expect(
            divider.accessibilityPreview
                == "• 用户要求在 README.md 末尾加一行\n2. Key Technical Concepts:\n◦ SwiftUI sheets")
    }

    // MARK: - Tool rows

    @Test(
        "A Read that showed an image offers its absolute Host path for a preview",
        arguments: [
            ("/tmp/proj/dot.png", "image", "/tmp/proj/dot.png"), ("/tmp/proj/notes.txt", "text", nil),
            ("dot.png", "image", nil),
        ] as [(String, String, String?)])
    func imageRead(path: String, type: String, expected: String?) {
        // Claude Code 2.1.301 (CL-32).
        let (transcript, _) = Self.read(
            Self.firstTurn + "\n" + #"""
                {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Read it"},"promptSource":"typed","origin":{"kind":"human"}}
                {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_read","name":"Read","input":{"file_path":"\#(path)"}}]},"apiBlockIndex":0}
                {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_read","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo"}}]}]},"toolUseResult":{"type":"\#(type)","file":{"type":"image/png"}}}
                """#)
        #expect(Self.tool("tool:toolu_read", in: transcript)?.imagePath == expected)
    }

    @Test("Chat about this on a question reads as Chat Instead, a plain decline as Declined")
    func chatInstead() {
        // Claude Code 2.1.301 (CLB-19).
        let decline = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file)."
        func question(feedback: String) -> ChatToolActivity? {
            let text = decline + " To tell you how to proceed, the user said:\\n" + feedback
            let (transcript, _) = Self.read(
                Self.firstTurn + "\n" + #"""
                    {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Ask me"},"promptSource":"typed","origin":{"kind":"human"}}
                    {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_ask","name":"AskUserQuestion","input":{"questions":[{"question":"Which size?","header":"Size","options":[{"label":"Small"},{"label":"Large"}],"multiSelect":false}]}}]},"apiBlockIndex":0}
                    {"type":"user","uuid":"r2","parentUuid":"a2","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_ask","is_error":true,"content":"\#(text)"}]},"toolUseResult":"Error: \#(text)","toolDenialKind":"user-rejected","userFeedback":"\#(feedback)"}
                    """#)
            return Self.tool("tool:toolu_ask", in: transcript)
        }
        let clarify = question(feedback: "The user wants to clarify these questions.\\n    Start by asking them what they would like to clarify.")
        #expect(clarify?.status == .chatInstead)
        #expect(clarify?.note == nil)
        let declined = question(feedback: "Not now")
        #expect(declined?.status == .declined)
        #expect(declined?.note == "Not now")
    }

    @Test("Task rows read by the task's subject and the status an update sets")
    func taskRows() {
        // Claude Code 2.1.301 with CLAUDE_CODE_ENABLE_TODO_TOOLS=1 (CL-40).
        let (transcript, _) = Self.read(
            Self.firstTurn + "\n" + #"""
                {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Track a"},"promptSource":"typed","origin":{"kind":"human"}}
                {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_create","name":"TaskCreate","input":{"subject":"Task a","description":"Track item a from the user's request"}}]},"apiBlockIndex":0}
                {"type":"assistant","uuid":"a3","parentUuid":"a2","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_update","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}]},"apiBlockIndex":1}
                {"type":"assistant","uuid":"a4","parentUuid":"a3","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_touch","name":"TaskUpdate","input":{"taskId":2}}]},"apiBlockIndex":2}
                """#)
        let create = Self.tool("tool:toolu_create", in: transcript)
        #expect(create?.title == "Task a")
        #expect(create?.subtitle == "Track item a from the user's request")
        #expect(Self.tool("tool:toolu_update", in: transcript)?.title == "Task #1: completed")
        #expect(Self.tool("tool:toolu_touch", in: transcript)?.title == "Updated task #2")
    }

    // MARK: - Links and unknown records

    @Test("Links are the newest relocation and a hand-off the session did not continue past")
    func links() {
        let records = #"""
            {"type":"relocated","relocatedCwd":"/home/dev/old","sessionId":"s1"}
            {"type":"continued-in","continuedInSessionId":"7d3f0c55-2a41-4c1e-9d0b-5b8e2f6a1c01","sessionId":"s1"}
            {"type":"user","uuid":"p2","parentUuid":"t1","message":{"role":"user","content":"Still here?"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"assistant","uuid":"a2","parentUuid":"p2","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"Yes."}]},"apiBlockIndex":0}
            {"type":"relocated","relocatedCwd":"/home/dev/new","sessionId":"s1"}
            {"type":"continued-in","continuedInSessionId":"0b9e4a7c-6f12-4d38-8c5a-3e1f7a2d9b02","sessionId":"s1"}
            """#
        let lines = ClaudeSample.lines(Self.firstTurn + "\n" + records)
        func links(_ count: Int) -> ChatTranscriptLinks {
            ClaudeSample.reducer(Array(lines.prefix(count))).transcript(ChatProjectionContext()).links
        }
        #expect(
            links(5)
                == ChatTranscriptLinks(
                    relocatedCwd: "/home/dev/old", continuedInSessionID: "7d3f0c55-2a41-4c1e-9d0b-5b8e2f6a1c01"))
        #expect(links(7) == ChatTranscriptLinks(relocatedCwd: "/home/dev/old"))
        #expect(
            links(9)
                == ChatTranscriptLinks(
                    relocatedCwd: "/home/dev/new", continuedInSessionID: "0b9e4a7c-6f12-4d38-8c5a-3e1f7a2d9b02"))

        // Fed newest first, the result is the same.
        var reversed = ClaudeSample.reducer(Array(lines.suffix(4)))
        reversed.prepend(Array(lines.prefix(5)))
        #expect(reversed.transcript(ChatProjectionContext()).links == links(9))
    }

    @Test("A record type this adapter does not know still links the records below it")
    func unknownRecord() {
        let (transcript, _) = Self.read(
            #"""
            {"type":"user","uuid":"p1","parentUuid":null,"message":{"role":"user","content":"Hello"},"promptSource":"typed","origin":{"kind":"human"}}
            {"type":"future-record","uuid":"f1","parentUuid":"p1","payload":{"anything":true}}
            {"type":"assistant","uuid":"a1","parentUuid":"f1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Hi."}]},"apiBlockIndex":0}
            """#)
        #expect(transcript.entries.map(\.id.rawValue) == ["user:p1", "text:a1"])
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics(unknownRecordTypes: ["future-record"]))
    }
}
