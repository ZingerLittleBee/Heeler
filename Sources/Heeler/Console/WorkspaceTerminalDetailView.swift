import SwiftUI

/// Both terminal entry points share the same lazy connection and renderer.
struct WorkspaceTerminalDetailView: View {
    let terminal: ConsoleTerminal
    let console: ConsoleStore
    let settings: TerminalSettings
    let activity: AppActivityCoordinator
    let onSelectAgent: (ConsoleAgent.ID) -> Void
    let onSelectTerminal: (ConsoleTerminal) -> Void
    var isSelected: () -> Bool = { true }
    /// Keyboard state in from the screen that selected this terminal and
    /// out to an Agent the drawer routes to; see `ShellTerminalView`.
    var keyboardHandoff: TerminalKeyboardHandoff? = nil
    let onBack: () -> Void

    @State private var ownerID = UUID()
    @State private var entry: TerminalConnectionPool.Entry?
    @State private var failure: String?
    @State private var isClosing = false
    @State private var closeFailure: String?
    @State private var isCreatingTerminal = false
    @State private var createFailure: String?
    @State private var retryID = 0

    private var identity: ShellTerminalIdentity {
        ShellTerminalIdentity(paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID)
    }

    private var poolKey: TerminalConnectionPool.Key {
        .init(hostID: terminal.hostID, identity: identity)
    }

    private var isMissing: Bool {
        console.hostStatuses[terminal.hostID] == .connected
            && !console.hostsAwaitingSnapshot.contains(terminal.hostID)
            && !console.terminals.contains(where: { $0.id == terminal.id && $0.terminalID == terminal.terminalID })
    }

    var body: some View {
        Group {
            if isMissing {
                ContentUnavailableView("Terminal Closed", systemImage: "terminal",
                    description: Text("This pane is no longer available on the Host."))
            } else if let entry, console.terminalConnections.entries[poolKey] === entry {
                ShellTerminalView(
                    store: entry.store,
                    agentID: .init(hostID: terminal.hostID, paneID: terminal.paneID),
                    terminal: settings,
                    activity: activity,
                    isReturning: false,
                    isClosingTerminal: isClosing,
                    onCloseTerminal: { closeTerminal() },
                    managesLifecycle: false,
                    surfaceRetention: entry.surfaceRetention,
                    title: terminal.displayTitle,
                    backTitle: "Back to Console",
                    workspaceDrawer: workspaceDrawer,
                    keyboardHandoff: keyboardHandoff,
                    backReturnsToAgent: false,
                    onBack: { onBack() })
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Open Terminal", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { retryID += 1 }
                }
            } else {
                ProgressView("Opening Terminal…")
                    // The keyboard this screen inherits must not drop while
                    // the connection is prepared; see `TerminalKeyboardHolder`.
                    .background {
                        if keyboardHandoff?.isShellTerminalArmed == true {
                            TerminalKeyboardHolderView()
                        }
                    }
            }
        }
        .task(id: LoadIdentity(
            identity: identity,
            generation: console.hostConnectionGenerations[terminal.hostID],
            activation: activity.activationCount,
            retry: retryID)) {
                await load()
        }
        .onDisappear {
            let leavingIdentity = entry?.store.identity ?? identity
            let keepingKeyboard = keyboardHandoff?.isArmed ?? false
            if !isSelected() {
                console.terminalConnections.release(
                    hostID: terminal.hostID, identity: leavingIdentity, ownerID: ownerID,
                    keepingKeyboard: keepingKeyboard)
            } else {
                Task { @MainActor in
                    await Task.yield()
                    guard !isSelected() else { return }
                    console.terminalConnections.release(
                        hostID: terminal.hostID, identity: leavingIdentity, ownerID: ownerID,
                        keepingKeyboard: keepingKeyboard)
                }
            }
        }
        .onChange(of: terminal.agentID, initial: true) { _, agentID in
            if let agentID { onSelectAgent(agentID) }
        }
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

    /// A new tab opens beside this one, in its directory. Like Agent
    /// detail's Open Terminal, a pane without a usable directory offers no
    /// New Terminal rather than letting herdr pick some other Pane's cwd.
    private var creationRequest: ShellTerminalCreationRequest? {
        let cwd = terminal.cwd
        guard cwd.hasPrefix("/") else { return nil }
        return ShellTerminalCreationRequest(workspaceID: terminal.workspaceID, cwd: cwd)
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
                    createFailure = "The terminal was created, but its Workspace hasn't refreshed yet."
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

    private func load() async {
        guard !isMissing else { return }
        failure = nil
        if let entry, entry.store.identity != identity {
            console.terminalConnections.release(
                hostID: terminal.hostID, identity: entry.store.identity, ownerID: ownerID)
            self.entry = nil
        }
        do {
            let selected = try await console.terminalConnections.select(
                hostID: terminal.hostID, identity: identity, ownerID: ownerID,
                generation: console.hostConnectionGenerations[terminal.hostID],
                isPresented: { isSelected() },
                runTerminal: console.terminalRunner(for: terminal.hostID))
            guard !Task.isCancelled else {
                retryAfterSpuriousDisappear()
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
                try await console.closePane(terminal.paneID, on: terminal.hostID)
                await console.terminalConnections.remove(hostID: terminal.hostID, identity: identity)
                onBack()
            } catch {
                closeFailure = error.localizedDescription
            }
        }
    }
}
