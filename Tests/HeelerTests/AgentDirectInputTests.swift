import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent Direct Input")
struct AgentDirectInputTests {
    @Test func productionLayoutSeamTracksSoftwareKeyboardOnly() {
        let hardwareOnly = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(hardwareOnly.keyboardPresentation == .hidden)
        #expect(!hardwareOnly.showsShortcutRow)
        #expect(hardwareOnly.layout.contentInset == 0)

        let softwareUp = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 336,
            lastPresentedHeight: 336)
        #expect(softwareUp.keyboardPresentation == .system)
        #expect(softwareUp.showsShortcutRow)
        #expect(softwareUp.layout.contentInset == 336)

        let tools = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: true,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(tools.keyboardPresentation == .tools)
        #expect(!tools.showsShortcutRow)
        #expect(tools.layout.contentInset == 336)
    }

    @Test func toolsToSystemPreShowKeepsStableInset() {
        // Shared TerminalAttachTests contract: `.system` with currentHeight 0
        // still reserves lastPresentedHeight during the Tools→iOS swap.
        let midSwap = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: true,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(midSwap.keyboardPresentation == .system)
        #expect(midSwap.showsShortcutRow)
        #expect(midSwap.layout.contentInset == 336)
        #expect(midSwap.layout.availableToolsHeight == 336)

        let withoutHold = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(withoutHold.keyboardPresentation == .hidden)
        #expect(withoutHold.layout.contentInset == 0)
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(!terminal.isLocalInputEnabled)
        terminal.requestKeyboard()
        terminal.sendControlKey(TerminalControlKey.enter)
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

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
        try #require(await Self.eventually { inputMode.mode == AgentInputMode.direct })

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
        try #require(await Self.eventually { inputMode.mode == AgentInputMode.composer })

        let restored = try #require(Self.terminals(in: controller.view).first)
        #expect(!restored.isLocalInputEnabled)
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func coldPersistedDirectDoesNotRaiseKeyboard() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        #expect(!terminal.isFirstResponder)
        #expect(
            Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)

        await owner.leave().value
    }

    @Test func ghosttyReturnSendsPtyCRWithoutComposerPrompt() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })

        // Soft-keyboard Return enters through UIKeyInput.insertText("\n"),
        // not sendControlKey / sendQuickKey. Production maps that to PTY CR.
        (terminal as UIKeyInput).insertText("\n")
        try #require(await Self.eventually {
            await transport.attachInputs.contains(
                TerminalAttachInput.keystrokes(Data([0x0D])))
        })
        #expect(composer.draft == "waiting draft")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func shortcutRowButtonsSendBytesWhileSoftwareKeyboardIsUp() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })

        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)
        controller.view.layoutIfNeeded()
        let heightBeforeKeyboard = terminal.frame.height

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
        let heightWithKeyboard = try #require(Self.terminals(in: controller.view).first)
            .frame.height

        for label in ["Escape", "Tab", "Shift Tab", "Enter"] {
            try #require(Self.activateAccessibility(labeled: label, in: controller.view))
        }

        try #require(await Self.eventually {
            let inputs = await transport.attachInputs
            return inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x09])))
                && inputs.contains(
                    TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x5A])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        // Rendered production inset: AgentTerminalKeyboardInsetModifier must
        // shrink the hosted terminal by the software-keyboard height.
        #expect(heightBeforeKeyboard - heightWithKeyboard >= 336)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)
        let heightAfterHide = try #require(Self.terminals(in: controller.view).first)
            .frame.height
        #expect(abs(heightAfterHide - heightBeforeKeyboard) < 1)

        await owner.leave().value
    }

    @Test func toolsToSystemSwapKeepsShortcutRowThroughCoalesce() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
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
        let heightWithSoftwareKeyboard = try #require(
            Self.terminals(in: controller.view).first).frame.height
        let shortcutRowID =
            AgentDirectInputPresentation.shortcutRowAccessibilityIdentifier
        try #require(await Self.eventually {
            Self.firstAccessible(identifier: shortcutRowID, in: controller.view) != nil
        })

        try #require(
            Self.activateAccessibility(labeled: "Show tools keyboard", in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Tools presentation hides the software-keyboard shortcut row; wait for
        // that source-specific identity rather than the shared Escape label the
        // Tools keypad also speaks.
        try #require(await Self.eventually {
            Self.firstAccessible(identifier: shortcutRowID, in: controller.view) == nil
        })

        // UIKit tears the software keyboard down while Tools stays first
        // responder — the production hold must keep `.system` once we leave Tools.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        try #require(
            Self.activateAccessibility(labeled: "Show iOS keyboard", in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        // Pre-show `.system` hold: shortcut row stays adjacent to the keyboard
        // footprint even while measured height is still zero. Two-sided bound:
        // wiring the modifier to the raw zero height expands the terminal by
        // ~lastPresentedHeight and still satisfies a one-sided upper bound.
        #expect(
            Self.firstAccessible(identifier: shortcutRowID, in: controller.view) != nil)
        let midSwapTerminal = try #require(Self.terminals(in: controller.view).first)
        #expect(midSwapTerminal.isFirstResponder)
        #expect(abs(heightWithSoftwareKeyboard - midSwapTerminal.frame.height) <= 1)

        // Software keyboard actually appears — hold must release without a
        // transient `.hidden` dip (row and inset stay).
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
        #expect(
            Self.firstAccessible(identifier: shortcutRowID, in: controller.view) != nil)
        let afterShow = try #require(Self.terminals(in: controller.view).first)
        #expect(afterShow.isFirstResponder)
        #expect(abs(afterShow.frame.height - heightWithSoftwareKeyboard) < 1)

        // Hardware keyboard hides the software keyboard while Ghostty remains
        // first responder. Released hold must not keep a stale inset or row.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let afterHardwareHide = try #require(Self.terminals(in: controller.view).first)
        #expect(afterHardwareHide.isFirstResponder)
        #expect(
            Self.firstAccessible(identifier: shortcutRowID, in: controller.view) == nil)
        #expect(afterHardwareHide.frame.height - heightWithSoftwareKeyboard >= 336)

        await owner.leave().value
    }

    @Test func hardwareFirstResponderDoesNotReserveSoftwareKeyboardGap() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        #expect(inset.lastPresentedHeight == 336)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let heightWithSoftwareKeyboard = try #require(
            Self.terminals(in: controller.view).first).frame.height

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        let hardwareTerminal = try #require(Self.terminals(in: controller.view).first)
        #expect(hardwareTerminal.isFirstResponder)
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) == nil)
        // No software keyboard: production inset must not reserve lastPresentedHeight.
        #expect(hardwareTerminal.frame.height - heightWithSoftwareKeyboard >= 336)

        await owner.leave().value
    }

    @Test func directPasteRoutesThroughAttachReview() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.requestPaste("git status\ngit diff")
        let pending = try #require(owner.pendingPaste)
        #expect(pending.preview == "git status\ngit diff")
        #expect(pending.lineCount == 2)
        #expect(pending.characterCount == "git status\ngit diff".count)
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
        let composer = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        #expect(inputMode.mode == AgentInputMode.direct)
        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.sendQuickKey(AgentQuickKey.enter)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(
                TerminalAttachInput.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func terminalReplacementWhileDirectOwnsKeyboardClaimsIntent() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view))
        try #require(await Self.eventually { inputMode.mode == AgentInputMode.direct })
        let first = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { first.isFirstResponder })
        let firstID = owner.terminalID
        let firstSurface = ObjectIdentifier(first)

        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually {
            owner.terminalID != firstID
        })
        // Replacement pipeline is a fresh Attach waiting for its first size.
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("replaced".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        // Hosted UI may still expose the predecessor surface briefly after the
        // replacement Attach is live — wait for a distinct rendered terminal.
        try #require(await Self.eventually {
            Self.terminals(in: controller.view).contains {
                ObjectIdentifier($0) != firstSurface
            }
        })

        let replacement = try #require(
            Self.terminals(in: controller.view).first {
                ObjectIdentifier($0) != firstSurface
            })
        #expect(ObjectIdentifier(replacement) != firstSurface)
        #expect(replacement.isLocalInputEnabled)
        try #require(await Self.eventually { replacement.isFirstResponder })
        #expect(composer.draft == "keep")

        await owner.leave().value
    }

    @Test func dismissAfterReplacementDoesNotRaiseOnSecondReplacement() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let (inputMode, cleanup) = try Self.makeInputMode()
        defer { cleanup() }
        let handoff = TerminalKeyboardHandoff()
        let agent = Self.makeAgent(status: .idle)

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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view))
        try #require(await Self.eventually { inputMode.mode == AgentInputMode.direct })
        let first = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { first.isFirstResponder })
        let firstID = owner.terminalID

        // Replacement while keyboard up — intent reclaim, not a leftover handoff.
        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually { owner.terminalID != firstID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("first-replace".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        let afterFirst = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { afterFirst.isFirstResponder })

        // Production dismiss clears Direct Input raised intent. A leftover
        // TerminalKeyboardHandoff arm after the first replacement must not
        // resurrect the keyboard on the next pipeline rebuild.
        try #require(await Self.eventually {
            Self.firstAccessible(labeled: "Dismiss keyboard", in: controller.view) != nil
        })
        try #require(
            Self.activateAccessibility(labeled: "Dismiss keyboard", in: controller.view))
        try #require(await Self.eventually { !afterFirst.isFirstResponder })
        #expect(!handoff.consume(agent.id))

        let secondID = owner.terminalID
        owner.transportGenerationDidChange(3)
        try #require(await Self.eventually { owner.terminalID != secondID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 3
        })
        #expect(await transport.emitAttachOutput(Data("second-replace".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let afterSecond = try #require(Self.terminals(in: controller.view).first)
        #expect(afterSecond.isLocalInputEnabled)
        #expect(!afterSecond.isFirstResponder)
        #expect(!handoff.consume(agent.id))

        await owner.leave().value
    }

    @Test func terminalReplacementWhileDirectKeyboardDownStaysDown() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
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
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let first = try #require(Self.terminals(in: controller.view).first)
        #expect(!first.isFirstResponder)
        let firstID = owner.terminalID

        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually { owner.terminalID != firstID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("still-down".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

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
        // Fresh stores start `.active` with `.waitingForSize`. `rejoin()` is a
        // no-op until leave/rejoinRequired, so open the channel the same way
        // production does: the first positive size report.
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
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
        firstAccessible(in: root) { $0.accessibilityLabel == label }
    }

    private static func firstAccessible(
        identifier: String, in root: UIView
    ) -> NSObject? {
        firstAccessible(in: root) { $0.accessibilityIdentifier == identifier }
    }

    private static func firstAccessible(
        in root: UIView, matching: (NSObject) -> Bool
    ) -> NSObject? {
        func visit(_ node: NSObject) -> NSObject? {
            if matching(node) {
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
