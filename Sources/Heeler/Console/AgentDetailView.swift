import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream,
/// while the local Composer owns every user-authored message and delivers it
/// through one `agent.prompt` request.
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
        attachStore: AgentAttachStore? = nil
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
        _composer = State(initialValue: composerStore ?? console.composerStore(for: agent))
        _attach = State(
            initialValue: attachStore
                ?? AgentAttachStore(
                    target: agent.agent.paneID,
                    paneTitle: AgentTerminalView.displayTitle(for: agent),
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isOnStage: isOnStage,
                    runTerminal: console.terminalRunner(for: agent.hostID),
                    stageImage: console.imageStager(for: agent.hostID)
                ) {
                    try await console.closePane(agent.agent.paneID, on: agent.hostID)
                })
    }

    var body: some View {
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
            composer: composer,
            attachStore: attach)
    }
}
