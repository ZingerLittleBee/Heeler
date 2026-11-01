import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream.
/// Composer owns authored delivery by default; Direct Input (ADR 0016) is an
/// explicit opt-in that types the Attach PTY with the system keyboard. A
/// Claude Code or Codex Agent can show Chat in the terminal's place
/// (ADR 0024); the two are never mounted together.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let inputMode: AgentInputModeSettings
    private let detailSurface: AgentDetailSurfaceSettings
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let isVisible: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    private let onSelectTerminal: ((ConsoleTerminal) -> Void)?
    /// Told whether Changes is shown in place of the terminal, so the
    /// Console stops dressing the window's chrome for a terminal.
    private let onShowsChanges: ((Bool) -> Void)?
    /// Told whether Chat is shown in place of the terminal, for the same
    /// reason.
    private let onShowsChat: ((Bool) -> Void)?
    /// Bumped when a notification lands on this Agent while it is already
    /// on the path: a pushed Shell Terminal steps back to it.
    private let repeatLandings: Int
    /// This detail's own copy of the remembered surface, taken when it
    /// opens: a choice made in another window leaves this one alone.
    @State private var surface: AgentDetailSurface
    @State private var focus = AgentFocusCoordinator()
    @State private var hasAppeared = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: AgentComposerSession
    /// This detail's presence in `session`, outside a scene root.
    @State private var presenceToken = UUID()
    @State private var attach: AgentAttachStore
    @State private var openTerminal: AgentOpenTerminalStore
    @State private var changes: AgentChangesPresentation
    @State private var retainedAgent: AgentTerminalCache.Entry?
    @State private var retentionOwnerID: UUID
    /// Lives as long as this detail does, which tells the cache whether a
    /// retained terminal hidden here will be wanted back.
    @State private var retentionHolder = AgentDetailRetentionHolder()
    /// `attach` is this detail's own viewer of a core Terminal another
    /// detail retains.
    @State private var isOwnViewer = false
    @State private var attachReference: AgentDetailAttachReference
    private let permitsRetention: Bool
    @State private var isResolvingTerminal = false
    @State private var isChoosingTerminal = false
    @State private var terminalOpenFailure: String?
    @State private var createdTerminal = CreatedWorkspaceTerminal()
    /// A Shell Terminal pushed over this Agent by Open Terminal, so Back
    /// returns here; nil beside a list, where the list selects it instead.
    /// The Console holds it, so a detail SwiftUI remounts (a size-class
    /// change) keeps it; this detail's own copy stands in outside one.
    private let heldShellRoute: Binding<WorkspaceTerminalRoute?>?
    @State private var ownShellRoute: WorkspaceTerminalRoute?
    private var shellRouteSelection: Binding<WorkspaceTerminalRoute?> {
        heldShellRoute ?? $ownShellRoute
    }
    private var shellRoute: WorkspaceTerminalRoute? {
        get { shellRouteSelection.wrappedValue }
        nonmutating set { shellRouteSelection.wrappedValue = newValue }
    }
    /// The detail stands alone, pushed over its list, rather than beside it.
    @Environment(\.showsDetailBackButton) private var isPushedOverList
    /// Which window holds this Host's terminal channel; nil outside a scene
    /// root, where this detail always holds it.
    @Environment(\.agentSceneRouting) private var sceneRouting
    @Environment(\.sceneWindow) private var sceneWindow
    @Environment(\.detailCrossfade) private var detailCrossfade

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        inputMode: AgentInputModeSettings,
        detailSurface: AgentDetailSurfaceSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        stage: AgentDetailStage,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        onSelectTerminal: ((ConsoleTerminal) -> Void)? = nil,
        onShowsChanges: ((Bool) -> Void)? = nil,
        onShowsChat: ((Bool) -> Void)? = nil,
        repeatLandings: Int = 0,
        shellRoute: Binding<WorkspaceTerminalRoute?>? = nil,
        composerSession: AgentComposerSession? = nil,
        attachStore: AgentAttachStore? = nil,
        openTerminalStore: AgentOpenTerminalStore? = nil,
        changesPresentation: AgentChangesPresentation? = nil
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.inputMode = inputMode
        self.detailSurface = detailSurface
        // A saved Chat entry's Host is not connected, so its terminal cannot
        // attach: it opens on Chat without changing the preference.
        _surface = State(
            initialValue: console.savedChatEntries[agent.id] != nil ? .chat : detailSurface.preferred)
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
        self.onShowsChanges = onShowsChanges
        self.onShowsChat = onShowsChat
        self.repeatLandings = repeatLandings
        heldShellRoute = shellRoute
        let session = composerSession ?? console.composerSession(for: agent)
        _session = State(initialValue: session)
        let corePin = session.corePin
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
                runTerminal: console.terminalRunner(for: agent.hostID, keepingTo: corePin)
            ) {
                try await console.closePane(agent.agent.paneID, on: agent.hostID, keepingTo: corePin)
            }
        _attach = State(initialValue: attach)
        let reference = AgentDetailAttachReference(attach)
        _attachReference = State(initialValue: reference)
        let hostID = agent.hostID
        let workspaceID = agent.agent.workspaceID
        _changes = State(
            initialValue: changesPresentation
                ?? AgentChangesPresentation.forAgentDetail(
                    agentID: agent.id, hostID: hostID, openingDirectory: agent.directory,
                    console: console))
        _openTerminal = State(
            initialValue: openTerminalStore
                ?? AgentOpenTerminalStore(
                    agent: agent,
                    transportGeneration: console.hostConnectionGenerations[agent.hostID],
                    isDetailOnStage: isOnStage,
                    createTerminal: { [console] request in
                        try await console.createShellTerminal(request, on: hostID)
                    },
                    runTerminal: console.terminalRunner(for: agent.hostID, keepingTo: corePin),
                    leaveAgent: { reference.store.leaveForTerminalHandoff() },
                    // Back to Chat, nothing shows the Agent's terminal; it
                    // rejoins when the terminal does.
                    rejoinAgent: {
                        guard !reference.showsChat else { return }
                        reference.store.rejoin()
                    },
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
                        try await console.closePane(identity.paneID, on: hostID, keepingTo: corePin)
                    }))
    }

    private var terminalAccess: HostTerminalAccess {
        console.capabilities(for: agent.hostID)
            .terminalAccess(sceneRouting?.terminalAccess(for: agent.hostID))
    }

    /// Whether Open Terminal has anywhere to go: a Shell Terminal already in
    /// this Workspace, or a new one on a Host that can start it.
    private var canOpenTerminal: Bool {
        guard terminalAccess == .holds else { return false }
        if console.capabilities(for: agent.hostID).startsTerminals {
            return !workspaceShells.isEmpty || openTerminal.canOpen
        }
        return onSelectTerminal != nil && !workspaceShells.isEmpty
    }

    /// One per window, so a detail SwiftUI remounts, as a size-class change
    /// does, takes its predecessor's place instead of outliving it.
    private var presenceKey: UUID {
        sceneRouting?.sceneID ?? presenceToken
    }

    private var changesRoute: Binding<ChangesRoute<ChangesStore>?> {
        Binding(
            get: { changes.store.map(ChangesRoute.init) },
            set: { if $0 == nil { changes.close() } })
    }

    /// Changes' screens, the list and a diff pushed over it, report coming
    /// and going; Changes as a whole hold the chrome while any is shown.
    /// Whether they still read in the row's place is the router's truth, not
    /// SwiftUI's: a view pushed over the page leaves it selected, while
    /// another tab or Agent does not.
    private var changesScreenPresence: ChangesScreenPresence {
        ChangesScreenPresence(
            appeared: { [changes, onShowsChanges, isVisible] in
                guard changes.screenAppeared(), changes.store != nil else { return }
                onShowsChanges?(true)
                if isVisible() { changes.detailAppeared() }
            },
            disappeared: { [changes, onShowsChanges, isVisible] in
                guard changes.screenDisappeared() else { return }
                onShowsChanges?(false)
                if !isVisible() { changes.detailDisappeared() }
            })
    }

    /// The program whose transcript Chat would read; nil while this Agent
    /// cannot show Chat, which hides every way to it.
    private var chatProgram: ChatProgram? {
        console.chatProgram(for: agent, keepingTo: session.corePin)
    }

    /// The chosen surface, or the terminal while Chat is unavailable. The
    /// choice itself is kept, so Chat comes back once it is available again.
    private var effectiveSurface: AgentDetailSurface {
        chatProgram == nil ? .terminal : surface
    }

    /// The terminal is on screen: no Shell Terminal, no Changes over it, and
    /// not Chat in its place.
    private var showsAgentTerminal: Bool {
        showsAgentSurface && effectiveSurface == .terminal
    }

    /// Chat is on screen in the terminal's place, with nothing over it.
    private var showsChatSurface: Bool {
        showsAgentSurface && effectiveSurface == .chat
    }

    /// Nothing stands over the Agent's own surface, Chat or terminal.
    private var showsAgentSurface: Bool {
        openTerminal.shell == nil && changes.store == nil && shellRoute == nil
    }

    /// Swaps Chat and the Agent terminal in place. A surface whose keyboard
    /// is up arms the handoff before calling this; only it knows.
    private func selectSurface(_ next: AgentDetailSurface) {
        guard next != effectiveSurface, next == .terminal || chatProgram != nil else { return }
        if let window = sceneWindow?.window { detailCrossfade?.beginSwap(in: window) }
        surface = next
        detailSurface.select(next)
        attachReference.showsChat = next == .chat
        // Claim the Host's channel before the terminal asks whether it
        // holds it, so the first build uses the retained Attach.
        sceneRouting?.chatSurfaceDidChange(agent: next == .chat ? agent.id : nil)
        if next == .terminal { applyTerminalAccess() }
    }

    private func applyTerminalAccess() {
        guard showsAgentTerminal, !openTerminal.isOpening else { return }
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

    /// Closing a window changes nothing `isOnStage` reads.
    private var windowHasEnded: Bool {
        console.hasSceneEnded(sceneRouting?.sceneID, on: agent.hostID)
    }

    private func prepareRetainedAgent() {
        guard permitsRetention, isOnStage(), showsAgentTerminal, !windowHasEnded else { return }
        if let retainedAgent, retainedAgent.isRetained {
            console.agentTerminals.activate(retainedAgent, ownerID: retentionOwnerID, isPresented: { isOnStage() })
            return
        }
        // A core Terminal takes any number of viewers, so another window's
        // detail keeps the one it retains, and this one is a viewer of its own.
        let takesViewers = !console.capabilities(for: agent.hostID).takeOver
        let sceneID = takesViewers ? sceneRouting?.sceneID : nil
        if takesViewers,
            console.agentTerminals.isHeldByAnotherDetail(
                agent, ownerID: retentionOwnerID, sceneID: sceneID)
        {
            guard !isOwnViewer else { return }
            if retainedAgent == nil { attach.leaveForTerminalHandoff() }
            retainedAgent = nil
            isOwnViewer = true
            attach = makePrivateAttach()
            attachReference.store = attach
            if let sceneID { console.agentTerminals.addViewer(attach, sceneID: sceneID) }
            return
        }
        if retainedAgent == nil { attach.leaveForTerminalHandoff() }
        let entry = console.agentTerminals.acquire(
            agent: agent, console: console, ownerID: retentionOwnerID, sceneID: sceneID,
            holder: retentionHolder, corePin: session.corePin, isPresented: { isOnStage() })
        retainedAgent = entry
        isOwnViewer = false
        attach = entry.attach
        attachReference.store = attach
    }

    private func makePrivateAttach() -> AgentAttachStore {
        let console = console
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        let sceneID = sceneRouting?.sceneID
        let isOnStage = isOnStage
        let corePin = session.corePin
        return AgentAttachStore(
            target: agent.agent.paneID,
            paneTitle: AgentTerminalView.displayTitle(for: agent),
            transportGeneration: console.hostConnectionGenerations[agent.hostID],
            isOnStage: { isOnStage() && !console.hasSceneEnded(sceneID, on: hostID) },
            runTerminal: console.terminalRunner(for: agent.hostID, keepingTo: corePin),
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(paneID, on: hostID, keepingTo: corePin)
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
            showsShellTerminal: openTerminal.shell != nil || openTerminal.isOpening
                || shellRoute != nil)
    }

    private func updateFocus() {
        let state = focusViewingState
        console.setAgentShown(
            state.showsAgent ? agent.id : nil, viewer: presenceToken, scene: sceneRouting?.sceneID)
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
                    finishedMessage: console.terminalEndedMessage(keepingTo: session.corePin, on: agent.hostID),
                    workspaceDrawer: workspaceDrawer,
                    keyboardHandoff: keyboardHandoff
                ) {
                    await openTerminal.returnToAgent()
                }
                .id(openTerminal.destination)
            } else if effectiveSurface == .chat, let chatProgram {
                AgentChatSurfaceView(
                    agent: agent,
                    program: chatProgram,
                    console: console,
                    terminal: terminal,
                    hosts: hosts,
                    session: session,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    // Chat holds no terminal channel, so a detail that lost
                    // it to another window still shows Chat.
                    isOnStage: { isVisible() && showsChatSurface },
                    onSwitch: onSwitch,
                    onClosed: onClosed,
                    canOpenTerminal: canOpenTerminal,
                    isOpeningTerminal: openTerminal.isOpening || isResolvingTerminal,
                    openTerminal: { openWorkspaceTerminal() },
                    showChanges: agent.directory == nil ? nil : { changes.open() },
                    workspaceDrawer: workspaceDrawer,
                    selectSurface: { selectSurface($0) })
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
                        isOnStage() && showsAgentTerminal
                    },
                    // A detail that lost its Host channel to another window
                    // is still on screen, and its sheets still cover commands.
                    isCommandOnStage: {
                        isVisible() && showsAgentTerminal
                    },
                    onSwitch: onSwitch,
                    onClosed: onClosed,
                    canOpenTerminal: canOpenTerminal,
                    isOpeningTerminal: openTerminal.isOpening || isResolvingTerminal,
                    openTerminal: { openWorkspaceTerminal() },
                    // Any Agent with a directory, whatever its worktree
                    // metadata: git resolves the Checkout on the Host.
                    showChanges: agent.directory == nil ? nil : { changes.open() },
                    showWorktreeChanges: { directory in
                        changes.open(directory: directory)
                    },
                    showChat: chatProgram == nil ? nil : { selectSurface(.chat) },
                    session: session,
                    attachStore: attach,
                    retainedSurface: retainedAgent?.surfaceRetention,
                    onRetainDeparture: retainedAgent.map { entry in
                        { keepingKeyboard in
                            console.agentTerminals.release(
                                entry, ownerID: retentionOwnerID, keepingKeyboard: keepingKeyboard)
                        }
                    },
                    workspaceDrawer: workspaceDrawer,
                    // Retention swaps `attach` on appear and rebuilds this
                    // view; the build before that swap is a placeholder and
                    // must not spend the keyboard handoff meant for the real one.
                    inheritsKeyboardHandoff: !permitsRetention || retainedAgent != nil || isOwnViewer)
                .id(ObjectIdentifier(attach))
            }
        }
        // Pushed as Hosts pushes a Host, so Back and the swipe are the
        // system's own; either one closes the presentation.
        .navigationDestination(item: changesRoute) { route in
            ChangesView(store: route.store)
                .environment(\.changesScreenPresence, changesScreenPresence)
        }
        // Open Terminal on an iPhone: a short detour, so Back and the swipe
        // come back to this Agent rather than to the list.
        .navigationDestination(item: shellRouteSelection) { route in
            pushedTerminal(route)
        }
        .onAppear {
            hasAppeared = true
            // A detail mounted afresh covers nothing, whatever the last one
            // in this window left behind.
            sceneRouting?.agentCoverDidChange(agent: shellRoute == nil ? nil : agent.id)
            session.detailDidAppear(presenceKey)
            prepareRetainedAgent()
            updateFocus()
        }
        .onChange(of: focusViewingState) {
            updateFocus()
        }
        .onDisappear {
            hasAppeared = false
            focus.leave()
            console.setAgentShown(nil, viewer: presenceToken, scene: sceneRouting?.sceneID)
            // The router's truth, not SwiftUI's: a spurious disappear, or
            // Changes pushed over the detail, keeps the upload going.
            let key = presenceKey
            let session = session
            Task { @MainActor in
                await Task.yield()
                guard !isVisible() else { return }
                session.detailDidDisappear(key)
            }
        }
        .onChange(of: console.hostConnectionGenerations[agent.hostID]) { _, generation in
            prepareRetainedAgent()
            openTerminal.transportGenerationDidChange(generation)
        }
        .onChange(of: activity.activationCount) { prepareRetainedAgent() }
        .confirmationDialog("Open Terminal", isPresented: $isChoosingTerminal, titleVisibility: .visible) {
            ForEach(workspaceShells) { @Sendable target in
                Button("\(target.displayTitle) · \(target.tabLabel ?? "Terminal")") {
                    showWorkspaceTerminal(target)
                }
            }
            if agent.shellTerminalCreationRequest != nil, console.capabilities(for: agent.hostID).startsTerminals {
                Button("New Terminal") { createWorkspaceTerminal() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .modifier(AgentStatusExplanationPresenter(console: console, agentID: agent.id))
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
        // Back from Changes: the terminal left as it does for the Agent list,
        // so it comes back the same way, through retention and rejoin.
        .onChange(of: changes.store == nil) { _, showsTerminal in
            onShowsChanges?(!showsTerminal)
            if showsTerminal {
                applyTerminalAccess()
                if let text = changes.takePendingInsertion() {
                    // Chat always writes through the Composer.
                    if inputMode.isDirect && effectiveSurface == .terminal {
                        attach.insertReference(text)
                    } else {
                        session.composer.insertIntoDraft(text)
                    }
                }
            }
        }
        // Availability can move the surface too: Chat appears once the
        // Host's platform is known, and goes when the Agent stops being one
        // Chat can read.
        .onChange(of: effectiveSurface, initial: true) { previous, current in
            attachReference.showsChat = current == .chat
            sceneRouting?.chatSurfaceDidChange(agent: current == .chat ? agent.id : nil)
            onShowsChat?(current == .chat && shellRoute == nil)
            if previous != current { applyTerminalAccess() }
        }
        // Back from a pushed Shell Terminal: the Agent's surface comes back
        // as it does from Changes. The terminal's chrome is the window's
        // while it stands over Chat.
        .onChange(of: shellRoute == nil) { _, showsAgent in
            onShowsChat?(effectiveSurface == .chat && showsAgent)
            sceneRouting?.agentCoverDidChange(agent: showsAgent ? nil : agent.id)
            if showsAgent { applyTerminalAccess() }
        }
        // A notification for this Agent, tapped while its Shell Terminal is
        // pushed, lands on the Agent rather than leaving the shell up.
        .onChange(of: repeatLandings) {
            shellRoute = nil
        }
        // A window widened beside its list: the list selects the terminal
        // pushed while the detail stood alone.
        .onChange(of: isPushedOverList, initial: true) { _, pushedOverList in
            guard !pushedOverList, let route = shellRoute else { return }
            shellRoute = nil
            onSelectTerminal?(route.terminal)
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
            edgeDock: terminal.edgeDock,
            onSelect: { target in
                if let agentID = target.agentID {
                    if agentID != agent.id { onSwitch(agentID) }
                    else if openTerminal.shell != nil {
                        Task { await openTerminal.returnToAgent() }
                    }
                } else {
                    onSelectTerminal(target)
                }
            },
            onNewTerminal: agent.shellTerminalCreationRequest == nil
                || !console.capabilities(for: agent.hostID).startsTerminals
                ? nil : { createWorkspaceTerminal(fresh: true) },
            isCreatingTerminal: isResolvingTerminal)
    }

    private var workspaceShells: [ConsoleTerminal] {
        console.terminals(on: agent.hostID, workspaceID: agent.agent.workspaceID)
            .filter { !$0.isAgent }
    }

    private func openWorkspaceTerminal() {
        guard onSelectTerminal != nil else { openTerminal.open(); return }
        _ = createdTerminal.resolve(in: console.terminals, hostID: agent.hostID)
        if createdTerminal.identity != nil { createWorkspaceTerminal(); return }
        switch workspaceShells.count {
        case 0: createWorkspaceTerminal()
        case 1: showWorkspaceTerminal(workspaceShells[0])
        default: isChoosingTerminal = true
        }
    }

    /// Open Terminal's destination: pushed over this Agent when the detail
    /// stands alone, selected in the list beside it otherwise. The drawer's
    /// picks always go through the list.
    private func showWorkspaceTerminal(_ target: ConsoleTerminal) {
        if isPushedOverList {
            shellRoute = WorkspaceTerminalRoute(terminal: target)
        } else {
            onSelectTerminal?(target)
        }
    }

    private func pushedTerminal(_ route: WorkspaceTerminalRoute) -> some View {
        WorkspaceTerminalDetailView(
            terminal: console.terminals.first(where: { $0.id == route.terminal.id })
                ?? route.terminal,
            console: console,
            corePin: session.corePin,
            settings: terminal,
            activity: activity,
            onSelectAgent: { id in
                if id == agent.id { shellRoute = nil } else { onSwitch(id) }
            },
            onSelectTerminal: { onSelectTerminal?($0) },
            isSelected: { [isVisible] in
                shellRoute?.terminal.id == route.terminal.id && isVisible()
            },
            keyboardHandoff: keyboardHandoff,
            backTitle: "Back to Agent",
            onBack: { shellRoute = nil })
        // A pushed screen takes the stack's environment, not this detail's,
        // and the Console sets Back inside the stack: without this the
        // terminal's header drew no Back, where a Terminals-tab push draws
        // one, and only the edge swipe returned to the Agent.
        .environment(\.showsDetailBackButton, isPushedOverList)
    }

    /// Open Terminal routes back to the tab this detail already created;
    /// `fresh` (the drawer's New Terminal) asks for another one, unless the
    /// last creation has not reached the inventory yet, in which case it is
    /// still the retry path and must not create a duplicate. A created tab
    /// closed since is forgotten, and Open Terminal goes where it would have
    /// without it.
    private func createWorkspaceTerminal(fresh: Bool = false) {
        guard !isResolvingTerminal, let request = agent.shellTerminalCreationRequest else { return }
        if createdTerminal.resolve(in: console.terminals, hostID: agent.hostID) != nil, fresh {
            createdTerminal.forget()
        }
        isResolvingTerminal = true
        Task { @MainActor in
            defer { isResolvingTerminal = false }
            do {
                if createdTerminal.identity != nil {
                    await console.refreshTerminalInventory(on: agent.hostID)
                    if createdTerminal.resolve(in: console.terminals, hostID: agent.hostID) == nil,
                        createdTerminal.identity == nil, !fresh, let shell = workspaceShells.first
                    {
                        if workspaceShells.count > 1 {
                            isChoosingTerminal = true
                        } else if isVisible() {
                            showWorkspaceTerminal(shell)
                        }
                        return
                    }
                }
                if createdTerminal.identity == nil {
                    createdTerminal.created(try await console.createShellTerminal(request, on: agent.hostID))
                }
                guard let target = createdTerminal.resolve(in: console.terminals, hostID: agent.hostID) else {
                    keyboardHandoff.cancelShellTerminal()
                    terminalOpenFailure = "The terminal was created, but its Workspace hasn't refreshed yet. Try Open Terminal again to refresh it."
                    return
                }
                if isVisible() { showWorkspaceTerminal(target) }
            } catch {
                keyboardHandoff.cancelShellTerminal()
                terminalOpenFailure = AgentOpenTerminalStore.presentation(for: error).message
            }
        }
    }
}

/// The Shell Terminal tab an Agent detail created for Open Terminal, which
/// Open Terminal goes back to rather than create another, until the
/// inventory shows it closed. Before the inventory first lists it, its
/// absence is the inventory not having caught up.
struct CreatedWorkspaceTerminal: Equatable {
    private(set) var identity: ShellTerminalIdentity?
    private(set) var wasListed = false

    mutating func created(_ identity: ShellTerminalIdentity) {
        self.identity = identity
        wasListed = false
    }

    mutating func forget() {
        identity = nil
        wasListed = false
    }

    /// The created tab as `inventory` lists it. One listed before that no
    /// longer is was closed, and is forgotten.
    mutating func resolve(in inventory: [ConsoleTerminal], hostID: Host.ID) -> ConsoleTerminal? {
        guard let identity else { return nil }
        if let target = inventory.first(where: { $0.hostID == hostID && $0.terminalID == identity.terminalID }) {
            wasListed = true
            return target
        }
        if wasListed { forget() }
        return nil
    }
}

/// A terminal is identified by its pane; the snapshot stands in while the
/// inventory no longer lists it.
struct WorkspaceTerminalRoute: Hashable {
    let terminal: ConsoleTerminal

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.terminal.id == rhs.terminal.id }
    func hash(into hasher: inout Hasher) { hasher.combine(terminal.id) }
}

/// The Shell Terminal pushed over one Agent's detail, held by the Console.
struct AgentShellRoute: Equatable {
    let agentID: ConsoleAgent.ID
    let route: WorkspaceTerminalRoute
}

private final class AgentDetailRetentionHolder {}

@MainActor
private final class AgentDetailAttachReference {
    var store: AgentAttachStore
    /// Chat shows in the terminal's place; read by the Shell Terminal
    /// return, which must not rejoin an Attach nothing shows.
    var showsChat = false
    init(_ store: AgentAttachStore) { self.store = store }
}
