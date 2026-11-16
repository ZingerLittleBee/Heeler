import Foundation

/// A Rex Host's share of the Console (ADRs 0049 and 0050): its connection, the
/// server that answers on its socket, and the terminals that server lists. A
/// session is a Workspace, a window a Tab and a terminal block a Pane, as
/// `RexOrganization` reads them, and a terminal running a known agent program
/// is an Agent with the status it reported to Rex (ADR 0054).
///
/// A Pane keeps to its server instance, as a tmux Pane does: another instance
/// leaves every detail open on the last one's terminals, and its Pins go. A
/// terminal opens from the server's redraw (ADR 0051) and takes input from its
/// first paint (ADR 0052), whether it is listed as an Agent or a Terminal;
/// every action a Host offers is unavailable on a Rex Host.
///
/// Done is per device, as on a tmux Host: each terminal's turns and this
/// device's seen marks (`RexTurnState`) are kept by server instance on this
/// device only, and opening an Agent's terminal is looking at it.
@MainActor
final class RexConsoleProjection: ConsoleHostProjection {
    private(set) var host: Host
    let session: RexHostSession

    private(set) var status: EventsSessionStatus?
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var transportGeneration: UInt64 = 0
    /// The server on the Host's socket, while one answers.
    private(set) var server: RexServerStatus?
    /// The instance whose terminals a detail keeps to: the last that answered,
    /// kept through a reconnect until another one answers.
    private(set) var inventoryCore: String?
    /// Until the server that answered has listed its terminals, nothing says
    /// what the Host runs.
    private(set) var isAwaitingSnapshot = true
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    /// The Agents as last listed, for a detail open on one while the Host
    /// recovers. Another instance's are not these.
    private(set) var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    private(set) var sidebarRevision: UInt64 = 0
    /// The last inventory folded into rows.
    private(set) var inventory: RexInventory?

    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let terminalLabelKeys: [String] = []

    /// What this device keeps of the Host by server instance, and its Pins.
    private let memory: HerdrCoreHostMemory
    private let pins: PinnedAgentsStore
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var hasEnded = false
    /// The Panes this device shows now, whose finished turns are seen as
    /// they are noted.
    private var shownAgents: Set<String> = []

    init(
        host: Host, session: RexHostSession, memory: HerdrCoreHostMemory = HerdrCoreHostMemory(),
        pins: PinnedAgentsStore, onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.onChange = onChange
    }

    // MARK: Lifecycle

    func start(isActive: Bool) {
        consumeTask = Task { [weak self, session] in
            for await update in session.updates {
                guard !Task.isCancelled, let self else { return }
                self.handle(update)
            }
        }
        // Only the wake-up: `session.currentLatency` is the value ordered
        // against the statuses, as `HostConsoleProjection` reads it.
        latencyTask = Task { [weak self, session] in
            for await _ in session.latencyUpdates {
                guard !Task.isCancelled, let self else { return }
                self.latency = session.currentLatency
                self.onChange()
            }
        }
        if isActive {
            Task { await session.resume() }
        }
    }

    func resume() async {
        await session.resume()
    }

    /// One attempt on a stopped session, else a question to the server that
    /// was answering, as a Herdr TUI Host is re-proved on a foreground return.
    func revalidate() async {
        if case .failed = status {
            beginNewActivation()
            await session.retry()
        } else {
            await session.revalidate()
        }
    }

    func suspend() async {
        await session.suspend()
    }

    func retry() async {
        beginNewActivation()
        await session.retry()
    }

    func cancelConnecting() async {
        await session.cancelConnecting()
    }

    /// Leaves for good: the session closes its control link with a close
    /// frame, so the server forgets this client at once.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        consumeTask?.cancel()
        latencyTask?.cancel()
        consumeTask = nil
        latencyTask = nil
        Task { [session] in await session.end() }
    }

    /// The catalog's Host changed. A socket noted where the record had none is
    /// what a connection looked up, here or on the Server page: it is taken as
    /// it is, and the connection stays, since the session keeps the socket it
    /// found and looks one up on each dial (ADR 0049). Anything else, another
    /// socket included, is another Host.
    func adoptSocket(of catalogHost: Host) {
        guard host.rexSocket == nil, catalogHost.rexSocket != nil else { return }
        var noted = host
        noted.rexSocket = catalogHost.rexSocket
        guard noted == catalogHost else { return }
        host = catalogHost
    }

    private func beginNewActivation() {
        status = .connecting
        latency = nil
        routeID = nil
        server = nil
        invalidateInventory()
        onChange()
    }

    private func handle(_ update: RexHostSessionUpdate) {
        guard !hasEnded else { return }
        switch update {
        case .status(let status):
            self.status = status
            latency = session.currentLatency
            routeID = session.currentRouteID
            transportGeneration = session.currentConnectionGeneration
            switch status {
            case .failed(let failure):
                standingFailure = failure
            case .connected, .reconnecting:
                standingFailure = nil
            case .connecting, .suspended, .ended:
                break
            }
            if status != .connected {
                server = nil
                invalidateInventory()
            }
        case .server(let server):
            // What was listed came from the server that answered before, and
            // its Pane ids may repeat under this one.
            if inventoryCore != server.instanceID {
                invalidateInventory()
                if inventoryCore != nil {
                    pins.removePins(hostID: host.id)
                    lastKnownAgentsByPane = [:]
                    shownAgents = []
                }
            }
            self.server = server
            inventoryCore = server.instanceID
            // Turns and seen marks this device kept of another instance, in
            // this run or an earlier one, go with it.
            memory.noteCore(server.instanceID, for: host.id)
        case .inventory(let inventory):
            guard status == .connected, server != nil else { return }
            self.inventory = inventory
            noteTurns(in: inventory)
            rebuildRows()
        }
        onChange()
    }

    // MARK: Inventory

    /// A Pane belongs to its server: a detail open on another instance's
    /// terminal has left the inventory.
    var keepsDetailsToInventory: Bool { true }

    var leftInventoryMessage: String { TerminalStatusPresentation.rexServerGoneMessage }

    var leftInventoryError: TransportError { .rexServerGone }

    private func invalidateInventory() {
        isAwaitingSnapshot = true
        inventory = nil
        workspaces = []
        terminalsByPane = [:]
        agentsByPane = [:]
    }

    /// Each inventory is the server's whole list, so Pins on Panes it no
    /// longer lists go.
    private func rebuildRows() {
        guard let inventory else { return }
        let builder = ConsolePaneRowBuilder(
            host: host, inventory: RexOrganization.build(inventory, doneTerminals: doneTerminals))
        let agents = builder.agentRows(liveChange: { _ in nil })
        terminalsByPane = builder.terminalRows(agents: agents, liveChange: { _ in nil })
        agentsByPane = agents
        lastKnownAgentsByPane = agents
        pins.retainPins(hostID: host.id, paneIDs: Set(terminalsByPane.keys))
        workspaces = builder.workspaceRows()
        isAwaitingSnapshot = false
        sidebarRevision &+= 1
    }

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}

    // MARK: Done per device

    /// Each listed terminal's record, folded into this device's turns, and
    /// the turns of terminals the server no longer lists forgotten. A record
    /// this link has yet to read, or one removed, changes nothing; one that is
    /// not its Agent's, or a terminal with no Agent, ends a finished turn's
    /// Done. A terminal never known to host an Agent costs nothing.
    private func noteTurns(in inventory: RexInventory) {
        let known = memory.rexTurnStates(for: host.id)
        var listed: Set<String> = []
        for session in inventory.sessions {
            for terminal in session.terminals {
                let paneID = RexPaneAddress(sessionID: session.id, blockID: terminal.blockID).paneID
                listed.insert(paneID)
                let details = terminal.details
                let kind = RexAgentRule.agentKind(in: details)
                if let kind, let report = RexAgentRule.report(of: details, heldBy: kind) {
                    let isShown = shownAgents.contains(paneID)
                    memory.updateRexTurnState(of: paneID, for: host.id) { state in
                        state.note(report, kind: kind)
                        if isShown { state.markSeen() }
                    }
                } else if kind == nil || details.status != nil, known[paneID] != nil {
                    memory.updateRexTurnState(of: paneID, for: host.id) { $0.noteNoAgent() }
                }
            }
        }
        memory.retainRexPanes(listed, for: host.id)
    }

    private var doneTerminals: Set<String> {
        Set(memory.rexTurnStates(for: host.id).filter(\.value.isDone).keys)
    }

    /// Marks each newly shown Agent's finished turn seen. A turn that ends
    /// while one stays shown is seen as it is noted, so it never reads Done.
    func setShownAgents(_ paneIDs: Set<String>) {
        let opened = paneIDs.subtracting(shownAgents)
        shownAgents = paneIDs
        let known = memory.rexTurnStates(for: host.id)
        let opening = opened.filter { known[$0] != nil }
        guard !opening.isEmpty else { return }
        let wasDone = doneTerminals
        for paneID in opening {
            memory.updateRexTurnState(of: paneID, for: host.id) { $0.markSeen() }
        }
        guard doneTerminals != wasDone, inventory != nil else { return }
        rebuildRows()
        onChange()
    }

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Actions

    /// Nothing is started, closed or renamed on a Rex Host (ADR 0049).
    private nonisolated static var unavailable: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "This action on a Rex Host"))
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] { throw Self.unavailable }
    func startAgent(_: AgentLaunchRequest) async throws -> Agent { throw Self.unavailable }
    func startAgentInNewWorktree(_: AgentLaunchRequest, worktree _: WorktreeSpec) async throws -> Agent {
        throw Self.unavailable
    }
    func startAgentInNewWorkspace(_: AgentLaunchRequest, workspace _: NewWorkspaceSpec) async throws -> Agent {
        throw Self.unavailable
    }
    func createShellTerminal(_: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        throw Self.unavailable
    }
    func createShellWorkspace(_: NewWorkspaceSpec, tabLabel _: String?) async throws -> ShellTerminalIdentity {
        throw Self.unavailable
    }
    func closePane(_: String) async throws { throw Self.unavailable }
    func closeTab(_: String) async throws { throw Self.unavailable }
    func listWorktrees(forWorkspaceID _: String) async throws -> WorktreeListResponse { throw Self.unavailable }
    func removeWorktree(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt { throw Self.unavailable }
    func worktreeRemovalRisk(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        throw Self.unavailable
    }
    func focusAgent(_: String) async throws { throw Self.unavailable }
    func renameAgent(_: String, name _: String?) async throws { throw Self.unavailable }
    func renameWorkspace(_: String, label _: String) async throws { throw Self.unavailable }

    // MARK: One Agent

    func agentInfo(paneID _: String) async throws -> Agent { throw Self.unavailable }
    func processInfo(paneID _: String) async throws -> PaneProcessInfo { throw Self.unavailable }
    func promptAgent(_: AgentPromptParams) async throws -> Agent { throw Self.unavailable }
    func readAgentScreen(_: String) async throws -> ANSIScreen { throw Self.unavailable }
    func sendAgentKeys(_: [String], to _: String) async throws { throw Self.unavailable }
    func pasteIntoAgent(_: String, paneID _: String) async throws { throw Self.unavailable }

    // MARK: The live connection

    /// Opens a Rex terminal (ADRs 0051 and 0052): its session is attached,
    /// its block's stream paints the view and follows its output, and the
    /// view's grid is asked for, and the view's input goes out from the first
    /// paint. A block that closed, a program that exited and another server
    /// end the terminal; a connection that went or was replaced reattaches,
    /// and the next attach paints afresh. Input that may have reached the
    /// program unanswered ends it as a failed input write.
    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            guard let address = RexPaneAddress(paneID: request.target.identifier) else {
                throw TerminalProgramEnd.finished
            }
            do {
                try await session.withTerminal(address) { connection in
                    guard await handler.admitsCore(connection.server.instanceID) else {
                        throw TerminalProgramEnd.finished
                    }
                    await handler.transportDidBecomeReady(connection.generation)
                    try await connection.attachSession()
                    let terminal = await RexTerminalAttach.session(
                        on: connection, columns: request.cols, rows: request.rows)
                    try await handler.runEndingSession(terminal)
                }
            } catch let ending as RexTerminalEnding {
                switch ending {
                case .finished, .serverGone: throw TerminalProgramEnd.finished
                case .connectionReset: throw TransportError.cancelled
                case .outputUnavailable: throw TransportError.rexTerminalOutputUnavailable
                case .historyTooLong: throw TransportError.rexTerminalHistoryTooLong
                case .inputFailed:
                    // As the other Server Kinds say an input write failed.
                    throw TransportError.channelFailed(detail: String(localized: "attach input failed"))
                }
            }
        }
    }
    func imageStager(beside _: String, keepingTo _: TerminalCorePin) -> ImageStager {
        { _, _ in throw Self.unavailable }
    }
    func fileStager(beside _: String, keepingTo _: TerminalCorePin) -> FileStager {
        { _, _ in throw Self.unavailable }
    }
    func sessionFileReader() -> SessionFileReader { { _ in throw Self.unavailable } }
    func modelContextWindowResolver() -> ModelContextWindowResolver { { _ in throw Self.unavailable } }
    func chatHostFiles() -> ChatHostFiles {
        ChatHostFiles(
            status: { _ in throw Self.unavailable },
            list: { _ in throw Self.unavailable },
            read: { _ in throw Self.unavailable },
            home: { throw Self.unavailable })
    }
    func remoteHomeDirectory() async throws -> String { throw Self.unavailable }
    func listRemoteDirectories(at _: String) async throws -> RemoteDirectoryListing { throw Self.unavailable }

    /// A Rex Host is reached through its server's socket only: nothing runs on
    /// it over SSH.
    func withHostServices<Value: Sendable>(
        _: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        throw Self.unavailable
    }

    /// A Rex Host has no plugin, Notifications or Usage files, and its plugin
    /// surfaces say it is the Server Kind's doing.
    func withNotificationTransport<Value: Sendable>(
        _: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.rex
    }
}
