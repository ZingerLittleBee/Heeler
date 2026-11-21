import Foundation
import SwiftUI
import Synchronization
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

    @Test func sharedActionMenuContractIsExhaustive() {
        #expect(
            AgentActionMenuPolicy.composerAddSections == [.addAttachments])
        #expect(
            AgentActionMenuPolicy.composerMoreSections
                == [.navigation, .sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuPolicy.directInputMoreSections
                == [.navigation, .addAttachments, .sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuSection.navigation.items == [.backToConsole])
        #expect(
            AgentActionMenuSection.addAttachments.items
                == [.addImage, .pasteImage, .addFile])
        #expect(
            AgentActionMenuSection.sessionTools.items
                == [
                    .showChat, .showAgentTerminal, .openTerminal, .changes, .newAgent, .skills,
                    .snippets,
                ])
        #expect(
            AgentActionMenuSection.agentLifecycle.items
                == [.worktreeDetails, .renameAgent, .renameWorkspace, .closeAgent])
        #expect(
            AgentActionMenuItem.allCases
                == AgentActionMenuSection.allCases.flatMap(\.items))

        let metadata: [(AgentActionMenuItem, String, AgentGlyph, Bool, Bool)] = [
            (.backToConsole, "Back to Console", .symbol("chevron.left"), false, false),
            (.addImage, "Add Image", .symbol("photo"), false, true),
            (.pasteImage, "Paste Image", .symbol("doc.on.clipboard"), false, true),
            (.addFile, "Add File", .symbol("doc"), false, true),
            (.showChat, "Show Chat", .symbol("text.bubble"), false, false),
            (.showAgentTerminal, "Show Agent Terminal", .codeBubble, false, false),
            (.openTerminal, "Open Terminal", .symbol("macwindow.badge.plus"), false, false),
            (.changes, "Changes", .symbol("plus.forwardslash.minus"), false, false),
            (.newAgent, "New Agent", .symbol("plus"), false, false),
            (.skills, "Skills", .symbol("sparkles"), false, true),
            (.snippets, "Snippets", .symbol("quote.bubble"), false, true),
            (.worktreeDetails, "Worktree Details", .symbol("arrow.triangle.branch"), false, false),
            (.renameAgent, "Rename Agent", .symbol("pencil"), false, false),
            (.renameWorkspace, "Rename Workspace", .symbol("pencil.line"), false, false),
            (.closeAgent, "Close Agent", .symbol("trash"), true, false),
        ]
        for (item, title, glyph, isDestructive, isDraftOwned) in metadata {
            #expect(item.title == title)
            #expect(item.glyph == glyph)
            #expect((item.role == .destructive) == isDestructive)
            #expect(item.isDraftOwned == isDraftOwned)
        }
    }

    @MainActor
    @Test func codeBubbleGlyphSharesTextBubbleCanvas() throws {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .medium)
        let textBubble = try #require(UIImage(systemName: "text.bubble", withConfiguration: configuration))
        let glyph = CodeBubbleGlyph.image(pointSize: 17)

        // iOS 27 symbol metrics can differ between `bubble` and
        // `text.bubble` by floating-point noise (20.0 vs 19.999999999999996).
        #expect(abs(glyph.size.width - textBubble.size.width) < 0.01)
        #expect(abs(glyph.size.height - textBubble.size.height) < 0.01)
        #expect(glyph.renderingMode == .alwaysTemplate)
    }

    @Test func sharedActionMenuAvailabilityAndDispatchCoverAllGates() {
        enum Event: Equatable {
            case back, addImage, addFile, showChat, showAgentTerminal, openTerminal, changes
            case startAgent, skills, snippets, worktree, renameAgent, renameWorkspace, closeAgent
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
            showChanges: nil,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: nil,
            showWorktreeDetails: nil,
            renameAgent: nil,
            renameWorkspace: nil,
            closeAgent: { events.append(.closeAgent) },
            backToConsole: { events.append(.back) })
        let busy = AgentComposerActions(
            canBegin: true,
            attachLinkCount: 0,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            showAttachLinks: {},
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: true,
            showChanges: { events.append(.changes) },
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            closeAgent: { events.append(.closeAgent) },
            backToConsole: { events.append(.back) })
        let ready = AgentComposerActions(
            canBegin: true,
            attachLinkCount: 0,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            showAttachLinks: {},
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: false,
            showChanges: { events.append(.changes) },
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            closeAgent: { events.append(.closeAgent) },
            backToConsole: { events.append(.back) },
            showChat: { events.append(.showChat) },
            showAgentTerminal: { events.append(.showAgentTerminal) })

        let availability: [(AgentActionMenuItem, AgentComposerActions, Bool, Bool)] = [
            (.addImage, gated, true, false),
            (.addFile, gated, true, false),
            // Each switch shows only where the other surface is on screen,
            // and only for an Agent that has Chat.
            (.showChat, gated, false, true),
            (.showChat, ready, true, true),
            (.showAgentTerminal, gated, false, true),
            (.showAgentTerminal, ready, true, true),
            (.openTerminal, gated, true, false),
            (.openTerminal, busy, true, false),
            (.openTerminal, ready, true, true),
            // Visible whenever the Agent has a directory, whatever its
            // worktree metadata says.
            (.changes, gated, false, true),
            (.changes, busy, true, true),
            (.changes, ready, true, true),
            (.newAgent, ready, true, true),
            (.skills, gated, false, true),
            (.skills, ready, true, true),
            (.snippets, ready, true, true),
            (.worktreeDetails, gated, false, true),
            (.worktreeDetails, ready, true, true),
            (.renameAgent, gated, false, true),
            (.renameWorkspace, gated, false, true),
            (.renameAgent, ready, true, true),
            (.renameWorkspace, ready, true, true),
            (.closeAgent, ready, true, true),
            (.backToConsole, gated, true, true),
        ]
        for (item, actions, visible, enabled) in availability {
            #expect(AgentActionMenuPolicy.isVisible(item, actions: actions) == visible)
            #expect(AgentActionMenuPolicy.isEnabled(item, actions: actions) == enabled)
        }

        #expect(AgentActionMenuPolicy.title(of: .closeAgent, actions: ready) == "Close Agent")
        var saved = ready
        saved.removesSavedChat = true
        #expect(AgentActionMenuPolicy.title(of: .closeAgent, actions: saved) == "Remove Saved Chat")
        #expect(AgentActionMenuPolicy.title(of: .renameAgent, actions: saved) == "Rename Agent")

        for item in AgentActionMenuItem.allCases {
            AgentActionMenuPolicy.perform(item, actions: ready)
        }
        #expect(
            events == [
                .back, .addImage, .addFile, .showChat, .showAgentTerminal, .openTerminal,
                .changes, .startAgent, .skills, .snippets, .worktree, .renameAgent,
                .renameWorkspace, .closeAgent,
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
            pasteImage: { steps.append(.action(.pasteImage)) },
            addFile: { steps.append(.action(.addFile)) },
            showAttachLinks: {},
            openTerminal: { steps.append(.action(.openTerminal)) },
            isOpeningTerminal: false,
            showChanges: { steps.append(.action(.changes)) },
            startAgent: { steps.append(.action(.newAgent)) },
            manageSnippets: { steps.append(.action(.snippets)) },
            showSkills: { steps.append(.action(.skills)) },
            showWorktreeDetails: { steps.append(.action(.worktreeDetails)) },
            renameAgent: { steps.append(.action(.renameAgent)) },
            renameWorkspace: { steps.append(.action(.renameWorkspace)) },
            closeAgent: { steps.append(.action(.closeAgent)) },
            backToConsole: { steps.append(.action(.backToConsole)) },
            showChat: { steps.append(.action(.showChat)) },
            showAgentTerminal: { steps.append(.action(.showAgentTerminal)) })
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
                .action(.backToConsole),
                .restore, .action(.addImage),
                .restore, .action(.pasteImage),
                .restore, .action(.addFile),
                .action(.showChat),
                .action(.showAgentTerminal),
                .action(.openTerminal),
                .action(.changes),
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
                .action(.addImage), .action(.pasteImage), .action(.addFile),
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

    @Test func toolsContextExposesInsertTabsWhenSkillsAreSupported() throws {
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
        let context = TerminalKeysContext(
            settings: settings, skills: skills, manageSnippets: {})
        #expect(context.tabs == [.controls, .skills, .snippets, .appearance])
        let withoutSkills = TerminalKeysContext(settings: settings, manageSnippets: {})
        #expect(withoutSkills.tabs == [.controls, .snippets, .appearance])
    }
}
