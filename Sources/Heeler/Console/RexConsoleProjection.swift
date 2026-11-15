import Foundation

/// A Rex Host's share of the Console (ADRs 0047 and 0048): its connection, the
/// server that answers on its socket, and the terminals that server lists. A
/// session is a Workspace, a window a Tab and a terminal block a Pane, as
/// `RexOrganization` reads them, and a Rex Host lists Terminals only.
///
/// A Pane keeps to its server instance, as a tmux Pane does: another instance
/// leaves every detail open on the last one's terminals. A terminal opens
/// from the server's redraw (ADR 0049) and takes input from its first paint
/// (ADR 0050); every action a Host offers is unavailable on a Rex Host.
@MainActor
final class RexConsoleProjection: ConsoleHostProjection {
    let host: Host
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
    private(set) var sidebarRevision: UInt64 = 0
    /// The last inventory folded into rows.
    private(set) var inventory: RexInventory?

    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let agentsByPane: [String: ConsoleAgent] = [:]
    let lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    let terminalLabelKeys: [String] = []

    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var hasEnded = false

    init(host: Host, session: RexHostSession, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.host = host
        self.session = session
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
            // What was listed came from the server that answered before.
            if inventoryCore != server.instanceID { invalidateInventory() }
            self.server = server
            inventoryCore = server.instanceID
        case .inventory(let inventory):
            guard status == .connected, server != nil else { return }
            self.inventory = inventory
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
    }

    private func rebuildRows() {
        guard let inventory else { return }
        let builder = ConsolePaneRowBuilder(host: host, inventory: RexOrganization.build(inventory))
        terminalsByPane = builder.terminalRows(agents: [:], liveChange: { _ in nil })
        workspaces = builder.workspaceRows()
        isAwaitingSnapshot = false
        sidebarRevision &+= 1
    }

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}
    func setShownAgents(_: Set<String>) {}

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Actions

    /// Nothing is started, closed or renamed on a Rex Host (ADR 0047).
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

    /// Opens a Rex terminal (ADRs 0049 and 0050): its session is attached,
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
