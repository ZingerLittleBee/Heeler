import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream.
/// Composer owns authored delivery by default; Direct Input (ADR 0016) is an
/// explicit opt-in that types the Attach PTY with the system keyboard.
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
    private let onSelectTerminal: ((ConsoleTerminal) -> Void)?
    @State private var focus = AgentFocusCoordinator()
    @State private var hasAppeared = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer: AgentComposerStore
    @State private var attach: AgentAttachStore
    @State private var openTerminal: AgentOpenTerminalStore
    @State private var retainedAgent: AgentTerminalCache.Entry?
    @State private var retentionOwnerID: UUID
    @State private var attachReference: AgentDetailAttachReference
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
        onSelectTerminal: ((ConsoleTerminal) -> Void)? = nil,
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil,
        openTerminalStore: AgentOpenTerminalStore? = nil
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
        self.onSelectTerminal = onSelectTerminal
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        let ownerID = UUID()
        _retentionOwnerID = State(initialValue: ownerID)
        permitsRetention = attachStore == nil && openTerminalStore == nil
        _retainedAgent = State(initialValue: nil)
        let retainsSessions = permitsRetention
        let attach = attachStore
            ?? AgentAttachStore(
                target: agent.agent.paneID,
                paneTitle: AgentTerminalView.displayTitle(for: agent),
                transportGeneration: console.hostConnectionGenerations[agent.hostID],
                isOnStage: { !retainsSessions && isOnStage() },
                runTerminal: console.terminalRunner(for: agent.hostID),
                stageImage: console.imageStager(for: agent.hostID),
                stageFile: console.fileStager(for: agent.hostID),
                composer: composer
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            }
        _attach = State(initialValue: attach)
        let reference = AgentDetailAttachReference(attach)
        _attachReference = State(initialValue: reference)
        let hostID = agent.hostID
        let workspaceID = agent.agent.workspaceID
        _openTerminal = State(
            initialValue: openTerminalStore
                ?? AgentOpenTerminalStore(
                    agent: agent,
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isDetailOnStage: isOnStage,
                    createTerminal: { [console] request in
                        try await console.createShellTerminal(request, on: hostID)
                    },
                    runTerminal: console.terminalRunner(for: agent.hostID),
                    leaveAgent: { reference.store.leaveForTerminalHandoff() },
                    rejoinAgent: { reference.store.rejoin() },
                    recallTerminal: { [console] in
                        console.recallShellTerminal(
                            forWorkspaceID: workspaceID, on: hostID)
                    },
                    rememberTerminal: { [console] identity in
                        console.rememberShellTerminal(
                            identity, forWorkspaceID: workspaceID, on: hostID)
                    },
                    forgetTerminal: { [console] in
                        console.forgetShellTerminal(
                            forWorkspaceID: workspaceID, on: hostID)
                    },
                    verifyTerminal: { [console] identity in
                        try await console.shellTerminalStillExists(identity, on: hostID)
                    },
                    closeRemoteTerminal: { [console] identity in
                        try await console.closePane(identity.paneID, on: hostID)
                    }))
    }

    private var terminalAccess: HostTerminalAccess {
        sceneRouting?.terminalAccess(for: agent.hostID) ?? .holds
    }

    private func applyTerminalAccess() {
        guard openTerminal.shell == nil, !openTerminal.isOpening else { return }
        switch terminalAccess {
        case .holds:
            prepareRetainedAgent()
            attach.rejoin()
        case .liveInAnotherWindow:
            if let retainedAgent {
                console.agentTerminals.release(retainedAgent, ownerID: retentionOwnerID)
                self.retainedAgent = nil
                attach = makePrivateAttach()
                attachReference.store = attach
            } else {
                attach.leaveForTerminalHandoff()
            }
        }
    }

    private func prepareRetainedAgent() {
        guard permitsRetention, isOnStage(), openTerminal.shell == nil else { return }
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
        attachReference.store = attach
    }

    private func makePrivateAttach() -> AgentAttachStore {
        let console = console
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        return AgentAttachStore(
            target: agent.agent.paneID,
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
            isOnStage: hasAppeared && isOnStage(),
            showsShellTerminal: openTerminal.shell != nil || openTerminal.isOpening)
    }

    private func updateFocus() {
        let state = focusViewingState
        focus.update(state) { id in
            // A queued task can begin after selection or Shell ownership moved,
            // before SwiftUI has delivered the next onChange callback.
            guard focusViewingState == state else { throw CancellationError() }
            try await console.focusAgent(id.paneID, on: id.hostID)
        }
    }

    var body: some View {
        Group {
            if let shell = openTerminal.shell {
                ShellTerminalView(
                    store: shell,
                    agentID: agent.id,
                    terminal: terminal,
                    activity: activity,
                    isReturning: openTerminal.isReturning,
                    isClosingTerminal: openTerminal.isClosingTerminal,
                    onCloseTerminal: { openTerminal.closeTerminal() },
                    workspaceDrawer: workspaceDrawer
                ) {
                    await openTerminal.returnToAgent()
                }
                .id(openTerminal.destination)
            } else {
                AgentTerminalView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    inputMode: inputMode,
                    hosts: hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    isOnStage: {
                        isOnStage() && openTerminal.shell == nil
                    },
                    // A detail that lost its Host channel to another window
                    // is still on screen, and its sheets still cover commands.
                    isCommandOnStage: {
                        isVisible() && openTerminal.shell == nil
                    },
                    onSwitch: onSwitch,
                    onClosed: onClosed,
                    canOpenTerminal: (!workspaceShells.isEmpty || openTerminal.canOpen) && terminalAccess == .holds,
                    isOpeningTerminal: openTerminal.isOpening || isResolvingTerminal,
                    openTerminal: { openWorkspaceTerminal() },
                    composer: composer,
                    attachStore: attach,
                    retainedSurface: retainedAgent?.surfaceRetention,
                    onRetainDeparture: retainedAgent.map { entry in
                        { console.agentTerminals.release(entry, ownerID: retentionOwnerID) }
                    },
                    workspaceDrawer: workspaceDrawer)
                .id(ObjectIdentifier(attach))
            }
        }
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
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            prepareRetainedAgent()
            openTerminal.transportGenerationDidChange(generation)
        }
        .onChange(of: activity.activationCount) { prepareRetainedAgent() }
        .confirmationDialog("Open Terminal", isPresented: $isChoosingTerminal, titleVisibility: .visible) {
            ForEach(workspaceShells) { target in
                Button("\(target.displayTitle) · \(target.tabLabel ?? "Terminal")") {
                    onSelectTerminal?(target)
                }
            }
            if agent.shellTerminalCreationRequest != nil {
                Button("New Terminal") { createWorkspaceTerminal() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't Open Terminal", isPresented: Binding(
            get: { terminalOpenFailure != nil }, set: { if !$0 { terminalOpenFailure = nil } })
        ) {
            Button("OK", role: .cancel) { terminalOpenFailure = nil }
        } message: {
            Text(terminalOpenFailure ?? "")
        }
        // The same-Host handoff between windows rides the Attach store's own
        // leave and rejoin, the path the Shell Terminal handoff already
        // uses: the window that loses the channel releases its Attach, and
        // the one that gains it rejoins behind that release through the
        // Host's terminal serialization. A Shell Terminal in this window
        // keeps the channel, so neither applies while one is open.
        .onChange(of: terminalAccess, initial: true) {
            applyTerminalAccess()
        }
        .onChange(of: openTerminal.shell != nil || openTerminal.isOpening, initial: true) {
            _, showsShellTerminal in
            sceneRouting?.shellTerminalDidChange(agent: showsShellTerminal ? agent.id : nil)
            // Access that changed while a Shell Terminal was opening applies
            // once the detail is back on the Agent.
            applyTerminalAccess()
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
        .alert(
            "Couldn't Close Terminal",
            isPresented: Binding(
                get: { openTerminal.closeFailureMessage != nil },
                set: { if !$0 { openTerminal.dismissCloseFailure() } })
        ) {
            Button("OK", role: .cancel) { openTerminal.dismissCloseFailure() }
        } message: {
            Text(openTerminal.closeFailureMessage ?? "")
        }
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: agent.id,
            isPresenting: openTerminal.failure != nil || openTerminal.closeFailureMessage != nil
                || terminalOpenFailure != nil || isChoosingTerminal))
    }

    /// Nil outside a Console that can select terminals (a scene root), and
    /// while the Workspace has nothing to switch to.
    private var workspaceDrawer: WorkspaceTerminalDrawer? {
        guard let onSelectTerminal else { return nil }
        let terminals = console.terminals(on: agent.hostID, workspaceID: agent.agent.workspaceID)
        guard !terminals.isEmpty else { return nil }
        return WorkspaceTerminalDrawer(
            terminals: terminals,
            selectedPaneID: openTerminal.shell?.identity.paneID ?? agent.agent.paneID,
            onSelect: { target in
                if let agentID = target.agentID {
                    if agentID != agent.id { onSwitch(agentID) }
                    else if openTerminal.shell != nil {
                        Task { await openTerminal.returnToAgent() }
                    }
                } else {
                    onSelectTerminal(target)
                }
            })
    }

    private var workspaceShells: [ConsoleTerminal] {
        console.terminals(on: agent.hostID, workspaceID: agent.agent.workspaceID)
            .filter { !$0.isAgent }
    }

    private func openWorkspaceTerminal() {
        guard onSelectTerminal != nil else { openTerminal.open(); return }
        if createdTerminal != nil { createWorkspaceTerminal(); return }
        switch workspaceShells.count {
        case 0: createWorkspaceTerminal()
        case 1: onSelectTerminal?(workspaceShells[0])
        default: isChoosingTerminal = true
        }
    }

    private func createWorkspaceTerminal() {
        guard !isResolvingTerminal, let request = agent.shellTerminalCreationRequest else { return }
        isResolvingTerminal = true
        Task { @MainActor in
            defer { isResolvingTerminal = false }
            do {
                if createdTerminal == nil {
                    createdTerminal = try await console.createShellTerminal(request, on: agent.hostID)
                } else {
                    await console.refreshTerminalInventory(on: agent.hostID)
                }
                guard let createdTerminal, let target = console.terminals.first(where: {
                    $0.hostID == agent.hostID && $0.terminalID == createdTerminal.terminalID
                }) else {
                    terminalOpenFailure = "The terminal was created, but its Workspace hasn't refreshed yet. Try Open Terminal again to refresh it."
                    return
                }
                if isVisible() { onSelectTerminal?(target) }
            } catch {
                terminalOpenFailure = AgentOpenTerminalStore.presentation(for: error).message
            }
        }
    }
}

@MainActor
private final class AgentDetailAttachReference {
    var store: AgentAttachStore
    init(_ store: AgentAttachStore) { self.store = store }
}
