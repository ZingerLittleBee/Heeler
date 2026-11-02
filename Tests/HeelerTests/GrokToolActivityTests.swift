import Foundation
import Testing

@testable import Heeler

@Suite("Grok Build tool activity")
struct GrokToolActivityTests {
    /// Where live-A's fixtures were captured: its group names the directory.
    private static let pathA =
        "/Users/developer/.grok/sessions/%2FUsers%2Fdeveloper%2Fscratch%2Fcap-grok-a%2Fproj/01900000-0000-7000-8000-000000000004/updates.jsonl"
    private static let pathB =
        "/Users/developer/.grok/sessions/%2FUsers%2Fdeveloper%2Fscratch%2Fcap-grok-b%2Fproj/01900000-0000-7000-8000-000000000014/updates.jsonl"
    private static let directoryA = "/Users/developer/scratch/cap-grok-a/proj"
    private static let directoryB = "/Users/developer/scratch/cap-grok-b/proj"

    // MARK: Helpers

    /// Lines `range` of a `grok/` fixture (1-based, inclusive), with their
    /// offsets in the file.
    private static func lines(_ fixture: String, _ range: ClosedRange<Int>? = nil) throws -> [ChatLine] {
        let all = try ChatFixture.lines("grok/\(fixture)")
        guard let range else { return all }
        return Array(all[(range.lowerBound - 1)..<range.upperBound])
    }

    private static func reducer(_ lines: [ChatLine], path: String = pathA) -> GrokTranscriptReducer {
        var reducer = GrokTranscriptReducer(transcriptPath: path)
        reducer.append(lines)
        return reducer
    }

    /// The transcript of `lines` read as a window that starts at the first
    /// of them.
    private static func transcript(
        _ lines: [ChatLine], path: String = pathA, activity: ChatAgentActivity = .idle
    ) -> ChatTranscript {
        reducer(lines, path: path).transcript(
            ChatProjectionContext(windowStart: lines.first?.offset ?? 0, activity: activity))
    }

    private static func fixture(
        _ name: String, lines range: ClosedRange<Int>? = nil, path: String = pathA,
        activity: ChatAgentActivity = .idle
    ) throws -> ChatTranscript {
        transcript(try lines(name, range), path: path, activity: activity)
    }

    /// Where line `number` of `lines` (1-based) is.
    private static func reference(_ lines: [ChatLine], _ number: Int) -> ChatOutputReference {
        ChatOutputReference(offset: lines[number - 1].offset, length: lines[number - 1].length)
    }

    private static func tools(_ transcript: ChatTranscript) -> [ChatToolActivity] {
        transcript.entries.compactMap { if case .tool(let tool) = $0.content { tool } else { nil } }
    }

    private static func tool(_ transcript: ChatTranscript, _ callID: String) throws -> ChatToolActivity {
        let entry = try #require(transcript.entries.first { $0.id.rawValue == "grok:tool:\(callID)" })
        let tool: ChatToolActivity? = if case .tool(let tool) = entry.content { tool } else { nil }
        return try #require(tool)
    }

    private static func notices(_ transcript: ChatTranscript) -> [ChatEntry] {
        transcript.entries.filter {
            if case .notice = $0.content { true } else { false }
        }
    }

    private static func preview(_ text: String) -> ChatToolPreview {
        ChatToolPreview(text: text, isTruncated: false)
    }

    // MARK: Synthetic records

    /// GrokTranscriptLocatorTests' test-only session id.
    private static let session = "01900000-0000-7000-8000-000000000010"
    private static let start: Int64 = 1_792_440_000_000
    private static let callID = "call-01900000-0000-7000-8000-000000000011-0"

    /// One `updates.jsonl` line: `update` is the body of that object.
    private static func record(_ update: String, event: Int, method: String = "session/update") -> String {
        let milliseconds = start + Int64(event) * 100
        return
            #"{"timestamp":\#(milliseconds / 1_000),"method":"\#(method)","params":{"sessionId":"\#(session)","update":{\#(update)},"_meta":{"eventId":"\#(session)-\#(event)","agentTimestampMs":\#(milliseconds)}}}"#
    }

    private static func json(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }

    private static func prompt(_ text: String, index: Int, event: Int) throws -> String {
        record(
            #""sessionUpdate":"user_message_chunk","content":{"type":"text","text":\#(try json(text))},"_meta":{"modelId":"grok-4.7-build-fast","promptIndex":\#(index)}"#,
            event: event)
    }

    /// A call as Grok writes it before it runs: its title is the tool's
    /// name, and `input` the body of its partial `rawInput`.
    private static func call(
        _ id: String = callID, name: String, kind: String = "execute", input: String, event: Int
    ) -> String {
        record(
            #""sessionUpdate":"tool_call","toolCallId":"\#(id)","title":"\#(name)","rawInput":{\#(input)},"_meta":{"x.ai/tool":{"version":1,"name":"\#(name)","kind":"\#(kind)","namespace":"grok_build","label":"Tool","read_only":false}}"#,
            event: event)
    }

    /// A completed result: `content` and `rawOutput` are the bodies of those
    /// values; a nil `content` leaves the key out.
    private static func result(
        _ id: String = callID, status: String = "completed", content: String? = "", rawOutput: String, event: Int
    ) -> String {
        let content = content.map { #","content":[\#($0)]"# } ?? ""
        return record(
            #""sessionUpdate":"tool_call_update","toolCallId":"\#(id)","status":"\#(status)"\#(content),"rawOutput":{\#(rawOutput)}"#,
            event: event)
    }

    private static func text(_ text: String) throws -> String {
        #"{"type":"content","content":{"type":"text","text":\#(try json(text))}}"#
    }

    private static func completed(_ stopReason: String, event: Int) -> String {
        record(
            #""sessionUpdate":"turn_completed","stop_reason":"\#(stopReason)","elapsed_ms":2500"#, event: event,
            method: "_x.ai/session/update")
    }

    private static func lines(_ rows: [String]) -> [ChatLine] {
        JSONLLineFramer.lines(in: Data((rows.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: Kinds and titles

    private static let kinds: [(String, ChatToolActivity.Kind)] = [
        ("run_terminal_command", .command), ("read_file", .fileRead), ("grep", .search), ("search_tool", .search),
        ("search_replace", .fileEdit), ("write", .fileWrite), ("list_dir", .listing), ("todo_write", .todo),
        ("spawn_subagent", .agent), ("ask_user_question", .question), ("web_fetch", .web), ("web_search", .web),
        ("x_search", .web), ("use_tool", .mcp), ("get_command_or_subagent_output", .other),
        ("kill_command_or_subagent", .other), ("monitor", .other),
    ]

    @Test(arguments: kinds)
    func mapsEachToolNameToItsRowKind(name: String, kind: ChatToolActivity.Kind) throws {
        // Grok's kind says read; the name decides.
        let transcript = Self.transcript(
            Self.lines([
                try Self.prompt("Go on.", index: 0, event: 1),
                Self.call(name: name, kind: "read", input: "", event: 2),
            ]), activity: .working)

        let tool = try Self.tool(transcript, Self.callID)
        #expect(tool.kind == kind)
        #expect(tool.name == name)
        #expect(tool.status == .running)
    }

    @Test func readsUnnamedCallsByTheirTitleOrKind() throws {
        let search = #"Web search: \"swift concurrency\""#
        let transcript = Self.transcript(
            Self.lines([
                try Self.prompt("Look it up.", index: 0, event: 1),
                // A search Grok's server runs names no tool.
                Self.record(
                    #""sessionUpdate":"tool_call","toolCallId":"\#(Self.callID)","title":"\#(search)","kind":"fetch","status":"in_progress","rawInput":{"variant":"WebSearch","backend":true}"#,
                    event: 2),
                // A tool this build does not know reads by Grok's kind.
                Self.call(
                    "call-01900000-0000-7000-8000-000000000011-1", name: "read_notebook", kind: "read",
                    input: #""file_path":"/Users/developer/scratch/cap-grok-a/proj/a.ipynb""#, event: 3),
            ]), activity: .working)

        let web = try Self.tool(transcript, Self.callID)
        #expect(web.kind == .web)
        #expect(web.name == "web_search")
        #expect(web.title == "swift concurrency")
        #expect(web.status == .running)
        let read = try Self.tool(transcript, "call-01900000-0000-7000-8000-000000000011-1")
        #expect(read.kind == .fileRead)
        #expect(read.name == "read_notebook")
        #expect(read.title == "a.ipynb")
    }

    // MARK: Commands

    @Test func commandRowsShowTheCommandAndItsOutput() throws {
        let lines = try Self.lines("core-turns.jsonl")
        let transcript = Self.transcript(lines)

        let id = "call-01900000-0000-7000-8000-000000000009-0"
        let entry = try #require(transcript.entries.first { $0.id.rawValue == "grok:tool:\(id)" })
        #expect(entry.sourceOffset == 6391)
        let output =
            "total 8\ndrwxr-xr-x@  4 developer  staff  128 Oct 19 22:53 .\ndrwxr-xr-x@  4 developer  staff  128 Oct 19 22:57 ..\ndrwxr-xr-x@ 12 developer  staff  384 Oct 19 22:53 .git\n-rw-r--r--@  1 developer  staff   90 Oct 19 22:53 README.md\n---\n       5"
        #expect(
            try Self.tool(transcript, id)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: #"ls -la && echo "---" && ls -la | wc -l"#,
                    subtitle: "List directory and count entries", status: .succeeded, exitCode: 0, callID: id,
                    preview: Self.preview(output), output: Self.reference(lines, 15)))
        // The row sits where the call was made, inside its turn.
        #expect(
            Array(transcript.entries.map(\.id.rawValue).suffix(4)) == [
                "grok:5853", "grok:tool:\(id)", "grok:10999", "grok:11607",
            ])
        #expect(transcript.pendingRequests.isEmpty)

        // A command that printed nothing shows no output.
        let quiet = try Self.lines("agent-turns-and-errors.jsonl", 11...16)
        let sleep = "call-01900000-0000-7000-8000-00000000001e-0"
        #expect(
            try Self.tool(Self.transcript(quiet), sleep)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "sleep 5", subtitle: "Wait five seconds",
                    status: .succeeded, exitCode: 0, callID: sleep, output: Self.reference(quiet, 4)))

        // `!echo hi` typed in Grok's shell mode, whose description is the
        // command.
        let shell = try Self.lines("agent-turns-and-errors.jsonl", 22...28)
        let bash = "bash-mode-01900000-0000-7000-8000-000000000022"
        #expect(
            try Self.tool(Self.transcript(shell), bash)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "echo hi", status: .succeeded, exitCode: 0,
                    callID: bash, preview: Self.preview("hi"), output: Self.reference(shell, 6)))

        // Grok completes a command that exits non-zero; the row fails.
        let failing = Self.transcript(
            Self.lines([
                try Self.prompt("Run the tests.", index: 0, event: 1),
                Self.call(name: "run_terminal_command", input: #""command":"make test""#, event: 2),
                Self.result(
                    content: try Self.text("1 failed\n"),
                    rawOutput: #""type":"Bash","output_for_prompt":"exit: 2\n1 failed\n","exit_code":2,"signal":null"#,
                    event: 3),
            ]))
        let failed = try Self.tool(failing, Self.callID)
        #expect(failed.status == .failed)
        #expect(failed.exitCode == 2)
        #expect(failed.preview == Self.preview("1 failed"))
    }

    struct CommandOutput: Sendable, CustomTestStringConvertible {
        let shape: String
        /// The result's content text.
        let content: String
        /// `rawOutput.output_for_prompt`; nil leaves it out.
        let outputForPrompt: String?
        /// What the row shows; nil when it shows no output.
        let preview: String?

        var testDescription: String { shape }
    }

    private static let listing = "-rwxr-xr-x@ 1 developer  wheel  21 Oct 20 19:30 hello.sh"

    private static let commandOutputs: [CommandOutput] = [
        // An approved `chmod +x hello.sh && ls -l hello.sh` as Grok Build
        // 1.0.62 recorded it in a live run, the account renamed.
        CommandOutput(
            shape: "one line", content: listing + "\n", outputForPrompt: "exit: 0\n" + listing + "\n",
            preview: listing),
        CommandOutput(
            shape: "blank lines and indents", content: "\n  first\r\n\n  second\n\n\n",
            outputForPrompt: "exit: 0\n\n  first\r\n\n  second\n\n\n", preview: "\n  first\r\n\n  second"),
        CommandOutput(
            shape: "content without output_for_prompt", content: "  first\n\nsecond\n", outputForPrompt: nil,
            preview: "  first\n\nsecond"),
        CommandOutput(shape: "nothing", content: "", outputForPrompt: "exit: 0\n", preview: nil),
        CommandOutput(shape: "only a line break", content: "\n", outputForPrompt: "exit: 0\n\n", preview: nil),
        CommandOutput(
            shape: "only a line break without output_for_prompt", content: "\r\n", outputForPrompt: nil,
            preview: nil),
        CommandOutput(
            shape: "spaces ending the last line", content: "first\n  \n", outputForPrompt: "exit: 0\nfirst\n  \n",
            preview: "first\n  "),
        CommandOutput(shape: "only spaces", content: "   ", outputForPrompt: "exit: 0\n   ", preview: "   "),
        CommandOutput(shape: "no final line break", content: "done", outputForPrompt: "exit: 0\ndone", preview: "done"),
    ]

    /// A command and its result with `content` as the result's text, and
    /// `outputForPrompt` (nil leaves it out) as its `output_for_prompt`.
    private static func commandLines(content: String, outputForPrompt: String?) throws -> [ChatLine] {
        let forPrompt = try outputForPrompt.map { #""output_for_prompt":\#(try json($0)),"# } ?? ""
        return lines([
            try prompt("Run the shell command: chmod +x hello.sh", index: 0, event: 1),
            call(name: "run_terminal_command", input: #""command":"chmod +x hello.sh && ls -l hello.sh""#, event: 2),
            result(
                content: try text(content), rawOutput: #""type":"Bash",\#(forPrompt)"exit_code":0,"signal":null"#,
                event: 3),
        ])
    }

    /// A command's last line ends with a line break, which the row's box
    /// would show as an empty line.
    @Test(arguments: commandOutputs)
    func commandOutputDropsOnlyItsTrailingLineBreaks(output: CommandOutput) throws {
        let lines = try Self.commandLines(content: output.content, outputForPrompt: output.outputForPrompt)
        let reducer = Self.reducer(lines)

        let tool = try Self.tool(reducer.transcript(ChatProjectionContext(activity: .idle)), Self.callID)

        #expect(tool.status == .succeeded)
        #expect(tool.preview == output.preview.map(Self.preview))
        // Expanded, the row reads the same output again.
        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: lines[2], for: tool)
        }
        #expect(expanded == .preview(output.preview.map(Self.preview)))
    }

    /// A row's cap can fall right after a line break; its box still ends
    /// with the last line it keeps.
    @Test func aCappedCommandOutputEndsWithItsLastLine() throws {
        // 256 bytes a line, so the row's 8 KiB cap falls right after the
        // 32nd line's break.
        let line = String(repeating: "x", count: 255)
        let output = String(repeating: line + "\n", count: 50)
        let lines = try Self.commandLines(content: output, outputForPrompt: "exit: 0\n" + output)
        let reducer = Self.reducer(lines)

        let tool = try Self.tool(reducer.transcript(ChatProjectionContext(activity: .idle)), Self.callID)

        let kept = Array(repeating: line, count: 32).joined(separator: "\n")
        #expect(tool.preview == ChatToolPreview(text: kept, isTruncated: true))
        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: lines[2], for: tool)
        }
        #expect(expanded == .preview(Self.preview(Array(repeating: line, count: 50).joined(separator: "\n"))))
    }

    /// What ripgrep exits with when a search finds nothing: 1 when nothing
    /// matched, 2 when it reported an error, -1 when it never finished.
    @Test(arguments: [1, 2, -1])
    func searchesSucceedWhateverRipgrepExitsWith(exitCode: Int) throws {
        // Grok completes every search and keeps ripgrep's exit code.
        let transcript = Self.transcript(
            Self.lines([
                try Self.prompt("Find the TODOs.", index: 0, event: 1),
                Self.call(name: "grep", kind: "search", input: #""pattern":"TODO","path":"src""#, event: 2),
                Self.result(
                    content: try Self.text("found 0 matches"),
                    rawOutput:
                        #""type":"GrepSearch","stdout":[],"stderr":[],"exit_code":\#(exitCode),"match_count":0,"file_matches":[]"#,
                    event: 3),
            ]))

        let tool = try Self.tool(transcript, Self.callID)
        #expect(tool.kind == .search)
        #expect(tool.status == .succeeded)
        #expect(tool.exitCode == nil)
        #expect(tool.preview == Self.preview("found 0 matches"))
    }

    struct Failure: Sendable, CustomTestStringConvertible {
        let variant: String
        /// The call's line in `failed-tools.jsonl`; its result follows.
        let line: Int
        let kind: ChatToolActivity.Kind
        let title: String
        let preview: String

        var testDescription: String { variant }
    }

    private static let failures: [Failure] = [
        Failure(
            variant: "tool_execution_failed", line: 2, kind: .search, title: "fn main(",
            preview: "regex parse error: unclosed group"),
        Failure(
            variant: "FileNotFound", line: 4, kind: .fileRead, title: "missing.txt",
            preview: "File not found: /Users/developer/scratch/cap-grok-a/proj/missing.txt"),
        Failure(variant: "FileTooLarge", line: 6, kind: .fileRead, title: "data/dump.json", preview: "File too large"),
        Failure(variant: "NotADirectory", line: 8, kind: .listing, title: "README.md", preview: "Not a directory"),
        Failure(variant: "NotFound", line: 10, kind: .listing, title: "build", preview: "NotFound"),
        Failure(
            variant: "NoMatchesFound", line: 12, kind: .fileEdit, title: "README.md",
            preview: "No matches found for old_string in README.md."),
        Failure(
            variant: "MultipleMatchesFound", line: 14, kind: .fileEdit, title: "README.md", preview: "Multiple matches"),
        Failure(variant: "InvalidInput", line: 16, kind: .fileEdit, title: "README.md", preview: "Invalid input"),
        Failure(variant: "MCP", line: 18, kind: .mcp, title: "github.get_issue", preview: "Issue 7 not found."),
    ]

    @Test(arguments: failures)
    func failedCallsPreviewTheirError(variant: Failure) throws {
        let lines = try Self.lines("failed-tools.jsonl", variant.line...(variant.line + 1))

        let tools = Self.tools(Self.transcript(lines))

        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.kind == variant.kind)
        #expect(tool.title == variant.title)
        #expect(tool.status == .failed)
        #expect(tool.preview == Self.preview(variant.preview))
        #expect(tool.fileChanges == nil)
        #expect(tool.output == Self.reference(lines, 2))
    }

    // MARK: File changes

    @Test func editsShowTheResultsDiff() throws {
        let lines = try Self.lines("reject-and-edit.jsonl", 14...20)

        let transcript = Self.transcript(lines)

        let id = "call-01900000-0000-7000-8000-00000000002f-10"
        let path = "/Users/developer/scratch/cap-grok-a/proj/notes.txt"
        let hunk = ChatDiffHunk(
            oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" alpha", "-beta", "+BETA", " gamma"])
        let changes = ChatFileChanges(
            files: [ChatFileChange(path: path, kind: .updated, recorded: [hunk])], directory: Self.directoryA)
        let tool = try Self.tool(transcript, id)
        #expect(
            tool
                == ChatToolActivity(
                    kind: .fileEdit, name: "search_replace", title: "notes.txt", status: .succeeded,
                    diff: ChatDiffStats(added: 1, removed: 1), fileChanges: changes, callID: id,
                    output: Self.reference(lines, 5)))
        #expect(changes.displayPath(of: try #require(changes.files.first)) == "notes.txt")
        #expect(tool.showsDiffAsOutput)

        // A result whose content holds no diff reads the edit Grok applied.
        var result = try #require(
            try JSONSerialization.jsonObject(with: lines[4].data) as? [String: Any])
        var params = try #require(result["params"] as? [String: Any])
        var update = try #require(params["update"] as? [String: Any])
        update["content"] = nil
        params["update"] = update
        result["params"] = params
        let bare = ChatLine(offset: lines[4].offset, data: try JSONSerialization.data(withJSONObject: result))
        let applied = Self.transcript(Array(lines[0..<4]) + [bare])
        #expect(try Self.tool(applied, id).fileChanges == changes)
    }

    @Test func fallsBackToTheInputPreviewDiff() throws {
        // The input update's preview, while the edit runs.
        let lines = try Self.lines("reject-and-edit.jsonl", 14...17)

        let transcript = Self.transcript(lines, activity: .working)

        let id = "call-01900000-0000-7000-8000-00000000002f-10"
        let hunk = ChatDiffHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ["-beta", "+BETA"])
        #expect(
            try Self.tool(transcript, id)
                == ChatToolActivity(
                    kind: .fileEdit, name: "search_replace", title: "notes.txt", status: .running,
                    diff: ChatDiffStats(added: 1, removed: 1),
                    fileChanges: ChatFileChanges(
                        files: [
                            ChatFileChange(
                                path: "/Users/developer/scratch/cap-grok-a/proj/notes.txt", kind: .updated,
                                recorded: [hunk])
                        ], directory: Self.directoryA), callID: id))
    }

    @Test func writesOfNewFilesShowAsCreated() throws {
        // `search_replace` with an empty old string creates the file.
        let edit = try Self.lines("reject-and-edit.jsonl", 7...13)
        let created = "call-01900000-0000-7000-8000-00000000002e-9"
        #expect(
            try Self.tool(Self.transcript(edit), created)
                == ChatToolActivity(
                    kind: .fileEdit, name: "search_replace", title: "notes.txt", status: .succeeded,
                    diff: ChatDiffStats(added: 3, removed: 0),
                    fileChanges: ChatFileChanges(
                        files: [
                            ChatFileChange(
                                path: "/Users/developer/scratch/cap-grok-a/proj/notes.txt", kind: .created,
                                recorded: [
                                    ChatDiffHunk(
                                        oldStart: 0, oldLines: 0, newStart: 1, newLines: 3,
                                        lines: ["+alpha", "+beta", "+gamma"])
                                ])
                        ], directory: Self.directoryA), callID: created, output: Self.reference(edit, 5)))

        let write = try Self.lines("subagent-todo-question.jsonl", 25...30)
        let written = "call-01900000-0000-7000-8000-000000000039-3"
        #expect(
            try Self.tool(Self.transcript(write, path: Self.pathB), written)
                == ChatToolActivity(
                    kind: .fileWrite, name: "write", title: "note.txt", status: .succeeded,
                    diff: ChatDiffStats(added: 1, removed: 0),
                    fileChanges: ChatFileChanges(
                        files: [
                            ChatFileChange(
                                path: "/Users/developer/scratch/cap-grok-b/proj/note.txt", kind: .created,
                                recorded: [
                                    ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+hi"])
                                ])
                        ], directory: Self.directoryB), callID: written, output: Self.reference(write, 5)))

        // A write over a file that held text replaces it.
        let path = "/Users/developer/scratch/cap-grok-a/proj/notes.txt"
        let overwrite = Self.transcript(
            Self.lines([
                try Self.prompt("Rewrite notes.txt.", index: 0, event: 1),
                Self.call(
                    name: "write", kind: "write", input: #""file_path":"\#(path)","content":"new\n""#, event: 2),
                Self.result(
                    content: #"{"type":"diff","path":"\#(path)","oldText":"old\n","newText":"new\n"}"#,
                    rawOutput: #""type":"SearchReplace""#, event: 3),
            ]))
        let file = try #require(try Self.tool(overwrite, Self.callID).fileChanges?.files.first)
        #expect(file.kind == .written)
        #expect(file.hunks == [ChatDiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-old", "+new"])])
    }

    @Test func aWriteShowsOnlyWhatItsResultChanged() throws {
        // Grok's preview of a write never records the file's old text, so
        // until the result a new file reads as written, as one the write
        // replaces would.
        let write = try Self.lines("subagent-todo-question.jsonl", 25...30)
        let id = "call-01900000-0000-7000-8000-000000000039-3"
        let running = Self.transcript(Array(write[0..<4]), path: Self.pathB, activity: .working)
        #expect(
            try Self.tool(running, id).fileChanges
                == ChatFileChanges(
                    files: [
                        ChatFileChange(
                            path: "/Users/developer/scratch/cap-grok-b/proj/note.txt", kind: .written,
                            recorded: [
                                ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+hi"])
                            ])
                    ], directory: Self.directoryB))
        #expect(try Self.tool(Self.transcript(write, path: Self.pathB), id).fileChanges?.files.map(\.kind) == [.created])

        // A write of the text the file already held changed nothing: no
        // diff shows, not even the preview's.
        let path = "/Users/developer/scratch/cap-grok-a/proj/notes.txt"
        let detail =
            #"{"old_string":"same\n","old_line":1,"new_string":"same\n","new_line":1,"context_before":"","context_after":"","line_prefix":""}"#
        let same = Self.lines([
            try Self.prompt("Write notes.txt again.", index: 0, event: 1),
            Self.call(name: "write", kind: "write", input: #""file_path":"\#(path)","content":"same\n""#, event: 2),
            Self.record(
                #""sessionUpdate":"tool_call_update","toolCallId":"\#(Self.callID)","kind":"edit","title":"Write `\#(path)`","content":[{"type":"diff","path":"\#(path)","oldText":"","newText":"same\n"}],"locations":[],"rawInput":{"variant":"Write","file_path":"\#(path)","content":"same\n"}"#,
                event: 3),
            Self.result(
                content: #"{"type":"diff","path":"\#(path)","oldText":"same\n","newText":"same\n","_meta":{"details":[\#(detail)]}}"#,
                rawOutput:
                    #""type":"SearchReplace","EditsApplied":{"absolute_path":"\#(path)","old_string":"same\n","new_string":"same\n","edits":{"details":[\#(detail)]},"tool_output_for_prompt":"Wrote file successfully to \#(path)."}"#,
                event: 4),
            Self.completed("end_turn", event: 5),
        ])
        let reducer = Self.reducer(same)
        let tool = try Self.tool(reducer.transcript(ChatProjectionContext(activity: .idle)), Self.callID)
        #expect(
            tool
                == ChatToolActivity(
                    kind: .fileWrite, name: "write", title: "notes.txt", status: .succeeded, callID: Self.callID,
                    output: Self.reference(same, 4)))
        #expect(reducer.output(of: same[3], for: tool) == .preview(nil))
    }

    // MARK: Images

    /// A read as Grok writes it: the path in the call and its input update,
    /// what it read only in the result (seen in a session from 2026-08-27).
    private static func read(_ target: String, location: String?, content: String, rawOutput: String) throws
        -> [ChatLine]
    {
        let locations = location.map { #","locations":[{"path":"\#($0)"}]"# } ?? ""
        return Self.lines([
            try Self.prompt("Look at the screenshot", index: 0, event: 1),
            Self.call(name: "read_file", kind: "read", input: #""target_file":"\#(target)""#, event: 2),
            Self.record(
                #""sessionUpdate":"tool_call_update","toolCallId":"\#(Self.callID)","kind":"read","title":"Read `\#(target)`"\#(locations),"rawInput":{"variant":"ReadFile","target_file":"\#(target)"}"#,
                event: 3),
            Self.result(content: content, rawOutput: rawOutput, event: 4),
            Self.completed("end_turn", event: 5),
        ])
    }

    @Test func imageReadsRecordTheFileTheyShowed() throws {
        let image = #"{"type":"content","content":{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}}"#
        let raw = #""type":"ReadFile","ImageContent":{"data":"iVBORw0KGgo=","mime_type":"image/png"}"#

        let shown = Self.transcript(
            try Self.read("/tmp/shot.png", location: "/tmp/shot.png", content: image, rawOutput: raw))
        #expect(try Self.tool(shown, Self.callID).imagePath == "/tmp/shot.png")

        // A relative path reads in the session's directory.
        let relative = Self.transcript(try Self.read("shots/a.png", location: nil, content: image, rawOutput: raw))
        #expect(try Self.tool(relative, Self.callID).imagePath == Self.directoryA + "/shots/a.png")

        // A read that showed text has no image, whatever the file's name.
        let text = Self.transcript(
            try Self.read(
                "/tmp/notes.png", location: "/tmp/notes.png", content: try Self.text("1→hello"),
                rawOutput: #""type":"ReadFile","FileContent":{"content":"1→hello"}"#))
        #expect(try Self.tool(text, Self.callID).imagePath == nil)
    }

    // MARK: Outcomes

    @Test func aRejectedCallIsDeclinedAndEndsTheTurn() throws {
        let transcript = try Self.fixture("reject-and-edit.jsonl", lines: 1...6)

        let id = "call-01900000-0000-7000-8000-00000000002d-8"
        let tool = try Self.tool(transcript, id)
        #expect(
            tool
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command",
                    title: #"chmod 600 README.md; echo "EXIT_CODE:$?"; ls -l README.md"#,
                    subtitle: "Set README.md to mode 600 and show result", status: .declined,
                    note: "Rejecting ended the turn", callID: id))
        #expect(!tool.ran)
        #expect(transcript.turns.map(\.ending) == [.interrupted])
        // The declined row says why the turn ended; no notice repeats it.
        #expect(Self.notices(transcript).isEmpty)

        // Until the turn ends, the row says only that it was declined.
        let open = try Self.fixture("reject-and-edit.jsonl", lines: 1...5, activity: .working)
        #expect(try Self.tool(open, id).status == .declined)
        #expect(try Self.tool(open, id).note == nil)
    }

    private static let turnEndings: [(String?, ChatToolActivity.Status)] = [
        ("end_turn", .noResult), ("cancelled", .interrupted), ("error", .notCompleted), (nil, .notCompleted),
    ]

    /// `stopReason` nil: the next prompt opened a turn instead.
    @Test(arguments: turnEndings)
    func openCallsFollowTheTurnsEnding(stopReason: String?, status: ChatToolActivity.Status) throws {
        var rows = [
            try Self.prompt("Run it.", index: 0, event: 1),
            Self.call(name: "run_terminal_command", input: #""command":"make""#, event: 2),
        ]
        rows.append(try stopReason.map { Self.completed($0, event: 3) } ?? Self.prompt("Next.", index: 1, event: 3))

        let transcript = Self.transcript(Self.lines(rows), activity: .working)

        #expect(try Self.tool(transcript, Self.callID).status == status)
        #expect(transcript.pendingRequests.isEmpty)
    }

    private static let activities: [(ChatAgentActivity, ChatToolActivity.Status)] = [
        (.blocked, .awaitingApproval), (.working, .running), (.unknown, .running), (.idle, .notCompleted),
    ]

    @Test(arguments: activities)
    func openCallsInTheOpenTurnFollowActivity(activity: ChatAgentActivity, status: ChatToolActivity.Status) throws {
        let lines = Self.lines([
            try Self.prompt("Run it.", index: 0, event: 1),
            Self.call(name: "run_terminal_command", input: #""command":"make""#, event: 2),
        ])

        let transcript = Self.transcript(lines, activity: activity)

        #expect(try Self.tool(transcript, Self.callID).status == status)
        #expect(transcript.turns.map(\.ending) == [nil])
    }

    @Test func whileBlockedTheBareCallIsAPendingRequest() throws {
        // Grok waits for permission: only the call is on disk.
        let transcript = try Self.fixture("pending-permission.jsonl", activity: .blocked)

        let id = "call-01900000-0000-7000-8000-000000000031-7"
        #expect(
            transcript.pendingRequests == [
                ChatPendingRequest(
                    entryID: ChatEntryID("grok:tool:\(id)"), callID: id, kind: .command,
                    toolName: "run_terminal_command", summary: "chmod 644 README.md",
                    detail: "Set README.md permissions to 644")
            ])
        #expect(try Self.tool(transcript, id).status == .awaitingApproval)

        let working = try Self.fixture("pending-permission.jsonl", activity: .working)
        #expect(working.pendingRequests.isEmpty)
        #expect(try Self.tool(working, id).status == .running)

        // Once Grok writes the input update, the call runs, whatever else
        // the Agent waits on.
        let running = try Self.fixture("reject-and-edit.jsonl", lines: 1...4, activity: .blocked)
        #expect(running.pendingRequests.isEmpty)
        #expect(try Self.tool(running, "call-01900000-0000-7000-8000-00000000002d-8").status == .running)

        // A question waits the same way, with its questions.
        let asked = try Self.fixture("subagent-todo-question.jsonl", lines: 18...20, path: Self.pathB, activity: .blocked)
        let question = "call-01900000-0000-7000-8000-000000000038-2"
        #expect(
            asked.pendingRequests == [
                ChatPendingRequest(
                    entryID: ChatEntryID("grok:tool:\(question)"), callID: question, kind: .question,
                    toolName: "ask_user_question", summary: "How should we handle the README rename plan?",
                    questions: [Self.renameQuestion(answer: nil)])
            ])
    }

    private static func renameQuestion(answer: String?) -> ChatQuestion {
        ChatQuestion(
            text: "How should we handle the README rename plan?",
            options: [
                ChatQuestion.Option(
                    label: "Keep it as a todo (Recommended)",
                    detail: "Leave the three-step plan in the todos and change no files."),
                ChatQuestion.Option(
                    label: "Rename it now", detail: "Start the rename with the three steps in the todos."),
            ], answer: answer)
    }

    @Test func questionCallsCarryTheirQuestionsAndAnswers() throws {
        let lines = try Self.lines("subagent-todo-question.jsonl", 18...24)

        let transcript = Self.transcript(lines, path: Self.pathB)

        let id = "call-01900000-0000-7000-8000-000000000038-2"
        // The answers show in the questions, and the result holds nothing
        // more, so an expanded row has no output to read.
        #expect(
            try Self.tool(transcript, id)
                == ChatToolActivity(
                    kind: .question, name: "ask_user_question", title: "How should we handle the README rename plan?",
                    status: .succeeded, questions: [Self.renameQuestion(answer: "Keep it as a todo (Recommended)")],
                    callID: id))

        // A question nobody answered completes, and the turn goes on.
        let declined = "User declined to answer the questions. Continue with the task using your best judgment."
        let declinedResult = Self.result(
            id, content: try Self.text(declined), rawOutput: #""type":"AskUserQuestion""#, event: 90)
        let skipped = Self.transcript(
            Array(lines[0..<4]) + [ChatLine(offset: lines[3].end, data: Data(declinedResult.utf8))], path: Self.pathB)
        let unanswered = try Self.tool(skipped, id)
        #expect(unanswered.status == .succeeded)
        #expect(unanswered.note == "Not answered")
        #expect(unanswered.questions == [Self.renameQuestion(answer: nil)])

        // Each answer by its question; a selected preview or the user's
        // notes after an answer stay out of it.
        let answers =
            "User has answered your questions: \"Which file?\"=\"README.md\" selected preview:\n# Title user notes: keep it short, \"Why?\"=\"It is, \"old\"\". You can now continue with the user's answers in mind."
        let two = Self.transcript(
            Self.lines([
                try Self.prompt("Ask me two things.", index: 0, event: 1),
                Self.call(
                    name: "ask_user_question", kind: "ask_user",
                    input:
                        #""questions":[{"question":"Which file?","options":[{"label":"README.md"}]},{"question":"Why?","options":[{"label":"It is old"}]}]"#,
                    event: 2),
                Self.result(
                    content: try Self.text(answers),
                    rawOutput: #""type":"AskUserQuestion","UserAnswered":{"message":\#(try Self.json(answers))}"#,
                    event: 3),
            ]))
        #expect(try Self.tool(two, Self.callID).questions.map(\.answer) == ["README.md", #"It is, "old""#])
        #expect(try Self.tool(two, Self.callID).title == "Which file? · Why?")
    }

    @Test func todoWritesAreUpdateTodosRows() throws {
        let lines = try Self.lines("subagent-todo-question.jsonl", 10...17)

        let transcript = Self.transcript(lines, path: Self.pathB)

        let id = "call-01900000-0000-7000-8000-000000000037-1"
        let todos = """
            [ ] Confirm README.md exists and find every reference to it
            [ ] Rename README.md with git mv, keeping history
            [ ] Update references and verify the new name and links
            """
        #expect(
            try Self.tool(transcript, id)
                == ChatToolActivity(
                    kind: .todo, name: "todo_write", title: "Update todos", status: .succeeded, callID: id,
                    preview: Self.preview(todos), output: Self.reference(lines, 5)))
        // The `plan` snapshot after it shows nothing of its own.
        #expect(Self.tools(transcript).count == 1)
        #expect(transcript.entries.count == 4)

        // Before the result, the call's own list shows.
        let running = Self.transcript(Array(lines[0..<4]), path: Self.pathB, activity: .working)
        #expect(try Self.tool(running, id).preview == Self.preview(todos))
    }

    // MARK: Subagents and background work

    @Test func subagentsShowTheirDescriptionTypeAndOutcome() throws {
        let lines = try Self.lines("subagent-todo-question.jsonl", 1...9)

        let transcript = Self.transcript(lines, path: Self.pathB)

        let id = "call-01900000-0000-7000-8000-000000000036-0"
        let report =
            "工作区根目录 `/Users/developer/scratch/cap-grok-b/proj` 很小。`list_dir` 只显示非隐藏条目；完整列表（含隐藏项）如下：\n\n- `README.md`：文件。项目说明。\n- `.git`：目录。Git 仓库元数据（`list_dir` 会略过点文件，因此未列出）。"
        #expect(
            try Self.tool(transcript, id)
                == ChatToolActivity(
                    kind: .agent, name: "spawn_subagent", title: "List workspace files", subtitle: "general-purpose",
                    status: .succeeded, note: "2 tool calls · 1 turn · 7s", callID: id,
                    preview: Self.preview(report), output: Self.reference(lines, 5)))
        // The Background Work strip stays Claude's.
        #expect(transcript.backgroundWork.isEmpty)
        #expect(transcript.backgroundWorkEnds.isEmpty)

        #expect(GrokToolCall.duration(999) == "0s")
        #expect(GrokToolCall.duration(38_900) == "38s")
        #expect(GrokToolCall.duration(120_000) == "2m")
        #expect(GrokToolCall.duration(138_000) == "2m 18s")
        #expect(GrokToolCall.duration(3_900_000) == "1h 5m")
    }

    @Test func aCancelledSubagentFinishesAfterItsParentTurn() throws {
        // Ctrl+C during the subagent: the parent's turn ends first, and the
        // spawn gets no result.
        let cancelled = try Self.fixture("cancel-takeover.jsonl", lines: 7...13)

        let id = "call-01900000-0000-7000-8000-00000000000f-0"
        let expected = ChatToolActivity(
            kind: .agent, name: "spawn_subagent", title: "Sleep 20 then report done", subtitle: "general-purpose",
            status: .interrupted, callID: id)
        #expect(try Self.tool(cancelled, id) == expected)

        let finished = try Self.fixture("cancel-takeover.jsonl", lines: 7...14)
        var withNote = expected
        withNote.note = "Subagent was cancelled"
        #expect(try Self.tool(finished, id) == withNote)
    }

    /// The subagent the spawns below describe, and the spawn that starts it
    /// after an earlier one did not.
    private static let subagent = "01900000-0000-7000-8000-000000000011"
    private static let laterSpawn = "call-01900000-0000-7000-8000-000000000011-1"

    private static func spawn(_ id: String, type: String?, background: Bool, event: Int) -> String {
        let type = type.map { #","subagent_type":"\#($0)""# } ?? ""
        return call(
            id, name: "spawn_subagent", kind: "task",
            input: #""description":"Audit dependencies","prompt":"List outdated dependencies."\#(type),"background":\#(background)"#,
            event: event)
    }

    private static func spawned(event: Int) -> String {
        record(
            #""sessionUpdate":"subagent_spawned","subagent_id":"\#(subagent)","subagent_type":"explore","description":"Audit dependencies""#,
            event: event, method: "_x.ai/session/update")
    }

    private static func subagentFinished(event: Int) -> String {
        record(
            #""sessionUpdate":"subagent_finished","subagent_id":"\#(subagent)","status":"completed","tool_calls":3,"turns":2,"duration_ms":37450,"output":"No dependency is outdated.""#,
            event: event, method: "_x.ai/session/update")
    }

    @Test func aSubagentStartsFromAnOpenSpawnOfItsTurn() throws {
        // A spawn with the subagent's description that failed, or that an
        // earlier turn left without a result, did not start it.
        var earlier = ChatToolActivity(
            kind: .agent, name: "spawn_subagent", title: "Audit dependencies", subtitle: "auditor", status: .failed,
            callID: Self.callID, preview: Self.preview("unknown subagent type"))
        var later = ChatToolActivity(
            kind: .agent, name: "spawn_subagent", title: "Audit dependencies", subtitle: "explore", status: .succeeded,
            note: "3 tool calls · 2 turns · 37s", callID: Self.laterSpawn,
            preview: Self.preview("No dependency is outdated."))
        let failure = Self.result(
            status: "failed", content: try Self.text("Tool `spawn_subagent` failed: unknown subagent type"),
            rawOutput: #""error":"tool_execution_failed","message":"unknown subagent type""#, event: 3)

        // Retried in the same turn.
        let retried = Self.lines([
            try Self.prompt("Audit the dependencies with a subagent.", index: 0, event: 1),
            Self.spawn(Self.callID, type: "auditor", background: false, event: 2),
            failure,
            Self.spawn(Self.laterSpawn, type: "explore", background: false, event: 4),
            Self.spawned(event: 5),
            Self.subagentFinished(event: 6),
            Self.result(
                Self.laterSpawn, content: try Self.text("No dependency is outdated."),
                rawOutput:
                    #""type":"SubagentCompleted","output":"No dependency is outdated.","subagent_id":"\#(Self.subagent)","subagent_type":"explore","tool_calls":3,"turns":2,"duration_ms":37450"#,
                event: 7),
            Self.completed("end_turn", event: 8),
        ])
        var transcript = Self.transcript(retried)
        earlier.output = Self.reference(retried, 3)
        later.output = Self.reference(retried, 6)
        #expect(try Self.tool(transcript, Self.callID) == earlier)
        #expect(try Self.tool(transcript, Self.laterSpawn) == later)

        // Run in the background in the next turn, after the failure.
        let afterFailure = try Self.backgroundSpawn(after: [failure, Self.completed("end_turn", event: 4)])
        transcript = Self.transcript(afterFailure)
        earlier.output = Self.reference(afterFailure, 3)
        later.output = Self.reference(afterFailure, afterFailure.count)
        #expect(try Self.tool(transcript, Self.callID) == earlier)
        #expect(try Self.tool(transcript, Self.laterSpawn) == later)

        // Or after a turn cancelled before the spawn had a result.
        let afterCancel = try Self.backgroundSpawn(after: [Self.completed("cancelled", event: 3)])
        transcript = Self.transcript(afterCancel)
        later.output = Self.reference(afterCancel, afterCancel.count)
        #expect(
            try Self.tool(transcript, Self.callID)
                == ChatToolActivity(
                    kind: .agent, name: "spawn_subagent", title: "Audit dependencies", subtitle: "auditor",
                    status: .interrupted, callID: Self.callID))
        #expect(try Self.tool(transcript, Self.laterSpawn) == later)
    }

    /// A turn whose spawn ends with `end`, then a turn whose spawn starts
    /// the subagent in the background, which finishes after the turn.
    private static func backgroundSpawn(after end: [String]) throws -> [ChatLine] {
        let event = 3 + end.count
        var rows: [String] = [
            try prompt("Audit the dependencies with a subagent.", index: 0, event: 1),
            spawn(callID, type: "auditor", background: false, event: 2),
        ]
        rows += end
        rows += [
            try prompt("Run it in the background instead.", index: 1, event: event),
            spawn(laterSpawn, type: nil, background: true, event: event + 1),
            spawned(event: event + 2),
            result(
                laterSpawn, content: try text("Subagent started in background."),
                rawOutput: #""type":"Text","text":"Subagent started in background.""#, event: event + 3),
            completed("end_turn", event: event + 4),
            subagentFinished(event: event + 5),
        ]
        return lines(rows)
    }

    /// Two parallel spawns wait for approval one card at a time. Grok
    /// writes `subagent_spawned` as an approved spawn starts and holds its
    /// input update back, so while the Agent is Blocked on the second
    /// card, the first runs and only the second waits.
    @Test func aSpawnWhoseSubagentStartedRunsWhileTheNextWaits() throws {
        let second = "call-01900000-0000-7000-8000-000000000011-2"
        let calls = [
            try Self.prompt("Audit the dependencies with two subagents.", index: 0, event: 1),
            Self.spawn(Self.callID, type: "explore", background: false, event: 2),
            Self.spawn(second, type: "explore", background: false, event: 3),
        ]

        let waiting = Self.transcript(Self.lines(calls), activity: .blocked)
        #expect(waiting.pendingRequests.map(\.callID) == [Self.callID, second])

        let started = Self.transcript(Self.lines(calls + [Self.spawned(event: 4)]), activity: .blocked)
        #expect(try Self.tool(started, Self.callID).status == .running)
        #expect(try Self.tool(started, second).status == .awaitingApproval)
        #expect(started.pendingRequests.map(\.callID) == [second])
    }

    @Test func backgroundedCommandsSayTheyWentToTheBackground() throws {
        let lines = try Self.lines("background-tasks.jsonl")
        let server = "call-01900000-0000-7000-8000-00000000003e-0"
        let tests = "call-01900000-0000-7000-8000-000000000040-1"
        let audit = "call-01900000-0000-7000-8000-000000000042-2"

        let started = Self.transcript(Array(lines[0..<21]))
        #expect(
            try Self.tool(started, server)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "npm run dev",
                    subtitle: "Start the dev server", status: .started, note: "Sent to the background",
                    callID: server, output: Self.reference(lines, 5)))
        #expect(
            try Self.tool(started, tests)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "make test", subtitle: "Run the test suite",
                    status: .started, note: "Sent to the background", callID: tests,
                    output: Self.reference(lines, 12)))
        #expect(
            try Self.tool(started, audit)
                == ChatToolActivity(
                    kind: .agent, name: "spawn_subagent", title: "Audit dependencies", subtitle: "explore",
                    status: .started, note: "Sent to the background", callID: audit,
                    output: Self.reference(lines, 19)))
        #expect(Self.notices(started).isEmpty)

        let tested = Self.transcript(Array(lines[0..<22]))
        #expect(
            try Self.tool(tested, tests)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "make test", subtitle: "Run the test suite",
                    status: .succeeded, note: "Finished in the background", exitCode: 0, callID: tests,
                    preview: Self.preview("Running 42 tests\n42 passed"), output: Self.reference(lines, 22)))
        #expect(
            Self.notices(tested).map(\.id.rawValue) == ["grok:15752:notice"])
        #expect(
            Self.notices(tested).first?.content
                == .notice(
                    ChatNotice(
                        kind: .taskNotification, title: "Background command finished",
                        detail: "make test · Exit code 0")))

        let audited = Self.transcript(Array(lines[0..<26]))
        #expect(
            try Self.tool(audited, audit)
                == ChatToolActivity(
                    kind: .agent, name: "spawn_subagent", title: "Audit dependencies", subtitle: "explore",
                    status: .succeeded, note: "3 tool calls · 2 turns · 37s", callID: audit,
                    preview: Self.preview("No dependency is outdated."), output: Self.reference(lines, 26)))

        let all = Self.transcript(Array(lines[0..<27]))
        #expect(
            try Self.tool(all, server)
                == ChatToolActivity(
                    kind: .command, name: "run_terminal_command", title: "npm run dev",
                    subtitle: "Start the dev server", status: .interrupted, note: "Stopped in the background",
                    callID: server, preview: Self.preview("ready on http://localhost:3000"),
                    output: Self.reference(lines, 27)))
        #expect(
            Self.notices(all).last
                == ChatEntry(
                    id: ChatEntryID("grok:18793:notice"), sourceOffset: 18793,
                    content: .notice(
                        ChatNotice(
                            kind: .taskNotification, title: "Background command finished",
                            detail: "npm run dev · Killed"))))
        #expect(all.backgroundWork.isEmpty)
    }

    @Test func monitorsShowTheirOutputOnceTheyEnd() throws {
        let lines = try Self.lines("background-tasks.jsonl")
        let monitor = "call-01900000-0000-7000-8000-000000000051-3"
        let title = "Start monitor: Wait for the build to finish"

        // The result names the monitor's task and holds no output.
        let watching = Self.transcript(Array(lines[27..<34]))
        #expect(
            try Self.tool(watching, monitor)
                == ChatToolActivity(
                    kind: .other, name: "monitor", title: title, status: .started, note: "Sent to the background",
                    callID: monitor, output: Self.reference(lines, 32)))

        // Its output comes with its task's end.
        let ended = Array(lines[27..<35])
        let reducer = Self.reducer(ended)
        let tool = try Self.tool(
            reducer.transcript(ChatProjectionContext(windowStart: ended[0].offset, activity: .idle)), monitor)
        #expect(
            tool
                == ChatToolActivity(
                    kind: .other, name: "monitor", title: title, status: .succeeded,
                    note: "Finished in the background", exitCode: 0, callID: monitor,
                    preview: Self.preview("BUILD SUCCEEDED"), output: Self.reference(lines, 35)))
        #expect(
            Self.notices(Self.transcript(ended)).last?.content
                == .notice(
                    ChatNotice(
                        kind: .taskNotification, title: "Background task finished",
                        detail: "[monitor] Wait for the build to finish · Exit code 0")))

        // Expanded, the row reads the task's end again.
        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: lines[34], for: tool)
        }
        #expect(expanded == .preview(Self.preview("BUILD SUCCEEDED")))
    }

    struct TaskAction: Sendable, CustomTestStringConvertible {
        let shape: String
        let name: String
        /// Grok's kind for the tool.
        let kind: String
        let input: String
        let failed: Bool
        let rawOutput: String
        let preview: String

        var testDescription: String { shape }
    }

    /// The background tasks the calls below name, and one Grok can't find.
    private static let backgroundTask = "call-01900000-0000-7000-8000-000000000011-5"
    private static let lintTask = "call-01900000-0000-7000-8000-000000000011-6"
    private static let missingTask = "call-01900000-0000-7000-8000-000000000011-9"

    /// `rawOutput` bodies of the shapes the census found, which hold no
    /// content: a read of one task, of several, of a task that isn't there,
    /// and a kill.
    private static let taskActions: [TaskAction] = [
        TaskAction(
            shape: "TaskOutput.Result", name: "get_command_or_subagent_output", kind: "background_task_action",
            input: #""task_ids":["\#(backgroundTask)"],"timeout_ms":30000"#, failed: false,
            rawOutput:
                #""type":"TaskOutput","Result":{"task_id":"\#(backgroundTask)","command":"make test","status":"completed","exit_code":0,"started":"2026-10-19T11:20:21Z","ended":"2026-10-19T11:21:20Z","duration_secs":59.25,"output":"Running 42 tests\n42 passed\n","output_file":"","truncated":false,"truncation_hint":"","raw_output_bytes":27}"#,
            preview: "Running 42 tests\n42 passed"),
        TaskAction(
            shape: "TaskOutput.MultiResult", name: "get_command_or_subagent_output", kind: "background_task_action",
            input: #""task_ids":["\#(backgroundTask)","\#(lintTask)"],"timeout_ms":30000"#, failed: false,
            rawOutput:
                #""type":"TaskOutput","MultiResult":{"mode":"wait_all","results":[{"task_id":"\#(backgroundTask)","command":"make test","status":"completed","exit_code":0,"started":"2026-10-19T11:20:21Z","ended":"2026-10-19T11:21:20Z","duration_secs":59.25,"output":"42 passed\n","output_file":"","truncated":false,"truncation_hint":"","raw_output_bytes":10},{"task_id":"\#(lintTask)","command":"npm run lint","status":"completed","exit_code":0,"started":"2026-10-19T11:20:22Z","ended":"2026-10-19T11:20:30Z","duration_secs":8.0,"output":"No lint errors.\n","output_file":"","truncated":false,"truncation_hint":"","raw_output_bytes":16}],"summary":"2/2 tasks completed (wait_all)"}"#,
            preview: "42 passed\n\nNo lint errors."),
        TaskAction(
            shape: "TaskOutput.MultiResult without output", name: "get_command_or_subagent_output",
            kind: "background_task_action", input: #""task_ids":["\#(backgroundTask)"]"#, failed: false,
            rawOutput:
                #""type":"TaskOutput","MultiResult":{"mode":"poll","results":[{"task_id":"\#(backgroundTask)","command":"make test","status":"running","exit_code":null,"started":"2026-10-19T11:20:21Z","ended":null,"duration_secs":3.5,"output":"","output_file":"","truncated":false,"truncation_hint":"","raw_output_bytes":0}],"summary":"0/1 tasks completed (poll)"}"#,
            preview: "0/1 tasks completed (poll)"),
        TaskAction(
            shape: "TaskOutput.TaskNotFound", name: "get_command_or_subagent_output", kind: "background_task_action",
            input: #""task_ids":["\#(missingTask)"]"#, failed: true,
            rawOutput:
                #""type":"TaskOutput","TaskNotFound":"Task \#(missingTask) not found. Known task IDs: [\#(backgroundTask)]""#,
            preview: "Task \(missingTask) not found. Known task IDs: [\(backgroundTask)]"),
        TaskAction(
            shape: "KillTask.Result", name: "kill_command_or_subagent", kind: "kill_task_action",
            input: #""task_id":"\#(backgroundTask)""#, failed: false,
            rawOutput:
                #""type":"KillTask","Result":{"task_id":"\#(backgroundTask)","outcome":"killed","message":"Task was terminated successfully"}"#,
            preview: "Task was terminated successfully"),
        TaskAction(
            shape: "KillTask.TaskNotFound", name: "kill_command_or_subagent", kind: "kill_task_action",
            input: #""task_id":"\#(missingTask)""#, failed: true,
            rawOutput: #""type":"KillTask","TaskNotFound":"Task \#(missingTask) not found""#,
            preview: "Task \(missingTask) not found"),
    ]

    @Test(arguments: taskActions)
    func taskReadsAndKillsPreviewTheirResult(action: TaskAction) throws {
        let lines = Self.lines([
            try Self.prompt("Check on the background task.", index: 0, event: 1),
            Self.call(name: action.name, kind: action.kind, input: action.input, event: 2),
            Self.result(
                status: action.failed ? "failed" : "completed", content: nil, rawOutput: action.rawOutput, event: 3),
        ])
        let reducer = Self.reducer(lines)

        let tool = try Self.tool(reducer.transcript(ChatProjectionContext(activity: .idle)), Self.callID)

        let status: ChatToolActivity.Status = action.failed ? .failed : .succeeded
        #expect(tool.kind == .other)
        #expect(tool.status == status)
        #expect(tool.preview == Self.preview(action.preview))
        #expect(tool.output == Self.reference(lines, 3))
        // Expanded, the row reads its result line again.
        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: lines[2], for: tool)
        }
        #expect(expanded == .preview(Self.preview(action.preview)))
    }

    // MARK: Expanded output

    @Test func expandedOutputReadsTheResultLineAgain() throws {
        let output = (1...60).map { "line \($0)\n" }.joined()
        let lines = Self.lines([
            try Self.prompt("Print sixty lines.", index: 0, event: 1),
            Self.call(name: "run_terminal_command", input: #""command":"seq 60""#, event: 2),
            Self.result(
                content: try Self.text(output),
                rawOutput: #""type":"Bash","output_for_prompt":\#(try Self.json("exit: 0\n" + output)),"exit_code":0"#,
                event: 3),
        ])
        let reducer = Self.reducer(lines)
        let tool = try Self.tool(reducer.transcript(ChatProjectionContext(activity: .idle)), Self.callID)
        #expect(
            tool.preview
                == ChatToolPreview(text: (1...40).map { "line \($0)" }.joined(separator: "\n"), isTruncated: true))
        #expect(tool.previewIsIncomplete)
        #expect(tool.output == Self.reference(lines, 3))

        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            reducer.output(of: lines[2], for: tool)
        }
        #expect(expanded == .preview(Self.preview((1...60).map { "line \($0)" }.joined(separator: "\n"))))
        // Another call's line, or a line without the result, holds none.
        var other = tool
        other.callID = "call-01900000-0000-7000-8000-000000000011-9"
        #expect(reducer.output(of: lines[2], for: other) == nil)
        #expect(reducer.output(of: lines[1], for: tool) == nil)

        // An edit's row reads its diff again.
        let edit = try Self.lines("reject-and-edit.jsonl", 14...20)
        let editReducer = Self.reducer(edit)
        let editTool = try Self.tool(
            editReducer.transcript(ChatProjectionContext(windowStart: edit[0].offset, activity: .idle)),
            "call-01900000-0000-7000-8000-00000000002f-10")
        let diff = ChatFileChanges.$limits.withValue(ChatFileChanges.expandedLimits) {
            editReducer.output(of: edit[4], for: editTool)
        }
        #expect(diff == .preview(nil, fileChanges: editTool.fileChanges))
        #expect(editReducer.output(of: edit[3], for: editTool) == nil)

        // A background command's row reads the task's end again.
        let background = try Self.lines("background-tasks.jsonl")
        let backgroundReducer = Self.reducer(background)
        let tests = try Self.tool(
            backgroundReducer.transcript(ChatProjectionContext(activity: .idle)),
            "call-01900000-0000-7000-8000-000000000040-1")
        #expect(
            backgroundReducer.output(of: background[21], for: tests)
                == .preview(Self.preview("Running 42 tests\n42 passed")))
    }
}
