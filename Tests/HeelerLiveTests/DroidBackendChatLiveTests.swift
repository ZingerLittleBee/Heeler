import CryptoKit
import Foundation
import Testing

@testable import Heeler

/// Opt-in only. The fixture supplies a distinct disposable Droid UUID and a
/// private backend address for every target. Never send until both match.
@MainActor
@Suite("Droid Chat over SSH on three live backends", .serialized)
struct DroidBackendChatLiveTests {
    private struct Lab: Decodable, LiveChatBackendLab {
        let port: Int
        let user, seed, fingerprint, coreName, tmuxSocket, tmuxExecutable, rexSocket, rexSession, rexBlock: String
        let panes, sessions: [String: String]
        let factoryHome, directory: String
        var directories: [String: String]?
        var beginsAtTrust: Bool?
        var herdrSocket: String?
    }

    @Test(arguments: LiveChatLabSelection.cases([.herdrCore, .tmux, .rex]))
    func bindsSendsAndReadsTheReply(_ kind: ServerKind) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HEELER_DROID_BACKENDS_LAB"])
        let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let (projection, pane) = try lab.connection(kind)
        let host = projection.host
        projection.start(isActive: true)
        defer { projection.end() }
        let deadline = ContinuousClock.now + .seconds(30)
        while projection.agentsByPane[pane]?.agent.kind != "droid", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let directory = lab.directories?[kind.rawValue] ?? lab.directory
        let id: String
        if lab.beginsAtTrust == true {
            id = try await firstTrust(projection: projection, pane: pane, directory: directory)
        } else {
            id = try #require(lab.sessions[kind.rawValue])
        }
        let agent = try #require(projection.agentsByPane[pane]?.agent)
        let evidence = try await projection.checkChatSession(paneID: pane, program: .droid)
        guard case .bound(id, _, _) = evidence else {
            Issue.record("The foreground Droid did not bind its fixture UUID: \(evidence)")
            return
        }
        let typing = try #require(projection.checkedChatTyping(at: pane))
        var source = AgentChatSource(hostID: host.id, socketLocation: .namedSession("lab"), files: projection.chatHostFiles(),
            agentInfo: { try await projection.agentInfo(paneID: pane) }, cache: VolatileChatTranscriptCache(),
            adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)))
        source.sessionEvidence = { try await projection.checkChatSession(paneID: pane, program: .droid) }
        source.screen = typing.blockedScreen
        source.screen.droidTarget = { try await projection.droidDialogTarget(paneID: pane) }
        source.screen.hostName = host.name
        source.coreScope = projection.chatCacheScope
        let chat = AgentChatStore(agentID: .init(hostID: host.id, paneID: pane), agent: agent, program: .droid, source: source)
        defer { chat.end() }
        await chat.step()
        guard case .following(let file) = chat.conversation.phase, file.hasSuffix("/" + id + ".jsonl") else {
            Issue.record("Chat could not follow the fixture transcript: \(chat.conversation.phase)")
            return
        }
        let sender = projection.checkedComposerSend(
            for: pane, keepingTo: TerminalCorePin(joined: projection.inventoryCore), live: { projection })
        let checked = try #require(sender)
        let composer = AgentComposerStore(target: pane, checkedSend: checked) { _ in
            Issue.record("Droid bypassed this backend's checked sender")
            throw TransportError.cancelled
        }
        composer.bindDroidDraft(to: chat.droidSessionID)
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []),
            activity: { ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown) },
            readScreen: typing.blockedScreen.readScreen, droidTarget: source.screen.droidTarget, displayedDroidTarget: { chat.displayedDroidTarget }, confirmSession: { await chat.confirmSessionBeforeSend() })
        let token = "HEELER_DROID_" + UUID().uuidString.prefix(8)
        let prompt = "Reply with only the marker on the last line, without indentation or formatting. Do not use tools.\n\n    \(token)"
        try await waitForEmptyBox(typing.blockedScreen, projection: projection, pane: pane)
        composer.replaceDraft(with: prompt)
        chat.draftDidChange(to: prompt)
        let sent = await composer.send(policy: policy)
        try #require(sent == .deliveredViaAttach || sent == .submittedViaAttach || sent == .deliveredViaPrompt, "Droid send: \(sent)")
        let replyDeadline = ContinuousClock.now + .seconds(75)
        while ContinuousClock.now < replyDeadline {
            await chat.step()
            let transcript = chat.conversation.transcript
            if transcript.entries.contains(where: { $0.content == .assistant(.init(text: token)) }) {
                #expect(transcript.recordedPrompts.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }.count == 1)
                if ProcessInfo.processInfo.environment["HEELER_DROID_BACKEND_SCENARIOS"] == "1" {
                    try await checkScopedDialogs(chat: chat, composer: composer, policy: policy, projection: projection,
                                                 pane: pane, directory: directory)
                }
                try await checkDraftAfterNewSession(chat: chat, composer: composer, policy: policy, projection: projection,
                                                    pane: pane, previous: id)
                try await checkHookSetup(lab: lab, projection: projection, pane: pane, session: id, directory: directory)
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("Droid's answer did not reach the Chat timeline")
    }

    /// The external driver replaces only this dedicated server. Both the old
    /// and the new Droid must show their own live Create call for the same file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEELER_DROID_REPLACEMENT_LAB"] != nil),
          arguments: LiveChatLabSelection.cases([.herdrTUI, .herdrCore, .tmux, .rex]))
    func staleCardAndDraftCannotWriteToAReplacementServer(_ kind: ServerKind) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HEELER_DROID_REPLACEMENT_LAB"]))
        let directory = root.appendingPathComponent(kind.rawValue)
        func open(_ name: String) async throws -> (any ConsoleHostProjection, String, AgentChatStore, BlockedCard) {
            let file = directory.appendingPathComponent(name + ".json")
            let until = ContinuousClock.now + .seconds(90)
            while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(250))
            }
            let lab = try JSONDecoder().decode(Lab.self, from: Data(contentsOf: file))
            let (projection, pane) = try lab.connection(kind)
            projection.start(isActive: true)
            do {
                while projection.agentsByPane[pane]?.agent.kind != "droid", ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(200))
                }
                let agent = try #require(projection.agentsByPane[pane]?.agent)
                var io = projection.checkedChatTyping(at: pane)?.blockedScreen ?? BlockedScreenIO(
                    readScreen: { try await projection.readAgentScreen(pane) },
                    sendKeys: { try await projection.sendAgentKeys($0, to: pane) },
                    paste: { try await projection.pasteIntoAgent($0, paneID: pane) })
                io.droidTarget = { try await projection.droidDialogTarget(paneID: pane) }
                var source = AgentChatSource(hostID: projection.host.id, socketLocation: .defaultSession,
                    files: projection.chatHostFiles(), agentInfo: { try await projection.agentInfo(paneID: pane) },
                    cache: VolatileChatTranscriptCache(), adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)), screen: io)
                source.sessionEvidence = {
                    if let tui = projection as? HostConsoleProjection { return try await tui.droidSessionEvidence(paneID: pane) }
                    return try await projection.checkChatSession(paneID: pane, program: .droid)
                }
                let chat = AgentChatStore(agentID: .init(hostID: projection.host.id, paneID: pane), agent: agent, program: .droid, source: source)
                var trusted = false
                var asked = false
                while ContinuousClock.now < until {
                    if let listed = projection.agentsByPane[pane]?.agent { chat.agentDidChange(listed) }
                    await chat.step()
                    await chat.blocked.refresh()
                    if case .card(let card) = chat.blocked.content, card.dialog.kind == .droidPermission,
                       card.dialog.subject.filePath == "replacement.txt", card.request?.callID != nil,
                       card.target?.directory == lab.directory, card.target?.sessionID != nil {
                        return (projection, pane, chat, card)
                    }
                    let screen = try await io.readScreen()
                    if !trusted, let dialog = DroidDialog.parse(screen).dialog, dialog.kind == .droidWorkspaceTrust,
                       dialog.subject.workspacePath == lab.directory, dialog.focus.focusedOrdinal == 1 {
                        trusted = true
                        try await projection.sendAgentKeys(["enter"], to: pane)
                    } else if !asked, let target = try await projection.droidDialogTarget(paneID: pane),
                              target.directory == lab.directory, target.sessionID != nil, DroidInputBox.read(screen).isSendable {
                        asked = true
                        try await projection.pasteIntoAgent("Use Create once to write replacement.txt with REPLACEMENT. Stop if refused.", paneID: pane)
                        try await projection.sendAgentKeys(["enter"], to: pane)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                chat.end()
                throw TransportError.cancelled
            } catch {
                projection.end()
                throw error
            }
        }
        let (oldProjection, oldPane, oldChat, oldCard) = try await open("before")
        defer { oldChat.end(); oldProjection.end() }
        let oldTarget = try #require(oldCard.target)
        let sender = oldProjection.checkedComposerSend(for: oldPane,
            keepingTo: TerminalCorePin(joined: oldProjection.inventoryCore), live: { oldProjection })
        let composer = AgentComposerStore(target: oldPane, checkedSend: sender) { try await oldProjection.promptAgent($0) }
        let marker = "OLD_DROID_" + UUID().uuidString
        composer.bindDroidDraft(to: oldTarget.sessionID)
        composer.replaceDraft(with: marker)
        let policy = ComposerDeliveryPolicy.chat(rules: .init(program: .droid, commands: []), activity: { .idle },
            readScreen: oldChat.droidScreen.readScreen, droidTarget: oldChat.droidScreen.droidTarget, displayedDroidTarget: { oldTarget })
        await oldProjection.suspend()
        try Data().write(to: directory.appendingPathComponent("replace"), options: .atomic)
        let (fresh, pane, chat, card) = try await open("after")
        defer { chat.end(); fresh.end() }
        let newTarget = try #require(card.target)
        #expect(oldTarget != newTarget && oldTarget.sessionID != newTarget.sessionID)
        try #require(oldCard.request?.callID != card.request?.callID)
        await oldProjection.resume()
        await oldChat.blocked.perform(.choose(ordinal: 1), shownCard: oldCard)
        guard case .refused = await composer.send(policy: policy) else { Issue.record("Old draft left Heeler"); return }
        #expect(composer.draft == marker)
        let after = try await fresh.readAgentScreen(pane)
        #expect(DroidDialog.parse(after).dialog?.fingerprint == card.dialog.fingerprint)
        #expect(try await fresh.chatHostFiles().status(newTarget.directory + "/replacement.txt") == nil)
        #expect(!chat.conversation.transcript.recordedPrompts.contains { $0.text.contains(marker) })
        await chat.blocked.perform(.choose(ordinal: try #require(card.dialog.options.last?.ordinal)), shownCard: card)
        let resolved = ContinuousClock.now + .seconds(12)
        while DroidDialog.parse(try await fresh.readAgentScreen(pane)).dialog?.kind == .droidPermission, ContinuousClock.now < resolved {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(DroidDialog.parse(try await fresh.readAgentScreen(pane)).dialog?.kind != .droidPermission)
        #expect(try await fresh.chatHostFiles().status(newTarget.directory + "/replacement.txt") == nil)
        print("Droid evidence \(kind) held the old approval and draft across a live server replacement")
    }

    private func waitForEmptyBox(_ io: BlockedScreenIO, projection: any ConsoleHostProjection, pane: String) async throws {
        let until = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < until {
            let activity = projection.agentsByPane[pane]?.agent.status
            if activity != .working && activity != .blocked, DroidInputBox.read(try await io.readScreen()).isSendable { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ChatSourceUnavailable(reason: .cannotTellSession(.droid))
    }

    private func firstTrust(projection: any ConsoleHostProjection, pane: String, directory: String) async throws -> String {
        let agent = try #require(projection.agentsByPane[pane]?.agent)
        let typing = try #require(projection.checkedChatTyping(at: pane))
        var io = typing.blockedScreen
        io.droidTarget = { try await projection.droidDialogTarget(paneID: pane) }
        io.hostName = projection.host.name
        var source = AgentChatSource(hostID: projection.host.id, socketLocation: .namedSession("lab"),
            files: projection.chatHostFiles(), agentInfo: { try await projection.agentInfo(paneID: pane) },
            cache: VolatileChatTranscriptCache(), adapter: try #require(ChatTranscriptAdapter.standard(for: .droid)), screen: io)
        source.sessionEvidence = { try await projection.checkChatSession(paneID: pane, program: .droid) }
        source.coreScope = projection.chatCacheScope
        let chat = AgentChatStore(agentID: .init(hostID: projection.host.id, paneID: pane), agent: agent, program: .droid, source: source)
        defer { chat.end() }
        await chat.step()
        await chat.blocked.refresh()
        let raw = try await io.readScreen()
        let trust = try #require(DroidDialog.parse(raw).dialog)
        try #require(trust.kind == .droidWorkspaceTrust && trust.subject.workspacePath == directory)
        if projection is RexConsoleProjection, agent.status == .unknown {
            #expect(try await projection.droidDialogTarget(paneID: pane) == nil)
            if case .card = chat.blocked.content { Issue.record("Unknown Rex offered a native trust card") }
            // The user continues in this exact terminal block.
            try await projection.sendAgentKeys(["enter"], to: pane)
        } else {
            guard case .card(let card) = chat.blocked.content else {
                Issue.record("No native trust card on \(projection.host.serverKind), status \(agent.status), \(chat.conversation.phase)")
                throw TransportError.cancelled
            }
            try #require(card.target?.sessionID == nil && card.target?.directory == directory)
            await chat.blocked.perform(.choose(ordinal: 1), shownCard: card)
        }
        for _ in 0..<80 {
            if case .bound(let id, _, _) = try await projection.checkChatSession(paneID: pane, program: .droid) {
                print("Droid evidence \(projection.host.serverKind) followed the foreground UUID after trust (initial status \(agent.status))")
                return id
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ChatSourceUnavailable(reason: .cannotTellSession(.droid))
    }

    private func checkScopedDialogs(chat: AgentChatStore, composer: AgentComposerStore, policy: ComposerDeliveryPolicy,
                                    projection: any ConsoleHostProjection, pane: String, directory: String) async throws {
        let io = try #require(projection.checkedChatTyping(at: pane)).blockedScreen
        func observe() async throws {
            chat.agentDidChange(try #require(projection.agentsByPane[pane]?.agent))
            await chat.step()
            await chat.blocked.refresh()
        }
        func wait(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let until = ContinuousClock.now + .seconds(65)
            while ContinuousClock.now < until {
                try await observe()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(220))
            }
            try #require(condition(), "Droid on \(projection.host.serverKind) did not reach this state (\(chat.agent.status), \(chat.conversation.phase))", sourceLocation: sourceLocation)
        }
        func card(_ kind: BlockedDialogKind, suffix: String? = nil) async throws -> BlockedCard {
            var result: BlockedCard?
            try await wait {
                guard case .card(let found) = chat.blocked.content, found.dialog.kind == kind,
                      found.request?.callID != nil && found.target?.sessionID == chat.droidSessionID else { return false }
                if let suffix, found.request?.summary.hasSuffix(suffix) != true { return false }
                result = found
                return true
            }
            return try #require(result)
        }
        func send(_ text: String) async throws {
            try await waitForEmptyBox(io, projection: projection, pane: pane)
            composer.replaceDraft(with: text)
            chat.draftDidChange(to: text)
            let result = await composer.send(policy: policy)
            try #require(result == .submittedViaAttach || result == .deliveredViaPrompt || result == .deliveredViaAttach, "Droid submission: \(result)")
        }
        func selectAutonomy(_ name: String) async throws {
            try await waitForEmptyBox(io, projection: projection, pane: pane)
            for _ in 0..<5 {
                let screen = try await io.readScreen()
                try #require(DroidInputBox.read(screen).isSendable)
                if screen.rows.contains(where: { $0.trimmedText.hasPrefix("Auto (\(name))") }) { return }
                try await projection.sendAgentKeys(["ctrl+l"], to: pane)
                try await Task.sleep(for: .milliseconds(350))
            }
            try #require(Bool(false), "The fixture could not select \(name) autonomy on \(projection.host.serverKind)")
        }
        try await selectAutonomy("Off")
        let tag = UUID().uuidString.prefix(8)
        let a = "approval-a-" + tag + ".txt"
        let b = "approval-b-" + tag + ".txt"
        let files = projection.chatHostFiles()
        try #require(try await files.status(directory + "/" + a) == nil)
        try #require(try await files.status(directory + "/" + b) == nil)
        try await send("Use Create to write \(a) with content ALPHA and one newline. After it succeeds use a separate Create call for \(b). If declined, stop. No other tools.")
        let first = try await card(.droidPermission, suffix: a)
        await chat.blocked.perform(.choose(ordinal: 1), shownCard: first)
        let second = try await card(.droidPermission, suffix: b)
        try #require(first.request?.callID != second.request?.callID)
        try await projection.sendAgentKeys(["esc"], to: pane)
        await chat.blocked.perform(.choose(ordinal: 1), shownCard: second)
        await chat.blocked.perform(.choose(ordinal: 1), shownCard: first)
        try await wait { chat.conversation.transcript.pendingRequests.isEmpty && chat.agent.status != .working && chat.agent.status != .blocked }
        let bytes = try await files.read(.init(path: directory + "/" + a, offset: 0, maxBytes: 48))
        #expect(String(decoding: bytes.data, as: UTF8.self) == "ALPHA\n")
        #expect(try await files.status(directory + "/" + b) == nil)
        print("Droid evidence \(projection.host.serverKind) approved A, desktop declined B, stale cards held")
        try await send("Use AskUser to ask one question, 'Which marker?', with options Scarlet or Azure. When I submit, reply with the selected option only.")
        let ask = try await card(.droidQuestion)
        let value = try #require(ask.dialog.options.first)
        await chat.blocked.perform(.choose(ordinal: value.ordinal), shownCard: ask)
        // Droid submits a single question immediately. A multi-question form has a review page.
        try await wait {
            chat.conversation.transcript.entries.contains {
                if case .assistant(let m) = $0.content { return m.text.localizedCaseInsensitiveContains("scarlet") }
                return false
            } && chat.agent.status != .working && chat.agent.status != .blocked
        }
        print("Droid evidence \(projection.host.serverKind) submitted the selected AskUser answer")
        try await selectAutonomy("High")
        try await DroidLiveBackground.exercise(chat: chat, send: send, poll: observe)
        print("Droid evidence \(projection.host.serverKind) stopped red, blue completed, late child reported once")
    }

    /// Only a fixture SSH account may receive setup files from this test.
    private func checkHookSetup(
        lab: Lab, projection: any ConsoleHostProjection, pane: String, session: String, directory: String
    ) async throws {
        let files = projection.chatHostFiles()
        let home = try await files.home()
        try #require(URL(fileURLWithPath: home).standardizedFileURL.path == lab.factoryHome)
        try #require(lab.factoryHome.hasPrefix("/tmp/") && lab.factoryHome.hasSuffix("/account"))
        let config = RemoteFilePath.join(home, ".factory", "settings.json")
        func readSettings() async throws -> Data {
            try await files.read(.init(path: config, offset: 0, maxBytes: 64 << 10)).data
        }
        let before = try await readSettings()
        if let rex = projection as? RexConsoleProjection {
            try await rex.configureDroidChatHook(.register, keepingTo: TerminalCorePin(joined: rex.inventoryCore))
            let after = try await readSettings()
            #expect(DroidChatHook.presence(in: after, script: RemoteFilePath.join(home, ".factory", "hooks", DroidChatHook.fileName)) == .on)
            let json = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
            let hooks = try #require(json["hooks"] as? [String: [[String: Any]]])
            #expect(hooks["SessionStart"]?.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { $0["command"] as? String == "true" } == true
            } == true)
            try await rex.configureDroidChatHook(.register, keepingTo: TerminalCorePin(joined: rex.inventoryCore))
            #expect(try await readSettings() == after)
            try await rex.configureDroidChatHook(.removeRegistration, keepingTo: TerminalCorePin(joined: rex.inventoryCore))
            #expect(try await readSettings() == before)
            return
        }
        let request = AgentLaunchRequest(kind: "droid", name: "droid-lab-" + UUID().uuidString.prefix(8).lowercased(),
                                        workspaceID: projection.agentsByPane[pane]?.agent.workspaceID, cwd: directory)
        let started: Agent
        if let core = projection as? HerdrCoreConsoleProjection {
            started = try await core.startAgent(request)
        } else {
            started = try await #require(projection as? TmuxConsoleProjection).startAgent(request)
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if case .bound(let id, _, _) = try? await projection.checkChatSession(paneID: started.paneID, program: .droid) {
                #expect(id != session)
                #expect(try await readSettings() == before)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("New Agent did not bind the separately launched Droid in the same directory")
    }

    /// Switch from the terminal while the phone still shows the old transcript.
    /// A send must return the original draft and the new transcript must be empty.
    private func checkDraftAfterNewSession(
        chat: AgentChatStore, composer: AgentComposerStore, policy: ComposerDeliveryPolicy,
        projection: any ConsoleHostProjection, pane: String, previous: String
    ) async throws {
        let draft = "Draft for the previous Droid conversation"
        composer.replaceDraft(with: draft)
        chat.draftDidChange(to: draft)
        let screen = try #require(projection.checkedChatTyping(at: pane)).blockedScreen
        try await waitForEmptyBox(screen, projection: projection, pane: pane)
        // The desktop changes the box after ordinary preflight succeeds, while
        // the transport still has to acquire its writer.
        let desktopDraft = "DESKTOP_" + UUID().uuidString.prefix(8)
        var raced = policy
        let preflight = policy.preflight
        raced.preflight = { text in
            if let refusal = await preflight?(text) { return refusal }
            do { try await projection.pasteIntoAgent(desktopDraft, paneID: pane) }
            catch { Issue.record("Could not stage the desktop draft: \(error)") }
            return nil
        }
        let held = await composer.send(policy: raced)
        guard case .refused = held else { Issue.record("Desktop draft was submitted: \(held)"); return }
        try #require(try await DroidInputBox.read(screen.readScreen()) == .text(desktopDraft))
        #expect(composer.draft == draft)
        try await projection.sendAgentKeys(["ctrl+u"], to: pane)
        try await waitForEmptyBox(screen, projection: projection, pane: pane)

        var switched: String?
        raced.preflight = { text in
            if let refusal = await preflight?(text) { return refusal }
            do {
                try await projection.pasteIntoAgent("/new", paneID: pane)
                try await projection.sendAgentKeys(["enter"], to: pane)
                var confirmed = false
                let deadline = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < deadline {
                    let evidence = try await projection.checkChatSession(paneID: pane, program: .droid)
                    if case .bound(let next, _, _) = evidence, next != previous {
                        switched = next
                        return nil
                    }
                    if !confirmed, case .bound(let shown, _, _) = evidence, shown == previous {
                        let rows = try await screen.readScreen().rows.map(\.trimmedText)
                        if rows.contains(where: { $0.contains("Droid is still working — stop the current run and run /new?") }),
                           rows.suffix(5).contains(where: { $0.contains("Enter to confirm, ESC to cancel") }) {
                            confirmed = true
                            try await projection.sendAgentKeys(["enter"], to: pane)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch { Issue.record("Desktop switch failed: \(error)") }
            return .inputNotReady("The fixture did not open a new conversation")
        }
        let result = await composer.send(policy: raced)
        let next = try #require(switched)
        guard case .refused = result else { Issue.record("Old draft reached the new session: \(result)"); return }
        #expect(composer.draft == draft)
        _ = await chat.confirmSessionBeforeSend()
        await chat.step()
        guard case .following(let path) = chat.conversation.phase else {
            Issue.record("Chat did not follow Droid after /new")
            return
        }
        #expect(path.hasSuffix("/" + next + ".jsonl"))
        #expect(chat.conversation.transcript.recordedPrompts.isEmpty)
        try #require(try await DroidInputBox.read(screen.readScreen()).isSendable)
        composer.bindDroidDraft(to: next)
        #expect(composer.draft.isEmpty)
        try await checkInterrupt(chat: chat, composer: composer, policy: policy, projection: projection, pane: pane)
    }

    private func checkInterrupt(
        chat: AgentChatStore, composer: AgentComposerStore, policy: ComposerDeliveryPolicy,
        projection: any ConsoleHostProjection, pane: String
    ) async throws {
        let typing = try #require(projection.checkedChatTyping(at: pane)).blockedScreen
        let plan = ChatStopPlan.standard(for: .droid)
        let screenGuard = try #require(plan.screenGuard)
        let keys = ChatAgentKeysStore(send: { try await projection.sendAgentKeys($0, to: pane) })
        let context: @MainActor () async throws -> ChatStopContext = {
            try await .init(screen: typing.readScreen(), activity: ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown))
        }
        @MainActor func interrupt(_ verify: @escaping ChatStopVerification) -> AgentComposerInterrupt {
            projection.checkedChatStop(for: pane, program: .droid, keepingTo: TerminalCorePin(joined: projection.inventoryCore),
                agentKeys: keys, followThrough: nil, confirmTarget: verify, live: { projection })
                ?? plan.composerInterrupt(context: context, agentKeys: keys, confirmTarget: verify)
        }
        var previous: AgentComposerInterrupt?
        for tag in ["first", "second"] {
            composer.replaceDraft(with: "List the numbers from one to two thousand on separate lines. Begin with " + tag + ". Do not use tools.")
            chat.draftDidChange(to: composer.draft)
            let result = await composer.send(policy: policy)
            try #require(result == .submittedViaAttach || result == .deliveredViaAttach || result == .deliveredViaPrompt)
            let deadline = ContinuousClock.now + .seconds(25)
            var pressed = false
            while ContinuousClock.now < deadline {
                await chat.step()
                let activity = ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown)
                if let turn = chat.conversation.transcript.turns.last, turn.ending == nil,
                   screenGuard(.init(screen: try await typing.readScreen(), activity: activity)) == .press {
                    let current = interrupt(chat.droidStopVerification())
                    if let previous {
                        try #require(await previous.perform() == .failed(ChatStopPlan.changedDroidTurn))
                    }
                    try #require(await current.perform() == .sent)
                    previous = current
                    pressed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            try #require(pressed)
            let idleDeadline = ContinuousClock.now + .seconds(20)
            var interrupted = false
            while ContinuousClock.now < idleDeadline {
                await chat.step()
                if chat.conversation.transcript.turns.last?.ending == .interrupted,
                   ChatAgentActivity(projection.agentsByPane[pane]?.agent.status ?? .unknown) == .idle,
                   DroidInputBox.read(try await typing.readScreen()).isSendable {
                    interrupted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            try #require(interrupted)
        }
        print("Droid evidence \(projection.host.serverKind) held the old Stop and interrupted only its selected turn")
    }
}
