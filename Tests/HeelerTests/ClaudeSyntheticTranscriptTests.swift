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
        #expect(
            ClaudeSample.entry("notice:k1", in: transcript)
                == .notice(ChatNotice(kind: .stopped, title: "All background agents stopped")))

        // Without it the agent is still running, whatever herdr reports.
        let running = Self.read(Self.backgroundAgent, activity: .idle).0
        #expect(Self.tool("tool:toolu_agent", in: running)?.status == .running)
        #expect(running.pendingRequests.isEmpty)
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
                == .notice(ChatNotice(kind: .system, title: "Ship it after the tests pass.")))
        #expect(
            ClaudeSample.entry("notice:e2", in: transcript)
                == .notice(ChatNotice(kind: .system, title: "Continue from where you left off.")))
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
