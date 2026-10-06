import Foundation
import Testing

@testable import Heeler

/// Tool rows: titles as the TUI renders them, outcomes and line counts (§6).
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

/// The formats legacy tool outputs were written in (§6 Legacy pairing).
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

/// A command still `in_progress` when the loaded lines end (§5).
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
