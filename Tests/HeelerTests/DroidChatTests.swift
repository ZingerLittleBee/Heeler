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
        #expect(await host.files[launch] != nil)
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
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []),
            activity: { .idle }, readScreen: { screen })
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
