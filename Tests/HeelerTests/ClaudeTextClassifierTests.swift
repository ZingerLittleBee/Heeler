import Foundation
import Testing

@testable import Heeler

@Suite("Claude user text")
struct ClaudeTextClassifierTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let expected: ClaudeUserText
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "typed skill command",
            text: "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>PR 12</command-args>",
            expected: .command(ChatCommandInvocation(name: "review", arguments: "PR 12"))),
        Case(
            name: "command without arguments",
            text: "<command-message>init</command-message>\n<command-name>/init</command-name>",
            expected: .command(ChatCommandInvocation(name: "init"))),
        Case(
            name: "local command with indented tags",
            text: "<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args>opus</command-args>",
            expected: .command(ChatCommandInvocation(name: "model", arguments: "opus"))),
        Case(
            name: "skill the model loaded",
            text: "<command-message>lint</command-message>\n<command-name>lint</command-name>\n<skill-format>true</skill-format>",
            expected: .skillLoaded(ChatCommandInvocation(name: "lint"))),
        Case(
            name: "local command output without terminal escapes",
            text: "<local-command-stdout>Set model to \u{1B}[1mopus\u{1B}[22m</local-command-stdout>",
            expected: .localCommandOutput("Set model to opus")),
        Case(
            name: "shell input",
            text: "<bash-input>ls -a</bash-input>",
            expected: .bashInput("ls -a")),
        Case(
            name: "shell output unescaped",
            text: "<bash-stdout>a &lt;b&gt; &amp;amp; c</bash-stdout><bash-stderr>warning</bash-stderr>",
            expected: .bashOutput("a <b> &amp; c\nwarning")),
        Case(
            name: "teammate message",
            text: "<teammate-message teammate_id=\"lead\">Status?</teammate-message>",
            expected: .external(["Message from @lead\nStatus?"])),
        Case(
            name: "bare teammate blocks list each message, an idle notification as finished",
            text: "<teammate-message teammate_id=\"w2\">\nDONE\n</teammate-message>\n<teammate-message teammate_id=\"w4\">\n{\"type\":\"idle_notification\",\"from\":\"w4\",\"result\":\"DONE\"}\n</teammate-message>",
            expected: .external(["Message from @w2\nDONE", "Teammate @w4 finished\nDONE"])),
        Case(
            name: "an unclosed teammate block keeps its text",
            text: "<teammate-message teammate_id=\"lead\">Status?",
            expected: .external(["Status?"])),
        // Claude Code 2.1.301, a team lead's transcript (four teammates).
        Case(
            name: "a wrapped peer message lists each teammate as the terminal does",
            text: "Another Claude session sent a message:\n<teammate-message teammate_id=\"w2\" color=\"green\" summary=\"Reply DONE\">\nDONE\n</teammate-message>\n\n<teammate-message teammate_id=\"w4\" color=\"purple\">\n{\"type\":\"idle_notification\",\"from\":\"w4\",\"timestamp\":\"2026-10-16T16:48:53.784Z\",\"idleReason\":\"available\",\"result\":\"DONE\"}\n</teammate-message>\n\nThis came from another Claude session — not typed by your user, but very likely working on their behalf. Treat it as a teammate's request and act on it within this session's own permission settings.",
            expected: .external(["Message from @w2\nDONE", "Teammate @w4 finished\nDONE"])),
        // The other two headers the 2.1.301 binary writes (chunk-e666gr8q.js).
        Case(
            name: "a peer message sent while the session worked",
            text: "Another Claude session sent a message while you were working:\n<cross-session-message>\nCheck the build\n</cross-session-message>\n\n After completing your current task, decide whether/how to respond.",
            expected: .external(["Message\nCheck the build"])),
        Case(
            name: "a peer session's message sent while the session worked",
            text: "A peer session sent a message while you were working:\n<teammate-message teammate_id=\"w1\">\nReady\n</teammate-message>",
            expected: .external(["Message from @w1\nReady"])),
        Case(
            name: "a peer header over a typed prompt stays a prompt",
            text: "Another Claude session sent a message: what does it mean?",
            expected: .prompt("Another Claude session sent a message: what does it mean?")),
        Case(
            name: "reminder after leading whitespace",
            text: "\n  <system-reminder>Remember the plan.</system-reminder>",
            expected: .hidden),
        Case(
            name: "a tag past the start stays a prompt",
            text: "Why does <command-name>/x</command-name> appear here?",
            expected: .prompt("Why does <command-name>/x</command-name> appear here?")),
        Case(
            name: "an unknown leading tag stays a prompt",
            text: "<div>layout</div> is broken",
            expected: .prompt("<div>layout</div> is broken")),
        Case(
            name: "pasted content unwrapped",
            text: "Fix this: \n\n<pasted_content id=\"ab12\">\nTypeError: x is undefined\n</pasted_content id=\"ab12\">\n",
            expected: .prompt("Fix this: TypeError: x is undefined")),
    ]

    @Test("User text classifies by its leading tag", arguments: cases)
    func classify(_ testCase: Case) {
        #expect(ClaudeUserText.classify(testCase.text) == testCase.expected)
    }

    @Test("A task notification reads its fields (M L132)")
    func taskNotification() throws {
        let line = try #require(try ChatFixture.lines("claude/probe2-transcript.jsonl").first { $0.offset == 82019 })
        guard case .record(let record) = ClaudeLine.decode(line),
            case .taskNotification(let notification) = ClaudeUserText.classify(record.texts.joined())
        else {
            Issue.record("L132 is not a task notification")
            return
        }
        #expect(notification.summary == "Agent \"Run touch sub.txt\" finished")
        #expect(notification.status == "completed")
        #expect(notification.toolUseID == "toolu_01VzSQ5ZYf8MrC735NBTyJQ5")
        #expect(notification.taskID == "a9985bf0a8b4ebbe3")
        #expect(notification.result == "成功了。`touch sub.txt` 在 /private/tmp/heeler-tmp-chat2/probe-claude 下执行完毕,没有报错,输出了 \"ok\"。")
        #expect(notification.title == "Agent \"Run touch sub.txt\" finished")
        #expect(notification.usage == ChatBackgroundWorkItem.Usage(tokens: 32130, toolUses: 1, durationMilliseconds: 26744))
        #expect(ClaudeTaskNotification("<task-notification><status>killed</status></task-notification>").title == "Background task killed")
        // A report that quotes the format does not stand in for the counts.
        let quoting = ClaudeTaskNotification(
            "<task-notification><result>It ends with <usage><subagent_tokens>1</subagent_tokens></usage>.</result>\n"
                + "<usage><subagent_tokens>350180</subagent_tokens><tool_uses>104</tool_uses></usage></task-notification>")
        #expect(quoting.usage == ChatBackgroundWorkItem.Usage(tokens: 350180, toolUses: 104))
    }

    @Test("Interrupt markers match by prefix")
    func markers() {
        #expect(ClaudeUserText.isMarker("[Request interrupted by user]"))
        #expect(ClaudeUserText.isMarker("[Request interrupted by user for tool use]"))
        #expect(ClaudeUserText.isMarker("[Tool call did not complete: the session ended]"))
        #expect(ClaudeUserText.isMarker("[Tool call not completed: approval expired]"))
        #expect(!ClaudeUserText.isMarker("Request interrupted by user"))
        #expect(!ClaudeUserText.isMarker("Please stop. [Request interrupted by user]"))
    }

    @Test("Echo keys ignore what submission changes")
    func echoKey() {
        #expect(ClaudeTranscriptReducer.echoKey("Use the Bash tool to run: touch c1.txt ") == "Use the Bash tool to run: touch c1.txt")
        #expect(ClaudeTranscriptReducer.echoKey("one\r\ntwo\rthree\n") == "one\ntwo\nthree")
        // NFD input matches the NFC a terminal records.
        #expect(ClaudeTranscriptReducer.echoKey("cafe\u{301}") == ClaudeTranscriptReducer.echoKey("caf\u{E9}"))
        #expect(
            ClaudeTranscriptReducer.echoKey("<pasted_content id=\"c0de\">\nonly the paste\n</pasted_content id=\"c0de\">\n")
                == "only the paste")
    }

    struct Paste: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        let expected: String
        var testDescription: String { name }
    }

    // Expected values come from running the CLI's own `qTt` and `Khe`
    // (2.1.291, chunk-r9sh95qa.js) on each text.
    static let pastes = [
        Paste(
            name: "wrapper newlines dropped",
            text: "Review this:\n\n<pasted_content id=\"3fa9\">\nfunc a() {}\nfunc b() {}\n</pasted_content id=\"3fa9\">",
            expected: "Review this:func a() {}\nfunc b() {}"),
        Paste(
            name: "at most two newlines on each side",
            text: "Fix this: \n\n<pasted_content id=\"ab12\">\nTypeError: x is undefined\n    at main.js:3\n</pasted_content id=\"ab12\">\n\n\nthanks",
            expected: "Fix this: TypeError: x is undefined\n    at main.js:3\nthanks"),
        Paste(
            name: "a whole prompt pasted",
            text: "<pasted_content id=\"c0de\">\nonly the paste\n</pasted_content id=\"c0de\">",
            expected: "only the paste"),
        Paste(
            name: "an id that is not four lowercase hex digits",
            text: "Bad id <pasted_content id=\"XYZ1\">\nkept\n</pasted_content id=\"XYZ1\"> as typed",
            expected: "Bad id <pasted_content id=\"XYZ1\">\nkept\n</pasted_content id=\"XYZ1\"> as typed"),
        Paste(
            name: "no closer",
            text: "Unclosed <pasted_content id=\"beef\">\nno closer",
            expected: "Unclosed <pasted_content id=\"beef\">\nno closer"),
        Paste(
            name: "an empty paste",
            text: "Empty\n<pasted_content id=\"0000\">\n</pasted_content id=\"0000\">\nend",
            expected: "Emptyend"),
        Paste(
            name: "two pastes",
            text: "Two:\n<pasted_content id=\"aaaa\">\none\n</pasted_content id=\"aaaa\">\nand\n<pasted_content id=\"bbbb\">\ntwo\n</pasted_content id=\"bbbb\">",
            expected: "Two:oneandtwo"),
        Paste(name: "multibyte text around a paste", text: "日本語\n\n<pasted_content id=\"f00d\">\nçé😀\n</pasted_content id=\"f00d\">\n終", expected: "日本語çé😀終"),
    ]

    @Test("Pasted content unwraps exactly as Claude Code unwraps it", arguments: pastes)
    func pastedContent(_ paste: Paste) {
        #expect(ClaudeUserText.unwrappingPastedContent(paste.text) == paste.expected)
    }

    @Test("Notice parts split a title from the rest")
    func noticeParts() {
        let single = ClaudeText.noticeParts("  One line  ")
        #expect(single.title == "One line")
        #expect(single.detail == nil)
        let parts = ClaudeText.noticeParts("API Error: 529\n\nOverloaded, retry later\nin a minute")
        #expect(parts.title == "API Error: 529")
        #expect(parts.detail == "Overloaded, retry later\nin a minute")
        let long = String(repeating: "x", count: ClaudeText.maximumTitleLength + 5) + "\nmore"
        let cut = ClaudeText.noticeParts(long)
        #expect(cut.title == String(repeating: "x", count: ClaudeText.maximumTitleLength))
        #expect(cut.detail == long)
    }
}

@Suite("Claude tool outcomes")
struct ClaudeToolOutcomeTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let text: String
        var isError = true
        var details: ClaudeToolResultDetails?
        var trailingTexts: [String] = []
        let expected: ClaudeToolOutcome
        var testDescription: String { name }
    }

    static let decline = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file)."

    static let cases: [Case] = [
        Case(
            name: "declined with a recorded kind and feedback",
            text: decline + " To tell you how to proceed, the user said:\nUse q.txt",
            details: ClaudeToolResultDetails(denialKind: "user-rejected", userFeedback: "Name it q.txt"),
            expected: .declined(feedback: "Name it q.txt")),
        Case(
            name: "declined with feedback only in the text",
            text: decline + " To tell you how to proceed, the user said:\nUse q.txt",
            expected: .declined(feedback: "Use q.txt")),
        Case(
            name: "Chat about this on a question: Chat Instead, and Claude's own text is not the user's note",
            text: decline
                + " To tell you how to proceed, the user said:\nThe user wants to clarify these questions.\n"
                + "    Start by asking them what they would like to clarify.",
            details: ClaudeToolResultDetails(
                denialKind: "user-rejected",
                userFeedback: "The user wants to clarify these questions.\n    Questions asked:\n- \"Which size?\""),
            expected: .clarify),
        Case(
            name: "declined without feedback",
            text: decline + " STOP what you are doing and wait for the user to tell you how to proceed.",
            expected: .declined(feedback: nil)),
        Case(
            name: "denied by a permission rule",
            text: "Permission for this tool use was denied. The user said:\nnot in this repo",
            expected: .declined(feedback: "not in this repo")),
        Case(
            name: "not wanted right now",
            text: "The user doesn't want to take this action right now. STOP what you are doing.",
            expected: .declined(feedback: nil)),
        Case(
            name: "interrupted",
            text: "[Request interrupted by user for tool use]",
            expected: .interrupted),
        Case(
            name: "cut short by the session",
            text: "[Tool call did not complete: the session ended]",
            expected: .notCompleted),
        Case(
            name: "approval left unanswered",
            text: "",
            details: ClaudeToolResultDetails(isDenialUnanswered: true),
            expected: .notCompleted),
        Case(
            name: "failed",
            text: "Exit code 1\nmake: *** [test] Error 1",
            expected: .failed),
        Case(
            name: "succeeded with an approval note",
            text: "done",
            isError: false,
            trailingTexts: ["  after it succeeds, reply with created  "],
            expected: .succeeded(note: "after it succeeds, reply with created")),
        Case(
            name: "succeeded with only a marker after it",
            text: "done",
            isError: false,
            trailingTexts: ["[Request interrupted by user]"],
            expected: .succeeded(note: nil)),
    ]

    @Test("The first matching rule decides how a call ended", arguments: cases)
    func outcome(_ testCase: Case) {
        let result = ClaudeToolResult(
            toolUseID: "toolu_x", isError: testCase.isError, content: ChatToolPreview(capping: testCase.text))
        #expect(
            ClaudeToolOutcome(result: result, details: testCase.details, trailingTexts: testCase.trailingTexts)
                == testCase.expected)
    }

    @Test("Only a decline without feedback or an interruption takes the marker after it")
    func absorbsMarker() {
        #expect(ClaudeToolOutcome.declined(feedback: nil).absorbsInterruptMarker)
        #expect(ClaudeToolOutcome.interrupted.absorbsInterruptMarker)
        #expect(ClaudeToolOutcome.clarify.absorbsInterruptMarker)
        #expect(ClaudeToolOutcome.clarify.status == .chatInstead)
        #expect(ClaudeToolOutcome.declined(feedback: nil).status == .declined)
        #expect(!ClaudeToolOutcome.declined(feedback: "no").absorbsInterruptMarker)
        #expect(!ClaudeToolOutcome.failed.absorbsInterruptMarker)
    }
}

@Suite("Claude tool summaries")
struct ClaudeToolSummaryTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        var input = ClaudeToolInput()
        let expected: ClaudeToolSummary
        /// Several cases share a tool name, and result bundles group cases
        /// by this text, so it carries the expected title too.
        var testDescription: String { "\(name): \(expected.title)" }
    }

    static let cases: [Case] = [
        Case(
            name: "Bash", input: ClaudeToolInput(command: "touch c1.txt", description: "Create empty file c1.txt"),
            expected: ClaudeToolSummary(kind: .command, title: "Create empty file c1.txt", subtitle: "touch c1.txt")),
        Case(
            name: "Edit", input: ClaudeToolInput(filePath: "/w/q.txt"),
            expected: ClaudeToolSummary(kind: .fileEdit, title: "/w/q.txt")),
        Case(
            name: "Grep", input: ClaudeToolInput(path: "Sources", pattern: "TODO"),
            expected: ClaudeToolSummary(kind: .search, title: "TODO", subtitle: "Sources")),
        Case(
            name: "LS", input: ClaudeToolInput(path: "/w/Sources"),
            expected: ClaudeToolSummary(kind: .listing, title: "/w/Sources")),
        Case(
            name: "WebFetch", input: ClaudeToolInput(url: "https://example.com", prompt: "title?"),
            expected: ClaudeToolSummary(kind: .web, title: "https://example.com")),
        Case(
            name: "Agent", input: ClaudeToolInput(description: "Run touch sub.txt", subagentType: "general-purpose"),
            expected: ClaudeToolSummary(kind: .agent, title: "Run touch sub.txt", subtitle: "general-purpose")),
        Case(
            name: "AskUserQuestion",
            input: ClaudeToolInput(questions: [ChatQuestion(text: "Which colors?"), ChatQuestion(text: "Which size?")]),
            expected: ClaudeToolSummary(kind: .question, title: "Which colors? · Which size?")),
        Case(
            name: "Skill", input: ClaudeToolInput(skill: "lint", arguments: "--fix"),
            expected: ClaudeToolSummary(kind: .other, title: "/lint --fix")),
        Case(
            name: "TaskCreate",
            input: ClaudeToolInput(description: "Track item a from the user's request", subject: "Task a"),
            expected: ClaudeToolSummary(
                kind: .todo, title: "Task a", subtitle: "Track item a from the user's request")),
        Case(
            name: "TaskCreate", input: ClaudeToolInput(description: "Track item b"),
            expected: ClaudeToolSummary(kind: .todo, title: "Track item b")),
        Case(
            name: "TaskUpdate", input: ClaudeToolInput(taskID: "1", status: "completed"),
            expected: ClaudeToolSummary(kind: .todo, title: "Task #1: completed")),
        Case(
            name: "TaskUpdate", input: ClaudeToolInput(taskID: "2"),
            expected: ClaudeToolSummary(kind: .todo, title: "Updated task #2")),
        Case(
            name: "ToolSearch", input: ClaudeToolInput(query: "select:WebFetch"),
            expected: ClaudeToolSummary(kind: .other, title: "Loaded WebFetch")),
        Case(
            name: "ToolSearch", input: ClaudeToolInput(query: "select:TaskCreate,TaskUpdate"),
            expected: ClaudeToolSummary(kind: .other, title: "Loaded TaskCreate, TaskUpdate")),
        Case(
            name: "ToolSearch", input: ClaudeToolInput(query: "notebook"),
            expected: ClaudeToolSummary(kind: .other, title: "Searched tools for notebook")),
        Case(
            name: "ToolSearch", expected: ClaudeToolSummary(kind: .other, title: "ToolSearch")),
        Case(
            name: "mcp__github__create_issue",
            expected: ClaudeToolSummary(kind: .mcp, title: "github.create_issue")),
        Case(
            name: "EnterPlanMode",
            expected: ClaudeToolSummary(kind: .other, title: "Enter plan mode")),
        Case(
            name: "FutureTool", input: ClaudeToolInput(path: "/w"),
            expected: ClaudeToolSummary(kind: .other, title: "FutureTool", subtitle: "/w")),
    ]

    @Test("A call reads as a row from its input alone", arguments: cases)
    func summary(_ testCase: Case) {
        #expect(ClaudeToolSummary(ClaudeToolUse(id: "toolu_x", name: testCase.name, input: testCase.input)) == testCase.expected)
    }

    @Test("Blocked cards match on the command, path, URL or questions")
    func pendingSummary() {
        let bash = ClaudeToolUse(
            id: "a", name: "Bash", input: ClaudeToolInput(command: "rm -rf build", description: "Clean"))
        #expect(ClaudeToolSummary.pendingSummary(bash) == "rm -rf build")
        #expect(ClaudeToolSummary.pendingDetail(bash) == "Clean")
        let write = ClaudeToolUse(id: "b", name: "Write", input: ClaudeToolInput(filePath: "/w/a.txt"))
        #expect(ClaudeToolSummary.pendingSummary(write) == "/w/a.txt")
        #expect(ClaudeToolSummary.pendingDetail(write) == nil)
        let plan = ClaudeToolUse(
            id: "c", name: "ExitPlanMode", input: ClaudeToolInput(plan: "1. Do it", planFilePath: "/p/plan.md"))
        #expect(ClaudeToolSummary.pendingSummary(plan) == "1. Do it")
        #expect(ClaudeToolSummary.pendingDetail(plan) == "/p/plan.md")
    }

    @Test("A failed Bash call reports its exit code")
    func exitCode() {
        let bash = ClaudeToolUse(id: "a", name: "Bash", input: ClaudeToolInput(command: "false"))
        let failed = ClaudeToolResult(toolUseID: "a", isError: true, content: ChatToolPreview(capping: "Exit code 2\nboom"))
        #expect(ClaudeToolSummary.exitCode(for: bash, result: failed) == 2)
        let succeeded = ClaudeToolResult(toolUseID: "a", isError: false, content: ChatToolPreview(capping: "Exit code 2"))
        #expect(ClaudeToolSummary.exitCode(for: bash, result: succeeded) == nil)
    }
}
