import SwiftUI

/// Both terminal entry points share the same lazy connection and renderer.
struct WorkspaceTerminalDetailView: View {
    let terminal: ConsoleTerminal
    let console: ConsoleStore
    /// The core whose Terminal this screen opened on. It outlives the screen: a
    /// remount at this address is still that Terminal.
    let corePin: TerminalCorePin
    let settings: TerminalSettings
    let activity: AppActivityCoordinator
    let onSelectAgent: (ConsoleAgent.ID) -> Void
    let onSelectTerminal: (ConsoleTerminal) -> Void
    var isSelected: () -> Bool = { true }
    /// Keyboard state in from the screen that selected this terminal and
    /// out to an Agent the drawer routes to; see `ShellTerminalView`.
    var keyboardHandoff: TerminalKeyboardHandoff? = nil
    /// The surface Agent details open on; nil counts as the terminal.
    var agentSurface: AgentDetailSurfaceSettings? = nil
    /// Where the terminal's screen hears and measures the keyboard. Nil gives
    /// it one of its own on UIKit's center; a test passes one it drives.
    var keyboardInset: TerminalKeyboardInset? = nil
    /// Where Back goes: the Console, or the Agent this was pushed over.
    var backTitle = String(localized: "Back to Console")
    let onBack: () -> Void

    @State private var ownerID = UUID()
    @State private var entry: TerminalConnectionPool.Entry?
    @State private var failure: String?
    @State private var isClosing = false
    @State private var closeFailure: String?
    @State private var isCreatingTerminal = false
    @State private var createFailure: String?
    @State private var retryID = 0
    /// A departure the terminal's screen made for an Agent that opens on
    /// Chat, while the keyboard goes down there. Held here, since that screen
    /// can go first: the pane a shell starts its Agent in stops being a
    /// terminal, and the pool lets it go at the next inventory change, on a
    /// Herdr TUI Host often before UIKit reports the keyboard gone (#644).
    @State private var departureAwaitingKeyboardHide: ShellTerminalView.AgentDeparture?
    /// This screen among the Agent viewers the Console counts, until SwiftUI
    /// drops its state.
    @State private var presence = AgentViewerPresence()
    @Environment(\.themeAppearance) private var themeAppearance
    @Environment(\.detailSurfaceEdges) private var surfaceEdges
    @Environment(\.scenePhase) private var scenePhase
    /// This window, so a remount of this screen takes its terminal over.
    @Environment(\.agentSceneRouting) private var sceneRouting

    private var identity: ShellTerminalIdentity {
        ShellTerminalIdentity(paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID)
    }

    private var poolKey: TerminalConnectionPool.Key {
        .init(hostID: terminal.hostID, identity: identity)
    }

    private var themePalette: TerminalThemePalette {
        settings.themes.selection(for: themeAppearance).palette(for: themeAppearance)
    }

    /// The states before and after the terminal draw on its surface too,
    /// as the Agent screen's do: the status bar and tab bar already follow
    /// the terminal's scheme from the first frame, and a light system page
    /// would flash under them before every shell.
    private func terminalSurface(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            settings.themes.selection(for: themeAppearance).surfaceBackground(for: themeAppearance)
                .ignoresSafeArea(edges: surfaceEdges)
            content()
        }
    }

    /// Closing a window changes nothing `isSelected` reads.
    private var windowHasEnded: Bool {
        console.hasSceneEnded(sceneRouting?.sceneID, on: terminal.hostID)
    }

    private var isMissing: Bool {
        console.hostStatuses[terminal.hostID] == .connected
            && !console.hostsAwaitingSnapshot.contains(terminal.hostID)
            && !console.terminals.contains(where: { $0.id == terminal.id && $0.terminalID == terminal.terminalID })
    }

    /// The pool's entry while this screen shows its terminal.
    private var shownEntry: TerminalConnectionPool.Entry? {
        guard let entry, console.terminalConnections.entries[poolKey] === entry else { return nil }
        return entry
    }

    /// The Agent this shell has started, which the screen leaves for. Another
    /// core's Agent at this address is no Agent of this Terminal's. An Agent
    /// that opens on its terminal, a Rex one, is this screen already
    /// (ADR 0054), opened from either list: the screen stays, with its
    /// connection and the size it took for it.
    private var startedAgentID: ConsoleAgent.ID? {
        guard let agentID = terminal.agentID,
            !console.capabilities(for: terminal.hostID).agentsOpenAsTerminals,
            !console.hasLeftCore(corePin, on: terminal.hostID)
        else { return nil }
        return agentID
    }

    /// The Agent in front of the user, on a Host whose Agents open on their
    /// terminals: there this screen is the Agent's detail, from either list,
    /// and showing it is looking at its finished turn (ADR 0054). It names
    /// its Pane before an Agent starts there too, so a turn that ends while
    /// it is shown is seen. The router says whether it is shown, as it does
    /// for the connection.
    private var shownAgent: ConsoleAgent.ID? {
        guard console.capabilities(for: terminal.hostID).agentsOpenAsTerminals,
            scenePhase == .active, isSelected(), !windowHasEnded
        else { return nil }
        return .init(hostID: terminal.hostID, paneID: terminal.paneID)
    }

    /// Whether `id`'s detail opens on Chat rather than its terminal. The
    /// drawer's Agents are this Terminal's Workspace on the same Host, so the
    /// same core pin applies to them as to a started one.
    private func opensOnChat(_ id: ConsoleAgent.ID) -> Bool {
        guard let agentSurface, let agent = console.detailAgent(for: id) else { return false }
        return AgentDetailView.openingSurface(
            for: agent, console: console, preferred: agentSurface.preferred, keepingTo: corePin) == .chat
    }

    var body: some View {
        Group {
            if isMissing {
                terminalSurface {
                    TerminalStatusDialog(
                        glyph: .symbol("terminal"),
                        title: String(localized: "Terminal Closed"),
                        message: console.terminalEndedMessage(keepingTo: corePin, on: terminal.hostID)
                            ?? String(localized: "This pane is no longer available on the Host."),
                        palette: themePalette,
                        dimsBackground: false
                    ) {
                        Button(backTitle) { onBack() }
                            .buttonStyle(.terminalStatusSecondary)
                    }
                }
            } else if let entry = shownEntry {
                ShellTerminalView(
                    store: entry.store,
                    agentID: .init(hostID: terminal.hostID, paneID: terminal.paneID),
                    terminal: settings,
                    activity: activity,
                    isReturning: false,
                    isClosingTerminal: isClosing,
                    onCloseTerminal: console.capabilities(for: terminal.hostID).closeTab
                        ? { @MainActor @Sendable in closeTerminal() } : nil,
                    finishedMessage: console.terminalEndedMessage(keepingTo: corePin, on: terminal.hostID),
                    managesLifecycle: false,
                    offersTakeOver: console.capabilities(for: terminal.hostID).takeOver,
                    surfaceRetention: entry.surfaceRetention,
                    title: terminal.displayTitle,
                    backTitle: backTitle,
                    workspaceDrawer: workspaceDrawer,
                    keyboardHandoff: keyboardHandoff,
                    backReturnsToAgent: false,
                    startedAgentID: startedAgentID,
                    onAgentStarted: { onSelectAgent($0) },
                    chatDepartures: AgentChatDepartures(
                        opensOnChat: { opensOnChat($0) },
                        awaitingKeyboardHide: $departureAwaitingKeyboardHide),
                    keyboardInsetOverride: keyboardInset,
                    onBack: { onBack() })
            } else if let failure {
                terminalSurface {
                    TerminalStatusDialog(
                        glyph: .symbol("exclamationmark.triangle"),
                        title: String(localized: "Couldn't Open Terminal"),
                        message: failure,
                        palette: themePalette,
                        dimsBackground: false
                    ) {
                        Button("Try Again") { retryID += 1 }
                            .buttonStyle(.terminalStatusPrimary)
                        Button(backTitle) { onBack() }
                            .buttonStyle(.terminalStatusSecondary)
                    }
                }
            } else {
                terminalSurface {
                    TerminalStatusDialog(
                        glyph: .progress, title: String(localized: "Opening Terminal…"),
                        palette: themePalette, dimsBackground: false)
                }
                // The keyboard this screen inherits must not drop while
                // the connection is prepared; see `TerminalKeyboardHolder`.
                .background {
                    if keyboardHandoff?.isShellTerminalArmed == true {
                        TerminalKeyboardHolderView()
                    }
                }
            }
        }
        // The terminal draws its own Back. Hidden here, not only on the
        // terminal, so no state before it (the first frames of a push show
        // Opening Terminal even for a pooled connection) flashes the bar's.
        .navigationBarBackButtonHidden(true)
        // A terminal left for another tab or screen comes back pooled:
        // claimed before the first frame, it never shows Opening Terminal.
        .onAppear {
            reclaimPooledEntry()
        }
        .task(id: LoadIdentity(
            identity: identity,
            generation: console.hostConnectionGenerations[terminal.hostID],
            activation: activity.activationCount,
            retry: retryID)) {
                await load()
        }
        .onChange(of: shownAgent, initial: true) { _, shown in
            presence.show(shown, on: console, scene: sceneRouting?.sceneID)
        }
        .onDisappear {
            let leavingIdentity = entry?.store.identity ?? identity
            let keepingKeyboard = keyboardHandoff?.isArmed ?? false
            let presence = presence
            let scene = sceneRouting?.sceneID
            if !isSelected() {
                console.terminalConnections.release(
                    hostID: terminal.hostID, identity: leavingIdentity, ownerID: ownerID,
                    keepingKeyboard: keepingKeyboard)
                presence.show(nil, on: console, scene: scene)
            } else {
                // Still selected: a spurious disappear, which keeps showing
                // the Agent, or a remount, whose old state lets go of it.
                Task { @MainActor in
                    await Task.yield()
                    guard !isSelected() else { return }
                    console.terminalConnections.release(
                        hostID: terminal.hostID, identity: leavingIdentity, ownerID: ownerID,
                        keepingKeyboard: keepingKeyboard)
                    presence.show(nil, on: console, scene: scene)
                }
            }
        }
        // A shown terminal leaves for its Agent itself, once it has settled
        // the keyboard; see `ShellTerminalView.leave(_:)`.
        .onChange(of: startedAgentID, initial: true) { _, agentID in
            if let agentID {
                if shownEntry == nil { onSelectAgent(agentID) }
            } else if case .started = departureAwaitingKeyboardHide {
                departureAwaitingKeyboardHide = nil
            }
        }
        .modifier(AgentKeyboardDeparture(
            awaitingHide: $departureAwaitingKeyboardHide,
            // Where the terminal's screen hears the keyboard.
            notificationCenter: keyboardInset?.notificationCenter ?? .default,
            complete: completeDeparture))
        .alert("Couldn't Close Terminal", isPresented: Binding(
            get: { closeFailure != nil }, set: { if !$0 { closeFailure = nil } })
        ) {
            Button("OK", role: .cancel) { closeFailure = nil }
        } message: {
            Text(closeFailure ?? "")
        }
        .alert("Couldn't Open Terminal", isPresented: Binding(
            get: { createFailure != nil }, set: { if !$0 { createFailure = nil } })
        ) {
            Button("OK", role: .cancel) { createFailure = nil }
        } message: {
            Text(createFailure ?? "")
        }
    }

    /// Routes as this screen now stands, which may have changed while the
    /// keyboard went down.
    private func completeDeparture(_ departure: ShellTerminalView.AgentDeparture) {
        switch departure {
        case .started(let id):
            // The Agent may have ended while the keyboard went down.
            guard startedAgentID == id else { return }
            onSelectAgent(id)
        case .drawer(let target, _):
            workspaceDrawer?.onSelect(target)
        }
    }

    private var workspaceDrawer: WorkspaceTerminalDrawer? {
        let terminals = console.terminals(on: terminal.hostID, workspaceID: terminal.workspaceID)
        guard !terminals.isEmpty else { return nil }
        return WorkspaceTerminalDrawer(
            terminals: terminals,
            selectedPaneID: terminal.paneID,
            edgeDock: settings.edgeDock,
            onSelect: { target in
                if let agentID = target.agentID { onSelectAgent(agentID) }
                else if target.id != terminal.id { onSelectTerminal(target) }
            },
            onNewTerminal: creationRequest == nil ? nil : { createTerminal() },
            isCreatingTerminal: isCreatingTerminal)
    }

    /// A new tab opens beside this one, in its directory.
    private var creationRequest: ShellTerminalCreationRequest? {
        console.capabilities(for: terminal.hostID)
            .newTerminalRequest(workspaceID: terminal.workspaceID, cwd: terminal.cwd)
    }

    private func createTerminal() {
        guard !isCreatingTerminal, let creationRequest else { return }
        isCreatingTerminal = true
        Task { @MainActor in
            defer { isCreatingTerminal = false }
            do {
                let created = try await console.createShellTerminal(creationRequest, on: terminal.hostID)
                guard let target = console.terminals.first(where: {
                    $0.hostID == terminal.hostID && $0.terminalID == created.terminalID
                }) else {
                    keyboardHandoff?.cancelShellTerminal()
                    createFailure = String(localized: "The terminal was created, but its Workspace hasn't refreshed yet.")
                    return
                }
                onSelectTerminal(target)
            } catch {
                keyboardHandoff?.cancelShellTerminal()
                createFailure = AgentOpenTerminalStore.presentation(for: error).message
            }
        }
    }

    private struct LoadIdentity: Equatable {
        let identity: ShellTerminalIdentity
        let generation: UInt64?
        let activation: UInt64
        let retry: Int
    }

    private func reclaimPooledEntry() {
        guard entry == nil, !isMissing else { return }
        entry = console.terminalConnections.reclaim(
            hostID: terminal.hostID, identity: identity, ownerID: ownerID,
            sceneID: sceneRouting?.sceneID,
            generation: console.hostConnectionGenerations[terminal.hostID],
            corePin: corePin,
            isPresented: { isSelected() })
    }

    private func load() async {
        guard !isMissing, !windowHasEnded else { return }
        failure = nil
        if let entry, entry.store.identity != identity {
            console.terminalConnections.release(
                hostID: terminal.hostID, identity: entry.store.identity, ownerID: ownerID)
            self.entry = nil
        }
        do {
            let selected = try await console.terminalConnections.select(
                hostID: terminal.hostID, identity: identity, ownerID: ownerID,
                sceneID: sceneRouting?.sceneID,
                generation: console.hostConnectionGenerations[terminal.hostID],
                corePin: corePin,
                isPresented: { isSelected() },
                runTerminal: console.terminalRunner(for: terminal.hostID, keepingTo: corePin))
            guard !Task.isCancelled else {
                retryAfterSpuriousDisappear()
                return
            }
            // The window closed while this waited, past its `sceneDidEnd`.
            guard !windowHasEnded else {
                console.terminalConnections.release(
                    hostID: terminal.hostID, identity: identity, ownerID: ownerID)
                return
            }
            entry = selected
        } catch is CancellationError {
            retryAfterSpuriousDisappear()
            return
        } catch {
            failure = error.localizedDescription
            // Nothing is coming to take the keyboard; a later open must
            // start with it down.
            keyboardHandoff?.cancelShellTerminal()
        }
    }

    /// SwiftUI can hand this screen an onDisappear it never follows with an
    /// onAppear (seen when a new shell opens right after Back to Console),
    /// cancelling the load while the screen stays up. The router, not
    /// SwiftUI, says whether it is still shown; if so, load again.
    private func retryAfterSpuriousDisappear() {
        Task { @MainActor in
            await Task.yield()
            guard isSelected(), entry == nil, failure == nil else { return }
            // `.task` does not restart for a screen SwiftUI thinks is gone,
            // so this load runs outside it.
            await load()
            if entry != nil, !isSelected() {
                console.terminalConnections.release(
                    hostID: terminal.hostID, identity: identity, ownerID: ownerID)
            }
        }
    }

    private func closeTerminal() {
        guard !isClosing else { return }
        isClosing = true
        Task { @MainActor in
            defer { isClosing = false }
            do {
                try await console.closePane(terminal.paneID, on: terminal.hostID, keepingTo: corePin)
                await console.terminalConnections.remove(hostID: terminal.hostID, identity: identity)
                onBack()
            } catch {
                closeFailure = ConsoleStore.tabCloseFailureMessage(for: error)
            }
        }
    }
}

/// One screen's place among the Console's Agent viewers
/// (`ConsoleStore.setAgentShown`). It lets go when SwiftUI drops the screen's
/// state: a screen rebuilt while it stays selected gets an `onDisappear` it
/// cannot tell from a spurious one, after which it keeps showing the Agent,
/// so only its state going says the old screen is gone.
final class AgentViewerPresence {
    let token = UUID()
    /// Where the Agent is shown from, while this screen shows one.
    private var shown: (console: ConsoleStore, scene: UUID?)?

    @MainActor
    func show(_ agent: ConsoleAgent.ID?, on console: ConsoleStore, scene: UUID?) {
        console.setAgentShown(agent, viewer: token, scene: scene)
        shown = agent == nil ? nil : (console, scene)
    }

    deinit {
        guard let shown else { return }
        let token = token
        let console = shown.console
        let scene = shown.scene
        Task { @MainActor in console.setAgentShown(nil, viewer: token, scene: scene) }
    }
}
