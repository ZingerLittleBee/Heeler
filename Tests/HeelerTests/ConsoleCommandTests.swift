import Foundation
import SwiftUI
import Testing

@testable import Heeler

@Suite("Console keyboard command policy")
struct ConsoleCommandTests {
    @Test func shortcutTableMapsEveryRequestedKeyToItsAction() {
        let expected: [Character: ConsoleCommandAction] = [
            "1": .selectAgent(1), "2": .selectAgent(2), "3": .selectAgent(3),
            "4": .selectAgent(4), "5": .selectAgent(5), "6": .selectAgent(6),
            "7": .selectAgent(7), "8": .selectAgent(8), "9": .selectAgent(9),
            "[": .previousAgent, "]": .nextAgent, "f": .focusSearch, "n": .newAgent,
            ",": .settings, "h": .hosts, "e": .toggleInputMode, "\r": .sendDraft,
            "w": .closeAgent,
        ]
        let shortcuts = ConsoleCommandShortcut.all
        #expect(shortcuts.count == expected.count)
        #expect(Set(shortcuts.map(\.id)).count == shortcuts.count)
        #expect(Set(shortcuts.map(\.key)).count == shortcuts.count)
        for shortcut in shortcuts {
            #expect(expected[shortcut.key] == shortcut.action)
            #expect(
                shortcut.modifiers == (shortcut.action == .hosts ? [.command, .shift] : [.command]))
            #expect(!shortcut.title.isEmpty)
        }
    }

    @Test func allShortcutsRequireCommandAndZoomIsAbsent() {
        for shortcut in ConsoleCommandShortcut.all {
            #expect(shortcut.modifiers.contains(.command))
            #expect(![Character("+"), "-", "=", "_"].contains(shortcut.key))
            #expect(!shortcut.modifiers.contains(.control))
            #expect(!shortcut.modifiers.contains(.option))
        }
    }

    @Test(arguments: ConsoleCommandFocus.allCases, [false, true])
    func availabilityCoversFocusAndSelection(focus: ConsoleCommandFocus, selected: Bool) {
        for mode in AgentInputMode.allCases {
            for hasDraft in [false, true] {
                let availability = ConsoleCommandAvailability(
                    focus: focus, hasSelection: selected, agentCount: 3,
                    inputMode: mode, hasDraft: hasDraft)
                for action: ConsoleCommandAction in [.focusSearch, .newAgent, .settings, .hosts] {
                    #expect(availability.allows(action))
                }
                #expect(availability.allows(.closeAgent) == selected)
                #expect(availability.allows(.toggleInputMode) == selected)
                #expect(
                    availability.allows(.sendDraft)
                        == (selected && focus == .composer && mode == .composer && hasDraft))
                #expect(availability.allows(.previousAgent))
                #expect(availability.allows(.nextAgent))
                #expect(availability.allows(.selectAgent(3)))
                #expect(!availability.allows(.selectAgent(4)))
            }
        }
    }

    @Test(arguments: [0, 1, 8, 9, 12])
    func numberedSelectionIsBoundedByBothInventoryAndNine(count: Int) {
        let availability = ConsoleCommandAvailability(
            focus: .none, hasSelection: false, agentCount: count,
            inputMode: .composer, hasDraft: false)
        #expect(availability.allows(.previousAgent) == (count > 0))
        #expect(availability.allows(.nextAgent) == (count > 0))
        for position in 0...10 {
            #expect(
                availability.allows(.selectAgent(position))
                    == ((1...9).contains(position) && position <= count))
        }
    }

    @Test func navigationUsesVisibleOrderAndWraps() {
        let rows = ["host-b:pinned", "host-b:working", "host-a:idle"]
        #expect(
            ConsoleCommandNavigation.destination(for: .selectAgent(2), in: rows, selection: nil)
                == rows[1])
        #expect(
            ConsoleCommandNavigation.destination(for: .nextAgent, in: rows, selection: rows[2])
                == rows[0])
        #expect(
            ConsoleCommandNavigation.destination(for: .previousAgent, in: rows, selection: rows[0])
                == rows[2])
        #expect(
            ConsoleCommandNavigation.destination(
                for: .nextAgent, in: rows, selection: "filtered-out") == rows[0])
        #expect(
            ConsoleCommandNavigation.destination(for: .previousAgent, in: rows, selection: nil)
                == rows[2])
        #expect(
            ConsoleCommandNavigation.destination(for: .selectAgent(4), in: rows, selection: nil)
                == nil)
        #expect(
            ConsoleCommandNavigation.destination(for: .nextAgent, in: [String](), selection: nil)
                == nil)
    }
}

@MainActor
@Suite("Console command scene registrations")
struct ConsoleCommandRegistryTests {
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "opaque:pA")

    private func target(
        registry: ConsoleCommandRegistry,
        context: @escaping @MainActor () -> ConsoleCommandTarget.Context,
        navigate: @escaping @MainActor (ConsoleAgent.ID) -> Void = { _ in },
        close: @escaping @MainActor () -> Void = {}
    ) -> ConsoleCommandTarget {
        ConsoleCommandTarget(
            registry: registry, context: context, navigate: navigate,
            focusSearch: {}, newAgent: {}, settings: {}, hosts: {}, closeAgent: close)
    }

    private func context(
        selection: ConsoleAgent.ID?, covered: Bool = false
    ) -> ConsoleCommandTarget.Context {
        .init(
            selection: selection, agents: [agent], isSearchFocused: false,
            isCovered: covered, inputMode: .composer)
    }

    private func registerTerminal(
        _ registry: ConsoleCommandRegistry, token: UUID = UUID(),
        focused: Bool = false, presenting: Bool = false,
        onStage: @escaping @MainActor () -> Bool = { true },
        toggle: @escaping @MainActor () -> Void = {}
    ) {
        registry.register(
            ConsoleCommandRegistry.Terminal(
                token: token, agentID: agent, isFocused: focused,
                isPresenting: presenting, isOnStage: onStage, toggleInputMode: toggle))
    }

    @Test func scenesDispatchOnlyTheirOwnActions() {
        let first = ConsoleCommandRegistry()
        let second = ConsoleCommandRegistry()
        var firstToggles = 0
        var secondToggles = 0
        registerTerminal(first, toggle: { firstToggles += 1 })
        registerTerminal(second, toggle: { secondToggles += 1 })
        let firstTarget = target(registry: first, context: { context(selection: agent) })
        let secondTarget = target(registry: second, context: { context(selection: agent) })
        firstTarget.perform(.toggleInputMode)
        #expect(firstToggles == 1)
        #expect(secondToggles == 0)
        secondTarget.perform(.toggleInputMode)
        #expect(firstToggles == 1)
        #expect(secondToggles == 1)
    }

    @Test func missingOrOffstageRegistrationDisablesDetailActions() {
        let registry = ConsoleCommandRegistry()
        let commands = target(registry: registry, context: { context(selection: agent) })
        #expect(!commands.allows(.toggleInputMode))
        #expect(!commands.allows(.sendDraft))
        #expect(commands.allows(.closeAgent))
        registerTerminal(registry, onStage: { false })
        #expect(!commands.allows(.toggleInputMode))
    }

    @Test func outgoingViewCannotUnregisterReplacement() {
        let registry = ConsoleCommandRegistry()
        let old = UUID()
        let replacement = UUID()
        registerTerminal(registry, token: old)
        registerTerminal(registry, token: replacement)
        registry.removeTerminal(old)
        #expect(registry.terminal?.token == replacement)
        for token in [old, replacement] {
            registry.register(
                ConsoleCommandRegistry.Composer(
                    token: token, terminalToken: replacement, agentID: agent,
                    isFocused: true, hasDraft: { true }, send: {}))
        }
        registry.removeComposer(old)
        #expect(registry.composer?.token == replacement)
        registry.removeTerminal(replacement)
        registry.removeComposer(replacement)
        #expect(registry.terminal == nil)
        #expect(registry.composer == nil)
    }

    @Test func selectionAndModalStateAreRecheckedAtDispatch() {
        let registry = ConsoleCommandRegistry()
        var selected: ConsoleAgent.ID? = agent
        var covered = false
        var toggles = 0
        var closes = 0
        registerTerminal(registry, toggle: { toggles += 1 })
        let commands = target(
            registry: registry, context: { context(selection: selected, covered: covered) },
            close: {
                closes += 1
                selected = nil
            })
        #expect(commands.allows(.toggleInputMode))
        covered = true
        for shortcut in ConsoleCommandShortcut.all {
            #expect(!commands.allows(shortcut.action))
        }
        commands.perform(.toggleInputMode)
        #expect(toggles == 0)
        covered = false
        commands.perform(.closeAgent)
        #expect(closes == 1)
        #expect(selected == nil)
        commands.perform(.toggleInputMode)
        #expect(toggles == 0)
    }

    @Test func sendUsesRegisteredActionAndRechecksDraftFocusAndOwner() async {
        let registry = ConsoleCommandRegistry()
        let token = UUID()
        let terminalToken = UUID()
        var draft = "a local draft"
        var sends = 0
        var selected: ConsoleAgent.ID? = agent
        registerTerminal(registry, token: terminalToken)
        func registerComposer(focused: Bool, token: UUID) {
            registry.register(
                ConsoleCommandRegistry.Composer(
                    token: token, terminalToken: terminalToken, agentID: agent, isFocused: focused,
                    hasDraft: { draft.contains { !$0.isWhitespace } },
                    send: {
                        sends += 1
                        draft = ""
                    }))
        }
        let commands = target(registry: registry, context: { context(selection: selected) })
        registerComposer(focused: true, token: token)
        #expect(commands.allows(.sendDraft))
        await commands.sendDraft(for: token)
        #expect(sends == 1)
        #expect(draft.isEmpty)
        #expect(!commands.allows(.sendDraft))
        draft = " \n "
        await commands.sendDraft(for: token)
        #expect(sends == 1)
        draft = "another draft"
        registerComposer(focused: false, token: token)
        await commands.sendDraft(for: token)
        #expect(sends == 1)
        registerComposer(focused: true, token: token)
        selected = ConsoleAgent.ID(hostID: UUID(), paneID: agent.paneID)
        await commands.sendDraft(for: token)
        #expect(sends == 1)
        selected = agent
        registerComposer(focused: true, token: UUID())
        await commands.sendDraft(for: token)
        #expect(sends == 1)
    }

    @Test func navigationDispatchUsesCurrentFilteredRows() {
        let registry = ConsoleCommandRegistry()
        let other = ConsoleAgent.ID(hostID: UUID(), paneID: "another")
        var rows = [agent, other]
        var selected: ConsoleAgent.ID?
        let commands = target(
            registry: registry,
            context: {
                .init(
                    selection: selected, agents: rows, isSearchFocused: true,
                    isCovered: false, inputMode: .composer)
            }, navigate: { selected = $0 })
        commands.perform(.selectAgent(2))
        #expect(selected == other)
        rows = [agent]
        commands.perform(.selectAgent(2))
        #expect(selected == other)
        commands.perform(.nextAgent)
        #expect(selected == agent)
    }

    @Test func searchAndTerminalFocusSuppressPendingComposerFocus() {
        let registry = ConsoleCommandRegistry()
        let terminalToken = UUID()
        var searchFocused = false
        registerTerminal(registry, token: terminalToken)
        registry.register(
            ConsoleCommandRegistry.Composer(
                token: UUID(), terminalToken: terminalToken, agentID: agent,
                isFocused: true, hasDraft: { true }, send: {}))
        let commands = target(
            registry: registry,
            context: {
                .init(
                    selection: agent, agents: [agent], isSearchFocused: searchFocused,
                    isCovered: false, inputMode: .composer)
            })
        #expect(commands.allows(.sendDraft))
        searchFocused = true
        #expect(!commands.allows(.sendDraft))
        searchFocused = false
        registerTerminal(registry, token: terminalToken, focused: true)
        #expect(!commands.allows(.sendDraft))
    }

    @Test func replacedTerminalCannotSendFromItsOutgoingComposer() {
        let registry = ConsoleCommandRegistry()
        let oldTerminal = UUID()
        registerTerminal(registry, token: oldTerminal)
        registry.register(
            ConsoleCommandRegistry.Composer(
                token: UUID(), terminalToken: oldTerminal, agentID: agent,
                isFocused: true, hasDraft: { true }, send: {}))
        let commands = target(registry: registry, context: { context(selection: agent) })
        #expect(commands.allows(.sendDraft))
        registerTerminal(registry)
        #expect(!commands.allows(.sendDraft))
    }

    @Test func detailPresentationBlocksEveryCommandAndRecovers() async {
        let registry = ConsoleCommandRegistry()
        let terminalToken = UUID()
        let composerToken = UUID()
        let rows =
            [agent]
            + (2...9).map {
                ConsoleAgent.ID(hostID: agent.hostID, paneID: "pane-\($0)")
            }
        var actionCount = 0
        let didFire: @MainActor () -> Void = { actionCount += 1 }
        registerTerminal(registry, token: terminalToken, toggle: didFire)
        registry.register(
            ConsoleCommandRegistry.Composer(
                token: composerToken, terminalToken: terminalToken, agentID: agent,
                isFocused: true, hasDraft: { true }, send: { didFire() }))
        let commands = ConsoleCommandTarget(
            registry: registry,
            context: {
                .init(
                    selection: agent, agents: rows, isSearchFocused: false,
                    isCovered: false, inputMode: .composer)
            },
            navigate: { _ in didFire() }, focusSearch: didFire, newAgent: didFire,
            settings: didFire, hosts: didFire, closeAgent: didFire)
        for shortcut in ConsoleCommandShortcut.all {
            #expect(commands.allows(shortcut.action))
        }

        registerTerminal(registry, token: terminalToken, presenting: true, toggle: didFire)
        for shortcut in ConsoleCommandShortcut.all {
            #expect(!commands.allows(shortcut.action))
            commands.perform(shortcut.action)
        }
        // A Send scheduled before the presentation also stops at the async boundary.
        await commands.sendDraft(for: composerToken)
        #expect(actionCount == 0)

        registerTerminal(registry, token: terminalToken, toggle: didFire)
        for shortcut in ConsoleCommandShortcut.all {
            #expect(commands.allows(shortcut.action))
        }
        commands.perform(.newAgent)
        #expect(actionCount == 1)
    }

    @Test func staleAttachPresentationDefersToCurrentDetailCoverage() {
        let registry = ConsoleCommandRegistry()
        var selected: ConsoleAgent.ID? = agent
        var onStage = true
        var rootCovered = false
        registerTerminal(registry, presenting: true, onStage: { onStage })
        let commands = target(
            registry: registry,
            context: { context(selection: selected, covered: rootCovered) })
        #expect(!commands.allows(.newAgent))

        // The same pane identifier on another Host is a different selection.
        selected = ConsoleAgent.ID(hostID: UUID(), paneID: agent.paneID)
        #expect(commands.allows(.newAgent))
        #expect(commands.allows(.nextAgent))
        #expect(commands.allows(.closeAgent))
        selected = nil
        #expect(commands.allows(.settings))

        // An unobstructed Shell Terminal ignores the off-stage Attach, while
        // its own presentation must independently cover the selected detail.
        selected = agent
        onStage = false
        #expect(commands.allows(.newAgent))
        #expect(commands.allows(.nextAgent))
        #expect(!commands.allows(.toggleInputMode))
        let shellToken = UUID()
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: shellToken, agentID: agent, isPresenting: true))
        #expect(!commands.allows(.newAgent))
        #expect(!commands.allows(.nextAgent))
        registry.removeDetailPresentation(shellToken)
        #expect(commands.allows(.newAgent))
        rootCovered = true
        #expect(!commands.allows(.newAgent))
    }

    @Test func sheetStillCoversCommandsAfterAnotherWindowTakesTheHost() {
        // Window A shows this Agent; window B, the key window, shows another
        // Agent on the same Host and so holds the channel.
        let windowA = UUID()
        let windowB = UUID()
        let claims = [
            HostTerminalClaim(sceneID: windowA, hostID: agent.hostID),
            HostTerminalClaim(sceneID: windowB, hostID: agent.hostID),
        ]
        var reconciled = HostTerminalOwnership()
        reconciled.reconcile(claims: claims, keySceneID: windowB)
        let ownership = reconciled
        let hostID = agent.hostID
        let stage = AgentDetailStage(
            isVisible: { true },
            terminalAccess: {
                ownership.access(sceneID: windowA, hostID: hostID, claims: claims)
            })
        #expect(stage.terminalAccess() == .liveInAnotherWindow)
        #expect(!stage.isOnStage())

        // A's Rename sheet is still presenting over its visible detail.
        let registry = ConsoleCommandRegistry()
        let terminalToken = UUID()
        var actionCount = 0
        let didFire: @MainActor () -> Void = { actionCount += 1 }
        let isVisible = stage.isVisible
        registerTerminal(registry, token: terminalToken, presenting: true, onStage: { isVisible() })
        let selection = agent
        let commands = ConsoleCommandTarget(
            registry: registry,
            context: {
                .init(
                    selection: selection, agents: [selection], isSearchFocused: false,
                    isCovered: false, inputMode: .composer)
            },
            navigate: { _ in didFire() }, focusSearch: didFire, newAgent: didFire,
            settings: didFire, hosts: didFire, closeAgent: didFire)
        for action: ConsoleCommandAction in [.closeAgent, .selectAgent(1), .newAgent] {
            #expect(!commands.allows(action))
            commands.perform(action)
        }
        #expect(actionCount == 0)

        registerTerminal(registry, token: terminalToken, onStage: { isVisible() })
        for action: ConsoleCommandAction in [.closeAgent, .selectAgent(1), .newAgent] {
            #expect(commands.allows(action))
        }
        commands.perform(.newAgent)
        #expect(actionCount == 1)
    }

    @Test func shellPresentationBlocksNavigationAndPresentationCommands() {
        let registry = ConsoleCommandRegistry()
        let shellToken = UUID()
        let rows =
            [agent]
            + (2...9).map {
                ConsoleAgent.ID(hostID: agent.hostID, paneID: "pane-\($0)")
            }
        var actionCount = 0
        let didFire: @MainActor () -> Void = { actionCount += 1 }
        // No Attach registration exists while the Shell Terminal is on screen.
        let commands = ConsoleCommandTarget(
            registry: registry,
            context: {
                .init(
                    selection: agent, agents: rows, isSearchFocused: false,
                    isCovered: false, inputMode: .direct)
            },
            navigate: { _ in didFire() }, focusSearch: didFire, newAgent: didFire,
            settings: didFire, hosts: didFire, closeAgent: didFire)
        let shellCommands = ConsoleCommandShortcut.all.filter {
            $0.action != .toggleInputMode && $0.action != .sendDraft
        }
        for shortcut in shellCommands {
            #expect(commands.allows(shortcut.action))
        }
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: shellToken, agentID: agent, isPresenting: true))
        for shortcut in ConsoleCommandShortcut.all {
            #expect(!commands.allows(shortcut.action))
            commands.perform(shortcut.action)
        }
        #expect(actionCount == 0)
        registry.removeDetailPresentation(shellToken)
        for shortcut in shellCommands {
            #expect(commands.allows(shortcut.action))
        }
        commands.perform(.newAgent)
        #expect(actionCount == 1)
    }

    @Test func wrapperAndShellPresentationTokensPreserveIndependentCoverage() {
        let registry = ConsoleCommandRegistry()
        let wrapperToken = UUID()
        let shellToken = UUID()
        let otherAgent = ConsoleAgent.ID(hostID: UUID(), paneID: agent.paneID)
        var selected: ConsoleAgent.ID? = agent
        let commands = target(registry: registry, context: { context(selection: selected) })
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: shellToken, agentID: agent, isPresenting: true))
        // The wrapper's initial non-presenting registration cannot mask its child.
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: wrapperToken, agentID: agent, isPresenting: false))
        #expect(!commands.allows(.nextAgent))
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: wrapperToken, agentID: agent, isPresenting: true))
        registry.removeDetailPresentation(shellToken)
        #expect(!commands.allows(.nextAgent))
        #expect(!commands.allows(.hosts))
        // The wrapper also gates an on-stage Attach after returning from Shell.
        registerTerminal(registry)
        #expect(!commands.allows(.toggleInputMode))
        registry.removeDetailPresentation(shellToken)
        #expect(registry.detailPresentations[wrapperToken] != nil)
        selected = otherAgent
        #expect(commands.allows(.hosts))
        selected = nil
        #expect(commands.allows(.settings))
        selected = agent
        registry.register(
            ConsoleCommandRegistry.DetailPresentation(
                token: wrapperToken, agentID: agent, isPresenting: false))
        #expect(commands.allows(.nextAgent))
        #expect(commands.allows(.toggleInputMode))
        registry.removeDetailPresentation(wrapperToken)
        #expect(registry.detailPresentations.isEmpty)
    }

    @Test func availabilityProjectsContextOnceWithActiveComposer() {
        let registry = ConsoleCommandRegistry()
        let terminalToken = UUID()
        var contextReads = 0
        registerTerminal(registry, token: terminalToken)
        registry.register(
            ConsoleCommandRegistry.Composer(
                token: UUID(), terminalToken: terminalToken, agentID: agent,
                isFocused: true, hasDraft: { true }, send: {}))
        let commands = target(
            registry: registry,
            context: {
                contextReads += 1
                return context(selection: agent)
            })
        for shortcut in ConsoleCommandShortcut.all {
            contextReads = 0
            _ = commands.allows(shortcut.action)
            #expect(contextReads == 1)
        }
    }
}
