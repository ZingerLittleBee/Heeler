import Foundation

/// A tmux Host's share of the Console (ADRs 0042 and 0043): its connection,
/// the server that answers on its socket, and what that server lists. A
/// session is a Workspace, a window a Tab and a pane a Pane, as
/// `TmuxOrganization` reads them.
///
/// A Pane is its server instance and its pane id: tmux counts pane ids from
/// zero again each time it starts. The instance is kept where a herdr-core
/// Host keeps its core id, so another instance drops what this device held of
/// the last one's Panes, and a detail open on one of them keeps to it through
/// the same pin.
///
/// Nothing on it can be opened, started or closed yet, and `HostCapabilities`
/// offers none of it.
@MainActor
final class TmuxConsoleProjection: ConsoleHostProjection {
    /// The catalog's Host, with the paths a connection last resolved.
    private(set) var host: Host
    let session: TmuxHostSession

    private(set) var status: EventsSessionStatus?
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var transportGeneration: UInt64 = 0
    /// The server on the Host's socket, while one answers. Another instance is
    /// another server, whose Panes only share ids with the last one's.
    private(set) var server: TmuxServerStatus?
    /// Until the server that answered has listed its panes, nothing says what
    /// the Host runs.
    private(set) var isAwaitingSnapshot = true

    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    private(set) var workspaces: [ConsoleWorkspace] = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    private(set) var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    private(set) var sidebarRevision: UInt64 = 0
    let terminalLabelKeys: [String] = []

    /// What this device keeps of the Host by server instance, and its Pins.
    private let memory: HerdrCoreHostMemory
    private let pins: PinnedAgentsStore
    private let onPathsResolved: @MainActor (TmuxPaths) -> Void
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var hasEnded = false

    /// `onPathsResolved` hears the paths a connection resolved again, after
    /// `host` already carries them.
    init(
        host: Host,
        session: TmuxHostSession,
        memory: HerdrCoreHostMemory,
        pins: PinnedAgentsStore,
        onPathsResolved: @escaping @MainActor (TmuxPaths) -> Void,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.onPathsResolved = onPathsResolved
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

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        consumeTask?.cancel()
        latencyTask?.cancel()
        consumeTask = nil
        latencyTask = nil
        Task { [session] in await session.end() }
    }

    /// The catalog's Host changed. Paths that moved alone are what a
    /// connection resolved, here or in Host detail: they are taken as they
    /// are, and the connection stays. Anything else is another Host.
    func adoptPaths(of catalogHost: Host) {
        guard catalogHost.tmuxPaths != host.tmuxPaths else { return }
        var moved = host
        moved.tmuxPaths = catalogHost.tmuxPaths
        guard moved == catalogHost else { return }
        host = catalogHost
        session.adoptStoredPaths(catalogHost.storedTmuxPaths)
    }

    private func beginNewActivation() {
        status = .connecting
        latency = nil
        routeID = nil
        server = nil
        invalidateInventory()
        onChange()
    }

    private func handle(_ update: TmuxHostSessionUpdate) {
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
            if self.server?.instance != server.instance { invalidateInventory() }
            self.server = server
            noteInstance(server.instance)
        case .paths(let paths):
            guard paths != host.tmuxPaths, paths.serves(socketName: host.tmuxSocketName) else { return }
            host.tmuxPaths = paths
            onPathsResolved(paths)
        case .inventory(let inventory):
            guard status == .connected, server != nil else { return }
            replaceInventory(with: inventory)
        }
        onChange()
    }

    // MARK: Inventory

    /// The server instance this inventory's pane ids mean, where a herdr-core
    /// Host has the core its addresses mean.
    var inventoryCore: String? {
        memory.coreID(for: host.id)
    }

    /// Another instance is another server, whose pane ids only repeat the last
    /// one's: the Pins on those go, with whatever else this device kept of
    /// them. Pins go first, so a crash in between still finds another instance
    /// next time.
    private func noteInstance(_ instance: TmuxServerInstance) {
        if let known = memory.coreID(for: host.id), known != instance.id {
            pins.removePins(hostID: host.id)
            lastKnownAgentsByPane = [:]
        }
        memory.noteCore(instance.id, for: host.id)
    }

    private func invalidateInventory() {
        isAwaitingSnapshot = true
        workspaces = []
        terminalsByPane = [:]
        agentsByPane = [:]
    }

    /// Each snapshot is the whole inventory, so nothing is carried over. Its
    /// rows name their server, which the loop asked later than `server` did.
    private func replaceInventory(with inventory: TmuxInventory) {
        if let instance = inventory.instance { noteInstance(instance) }
        pins.retainPins(hostID: host.id, paneIDs: Set(inventory.panes.map(\.paneID)))
        let organization = TmuxOrganization.build(inventory)
        let builder = ConsolePaneRowBuilder(host: host, inventory: organization.snapshot)
        let agents = builder.agentRows(lastOutputSnippet: { _ in nil }, liveChange: { _ in nil })
        var rows = builder.terminalRows(agents: agents, liveChange: { _ in nil })
        for pane in organization.panes {
            rows[pane.paneID]?.gridColumns = pane.width
            rows[pane.paneID]?.gridRows = pane.height
        }
        terminalsByPane = rows
        agentsByPane = agents
        lastKnownAgentsByPane = agents
        workspaces = builder.workspaceRows()
        isAwaitingSnapshot = false
        sidebarRevision &+= 1
    }

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}
    func setShownAgents(_ paneIDs: Set<String>) {}

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: What a tmux Host does not do yet

    private var unavailable: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "This action on a tmux Host"))
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] { [] }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent { throw unavailable }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent { throw unavailable }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent { throw unavailable }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity { throw unavailable }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity { throw unavailable }

    func closePane(_ paneID: String) async throws { throw unavailable }
    func closeTab(_ tabID: String) async throws { throw unavailable }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        throw unavailable
    }

    func removeWorktree(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt {
        throw unavailable
    }

    func worktreeRemovalRisk(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        throw unavailable
    }

    func focusAgent(_ paneID: String) async throws {}
    func renameAgent(_ paneID: String, name: String?) async throws { throw unavailable }
    func renameWorkspace(_ workspaceID: String, label: String) async throws { throw unavailable }

    func agentInfo(paneID: String) async throws -> Agent { throw unavailable }
    func processInfo(paneID: String) async throws -> PaneProcessInfo { throw unavailable }
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent { throw unavailable }
    func readAgentScreen(_ paneID: String) async throws -> ANSIScreen { throw unavailable }
    func sendAgentKeys(_ keys: [String], to paneID: String) async throws { throw unavailable }
    func pasteIntoAgent(_ text: String, paneID: String) async throws { throw unavailable }

    func terminalRunner() -> TerminalSessionRunner {
        let unavailable = unavailable
        return { _, _ in throw unavailable }
    }

    func imageStager(beside paneID: String, keepingTo corePin: TerminalCorePin) -> ImageStager {
        let unavailable = unavailable
        return { _, _ in throw unavailable }
    }

    func fileStager(beside paneID: String, keepingTo corePin: TerminalCorePin) -> FileStager {
        let unavailable = unavailable
        return { _, _ in throw unavailable }
    }

    func modelContextWindowResolver() -> ModelContextWindowResolver {
        { _ in nil }
    }

    // MARK: The Host's files, on the same SSH connection

    func sessionFileReader() -> SessionFileReader {
        let session = session
        return { range in
            try await session.withTransport { $0.hostServices }.readFileSlice(range)
        }
    }

    func chatHostFiles() -> ChatHostFiles {
        let session = session
        return ChatHostFiles(
            status: { path in
                try await session.withTransport { $0.hostServices }.fileStatus(atPath: path)
            },
            list: { request in
                try await session.withTransport { $0.hostServices }.listFiles(request)
            },
            read: { range in
                try await session.withTransport { $0.hostServices }.readHostFileRange(range)
            },
            home: {
                try await session.withTransport { $0.hostServices }.hostHomeDirectory()
            })
    }

    func remoteHomeDirectory() async throws -> String {
        try await session.withTransport { $0.hostServices }.hostHomeDirectory()
    }

    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing {
        try await session.withTransport { $0.hostServices }.listDirectories(at: path)
    }

    func withHostServices<Value: Sendable>(
        _ operation: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        try await operation(try await session.withTransport { $0.hostServices })
    }

    /// The plugin's files belong to Herdr TUI Hosts, and its surfaces say so.
    func withNotificationTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.tmux
    }
}
