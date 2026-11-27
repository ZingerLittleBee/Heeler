import SwiftUI
import Testing
import UIKit

@testable import Heeler

extension DroidChatLiveTests {
    @MainActor private struct LiveChat {
        let chat: AgentChatStore
        let projection: HostConsoleProjection
        let fixture: Scenario
        let composer: AgentComposerStore
        let policy: ComposerDeliveryPolicy

        func poll() async throws {
            chat.agentDidChange(try await projection.agentInfo(paneID: fixture.pane))
            chat.sessionEvidenceMayHaveChanged()
            await chat.step()
            await chat.blocked.refresh()
        }

        func wait(_ condition: () -> Bool, seconds: Int = 65) async throws {
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end {
                try await poll()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(240))
            }
            throw ChatSourceUnavailable(reason: .cannotTellSession(.droid))
        }

        func card(_ kind: BlockedDialogKind, path: String? = nil) async throws -> BlockedCard {
            func shown() -> BlockedCard? {
                guard case .card(let card) = chat.blocked.content, card.dialog.kind == kind,
                      card.target != nil, kind == .droidWorkspaceTrust || card.request?.callID != nil else { return nil }
                if let path, card.dialog.subject.filePath != path { return nil }
                return card
            }
            try await wait { shown() != nil }
            return try #require(shown())
        }

        func send(_ message: String) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            var ready = false
            while ContinuousClock.now < deadline {
                try await poll()
                let screen = try await projection.readAgentScreen(fixture.pane)
                if case .following = chat.conversation.phase, chat.agent.status != .working, chat.agent.status != .blocked,
                   DroidInputBox.read(screen).isSendable, let id = chat.droidSessionID,
                   try await projection.droidDialogTarget(paneID: fixture.pane)?.sessionID == id {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            try #require(ready, "Droid has no confirmed composer for \(fixture.pane), \(chat.conversation.phase)")
            composer.bindDroidDraft(to: chat.droidSessionID)
            composer.replaceDraft(with: message)
            chat.draftDidChange(to: message)
            let result = await composer.send(policy: policy)
            try #require(result == .deliveredViaPrompt, "Droid send: \(result)")
        }

        func reply(_ token: String) -> Bool {
            chat.conversation.transcript.entries.contains { entry in
                if case .assistant(let message) = entry.content { return message.text.contains(token) }
                return false
            }
        }
    }

    private func live(_ name: String, lab: Lab, host: Host, projection: HostConsoleProjection) async throws -> LiveChat {
        let fixture = try #require(lab.scenarios?[name])
        let pane = fixture.pane
        let agent = try await projection.agentInfo(paneID: pane)
        try #require(agent.kind == "droid")
        try #require(agent.foregroundCwd == fixture.directory || agent.cwd == fixture.directory)
        let io = BlockedScreenIO(droidTarget: { try await projection.droidDialogTarget(paneID: pane) }, hostName: host.name, herdrReportsDroidSession: true,
            readScreen: { try await projection.readAgentScreen(pane) },
            sendKeys: { try await projection.sendAgentKeys($0, to: pane) },
            paste: { try await projection.pasteIntoAgent($0, paneID: pane) })
        var source = AgentChatSource(hostID: host.id, socketLocation: .absolutePath(lab.socket), files: projection.chatHostFiles(),
            agentInfo: { try await projection.agentInfo(paneID: pane) }, cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)), screen: io)
        source.sessionEvidence = { try await projection.droidSessionEvidence(paneID: pane) }
        let chat = AgentChatStore(agentID: .init(hostID: host.id, paneID: pane), agent: agent, program: .droid, source: source)
        let composer = AgentComposerStore(target: pane) { try await projection.promptAgent($0) }
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []),
            activity: { ChatAgentActivity(chat.agent.status) }, readScreen: io.readScreen, droidTarget: io.droidTarget, displayedDroidTarget: { chat.displayedDroidTarget },
            confirmSession: {
                if let reason = await chat.confirmSessionBeforeSend() { return reason }
                return composer.droidDraftMatches(chat.droidSessionID) ? nil : "Session changed"
            })
        return .init(chat: chat, projection: projection, fixture: fixture, composer: composer, policy: policy)
    }

    private func desktop(_ text: String, in pane: String, projection: HostConsoleProjection) async throws {
        try await projection.pasteIntoAgent(text, paneID: pane)
        try await projection.sendAgentKeys(["enter"], to: pane)
    }

    private func capture(_ live: LiveChat, lab: Lab, name: String) async throws {
        guard let directory = lab.evidenceDirectory else { return }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let card = BlockedCardView(store: live.chat.blocked, maxHeight: isPad ? 540 : 430, openTerminal: {})
            .padding().frame(maxWidth: isPad ? 640 : .infinity).background(.background)
        let controller = UIHostingController(rootView: card)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(450))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(isPad ? "ipad" : "iphone").png")
        try #require(image.pngData()).write(to: url)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func trustBeforeSessionAndExitWithoutTypingInShell() async throws {
        try await withLab { lab, host, projection in
            for name in ["trust", "decline"] {
                let live = try await self.live(name, lab: lab, host: host, projection: projection)
                defer { live.chat.end() }
                let card = try await live.card(.droidWorkspaceTrust)
                try #require(card.target?.sessionID == nil && card.dialog.subject.workspacePath == live.fixture.directory)
                if name == "trust" {
                    try await capture(live, lab: lab, name: "native-trust")
                    await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
                    try await live.wait { live.chat.droidSessionID != nil }
                    let marker = "DROID_TRUST_" + UUID().uuidString.prefix(8)
                    try await live.send("Reply with exactly \(marker). Do not use tools.")
                    try await live.wait { live.reply(marker) }
                } else {
                    await live.chat.blocked.perform(.choose(ordinal: 2), shownCard: card)
                    await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
                    try await Task.sleep(for: .seconds(2))
                    let data = try await projection.chatHostFiles().read(.init(path: live.fixture.directory + "/shell-observation", offset: 0, maxBytes: 64))
                    #expect(String(decoding: data.data, as: UTF8.self) == "ready")
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func changingDirectoryCancelsInPlaceOrFollowsTheAcceptedDestination() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("directory", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            let original = try #require(live.chat.droidSessionID)
            let parent = (live.fixture.directory as NSString).deletingLastPathComponent
            let next = RemoteFilePath.join(parent, "next folder")
            for accepts in [false, true] {
                try await desktop("/cd " + next, in: live.fixture.pane, projection: projection)
                let card = try await live.card(.droidWorkspaceTrust)
                try #require(card.target?.sessionID == original && card.dialog.subject.workspacePath == next)
                try #require(card.dialog.options.last?.role == .decline)
                await live.chat.blocked.perform(.choose(ordinal: accepts ? 1 : 2), shownCard: card)
                try await live.wait {
                    if case .card = live.chat.blocked.content { return false }
                    return live.chat.droidSessionID != nil
                }
                if !accepts {
                    #expect(try await projection.droidDialogTarget(paneID: live.fixture.pane)?.directory == live.fixture.directory)
                    #expect(live.chat.droidSessionID == original)
                }
            }
            let marker = "AFTER_CD_" + UUID().uuidString.prefix(8)
            try await live.send("Reply with exactly \(marker). No tools.")
            try await live.wait { live.reply(marker) }
            let current = try #require(try await projection.droidDialogTarget(paneID: live.fixture.pane))
            #expect(current.directory == next && current.sessionID == live.chat.droidSessionID)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func staleApprovalAfterDesktopDeclinesCannotCreateSecondFile() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("approval", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            let files = projection.chatHostFiles()
            let directory = live.fixture.directory
            for path in ["approval-a.txt", "approval-b.txt"] {
                try #require(try await files.status(directory + "/" + path) == nil)
            }
            try await live.send("Use Create to write approval-a.txt with exactly ALPHA-DROID and one newline. After it succeeds, use a separate Create call to write approval-b.txt with exactly BETA-DROID and one newline. If refused, stop immediately. No other tools.")
            let a = try await live.card(.droidPermission, path: "approval-a.txt")
            try await capture(live, lab: lab, name: "native-approval")
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: a)
            let b = try await live.card(.droidPermission, path: "approval-b.txt")
            #expect(a.request?.callID != b.request?.callID)
            // This independent terminal input is the desktop operator's response.
            try await projection.sendAgentKeys(["esc"], to: live.fixture.pane)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: a)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: b)
            try await Task.sleep(for: .seconds(2))
            let bytes = try await files.read(.init(path: directory + "/approval-a.txt", offset: 0, maxBytes: 64))
            #expect(String(decoding: bytes.data, as: UTF8.self) == "ALPHA-DROID\n")
            #expect(try await files.status(directory + "/approval-b.txt") == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func backgroundCommandsAndLateChildReportStayWithTheirTasks() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("work", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            try await DroidLiveBackground.exercise(chat: live.chat, send: live.send, poll: live.poll)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func keepsAnUnsentDraftWithItsSessionThroughSwitchAndReconnect() async throws {
        try await withLab { lab, host, projection in
            let a = try await self.live("history", lab: lab, host: host, projection: projection)
            let b = try await self.live("peer", lab: lab, host: host, projection: projection)
            defer { a.chat.end(); b.chat.end() }
            try await a.wait { a.chat.droidSessionID != nil }
            try await b.wait { b.chat.droidSessionID != nil }
            let original = try #require(a.chat.droidSessionID)
            let peer = try #require(b.chat.droidSessionID)
            try #require(original != peer && a.fixture.directory == b.fixture.directory)
            let token = UUID().uuidString.prefix(8)
            try await a.send("Reply with A_\(token). Do not use tools.")
            try await a.wait { a.reply("A_\(token)") }
            try await b.send("Reply with B_\(token). Do not use tools.")
            try await b.wait { b.reply("B_\(token)") }
            let pane = a.fixture.pane
            try await desktop("/fork", in: pane, projection: projection)
            var fork: String?
            for _ in 0..<40 {
                let rows = try await projection.readAgentScreen(pane).rows.map(\.trimmedText)
                if rows.contains("You are still in the original session. Resume the fork with:"),
                   let line = rows.last(where: { $0.hasPrefix("droid --resume ") }) {
                    fork = ConversationReference.canonicalUUID(String(line.dropFirst("droid --resume ".count)))
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            let copy = try #require(fork)
            try await a.poll()
            #expect(a.chat.droidSessionID == original)
            let draft = "A_ONLY_草稿_" + token
            a.composer.replaceDraft(with: draft)
            a.chat.draftDidChange(to: draft)
            for reconnect in [false, true] {
                if reconnect { a.chat.suspend(); await projection.suspend() }
                try await withLab { _, _, desktop in
                    try await self.desktop(reconnect ? "/resume " + peer : "/new", in: pane, projection: desktop)
                    let deadline = ContinuousClock.now + .seconds(15)
                    while ContinuousClock.now < deadline {
                        let found = try await desktop.droidDialogTarget(paneID: pane)?.sessionID
                        if let found, found != original, !reconnect || found == peer { return }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try #require(Bool(false), "The desktop did not switch the foreground Factory session")
                }
                if reconnect { await projection.resume() }
                let result = await a.composer.send(policy: a.policy)
                guard case .refused = result else { Issue.record("Unexpected send from A: \(result)"); return }
                if reconnect { a.chat.resume() }
                try await a.wait { a.chat.droidSessionID != nil && a.chat.droidSessionID != original }
                a.composer.bindDroidDraft(to: a.chat.droidSessionID)
                #expect(a.composer.draft.isEmpty)
                #expect(!a.chat.conversation.transcript.recordedPrompts.contains { $0.text.contains(draft) })
                try await desktop("/resume " + original, in: pane, projection: projection)
                try await a.wait { a.chat.droidSessionID == original }
                a.composer.bindDroidDraft(to: original)
                #expect(a.composer.draft == draft)
            }
            try await desktop("/resume " + copy, in: pane, projection: projection)
            try await a.wait { a.chat.droidSessionID == copy && a.reply("A_\(token)") }
            a.composer.bindDroidDraft(to: copy)
            #expect(a.composer.draft.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func answersEditsAndSubmitsAQuestionnaireWithoutConsumingTheDraft() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("ask", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            try await live.send("Use AskUser once with two short questions, Color (Red or Gold), then Size (Small or Large). Include a one-line explanation each. When submitted, repeat the two answers exactly. No other tools.")
            live.composer.replaceDraft(with: "Ordinary draft")
            let first = try await live.card(.droidQuestion)
            try await capture(live, lab: lab, name: "native-question")
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: first)
            let second = try await live.card(.droidQuestion)
            try #require(second.dialog.fingerprint != first.dialog.fingerprint)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: second)
            let review = try await live.card(.droidQuestionReview)
            await live.chat.blocked.perform(.choose(ordinal: 2), shownCard: review)
            let edit = try await live.card(.droidQuestion)
            let field = try #require(edit.dialog.options.first { $0.role == .otherText })
            let custom = "Custom_秋"
            await live.chat.blocked.perform(.respond(ordinal: field.ordinal, text: custom), shownCard: edit)
            let updated = try await live.card(.droidQuestionReview)
            try #require(updated.dialog.body.joined().contains(custom))
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: updated)
            try await live.wait { live.reply(custom) }
            #expect(live.composer.draft == "Ordinary draft")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func reviewsRevisesAndApprovesASpecWithoutUsingTheOrdinaryDraft() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("spec", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            try await live.send("Propose a two-step plan for a greeting and call ExitSpecMode now. Use no other tools. When approved just reply GREETING_DONE. No files.")
            live.composer.replaceDraft(with: "ordinary proposal draft")
            let first = try await live.card(.droidSpec)
            try #require(first.request?.summary.isEmpty == false)
            try await capture(live, lab: lab, name: "native-spec")
            await live.chat.blocked.perform(.choose(ordinal: 5), shownCard: first)
            let revision = try #require(live.chat.blocked.droidRevision)
            revision.text = "Revise the proposal to include a greeting in Italian. Use ExitSpecMode again."
            try await live.wait { live.chat.agent.status != .working && live.chat.agent.status != .blocked }
            try #require(await live.composer.sendDroidRevision(revision, policy: live.policy,
                readScreen: { try await projection.readAgentScreen(live.fixture.pane) }))
            let updated = try await live.card(.droidSpec)
            #expect(first.request?.callID != updated.request?.callID)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: updated)
            let level = try await live.card(.droidSpecAutonomy)
            #expect(level.dialog.options.count == 4)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: level)
            try await live.wait { live.reply("GREETING_DONE") }
            #expect(live.composer.draft == "ordinary proposal draft")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func showsTheFullCommandAndDeclinesItWithoutCreatingTheFile() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("command", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            let text = "COMMAND_" + String(repeating: "abcdefghij", count: 14)
            let command = "printf '" + text + "' > review-command.txt"
            try await live.send("Use Execute with the exact command below. If it is declined, stop. Use no other tools.\n" + command)
            let card = try await live.card(.droidPermission)
            try #require(card.request?.summary == command)
            try await capture(live, lab: lab, name: "native-command")
            let no = try #require(card.dialog.options.first { $0.role == .decline })
            await live.chat.blocked.perform(.choose(ordinal: no.ordinal), shownCard: card)
            try await live.wait { live.chat.conversation.transcript.pendingRequests.isEmpty }
            #expect(try await projection.chatHostFiles().status(live.fixture.directory + "/review-command.txt") == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func aReviewedEditChangesOnlyTheDisplayedFile() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("edit", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            let path = live.fixture.directory + "/proof.txt"
            let files = projection.chatHostFiles()
            func contents() async throws -> String {
                String(decoding: try await files.read(.init(path: path, offset: 0, maxBytes: 80)).data, as: UTF8.self)
            }
            try #require(try await contents() == "old fixture line\n")
            try await live.send("Use Edit directly to replace 'old fixture line' with 'new fixture line' in proof.txt. Do not use a shell. Reply EDIT_DONE.")
            let card = try await live.card(.droidPermission, path: "proof.txt")
            try #require(card.request?.toolName == "Edit")
            let diff = card.dialog.subject.changeLines.joined(separator: "\n")
            try #require(diff.contains("old fixture line") && diff.contains("new fixture line"))
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
            try await live.wait { live.reply("EDIT_DONE") }
            #expect(try await contents() == "new fixture line\n")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func cancellingAnAskUserCardInterruptsItsTurnAndKeepsTheDraft() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("askCancel", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.send("Call AskUser directly to ask 'Which fixture?' with Peach and Plum as options. Wait for my answer.")
            let ask = try await live.card(.droidQuestion)
            let session = try #require(live.chat.droidSessionID)
            live.composer.replaceDraft(with: "Keep this unsent draft")
            await live.chat.blocked.perform(.dismiss, shownCard: ask)
            try await live.wait { live.chat.conversation.transcript.turns.last?.ending == .interrupted }
            #expect(live.chat.droidSessionID == session && live.composer.draft == "Keep this unsent draft")
            #expect(DroidInputBox.read(try await projection.readAgentScreen(live.fixture.pane)).isSendable)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func aSpecHandoffFollowsTheNewForegroundSession() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("handoff", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.send("Call ExitSpecMode with a short plan whose only implementation step is to reply HANDOFF_DONE. No files or other tools.")
            let spec = try await live.card(.droidSpec)
            let original = try #require(live.chat.droidSessionID)
            let choice = try #require(spec.dialog.options.first { $0.label.contains("handoff to a new session") })
            await live.chat.blocked.perform(.choose(ordinal: choice.ordinal), shownCard: spec)
            let autonomy = try await live.card(.droidSpecAutonomy)
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: autonomy)
            try await live.wait { live.chat.droidSessionID != nil && live.chat.droidSessionID != original && live.reply("HANDOFF_DONE") }
            #expect(try await projection.droidDialogTarget(paneID: live.fixture.pane)?.sessionID == live.chat.droidSessionID)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func anOldStopCannotInterruptANewDroidConversation() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("stop", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            let keys = ChatAgentKeysStore { try await projection.sendAgentKeys($0, to: live.fixture.pane) }
            let plan = ChatStopPlan.standard(for: .droid)
            let context: @MainActor () async throws -> ChatStopContext = {
                try await .init(screen: projection.readAgentScreen(live.fixture.pane), activity: ChatAgentActivity(live.chat.agent.status))
            }
            @MainActor func begin(_ marker: String) async throws -> AgentComposerInterrupt {
                try await live.send("List the numbers 1 through 2000, one per line with prefix " + marker + ". Do not use tools.")
                let deadline = ContinuousClock.now + .seconds(25)
                while ContinuousClock.now < deadline {
                    try await live.poll()
                    if let turn = live.chat.conversation.transcript.turns.last, turn.ending == nil,
                       try await DroidInputBox.stop(context()) == .press {
                        return plan.composerInterrupt(context: context, agentKeys: keys, confirmTarget: live.chat.droidStopVerification())
                    }
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw ChatSourceUnavailable(reason: .cannotTellSession(.droid))
            }
            let old = try await begin("FIRST_STOP")
            let original = try #require(live.chat.droidSessionID)
            try #require(await old.perform() == .sent)
            try await live.wait {
                live.chat.conversation.transcript.turns.last?.ending == .interrupted && ChatAgentActivity(live.chat.agent.status) == .idle
            }
            try #require(DroidInputBox.read(try await projection.readAgentScreen(live.fixture.pane)).isSendable)
            try await self.desktop("/new", in: live.fixture.pane, projection: projection)
            try await live.wait { live.chat.droidSessionID != nil && live.chat.droidSessionID != original }
            let current = try await begin("SECOND_STOP")
            #expect(await old.perform() == .failed(ChatStopPlan.changedDroidTurn))
            try #require(await current.perform() == .sent)
            try await live.wait {
                live.chat.conversation.transcript.turns.last?.ending == .interrupted && ChatAgentActivity(live.chat.agent.status) == .idle
            }
            #expect(DroidInputBox.read(try await projection.readAgentScreen(live.fixture.pane)).isSendable)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func stagesImageAndFileAndKeepsBothWhenTheTerminalHasADraft() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("attach", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            live.composer.bindDroidDraft(to: live.chat.droidSessionID)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appendingPathComponent("测试 with spaces.txt")
            try Data("FACTORY_ATTACHMENT".utf8).write(to: file)
            let png = UIGraphicsImageRenderer(size: .init(width: 20, height: 20)).pngData { context in
                UIColor.red.setFill()
                context.fill(.init(x: 0, y: 0, width: 20, height: 20))
            }
            let staging = ComposerStagingStore(stageImage: { image, progress in
                try await projection.withHostServices { try await $0.stageImage(image, progress: progress.report) }
            }, stageFile: { file, progress in
                try await projection.withHostServices { try await $0.stageFile(file, progress: progress.report) }
            }, composer: live.composer)
            defer { _ = staging }
            live.composer.bindStaging(staging)
            let message = "检查附件路径。\nReply only FILE_AND_IMAGE_RECEIVED. Do not use tools.\n"
            live.composer.replaceDraft(with: message)
            live.composer.enqueueImages([DataImageSelection(data: png)])
            live.composer.enqueueFile(URLFileSelection(url: file))
            let deadline = ContinuousClock.now + .seconds(30)
            while (live.composer.readyImagePaths.count != 1 || live.composer.draft == message), ContinuousClock.now < deadline {
                if case .failed = staging.state { break }
                try await Task.sleep(for: .milliseconds(150))
            }
            try #require(live.composer.readyImagePaths.count == 1 && live.composer.draft != message, "Attachment staging: \(staging.state)")
            let kept = live.composer.draft
            let stagedFile = kept.replacingOccurrences(of: message, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let paths = live.composer.readyImagePaths + [stagedFile]
            for path in paths { try #require(try await projection.chatHostFiles().status(path)?.kind == .regular) }
            try await projection.pasteIntoAgent("LOCAL_UNSENT", paneID: live.fixture.pane)
            let held = await live.composer.send(policy: live.policy)
            guard case .refused = held else { Issue.record("The desktop draft did not hold the send"); return }
            #expect(live.composer.draft == kept && live.composer.readyImagePaths == Array(paths.prefix(1)))
            try await projection.sendAgentKeys(["ctrl+u"], to: live.fixture.pane)
            try #require(await live.composer.send(policy: live.policy) == .deliveredViaPrompt)
            try await live.wait { live.reply("FILE_AND_IMAGE_RECEIVED") }
            #expect(live.chat.conversation.transcript.recordedPrompts.contains { prompt in
                paths.allSatisfy { prompt.text.contains($0) } && prompt.text.contains("检查附件路径")
            })
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_SCENARIOS"] == "1"))
    func approvesOnlyTheTwoFilesInTheReviewedGitPatch() async throws {
        try await withLab { lab, host, projection in
            let live = try await self.live("patch", lab: lab, host: host, projection: projection)
            defer { live.chat.end() }
            try await live.wait { live.chat.droidSessionID != nil }
            let files = projection.chatHostFiles()
            for name in ["first.txt", "second.txt"] {
                try #require(try await files.status(live.fixture.directory + "/" + name) == nil)
            }
            try await live.send("Execute exactly git apply './two files.patch'. Use no other tools. Then reply PATCH_APPLIED.")
            let card = try await live.card(.droidPermission)
            let patch = try #require(card.patch)
            #expect(patch.contains("+++ b/first.txt") && patch.contains("+++ b/second.txt") && patch.contains("+SECOND"))
            await live.chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
            try await live.wait { live.reply("PATCH_APPLIED") }
            for (name, value) in [("first.txt", "FIRST\n"), ("second.txt", "SECOND\n")] {
                let chunk = try await files.read(.init(path: live.fixture.directory + "/" + name, offset: 0, maxBytes: 64))
                #expect(String(decoding: chunk.data, as: UTF8.self) == value)
            }
        }
    }
}

@MainActor
enum DroidLiveBackground {
    static func exercise(chat: AgentChatStore, send: (String) async throws -> Void,
                         poll: () async throws -> Void) async throws {
        func reply(_ marker: String) -> Bool {
            chat.conversation.transcript.entries.contains {
                if case .assistant(let message) = $0.content { return message.text.contains(marker) }
                return false
            }
        }
        func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let deadline = ContinuousClock.now + .seconds(75)
            while ContinuousClock.now < deadline {
                try await poll()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            try #require(condition(), "Droid background evidence did not arrive", sourceLocation: sourceLocation)
        }
        let id = try #require(chat.droidSessionID)
        let tag = UUID().uuidString.prefix(6)
        try await send("Use two Execute calls with fireAndForget true. First run: echo RED_\(tag); sleep 72. Separately run: echo BLUE_\(tag); sleep 42. Reply immediately with PARENT_\(tag). No other tools.")
        try await wait { reply("PARENT_\(tag)") && chat.backgroundWork.rows.filter(\.isRunning).count == 2 }
        chat.suspend()
        chat.resume()
        try await poll()
        let rows = chat.backgroundWork.rows
        let red = try #require(rows.first { $0.item.title.contains("RED_\(tag)") }?.item)
        let blue = try #require(rows.first { $0.item.title.contains("BLUE_\(tag)") }?.item)
        #expect(red.taskID != blue.taskID)
        let output = await chat.inspectDroidTask(red, session: id, stop: false)
        #expect(output.contains("RED_\(tag)") && !output.contains("BLUE_\(tag)"))
        let stop = await chat.inspectDroidTask(red, session: id, stop: true)
        try #require(stop.contains("Stop requested"))
        try await wait {
            let items = chat.conversation.transcript.backgroundWork
            return items.contains { $0.id == red.id && $0.state == .stopped }
                && items.contains { $0.id == blue.id && $0.state == .completed }
        }
        try await send("Use Task to launch an asynchronous worker. It must run sleep 8, then return CHILD_\(tag) only and write no files. Reply with PARENT_CHILD_\(tag) immediately after launch.")
        try await wait { reply("PARENT_CHILD_\(tag)") }
        try await wait {
            chat.conversation.transcript.backgroundWork.contains { $0.kind == .subagent && $0.reportedOutput?.contains("CHILD_\(tag)") == true }
        }
        #expect(chat.conversation.transcript.backgroundWork.filter { $0.kind == .subagent && $0.reportedOutput?.contains("CHILD_\(tag)") == true }.count == 1)
    }
}
