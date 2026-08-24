import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream,
/// while the local Composer owns every user-authored message and delivers it
/// through one `agent.prompt` request, except when Agent Status is Blocked.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    @State private var composer: AgentComposerStore
    @State private var attach: AgentAttachStore
    @State private var openTerminal: AgentOpenTerminalStore

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil,
        openTerminalStore: AgentOpenTerminalStore? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        self.isOnStage = isOnStage
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        let attach = attachStore
            ?? AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: AgentTerminalView.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: isOnStage,
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID),
                stageFile: console.fileStager(for: agent.hostID),
                composer: composer
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            }
        _attach = State(initialValue: attach)
        _openTerminal = State(
            initialValue: openTerminalStore
                ?? AgentOpenTerminalStore(
                    agent: agent,
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isDetailOnStage: isOnStage,
                    createTerminal: { [console] request in
                        try await console.createShellTerminal(request, on: agent.hostID)
                    },
                    runTerminal: console.terminalRunner(for: agent.hostID),
                    leaveAgent: { attach.leaveForTerminalHandoff() },
                    rejoinAgent: { attach.rejoin() }))
    }

    var body: some View {
        Group {
            if let shell = openTerminal.shell {
                ShellTerminalView(
                    store: shell,
                    terminal: terminal,
                    activity: activity,
                    isReturning: openTerminal.isReturning
                ) {
                    await openTerminal.returnToAgent()
                }
                .id(openTerminal.destination)
            } else {
                AgentTerminalView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    hosts: hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    isOnStage: isOnStage,
                    onSwitch: onSwitch,
                    onClosed: onClosed,
                    canOpenTerminal: openTerminal.canOpen,
                    isOpeningTerminal: openTerminal.isOpening,
                    openTerminal: { openTerminal.open() },
                    composer: composer,
                    attachStore: attach)
                .id(openTerminal.destination)
            }
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            openTerminal.transportGenerationDidChange(generation)
        }
        .alert(
            "Couldn't Open Terminal",
            isPresented: Binding(
                get: { openTerminal.failure != nil },
                set: { if !$0 { openTerminal.dismissFailure() } })
        ) {
            Button("OK", role: .cancel) { openTerminal.dismissFailure() }
        } message: {
            Text(openTerminal.failure?.message ?? "")
        }
    }
}
