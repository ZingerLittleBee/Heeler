import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent Direct Input")
struct AgentDirectInputTests {
    @Test func shortcutRowTracksSystemKeyboardPresentationOnly() {
        #expect(AgentDirectInputChrome.showsShortcutRow(presentation: .system))
        #expect(!AgentDirectInputChrome.showsShortcutRow(presentation: .hidden))
        #expect(!AgentDirectInputChrome.showsShortcutRow(presentation: .tools))
    }

    @Test func directKeyboardPresentationMatchesShellArithmetic() {
        #expect(
            AgentDirectInputChrome.keyboardPresentation(
                usesToolsKeyboard: false,
                insetHeight: 0,
                keyboardIsUp: true) == .system)
        #expect(
            AgentDirectInputChrome.keyboardPresentation(
                usesToolsKeyboard: false,
                insetHeight: 0,
                keyboardIsUp: false) == .hidden)
        #expect(
            AgentDirectInputChrome.keyboardPresentation(
                usesToolsKeyboard: true,
                insetHeight: 0,
                keyboardIsUp: true) == .tools)
        #expect(
            AgentDirectInputChrome.keyboardPresentation(
                usesToolsKeyboard: false,
                insetHeight: 336,
                keyboardIsUp: false) == .system)
    }

    @Test func composerModeStillRejectsLocalGhosttyInput() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "keep me")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode()
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(!terminal.isLocalInputEnabled)
        terminal.requestKeyboard()
        terminal.sendControlKey(.enter)
        await Task.yield()
        #expect(!terminal.isFirstResponder)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })
        #expect(composer.draft == "keep me")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func directInputEnablesLocalInputAndSendsPtyBytes() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "waiting draft")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.requestKeyboard()
        #expect(terminal.isFirstResponder)

        terminal.sendControlKey(.enter)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(Data([0x0D])))
        })
        #expect(composer.draft == "waiting draft")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func modeSwitchPreservesDraftAndSendsNothing() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "do not send")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode()
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        inputMode.select(.direct)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        inputMode.select(.composer)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        let restored = try #require(Self.terminals(in: controller.view).first)
        #expect(!restored.isLocalInputEnabled)
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func shortcutKeysWriteAgentQuickKeyBytes() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.sendQuickKey(.escape)
        terminal.sendQuickKey(.tab)
        terminal.sendQuickKey(.shiftTab)
        terminal.sendQuickKey(.enter)

        try #require(await Self.eventually {
            let inputs = await transport.attachInputs
            return inputs.contains(.keystrokes(Data([0x1B])))
                && inputs.contains(.keystrokes(Data([0x09])))
                && inputs.contains(.keystrokes(Data([0x1B, 0x5B, 0x5A])))
                && inputs.contains(.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func blockedStatusStaysInDirectInput() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) { _ in }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(status: .blocked),
                attachStore: owner,
                composer: composer,
                inputMode: inputMode))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        #expect(inputMode.mode == .direct)
        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.sendQuickKey(.enter)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func directHandoffClaimsGhosttyKeyboard() async throws {
        let handoff = TerminalKeyboardHandoff()
        let agent = Self.makeAgent(status: .idle)
        handoff.arm(for: agent.id)

        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: agent,
                attachStore: owner,
                composer: composer,
                inputMode: inputMode,
                keyboardHandoff: handoff))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        #expect(terminal.isFirstResponder)
        #expect(!handoff.consume(agent.id))

        await owner.leave().value
    }

    @Test func directToolsContextHidesDraftInsertTabs() throws {
        let suiteName = "direct-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        let skills = TerminalSkillsContext(
            store: SkillsPaneStore(commandPrefixes: ["/"]) { _ in [] })
        let direct = TerminalKeysContext(
            settings: settings,
            skills: skills,
            includesDraftTools: false,
            manageSnippets: {})
        #expect(direct.tabs == [.controls, .appearance])

        let composer = TerminalKeysContext(
            settings: settings,
            skills: skills,
            includesDraftTools: true,
            manageSnippets: {})
        #expect(composer.tabs == [.controls, .skills, .snippets, .appearance])
    }

    @Test func hideAndShowComposerAccessibilityCopy() {
        #expect(AgentInputMode.composer.segmentTitle == "Composer")
        #expect(AgentInputMode.direct.segmentTitle == "Keyboard")
        #expect(AgentQuickKey.escape.accessibilityLabel == "Escape")
        #expect(AgentQuickKey.tab.accessibilityLabel == "Tab")
        #expect(AgentQuickKey.shiftTab.accessibilityLabel == "Shift Tab")
        #expect(AgentQuickKey.enter.accessibilityLabel == "Enter")
    }

    private static func makeInputMode(
        initial: AgentInputMode = .composer
    ) throws -> (AgentInputModeSettings, () -> Void) {
        let suiteName = "direct-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AgentInputModeSettings(defaults: defaults)
        if initial != .composer {
            settings.select(initial)
        }
        return (settings, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private static func makeLiveAttach(
        transport: ScriptedTransport,
        composer: AgentComposerStore
    ) async throws -> AgentAttachStore {
        let owner = AgentAttachStore(
            target: "w1:p1",
            paneTitle: "Claude",
            transportGeneration: 1,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
        owner.rejoin()
        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })
        return owner
    }

    private static func makeDetailView(
        agent: ConsoleAgent? = nil,
        attachStore: AgentAttachStore,
        composer: AgentComposerStore,
        inputMode: AgentInputModeSettings,
        keyboardHandoff: TerminalKeyboardHandoff = TerminalKeyboardHandoff()
    ) -> AgentTerminalView {
        let defaults = UserDefaults(suiteName: "direct-detail-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))
        return AgentTerminalView(
            agent: agent ?? makeAgent(status: .idle),
            console: console,
            terminal: terminal,
            inputMode: inputMode,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: keyboardHandoff,
            keyboardInset: TerminalKeyboardInset(),
            isOnStage: { true },
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore)
    }

    private static func makeAgent(status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(),
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_w1:p1", kind: "claude", title: "",
                status: status, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                cwd: "/work", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil,
            lastOutputSnippet: nil)
    }

    private static func terminals(in root: UIView) -> [HeelerTerminalView] {
        var found: [HeelerTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? HeelerTerminalView {
                found.append(terminal)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func makeLocalTestWindow(
        frame: CGRect,
        rootViewController: UIViewController
    ) -> UIWindow {
        let window = UIWindow(frame: frame)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
