import Foundation
import Testing

@testable import Heeler

@Suite("Droid Chat")
struct DroidChatTests {
    private let session = "c5cc3f15-8d61-4921-a9e4-06419e62b300"
    private let other = "0160cefa-7648-4324-b7d3-b2fb89d4f2d3"

    private func header(_ id: String) -> String {
        #"{"type":"session_start","id":"\#(id)","title":"Read a file","version":2,"cwd":"/repo"}"# + "\n"
    }

    @Test func followsOnlyTheReportedSessionAcrossProjectsAndRewrites() async throws {
        let files = VirtualHostFiles(home: "/home/test")
        let root = "/home/test/.factory/sessions"
        let misplaced = "\(root)/-repo/\(session).jsonl"
        let resumed = "\(root)/-old-dir/\(session).jsonl"
        await files.write(header(other), at: misplaced)
        await files.write(header(other), at: "\(root)/-repo/\(other).jsonl")
        await files.write(header(session), at: resumed)
        let reference = ConversationReference(program: .droid, sessionID: session)
        let engine = ChatConversationEngine(
            reference: reference, cacheKey: .init(hostID: UUID(), herdrSession: "", program: .droid, conversationID: session),
            files: files.hostFiles(), cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)), now: { Date() })
        let snapshot = await engine.open(directories: ["/repo"], context: .init())
        #expect(snapshot.phase == .following(path: resumed))
        #expect(snapshot.transcript.title == "Read a file")

        await files.write(header(other) + #"{"type":"message","id":"new","message":{"role":"assistant","content":"other conversation"}}"# + "\n", at: resumed)
        let replaced = await engine.poll(context: .init())
        #expect(replaced.phase == .unavailable(.mismatched))
        #expect(replaced.transcript.entries.isEmpty)
    }

    @Test func projectsVisibleMessagesAndMatchesToolResultsAcrossPages() throws {
        // The fields and roles are from Droid 1.21.1, with test text and ids.
        let data = header(session) + """
            {"type":"message","id":"hook","message":{"role":"user","visibility":"user_only","hookEventName":"SessionStart","content":"hook output"}}
            {"type":"message","id":"ctx","message":{"role":"user","visibility":"llm_only","content":[{"type":"text","text":"host context"}]}}
            {"type":"message","id":"u","timestamp":"2026-11-27T00:00:00.000Z","message":{"role":"user","userMessageSource":"cli_tui","content":[{"type":"text","text":"Read the file"}]}}
            {"type":"message","id":"a","message":{"role":"assistant","modelId":"model","content":[{"type":"thinking","thinking":"Looking up the file"},{"type":"tool_use","name":"Read","id":"c","input":{"file_path":"/repo/LICENSE"}}]}}
            {"type":"message","id":"r","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","is_error":false,"content":"license text","model_content":"internal copy"},{"type":"text","text":"tool context"}]}}
            {"type":"message","id":"b","message":{"role":"assistant","content":"Here it is."}}
            {"type":"agent_turn_outcome","turnId":"u","reason":"completed","resultKind":"text"}
            """ + "\n"
        let lines = JSONLLineFramer.lines(in: Data(data.utf8))
        var reducer = DroidTranscriptReducer()
        reducer.append(Array(lines.suffix(3)))
        reducer.prepend(Array(lines.dropLast(3)))
        let transcript = reducer.transcript(.init(activity: .idle))
        #expect(transcript.recordedPrompts.map(\.text) == ["Read the file"])
        #expect(transcript.entries.count == 4)
        let tool = try #require(transcript.entries.compactMap { entry -> ChatToolActivity? in
            guard case .tool(let value) = entry.content else { return nil }
            return value
        }.first)
        #expect(tool.title == "LICENSE")
        #expect(tool.status == .succeeded)
        #expect(tool.preview?.text == "license text")
        let resultLine = try #require(lines.first { $0.offset == tool.output?.offset })
        #expect(reducer.output(of: resultLine, for: tool) == .preview(.init(capping: "license text")))
        #expect(transcript.entries.last?.content == .assistant(.init(text: "Here it is.")))
        #expect(transcript.turns.map(\.ending) == [.completed])
    }

    @Test func hookPlacementPreservesCustomLaunchSettingsAndExistingUserHooks() async throws {
        let config = "/home/dev/.factory/settings.json"
        let original = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]},"other":true}"#.utf8)
        let host = InMemoryHostFiles(files: [config: original])
        func place(_ action: DroidChatHook.Action) async throws -> String {
            try await DroidChatHook.place(on: host, action: action) { try await host.createHostFolder(path: $0) }
        }
        let launch = try await place(.launch)
        #expect(await host.files[config] == original)
        let generated = try #require(await host.files[launch])
        let previous = String(decoding: generated, as: UTF8.self)
            .replacingOccurrences(of: "permission_prompt|elicitation_dialog", with: "permission_prompt")
        await host.set(launch, Data(previous.utf8))
        _ = try await place(.launch)
        #expect(await host.files[launch] == generated)
        for arguments in [["--settings", "/custom.json"], ["--settings=/custom.json"]] {
            #expect(!DroidChatHook.offersLaunchSettings(kind: "droid", arguments: arguments, kernel: HerdrCoreLocator.macOSKernel))
        }
        _ = try await place(.register)
        let added = try #require(await host.files[config])
        #expect(added != original)
        _ = try await place(.register)
        #expect(await host.files[config] == added)
        _ = try await place(.removeRegistration)
        #expect(await host.files[config] == original)
        await host.set(launch, original)
        await #expect(throws: HostTextFileError.self) { try await place(.launch) }
        #expect(await host.files[launch] == original)
    }

    @Test func trustReadsTheCompleteFolderBeforeFactoryHasASession() throws {
        for stem in ["droid-trust", "droid-trust-narrow"] {
            let screen = try ScreenFixture.screen(stem)
            let dialog = try #require(DroidDialog.parse(screen).dialog)
            #expect(dialog.kind == .droidWorkspaceTrust)
            #expect(dialog.subject.workspacePath == "/tmp/fixture/trust long path 中文 acceptance")
            #expect(dialog.options.map(\.role) == [.trust, .exitProgram])
            #expect(try DroidDialog.plan(.choose(ordinal: 2), dialog, callID: nil).keys == ["esc"])
        }
    }

    @Test func patchApprovalRequiresOneLiteralFileInTheDisplayedDirectory() {
        for (command, file) in [
            ("git apply ./change.patch", "change.patch"),
            ("git apply './two files.patch'", "two files.patch"),
            ("git apply -- \"改动/两个 文件.diff\"", "改动/两个 文件.diff"),
        ] {
            #expect(DroidDialog.patchReview(command: command, directory: "/repo") == .file("/repo/" + file))
        }
        for command in ["git apply a.patch b.patch", "git apply < a", "git -C ../repo apply a.patch",
                        "cat a | git apply", "git apply \"$PATCH\"", "git apply ../other", "patch -p1 < file"] {
            #expect(DroidDialog.patchReview(command: command, directory: "/repo") == .terminal)
        }
        #expect(DroidDialog.patchReview(command: "git status", directory: "/repo") == .ordinaryCommand)
    }

    @Test func upgradingAndRemovingOnlyOwnsTheGeneratedDroidHandlers() throws {
        let path = "/home/me/.factory/hooks/" + DroidChatHook.fileName
        let command = DroidChatHook.jsonString(DroidChatHook.command(script: path))
        let handler = #"{"type":"command","command":\#(command),"timeout":5}"#
        let backup = #"{"type":"command","command":"python3 /home/me/.factory/hooks/heeler-droid.py.backup"}"#
        let original = #"{"hooks":{"Notification":[{"matcher":"permission_prompt","hooks":[\#(backup)]}],"Other":[{"hooks":[\#(handler)]}],"hooksDisabled":true},"custom":42}"#
        let mixed = original.replacingOccurrences(of: "[" + backup + "]", with: "[" + handler + "," + backup + "]")
        let old = Data(mixed.utf8)
        #expect(DroidChatHook.presence(in: old, script: path) == .partly)
        guard case .change(let upgraded) = DroidChatHook.registration(script: path, remove: false, settings: old) else {
            Issue.record("The legacy matcher did not upgrade")
            return
        }
        #expect(DroidChatHook.presence(in: upgraded, script: path) == .on)
        #expect(DroidChatHook.registration(script: path, remove: false, settings: upgraded) == .alreadyApplied)
        #expect(DroidChatHook.registration(script: path, remove: true, settings: upgraded) == .change(to: Data(original.utf8)))
        #expect(DroidChatHook.presence(in: Data(original.utf8), script: path) == .off)
    }

    @MainActor @Test func patchCardNeedsTheCompleteFileAndChecksItAgainBeforeEnter() async throws {
        let command = "git apply './two files.patch'"
        let frame = try ScreenFixture.text("droid-execute").replacingOccurrences(
            of: "printf DROID_APPROVAL_COMMAND > command-proof.txt", with: command)
        let screen = ANSIScreenDecoder.decode(frame)
        let target = DroidDialogTarget(scope: "pane", pid: "12", start: "birth", directory: "/repo", sessionID: session)
        let store = BlockedCardStore(program: .droid, io: .init(droidTarget: { target }, readScreen: { screen },
            sendKeys: { _ in Issue.record("Changed patch reached Enter") }, paste: { _ in Issue.record("Unexpected paste") }))
        defer { store.end() }
        let request = ChatPendingRequest(entryID: .init("execute"), callID: "call", kind: .command, toolName: "Execute", summary: command)
        store.update(transcript: .init(pendingRequests: [request]))
        store.update(activity: .blocked)
        store.droidCallStillOpen = { _, _ in true }
        store.readDroidPatch = { _ in nil }
        await store.refresh()
        guard case .generic = store.content else { Issue.record("Unreadable patch offered an action"); return }
        store.readDroidPatch = { $0 == "/repo/two files.patch" ? "reviewed bytes" : nil }
        await store.refresh()
        guard case .card(let shown) = store.content else { Issue.record("Readable patch did not open"); return }
        #expect(shown.patch == "reviewed bytes")
        store.readDroidPatch = { _ in "replacement bytes" }
        await store.perform(.choose(ordinal: 1), shownCard: shown)
    }

    @MainActor @Test func enterNeedsTheStagedPayloadAndItsOriginalProcess() async throws {
        let initial = try ScreenFixture.text("droid-execute")
        let idle = try ScreenFixture.screen("droid-01-idle")
        let target = DroidDialogTarget(scope: "server/pane", pid: "12", start: "birth", directory: "/repo", sessionID: session)
        let check = DroidSendVerification(target: target, readTarget: { target }, readScreen: { idle }, requiresSpec: false)
        #expect(await check.refusal() == nil)
        #expect(await check.refusal(staged: "missing") != nil)
        let changed = DroidSendVerification(target: target, readTarget: { nil },
            readScreen: { ANSIScreenDecoder.decode(initial) }, requiresSpec: false)
        #expect(await changed.refusal(staged: "mine") != nil)
    }

    @MainActor @Test func enterPreservesIndentationAndBlankLinesAcrossDroidWordWraps() async throws {
        let screen = try ScreenFixture.screen("droid-multiline-paste")
        let target = DroidDialogTarget(scope: "server/pane", pid: "12", start: "birth", directory: "/repo", sessionID: session)
        let check = DroidSendVerification(target: target, readTarget: { target }, readScreen: { screen }, requiresSpec: false)
        let rules = ChatSendRules(program: .droid, commands: [])
        let draft = "示例\n    let title = \"a narrow window wraps these words but keeps indentation\"\n\n    return title"
        #expect(await check.refusal(staged: rules.outgoingText(draft)) == nil)
        for changed in [
            draft.replacingOccurrences(of: "\n\n", with: "\n").replacingOccurrences(of: "\n    ", with: "\n"),
            draft.replacingOccurrences(of: "    let", with: "let"),
            draft.replacingOccurrences(of: "    return", with: "      return"),
            draft.replacingOccurrences(of: "\n\n", with: "\n"),
            draft.replacingOccurrences(of: "\n\n", with: "\n\n\n"),
            draft.replacingOccurrences(of: "narrow window", with: "narrow\nwindow"),
            draft.replacingOccurrences(of: "return title", with: "return other")
        ] {
            #expect(await check.refusal(staged: rules.outgoingText(changed)) != nil)
        }
    }

    @Test func customHookScriptSurvivesAnInstallAndOnlyProcessBoundHostsOfferIt() async throws {
        let script = "/home/dev/.factory/hooks/" + DroidChatHook.fileName
        let edited = Data("# Heeler Droid Chat hook\nprint('customized')\n".utf8)
        let host = InMemoryHostFiles(files: [script: edited])
        await #expect(throws: HostTextFileError.self) {
            try await DroidChatHook.place(on: host, action: .register) { try await host.createHostFolder(path: $0) }
        }
        #expect(await host.files[script] == edited)
        for kind in [ServerKind.herdrTUI, .tmux, .herdrCore, .rex] {
            for kernel in [HerdrCoreLocator.macOSKernel, HerdrCoreLocator.linuxKernel] {
                #expect(HostCapabilities(serverKind: kind, platform: .posix, coreKernel: kernel).offersDroidChatHook == (kind != .herdrTUI))
            }
            #expect(!HostCapabilities(serverKind: kind, platform: .nativeWindows, coreKernel: HerdrCoreLocator.windowsKernel).offersDroidChatHook)
        }
    }

    @MainActor @Test func sessionProcessOrScreenChangingAfterPreflightKeepsTheDraft() async throws {
        @MainActor final class Terminal {
            var target: DroidDialogTarget?
            var screen: ANSIScreen
            init(_ screen: ANSIScreen) { self.screen = screen }
        }
        let empty = try ScreenFixture.screen("droid-01-idle")
        let menu = try ScreenFixture.screen("droid-model-selector")
        let terminal = Terminal(empty)
        let owner = DroidDialogTarget(scope: "server/pane", pid: "12", start: "birth", directory: "/tmp/repo", sessionID: session)
        var next = owner
        next.sessionID = other
        var reused = owner
        reused.start = "another birth"
        var server = owner
        server.scope = "new server/pane"
        for (replacement, display) in [(next, empty), (reused, empty), (server, empty), (owner, menu)] {
            terminal.target = owner
            terminal.screen = empty
            let composer = AgentComposerStore(target: "pane") { _ in Issue.record("Stale send reached the terminal"); throw TransportError.cancelled }
            composer.bindDroidDraft(to: session)
            composer.replaceDraft(with: "Keep this draft")
            var policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []),
                activity: { .idle }, readScreen: { terminal.screen }, droidTarget: { await terminal.target })
            let preflight = policy.preflight
            policy.preflight = { text in
                let refusal = await preflight?(text)
                terminal.target = replacement
                terminal.screen = display
                return refusal
            }
            guard case .refused = await composer.send(policy: policy) else { Issue.record("Expected a refusal"); continue }
            #expect(composer.draft == "Keep this draft")
        }
    }

    @Test func changingDirectoryRequiresTheBoundProcessAndCancelsInPlace() throws {
        let dialog = try #require(DroidDialog.parse(ScreenFixture.screen("droid-change-directory")).dialog)
        #expect(dialog.subject.workspacePath == "/tmp/fixture/next folder")
        #expect(dialog.options.map(\.role) == [.trust, .decline])
        let initial = DroidDialogTarget(scope: "server/pane", pid: "42", start: "birth", directory: "/tmp/original")
        #expect(!initial.shows(dialog))
        var running = initial
        running.sessionID = UUID().uuidString
        #expect(running.shows(dialog))
        #expect(try DroidDialog.plan(.choose(ordinal: 2), dialog, callID: nil).keys == ["esc"])
        let file = try #require(DroidDialog.parse(ScreenFixture.screen("droid-create-rex")).dialog)
        #expect(file.subject.filePath == "approval-a.txt")
        #expect(file.options.last?.role == .decline)
    }

    @Test func permissionUsesOnlyTheObservedChoicesAndOneMatchingCall() throws {
        let dialog = try #require(DroidDialog.parse(ScreenFixture.screen("droid-create")).dialog)
        #expect(dialog.subject.filePath == "approval-a.txt")
        #expect(dialog.subject.changeLines.contains { $0.contains("ALPHA-DROID") })
        #expect(dialog.focus.focusedOrdinal == 1)
        #expect(try DroidDialog.plan(.choose(ordinal: 1), dialog, callID: "first").keys == ["enter"])
        #expect(throws: DialogPlanError.self) { try DroidDialog.plan(.choose(ordinal: 1), dialog, callID: nil) }
        let a = ChatPendingRequest(entryID: .init("a"), callID: "a", kind: .fileWrite, toolName: "Create", summary: "/tmp/fixture/approval-a.txt")
        var b = a
        b.callID = "b"
        #expect(BlockedRequestMatch.request(for: dialog, in: [a, b]) == nil)
        let command = try #require(DroidDialog.parse(ScreenFixture.screen("droid-execute")).dialog)
        #expect(command.subject.command == "printf DROID_APPROVAL_COMMAND > command-proof.txt")
    }

    @Test func questionAndProposalUseTheirOwnPagesAndKeyboardContracts() throws {
        let first = try #require(DroidDialog.parse(ScreenFixture.screen("droid-ask")).dialog)
        let second = try #require(DroidDialog.parse(ScreenFixture.screen("droid-ask-next")).dialog)
        #expect(first.fingerprint != second.fingerprint)
        #expect(first.body.count == 2)
        #expect(first.options.last?.role == .otherText)
        #expect(try DroidDialog.plan(.choose(ordinal: 2), first, callID: "ask").keys == ["2"])
        let spec = try #require(DroidDialog.parse(ScreenFixture.screen("droid-spec")).dialog)
        #expect(spec.kind == .droidSpec)
        #expect(spec.options.count == 5)
        let linux = try #require(DroidDialog.parse(ScreenFixture.screen("droid-spec-linux")).dialog)
        #expect(linux.kind == .droidSpec && linux.options.count == 5)
        #expect(linux.options[3].label.contains("xdg-open"))
        #expect(try DroidDialog.plan(.choose(ordinal: 3), spec, callID: "plan").keys == ["3"])
    }

    @Test func anOfflineProviderReportsItsReasonWithoutAcknowledgingAnotherPrompt() throws {
        let lines = JSONLLineFramer.lines(in: Data(try ChatFixture.text("droid/offline.jsonl").utf8))
        var reducer = DroidTranscriptReducer()
        reducer.append(lines)
        let transcript = reducer.transcript(.init())
        #expect(transcript.turns.map(\.ending) == [.failed])
        #expect(transcript.recordedPrompts.map(\.text) == ["Reply with LOCAL_OFFLINE_MARKER. No tools."])
        guard case .notice(let notice) = transcript.entries.last?.content else {
            Issue.record("Missing Factory's visible provider notice")
            return
        }
        #expect(notice.title.hasPrefix("Unable to reach the server."))
    }

    @Test func scriptCommandsRequireTheirOwnOuterCallResultAndOutputFile() throws {
        let lines = JSONLLineFramer.lines(in: Data(try ChatFixture.text("droid/script-background.jsonl").utf8))
        let firstEnd = try #require(lines.firstIndex { String(decoding: $0.data, as: UTF8.self).contains(#""id":"blue-ended""#) })
        var reducer = DroidTranscriptReducer()
        reducer.append(Array(lines[firstEnd...]))
        #expect(reducer.transcript(.init(windowStart: lines[firstEnd].offset)).needsOlderHistory)
        reducer.prepend(Array(lines[..<firstEnd]))
        var running = DroidTranscriptReducer()
        running.append(Array(lines[..<firstEnd]))
        let commands = running.transcript(.init()).backgroundWork
        #expect(commands.count == 2 && commands.allSatisfy { $0.state == .running && !$0.allowsDroidTaskPanel })
        let transcript = reducer.transcript(.init(activity: .idle))
        #expect(transcript.recordedPrompts.map(\.text) == ["Start the two commands."])
        #expect(transcript.turns.map(\.ending) == [.completed])
        #expect(transcript.pendingRequests.isEmpty)
        #expect(transcript.backgroundWork.count == 2)
        let red = try #require(transcript.backgroundWork.first { $0.title == "printf red" })
        let blue = try #require(transcript.backgroundWork.first { $0.title == "printf blue" })
        #expect(red.droidScriptCallID == "script-a" && blue.droidScriptCallID == "script-a")
        #expect(red.taskID == "5181" && blue.taskID == "5182")
        #expect(red.state == .completed && red.exitCode == 0 && red.reportedOutput == "RED OUTPUT")
        #expect(blue.state == .failed && blue.exitCode == 17 && blue.reportedOutput == "BLUE OUTPUT\nexit_status: code 0")
        #expect(!red.allowsDroidTaskPanel && !blue.allowsDroidTaskPanel)
        #expect(!transcript.entries.contains { entry in
            if case .tool(let tool) = entry.content { return tool.callID == red.id || tool.callID == blue.id }
            return false
        })
    }

    @Test func lateTaskResultsMergeByIdentityWithoutOpeningUserTurns() throws {
        let data = Data(try ChatFixture.text("droid/background.jsonl").utf8)
        let lines = JSONLLineFramer.lines(in: data)
        var reducer = DroidTranscriptReducer()
        reducer.append(Array(lines.suffix(4)))
        reducer.prepend(lines)
        reducer.append(JSONLLineFramer.lines(in: data, startOffset: UInt64(data.count)))
        let transcript = reducer.transcript(.init(activity: .idle))
        #expect(transcript.recordedPrompts.count == 1)
        #expect(transcript.turns.map(\.ending) == [.completed])
        #expect(transcript.backgroundWork.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: transcript.backgroundWork.map { ($0.id, $0) })
        #expect(byID["call_red"]?.state == .stopped)
        #expect(byID["call_blue"]?.state == .completed)
        #expect(byID["call_child"]?.reportedOutput == "DROID_CHILD_742")
        #expect(byID["call_red"]?.reportedOutput?.contains("ISOLATED_BLUE") == false)
    }

    @Test func anElidedTaskListMayOpenDetailsButAClippedCommandCannotBeKilled() throws {
        let data = Data(try ChatFixture.text("droid/background.jsonl").utf8)
        var reducer = DroidTranscriptReducer()
        reducer.append(JSONLLineFramer.lines(in: data))
        var item = try #require(reducer.transcript(.init()).backgroundWork.first { $0.kind == .command })
        item.title = "for i in 1 2 3 4 5; do echo LONG_87654_TEST; sleep 17; done"
        item.taskID = "103804"
        guard case .list(let list, let index) = try DroidTaskPanel.read(ScreenFixture.screen("droid-task-list-narrow")),
              case .detail(let detail, _) = try DroidTaskPanel.read(ScreenFixture.screen("droid-task-detail-narrow")) else {
            Issue.record("Droid's narrow task panel was not identified")
            return
        }
        #expect(list[index].mayIdentify(item))
        #expect(detail.pid == item.taskID)
        #expect(!DroidTaskPanel.matches(detail, item: item))
    }

    @Test func sendsOnlyAtAnEmptyDroidPromptAndInterruptsOnlyAWorkingTurn() {
        func screen(_ field: String, above: String = "", footer: String = "MCP ✓ | IDE ◌") -> ANSIScreen {
            ANSIScreenDecoder.decode("\(above)\n╭──────────────────────────────────────╮\n│ > \(field) │\n╰──────────────────────────────────────╯\n\(footer)")
        }
        #expect(DroidInputBox.read(screen("")) == .empty(placeholder: nil))
        for status in ["MCP ✓ | TMUX ⧉", "MCP ✓ | GHOSTTY ᗣ", "? for help     TMUX ⧉",
                       "? for help     GHOSTTY ᗣ", "? for help     IDE ◌", "[⏱ 2s] ? for help     TMUX ⧉"] {
            #expect(DroidInputBox.read(screen("", footer: status)) == .empty(placeholder: nil))
        }
        #expect(DroidInputBox.read(screen("draft")) == .text("draft"))
        #expect(!DroidInputBox.read(screen("", footer: "> 1. Trust this folder\nEnter to confirm")).allowsSendAnyway)
        #expect(!DroidInputBox.read(ANSIScreenDecoder.decode("Trust this folder?\n> 1. Trust this folder")).isSendable)
        let busy = screen("Enter to steer · Ctrl+Enter to queue", above: "⠇ Thinking...  (Press ESC to stop)")
        #expect(DroidInputBox.read(busy) == .disabled(DroidInputBox.working))
        #expect(DroidInputBox.stop(.init(screen: busy, activity: .working)) == .press)
        #expect(DroidInputBox.stop(.init(screen: screen(""), activity: .working)) != .press)
    }

    @MainActor @Test func stopRequiresTheSameLiveTurnAfterTheLastTranscriptRead() async throws {
        let files = VirtualHostFiles(home: "/home/test")
        let path = "/home/test/.factory/sessions/-repo/" + session + ".jsonl"
        let first = header(session) + #"{"type":"message","id":"first","message":{"role":"user","content":"first"}}"# + "\n"
        await files.write(first, at: path)
        let agent = Agent(terminalID: "t", kind: "droid", title: "", status: .working, workspaceID: "w",
            tabID: "tab", paneID: "p", cwd: "/repo", revision: 1,
            agentSession: .init(agent: "droid", kind: .id, source: "herdr:droid", value: session))
        let host = UUID()
        let source = AgentChatSource(hostID: host, socketLocation: .defaultSession, files: files.hostFiles(),
            agentInfo: { agent }, cache: VolatileChatTranscriptCache(), adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)))
        let chat = AgentChatStore(agentID: .init(hostID: host, paneID: agent.paneID), agent: agent, program: .droid, source: source)
        defer { chat.end() }
        await chat.step()
        let old = chat.droidStopVerification()
        try #require(await old())
        let next = first + #"{"type":"agent_turn_outcome","turnId":"first","reason":"completed"}"# + "\n"
            + #"{"type":"message","id":"second","message":{"role":"user","content":"second"}}"# + "\n"
        await files.write(next, at: path)
        #expect(!(await old()))
        let current = chat.droidStopVerification()
        try #require(await current())
        await files.write(header(other), at: path)
        #expect(!(await current()))
    }

    @Test func terminalPagesKeepSendAndStopAwayFromSelections() throws {
        for page in ["bash-mode", "model-selector", "skills", "mission-control", "btw", "slash-menu", "linux-login", "mcp-approval"] {
            let screen = try ScreenFixture.screen("droid-" + page)
            #expect(!DroidInputBox.read(screen).isSendable && !DroidInputBox.read(screen).allowsSendAnyway, "Page: \(page)")
            #expect(DroidInputBox.stop(.init(screen: screen, activity: .working)) != .press, "Page: \(page)")
        }
        let single = try #require(DroidDialog.parse(ScreenFixture.screen("droid-single-ask")).dialog)
        #expect(single.subject.question == "Which marker?")
        #expect(single.options.map(\.label) == ["Scarlet", "Azure", "Or type your own answer..."])
    }

    @MainActor @Test func aLostHerdrPromptReceiptDoesNotReplayTheDraft() async throws {
        let composer = AgentComposerStore(target: "fixture") { _ in throw TransportError.cancelled }
        composer.bindDroidDraft(to: session)
        let screen = try ScreenFixture.screen("droid-01-idle")
        let target = DroidDialogTarget(scope: "server/pane", pid: "1", start: "birth", directory: "/repo", sessionID: session)
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []),
            activity: { .idle }, readScreen: { screen }, droidTarget: { target })
        composer.replaceDraft(with: "Do not replay")
        #expect(await composer.send(policy: policy) == .outcomeUnknown)
        let message = try #require(composer.messages.first)
        #expect(message.text == "Do not replay" && message.state == .outcomeUnknown)
        composer.isConnectionAvailable = false
        composer.isConnectionAvailable = true
        #expect(await composer.retry(message.id, policy: policy) == .ignored)
        #expect(composer.messages.count == 1)
    }
}
