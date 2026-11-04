import Foundation
import Testing

@testable import Heeler

/// Tool rows: titles as the TUI renders them, outcomes and line counts
/// (docs/research/codex-rollout-format.md, "Tool calls and outputs").
@Suite("Codex tool summaries")
struct CodexToolSummaryTests {
    @Test("Command titles follow the TUI", arguments: CodexCommandTitleCase.allCases)
    func commandTitle(_ titleCase: CodexCommandTitleCase) {
        #expect(CodexToolSummary.commandTitle(titleCase.argv) == titleCase.title)
    }

    @Test("Legacy outputs give their exit code and body", arguments: CodexLegacyOutputCase.allCases)
    func legacyOutput(_ outputCase: CodexLegacyOutputCase) {
        let parsed = CodexToolSummary.legacyOutput(outputCase.text)
        #expect(parsed.exitCode == outputCase.exitCode)
        #expect(parsed.body == outputCase.body)
    }

    @Test("A review's forwarded reviewer turn joins the review turn without its prompt")
    func reviewForwardedTurn() {
        // Codex 0.162.1: the review turn has no task_started; the reviewer's
        // turn starts under it and writes the prompt Codex made for it.
        var builder = CodexRolloutBuilder()
        builder.item(
            "rv", ["type": "EnteredReviewMode", "id": "e1", "user_facing_hint": "current changes"])
        builder.event(
            "task_started", [("turn_id", "child"), ("root_turn_id", "rv"), ("started_at", 1_791_266_142)])
        builder.userMessage("child", id: "u1", text: "Review the current code changes and provide findings.")
        builder.command("child", id: "c1", argv: ["/bin/zsh", "-lc", "git diff"])
        builder.item(
            "rv",
            [
                "type": "ExitedReviewMode", "id": "x1",
                "review_output": ["findings": [], "overall_explanation": "No issues."],
            ])
        builder.agentMessage("rv", id: "a1", text: "No issues.")
        builder.turnComplete("rv")

        #expect(
            Self.shapes(builder.reducer().transcript(ChatProjectionContext(activity: .idle)))
                == ["notice Review started", "tool git diff", "notice Review finished", "assistant No issues."])
    }

    @Test("A reviewer turn joins its review turn when the review's own lines all come after it")
    func reviewForwardedTurnBeforeItsRoot() {
        // A window that starts at the reviewer's task_started.
        var builder = CodexRolloutBuilder()
        builder.event(
            "task_started", [("turn_id", "child"), ("root_turn_id", "rv"), ("started_at", 1_791_266_142)])
        builder.userMessage("child", id: "u1", text: "Review the current code changes and provide findings.")
        builder.command("child", id: "c1", argv: ["/bin/zsh", "-lc", "git diff"])
        builder.item(
            "rv",
            [
                "type": "ExitedReviewMode", "id": "x1",
                "review_output": ["findings": [], "overall_explanation": "No issues."],
            ])
        builder.agentMessage("rv", id: "a1", text: "No issues.")
        builder.turnComplete("rv")

        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: .idle))
        #expect(Self.shapes(transcript) == ["tool git diff", "notice Review finished", "assistant No issues."])
        #expect(transcript.turns.count == 1)
    }

    @Test("A turn started under a turn the file never names stays its own turn with its prompt")
    func turnUnderAnAbsentRoot() {
        // A Codex 0.162.1 subagent child rollout: root_turn_id is the
        // parent's spawning turn, which lives in the parent's file.
        var builder = CodexRolloutBuilder()
        builder.event(
            "task_started", [("turn_id", "child"), ("root_turn_id", "parent-turn"), ("started_at", 1_791_266_142)])
        builder.userMessage("child", id: "u1", text: "Look into the flaky test")
        builder.agentMessage("child", id: "a1", text: "Found it.")
        builder.turnComplete("child")

        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: .idle))
        #expect(Self.shapes(transcript) == ["user Look into the flaky test", "assistant Found it."])
        #expect(transcript.turns.map(\.firstEntryID) == [transcript.entries.first?.id])
    }

    private static func shapes(_ transcript: ChatTranscript) -> [String] {
        transcript.entries.map { entry in
            switch entry.content {
            case .user(let message): "user \(message.text)"
            case .assistant(let message): "assistant \(message.text)"
            case .tool(let tool): "tool \(tool.title)"
            case .notice(let notice): "notice \(notice.title)"
            default: "other"
            }
        }
    }

    @Test("Turn items become tool rows")
    func toolItems() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.item(
            "t1",
            [
                "type": "FileChange", "id": "p1",
                "changes": [
                    "/work/new.txt": ["type": "add", "content": "a\nb\n"],
                    "/work/old.txt": ["type": "delete", "content": "x\n"],
                    "/work/src/a.swift": [
                        "type": "update", "unified_diff": "@@ -1,2 +1,2 @@\n-old\n+new\n context\n",
                        "move_path": "/work/src/b.swift",
                    ],
                ],
                "status": "completed",
            ])
        builder.item(
            "t1",
            [
                "type": "McpToolCall", "id": "m1", "server": "docs", "tool": "search", "status": "failed",
                "arguments": ["q": "x"], "error": ["message": "timeout"],
            ])
        builder.item(
            "t1",
            [
                "type": "WebSearch", "id": "w1", "query": "swift testing",
                "action": ["type": "search", "query": "swift testing"],
            ])
        builder.command("t1", id: "c1", argv: ["rm", "-rf", "build"], status: "declined", exitCode: nil)
        builder.command(
            "t1", id: "c2", argv: ["bash", "-lc", "cat README.md"],
            parsedCommands: [["type": "read", "cmd": "cat README.md", "name": "README.md", "path": "README.md"]])
        builder.command("t1", id: "c3", argv: ["false"], status: "failed", exitCode: 1)
        builder.turnComplete("t1")
        let lines = builder.chatLines
        func reference(_ index: Int) -> ChatOutputReference {
            ChatOutputReference(offset: lines[index].offset, length: lines[index].length)
        }

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(
            tools == [
                ChatToolActivity(
                    kind: .fileEdit, name: "FileChange", title: "new.txt, old.txt, src/a.swift → src/b.swift",
                    status: .succeeded, diff: ChatDiffStats(added: 3, removed: 2, files: 3), callID: "p1",
                    output: reference(2)),
                ChatToolActivity(
                    kind: .mcp, name: "docs.search", title: "docs.search", status: .failed, callID: "m1",
                    preview: ChatToolPreview(text: "timeout", isTruncated: false), output: reference(3)),
                ChatToolActivity(
                    kind: .web, name: "WebSearch", title: "swift testing", status: .succeeded, callID: "w1",
                    output: reference(4)),
                ChatToolActivity(
                    kind: .command, name: "CommandExecution", title: "rm -rf build", status: .declined, callID: "c1",
                    output: reference(5)),
                ChatToolActivity(
                    kind: .fileRead, name: "CommandExecution", title: "cat README.md", subtitle: "README.md",
                    status: .succeeded, exitCode: 0, callID: "c2", output: reference(6)),
                ChatToolActivity(
                    kind: .command, name: "CommandExecution", title: "false", status: .failed, exitCode: 1,
                    callID: "c3", output: reference(7)),
            ])
    }

    @Test("A directory listing is its own kind; mixed exploration stays a search")
    func listingKind() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.command(
            "t1", id: "c1", argv: ["bash", "-lc", "ls /nonexistent-heeler-dir"], status: "failed", exitCode: 1,
            parsedCommands: [
                ["type": "list_files", "cmd": "ls /nonexistent-heeler-dir", "path": "/nonexistent-heeler-dir"]
            ])
        builder.command(
            "t1", id: "c2", argv: ["bash", "-lc", "ls src && cat README.md"],
            parsedCommands: [
                ["type": "list_files", "cmd": "ls src", "path": "src"],
                ["type": "read", "cmd": "cat README.md", "name": "README.md", "path": "README.md"],
            ])
        builder.turnComplete("t1")

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(tools.map(\.kind) == [.listing, .search])
        #expect(tools.map(\.subtitle) == ["/nonexistent-heeler-dir", nil])
    }

    @Test("A wait for subagents is a plain step, not a subagent card")
    func waitForSubagents() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.item(
            "t1",
            [
                "type": "CollabAgentToolCall", "id": "call_w1", "tool": "wait", "status": "completed",
                "sender_thread_id": "thread-1", "receiver_thread_ids": [], "receiver_agents": [],
                "agents_states": [:],
            ])
        builder.turnComplete("t1")
        let lines = builder.chatLines

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(
            tools == [
                ChatToolActivity(
                    kind: .other, name: "wait", title: "Waited for subagents", status: .succeeded,
                    callID: "call_w1", output: ChatOutputReference(offset: lines[2].offset, length: lines[2].length))
            ])
    }

    /// Codex 0.163.0 (V2 CX-22): a turn can end while a command it started
    /// keeps running as a background terminal, whose item Codex records
    /// under the ended turn when it finishes.
    @Test("A command recorded after its turn completed joins the turn's steps, above the answer")
    func lateCommandJoinsTheSteps() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "Run sleep 20 then reply done.")
        builder.command("t1", id: "c1", argv: ["echo", "first"])
        builder.agentMessage("t1", id: "a1", text: "third")
        builder.turnComplete("t1")
        builder.command("t1", id: "c2", argv: ["sleep", "20"])
        builder.turnStarted("t2")
        builder.userMessage("t2", id: "u2", text: "Next")
        builder.agentMessage("t2", id: "a2", text: "ok")
        builder.turnComplete("t2")

        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: .idle))
        #expect(
            transcript.entries.map { $0.tool?.title ?? $0.assistant?.text ?? "prompt" }
                == ["prompt", "echo first", "sleep 20", "third", "prompt", "ok"])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed])
    }

    @Test("A patch aborted before it applied is interrupted, not failed")
    func abortedPatch() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        for (id, stderr) in [("p1", "execution error: TurnAborted\n"), ("p2", "patch rejected: context mismatch")] {
            builder.item(
                "t1",
                [
                    "type": "FileChange", "id": .string(id),
                    "changes": ["/work/a.txt": ["type": "add", "content": "a\n"]],
                    "status": "failed", "stdout": "", "stderr": .string(stderr),
                ])
        }
        builder.turnAborted("t1")

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(tools.map(\.status) == [.interrupted, .failed])
        #expect(tools.map(\.preview?.text) == [nil, "patch rejected: context mismatch"])
        // Nothing was applied, so a group counts no added lines for it.
        #expect(tools.first?.diff == nil)
    }

    /// Codex 0.163.0 in code mode (V2 CXB-05): a patch declined on its card
    /// leaves only the `exec` call that wrapped it and its "aborted by user"
    /// output, with no `FileChange` item.
    private static func codeModeTurn(
        _ builder: inout CodexRolloutBuilder, script: String, output: String, fileChange: Bool = false
    ) {
        builder.turnStarted("t1")
        let passthrough: CodexJSON = ["turn_id": "t1"]
        builder.response(
            "custom_tool_call",
            [
                ("id", "ctc_1"), ("status", "completed"), ("call_id", "call_x"), ("name", "exec"),
                ("input", .string(script)), ("internal_chat_message_metadata_passthrough", passthrough),
            ])
        builder.response(
            "custom_tool_call_output",
            [
                ("id", "ctco_1"), ("call_id", "call_x"), ("output", .string(output)),
                ("internal_chat_message_metadata_passthrough", passthrough),
            ])
        if fileChange {
            // Codex 0.160.1 and 0.162.1 also record the patch itself.
            builder.item(
                "t1",
                [
                    "type": "FileChange", "id": "exec-1",
                    "changes": ["/work/patch2.txt": ["type": "add", "content": "probe\n"]],
                    "status": "failed", "stdout": "", "stderr": "execution error: TurnAborted",
                ])
        }
        builder.turnAborted("t1")
    }

    private static let patchScript =
        #"text(await tools.apply_patch("*** Begin Patch\n*** Add File: /work/patch2.txt\n+probe\n*** End Patch"));"#
        + "\n"

    @Test("A code-mode patch the user declined reads as an interrupted file row")
    func declinedCodeModePatch() {
        var builder = CodexRolloutBuilder()
        Self.codeModeTurn(&builder, script: Self.patchScript, output: "aborted by user after 11.8s")
        let lines = builder.chatLines

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(
            tools == [
                ChatToolActivity(
                    kind: .fileWrite, name: "apply_patch", title: "patch2.txt", status: .interrupted,
                    callID: "call_x", output: ChatOutputReference(offset: lines[2].offset, length: lines[2].length))
            ])
    }

    @Test(
        "A code-mode call shows no row unless it was an aborted patch",
        arguments: [
            (Self.patchScript, "Script completed\nSuccess. Updated the following files:\nA patch2.txt"),
            ("text(await tools.exec_command({cmd: \"ls\"}));\n", "aborted by user after 2.0s"),
        ])
    func codeModeCallWithoutRow(script: String, output: String) {
        var builder = CodexRolloutBuilder()
        Self.codeModeTurn(&builder, script: script, output: output)

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(tools.isEmpty)
    }

    @Test("A declined code-mode patch that Codex also recorded shows once")
    func declinedCodeModePatchWithItsFileChange() {
        var builder = CodexRolloutBuilder()
        Self.codeModeTurn(&builder, script: Self.patchScript, output: "aborted by user after 9.7s", fileChange: true)

        let tools = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.tool)
        #expect(tools.map(\.name) == ["FileChange"])
        #expect(tools.map(\.status) == [.interrupted])
    }

    @Test("A legacy patch end aborted before it applied is interrupted")
    func abortedLegacyPatch() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.legacyUser("add a")
        builder.event(
            "patch_apply_end",
            [
                ("call_id", "call-p"), ("stdout", ""), ("stderr", "execution error: TurnAborted"),
                ("success", false), ("changes", ["/work/a.txt": ["type": "add", "content": "a\n"]]),
            ])

        let tool = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.last?.tool
        #expect(tool?.status == .interrupted)
        #expect(tool?.preview == nil)
        #expect(tool?.diff == nil)
    }

    @Test("A failed turn shows an API error's message and keeps the JSON to copy")
    func failedTurnError() {
        let json = #"{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"The 'heeler-no-such-model' model is not supported when using Codex with a ChatGPT account."}}"#
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.userMessage("t1", id: "u1", text: "hi")
        builder.turnComplete("t1", error: json)
        builder.turnStarted("t2")
        builder.userMessage("t2", id: "u2", text: "again")
        builder.turnComplete("t2", error: "stream disconnected before completion")

        let notices = builder.reducer().transcript(ChatProjectionContext(activity: .idle)).entries.compactMap(\.notice)
        #expect(
            notices == [
                ChatNotice(
                    kind: .error, title: "Turn failed",
                    detail: "The 'heeler-no-such-model' model is not supported when using Codex with a ChatGPT account.",
                    rawDetail: json),
                ChatNotice(kind: .error, title: "Turn failed", detail: "stream disconnected before completion"),
            ])
        #expect(CodexToolSummary.errorDisplay(#"{"message":"Rate limited"}"#) == "Rate limited")
        #expect(CodexToolSummary.errorDisplay(#"{"error":{"code":"x"}}"#) == #"{"error":{"code":"x"}}"#)
    }

    @Test("An answer's note drops its user_note key")
    func displayAnswer() {
        #expect(
            CodexToolSummary.displayAnswer("None of the above\nuser_note: Medium please")
                == "None of the above\nMedium please")
        #expect(CodexToolSummary.displayAnswer("Red") == "Red")
        #expect(CodexToolSummary.displayAnswer("say user_note: x") == "say user_note: x")
    }

    @Test("A call without an outcome follows the turn and herdr's activity", arguments: CodexOpenCallCase.allCases)
    func openCall(_ openCase: CodexOpenCallCase) {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.command("t1", id: "c1", argv: ["sleep", "60"], status: "in_progress", exitCode: nil)
        switch openCase.ending {
        case .open:
            break
        case .aborted:
            builder.turnAborted("t1")
        case .followedByTurn:
            builder.turnStarted("t2")
        }

        let transcript = builder.reducer().transcript(ChatProjectionContext(activity: openCase.activity))
        #expect(transcript.entries.first?.tool?.status == openCase.status)
        #expect(transcript.pendingRequests.map(\.callID) == (openCase.isPending ? ["c1"] : []))
    }
}

/// argv and the title the TUI shows for it.
enum CodexCommandTitleCase: CaseIterable, CustomTestStringConvertible {
    case bashScript
    case zshPath
    case powershell
    case plainArgv
    case spacedWord
    case singleQuote
    case dollarSign
    case emptyWord
    case shellWithExtraWords

    var testDescription: String {
        switch self {
        case .bashScript: "bash -lc script"
        case .zshPath: "/bin/zsh -c script"
        case .powershell: "pwsh -Command"
        case .plainArgv: "plain argv"
        case .spacedWord: "word with a space"
        case .singleQuote: "word with a single quote"
        case .dollarSign: "word with a dollar sign"
        case .emptyWord: "empty word"
        case .shellWithExtraWords: "shell with extra words"
        }
    }

    var argv: [String] {
        switch self {
        case .bashScript: ["bash", "-lc", "echo hi && ls"]
        case .zshPath: ["/bin/zsh", "-c", "ls -la"]
        case .powershell: ["pwsh", "-NoProfile", "-Command", "Get-ChildItem"]
        case .plainArgv: ["git", "status"]
        case .spacedWord: ["git", "commit", "-m", "fix it"]
        case .singleQuote: ["echo", "it's"]
        case .dollarSign: ["echo", "$HOME"]
        case .emptyWord: ["printf", ""]
        case .shellWithExtraWords: ["bash", "-lc", "ls", "extra"]
        }
    }

    var title: String {
        switch self {
        case .bashScript: "echo hi && ls"
        case .zshPath: "ls -la"
        case .powershell: "Get-ChildItem"
        case .plainArgv: "git status"
        case .spacedWord: "git commit -m 'fix it'"
        case .singleQuote: #"echo "it's""#
        case .dollarSign: "echo '$HOME'"
        case .emptyWord: "printf ''"
        case .shellWithExtraWords: "bash -lc ls extra"
        }
    }
}

/// The formats legacy tool outputs were written in
/// (docs/research/codex-rollout-format.md, "Legacy pairing").
enum CodexLegacyOutputCase: CaseIterable, CustomTestStringConvertible {
    case json045
    case exitCodeHeader
    case unifiedExec
    case stillRunning
    case plainText
    case outputWordWithoutHeader

    var testDescription: String {
        switch self {
        case .json045: "0.45 JSON"
        case .exitCodeHeader: "Exit code header"
        case .unifiedExec: "unified exec header"
        case .stillRunning: "session still running"
        case .plainText: "plain text"
        case .outputWordWithoutHeader: "Output: without a header"
        }
    }

    var text: String {
        switch self {
        case .json045: #"{"output":"done\n","metadata":{"exit_code":2,"duration_seconds":1.5}}"#
        case .exitCodeHeader: "Exit code: 0\nWall time: 1.2 seconds\nOutput:\nok"
        case .unifiedExec:
            "Chunk ID: 4f2a\nWall time: 0.5 seconds\nProcess exited with code 3\nOriginal token count: 10\nOutput:\nfail"
        case .stillRunning: "Chunk ID: 4f2b\nWall time: 1.0 seconds\nProcess running with session ID 7\nOutput:\npartial"
        case .plainText: "just text"
        case .outputWordWithoutHeader: "Output:\nliteral"
        }
    }

    var exitCode: Int? {
        switch self {
        case .json045: 2
        case .exitCodeHeader: 0
        case .unifiedExec: 3
        case .stillRunning, .plainText, .outputWordWithoutHeader: nil
        }
    }

    var body: String {
        switch self {
        case .json045: "done\n"
        case .exitCodeHeader: "ok"
        case .unifiedExec: "fail"
        case .stillRunning: "partial"
        case .plainText: "just text"
        case .outputWordWithoutHeader: "Output:\nliteral"
        }
    }
}

/// A command still `in_progress` when the loaded lines end
/// (docs/research/codex-rollout-format.md, "Paginated turns").
enum CodexOpenCallCase: CaseIterable, CustomTestStringConvertible {
    case workingInOpenTurn
    case blockedInOpenTurn
    case idleInOpenTurn
    case abortedTurn
    case laterTurnStarted

    enum Ending {
        case open
        case aborted
        case followedByTurn
    }

    var testDescription: String {
        switch self {
        case .workingInOpenTurn: "open turn while Working"
        case .blockedInOpenTurn: "open turn while Blocked"
        case .idleInOpenTurn: "open turn while idle"
        case .abortedTurn: "aborted turn"
        case .laterTurnStarted: "a later turn started"
        }
    }

    var ending: Ending {
        switch self {
        case .workingInOpenTurn, .blockedInOpenTurn, .idleInOpenTurn: .open
        case .abortedTurn: .aborted
        case .laterTurnStarted: .followedByTurn
        }
    }

    var activity: ChatAgentActivity {
        switch self {
        case .blockedInOpenTurn: .blocked
        case .idleInOpenTurn: .idle
        case .workingInOpenTurn, .abortedTurn, .laterTurnStarted: .working
        }
    }

    var status: ChatToolActivity.Status {
        switch self {
        case .workingInOpenTurn: .running
        case .blockedInOpenTurn: .awaitingApproval
        case .idleInOpenTurn: .noResult
        case .abortedTurn, .laterTurnStarted: .interrupted
        }
    }

    var isPending: Bool {
        self == .workingInOpenTurn || self == .blockedInOpenTurn
    }
}
