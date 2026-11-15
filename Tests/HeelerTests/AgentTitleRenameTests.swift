import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Native Agent title rename", .serialized)
struct AgentTitleRenameTests {
    @Test(arguments: ChatProgram.allCases.filter(AgentTitleNaming.supportsRename))
    func savesNativeTitleAndRefreshes(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        store.input = "  Updated guide ✅  "
        await store.save()
        #expect(store.state == .renamed)
        #expect(rig.refreshes == 1)
        if program == .opencode {
            #expect(rig.commands.isEmpty)
            #expect(rig.pastes == ["Updated guide ✅"])
            #expect(rig.keys == [["ctrl+r"], ["ctrl+e", "ctrl+u"], ["enter"]])
        } else {
            #expect(rig.commands == [(program == .pi ? "/name " : "/rename ") + "Updated guide ✅"])
        }
    }

    @Test(arguments: [ChatProgram.claude, .codex, .omp])
    func regeneratesThroughNativeCommand(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        await store.generate()
        #expect(store.state == .renamed)
        #expect(rig.commands == ["/rename"])
        #expect(rig.keys == (program == .codex ? [["enter"]] : []))
        #expect(rig.refreshes == 1)
    }

    /// Antigravity CLI prints its rename confirmation on screen without setting
    /// a terminal title by default, and `/rename` with no argument is an error.
    @Test func antigravityConfirmsRenameOnScreenWithoutGeneration() async throws {
        #expect(ChatProgram.allCases.allSatisfy(AgentTitleNaming.supportsRename))
        #expect(!AgentTitleNaming.supportsGeneration(.agy))
        let rig = try Rig(.agy)
        rig.apply = false
        rig.afterCommand = {
            rig.screenOverride = ANSIScreenDecoder.decode("> /rename Updated guide ✅\n  ⎿  Conversation renamed to: Updated guide ✅")
        }
        let store = rig.store()
        store.input = "Updated guide ✅"
        await store.save()
        #expect(store.state == .renamed)
        #expect(rig.commands == ["/rename Updated guide ✅"])
        #expect(rig.refreshes == 1)
    }

    @Test func antigravityRenameFailureKeepsManualDraft() async throws {
        let rig = try Rig(.agy)
        rig.apply = false
        rig.afterCommand = {
            rig.screenOverride = ANSIScreenDecoder.decode("> /rename Keep my draft\n  ⎿  Error: Failed to rename conversation: no active conversation")
        }
        let store = rig.store()
        store.input = "Keep my draft"
        await store.save()
        #expect(store.input == "Keep my draft")
        #expect(!store.outcomeUncertain)
        #expect(store.canSave)
    }

    @Test(arguments: [ChatProgram.pi, .grok, .opencode, .agy])
    func unsupportedGenerationSendsNothing(program: ChatProgram) async throws {
        let rig = try Rig(program)
        let store = rig.store()
        #expect(store.generationUnavailable != nil)
        await store.generate()
        #expect(rig.commands.isEmpty)
        #expect(rig.keys.isEmpty)
    }

    @Test(arguments: ["", "   ", "hello\n/exit", "title\u{2028}/exit", "title\u{1b}[A", String(repeating: "x", count: 121)])
    func invalidInputSendsNothing(value: String) async throws {
        let rig = try Rig(.claude)
        let store = rig.store()
        store.input = value
        await store.save()
        #expect(!store.canSave)
        #expect(rig.commands.isEmpty)
    }

    @Test(arguments: [AgentStatus.working, .blocked, .unknown])
    func busyAgentSendsNothing(status: AgentStatus) async throws {
        let rig = try Rig(.claude)
        rig.status = status
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.commands.isEmpty)
        #expect(!store.outcomeUncertain)
    }

    @Test func refusesDraftAndChangedSession() async throws {
        let rig = try Rig(.claude)
        let store = rig.store()
        store.input = "New title"
        rig.screenOverride = ANSIScreenDecoder.decode("❯ unfinished draft")
        await store.save()
        #expect(rig.commands.isEmpty)
        rig.screenOverride = nil
        rig.session = "another-conversation"
        await store.save()
        #expect(rig.commands.isEmpty)
    }

    @Test func refusesMissingSession() async throws {
        let rig = try Rig(.pi)
        rig.session = nil
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.commands.isEmpty)
    }

    @Test func noAcknowledgementDoesNotReplay() async throws {
        let rig = try Rig(.claude)
        rig.apply = false
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(store.outcomeUncertain)
        await store.save()
        await store.generate()
        #expect(rig.commands == ["/rename New title"])
        #expect(store.input == "New title")
    }

    @Test func generationFailureKeepsManualDraft() async throws {
        let rig = try Rig(.omp)
        rig.apply = false
        let store = rig.store()
        store.input = "Keep my draft"
        rig.afterCommand = { rig.screenOverride = ANSIScreenDecoder.decode("Could not generate a session title. Use /rename <title> to set one.") }
        await store.generate()
        #expect(store.input == "Keep my draft")
        #expect(!store.outcomeUncertain)
        #expect(store.canSave)
        #expect(rig.title == "Original")
    }

    @Test(arguments: [ChatProgram.claude, .omp])
    func generationMayConfirmTheSameTitle(program: ChatProgram) async throws {
        let rig = try Rig(program)
        rig.apply = false
        rig.afterCommand = {
            rig.screenOverride = ANSIScreenDecoder.decode(program == .claude
                ? "Session renamed to: Original"
                : "Session renamed to \"📝 MANUAL: Original\".")
        }
        let store = rig.store()
        await store.generate()
        #expect(store.state == .renamed)
    }

    /// The acknowledgement is matched against the Agent's own English output,
    /// so it never follows the app's language.
    @Test func nativeAcknowledgementIsTheAgentsOwnLine() {
        #expect(
            AgentTitleRenameStore.nativeAcknowledgement(program: .claude, title: "Original")
                == "Session renamed to: Original")
        #expect(
            AgentTitleRenameStore.nativeAcknowledgement(program: .omp, title: "π > 📝 MANUAL: Original")
                == "Session renamed to \"📝 MANUAL: Original\".")
        #expect(
            AgentTitleRenameStore.nativeAcknowledgement(program: .agy, title: "Original")
                == "Conversation renamed to: Original")
        for program in [ChatProgram.codex, .pi, .grok, .opencode] {
            #expect(AgentTitleRenameStore.nativeAcknowledgement(program: program, title: "Original") == nil)
        }
    }

    @Test func sessionChangeAfterPromptNeverConfirmsDialog() async throws {
        let rig = try Rig(.codex)
        rig.afterCommand = { rig.session = "changed" }
        let store = rig.store()
        await store.generate()
        #expect(store.outcomeUncertain)
        #expect(rig.keys.isEmpty)
    }

    @Test func duplicateOperationsShareOneLease() async throws {
        let rig = try Rig(.claude)
        let first = rig.store()
        let second = rig.store()
        first.input = "First"
        second.input = "Second"
        rig.afterCommand = { await second.save() }
        await first.save()
        #expect(first.state == .renamed)
        #expect(rig.commands == ["/rename First"])
        if case .failed = second.state {} else { Issue.record("second rename should be refused") }
    }

    @Test func openCodeFullTitleMatchesTruncatedTerminalTitle() async throws {
        let rig = try Rig(.opencode)
        rig.title = String(repeating: "Long title ", count: 6)
        rig.openCodeInitial = rig.title
        let store = rig.store()
        store.input = "Short replacement"
        await store.save()
        #expect(store.state == .renamed)
        #expect(rig.pastes == ["Short replacement"])
    }

    @Test func openCodeDialogChangeNeverClearsUserInput() async throws {
        let rig = try Rig(.opencode)
        rig.openCodeInitial = "Different conversation"
        let store = rig.store()
        store.input = "New title"
        await store.save()
        #expect(rig.keys == [["ctrl+r"]])
        #expect(rig.pastes.isEmpty)
    }

    @Test func nativeDialogParsersRequireTheirBoundedShape() {
        #expect(AgentTitleRenameStore.codexSuggestion(ANSIScreenDecoder.decode("Rename thread\nGenerating a title suggestion…\n› Old\nenter submit · esc back")) == nil)
        #expect(AgentTitleRenameStore.codexSuggestion(ANSIScreenDecoder.decode("Rename thread\nSuggested from this conversation\n› New\nenter submit · esc back")) == "New")
        #expect(AgentTitleRenameStore.openCodeField(ANSIScreenDecoder.decode("Rename session esc\n\nNew\n\nsubmit enter")) == "New")
        #expect(AgentTitleRenameStore.openCodeField(ANSIScreenDecoder.decode("Rename session\nSome transcript text")) == nil)
    }

    @Test func openCodeEmptyPlaceholderIsNotAnEnteredTitle() {
        let muted = SGR.fg(128, 128, 128)
        let input = SGR.fg(238, 238, 238)
        let header = input + "Rename session    " + muted + "esc" + SGR.reset
        let placeholder = ANSIScreenDecoder.decode(header + "\n\n" + muted + "Session title" + SGR.reset + "\n\nsubmit enter")
        let literal = ANSIScreenDecoder.decode(header + "\n\n" + input + "Session title" + SGR.reset + "\n\nsubmit enter")
        #expect(AgentTitleRenameStore.openCodeField(placeholder) == "")
        #expect(AgentTitleRenameStore.openCodeField(literal) == "Session title")
    }

    @Test func codexShortenedDirectoryDoesNotBecomePartOfTheTitle() {
        let agent = Agent(terminalID: "term", kind: "codex", title: "Guide | worktree-silver-cloud...",
            status: .idle, workspaceID: "w", tabID: "t", paneID: "p",
            cwd: "/worktree-silver-cloud-364f", revision: 1)
        #expect(AgentTitleNaming.title(of: agent, program: .codex) == "Guide")
        #expect(AgentTitleNaming.matches(agent, program: .codex, title: "Guide"))
    }

    @Test func clearButtonClearsTitleOnTrailingEdgeAndFocusesInput() async throws {
        let rig = try Rig(.claude)
        let gate = SaveGate()
        rig.afterCommand = { await gate.wait() }
        let store = rig.store()
        store.input = "Host 插件与 helper 升级提示 UI"
        let controller = UIHostingController(rootView: AgentTitleRenameSheet(store: store))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            try await waitUntil {
                !Self.views(UITextField.self, in: window).isEmpty
                    && accessibleElement(labeled: "Clear text", in: window) != nil
            }
            let textField = try #require(Self.views(UITextField.self, in: window).first)
            let clear = try #require(accessibleElement(labeled: "Clear text", in: window))
            let fieldFrame = UIAccessibility.convertToScreenCoordinates(textField.bounds, in: textField)
            #expect(clear.accessibilityFrame.minX >= fieldFrame.maxX - 1)
            #expect(clear.accessibilityFrame.width >= 16)
            let cell = Self.enclosingCell(of: textField)
            let initialCellHeight = cell?.bounds.height

            #expect(clear.accessibilityActivate())
            try await waitUntil {
                store.input.isEmpty
                    && accessibleElement(labeled: "Clear text", in: window) == nil
                    && textField.isFirstResponder
            }
            #expect(textField.text == "")
            #expect(!store.canSave)
            #expect(textField.isFirstResponder)
            if let initialCellHeight, let currentHeight = cell?.bounds.height {
                #expect(abs(currentHeight - initialCellHeight) <= 1)
            }

            textField.text = "Fresh title"
            textField.sendActions(for: .editingChanged)
            try await waitUntil {
                store.input == "Fresh title"
                    && accessibleElement(labeled: "Clear text", in: window) != nil
            }

            let saveTask = Task { await store.save() }
            try await waitUntil { store.isBusy && accessibleElement(labeled: "Clear text", in: window) == nil }
            await gate.open()
            await saveTask.value
            #expect(store.state == .renamed)
        }
    }

    @Test func deferredSaveConfirmationsAndSuppressNextTime() async throws {
        let suiteName = "AgentTitleRenameTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hostID = UUID()
        let pendingStore = PendingAgentTitleRenameStore(defaults: defaults)
        let rig = try Rig(.claude)
        rig.status = .working

        let first = rig.store(hostID: hostID, pendingStore: pendingStore)
        first.input = "  First queued  "
        await first.save()
        #expect(rig.commands.isEmpty)
        #expect(first.state == .editing)
        #expect(first.deferredSaveConfirmation?.title == "First queued")
        #expect(pendingStore.entries.isEmpty)

        first.cancelDeferredSave()
        #expect(first.deferredSaveConfirmation == nil)
        #expect(first.state == .editing)
        #expect(pendingStore.entries.isEmpty)

        await first.save()
        #expect(first.deferredSaveConfirmation?.title == "First queued")
        first.confirmDeferredSave(suppressNextTime: false)
        #expect(first.deferredSaveConfirmation == nil)
        #expect(first.state == .renamed)
        #expect(!pendingStore.suppressBusyNotice)
        let agentID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        #expect(pendingStore.entries[agentID]?.title == "First queued")

        // Reloading from UserDefaults restores the queued rename and notice preference.
        let reloaded = PendingAgentTitleRenameStore(defaults: defaults)
        #expect(!reloaded.suppressBusyNotice)
        #expect(reloaded.entries[agentID]?.title == "First queued")

        // Without "Don't Show Again", saving again while running still asks for confirmation.
        let second = rig.store(hostID: hostID, pendingStore: pendingStore)
        #expect(second.hasQueuedRename)
        second.input = "Second queued"
        await second.save()
        #expect(second.deferredSaveConfirmation?.title == "Second queued")
        second.confirmDeferredSave(suppressNextTime: true)
        #expect(second.state == .renamed)
        #expect(pendingStore.suppressBusyNotice)
        #expect(pendingStore.entries[agentID]?.title == "Second queued")

        // Once "Don't Show Again" is chosen, future saves while running queue immediately without prompting.
        rig.status = .blocked
        let third = rig.store(hostID: hostID, pendingStore: pendingStore)
        third.input = "Third immediate"
        await third.save()
        #expect(third.deferredSaveConfirmation == nil)
        #expect(third.state == .renamed)
        #expect(pendingStore.entries[agentID]?.title == "Third immediate")

        // Marking dispatched removes the entry from persistent storage immediately so an unconfirmed write never replays.
        pendingStore.markDispatched(agentID)
        #expect(PendingAgentTitleRenameStore(defaults: defaults).entries.isEmpty)
    }

    @Test func deferredSaveSheetPresentsConfirmationAlertAndSuppressOption() async throws {
        let hostID = UUID()
        let pendingStore = PendingAgentTitleRenameStore()
        let rig = try Rig(.claude)
        rig.status = .working
        let store = rig.store(hostID: hostID, pendingStore: pendingStore)
        store.input = "Saved while busy"
        let controller = UIHostingController(rootView: AgentTitleRenameSheet(store: store))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            try await waitUntil { accessibleElement(labeled: "Save", in: window) != nil }
            await store.save()
            try await waitUntil {
                (controller.presentedViewController as? UIAlertController) != nil
            }
            let alert = try #require(controller.presentedViewController as? UIAlertController)
            #expect(alert.title == "Rename After Agent Stops?")
            let actionTitles = alert.actions.compactMap(\.title)
            #expect(actionTitles == ["Save", "Save and Don’t Show Again", "Cancel"])
            #expect(alert.actions[2].style == .cancel)

            store.confirmDeferredSave(store.deferredSaveConfirmation, suppressNextTime: true)
            alert.dismiss(animated: false)
            #expect(store.state == .renamed)
            #expect(pendingStore.suppressBusyNotice)
            #expect(pendingStore.entries[ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")]?.title == "Saved while busy")
        }

        let reopened = rig.store(hostID: hostID, pendingStore: pendingStore)
        #expect(reopened.hasQueuedRename)
        let reopenedController = UIHostingController(rootView: AgentTitleRenameSheet(store: reopened))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: reopenedController
        ) { window in
            try await waitUntil {
                Self.views(UILabel.self, in: window).contains {
                    $0.text == "Saved on this device. Will be sent once the Agent stops."
                }
            }
        }
    }

    @Test func consoleStoreQueuesRenameWhileWorkingAndFlushesWhenIdleOrDropsOnSessionChange() async throws {
        let suiteName = "AgentTitleRenameTests.Console.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let host = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        let files = VirtualHostFiles(home: "/home/dev")
        let readyScreen = try ScreenFixture.text("claude-01-ready")

        func makeInfo(
            title: String, sessionID: String, status: AgentStatus, revision: Int
        ) -> AgentInfo {
            AgentInfo(
                agentStatus: status, focused: false, paneID: "w1:p1", revision: revision,
                tabID: "w1:t1", terminalID: "term-1", workspaceID: "w1",
                agent: ChatProgram.claude.rawValue,
                agentSession: AgentSessionInfo(
                    agent: ChatProgram.claude.rawValue, kind: .id, source: "test", value: sessionID),
                cwd: "/home/dev/proj",
                terminalTitleStripped: title,
                title: title)
        }

        let workingInfo = makeInfo(title: "Initial", sessionID: "session-one", status: .working, revision: 1)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [workingInfo]))
        await transport.setPaneText(readyScreen, paneID: "w1:p1")
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(workingInfo))

        let pendingStore = PendingAgentTitleRenameStore(defaults: defaults)
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            chatPrefetchRetryDelay: .milliseconds(20),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions, connect: { transport },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                    keepalive: nil)
            },
            pendingTitleRenames: pendingStore,
            pendingTitleRenameSleep: { _ in try await Task.sleep(for: .milliseconds(5)) })
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil { store.agents.first?.agent.title == "Initial" }

        let initialRow = try #require(store.agents.first)
        let rename = try #require(store.titleRenameStore(for: initialRow))
        rename.input = "Queued While Running"
        await rename.save()
        #expect(rename.deferredSaveConfirmation?.title == "Queued While Running")
        rename.confirmDeferredSave(suppressNextTime: false)
        #expect(rename.state == .renamed)

        // Immediately visible on iOS surfaces and persisted locally, with nothing sent while working.
        #expect(store.agents.first?.agent.title == "Queued While Running")
        #expect(store.detailAgent(for: initialRow.id)?.agent.title == "Queued While Running")
        #expect(defaults.data(forKey: PendingAgentTitleRenameStore.storageKey) != nil)
        #expect((await transport.agentPromptParams).isEmpty)

        // Reopening Rename while still running seeds the queued title and marks it queued.
        let queuedRow = try #require(store.agents.first)
        let reopened = try #require(store.titleRenameStore(for: queuedRow))
        #expect(reopened.input == "Queued While Running")
        #expect(reopened.hasQueuedRename)

        // Gate the outgoing prompt so we can verify UserDefaults is cleared before completion.
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let idleInfo = makeInfo(title: "Initial", sessionID: "session-one", status: .idle, revision: 2)
        await transport.setSnapshot(.fixture(agents: [idleInfo]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(idleInfo))
        await transport.emit(HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))

        await promptGate.waitForEntry()
        #expect(await transport.agentPromptParams == [
            AgentPromptParams(target: "w1:p1", text: "/rename Queued While Running")
        ])
        #expect(defaults.data(forKey: PendingAgentTitleRenameStore.storageKey) == nil)

        let renamedInfo = makeInfo(
            title: "Queued While Running", sessionID: "session-one", status: .idle, revision: 3)
        await transport.setSnapshot(.fixture(agents: [renamedInfo]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(renamedInfo))
        await promptGate.open()

        try await waitUntil {
            pendingStore.entries.isEmpty && store.agents.first?.agent.title == "Queued While Running"
        }

        // If the Agent starts working again, queues a new rename, and switches conversations before stopping,
        // the queued rename is dropped without dispatching anything to the new conversation.
        let workingAgain = makeInfo(
            title: "Queued While Running", sessionID: "session-one", status: .working, revision: 4)
        await transport.setSnapshot(.fixture(agents: [workingAgain]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(workingAgain))
        await transport.emit(HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
        try await waitUntil { store.agents.first?.agent.status == .working }

        let workingRow = try #require(store.agents.first)
        let secondRename = try #require(store.titleRenameStore(for: workingRow))
        secondRename.input = "Drop On New Session"
        await secondRename.save()
        secondRename.confirmDeferredSave(suppressNextTime: true)
        #expect(store.agents.first?.agent.title == "Drop On New Session")

        let otherSessionIdle = makeInfo(
            title: "Fresh Topic", sessionID: "session-two", status: .idle, revision: 5)
        await transport.setSnapshot(.fixture(agents: [otherSessionIdle]))
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(otherSessionIdle))
        await transport.emit(HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))

        try await waitUntil {
            pendingStore.entries.isEmpty && store.agents.first?.agent.title == "Fresh Topic"
        }
        #expect((await transport.agentPromptParams).count == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        var budget = PollBudget(.seconds(3))
        while !condition(), budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        try #require(condition())
    }

    private static func views<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }

    private static func enclosingCell(of view: UIView) -> UICollectionViewCell? {
        var current: UIView? = view.superview
        while let candidate = current {
            if let cell = candidate as? UICollectionViewCell { return cell }
            current = candidate.superview
        }
        return nil
    }

    private actor SaveGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    @MainActor
    private final class Rig {
        let program: ChatProgram
        let empty: ANSIScreen
        var title = "Original"
        var session: String? = "session-one"
        var status: AgentStatus = .idle
        var commands: [String] = []
        var keys: [[String]] = []
        var pastes: [String] = []
        var refreshes = 0
        var held = false
        var apply = true
        var field: String?
        var openCodeInitial = "Original"
        var screenOverride: ANSIScreen?
        var afterCommand: (() async -> Void)?

        init(_ program: ChatProgram) throws {
            self.program = program
            let fixture: String = switch program {
            case .claude: "claude-01-ready"
            case .codex: "codex-00-ready"
            case .pi: "pi-16-empty-editor-120-attached"
            case .omp: "omp-08-empty-120-after-first"
            case .grok: "grok-01-idle-empty"
            case .opencode: "opencode-02-session-empty-180"
            case .agy: "agy-02-idle-empty-120x40"
            }
            empty = try ScreenFixture.screen(fixture)
        }

        func agent() -> Agent {
            let displayed: String = switch program {
            case .claude: title
            case .codex: title + " | project"
            case .pi: "π - " + title + " - project"
            case .omp: "π > 📝 MANUAL: " + title
            case .grok: title + " - grok"
            case .opencode: OpenCodeTerminalTitle.expected(sessionTitle: title)
            case .agy: title
            }
            return Agent(terminalID: "term-one", kind: program.rawValue, title: displayed, status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/project", revision: 1,
                terminalTitleStripped: displayed,
                agentSession: session.map { AgentSessionInfo(agent: program.rawValue, kind: .id, source: "test", value: $0) })
        }

        func store(
            hostID: Host.ID = UUID(), pendingStore: PendingAgentTitleRenameStore? = nil
        ) -> AgentTitleRenameStore {
            let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
            var seeded = agent()
            if let pendingStore {
                let wrapped = ConsoleAgent(
                    hostID: hostID, hostName: "test", agent: seeded, workspaceLabel: "w1",
                    repositoryCheckout: nil)
                seeded = pendingStore.applying(to: wrapped).agent
            }
            return AgentTitleRenameStore(agent: seeded, program: program, io: AgentTitleRenameIO(
                agent: { self.agent() },
                screen: {
                    if let override = self.screenOverride { return override }
                    if let field = self.field {
                        return ANSIScreenDecoder.decode(self.program == .opencode
                            ? "Rename session esc\n\n\(field)\n\nsubmit enter"
                            : "Rename thread\nSuggested from this conversation\n\n› \(field)\n\nenter submit · esc back")
                    }
                    return self.empty
                },
                prompt: { command in
                    self.commands.append(command)
                    if self.apply {
                        if command == "/rename", self.program == .codex { self.field = "Generated title" }
                        else { self.title = command == "/rename" ? "Generated title" : String(command.dropFirst(command.hasPrefix("/name ") ? 6 : 8)) }
                    }
                    await self.afterCommand?()
                },
                keys: { keys in
                    self.keys.append(keys)
                    if keys == ["ctrl+r"] { self.field = self.openCodeInitial }
                    if keys == ["ctrl+e", "ctrl+u"] { self.field = "" }
                    if keys == ["enter"], let field = self.field { self.title = field; self.field = nil }
                },
                paste: { self.pastes.append($0); self.field = $0 },
                refresh: { self.refreshes += 1 },
                queueWhenIdle: pendingStore.map { pendingStore in
                    { liveAgent, title in
                        pendingStore.enqueue(
                            PendingAgentTitleRename(
                                hostID: hostID,
                                paneID: liveAgent.paneID,
                                terminalID: liveAgent.terminalID,
                                workspaceID: liveAgent.workspaceID,
                                tabID: liveAgent.tabID,
                                program: self.program,
                                session: liveAgent.agentSession,
                                title: title))
                    }
                },
                clearQueued: pendingStore.map { pendingStore in
                    { pendingStore.remove(id) }
                },
                hasQueuedRename: {
                    guard let pendingStore else { return false }
                    let wrapped = ConsoleAgent(
                        hostID: hostID, hostName: "test", agent: self.agent(),
                        workspaceLabel: "w1", repositoryCheckout: nil)
                    return pendingStore.hasUndispatched(for: wrapped)
                },
                shouldSuppressBusyNotice: { pendingStore?.suppressBusyNotice == true },
                setSuppressBusyNotice: { pendingStore?.suppressBusyNotice = $0 },
                acquire: { if self.held { return false }; self.held = true; return true },
                release: { self.held = false },
                sleep: { _ in }))
        }
    }
}

@MainActor
@Suite struct AntigravityTitleRenameTests {
    @MainActor
    private final class AgyHarness {
        let empty: ANSIScreen
        let draft: ANSIScreen
        var title = "Original"
        var status: AgentStatus = .idle
        var session: String? = "5f0d2b6c-1234-4abc-9def-0123456789ab"
        var screenOverride: ANSIScreen?
        var commands: [String] = []
        var refreshes = 0
        var held = false
        var onPrompt: ((String, AgyHarness) async -> Void)?
        var initialTitleProvider: (() async -> String?)?

        init() throws {
            empty = try ScreenFixture.screen("agy-02-idle-empty-120x40")
            draft = try ScreenFixture.screen("agy-14-idle-draft-oneline-120x40")
        }

        func agent() -> Agent {
            Agent(
                terminalID: "term-agy", kind: ChatProgram.agy.rawValue, title: title, status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/project", revision: 1,
                terminalTitleStripped: title,
                agentSession: session.map {
                    AgentSessionInfo(agent: ChatProgram.agy.rawValue, kind: .id, source: "herdr:antigravity_cli", value: $0)
                })
        }

        func store() -> AgentTitleRenameStore {
            AgentTitleRenameStore(
                agent: agent(), program: .agy,
                io: AgentTitleRenameIO(
                    agent: { self.agent() },
                    screen: { self.screenOverride ?? self.empty },
                    prompt: { command in
                        self.commands.append(command)
                        await self.onPrompt?(command, self)
                    },
                    keys: { _ in },
                    paste: { _ in },
                    refresh: { self.refreshes += 1 },
                    initialTitle: initialTitleProvider,
                    acquire: {
                        guard !self.held else { return false }
                        self.held = true
                        return true
                    },
                    release: { self.held = false },
                    sleep: { _ in }))
        }
    }

    @Test func wrappedAgyAcknowledgementMatchesAcrossRowsAndStopsAtSeparators() {
        let acknowledgement = "Conversation renamed to: Investigate Long Topic Title"
        let wrappedWithSpaceSplit = """
            > /rename Investigate Long Topic Title
              ⎿  Conversation renamed to: Investigate Long Topic
                 Title
            """
        let wrappedMidWord = """
            > /rename InvestigateLongWordTitle
              ⎿  Conversation renamed to: InvestigateLong
                 WordTitle
            """
        let incompleteAcrossSeparator = """
              ⎿  Conversation renamed to: Investigate Long
            ────────
                 Topic Title
            """

        #expect(AgentTitleRenameStore.acknowledgementCount(acknowledgement, program: .agy, in: wrappedWithSpaceSplit) == 1)
        #expect(
            AgentTitleRenameStore.acknowledgementCount(
                "Conversation renamed to: InvestigateLongWordTitle", program: .agy, in: wrappedMidWord) == 1)
        #expect(AgentTitleRenameStore.acknowledgementCount(acknowledgement, program: .agy, in: incompleteAcrossSeparator) == 0)
    }

    @Test func refreshInitialTitleUpdatesUneditedInputAndPreservesUserEdit() async throws {
        let rig = try AgyHarness()
        rig.title = ""
        var latestFromDisk: String? = "Title From Host"
        rig.initialTitleProvider = { latestFromDisk }

        let store = rig.store()
        #expect(store.input.isEmpty)
        #expect(!store.canSave)

        await store.refreshInitialTitle()
        #expect(store.input == "Title From Host")
        #expect(store.canSave)

        latestFromDisk = "Renamed On Mac"
        await store.refreshInitialTitle()
        #expect(store.input == "Renamed On Mac")

        store.input = "Draft By User"
        latestFromDisk = "Should Not Clobber"
        await store.refreshInitialTitle()
        #expect(store.input == "Draft By User")
    }

}
