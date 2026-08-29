import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent Direct Input")
struct AgentDirectInputTests {
    @Test func softwareKeyboardPresentationIgnoresFirstResponderAlone() {
        let hardwareOnly = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(hardwareOnly.keyboardPresentation == .hidden)
        #expect(!hardwareOnly.showsShortcutRow)
        #expect(hardwareOnly.contentInset == 0)

        let softwareUp = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            currentHeight: 336,
            lastPresentedHeight: 336)
        #expect(softwareUp.keyboardPresentation == .system)
        #expect(softwareUp.showsShortcutRow)
        #expect(softwareUp.contentInset == 336)

        let tools = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: true,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(tools.keyboardPresentation == .tools)
        #expect(!tools.showsShortcutRow)
        #expect(tools.contentInset == 336)
    }

    @Test func hideAndShowComposerAccessibilityCopyIsProductionFacing() {
        #expect(
            AgentDirectInputPresentation.hideComposerAccessibilityLabel
                == "Hide Composer")
        #expect(
            AgentDirectInputPresentation.showComposerAccessibilityLabel
                == "Show Composer")
        #expect(
            AgentDirectInputPresentation.hideComposerAccessibilityHint.contains(
                "iOS keyboard"))
        #expect(
            AgentDirectInputPresentation.showComposerAccessibilityHint.contains(
                "draft"))
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

    @Test func hideComposerControlSelectsDirectAndRaisesKeyboard() async throws {
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

        #expect(
            Self.firstAccessible(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view) != nil)

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { inputMode.mode == .direct })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        try #require(await Self.eventually { terminal.isFirstResponder })
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.showComposerAccessibilityLabel,
                in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { inputMode.mode == .composer })

        let restored = try #require(Self.terminals(in: controller.view).first)
        #expect(!restored.isLocalInputEnabled)
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func coldPersistedDirectDoesNotRaiseKeyboard() async throws {
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
        #expect(terminal.isLocalInputEnabled)
        #expect(!terminal.isFirstResponder)
        #expect(
            Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)

        await owner.leave().value
    }

    @Test func shortcutRowButtonsSendBytesWhileSoftwareKeyboardIsUp() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode,
                keyboardInset: inset))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })

        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        for label in ["Escape", "Tab", "Shift Tab", "Enter"] {
            try #require(Self.activateAccessibility(labeled: label, in: controller.view))
        }

        try #require(await Self.eventually {
            let inputs = await transport.attachInputs
            return inputs.contains(.keystrokes(Data([0x1B])))
                && inputs.contains(.keystrokes(Data([0x09])))
                && inputs.contains(.keystrokes(Data([0x1B, 0x5B, 0x5A])))
                && inputs.contains(.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)
        #expect(
            AgentDirectInputPresentation.resolve(
                usesToolsKeyboard: false,
                currentHeight: inset.height,
                lastPresentedHeight: inset.lastPresentedHeight).contentInset == 0)

        await owner.leave().value
    }

    @Test func hardwareFirstResponderDoesNotReserveSoftwareKeyboardGap() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode(initial: .direct)
        defer { cleanup() }

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                inputMode: inputMode,
                keyboardInset: inset))
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { owner.terminalStatus == .live })

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        #expect(inset.lastPresentedHeight == 336)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        let presentation = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            currentHeight: inset.height,
            lastPresentedHeight: inset.lastPresentedHeight)
        #expect(terminal.isFirstResponder)
        #expect(presentation.keyboardPresentation == .hidden)
        #expect(!presentation.showsShortcutRow)
        #expect(presentation.contentInset == 0)
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)

        await owner.leave().value
    }

    @Test func directPasteRoutesThroughAttachReview() async throws {
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
        #expect(terminal.isLocalInputEnabled)
        terminal.requestPaste("git status\ngit diff")
        let pending = try #require(owner.pendingPaste)
        #expect(pending.text == "git status\ngit diff")
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        owner.confirmPaste()
        try #require(await Self.eventually {
            await transport.attachInputs.contains {
                if case .keystrokes(let data) = $0 {
                    return String(data: data, encoding: .utf8)?.contains("git status") == true
                }
                return false
            }
        })
        #expect(owner.pendingPaste == nil)

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

    @Test func terminalReplacementWhileDirectOwnsKeyboardClaimsIntent() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in }
        composer.replaceDraft(with: "keep")
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

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view))
        try #require(await Self.eventually { inputMode.mode == .direct })
        let first = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { first.isFirstResponder })
        let firstID = owner.terminalID
        let firstSurface = ObjectIdentifier(first)

        // Same-screen pipeline replacement (reconnect). Intent is owned by
        // Direct Input's presentation state, so the new surface claims without
        // raising a keyboard that was down.
        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually {
            owner.terminalID != firstID
        })
        #expect(await transport.emitAttachOutput(Data("replaced".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let replacement = try #require(Self.terminals(in: controller.view).first)
        #expect(ObjectIdentifier(replacement) != firstSurface)
        #expect(replacement.isLocalInputEnabled)
        try #require(await Self.eventually { replacement.isFirstResponder })
        #expect(composer.draft == "keep")

        await owner.leave().value
    }

    @Test func terminalReplacementWhileDirectKeyboardDownStaysDown() async throws {
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

        let first = try #require(Self.terminals(in: controller.view).first)
        #expect(!first.isFirstResponder)
        let firstID = owner.terminalID

        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually { owner.terminalID != firstID })
        #expect(await transport.emitAttachOutput(Data("still-down".utf8)))
        try #require(await Self.eventually { owner.terminalStatus == .live })

        let replacement = try #require(Self.terminals(in: controller.view).first)
        #expect(replacement.isLocalInputEnabled)
        #expect(!replacement.isFirstResponder)

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
        keyboardHandoff: TerminalKeyboardHandoff = TerminalKeyboardHandoff(),
        keyboardInset: TerminalKeyboardInset = TerminalKeyboardInset()
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
            keyboardInset: keyboardInset,
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

    private static func firstAccessible(labeled label: String, in root: UIView) -> NSObject? {
        func visit(_ node: NSObject) -> NSObject? {
            if node.accessibilityLabel == label {
                return node
            }
            if let elements = node.accessibilityElements {
                for element in elements {
                    if let object = element as? NSObject, let match = visit(object) {
                        return match
                    }
                }
            } else {
                let count = node.accessibilityElementCount()
                if count > 0, count != NSNotFound {
                    for index in 0..<count {
                        if let object = node.accessibilityElement(at: index) as? NSObject,
                            let match = visit(object)
                        {
                            return match
                        }
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    if let match = visit(subview) { return match }
                }
            }
            return nil
        }
        return visit(root)
    }

    @discardableResult
    private static func activateAccessibility(labeled label: String, in root: UIView) -> Bool {
        guard let element = firstAccessible(labeled: label, in: root) else { return false }
        if let control = element as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        return element.accessibilityActivate()
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
