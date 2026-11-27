import Foundation
import Testing

@testable import Heeler

@Suite("Devin Chat")
struct DevinChatTests {
    @Test func stopNeedsTheOpenTurnAndInterruptFooterWhenTheLastReportWasIdle() throws {
        let screen = ANSIScreenDecoder.decode("""
            Generating (esc twice to interrupt)
            ─────────────────────────
            ❭ Guide Devin while it works
            ─────────────────────────
            SWE-2 High
            """)
        #expect(DevinInputBox.stop(.init(screen: screen, activity: .idle, hasVerifiedTurn: true)) == .press)
        for context in [
            ChatStopContext(screen: screen, activity: .idle),
            .init(screen: screen, activity: .blocked, hasVerifiedTurn: true),
            .init(screen: try ScreenFixture.screen("devin-idle"), activity: .idle, hasVerifiedTurn: true),
        ] {
            if case .press = DevinInputBox.stop(context) { Issue.record("Unexpected Stop on a stale or blocked turn") }
        }
    }

    @Test func ordinaryNewAgentUsesADedicatedWriterAndPreservesPresets() {
        let plain = AgentLaunchRequest(kind: "devin", name: "review")
        #expect(DevinSession.localLaunch(plain, platform: .posix).arguments == ["--process-model=in-process"])
        #expect(DevinSession.localLaunch(plain, platform: .nativeWindows) == plain)
        let cloud = AgentLaunchRequest(kind: "devin", name: "review", arguments: ["--cloud"])
        #expect(DevinSession.localLaunch(cloud, platform: .posix) == cloud)
        let preset = AgentLaunchRequest(kind: "devin", name: "review", environment: ["XDG_DATA_HOME": "/work/account"])
        #expect(DevinSession.localLaunch(preset, platform: .posix) == preset)
    }

    @Test func bindsOnlyTheForegroundWritersOwnValidLock() async throws {
        let files = VirtualHostFiles(home: "/home/qa")
        let folder = "/home/qa/.local/share/devin/cli"
        let lock = folder + "/session_locks/steady-willow.lock"
        let ui = HostProcessReader.Facts(start: .value("ui-start"), arguments: .value([]), name: "devin")
        let acp = HostProcessReader.Facts(start: .value("writer-start"), openFiles: .value([lock]),
            arguments: .value(["acp", "--process-model=in-process"]), parent: "41", name: "devin")
        func target(_ facts: [String: HostProcessReader.Facts], members: [String]) async throws -> DroidDialogTarget? {
            try await DevinSession.target(root: "41", members: members, facts: facts, directory: "/work", scope: "one", files: files.hostFiles())
        }
        await files.write("52\n", at: lock)
        let bound = try #require(try await target(["41": ui, "52": acp], members: ["41", "52"]))
        #expect(bound.sessionID == "steady-willow" && bound.transcriptFolder == folder)
        #expect(bound.start == "writer-start" && bound.scope.contains("ui-start"))
        #expect(try await target(["41": ui], members: ["41"])?.sessionID == nil)
        await files.write("72\n", at: lock)
        #expect(try await target(["41": ui, "52": acp], members: ["41", "52"]) == nil)
        #expect(try await target(["41": ui, "52": acp, "53": acp], members: ["41", "52", "53"]) == nil)
        #expect(DevinSession.id("../another.lock") == nil)
    }

    @Test func directoryTrustNeedsTheCompleteScreenAndSameDirectory() throws {
        let screen = try ScreenFixture.screen("devin-trust")
        let card = try #require(DevinDialog.parse(screen).dialog)
        #expect(card.kind == .devinWorkspaceTrust && card.subject.workspacePath == "/tmp/heeler-qa")
        #expect(card.options.map(\.role) == [.trust, .exitProgram])
        #expect(try DevinDialog.plan(.choose(ordinal: 2), card, call: nil).steps == [.keys(["down"]), .expect(.focus(ordinal: 2)), .keys(["enter"])])
        var target = DroidDialogTarget(scope: "pane", pid: "12", start: "a", directory: "/tmp/heeler-qa", sessionID: nil)
        #expect(target.shows(card))
        target.directory += "-other"
        #expect(!target.shows(card))
        #expect(DevinDialog.parse(.init(rows: Array(screen.rows.dropFirst()))).dialog == nil)
    }

    @Test func permissionsKeepTheFullFileAndTheSelectedScope() throws {
        let write = try #require(DevinDialog.parse(ScreenFixture.screen("devin-write")).dialog)
        #expect(write.subject.filePath == "./approval-b.txt")
        #expect(write.options.map(\.label) == ["Allow", "Accept edits mode", "Bypass mode", "Deny"])
        #expect(write.options[0].detail == "Write(/tmp/heeler-qa)")
        #expect(throws: DialogPlanError.self) { try DevinDialog.plan(.choose(ordinal: 1), write, call: nil) }
        let once = try #require(DevinDialog.parse(ScreenFixture.screen("devin-exec")).dialog)
        #expect(once.subject.command == "sleep 2 && echo HEELER_SCOPE_9")
        #expect(once.options.prefix(4).map(\.label) == ["Allow · Once", "Allow · Session", "Allow · Project", "Allow · Always"])
        #expect(once.focus.focusedOrdinal == 1)
        let wrapped = try #require(DevinDialog.parse(ScreenFixture.screen("devin-exec-wrapped")).dialog)
        let command = #"sleep 1 && printf "%s %s %s" HEELER_LONG_COMMAND_ALPHA HEELER_LONG_COMMAND_BETA HEELER_LONG_COMMAND_GAMMA ."#
        var request = ChatPendingRequest(entryID: .init("exec"), callID: "long", kind: .command, toolName: "exec", summary: command)
        #expect(BlockedRequestMatch.request(for: wrapped, in: [request]) == request)
        request.summary += " other"
        #expect(BlockedRequestMatch.request(for: wrapped, in: [request]) == nil)
        let project = try #require(DevinDialog.parse(ScreenFixture.screen("devin-project")).dialog)
        #expect(project.focus.focusedOrdinal == 3)
        #expect(once.fingerprint.matches(project.fingerprint))
        #expect(try DevinDialog.plan(.choose(ordinal: 2), project, call: "call-a").steps == [.keys(["left"]), .expect(.focus(ordinal: 2)), .keys(["enter"])])
    }

    @Test func questionAndCustomAnswerHaveSeparateInputs() throws {
        let question = try #require(DevinDialog.parse(ScreenFixture.screen("devin-ask")).dialog)
        #expect(question.title == "Which color do you prefer?")
        #expect(question.options.map(\.label) == ["Cobalt", "Amber", "Other"])
        #expect(question.options[1].detail == "A warm golden orange")
        let edit = try #require(DevinDialog.parse(ScreenFixture.screen("devin-answer")).dialog)
        let typed = try #require(DevinDialog.parse(ScreenFixture.screen("devin-typed")).dialog)
        #expect(edit.fingerprint.matches(typed.fingerprint) && question.fingerprint.matches(edit.fingerprint))
        #expect(typed.focus.inputText == "Jade")
        #expect(try DevinDialog.plan(.respond(ordinal: 3, text: "Jade"), edit, call: "ask").steps == [.paste("Jade"), .expect(.inputText("Jade")), .keys(["enter"])])
        #expect(throws: DialogPlanError.self) { try DevinDialog.plan(.respond(ordinal: 3, text: "else"), typed, call: "ask") }
    }

    @Test func planShowsTheImplementationProposalAndItsThreeRealChoices() throws {
        let dialog = try #require(DevinDialog.parse(ScreenFixture.screen("devin-plan")).dialog)
        #expect(dialog.kind == .devinPlan)
        #expect(dialog.options.map(\.label) == ["Yes, switch to accept edits mode", "Yes, switch to bypass mode", "No"])
        let plan = """
            Two-step plan:

            1. Create `/tmp/heeler-qa/plan-qa.txt` with a short temporary note (e.g. "Temporary QA note — safe to delete.").
            2. Verify it exists and print its contents with `ls -l` and `cat`.

            No source code or configuration is touched — it's just a small temp note in the current test folder.
            """
        let request = ChatPendingRequest(entryID: .init("call"), callID: "id", kind: .other, toolName: "exit_plan_mode", summary: plan)
        #expect(BlockedRequestMatch.request(for: dialog, in: [request]) == request)
        #expect(BlockedRequestMatch.request(for: dialog, in: [request, request]) == nil)
        var other = request
        other.summary = plan.replacingOccurrences(of: "ls -l", with: "ls /l")
        #expect(BlockedRequestMatch.request(for: dialog, in: [other]) == nil)
    }

    @Test func readsThePlaceholderInEitherTheme() throws {
        let placeholder = "Ask Devin to build features, fix bugs, or work on your code"
        for stem in ["devin-idle", "devin-light-idle"] {
            #expect(DevinInputBox.read(try ScreenFixture.screen(stem)) == .empty(placeholder: placeholder))
        }
        // The placeholder's text in the default color could be typed.
        let light = try ScreenFixture.text("devin-light-idle")
        let typed = light.replacingOccurrences(of: "\(SGR.reset)\(SGR.fg(107, 107, 107))\(placeholder)", with: placeholder)
        try #require(typed != light)
        #expect(!DevinInputBox.read(ANSIScreenDecoder.decode(typed)).isSendable)
    }

    @Test func refusesMenusDesktopDraftsAndChangedPastes() throws {
        #expect(DevinInputBox.read(try ScreenFixture.screen("devin-idle")).isSendable)
        for screen in ["devin-menu", "devin-write", "devin-trust", "devin-ask", "devin-paste"] {
            #expect(!DevinInputBox.read(try ScreenFixture.screen(screen)).isSendable)
        }
        let paste = try ScreenFixture.screen("devin-paste")
        let draft = "示例\n    return first with spaces\n\n    final中文 "
        #expect(DevinInputBox.showsPaste(draft, on: paste))
        #expect(!DevinInputBox.showsPaste(draft.replacingOccurrences(of: "\n\n", with: "\n"), on: paste))
        let wrapped = "DevinWrap " + String(repeating: "word ", count: 20) + String(repeating: "MORE  中文 repeatedWithNoSpaces", count: 2) + " tail "
        #expect(DevinInputBox.showsPaste(wrapped, on: try ScreenFixture.screen("devin-wrap")))
    }

    @Test func mergesLateSubagentReportsAndEachShellsOutputOnlyOnce() throws {
        let records = [
            #"{"id":"u","role":"user","text":"Run two jobs","calls":[]}"#,
            #"{"id":"a","role":"assistant","text":"","calls":[{"id":"child","name":"run_subagent","arguments":{"is_background":true,"title":"Child"},"complete":true},{"id":"one","name":"exec","arguments":{"command":"first","shell_id":"qa-one"},"complete":true},{"id":"two","name":"exec","arguments":{"command":"second","timeout":0},"complete":true}]}"#,
            #"{"id":"r","role":"tool","text":"Background subagent started with agent_id=123abcd. You can wait.","calls":[],"resultFor":"child","agentID":"123abcd"}"#,
            #"{"id":"r1","role":"tool","text":"Command running in background with ID: qa-one. Run get_output with timeout if you need to wait.","calls":[],"resultFor":"one"}"#,
            #"{"id":"r2","role":"tool","text":"Command running in background with ID: 22fd3e","calls":[],"resultFor":"two","success":true}"#,
            #"{"id":"f","role":"assistant","text":"Parent done","calls":[],"finish":"stop"}"#,
            #"{"id":"child-report","role":"subagent_report","text":"child output","agentID":"123abcd","calls":[]}"#,
            #"{"id":"get","role":"assistant","text":"","calls":[{"id":"read2","name":"get_output","arguments":{"shell_id":"22fd3e"},"complete":true}]}"#,
            #"{"id":"res","role":"tool","text":"second output\n\nExit code: 0","calls":[],"resultFor":"read2","shellExit":{"code":0,"outputLength":14},"childReports":{"123abcd":"child output"}}"#,
        ]
        let lines = records.enumerated().map { index, record in
            ChatLine(offset: UInt64(index), data: Data(record.replacingOccurrences(of: #""role":"#, with: #""truncated":false,"role":"#).utf8))
        }
        var reducer = DevinTranscriptReducer()
        reducer.prepend(Array(lines.prefix(6)))
        #expect(reducer.transcript(.init()).backgroundWork.map(\.state) == [.running, .running, .running])
        reducer.append(Array(lines.suffix(4)))
        reducer.append(lines)
        let transcript = reducer.transcript(.init())
        #expect(transcript.recordedPrompts.map(\.text) == ["Run two jobs"])
        #expect(transcript.backgroundWork.map(\.state) == [.completed, .running, .completed])
        #expect(transcript.backgroundWork.map(\.reportedOutput) == ["child output", nil, "second output"])
        #expect(transcript.turns.count == 1)
    }

    @Test func truncatedShellResultsKeepTheirOwnExitStatesAfterReopening() throws {
        typealias Row = DevinSessionPage.Row
        let shells = ["success", "failure", "busy"]
        let launches = shells.map { DevinSessionPage.Call(id: "launch-" + $0, name: "exec", arguments: .init(command: $0, shell_id: $0), complete: true) }
        let reads = shells.map { DevinSessionPage.Call(id: "read-" + $0, name: "get_output", arguments: .init(shell_id: $0), complete: true) }
        var rows = [Row(id: "launch", role: "assistant", text: "", truncated: false, calls: launches)]
        rows += shells.map { shell in
            Row(id: "ack-" + shell, role: "tool", text: "Command running in background with ID: " + shell + ". Run get_output with timeout if you need to wait.",
                truncated: false, calls: [], resultFor: "launch-" + shell, success: true)
        }
        rows.append(Row(id: "read", role: "assistant", text: "", truncated: false, calls: reads))
        let output = String(repeating: "中", count: 2048)
        rows += [
            Row(id: "ok", role: "tool", text: output, truncated: true, shellExit: .init(code: 0, outputLength: 9000), calls: [], resultFor: "read-success"),
            Row(id: "bad", role: "tool", text: "failed\nExit co", truncated: true, shellExit: .init(code: 17, outputLength: 6), calls: [], resultFor: "read-failure"),
            Row(id: "pending", role: "tool", text: "output\nExit code: 0", truncated: true, calls: [], resultFor: "read-busy", success: true),
        ]
        let earlier = rows.enumerated().map { DevinSessionPage.EarlierWork(offset: UInt64($0.offset), row: $0.element) }
        let tail = Row(id: "tail", role: "assistant", text: "Parent done", truncated: false, calls: [], earlierWork: earlier)
        var reducer = DevinTranscriptReducer()
        reducer.append([try ChatLine(offset: UInt64(rows.count), data: JSONEncoder().encode(tail))])
        let work = reducer.transcript(.init()).backgroundWork
        #expect(work.map(\.state) == [.completed, .failed, .running])
        #expect(work.map(\.reportedOutput) == [output, "failed", "output\nExit code: 0"])
    }

    @Test func chatAndHandOffReadWholeMessagesAcrossUnicodeChunkBoundaries() async throws {
        let texts = [String(repeating: "u", count: 8191) + "e\u{301} prompt end",
                     String(repeating: "👩🏽‍🔧", count: 5000) + " reply end"]
        let rows = texts.enumerated().map { i, text in
            DevinSessionPage.Row(id: "message-\(i)", role: i == 0 ? "user" : "assistant",
                text: String(text.unicodeScalars.prefix(8192)), truncated: true,
                fullText: .init(length: text.unicodeScalars.count, sha256: "revision-\(i)"), calls: [])
        }
        let page = DevinSessionPage(offset: 0, total: rows.count, rows: rows)
        var files = VirtualHostFiles().hostFiles()
        files.queryDevin = { query in
            guard let part = query.messageText else { return page }
            let i = try #require(query.offset)
            #expect(query.session == "test" && query.limit == 1 && part.id == rows[i].id && part.sha256 == rows[i].fullText?.sha256)
            let chunk = texts[i].unicodeScalars.dropFirst(part.start).prefix(5001)
            return .init(offset: i, total: rows.count, rows: [], textChunk: String(chunk))
        }
        var source = try #require(DevinRecordSource(session: "test", root: "/qa/devin/cli"))
        var changing = files
        let read = try #require(files.queryDevin)
        changing.queryDevin = { query in
            if let part = query.messageText, part.id == rows[1].id, part.start > 8192 {
                return .init(offset: 1, total: rows.count, rows: [])
            }
            return try await read(query)
        }
        await #expect(throws: TransportError.self) { try await source.open(changing) }
        #expect(source.readOffset == 0)

        let lines = try #require(try await source.open(files))
        var reducer = DevinTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init())
        #expect(transcript.recordedPrompts.map(\.text) == [texts[0]])
        #expect(transcript.entries.map(\.content) == [.user(.init(text: texts[0])), .assistant(.init(text: texts[1]))])
        let handOff = HandOffSource(agentName: "QA", program: .devin, transcriptPath: source.path, transcript: transcript, startsMidConversation: false)
        let record = HandOffRecord.markdown(for: handOff, recordedAt: .now)
        #expect(texts.allSatisfy { record.contains($0) })
        let capped = HandOffRecord.markdown(for: handOff, recordedAt: .now, characterLimit: 80)
        #expect(capped.contains("beginning of the first included entry was omitted") && capped.contains("[…]") && capped.contains("reply end"))

        files.queryDevin = { query in
            #expect(query.messageText == nil)
            return page
        }
        #expect(try await source.poll(files) == .unchanged)
    }

    @Test func olderSavedMessagesKeepTheirTextAndMarkPossibleTruncation() throws {
        let prefix = String(repeating: "e\u{301}", count: 4096)
        let entries: [ChatEntry] = [
            .init(id: .init("devin:1"), sourceOffset: 0, content: .user(.init(text: prefix))),
            .init(id: .init("devin:2"), sourceOffset: 1, content: .assistant(.init(text: "Short reply"))),
        ]
        let saved = ChatCacheDocument(key: .init(hostID: UUID(), herdrSession: "", program: .devin, conversationID: "test"),
                                      adapterRevision: 1, transcriptPath: "/qa/devin/cli/sessions.db#test", head: Data(),
                                      coverageStart: 0, coverageEnd: 2, reachedStart: true, title: nil, entries: entries, savedAt: .now)
        let migrated = try #require(ChatTranscriptAdapter.standard(for: .devin)?.migrateCache?(saved))
        #expect(migrated.entries.first == entries.first && migrated.entries.last == entries.last)
        #expect(migrated.entries.count == 3)
        guard case .notice(let notice) = migrated.entries[1].content else { Issue.record("Missing saved message notice"); return }
        #expect(notice.title == String(localized: "This saved Devin message may be incomplete."))
    }

    @Test @MainActor func parksEachSessionsDraftAndRefusesTheOldTarget() async throws {
        let composer = AgentComposerStore(target: "pane") { _ in throw TransportError.cancelled }
        composer.bindDroidDraft(to: "a", program: .devin)
        composer.replaceDraft(with: "Draft A")
        composer.bindDroidDraft(to: "b", program: .devin)
        #expect(composer.draft.isEmpty && !composer.droidDraftMatches("a"))
        composer.replaceDraft(with: "Draft B")
        composer.bindDroidDraft(to: "a", program: .devin)
        #expect(composer.draft == "Draft A")
        let first = DroidDialogTarget(scope: "server", pid: "42", start: "old", directory: "/qa", sessionID: "a", transcriptFolder: "/account-one/devin/cli")
        composer.bindDroidDraft(to: first.draftID(for: .devin), program: .devin)
        composer.replaceDraft(with: "Account one's unsent draft")
        var secondAccount = first
        secondAccount.transcriptFolder = "/account-two/devin/cli"
        composer.bindDroidDraft(to: secondAccount.draftID(for: .devin), program: .devin)
        #expect(composer.draft.isEmpty)
        composer.bindDroidDraft(to: first.draftID(for: .devin), program: .devin)
        #expect(composer.draft == "Account one's unsent draft")
        var next = first
        next.start = "new"
        let replacement = next
        let screen = try ScreenFixture.screen("devin-idle")
        let check = DroidSendVerification(target: first, readTarget: { replacement }, readScreen: { screen }, requiresSpec: false, program: .devin)
        #expect(await check.refusal() != nil)
        #expect(await check.refusal(staged: "Draft A") != nil)
    }
}
