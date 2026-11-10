import Foundation

/// A tmux Host's share of the Console (ADR 0042): its connection, and the
/// server that answers on its socket. It lists no inventory yet, so nothing
/// on it can be opened, started or closed, and `HostCapabilities` offers none
/// of it.
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
    /// Until a server answered, nothing says what the Host runs.
    var isAwaitingSnapshot: Bool { server == nil }

    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    let workspaces: [ConsoleWorkspace] = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let terminalsByPane: [String: ConsoleTerminal] = [:]
    let agentsByPane: [String: ConsoleAgent] = [:]
    let lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    let sidebarRevision: UInt64 = 0
    let terminalLabelKeys: [String] = []

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
        onPathsResolved: @escaping @MainActor (TmuxPaths) -> Void,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
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
            if status != .connected { server = nil }
        case .server(let server):
            self.server = server
        case .paths(let paths):
            guard paths != host.tmuxPaths, paths.serves(socketName: host.tmuxSocketName) else { return }
            host.tmuxPaths = paths
            onPathsResolved(paths)
        }
        onChange()
    }

    // MARK: Inventory

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}
    func setShownAgents(_ paneIDs: Set<String>) {}

    func paneExists(_ paneID: String) async throws -> Bool { false }

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
