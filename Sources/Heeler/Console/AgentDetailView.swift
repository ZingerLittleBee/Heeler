import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream.
/// Composer owns authored delivery by default; Direct Input (ADR 0016) is an
/// explicit opt-in that types the Attach PTY with the system keyboard. A plain
/// shell row is shown here too, exactly like an Agent: it attaches through
/// `terminal attach` and its Composer types through `pane.send_input`.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let inputMode: AgentInputModeSettings
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let isVisible: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    @State private var focus = AgentFocusCoordinator()
    @State private var hasAppeared = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer: AgentComposerStore
    @State private var attach: AgentAttachStore
    @State private var retainedAgent: AgentTerminalCache.Entry?
    @State private var retentionOwnerID: UUID
    private let permitsRetention: Bool
    @State private var isResolvingTerminal = false
    @State private var isChoosingTerminal = false
    @State private var terminalOpenFailure: String?
    @State private var createdTerminal: ShellTerminalIdentity?
    /// Which window holds this Host's terminal channel; nil outside a scene
    /// root, where this detail always holds it.
    @Environment(\.agentSceneRouting) private var sceneRouting

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        inputMode: AgentInputModeSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        stage: AgentDetailStage,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.inputMode = inputMode
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        let isOnStage = stage.isOnStage
        self.isOnStage = isOnStage
        self.isVisible = stage.isVisible
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        let ownerID = UUID()
        _retentionOwnerID = State(initialValue: ownerID)
        permitsRetention = attachStore == nil
        _retainedAgent = State(initialValue: nil)
        let retainsSessions = permitsRetention
        let attach = attachStore
            ?? AgentAttachStore(
                target: agent.attachTarget,
                paneTitle: AgentTerminalView.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: { !retainsSessions && isOnStage() },
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID),
                stageFile: console.fileStager(for: agent.hostID),
                composer: composer
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            } invalidateMosh: {
                await console.invalidateMosh(for: agent.hostID)
            }
        _attach = State(initialValue: attach)
    }

    private var terminalAccess: HostTerminalAccess {
        sceneRouting?.terminalAccess(for: agent.hostID) ?? .holds
    }

    private func applyTerminalAccess() {
        switch terminalAccess {
        case .holds:
            prepareRetainedAgent()
            attach.rejoin()
        case .liveInAnotherWindow:
            if let retainedAgent {
                console.agentTerminals.release(retainedAgent, ownerID: retentionOwnerID)
                self.retainedAgent = nil
                attach = makePrivateAttach()
            } else {
                attach.leaveForTerminalHandoff()
            }
        }
    }

    private func prepareRetainedAgent() {
        guard permitsRetention, isOnStage() else { return }
        if let retainedAgent, retainedAgent.isRetained {
            console.agentTerminals.activate(retainedAgent, ownerID: retentionOwnerID, isPresented: { isOnStage() })
            return
        }
        if retainedAgent == nil { attach.leaveForTerminalHandoff() }
        let entry = console.agentTerminals.acquire(
            agent: agent, console: console, composer: composer, ownerID: retentionOwnerID,
            isPresented: { isOnStage() })
        retainedAgent = entry
        attach = entry.attach
    }

    private func makePrivateAttach() -> AgentAttachStore {
        let console = console
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        return AgentAttachStore(
            target: agent.attachTarget,
            paneTitle: AgentTerminalView.displayTitle(for: agent),
            transportGeneration: console.hostConnectionGenerations[agent.hostID],
            isOnStage: isOnStage,
            runTerminal: console.terminalRunner(for: agent.hostID),
            stageImage: console.imageStager(for: agent.hostID),
            stageFile: console.fileStager(for: agent.hostID),
            composer: composer,
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(paneID, on: hostID)
            },
            invalidateMosh: { [weak console] in
                guard let console else { return }
                await console.invalidateMosh(for: hostID)
            })
    }

    private var focusViewingState: AgentFocusCoordinator.ViewingState {
        let current = console.agents.first { $0.id == agent.id }
        return .init(
            agentID: agent.id,
            terminalID: current?.agent.terminalID ?? agent.agent.terminalID,
            transportGeneration: console.hostConnectionGenerations[agent.hostID],
            status: current?.agent.status,
            isHostReady: console.hostStatuses[agent.hostID] == .connected
                && !console.hostsAwaitingSnapshot.contains(agent.hostID),
            isSceneActive: scenePhase == .active,
            isOnStage: hasAppeared && isOnStage())
    }

    private func updateFocus() {
        let state = focusViewingState
        focus.update(state) { id in
            // A queued task can begin after selection moved, before SwiftUI
            // has delivered the next onChange callback.
            guard focusViewingState == state else { throw CancellationError() }
            try await console.focusAgent(id.paneID, on: id.hostID)
        }
    }

    var body: some View {
        AgentTerminalView(
            agent: agent,
            console: console,
            terminal: terminal,
            inputMode: inputMode,
            hosts: hosts,
            activity: activity,
            keyboardHandoff: keyboardHandoff,
            keyboardInset: keyboardInset,
            isOnStage: isOnStage,
            // A detail that lost its Host channel to another window is still
            // on screen, and its sheets still cover commands.
            isCommandOnStage: isVisible,
            onSwitch: onSwitch,
            onClosed: onClosed,
            canOpenTerminal: (!workspaceShells.isEmpty || agent.shellTerminalCreationRequest != nil)
                && terminalAccess == .holds,
            isOpeningTerminal: isResolvingTerminal,
            openTerminal: { openWorkspaceTerminal() },
            composer: composer,
            attachStore: attach,
            retainedSurface: retainedAgent?.surfaceRetention,
            onRetainDeparture: retainedAgent.map { entry in
                { keepingKeyboard in
                    console.agentTerminals.release(
                        entry, ownerID: retentionOwnerID, keepingKeyboard: keepingKeyboard)
                }
            },
            workspaceDrawer: workspaceDrawer,
            // Retention swaps `attach` on appear and rebuilds this view; the
            // build before that swap is a placeholder and must not spend the
            // keyboard handoff meant for the real one.
            inheritsKeyboardHandoff: !permitsRetention || retainedAgent != nil)
        .id(ObjectIdentifier(attach))
        .onAppear {
            hasAppeared = true
            prepareRetainedAgent()
            updateFocus()
        }
        .onChange(of: focusViewingState) {
            updateFocus()
        }
        .onDisappear {
            hasAppeared = false
            focus.leave()
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) {
            prepareRetainedAgent()
        }
        .onChange(of: activity.activationCount) { prepareRetainedAgent() }
        .confirmationDialog("Open Terminal", isPresented: $isChoosingTerminal, titleVisibility: .visible) {
            ForEach(workspaceShells) { shell in
                Button(shellChoiceTitle(shell)) { openShell(shell.id) }
            }
            if agent.shellTerminalCreationRequest != nil {
                Button("New Terminal") { createWorkspaceTerminal() }
            }
            Button("Cancel", role: .cancel) { keyboardHandoff.cancelShellTerminal() }
        }
        .alert("Couldn't Open Terminal", isPresented: Binding(
            get: { terminalOpenFailure != nil }, set: { if !$0 { terminalOpenFailure = nil } })
        ) {
            Button("OK", role: .cancel) { terminalOpenFailure = nil }
        } message: {
            Text(terminalOpenFailure ?? "")
        }
        // The same-Host handoff between windows rides the Attach store's own
        // leave and rejoin: the window that loses the channel releases its
        // Attach, and the one that gains it rejoins behind that release
        // through the Host's terminal serialization.
        .onChange(of: terminalAccess, initial: true) {
            applyTerminalAccess()
        }
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: agent.id,
            isPresenting: terminalOpenFailure != nil || isChoosingTerminal))
    }

    /// Every terminal in this Workspace, an Agent's and a shell's alike: each
    /// is a Console row, so every route opens its detail by row identity.
    private var workspaceDrawer: WorkspaceTerminalDrawer? {
        let terminals = console.terminals(on: agent.hostID, workspaceID: agent.agent.workspaceID)
        guard !terminals.isEmpty else { return nil }
        return WorkspaceTerminalDrawer(
            terminals: terminals,
            selectedPaneID: agent.agent.paneID,
            edgeDock: terminal.edgeDock,
            onSelect: { target in
                if target.rowID != agent.id { onSwitch(target.rowID) }
            },
            onNewTerminal: agent.shellTerminalCreationRequest == nil
                ? nil : { createWorkspaceTerminal(fresh: true) },
            isCreatingTerminal: isResolvingTerminal)
    }

    /// The Workspace's other shell rows: what Open Terminal offers.
    private var workspaceShells: [ConsoleAgent] {
        console.agents.filter {
            $0.isShell && $0.id != agent.id && $0.hostID == agent.hostID
                && $0.agent.workspaceID == agent.agent.workspaceID
        }
    }

    private func shellChoiceTitle(_ shell: ConsoleAgent) -> String {
        let title = shell.agent.title.isEmpty ? shell.agent.displayName : shell.agent.title
        guard let tab = shell.tabLabel, !tab.isEmpty, tab != title else { return title }
        return "\(title) · \(tab)"
    }

    /// Opens a shell row's own detail. A keyboard raised when Open Terminal
    /// or New Terminal was tapped — armed before the destination was known —
    /// carries over to it like any Agent switch, in the mode it was armed in.
    private func openShell(_ id: ConsoleAgent.ID) {
        if let mode = keyboardHandoff.consumeShellTerminal() {
            keyboardHandoff.arm(for: id, mode: mode)
        }
        onSwitch(id)
    }

    private func openWorkspaceTerminal() {
        if createdTerminal != nil { createWorkspaceTerminal(); return }
        switch workspaceShells.count {
        case 0: createWorkspaceTerminal()
        case 1: openShell(workspaceShells[0].id)
        default: isChoosingTerminal = true
        }
    }

    /// Open Terminal routes back to the tab this detail already created;
    /// `fresh` (the drawer's New Terminal) asks for another one, unless the
    /// last creation has not reached the Console yet, in which case it is
    /// still the retry path and must not create a duplicate.
    private func createWorkspaceTerminal(fresh: Bool = false) {
        guard !isResolvingTerminal, let request = agent.shellTerminalCreationRequest else {
            keyboardHandoff.cancelShellTerminal()
            return
        }
        if fresh, let created = createdTerminal, console.agents.contains(where: {
            $0.id == ConsoleAgent.ID(hostID: agent.hostID, paneID: created.paneID)
        }) {
            createdTerminal = nil
        }
        isResolvingTerminal = true
        Task { @MainActor in
            defer { isResolvingTerminal = false }
            do {
                let created: ShellTerminalIdentity
                if let createdTerminal {
                    created = createdTerminal
                    await console.refreshTerminalInventory(on: agent.hostID)
                } else {
                    created = try await console.createShellTerminal(request, on: agent.hostID)
                    createdTerminal = created
                }
                let id = ConsoleAgent.ID(hostID: agent.hostID, paneID: created.paneID)
                await console.waitForAgent(id)
                guard console.agents.contains(where: { $0.id == id }) else {
                    keyboardHandoff.cancelShellTerminal()
                    terminalOpenFailure = "The terminal was created, but its Workspace hasn't refreshed yet. Try Open Terminal again to refresh it."
                    return
                }
                if isVisible() {
                    openShell(id)
                } else {
                    keyboardHandoff.cancelShellTerminal()
                }
            } catch {
                keyboardHandoff.cancelShellTerminal()
                terminalOpenFailure = Self.terminalCreationFailureMessage(for: error)
            }
        }
    }

    /// A definitive herdr rejection created nothing; anything else may have
    /// created a tab the reply never confirmed, so the user checks the Host
    /// instead of blindly retrying into a duplicate.
    static func terminalCreationFailureMessage(for error: any Error) -> String {
        switch error {
        case let api as HerdrAPIError:
            "herdr couldn't create the terminal: \(api.message)"
        case TransportError.apiRejected(_, let message):
            "herdr couldn't create the terminal: \(message)"
        default:
            "The request did not finish clearly. A new tab may already exist on the Host. Check the Host before trying again."
        }
    }
}
