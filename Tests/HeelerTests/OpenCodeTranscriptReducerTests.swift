import Foundation
import Testing

@testable import Heeler

@Suite("OpenCode transcript reducer", .timeLimit(.minutes(1)))
struct OpenCodeTranscriptReducerTests {
    // MARK: Turns

    @Test func aTurnIsAUserRowItsStepsAndAnIdleRow() throws {
        let transcript = try Self.transcript("pong")
        let prompt = ChatEntryID("oc:msg_0a1b2c3d4e10bdgTHK86OgNR4o")
        #expect(
            transcript.entries == [
                ChatEntry(
                    id: prompt, sourceOffset: 4, content: .user(ChatUserMessage(text: "Reply with exactly the word pong."))),
                ChatEntry(
                    id: ChatEntryID("oc:msg_0a1b2c3d4e20qfPDcxniwu6NKr:0"), sourceOffset: 7,
                    content: .assistant(ChatAssistantMessage(text: "pong"))),
            ])
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: prompt, startedAt: Self.date(1_800_000_000_016), endedAt: Self.date(1_800_000_013_843),
                    ending: .completed)
            ])
        #expect(transcript.title == "Pong")
        #expect(transcript.latestPromptOffset == 4)
        #expect(transcript.precedingTurnEnd == nil)
        #expect(!transcript.needsOlderHistory)
        #expect(transcript.pendingRequests.isEmpty)
    }

    @Test func aSteerInsideARunningTurnStaysInIt() throws {
        let transcript = try Self.transcript("steer")
        #expect(transcript.turns.count == 1)
        #expect(transcript.turns.first?.ending == .completed)
        #expect(transcript.turns.first?.endedAt == Self.date(1_800_000_692_097))
        let steer = try #require(transcript.entries.first { $0.id == Self.steerID })
        #expect(steer.content == .user(ChatUserMessage(text: "After that, reply with two.", wasQueued: true)))
        #expect(transcript.recordedPrompts.map(\.offset) == [176, 187])
        #expect(transcript.latestPromptOffset == 187)
        let shell = try #require(Self.tools(transcript).first)
        #expect(shell.status == .succeeded)
        #expect(shell.title == "sleep 15; echo one")
        #expect(shell.preview == ChatToolPreview(text: "one\n", isTruncated: false))
    }

    @Test func anInboxSteerShowsQueuedUntilItsUserRowArrives() throws {
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(try Self.lines("steer-queued"))
        let queued = reducer.transcript(ChatProjectionContext(activity: .working))
        Self.expectNoMalformedLines(queued)
        #expect(
            queued.entries.last
                == ChatEntry(
                    id: Self.steerID, sourceOffset: 184,
                    content: .user(ChatUserMessage(text: "After that, reply with two.", wasQueued: true))))
        #expect(queued.unrecordedEntryIDs == [Self.steerID])
        #expect(
            queued.recordedPrompts.last
                == ChatRecordedPrompt(offset: 184, text: "After that, reply with two.", entryID: Self.steerID))
        #expect(queued.turns.map(\.ending) == [nil])

        reducer.append(try Self.lines("steer"))
        let promoted = reducer.transcript(ChatProjectionContext(activity: .idle))
        Self.expectNoMalformedLines(promoted)
        #expect(promoted.entries.filter { $0.id == Self.steerID }.map(\.sourceOffset) == [187])
        #expect(promoted.unrecordedEntryIDs.isEmpty)
        #expect(promoted.recordedPrompts.filter { $0.entryID == Self.steerID }.map(\.offset) == [187])
        #expect(promoted.turns.map(\.ending) == [.completed])
    }

    @Test func aRejectedPermissionEndsTheTurnWithoutAnIdleRow() throws {
        // herdr may still say Blocked; the declined call is no request.
        let transcript = try Self.transcript("reject", activity: .blocked)
        #expect(transcript.turns.map(\.ending) == [.interrupted])
        #expect(transcript.turns.first?.endedAt == Self.date(1_800_000_342_454))
        let read = try #require(Self.tools(transcript).first)
        #expect(read.kind == .fileRead)
        #expect(read.status == .declined)
        #expect(read.title == "/Users/developer/work/heeler-tmp-chat/opencode-a/project/.env")
        #expect(transcript.pendingRequests.isEmpty)
        // The step's own error is the decline, which is no failure.
        #expect(!transcript.entries.contains { Self.isNotice($0) })
    }

    @Test func aTurnResumedAfterARestartRunsAgain() throws {
        let restart = Self.row(
            "msg_restart", "synthetic", seq: 90,
            #"{"text":"The server restarted while you were working.","n":45,"description":"Continuing after restart","metadata":{"source":null,"childID":null,"state":null,"exit":null,"notice":"restart","jobID":null,"shellID":null,"truncated":null}}"#
        )
        let resumed = Self.step(91, isFinal: false, items: [Self.text(0, "Reading it again.")])
        let running = Self.project(try Self.lines("reject") + [restart, resumed], activity: .working)
        Self.expectNoMalformedLines(running)
        #expect(running.turns.count == 1)
        #expect(running.turns.first?.ending == nil)
        #expect(running.turns.first?.endedAt == nil)
        #expect(
            running.entries.contains {
                $0.content == .notice(ChatNotice(kind: .system, title: "Continuing after a restart"))
            })
        #expect(Self.tools(running).first?.status == .declined)

        let ended = Self.project(try Self.lines("reject") + [restart, resumed, Self.idle(95)])
        #expect(ended.turns.map(\.ending) == [.completed])
        #expect(ended.turns.first?.endedAt == Self.date(1_800_000_100_095))
    }

    /// OpenCode 2 imports a 1.x session without `idle` rows, keeping its
    /// version. Each prompt opens its own turn, and the turn before ends
    /// with its last step.
    @Test func anImportedSessionOpensATurnPerPrompt() throws {
        let transcript = Self.project(Self.imported)
        Self.expectNoMalformedLines(transcript)
        #expect(transcript.turns.map(\.firstEntryID) == [0, 3, 5, 7].map { ChatEntryID("oc:msg_u\($0)") })
        #expect(transcript.turns.map(\.ending) == [.completed, .interrupted, .failed, nil])
        #expect(
            transcript.turns.map(\.endedAt) == [
                Self.date(1_800_000_100_102), Self.date(1_800_000_100_104), Self.date(1_800_000_100_106), nil,
            ])
        #expect(Self.prompts(transcript).allSatisfy { !$0.wasQueued })
        #expect(transcript.entries.contains { $0.content == .notice(ChatNotice(kind: .error, title: "Rate limited")) })
    }

    /// An imported session OpenCode 2 goes on with: its first new prompt
    /// opens a turn, and once an `idle` row arrives, steers stay in the
    /// turn they steer.
    @Test func anImportedSessionThatGoesOnInOpenCode2KeepsItsSteers() throws {
        let continued = Self.imported + [
            Self.prompt(9), Self.step(10, items: [Self.text(0, "Five.")], fields: #""finish":"stop""#),
            Self.idle(11), Self.prompt(12),
            Self.step(13, items: [Self.tool(0, name: "shell", status: "completed")], fields: #""finish":"tool-calls""#),
            Self.prompt(14), Self.step(15, items: [Self.text(0, "Six.")], fields: #""finish":"stop""#), Self.idle(16),
        ]
        let transcript = Self.project(continued)
        Self.expectNoMalformedLines(transcript)
        #expect(transcript.turns.map(\.firstEntryID) == [0, 3, 5, 7, 9, 12].map { ChatEntryID("oc:msg_u\($0)") })
        #expect(transcript.turns.map(\.ending) == [.completed, .interrupted, .failed, .completed, .completed, .completed])
        try #require(transcript.turns.count == 6)
        #expect(transcript.turns[3].endedAt == Self.date(1_800_000_100_108))
        #expect(Self.prompts(transcript).map(\.wasQueued) == [false, false, false, false, false, false, true])
    }

    @Test func escStopEndsTheTurnInterruptedAndKeepsPartialText() throws {
        let transcript = try Self.transcript("esc-stop")
        #expect(transcript.turns.map(\.ending) == [.interrupted])
        #expect(transcript.turns.first?.endedAt == Self.date(1_800_000_558_362))
        #expect(
            transcript.entries.contains {
                $0.content
                    == .assistant(
                        ChatAssistantMessage(
                            text: "I'll run that command, wait about 30 seconds, then report the output."))
            })
        let shell = try #require(Self.tools(transcript).first)
        #expect(shell.title == "sleep 30; echo done")
        #expect(shell.status == .interrupted)
        // The aborted step is no failure: the stop shows once, at its end.
        #expect(transcript.entries.filter { Self.isNotice($0) }.count == 1)
        #expect(
            transcript.entries.last
                == ChatEntry(
                    id: ChatEntryID("oc:msg_0a1b2c3d4e30m2eiCL86VTGcGZ"), sourceOffset: 159,
                    content: .notice(ChatNotice(kind: .interrupted, title: "Interrupted"))))
    }

    /// OpenCode ends a stopped turn with an `interrupted` idle row, and the
    /// turn says so where OpenCode's own screen reads `· interrupted`: after
    /// the partial reply, or after the prompt when the stop came before any
    /// text. A turn that succeeded says nothing. The rows are those of the
    /// in-app check's Stop during a reply and Stop before any text.
    @Test func aStoppedTurnSaysItWasInterrupted() {
        let aborted = #""finish":"error","error":{"type":"aborted","message":"Step interrupted"}"#
        let interrupted = #"{"outcome":"interrupted"}"#
        let transcript = Self.project([
            Self.prompt(82), Self.step(83, items: [Self.text(0, "lime")], fields: #""finish":"stop""#), Self.idle(88),
            Self.prompt(92), Self.step(93, items: [Self.text(0, "1\n2\n3\n")], fields: aborted),
            Self.row("msg_i98", "idle", seq: 98, interrupted),
            Self.prompt(163), Self.step(165, items: [], fields: aborted),
            Self.row("msg_i167", "idle", seq: 167, interrupted),
        ])
        #expect(
            transcript.entries.map(\.id.rawValue) == [
                "oc:msg_u82", "oc:msg_s83:0", "oc:msg_u92", "oc:msg_s93:0", "oc:msg_i98", "oc:msg_u163",
                "oc:msg_i167",
            ])
        let stop = ChatEntry.Content.notice(ChatNotice(kind: .interrupted, title: "Interrupted"))
        #expect(
            transcript.entries.filter { Self.isNotice($0) } == [
                ChatEntry(id: ChatEntryID("oc:msg_i98"), sourceOffset: 98, content: stop),
                ChatEntry(id: ChatEntryID("oc:msg_i167"), sourceOffset: 167, content: stop),
            ])
        #expect(transcript.turns.map(\.ending) == [.completed, .interrupted, .interrupted])
    }

    @Test func anUpdatedRowReplacesItsEntriesInPlace() throws {
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(try Self.lines("steer-queued"))
        let before = reducer.transcript(ChatProjectionContext(activity: .working))
        let toolID = ChatEntryID("oc:msg_0a1b2c3d4e20NVcJRLTUWz3eOd:1")
        #expect(Self.tool(toolID, in: before)?.status == .running)
        #expect(Self.tool(toolID, in: before)?.preview == nil)

        // The step is rewritten when it ends.
        reducer.append([try #require(try Self.lines("steer").first { $0.offset == 177 })])
        let after = reducer.transcript(ChatProjectionContext(activity: .working))
        Self.expectNoMalformedLines(after)
        #expect(after.entries.map(\.id) == before.entries.map(\.id))
        #expect(Self.tool(toolID, in: after)?.status == .succeeded)
        #expect(Self.tool(toolID, in: after)?.preview == ChatToolPreview(text: "one\n", isTruncated: false))
    }

    @Test func aStagedRevertHidesRowsFromItsBoundary() throws {
        let staged = try Self.transcript("undo-staged")
        #expect(
            staged.entries.map(\.id.rawValue) == [
                "oc:msg_0a1b2c3d4e10o4v5vvo06tWSNU", "oc:msg_0a1b2c3d4e20p5xbehYANs7699:0",
                "oc:msg_0a1b2c3d4e40bnybbDUaT4t4KD", "oc:msg_0a1b2c3d4e501nQ3DdIbolthRf:1",
                "oc:revert:msg_0a1b2c3d4e70LMbLuB1pGKgZbA",
            ])
        #expect(
            staged.entries.last
                == ChatEntry(
                    id: ChatEntryID("oc:revert:msg_0a1b2c3d4e70LMbLuB1pGKgZbA"), sourceOffset: 27,
                    content: .notice(
                        ChatNotice(
                            kind: .system, title: "Undone in the terminal",
                            detail: "The next message removes these messages; /redo brings them back."))))
        #expect(staged.turns.map(\.ending) == [.completed, .completed])
        #expect(staged.recordedPrompts.map(\.offset) == [4, 15])
        #expect(staged.latestPromptOffset == 15)

        // The next prompt commits the revert: its rows are gone.
        let committed = try Self.transcript("undo-committed")
        #expect(committed.turns.map(\.ending) == [.completed, .completed, .completed])
        #expect(!committed.entries.contains { $0.id.rawValue.hasPrefix("oc:revert:") })
        #expect(committed.latestPromptOffset == 45)
    }

    @Test func aBareIdleAfterRedoOpensNoTurn() throws {
        let transcript = try Self.transcript("undo-before")
        #expect(
            transcript.turns.map(\.firstEntryID.rawValue) == [
                "oc:msg_0a1b2c3d4e10o4v5vvo06tWSNU", "oc:msg_0a1b2c3d4e40bnybbDUaT4t4KD",
                "oc:msg_0a1b2c3d4e70LMbLuB1pGKgZbA",
            ])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed, .completed])
        // The last turn keeps the end its own idle row gave it.
        #expect(transcript.turns.last?.endedAt == Self.date(1_800_000_280_083))
        #expect(!transcript.entries.contains { $0.id.rawValue.hasPrefix("oc:msg_0a1b2c3d4ea0") })
    }

    @Test func manualCompactionOpensATurnAndShowsItsSummary() throws {
        let transcript = try Self.transcript("compact")
        let opener = ChatEntryID("oc:msg_0a1b2c3d4e107YWDFivnBRVaqN")
        #expect(
            transcript.entries.first
                == ChatEntry(id: opener, sourceOffset: 210, content: .notice(ChatNotice(kind: .command, title: "/compact"))))
        #expect(transcript.entries.count == 2)
        let divider = try #require(transcript.entries.last)
        #expect(divider.id == ChatEntryID("oc:msg_0a1b2c3d4e107YWDFivnBRVaqN:divider"))
        guard case .divider(let compaction) = divider.content else {
            Issue.record("Expected a compaction divider, got \(divider.content)")
            return
        }
        #expect(compaction.kind == .compaction)
        #expect(compaction.detail?.contains("Wait for the user's next request.") == true)
        #expect(
            transcript.turns == [
                ChatTurn(
                    firstEntryID: opener, startedAt: Self.date(1_800_000_767_401), endedAt: Self.date(1_800_000_776_638),
                    ending: .completed)
            ])

        // OpenCode's own compaction stays in the turn it runs in.
        let auto = Self.project([
            Self.prompt(1),
            Self.row("msg_auto", "compaction", seq: 2, #"{"status":"completed","reason":"auto","summary":"Earlier work."}"#),
            Self.step(3, items: [Self.text(0, "Done.")]), Self.idle(4),
        ])
        #expect(auto.turns.count == 1)
        #expect(auto.entries.map(\.id.rawValue) == ["oc:msg_u1", "oc:msg_auto:divider", "oc:msg_s3:0"])
        #expect(auto.recordedPrompts.map(\.text) == ["Go."])
    }

    /// OpenCode 2.0.32 records a `/compact` with nothing to compact as a
    /// failed compaction whose error says so, then an idle row (seq 363 and
    /// 365 as captured, their times moved). Nothing failed, so Chat shows
    /// OpenCode's words as a notice. Any other failure but a stop (below),
    /// or a refusal without a message, stays "Compaction failed", with the
    /// message as its detail.
    @Test func aCompactionWithNothingToCompactSaysSo() {
        let refused = Self.project([
            Self.row(
                "msg_c363", "compaction", seq: 363,
                #"{"status":"failed","reason":"manual","summary":null,"error":{"type":"compaction.unavailable","message":"Nothing to compact yet"},"time":{"created":1800000100363}}"#
            ),
            Self.row("msg_i365", "idle", seq: 365, #"{"time":{"created":1800000100365},"outcome":"succeeded"}"#),
        ])
        #expect(
            refused.entries == [
                ChatEntry(
                    id: ChatEntryID("oc:msg_c363"), sourceOffset: 363,
                    content: .notice(ChatNotice(kind: .command, title: "/compact"))),
                ChatEntry(
                    id: ChatEntryID("oc:msg_c363:notice"), sourceOffset: 363,
                    content: .notice(ChatNotice(kind: .system, title: "Nothing to compact yet"))),
            ])
        #expect(refused.turns.map(\.ending) == [.completed])

        // The entry a failed compaction with `error` gives.
        func outcome(_ error: String) -> ChatEntry.Content? {
            let data = #"{"status":"failed","reason":"auto","summary":null,"error":\#(error),"time":null}"#
            return Self.project([Self.row("msg_c1", "compaction", seq: 1, data)]).entries.last?.content
        }
        // Another type, written for the test.
        #expect(
            outcome(#"{"type":"provider.transport","message":"Unable to connect."}"#)
                == .notice(ChatNotice(kind: .error, title: "Compaction failed", detail: "Unable to connect.")))
        let failed = ChatEntry.Content.notice(ChatNotice(kind: .error, title: "Compaction failed"))
        #expect(outcome(#"{"type":"compaction.unavailable","message":null}"#) == failed)
        #expect(outcome(#"{"type":"compaction.unavailable","message":" "}"#) == failed)
        #expect(outcome(#"{"type":"provider.transport","message":null}"#) == failed)
        #expect(outcome("null") == failed)
    }

    /// OpenCode 2.0.32 records a `/compact` the user stopped as a failed
    /// compaction whose `aborted` error says "Compaction cancelled", then an
    /// `interrupted` idle row, and its own screen shows a muted
    /// "Compaction · cancelled". Nothing failed: Chat shows OpenCode's words
    /// as a notice, and the stop once, at its end. Not seen live: the
    /// compaction row is the one OpenCode's own test expects
    /// (`core/test/session-runner.test.ts:3018-3043`).
    @Test func aStoppedCompactionSaysItWasCancelled() {
        let cancelled = ChatEntry.Content.notice(ChatNotice(kind: .system, title: "Compaction cancelled"))
        let stopped = Self.project([
            Self.row(
                "msg_c40", "compaction", seq: 40,
                #"{"status":"failed","reason":"manual","summary":null,"error":{"type":"aborted","message":"Compaction cancelled"},"time":{"created":1800000100040}}"#
            ),
            Self.row("msg_i41", "idle", seq: 41, #"{"outcome":"interrupted"}"#),
        ])
        #expect(
            stopped.entries == [
                ChatEntry(
                    id: ChatEntryID("oc:msg_c40"), sourceOffset: 40,
                    content: .notice(ChatNotice(kind: .command, title: "/compact"))),
                ChatEntry(id: ChatEntryID("oc:msg_c40:notice"), sourceOffset: 40, content: cancelled),
                ChatEntry(
                    id: ChatEntryID("oc:msg_i41"), sourceOffset: 41,
                    content: .notice(ChatNotice(kind: .interrupted, title: "Interrupted"))),
            ])
        #expect(stopped.turns.map(\.ending) == [.interrupted])

        // Another message, written for the test, titles the notice.
        let byUser =
            #"{"status":"failed","reason":"manual","summary":null,"error":{"type":"aborted","message":"Stopped by the user"},"time":null}"#
        #expect(
            Self.project([Self.row("msg_c1", "compaction", seq: 1, byUser)]).entries.last?.content
                == .notice(ChatNotice(kind: .system, title: "Stopped by the user")))

        // Without a message, the notice keeps OpenCode's word for a stop.
        for message in ["null", #"" ""#] {
            let data =
                #"{"status":"failed","reason":"manual","summary":null,"error":{"type":"aborted","message":\#(message)},"time":null}"#
            #expect(Self.project([Self.row("msg_c1", "compaction", seq: 1, data)]).entries.last?.content == cancelled)
        }
    }

    // MARK: Tools

    @Test func patchFilesBecomeFileChanges() throws {
        let transcript = try Self.transcript("patch")
        let tools = Self.tools(transcript)
        try #require(tools.count == 2)
        let created = tools[0]
        #expect(created.kind == .fileEdit)
        #expect(created.status == .succeeded)
        #expect(created.title == "notes.txt")
        #expect(created.diff == ChatDiffStats(added: 3, removed: 0, files: 1))
        #expect(
            created.fileChanges?.files == [
                ChatFileChange(
                    path: "notes.txt", kind: .created, added: 3, removed: 0, lineCount: 3,
                    hunks: [
                        ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 3, lines: ["+alpha", "+beta", "+gamma"])
                    ])
            ])
        #expect(created.showsDiffAsOutput)
        let updated = tools[1]
        #expect(updated.diff == ChatDiffStats(added: 1, removed: 1, files: 1))
        #expect(
            updated.fileChanges?.files == [
                ChatFileChange(
                    path: "notes.txt", kind: .updated, added: 1, removed: 1, lineCount: 4,
                    hunks: [
                        ChatDiffHunk(
                            oldStart: 1, oldLines: 3, newStart: 1, newLines: 3,
                            lines: [" alpha", "-beta", "+BETA", " gamma"])
                    ])
            ])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed])
    }

    @Test func olderDiffShapesStillShowFiles() throws {
        let transcript = try Self.transcript("v1-names")
        let tools = Self.tools(transcript)
        #expect(tools.map(\.kind) == [.command, .agent, .fileEdit, .todo, .fileEdit])
        #expect(tools.map(\.status) == [.succeeded, .succeeded, .succeeded, .succeeded, .succeeded])
        try #require(tools.count == 5)
        #expect(tools[0].title == "ls")
        #expect(tools[1].title == "Count files")
        #expect(tools[1].subtitle == "general")
        let hunk = ChatDiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" alpha", "-beta", "+BETA", " gamma"])
        #expect(
            tools[2].fileChanges?.files == [
                ChatFileChange(path: "notes.txt", kind: .updated, added: 1, removed: 1, lineCount: 4, hunks: [hunk])
            ])
        #expect(tools[2].title == "notes.txt")
        // An edit's single-file `diff`, counted by its `filediff`.
        let path = "/Users/developer/work/heeler-tmp-chat/opencode-a/project/notes.txt"
        #expect(tools[4].title == path)
        #expect(tools[4].diff == ChatDiffStats(added: 1, removed: 1, files: 1))
        #expect(
            tools[4].fileChanges?.files == [
                ChatFileChange(
                    path: path, kind: .updated, added: 1, removed: 1, lineCount: 4,
                    hunks: [
                        ChatDiffHunk(
                            oldStart: 1, oldLines: 3, newStart: 1, newLines: 3,
                            lines: [" alpha", " BETA", "-gamma", "+GAMMA"])
                    ])
            ])
    }

    @Test(
        arguments: [
            ("shell", .command), ("bash", .command), ("interactive_bash", .command), ("execute", .command),
            ("read", .fileRead),
            ("edit", .fileEdit), ("patch", .fileEdit), ("apply_patch", .fileEdit), ("ast_grep_replace", .fileEdit),
            ("write", .fileWrite),
            ("grep", .search), ("glob", .search), ("codesearch", .search), ("grep_app_searchGitHub", .search),
            ("ast_grep_search", .search),
            ("list", .listing), ("ls", .listing),
            ("webfetch", .web), ("websearch", .web), ("websearch_web_search_exa", .web),
            ("subagent", .agent), ("task", .agent), ("call_omo_agent", .agent),
            ("question", .question),
            ("todowrite", .todo), ("todoread", .todo),
            ("mcp-resource", .mcp),
            ("skill", .other), ("opencode", .other), ("github_create_issue", .other),
        ] as [(String, ChatToolActivity.Kind)])
    func toolNamesMapToKinds(name: String, kind: ChatToolActivity.Kind) {
        #expect(OpenCodeToolSummary.kind(of: name) == kind)
    }

    @Test(
        arguments: [
            ("streaming", nil, .running),
            ("running", nil, .running),
            ("completed", nil, .succeeded),
            ("error", "The user declined this tool call", .declined),
            ("error", "The user dismissed this question", .declined),
            ("error", "Tool execution interrupted", .interrupted),
            ("error", "File not found: notes.txt", .failed),
        ] as [(String, String?, ChatToolActivity.Status)])
    func toolStatesReadAsChatStatuses(state: String, errorMessage: String?, status: ChatToolActivity.Status) {
        let aborted = errorMessage.map { !$0.hasPrefix("File not found") } ?? false
        let error = errorMessage.map { #"{"type":"\#(aborted ? "aborted" : "unknown")","message":"\#($0)"}"# } ?? "null"
        let transcript = Self.project(
            [
                Self.prompt(1),
                Self.step(
                    2, isFinal: false,
                    items: [Self.tool(0, name: "read", status: state, input: #"{"path":"notes.txt"}"#, error: error)]),
            ], activity: .working)
        #expect(Self.tools(transcript).map(\.status) == [status])
    }

    @Test func aShellExitCodeFailsTheRow() throws {
        let transcript = Self.project([
            Self.prompt(1),
            Self.step(
                2,
                items: [
                    Self.tool(
                        0, name: "shell", status: "completed", input: #"{"command":"make check"}"#,
                        meta: #"{"exit":2,"truncated":false}"#, output: "boom\n"),
                    Self.tool(
                        1, name: "shell", status: "completed", input: #"{"command":"true"}"#,
                        meta: #"{"exit":0,"truncated":false}"#, output: ""),
                ]),
            Self.idle(3),
        ])
        let tools = Self.tools(transcript)
        try #require(tools.count == 2)
        #expect(tools[0].status == .failed)
        #expect(tools[0].exitCode == 2)
        #expect(tools[0].title == "make check")
        #expect(tools[0].preview == ChatToolPreview(text: "boom\n", isTruncated: false))
        #expect(tools[1].status == .succeeded)
        #expect(tools[1].exitCode == nil)
    }

    @Test func aPendingQuestionCarriesItsQuestions() throws {
        let transcript = try Self.transcript("question-blocked", activity: .blocked)
        let question = ChatQuestion(
            header: "Color preference", text: "Which do you prefer, red or blue?",
            options: [
                ChatQuestion.Option(label: "red", detail: "Choose red"),
                ChatQuestion.Option(label: "blue", detail: "Choose blue"),
            ])
        let id = ChatEntryID("oc:msg_0a1b2c3d4e209ecxMyRuwgbXTu:0")
        #expect(
            transcript.pendingRequests == [
                ChatPendingRequest(
                    entryID: id, callID: "call_hcrSLLaaATjmTdXTbaOQlnIV", kind: .question, toolName: "question",
                    summary: "Which do you prefer, red or blue?", questions: [question])
            ])
        #expect(Self.tool(id, in: transcript)?.status == .awaitingApproval)
        #expect(Self.tool(id, in: transcript)?.questions == [question])
        #expect(transcript.turns.map(\.ending) == [nil])

        // Working, the call runs and asks nothing.
        let working = try Self.transcript("question-blocked", activity: .working)
        #expect(working.pendingRequests.isEmpty)
        #expect(Self.tool(id, in: working)?.status == .running)
    }

    @Test func anAnsweredQuestionShowsItsAnswer() throws {
        let transcript = try Self.transcript("question-answered")
        let tool = try #require(Self.tools(transcript).first)
        #expect(tool.status == .succeeded)
        #expect(tool.questions.map(\.answer) == ["blue"])
        #expect(tool.preview == ChatToolPreview(text: "Answered: blue", isTruncated: false))
        #expect(transcript.pendingRequests.isEmpty)
        #expect(transcript.turns.map(\.ending) == [.completed])
    }

    @Test func aSubagentToolShowsItsDescriptionAndStatus() throws {
        let transcript = try Self.transcript("subagent")
        let agent = try #require(Self.tools(transcript).first)
        #expect(agent.kind == .agent)
        #expect(agent.title == "Calculate two plus two")
        #expect(agent.subtitle == "general")
        #expect(agent.status == .succeeded)
        #expect(agent.preview == ChatToolPreview(text: "4", isTruncated: false))

        // A background subagent's call completes once it starts.
        let background = Self.project(
            [
                Self.prompt(1),
                Self.step(
                    2,
                    items: [
                        Self.tool(
                            0, name: "subagent", status: "completed",
                            input: #"{"agent":"explore","description":"Survey the tests","prompt":"Survey.","background":true}"#,
                            meta: #"{"sessionID":"ses_0a1b2c3d4e10fn1YIRc07x6WEB","status":"running","truncated":false}"#,
                            output: "The subagent is working in the background.")
                    ]),
            ], activity: .working)
        #expect(Self.tools(background).map(\.status) == [.started])
        #expect(Self.tools(background).map(\.title) == ["Survey the tests"])
    }

    @Test func skillAndOtherToolsAreTitledByName() {
        let transcript = Self.project([
            Self.prompt(1),
            Self.step(
                2,
                items: [
                    Self.tool(
                        0, name: "skill", status: "completed", input: #"{"id":"review"}"#,
                        meta: #"{"name":"Review","directory":"/skills/review"}"#, output: "Loaded."),
                    Self.tool(1, name: "github_create_issue", status: "completed", input: #"{"title":"Bug"}"#),
                ]),
            Self.idle(3),
        ])
        #expect(Self.tools(transcript).map(\.title) == ["Skill Review", "github_create_issue"])
    }

    // MARK: Steps

    @Test func retryingStepsShowARetryNotice() {
        let retry = #""retry":{"attempt":2,"at":1800000100500,"error":{"type":"provider","message":"Rate limited"}}"#
        let open = Self.project([Self.prompt(1), Self.step(2, isFinal: false, items: [], fields: retry)], activity: .working)
        #expect(
            open.entries.last
                == ChatEntry(
                    id: ChatEntryID("oc:msg_s2:retry"), sourceOffset: 2,
                    content: .notice(ChatNotice(kind: .system, title: "Retrying (attempt 2): Rate limited"))))

        // Once the step ends, the retry is history.
        let ended = Self.project([
            Self.prompt(1), Self.step(2, items: [Self.text(0, "Done.")], fields: retry + #","finish":"stop""#),
        ])
        #expect(!ended.entries.contains { $0.id == ChatEntryID("oc:msg_s2:retry") })
    }

    @Test(arguments: ["length", "content-filter"])
    func outputLimitAndFilterEndingsSayWhy(finish: String) {
        let transcript = Self.project([
            Self.prompt(1), Self.step(2, items: [Self.text(0, "Partial")], fields: #""finish":"\#(finish)""#),
            Self.idle(3),
        ])
        let why = finish == "length" ? "The model stopped at its output limit." : "The provider filtered the reply."
        #expect(
            transcript.entries.last
                == ChatEntry(
                    id: ChatEntryID("oc:msg_s2:finish"), sourceOffset: 2,
                    content: .notice(ChatNotice(kind: .system, title: why))))
    }

    @Test func aFailedTurnSaysWhyOnce() {
        let failed = #"{"outcome":"failed","error":{"type":"provider","message":"Model not found: gpt-0"}}"#
        let transcript = Self.project([
            Self.prompt(1),
            Self.step(
                2, items: [],
                fields: #""finish":"error","error":{"type":"provider","message":"Model not found: gpt-0"}"#),
            Self.row("msg_idle", "idle", seq: 3, failed),
        ])
        #expect(
            transcript.entries.dropFirst().map(\.id.rawValue) == ["oc:msg_s2:error"])
        #expect(
            transcript.entries.last?.content == .notice(ChatNotice(kind: .error, title: "Model not found: gpt-0")))
        #expect(transcript.turns.map(\.ending) == [.failed])

        // A turn that failed with no step saying so says it at its end.
        let bare = Self.project([Self.prompt(1), Self.row("msg_idle", "idle", seq: 3, failed)])
        #expect(
            bare.entries.last
                == ChatEntry(
                    id: ChatEntryID("oc:msg_idle"), sourceOffset: 3,
                    content: .notice(ChatNotice(kind: .error, title: "Model not found: gpt-0"))))
        #expect(bare.turns.map(\.ending) == [.failed])
    }

    @Test func emptyTextItemsAreHidden() throws {
        // The step after `/new ` starts with an empty reasoning item.
        let transcript = try Self.transcript("undo-before")
        #expect(!transcript.entries.contains { $0.id == ChatEntryID("oc:msg_0a1b2c3d4e501nQ3DdIbolthRf:0") })
        #expect(transcript.entries.contains { $0.id == ChatEntryID("oc:msg_0a1b2c3d4e501nQ3DdIbolthRf:1") })

        // Text fills in only when its block ends.
        let open = Self.project(
            [Self.prompt(1), Self.step(2, isFinal: false, items: [#"{"_i":0,"type":"text","text":"","n":0}"#])],
            activity: .working)
        #expect(open.entries.map(\.id.rawValue) == ["oc:msg_u1"])
    }

    @Test func longTextSaysItWasTruncated() {
        let transcript = Self.project([
            Self.row("msg_u1", "user", seq: 1, #"{"text":"Long prompt ","n":300000,"files":[]}"#),
            Self.step(
                2,
                items: [
                    #"{"_i":0,"type":"text","text":"Long reply","n":70000}"#,
                    #"{"_i":1,"type":"reasoning","text":"Long thought","n":70000}"#,
                ]),
            Self.inbox(#"{"id":"msg_q","type":"user","delivery":"steer","seq":3,"text":"Long steer","n":20000,"files":[]}"#),
        ])
        #expect(
            transcript.entries.map(\.content) == [
                .user(ChatUserMessage(text: "Long prompt\n\n(truncated in Chat)")),
                .assistant(ChatAssistantMessage(text: "Long reply\n\n(truncated in Chat)")),
                .reasoning(ChatReasoning(text: "Long thought\n\n(truncated in Chat)")),
                .user(ChatUserMessage(text: "Long steer\n\n(truncated in Chat)", wasQueued: true)),
            ])
        // The row's prompt echoes by the text it keeps; the queued one only
        // once its row holds more.
        #expect(transcript.recordedPrompts == [ChatRecordedPrompt(offset: 1, text: "Long prompt ", entryID: ChatEntryID("oc:msg_u1"))])
    }

    @Test func aShortenedToolOutputSaysTheFullOutputStaysOnTheHost() {
        func preview(outputLength: Int) -> ChatToolPreview? {
            Self.tools(
                Self.project([
                    Self.prompt(1),
                    Self.step(
                        2,
                        items: [
                            Self.tool(
                                0, name: "grep", status: "completed", input: #"{"pattern":"TODO"}"#,
                                meta: #"{"truncated":true}"#, output: "a.swift:1: TODO\n", outputLength: outputLength)
                        ]),
                    Self.idle(3),
                ])
            ).first?.preview
        }
        #expect(
            preview(outputLength: 16)
                == ChatToolPreview(
                    text: "a.swift:1: TODO\n[OpenCode shortened this output. The full output stays on the Host.]",
                    isTruncated: false))
        // Cut again on the way, the row reads on when expanded.
        #expect(preview(outputLength: 20_000) == ChatToolPreview(text: "a.swift:1: TODO\n", isTruncated: true))
    }

    @Test func anExpandedOutputReadsTheRowAgain() throws {
        let fixture = try OpenCodeStoreFixture.named("pong")
        let harness = try OpenCodeSQLiteHarness(fixture)
        let session = try #require(fixture.sessionID)
        let output = (1...3_000).map { "line \($0)" }.joined(separator: "\n")
        let time = 1_800_000_100_000
        let step: [String: Any] = [
            "type": "assistant", "agent": "build", "model": ["id": "gpt-6-astra", "providerID": "openai"],
            "finish": "stop", "time": ["created": time, "completed": time + 9],
            "content": [
                [
                    "type": "tool", "id": "call_long", "name": "shell",
                    "state": [
                        "status": "completed", "input": ["command": "seq 3000"],
                        "content": [["type": "text", "text": output]], "metadata": ["exit": 0, "truncated": false],
                    ],
                    "time": ["created": time, "completed": time + 8],
                ]
            ],
        ]
        try harness.insert(
            into: "session_message",
            [
                "id": .text("msg_inserted_20"), "session_id": .text(session.rawValue), "type": .text("assistant"),
                "seq": .integer(20), "time_created": .integer(Int64(time)), "time_updated": .integer(Int64(time)),
                "data": .text(String(decoding: try JSONSerialization.data(withJSONObject: step), as: UTF8.self)),
            ])
        let records = try harness.records(OpenCodeQuery(session: session, kind: .tail(budget: 524_288)))
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(Self.lines(records))
        let transcript = reducer.transcript(ChatProjectionContext())
        Self.expectNoMalformedLines(transcript)
        let tool = try #require(Self.tools(transcript).first)
        let shown = try #require(tool.preview)
        #expect(shown.isTruncated)
        #expect(tool.previewIsIncomplete)
        let row = try #require(records.rows.first { $0.seq == 20 })
        #expect(tool.output == ChatOutputReference(offset: 20, length: row.line.count))

        let again = try harness.records(OpenCodeQuery(session: session, kind: .row(seq: 20, outputLimit: 256 << 10)))
        let line = ChatLine(offset: 20, data: try #require(again.rows.first).line)
        let expanded = ChatToolPreview.$limits.withValue(ChatToolPreview.expandedLimits) {
            (reducer.output(of: line, for: tool), ChatToolPreview(capping: output))
        }
        #expect(expanded.0 == .preview(expanded.1, fileChanges: nil))
        #expect(expanded.1.text.count > shown.text.count)
        #expect(expanded.1.text.hasPrefix(shown.text))
        // A line that no longer holds the call reads as gone.
        var other = tool
        other.callID = "call_gone"
        #expect(reducer.output(of: line, for: other) == nil)
    }

    // MARK: Reads

    @Test func prependAndRepeatedReadsConvergeWithoutDuplicates() throws {
        let lines = try Self.lines("steer")
        let expected = Self.project(lines)
        // The source puts its session and inbox lines past every row.
        let older = lines.filter { $0.offset < 187 }
        let newer = lines.filter { $0.offset >= 187 }
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(newer)
        let window = reducer.transcript(ChatProjectionContext(windowStart: 187))
        #expect(window.needsOlderHistory)
        reducer.prepend(older)
        reducer.append(newer)
        reducer.prepend(older)
        #expect(reducer.transcript(ChatProjectionContext(activity: .idle)) == expected)

        // A window that starts inside a turn its idle row closes ends the
        // turn above it.
        var inside = OpenCodeTranscriptReducer()
        inside.append(lines.filter { $0.offset >= 188 })
        let tail = inside.transcript(ChatProjectionContext(windowStart: 188))
        #expect(tail.turns.isEmpty)
        #expect(tail.precedingTurnEnd == ChatTurnEnd(ending: .completed, endedAt: Self.date(1_800_000_692_097)))
    }

    @Test func entryIDsAreStableAcrossReads() throws {
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(try Self.lines("steer-queued"))
        let first = reducer.transcript(ChatProjectionContext(activity: .working)).entries.map(\.id)
        reducer.append(try Self.lines("steer"))
        let second = reducer.transcript(ChatProjectionContext()).entries.map(\.id)
        #expect(Set(first).isSubset(of: Set(second)))
        #expect(Self.project(try Self.lines("steer")).entries.map(\.id) == second)
        #expect(
            second.map(\.rawValue) == [
                "oc:msg_0a1b2c3d4e10bMU8QeC6LKaTL1", "oc:msg_0a1b2c3d4e20NVcJRLTUWz3eOd:0",
                "oc:msg_0a1b2c3d4e20NVcJRLTUWz3eOd:1", "oc:msg_0a1b2c3d4e30c6n5ci7hO7j2rp",
                "oc:msg_0a1b2c3d4e40CyCgt7ZzrFc9ru:0",
            ])
    }

    @Test func recordedPromptsCoverUserRowsInboxItemsAndCompactions() throws {
        let queued = try Self.transcript("two-sessions")
        #expect(
            queued.recordedPrompts == [
                ChatRecordedPrompt(
                    offset: 4, text: "Reply with exactly the word apple.",
                    entryID: ChatEntryID("oc:msg_0a1b2c3d4110A1b2C3d4E5f6G7")),
                ChatRecordedPrompt(
                    offset: 14, text: "Then reply with banana.", entryID: ChatEntryID("oc:msg_0a1b2c3d4e04V2w3X4y5Z6a7B8")),
            ])
        let compaction = try Self.transcript("compact")
        #expect(
            compaction.recordedPrompts == [
                ChatRecordedPrompt(offset: 210, text: "/compact", entryID: ChatEntryID("oc:msg_0a1b2c3d4e107YWDFivnBRVaqN"))
            ])
        // OpenCode stores a prompt untrimmed; the bubble trims it.
        let untrimmed = try Self.transcript("undo-before")
        #expect(untrimmed.recordedPrompts.map(\.text).contains("/new "))
        #expect(
            untrimmed.entries.first { $0.id == ChatEntryID("oc:msg_0a1b2c3d4e40bnybbDUaT4t4KD") }?.content
                == .user(ChatUserMessage(text: "/new")))
        // A prompt of only an image has no text to match a send by.
        let image = Self.project([
            Self.row(
                "msg_u1", "user", seq: 1,
                #"{"text":"","n":0,"files":[{"name":"shot.png","mime":"image/png","mention":0}]}"#)
        ])
        #expect(
            image.recordedPrompts == [
                ChatRecordedPrompt(offset: 1, text: "", entryID: ChatEntryID("oc:msg_u1"), pastedImagePaths: [])
            ])
        #expect(image.entries.map(\.content) == [.user(ChatUserMessage(text: "", attachmentLabels: ["shot.png"]))])
    }

    // MARK: Images

    /// OpenCode 2.0.32 resolves a relative read against the session's folder
    /// at the time, and names the image it returned with the path it read.
    @Test func imageReadsRecordTheFileTheyShowed() {
        func read(_ seq: Int64, input: String, output: String, image: String? = nil) -> ChatLine {
            Self.step(
                seq, items: [Self.tool(0, name: "read", status: "completed", input: input, output: output, image: image)])
        }
        let moved = Self.row(
            "msg_m3", "location-switched", seq: 3,
            #"{"location":{"directory":"/work/b"},"previous":{"location":{"directory":"/work/a"}}}"#)
        let transcript = Self.project([
            Self.session(directory: "/work/b"),
            read(1, input: #"{"path":"shots/a.png"}"#, output: "Image read successfully", image: "shots/a.png"),
            moved,
            // Read under another case: the image names the file it found.
            read(4, input: #"{"path":"shots/B.PNG"}"#, output: "Image read successfully", image: "shots/b.png"),
            read(5, input: #"{"path":"notes.txt"}"#, output: "Read file notes.txt, lines 1-2"),
            read(6, input: #"{"path":"guide.pdf"}"#, output: "PDF read successfully"),
            // A session imported from 1.x records absolute paths and no image.
            read(7, input: #"{"filePath":"/work/b/old.png"}"#, output: "Image read successfully"),
        ])
        #expect(
            Self.tools(transcript).map(\.imagePath) == [
                "/work/a/shots/a.png", "/work/b/shots/b.png", nil, nil, "/work/b/old.png",
            ])

        // A move that names no earlier folder leaves the reads before it
        // unplaced rather than guessed.
        let unplaced = Self.project([
            Self.session(directory: "/work/b"),
            read(1, input: #"{"path":"a.png"}"#, output: "Image read successfully", image: "a.png"),
            Self.row("msg_m2", "location-switched", seq: 2, #"{"time":{"created":1800000100002}}"#),
            read(3, input: #"{"path":"b.png"}"#, output: "Image read successfully", image: "b.png"),
        ])
        #expect(Self.tools(unplaced).map(\.imagePath) == [nil, "/work/b/b.png"])
    }

    // MARK: Other rows

    @Test func otherRowTypesShowAsNotices() throws {
        let transcript = try Self.transcript("row-types", activity: .working, invalidRows: 1)
        #expect(
            transcript.entries.map(\.content) == [
                .notice(ChatNotice(kind: .shellCommand, title: "git status", detail: "fatal: not a git repository\n")),
                .notice(ChatNotice(kind: .shellCommand, title: "sleep 60")),
                .notice(ChatNotice(kind: .taskNotification, title: "Shell job", detail: "Background shell job finished.")),
                .notice(ChatNotice(kind: .system, title: "Reminder")),
                .notice(ChatNotice(kind: .command, title: "Skill Review")),
                .notice(
                    ChatNotice(
                        kind: .system, title: "Moved to /Users/developer/work/heeler-tmp-chat/opencode-a/project/sub")),
                .notice(ChatNotice(kind: .modelChange, title: "Model: gpt-6-astra")),
                .assistant(ChatAssistantMessage(text: "Still working.")),
            ])
        #expect(transcript.title == "Row types")
        #expect(transcript.turns.isEmpty)

        // OpenCode tells the model about a command the user ran in shell
        // mode, which its own row already shows.
        let echo = Self.row(
            "msg_echo", "synthetic", seq: 30,
            #"{"text":"The following shell command was executed by the user:\n<shell id=\"sh_1\" state=\"completed\" command=\"git status\">\nfatal\n</shell>","n":120,"description":null,"metadata":{"source":"shell","childID":null,"state":"completed","exit":128,"notice":null,"jobID":null,"shellID":"sh_1","truncated":0}}"#
        )
        let echoed = Self.project(try Self.lines("row-types") + [echo])
        #expect(!echoed.entries.contains { $0.id == ChatEntryID("oc:msg_echo") })
    }

    /// OpenCode tells the model it entered or left Plan mode with a
    /// `synthetic` row of only text, and its own screen draws no such row,
    /// so Chat shows the agent switch alone. The rows are the in-app
    /// check's switch to Plan and back.
    @Test func planModeRemindersAreHidden() {
        let transcript = Self.project([
            Self.row("msg_a450", "agent-switched", seq: 450, #"{"agent":"plan","previous":"build"}"#),
            Self.synthetic(454, text: Self.planReminder),
            Self.prompt(455), Self.step(456, items: [Self.text(0, "plum")], fields: #""finish":"stop""#),
            Self.idle(461),
            Self.row("msg_a473", "agent-switched", seq: 473, #"{"agent":"build","previous":"plan"}"#),
            Self.synthetic(477, text: Self.buildReminder),
            Self.prompt(478), Self.step(479, items: [Self.text(0, "apple")], fields: #""finish":"stop""#),
            Self.idle(484),
        ])
        #expect(
            transcript.entries.map(\.content) == [
                .notice(ChatNotice(kind: .modelChange, title: "Agent: plan")),
                .user(ChatUserMessage(text: "Go.")), .assistant(ChatAssistantMessage(text: "plum")),
                .notice(ChatNotice(kind: .modelChange, title: "Agent: build")),
                .user(ChatUserMessage(text: "Go.")), .assistant(ChatAssistantMessage(text: "apple")),
            ])
        #expect(transcript.turns.map(\.ending) == [.completed, .completed])

        // A description or metadata keeps the notice; a blank description
        // is none.
        let metadata =
            #"{"source":null,"childID":null,"state":null,"exit":null,"notice":null,"jobID":null,"shellID":null,"truncated":null}"#
        let notes = Self.project([
            Self.synthetic(1, text: "Instructions from: AGENTS.md", description: "Loaded AGENTS.md"),
            Self.synthetic(2, text: "For the model.", metadata: metadata),
            Self.synthetic(3, text: "For the model alone.", description: " "),
        ])
        #expect(
            notes.entries.map(\.content) == [
                .notice(ChatNotice(kind: .system, title: "Loaded AGENTS.md", detail: "Instructions from: AGENTS.md")),
                .notice(ChatNotice(kind: .system, title: "Note", detail: "For the model.")),
            ])
    }

    @Test func unexpectedValueTypesCostOnlyTheirField() throws {
        let transcript = try Self.transcript("odd-types")
        #expect(
            transcript.entries.map(\.id.rawValue) == [
                "oc:msg_0a1b2c3d4e10R2t3Y4u5I6o7P8", "oc:msg_0a1b2c3d4e20A9s0D1f2G3h4J5:0",
                "oc:msg_0a1b2c3d4e20A9s0D1f2G3h4J5:1", "oc:msg_0a1b2c3d4e20A9s0D1f2G3h4J5:4",
                "oc:msg_0a1b2c3d4e40S5d6F7g8H9j0K1",
            ])
        #expect(
            transcript.entries.first?.content
                == .user(ChatUserMessage(text: "Describe diagram.png.", attachmentLabels: ["diagram.png"])))
        #expect(transcript.entries[1].content == .reasoning(ChatReasoning(text: "Checking the file.")))
        let shell = try #require(Self.tools(transcript).first)
        #expect(shell.title == "shell")
        #expect(shell.status == .failed)
        #expect(shell.preview == ChatToolPreview(text: "Command failed with exit code 2", isTruncated: false))
        #expect(transcript.turns.map(\.ending) == [.completed])
        #expect(transcript.unrecordedEntryIDs == [ChatEntryID("oc:msg_0a1b2c3d4e40S5d6F7g8H9j0K1")])
    }

    @Test func unknownAndInvalidRowsAreCountedNotShown() throws {
        let lines = try Self.lines("row-types") + [ChatLine(offset: 30, data: Data("not json".utf8))]
        let transcript = Self.project(lines)
        #expect(
            transcript.diagnostics
                == ChatTranscriptDiagnostics(invalidLines: 2, oversizedLines: 0, unknownRecordTypes: ["future-kind"]))
        #expect(
            !transcript.entries.contains {
                $0.id.rawValue.hasPrefix("oc:msg_0a1b2c3d4e80A2s3D4f5G6h7J8")
                    || $0.id.rawValue.hasPrefix("oc:msg_0a1b2c3d4e90K9l0Z1x2C3v4B5")
            })
    }

    @Test func aTooLargeRowSaysSo() {
        let transcript = Self.project([
            ChatLine(
                offset: 1,
                data: Data(
                    #"{"k":"row","id":"msg_bigu","type":"user","seq":1,"tc":1800000100001,"tu":1800000100001,"f":true,"big":1500000}"#
                        .utf8)),
            ChatLine(
                offset: 2,
                data: Data(
                    #"{"k":"row","id":"msg_big","type":"assistant","seq":2,"tc":1800000100002,"tu":1800000100002,"f":true,"big":2000000}"#
                        .utf8)),
            Self.idle(3),
        ])
        #expect(
            transcript.entries == [
                ChatEntry(
                    id: ChatEntryID("oc:msg_bigu"), sourceOffset: 1,
                    content: .notice(ChatNotice(kind: .system, title: "This message is too large to show in Chat."))),
                ChatEntry(
                    id: ChatEntryID("oc:msg_big"), sourceOffset: 2,
                    content: .notice(ChatNotice(kind: .system, title: "This step is too large to show in Chat."))),
            ])
        #expect(transcript.diagnostics == ChatTranscriptDiagnostics(oversizedLines: 2))
        #expect(transcript.turns.map(\.firstEntryID) == [ChatEntryID("oc:msg_bigu")])
        #expect(transcript.turns.map(\.ending) == [.completed])
        #expect(transcript.recordedPrompts.isEmpty)
        #expect(transcript.latestPromptOffset == 1)
    }

    // MARK: Session

    @Test func aNewerSessionVersionIsUnsupported() {
        var reducer = OpenCodeTranscriptReducer()
        reducer.append([Self.session(version: "2.0.32")])
        #expect(reducer.unsupportedFormat == nil)
        reducer.append([Self.session(version: "3.0.0")])
        #expect(reducer.unsupportedFormat == "OpenCode session version 3.0.0")
    }

    @Test func fallbackTitlesAreNoTitle() {
        let titles: [(String, String?)] = [
            ("New session - 2026-07-30T18:45:03.662Z", nil),
            ("Child session - 2026-07-30T18:45:03.662Z", nil),
            ("", nil),
            ("New session - custom", "New session - custom"),
            ("Pong", "Pong"),
        ]
        for (title, shown) in titles {
            #expect(Self.project([Self.session(title: title)]).title == shown, "\(title)")
        }
        let untitled = ChatLine(
            offset: 100, data: Data(#"{"k":"session","id":"ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9","title":null}"#.utf8))
        #expect(Self.project([untitled]).title == nil)
    }

    // MARK: Helpers

    /// The id the steer in `rows-steer` carries, queued and promoted.
    private static let steerID = ChatEntryID("oc:msg_0a1b2c3d4e30c6n5ci7hO7j2rp")

    /// The reminders OpenCode 2.0.32 writes on a switch to Plan mode and
    /// back, as captured.
    private static let planReminder = """
        <system-reminder>
        You are in Plan mode. Discuss the plan with the user directly in the conversation. Do not create or update plan files unless the user explicitly asks you to; when they do, write them only in:
        /Users/developer/.opencode/plan

        Do not modify any other files or ask a subagent to do so.

        You remain in Plan mode until the user switches agents. If the user asks you to implement changes, do not do so. Tell them they need to switch agents.
        </system-reminder>
        """
    private static let buildReminder = """
        <system-reminder>
        You are NO LONGER in Plan mode. The previous Plan restrictions no longer apply. Any Plan mode instructions from earlier in this conversation are no longer active.
        </system-reminder>
        """

    /// `rows-<scenario>.jsonl` projected, with no malformed line among it.
    /// `invalidRows` counts rows the fixture holds whose data is not JSON.
    private static func transcript(
        _ scenario: String, activity: ChatAgentActivity = .idle, invalidRows: Int = 0
    ) throws -> ChatTranscript {
        let transcript = project(try lines(scenario), activity: activity)
        #expect(transcript.diagnostics.invalidLines == invalidRows, "rows-\(scenario).jsonl")
        #expect(transcript.diagnostics.oversizedLines == 0, "rows-\(scenario).jsonl")
        return transcript
    }

    private static func expectNoMalformedLines(_ transcript: ChatTranscript) {
        #expect(transcript.diagnostics.invalidLines == 0)
        #expect(transcript.diagnostics.oversizedLines == 0)
    }

    private static func project(_ lines: [ChatLine], activity: ChatAgentActivity = .idle) -> ChatTranscript {
        var reducer = OpenCodeTranscriptReducer()
        reducer.append(lines)
        return reducer.transcript(ChatProjectionContext(activity: activity))
    }

    /// The lines the record source hands the reducer for
    /// `rows-<scenario>.jsonl`: each row at its `seq`, the session and inbox
    /// lines at the read offset past the store's event counter.
    private static func lines(_ scenario: String) throws -> [ChatLine] {
        let readOffset = UInt64(max(try OpenCodeStoreFixture.named(scenario).eventSeq ?? 0, 0)) + 1
        return try ChatFixture.lines("opencode/rows-\(scenario).jsonl").map { line in
            let value = try JSONDecoder().decode(JSONValue.self, from: line.data)
            guard case .number(let seq)? = value["seq"] else { return ChatLine(offset: readOffset, data: line.data) }
            return ChatLine(offset: UInt64(seq), data: line.data)
        }
    }

    /// A query's records as the source hands them on.
    private static func lines(_ records: OpenCodeRecords) -> [ChatLine] {
        let readOffset = UInt64(max(records.eventSeq ?? 0, 0)) + 1
        return [records.sessionLine, records.inboxLine].compactMap { $0 }.map { ChatLine(offset: readOffset, data: $0) }
            + records.rows.map { ChatLine(offset: UInt64($0.seq), data: $0.line) }
    }

    /// A session OpenCode 2 imported from 1.x, as its importer writes one:
    /// the 1.x version, `seq` from 0, and no `idle` rows. Its turns end
    /// with a stop, an Esc stop and a provider error, and the last never
    /// ends.
    private static let imported: [ChatLine] = [
        session(title: "Imported", version: "1.3.10"),
        prompt(0),
        step(1, items: [tool(0, name: "bash", status: "completed")], fields: #""finish":"tool-calls""#),
        step(2, items: [text(0, "One.")], fields: #""finish":"stop","time":{"completed":1800000100102}"#),
        prompt(3),
        step(
            4, items: [text(0, "Partial")],
            fields: #""error":{"type":"aborted","message":"The operation was aborted."},"time":{"completed":1800000100104}"#),
        prompt(5),
        step(
            6, items: [],
            fields: #""finish":"error","error":{"type":"provider.error","message":"Rate limited"},"time":{"completed":1800000100106}"#),
        prompt(7),
        step(8, items: [text(0, "Four.")], fields: #""finish":"stop","time":{"completed":1800000100108}"#),
    ]

    private static func prompts(_ transcript: ChatTranscript) -> [ChatUserMessage] {
        transcript.entries.compactMap { entry -> ChatUserMessage? in
            guard case .user(let message) = entry.content else { return nil }
            return message
        }
    }

    private static func tools(_ transcript: ChatTranscript) -> [ChatToolActivity] {
        transcript.entries.compactMap { entry -> ChatToolActivity? in
            guard case .tool(let tool) = entry.content else { return nil }
            return tool
        }
    }

    private static func tool(_ id: ChatEntryID, in transcript: ChatTranscript) -> ChatToolActivity? {
        guard case .tool(let tool)? = transcript.entries.first(where: { $0.id == id })?.content else { return nil }
        return tool
    }

    private static func isNotice(_ entry: ChatEntry) -> Bool {
        guard case .notice = entry.content else { return false }
        return true
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    // MARK: Lines

    /// A row line holding `data`, a JSON object's text.
    private static func row(_ id: String, _ type: String, seq: Int64, isFinal: Bool = true, _ data: String) -> ChatLine {
        let time = 1_800_000_100_000 + seq
        return ChatLine(
            offset: UInt64(seq),
            data: Data(
                #"{"k":"row","id":"\#(id)","type":"\#(type)","seq":\#(seq),"tc":\#(time),"tu":\#(time),"f":\#(isFinal),"d":\#(data)}"#
                    .utf8))
    }

    private static func prompt(_ seq: Int64) -> ChatLine {
        row("msg_u\(seq)", "user", seq: seq, #"{"text":"Go.","n":3,"files":[]}"#)
    }

    private static func idle(_ seq: Int64) -> ChatLine {
        row("msg_i\(seq)", "idle", seq: seq, #"{"outcome":"succeeded"}"#)
    }

    /// A `synthetic` row as the query prints it: `metadata` is the object it
    /// keeps, or null when the row has none.
    private static func synthetic(
        _ seq: Int64, text: String, description: String? = nil, metadata: String = "null"
    ) -> ChatLine {
        let described = description.map(json) ?? "null"
        return row(
            "msg_n\(seq)", "synthetic", seq: seq,
            #"{"text":\#(json(text)),"n":\#(text.unicodeScalars.count),"description":\#(described),"metadata":\#(metadata)}"#)
    }

    /// An assistant row with `items`, plus `fields` (JSON members) beside
    /// its content.
    private static func step(_ seq: Int64, isFinal: Bool = true, items: [String], fields: String = "") -> ChatLine {
        let extra = fields.isEmpty ? "" : "," + fields
        return row(
            "msg_s\(seq)", "assistant", seq: seq, isFinal: isFinal,
            #"{"content":[\#(items.joined(separator: ","))]\#(extra)}"#)
    }

    private static func text(_ index: Int, _ text: String) -> String {
        #"{"_i":\#(index),"type":"text","text":\#(json(text)),"n":\#(text.unicodeScalars.count)}"#
    }

    private static func tool(
        _ index: Int, name: String, status: String, input: String = "{}", error: String = "null",
        meta: String = "null", output: String? = nil, outputLength: Int? = nil, image: String? = nil
    ) -> String {
        let length = outputLength ?? output?.unicodeScalars.count
        return
            #"{"_i":\#(index),"type":"tool","id":"call_\#(index)","name":"\#(name)","status":"\#(status)","input":\#(input),"error":\#(error),"meta":\#(meta),"out":\#(output.map(json) ?? "null"),"outN":\#(length.map(String.init) ?? "null"),"image":\#(image.map(json) ?? "null")}"#
    }

    private static func inbox(_ items: String...) -> ChatLine {
        ChatLine(offset: 100, data: Data(#"{"k":"inbox","items":[\#(items.joined(separator: ","))],"more":0}"#.utf8))
    }

    private static func session(
        title: String = "Pong", version: String = "2.0.32", directory: String? = nil
    ) -> ChatLine {
        ChatLine(
            offset: 100,
            data: Data(
                #"{"k":"session","id":"ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9","parent":null,"title":\#(json(title)),"version":"\#(version)","directory":\#(directory.map(json) ?? "null"),"revertMessage":null,"revertFiles":null,"revertSeq":null,"updated":1800000000000}"#
                    .utf8))
    }

    private static func json(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
