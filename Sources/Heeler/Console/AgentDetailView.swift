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
    /// Whether the Files surface is up. One flag serves both size classes:
    /// regular width docks the column beside the terminal, compact width
    /// presents a sheet over it.
    @State private var isShowingFiles = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

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
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        _attach = State(
            initialValue: attachStore
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
            attachStore: attach,
            onBrowseFiles: projectRoot == nil ? nil : { isShowingFiles.toggle() })
        // An inset, not a conditional HStack: the terminal keeps its view
        // identity when the column appears, so Attach never tears down — the
        // grid resize rides the existing PTY-resize path, same as rotation.
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if isShowingFiles, horizontalSizeClass == .regular, let projectRoot {
                filesColumn(root: projectRoot)
                    .frame(width: 380)
                    .background(.background)
                    .overlay(alignment: .leading) { Divider().ignoresSafeArea() }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy, value: isShowingFiles)
        .sheet(
            isPresented: Binding(
                get: { isShowingFiles && horizontalSizeClass != .regular },
                set: { if !$0 { isShowingFiles = false } })
        ) {
            if let projectRoot {
                filesColumn(root: projectRoot)
            }
        }
    }

    /// The directory this Agent's project lives in: the worktree checkout
    /// when the workspace has one, else the launch cwd — the same root the
    /// Skills probe uses, deliberately not the live foreground cwd.
    private var projectRoot: String? {
        agent.skillsProjectRoot
    }

    private func filesColumn(root: String) -> some View {
        ProjectFilesColumn(
            root: root,
            hostName: agent.hostName,
            access: console.fileAccess(for: agent.hostID),
            fontFamily: terminal.fonts.familyName,
            palette: terminal.themes.selection(for: colorScheme)
                .palette(for: colorScheme))
    }
}
