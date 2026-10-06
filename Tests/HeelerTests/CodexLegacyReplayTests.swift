import Foundation
import Testing

@testable import Heeler

/// Legacy rollouts: events and response items replayed through the rules of
/// Codex's `ThreadHistoryBuilder` (§5), with tool calls paired by `call_id`
/// (§6). No local file is legacy, so every input here is synthetic.
@Suite("Codex legacy replay")
struct CodexLegacyReplayTests {
    private let idle = ChatProjectionContext(activity: .idle)
    private let working = ChatProjectionContext(activity: .working)

    /// Events only: two implicit turns, a compaction, a turn that is rolled
    /// back and one still open at the end.
    private static func conversation() -> CodexRolloutBuilder {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("<environment_context>\n  <cwd>/work</cwd>\n</environment_context>")  // L1
        builder.legacyUser("first prompt")  // L2
        builder.legacyReasoning("thinking a")  // L3
        builder.legacyReasoning("thinking b")  // L4
        builder.legacyAgent("first answer")  // L5
        builder.legacyUser("second prompt")  // L6
        builder.legacyAgent("second answer")  // L7
        builder.event("context_compacted")  // L8
        builder.compacted(message: "summary for the model")  // L9
        builder.legacyUser("third prompt")  // L10
        builder.legacyAgent("third answer")  // L11
        builder.rolledBack(1)  // L12
        builder.legacyUser("fourth prompt")  // L13
        builder.legacyAgent("")  // L14
        return builder
    }

    @Test("Events replay into implicit turns, without the rolled-back turn")
    func legacyReplay() {
        let builder = Self.conversation()
        let lines = builder.chatLines
        let reducer = builder.reducer()
        #expect(reducer.support == .supported(.legacy))
        let projection = reducer.projection(idle)

        #expect(projection.turns.map(\.id) == [2, 6, 13].map { "legacy@\(lines[$0].offset)" })
        #expect(projection.turns.map(\.status) == [.completed, .completed, nil])
        #expect(
            projection.transcript.entries.map(\.id.rawValue)
                == [2, 3, 5, 6, 7, 8, 13].map { "codex/r1/@\(lines[$0].offset)" })
        #expect(
            projection.transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "first prompt")),
                .reasoning(ChatReasoning(text: "thinking a\n\nthinking b")),
                .assistant(ChatAssistantMessage(text: "first answer")),
                .user(ChatUserMessage(text: "second prompt")),
                .assistant(ChatAssistantMessage(text: "second answer")),
                .divider(ChatDivider(kind: .compaction)),
                .user(ChatUserMessage(text: "fourth prompt")),
            ])
        #expect(
            projection.transcript.recordedPrompts.map(\.text) == ["first prompt", "second prompt", "fourth prompt"])
        #expect(projection.transcript.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("A rollback that arrives live takes its turn's rows away")
    func liveRollback() {
        let builder = Self.conversation()
        let lines = builder.chatLines
        var reducer = CodexRolloutReducer(rolloutID: "r1")
        reducer.append(Array(lines[..<12]))
        #expect(
            reducer.transcript(working).entries.compactMap(\.user?.text) == [
                "first prompt", "second prompt", "third prompt",
            ])

        reducer.append([lines[12]])
        #expect(reducer.transcript(working).entries.compactMap(\.user?.text) == ["first prompt", "second prompt"])

        reducer.append(Array(lines[13...]))
        #expect(reducer.projection(working) == builder.reducer().projection(working))
    }

    @Test("A prompt joins a turn that holds only a compaction")
    func promptAfterCompaction() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.compacted(message: "")  // L1
        builder.legacyUser("continue")  // L2
        builder.legacyAgent("continuing")  // L3
        let lines = builder.chatLines

        let projection = builder.reducer().projection(idle)
        #expect(projection.turns.map(\.id) == ["legacy@\(lines[1].offset)"])
        #expect(projection.transcript.entries.map(\.sourceOffset) == [lines[2].offset, lines[3].offset])
    }

    @Test("Explicit turns end by id, with a Stopped or failure row")
    func explicitTurns() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.turnStarted("t1")  // L1
        builder.legacyUser("go")  // L2
        builder.legacyAgent("working on it")  // L3
        builder.turnAborted("t1")  // L4
        builder.turnStarted("t2")  // L5
        builder.legacyUser("again")  // L6
        builder.turnComplete("t2", error: "model overloaded")  // L7
        let lines = builder.chatLines

        let projection = builder.reducer().projection(idle)
        #expect(projection.turns.map(\.id) == ["t1", "t2"])
        #expect(projection.turns.map(\.status) == [.interrupted, .failed])
        #expect(
            projection.transcript.entries.map(\.id.rawValue)
                == [2, 3, 4, 6, 7].map { "codex/r1/@\(lines[$0].offset)" })
        #expect(
            projection.transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "go")),
                .assistant(ChatAssistantMessage(text: "working on it")),
                .notice(ChatNotice(kind: .stopped, title: "Stopped")),
                .user(ChatUserMessage(text: "again")),
                .notice(ChatNotice(kind: .error, title: "Turn failed", detail: "model overloaded")),
            ])
    }

    @Test("Calls pair with outputs in the 0.45 JSON and the text format")
    func toolPairing() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("list files")  // L1
        builder.legacyCall("shell", callID: "call-1", arguments: ["command": ["bash", "-lc", "ls"]])  // L2
        builder.legacyCall("exec_command", callID: "call-2", arguments: ["cmd": "false"])  // L3
        builder.legacyOutput(callID: "call-2", output: "Exit code: 1\nWall time: 0.1 seconds\nOutput:\nboom")  // L4
        builder.legacyOutput(
            callID: "call-1", output: #"{"output":"a.txt\n","metadata":{"exit_code":0,"duration_seconds":0.1}}"#)  // L5
        builder.legacyCall("shell", callID: "call-3", arguments: ["command": ["sleep", "60"]])  // L6
        let lines = builder.chatLines
        func reference(_ index: Int) -> ChatOutputReference {
            ChatOutputReference(offset: lines[index].offset, length: lines[index].length)
        }

        let reducer = builder.reducer()
        let transcript = reducer.transcript(working)
        #expect(transcript.entries.map(\.sourceOffset) == [1, 2, 3, 6].map { lines[$0].offset })
        #expect(
            transcript.entries.compactMap(\.tool) == [
                ChatToolActivity(
                    kind: .command, name: "shell", title: "ls", status: .succeeded, exitCode: 0, callID: "call-1",
                    preview: ChatToolPreview(text: "a.txt\n", isTruncated: false), output: reference(5)),
                ChatToolActivity(
                    kind: .command, name: "exec_command", title: "false", status: .failed, exitCode: 1,
                    callID: "call-2", preview: ChatToolPreview(text: "boom", isTruncated: false),
                    output: reference(4)),
                ChatToolActivity(
                    kind: .command, name: "shell", title: "sleep 60", status: .running, callID: "call-3",
                    output: reference(6)),
            ])
        #expect(
            transcript.pendingRequests == [
                ChatPendingRequest(
                    entryID: ChatEntryID("codex/r1/@\(lines[6].offset)"), callID: "call-3", kind: .command,
                    toolName: "shell", summary: "sleep 60")
            ])

        // Once herdr stops reporting Working, the unpaired call has no result.
        let settled = reducer.transcript(idle)
        #expect(settled.entries.last?.tool?.status == .noResult)
        #expect(settled.pendingRequests.isEmpty)
    }

    @Test("A patch call, its end event and its output share one row")
    func patchEndMerges() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("add notes")  // L1
        builder.response(
            "custom_tool_call",
            [
                ("call_id", "call-p"), ("name", "apply_patch"),
                ("input", "*** Begin Patch\n*** Add File: /work/notes.txt\n+hello\n*** End Patch\n"),
            ])  // L2
        builder.event(
            "patch_apply_end",
            [
                ("call_id", "call-p"), ("stdout", "Success. Updated the following files:\nA notes.txt\n"),
                ("stderr", ""), ("success", true),
                ("changes", ["/work/notes.txt": ["type": "add", "content": "hello\n"]]),
            ])  // L3
        builder.response(
            "custom_tool_call_output",
            [("call_id", "call-p"), ("output", "Success. Updated the following files:\nA notes.txt\n")])  // L4
        let lines = builder.chatLines

        let entries = builder.reducer().transcript(idle).entries
        #expect(entries.map(\.sourceOffset) == [lines[1].offset, lines[2].offset])
        #expect(
            entries.last?.tool
                == ChatToolActivity(
                    kind: .fileWrite, name: "apply_patch", title: "notes.txt", status: .succeeded,
                    diff: ChatDiffStats(added: 1, removed: 0), callID: "call-p",
                    preview: ChatToolPreview(text: "Success. Updated the following files:\nA notes.txt\n", isTruncated: false),
                    output: ChatOutputReference(offset: lines[4].offset, length: lines[4].length)))
    }
}
