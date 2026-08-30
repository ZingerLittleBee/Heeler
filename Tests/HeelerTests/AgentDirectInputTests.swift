import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent Direct Input", .serialized)
struct AgentDirectInputTests {
    @Test func productionLayoutSeamTracksSoftwareKeyboardOnly() {
        let hardwareOnly = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(hardwareOnly.keyboardPresentation == .hidden)
        #expect(hardwareOnly.layout.contentInset == 0)

        let softwareUp = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 336,
            lastPresentedHeight: 336)
        #expect(softwareUp.keyboardPresentation == .system)
        #expect(softwareUp.layout.contentInset == 336)

        let tools = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: true,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(tools.keyboardPresentation == .tools)
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

    @Test func accessibilityTraversalFallsBackToIndexedContainerWhenElementsAreEmpty() {
        let root = IndexedAccessibilityContainerView(indexedLabel: "Indexed control")

        #expect(Self.firstAccessible(labeled: "Indexed control", in: root) != nil)
    }

    @Test func accessibilityTraversalIncludesIndexedElementsWhenArrayIsIncomplete() {
        let root = IndexedAccessibilityContainerView(
            indexedLabel: "Indexed control",
            arrayLabel: "Array control")

        #expect(Self.firstAccessible(labeled: "Indexed control", in: root) != nil)
    }

    @Test func sharedActionMenuContractIsExhaustive() {
        #expect(
            AgentActionMenuPolicy.composerAddSections == [.addAttachments])
        #expect(
            AgentActionMenuPolicy.composerMoreSections
                == [.sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuPolicy.directInputMoreSections
                == [.addAttachments, .sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuSection.addAttachments.items
                == [.addImage, .addFile])
        #expect(
            AgentActionMenuSection.sessionTools.items
                == [.openTerminal, .newAgent, .skills, .snippets])
        #expect(
            AgentActionMenuSection.agentLifecycle.items
                == [.worktreeDetails, .renameAgent, .renameWorkspace, .closeAgent])
        #expect(
            AgentActionMenuItem.allCases
                == AgentActionMenuSection.allCases.flatMap(\.items))

        let metadata: [(AgentActionMenuItem, String, String, Bool, Bool)] = [
            (.addImage, "Add Image", "photo", false, true),
            (.addFile, "Add File", "doc", false, true),
            (.openTerminal, "Open Terminal", "apple.terminal", false, false),
            (.newAgent, "New Agent", "plus", false, false),
            (.skills, "Skills", "sparkles", false, true),
            (.snippets, "Snippets", "quote.bubble", false, true),
            (.worktreeDetails, "Worktree Details", "arrow.triangle.branch", false, false),
            (.renameAgent, "Rename Agent", "pencil", false, false),
            (.renameWorkspace, "Rename Workspace", "pencil.line", false, false),
            (.closeAgent, "Close Agent", "trash", true, false),
        ]
        for (item, title, systemImage, isDestructive, isDraftOwned) in metadata {
            #expect(item.title == title)
            #expect(item.systemImage == systemImage)
            #expect((item.role == .destructive) == isDestructive)
            #expect(item.isDraftOwned == isDraftOwned)
        }
    }

    @Test func sharedActionMenuAvailabilityAndDispatchCoverAllGates() {
        enum Event: Equatable {
            case addImage, addFile, openTerminal, startAgent, skills, snippets
            case worktree, renameAgent, renameWorkspace, closeAgent
        }
        var events: [Event] = []
        let gated = AgentComposerActions(
            canBegin: false,
            attachLinkCount: 0,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            showAttachLinks: {},
            openTerminal: nil,
            isOpeningTerminal: false,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: nil,
            showWorktreeDetails: nil,
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            closeAgent: { events.append(.closeAgent) })
        let busy = AgentComposerActions(
            canBegin: true,
            attachLinkCount: 0,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            showAttachLinks: {},
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: true,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            closeAgent: { events.append(.closeAgent) })
        let ready = AgentComposerActions(
            canBegin: true,
            attachLinkCount: 0,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            showAttachLinks: {},
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: false,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            closeAgent: { events.append(.closeAgent) })

        let availability: [(AgentActionMenuItem, AgentComposerActions, Bool, Bool)] = [
            (.addImage, gated, true, false),
            (.addFile, gated, true, false),
            (.openTerminal, gated, true, false),
            (.openTerminal, busy, true, false),
            (.openTerminal, ready, true, true),
            (.newAgent, ready, true, true),
            (.skills, gated, false, true),
            (.skills, ready, true, true),
            (.snippets, ready, true, true),
            (.worktreeDetails, gated, false, true),
            (.worktreeDetails, ready, true, true),
            (.renameAgent, ready, true, true),
            (.renameWorkspace, ready, true, true),
            (.closeAgent, ready, true, true),
        ]
        for (item, actions, visible, enabled) in availability {
            #expect(AgentActionMenuPolicy.isVisible(item, actions: actions) == visible)
            #expect(AgentActionMenuPolicy.isEnabled(item, actions: actions) == enabled)
        }

        for item in AgentActionMenuItem.allCases {
            AgentActionMenuPolicy.perform(item, actions: ready)
        }
        #expect(
            events == [
                .addImage, .addFile, .openTerminal, .startAgent, .skills, .snippets,
                .worktree, .renameAgent, .renameWorkspace, .closeAgent,
            ])
    }

    @Test func directInputRestoreComposerThenRunsBeforeDraftOwnedActions() {
        enum Step: Equatable {
            case restore
            case action(AgentActionMenuItem)
        }
        var steps: [Step] = []
        let actions = AgentComposerActions(
            canBegin: true,
            attachLinkCount: 0,
            addImage: { steps.append(.action(.addImage)) },
            addFile: { steps.append(.action(.addFile)) },
            showAttachLinks: {},
            openTerminal: { steps.append(.action(.openTerminal)) },
            isOpeningTerminal: false,
            startAgent: { steps.append(.action(.newAgent)) },
            manageSnippets: { steps.append(.action(.snippets)) },
            showSkills: { steps.append(.action(.skills)) },
            showWorktreeDetails: { steps.append(.action(.worktreeDetails)) },
            renameAgent: { steps.append(.action(.renameAgent)) },
            renameWorkspace: { steps.append(.action(.renameWorkspace)) },
            closeAgent: { steps.append(.action(.closeAgent)) })
        let restoreComposerThen: (@escaping () -> Void) -> Void = { action in
            steps.append(.restore)
            action()
        }

        for item in AgentActionMenuItem.allCases {
            AgentActionMenuPolicy.dispatch(
                item,
                actions: actions,
                restoreComposerThen: restoreComposerThen)
        }

        #expect(
            steps == [
                .restore, .action(.addImage),
                .restore, .action(.addFile),
                .action(.openTerminal),
                .action(.newAgent),
                .restore, .action(.skills),
                .restore, .action(.snippets),
                .action(.worktreeDetails),
                .action(.renameAgent),
                .action(.renameWorkspace),
                .action(.closeAgent),
            ])

        steps.removeAll()
        for item in AgentActionMenuItem.allCases where item.isDraftOwned {
            AgentActionMenuPolicy.dispatch(item, actions: actions)
        }
        #expect(
            steps == [
                .action(.addImage), .action(.addFile),
                .action(.skills), .action(.snippets),
            ])
    }

    @Test func keyboardClaimPolicyUnifiesReplacementAndAgentSwitchGates() {
        #expect(
            !AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: true,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: true,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: true,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 336))
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

    @Test func composerAndDirectInputTransferVisibleKeyboardWithoutReloading() async throws {
        let center = NotificationCenter.default
        let inset = TerminalKeyboardInset(notificationCenter: center)
        let keyboardTransitions = KeyboardTransitionProbe(
            notificationCenter: center,
            insetHeight: { inset.height })
        defer { keyboardTransitions.stop() }
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
                inputMode: inputMode,
                keyboardInset: inset))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(!terminal.isLocalInputEnabled)
        let composerInput = try #require(
            Self.firstView(in: controller.view) {
                $0 is UITextView && $0.accessibilityLabel == "Message the Agent"
            } as? UITextView)
        composerInput.becomeFirstResponder()
        try #require(await Self.eventually { composerInput.isFirstResponder })
        try #require(await Self.eventually { composerInput.inputView == nil })
        try #require(await Self.eventually {
            inset.height > 0
                && (keyboardTransitions.willShowCount > 0
                    || keyboardTransitions.willChangeFrameCount > 0)
        })
        let keyboardHeight = inset.height
        #expect(window.isKeyWindow)
        #expect(composerInput.window === window)
        keyboardTransitions.setChromeSample {
            Self.keyboardChromeSample(in: controller.view, window: window, inset: inset)
        }
        keyboardTransitions.reset()
        try #require(await Self.eventually { keyboardTransitions.hasStableTail() })
        keyboardTransitions.reset()

        #expect(
            Self.firstAccessible(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view) != nil)

        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.hideComposerAccessibilityLabel,
                in: controller.view))
        // The measured keyboard stays in place while SwiftUI updates the
        // existing terminal and transfers first responder to it.
        #expect(inset.height == keyboardHeight)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            inputMode.mode == AgentInputMode.direct
                && terminal.isLocalInputEnabled
                && terminal.isFirstResponder
                && !inset.isHoldingHandoffHeight
                && keyboardTransitions.observedHandoffWindow()
                && keyboardTransitions.hasStableTail()
        })
        keyboardTransitions.stopSampling()
        #expect(!composerInput.isFirstResponder)
        #expect(terminal.window === window)
        #expect(inset.height == keyboardHeight)
        #expect(
            keyboardTransitions.observedInsetHeights.allSatisfy { $0 == keyboardHeight },
            "Composer→Direct Input exposed transient insets: \(keyboardTransitions.observedInsetHeights)")
        Self.expectStableKeyboardChrome(
            keyboardTransitions.chromeSamples,
            keyboardHeight: keyboardHeight,
            direction: "Composer→Direct Input")
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        keyboardTransitions.reset()
        try #require(
            Self.activateAccessibility(
                labeled: AgentDirectInputPresentation.showComposerAccessibilityLabel,
                in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            inputMode.mode == AgentInputMode.composer
                && !inset.isHoldingHandoffHeight
                && keyboardTransitions.observedHandoffWindow()
                && keyboardTransitions.hasStableTail()
        })
        keyboardTransitions.stopSampling()

        let restored = try #require(Self.terminals(in: controller.view).first)
        let restoredComposerInput = try #require(
            Self.firstView(in: controller.view) {
                $0 is UITextView && $0.accessibilityLabel == "Message the Agent"
            } as? UITextView)
        #expect(!restored.isLocalInputEnabled)
        #expect(restoredComposerInput.isFirstResponder)
        #expect(restoredComposerInput.autocorrectionType == terminal.autocorrectionType)
        #expect(restoredComposerInput.autocapitalizationType == terminal.autocapitalizationType)
        #expect(!terminal.isFirstResponder)
        #expect(inset.height == keyboardHeight)
        #expect(
            keyboardTransitions.observedInsetHeights.allSatisfy { $0 == keyboardHeight },
            "Direct Input→Composer exposed transient insets: \(keyboardTransitions.observedInsetHeights)")
        Self.expectStableKeyboardChrome(
            keyboardTransitions.chromeSamples,
            keyboardHeight: keyboardHeight,
            direction: "Direct Input→Composer")
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
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)

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

    @Test func shortcutRowPersistsAndSendsBytesAcrossKeyboardVisibility() async throws {
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

        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
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

        for label in [
            "Escape", "Tab", "Shift Tab", "Backspace", "Shift Enter", "Enter",
            "Up Arrow", "Down Arrow", "Left Arrow", "Right Arrow",
        ] {
            try #require(Self.activateAccessibility(labeled: label, in: controller.view))
        }

        // Shortcut row sits immediately above the Agent switcher strip.
        // Keyboard dismiss lives only on the switcher — not on the row.
        let escapeFrame = try #require(
            Self.firstAccessibleFrame(labeled: "Escape", in: controller.view))
        let dismissFrame = try #require(
            Self.firstAccessibleFrame(labeled: "Dismiss keyboard", in: controller.view))
        let enterFrame = try #require(
            Self.firstAccessibleFrame(labeled: "Enter", in: controller.view))
        let moreFrame = try #require(
            Self.firstAccessibleFrame(labeled: "More", in: controller.view))
        #expect(escapeFrame.maxY <= dismissFrame.minY + 1)
        #expect(moreFrame.minX >= enterFrame.maxX)
        #expect(Self.accessibleCount(labeled: "Dismiss keyboard", in: controller.view) == 1)
        #expect(
            Self.accessibleCount(
                labeled: AgentDirectInputPresentation.showComposerAccessibilityLabel,
                in: controller.view) == 1)

        try #require(await Self.eventually {
            let inputs = await transport.attachInputs
            return inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x09])))
                && inputs.contains(
                    TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x5A])))
                && inputs.contains(
                    TerminalAttachInput.keystrokes(Data([0x0A])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x0D])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x7F])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x41])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x42])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x44])))
                && inputs.contains(TerminalAttachInput.keystrokes(Data([0x1B, 0x5B, 0x43])))
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
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
        #expect(Self.accessibleCount(labeled: "Dismiss keyboard", in: controller.view) == 1)
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
        // Show Composer lives only on the switcher; the shortcut row remains
        // focused on terminal keys through every keyboard presentation.
        let showComposer = AgentDirectInputPresentation.showComposerAccessibilityLabel
        try #require(await Self.eventually {
            Self.accessibleCount(labeled: showComposer, in: controller.view) == 1
        })

        try #require(
            Self.activateAccessibility(labeled: "Show tools keyboard", in: controller.view))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Tools replaces the software keyboard without hiding the shortcut row.
        try #require(await Self.eventually {
            Self.accessibleCount(labeled: showComposer, in: controller.view) == 1
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

        // Pre-show `.system` hold: shortcut row stays visible above the
        // switcher even while measured height is still zero. Two-sided bound:
        // wiring the modifier to the raw zero height expands the terminal by
        // ~lastPresentedHeight and still satisfies a one-sided upper bound.
        #expect(Self.accessibleCount(labeled: showComposer, in: controller.view) == 1)
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
        #expect(Self.accessibleCount(labeled: showComposer, in: controller.view) == 1)
        let afterShow = try #require(Self.terminals(in: controller.view).first)
        #expect(afterShow.isFirstResponder)
        #expect(abs(afterShow.frame.height - heightWithSoftwareKeyboard) < 1)

        // Hardware keyboard hides the software keyboard while Ghostty remains
        // first responder. Released hold must not keep a stale inset; the row
        // remains because Direct Input still owns it.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let afterHardwareHide = try #require(Self.terminals(in: controller.view).first)
        #expect(afterHardwareHide.isFirstResponder)
        #expect(Self.accessibleCount(labeled: showComposer, in: controller.view) == 1)
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
        #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
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
        let firstFeed = owner.terminalFeed

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
        // Hosted SwiftUI may reuse the UIView address; prove the rendered
        // terminal is attached to the replacement feed, not the predecessor.
        #expect(owner.terminalFeed !== firstFeed)
        let replacement = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!firstFeed.isAttached(to: replacement))
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
        let firstFeed = owner.terminalFeed

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
        // Bind to the replacement feed before reading first-responder or
        // chrome — `.first` can still be a predecessor briefly.
        #expect(owner.terminalFeed !== firstFeed)
        let afterFirst = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!firstFeed.isAttached(to: afterFirst))
        try #require(await Self.eventually { afterFirst.isFirstResponder })

        // Production dismiss clears Direct Input raised intent via the
        // switcher-owned keyboard toggle. A leftover TerminalKeyboardHandoff
        // arm after the first replacement must not resurrect the keyboard on
        // the next pipeline rebuild. Wait on the observable chrome refresh
        // after reclaim, not a stale surface.
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return Self.firstAccessible(labeled: "Dismiss keyboard", in: controller.view) != nil
        })
        try #require(
            Self.activateAccessibility(labeled: "Dismiss keyboard", in: controller.view))
        try #require(await Self.eventually { !afterFirst.isFirstResponder })
        #expect(!handoff.consume(agent.id))

        let secondID = owner.terminalID
        let secondFeed = owner.terminalFeed
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

        #expect(owner.terminalFeed !== secondFeed)
        let afterSecond = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!secondFeed.isAttached(to: afterSecond))
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

    private static func firstView(
        in root: UIView, matching: (UIView) -> Bool
    ) -> UIView? {
        if matching(root) { return root }
        for subview in root.subviews {
            if let match = firstView(in: subview, matching: matching) {
                return match
            }
        }
        return nil
    }

    private struct KeyboardChromeSample {
        let insetHeight: CGFloat
        let switcherBottom: CGFloat?
    }

    @MainActor
    private final class KeyboardTransitionProbe: NSObject {
        // Hosted app tests cannot inspect the out-of-process keyboard surface:
        // its layout guide remains empty even while Simulator renders it. This
        // probe therefore samples the app-owned chrome on every display frame;
        // Simulator acceptance separately verifies the keyboard surface itself.
        private let notificationCenter: NotificationCenter
        private var token: NSObjectProtocol?
        private var showToken: NSObjectProtocol?
        private var changeFrameToken: NSObjectProtocol?
        private var displayLink: CADisplayLink?
        private var samplingStartedAt: CFTimeInterval?
        private let insetHeight: @MainActor () -> CGFloat
        private var chromeSample: (@MainActor () -> KeyboardChromeSample)?
        private(set) var willShowCount = 0
        private(set) var willHideCount = 0
        private(set) var willChangeFrameCount = 0
        private(set) var observedInsetHeights: [CGFloat] = []
        private(set) var chromeSamples: [KeyboardChromeSample] = []

        init(
            notificationCenter: NotificationCenter,
            insetHeight: @escaping @MainActor () -> CGFloat
        ) {
            self.notificationCenter = notificationCenter
            self.insetHeight = insetHeight
            super.init()
            showToken = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willShowCount += 1
                    self?.recordInsetHeight()
                }
            }
            token = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willHideCount += 1
                    self?.recordInsetHeight()
                }
            }
            changeFrameToken = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willChangeFrameCount += 1
                    self?.recordInsetHeight()
                }
            }
        }

        func reset() {
            stopSampling()
            willShowCount = 0
            willHideCount = 0
            willChangeFrameCount = 0
            observedInsetHeights = []
            chromeSamples = []
            captureChromeSample()
            let displayLink = CADisplayLink(target: self, selector: #selector(sampleDisplayFrame))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
            samplingStartedAt = CACurrentMediaTime()
        }

        func setChromeSample(_ sample: @escaping @MainActor () -> KeyboardChromeSample) {
            chromeSample = sample
        }

        func captureChromeSample() {
            if let chromeSample {
                chromeSamples.append(chromeSample())
            }
        }

        @objc private func sampleDisplayFrame() {
            captureChromeSample()
        }

        func hasStableTail(frameCount: Int = 4) -> Bool {
            guard chromeSamples.count >= frameCount,
                  let baseline = chromeSamples.last,
                  baseline.switcherBottom != nil
            else { return false }
            return chromeSamples.suffix(frameCount).allSatisfy { sample in
                abs(sample.insetHeight - baseline.insetHeight) <= 1
                    && Self.close(sample.switcherBottom, baseline.switcherBottom)
            }
        }

        func observedHandoffWindow(_ duration: TimeInterval = 0.65) -> Bool {
            guard let samplingStartedAt else { return false }
            return CACurrentMediaTime() - samplingStartedAt >= duration
        }

        private static func close(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return abs(lhs - rhs) <= 1
        }

        func stopSampling() {
            displayLink?.invalidate()
            displayLink = nil
            samplingStartedAt = nil
        }

        private func recordInsetHeight() {
            observedInsetHeights.append(insetHeight())
            captureChromeSample()
        }

        func stop() {
            stopSampling()
            if let showToken {
                notificationCenter.removeObserver(showToken)
            }
            if let token {
                notificationCenter.removeObserver(token)
            }
            if let changeFrameToken {
                notificationCenter.removeObserver(changeFrameToken)
            }
            showToken = nil
            self.token = nil
            changeFrameToken = nil
        }
    }

    @MainActor
    private static func keyboardChromeSample(
        in root: UIView,
        window: UIWindow,
        inset: TerminalKeyboardInset
    ) -> KeyboardChromeSample {
        let switcher = switchers(in: root)
            .filter { $0.window === window }
            .max { effectivePresentationOpacity(of: $0) < effectivePresentationOpacity(of: $1) }
        let bottom = switcher.flatMap { switcher -> CGFloat? in
            guard switcher.window === window, let superview = switcher.superview else { return nil }
            let frame = switcher.layer.presentation()?.frame ?? switcher.frame
            return superview.convert(frame, to: window).maxY
        }
        return KeyboardChromeSample(
            insetHeight: inset.height,
            switcherBottom: bottom)
    }

    private static func switchers(in root: UIView) -> [TerminalAgentSwitcherBar] {
        var result: [TerminalAgentSwitcherBar] = []
        if let switcher = root as? TerminalAgentSwitcherBar {
            result.append(switcher)
        }
        for subview in root.subviews {
            result.append(contentsOf: switchers(in: subview))
        }
        return result
    }

    private static func effectivePresentationOpacity(of view: UIView) -> Float {
        var opacity: Float = 1
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return 0 }
            opacity *= node.layer.presentation()?.opacity ?? node.layer.opacity
            current = node.superview
        }
        return opacity
    }

    private static func expectStableKeyboardChrome(
        _ samples: [KeyboardChromeSample],
        keyboardHeight: CGFloat,
        direction: String
    ) {
        #expect(!samples.isEmpty, "\(direction) produced no display-frame samples")
        #expect(
            samples.allSatisfy { abs($0.insetHeight - keyboardHeight) <= 1 },
            "\(direction) moved the keyboard inset during a UIKit transition")
        let bottoms = samples.compactMap(\.switcherBottom)
        #expect(
            bottoms.count == samples.count,
            "\(direction) removed the Agent switcher during a UIKit transition")
        guard let baseline = bottoms.first else { return }
        #expect(
            bottoms.allSatisfy { abs($0 - baseline) <= 1 },
            "\(direction) moved the Agent switcher during a UIKit transition: \(bottoms)")
    }

    /// Waits for the hosted terminal attached to the owner's current feed —
    /// the binding seam when UIView object identity may be reused and Ghostty
    /// viewport text is not a reliable harness signal.
    private static func eventuallyTerminal(
        boundTo feed: TerminalByteFeed,
        in root: UIView,
        timeout: Duration = .seconds(5)
    ) async throws -> HeelerTerminalView? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            if let terminal = terminals(in: root).first(where: { feed.isAttached(to: $0) }) {
                return terminal
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        root.setNeedsLayout()
        root.layoutIfNeeded()
        return terminals(in: root).first(where: { feed.isAttached(to: $0) })
    }

    private static func firstAccessible(labeled label: String, in root: UIView) -> NSObject? {
        firstAccessible(in: root) { $0.accessibilityLabel == label }
    }

    private static func firstAccessibleFrame(labeled label: String, in root: UIView) -> CGRect? {
        // Reuse visitAccessible so frame probes share the same container walk as
        // label lookups. Skip zero-size matches and keep searching — same rule
        // TerminalAttachTests uses for hosted SwiftUI chrome.
        var match: CGRect?
        visitAccessible(in: root) { node in
            guard match == nil, node.accessibilityLabel == label else { return }
            if let view = node as? UIView {
                guard view.bounds.width > 0, view.bounds.height > 0 else { return }
                match = view.convert(view.bounds, to: root)
            } else {
                let frame = node.accessibilityFrame
                guard frame.width > 0, frame.height > 0 else { return }
                match = root.convert(frame, from: nil)
            }
        }
        return match
    }

    private static func accessibleCount(labeled label: String, in root: UIView) -> Int {
        var count = 0
        visitAccessible(in: root) { node in
            if node.accessibilityLabel == label {
                count += 1
            }
        }
        return count
    }

    private static func firstAccessible(
        in root: UIView, matching: (NSObject) -> Bool
    ) -> NSObject? {
        var match: NSObject?
        visitAccessible(in: root) { node in
            guard match == nil, matching(node) else { return }
            match = node
        }
        return match
    }

    private static func visitAccessible(
        in root: UIView, body: (NSObject) -> Void
    ) {
        var visited = Set<ObjectIdentifier>()

        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            body(node)
            if let elements = node.accessibilityElements {
                for element in elements {
                    if let object = element as? NSObject {
                        visit(object)
                    }
                }
            }
            // SwiftUI containers can expose an empty or incomplete array while
            // their indexed accessibility API still owns the live controls.
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }
        visit(root)
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

private final class IndexedAccessibilityContainerView: UIView {
    private let indexedLabel: String
    private let arrayLabel: String?
    private lazy var indexedElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = indexedLabel
        return element
    }()
    private lazy var arrayElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = arrayLabel
        return element
    }()

    init(indexedLabel: String, arrayLabel: String? = nil) {
        self.indexedLabel = indexedLabel
        self.arrayLabel = arrayLabel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityElements: [Any]? {
        get { arrayLabel == nil ? [] : [arrayElement] }
        set { }
    }

    override func accessibilityElementCount() -> Int { 1 }

    override func accessibilityElement(at index: Int) -> Any? {
        index == 0 ? indexedElement : nil
    }
}
