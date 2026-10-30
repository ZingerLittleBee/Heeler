import Foundation

/// A herdr-core Host's share of the Console (ADR 0032). It folds the Host
/// session's subscribe snapshots and deltas into the Console's models: a snapshot
/// or `missed` replaces the inventory wholesale, and deltas change one Terminal
/// in place without asking the core again.
///
/// Actions a core Host does not offer yet are hidden by `HostCapabilities`. The
/// ones here that throw are for callers that went around it.
@MainActor
final class HerdrCoreConsoleProjection: ConsoleHostProjection {
    let host: Host
    let session: HerdrCoreHostSession

    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var status: EventsSessionStatus?
    /// See Standing Failure in `CONTEXT.md`.
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var transportGeneration: UInt64 = 0
    private(set) var sidebarRevision: UInt64 = 0
    /// `.connected` precedes the subscribe snapshot, so an empty projection in
    /// this window means "unknown", not "no Terminals".
    private(set) var isAwaitingSnapshot = true

    let syncError: String? = nil
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let agentsByPane: [String: ConsoleAgent] = [:]

    private let memory: HerdrCoreHostMemory
    private let onChange: @MainActor @Sendable () -> Void
    private var records: [HerdrCoreTerminalRecord] = []
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var hasEnded = false

    init(
        host: Host,
        session: HerdrCoreHostSession,
        memory: HerdrCoreHostMemory,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
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
                self.publish()
            }
        }
        if isActive {
            Task { await session.resume() }
        }
    }

    func resume() async {
        await session.resume()
    }

    /// One attempt on a stopped session, else a question to the live link, as
    /// a Herdr TUI Host is re-proved on a foreground return.
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

    private func beginNewActivation() {
        status = .connecting
        latency = nil
        routeID = nil
        invalidateInventory()
        publish()
    }

    // MARK: Folding the session's updates

    private func handle(_ update: HerdrCoreHostSessionUpdate) {
        guard !hasEnded else { return }
        switch update {
        case .status(let status):
            self.status = status
            latency = session.currentLatency
            routeID = session.currentRouteID
            switch status {
            case .failed(let failure):
                standingFailure = failure
            case .connected, .reconnecting:
                standingFailure = nil
            case .connecting, .suspended, .ended:
                break
            }
            if status != .connected { invalidateInventory() }
            publish()
        case .snapshot(let snapshot, let coreID):
            memory.noteCore(coreID, for: host.id)
            replaceInventory(with: snapshot)
        case .event(let event):
            apply(event)
        }
    }

    private func invalidateInventory() {
        isAwaitingSnapshot = true
        records = []
        terminalsByPane = [:]
        workspaces = []
    }

    private func replaceInventory(with snapshot: HerdrCoreSnapshot) {
        memory.noteInventory(snapshot.terminals, for: host.id)
        records = snapshot.terminals
        isAwaitingSnapshot = false
        transportGeneration = max(transportGeneration, session.currentConnectionGeneration)
        sidebarRevision &+= 1
        rebuildRows()
        publish()
    }

    private func apply(_ event: HerdrCoreEvent) {
        switch event {
        case .created(let record), .restarted(let record):
            memory.noteTerminal(record, for: host.id)
            if let index = records.firstIndex(where: { $0.address == record.address }) {
                records[index] = record
            } else {
                records.append(record)
            }
            sidebarRevision &+= 1
        case .size(let terminal, let columns, let rows):
            update(terminal) {
                $0.columns = columns
                $0.rows = rows
            }
        case .title(let terminal, let title):
            update(terminal) { $0.title = title }
        case .foreground(let terminal, let foreground):
            update(terminal) { $0.foreground = foreground }
        case .labels(let terminal, let labels):
            update(terminal) { $0.labels = labels }
        case .keep(let terminal, let keep):
            update(terminal) { $0.keep = keep }
        case .lost(let terminal, let end):
            update(terminal) {
                $0.pid = nil
                $0.foreground = nil
                $0.reason = end.reason ?? "lost"
            }
        case .finished(let terminal, _):
            update(terminal) {
                $0.state = "finished"
                $0.pid = nil
                $0.foreground = nil
            }
            sidebarRevision &+= 1
        case .removed(let terminal):
            memory.forgetTerminal(terminal, for: host.id)
            records.removeAll { $0.address == terminal }
            sidebarRevision &+= 1
        case .missed(let snapshot):
            replaceInventory(with: snapshot)
            return
        case .dropped, .unknown:
            // These deltas can no longer be trusted: start over from a snapshot.
            Task { [session] in await session.resubscribe() }
            return
        case .status, .turn, .document, .heartbeat:
            return
        }
        rebuildRows()
        publish()
    }

    private func update(_ address: String, _ change: (inout HerdrCoreTerminalRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.address == address }) else { return }
        change(&records[index])
    }

    private func rebuildRows() {
        let builder = ConsolePaneRowBuilder(
            host: host,
            inventory: HerdrCoreOrganization.snapshot(
                terminals: records,
                firstSeenDirectories: memory.firstSeenDirectories(for: host.id)))
        var rows = builder.terminalRows(agents: [:], liveChange: { _ in nil })
        for record in records where rows[record.address] != nil {
            rows[record.address]?.isRestarting = record.isRestarting
            rows[record.address]?.gridColumns = record.columns
            rows[record.address]?.gridRows = record.rows
        }
        terminalsByPane = rows
        workspaces = builder.workspaceRows()
    }

    private func publish() {
        onChange()
    }

    // MARK: Inventory

    /// The snapshot and its deltas are the inventory: nothing to ask for.
    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Actions not built yet

    private func unavailable(_ feature: String) -> TransportError {
        .hostFeatureUnavailable(feature: "\(feature) on a herdr-core Host")
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        throw unavailable("Starting Agents")
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        throw unavailable("Starting Agents")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        throw unavailable("Worktrees")
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        throw unavailable("Starting Agents")
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        throw unavailable("New Terminal")
    }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity {
        throw unavailable("New Terminal")
    }

    func closePane(_ paneID: String) async throws {
        throw unavailable("Closing a Terminal")
    }

    func closeTab(_ tabID: String) async throws {
        throw unavailable("Close Tab")
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        throw unavailable("Worktrees")
    }

    func removeWorktree(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt {
        throw unavailable("Worktrees")
    }

    func focusAgent(_ paneID: String) async throws {
        throw unavailable("Agents")
    }

    func renameAgent(_ paneID: String, name: String?) async throws {
        throw unavailable("Rename Agent")
    }

    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        throw unavailable("Rename Workspace")
    }

    func agentInfo(paneID: String) async throws -> Agent {
        throw unavailable("Agents")
    }

    func processInfo(paneID: String) async throws -> PaneProcessInfo {
        throw unavailable("Agents")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw unavailable("The Composer")
    }

    func readAgentScreen(_ paneID: String) async throws -> ANSIScreen {
        throw unavailable("Agents")
    }

    func sendAgentKeys(_ keys: [String], to paneID: String) async throws {
        throw unavailable("Agents")
    }

    func pasteIntoAgent(_ text: String, paneID: String) async throws {
        throw unavailable("Agents")
    }

    func terminalRunner() -> TerminalSessionRunner {
        let failure = unavailable("Opening a Terminal")
        return { _, _ in throw failure }
    }

    func imageStager() -> ImageStager {
        let failure = unavailable("Uploads")
        return { _, _ in throw failure }
    }

    func fileStager() -> FileStager {
        let failure = unavailable("Uploads")
        return { _, _ in throw failure }
    }

    func sessionFileReader() -> SessionFileReader {
        let session = session
        return { range in
            try await session.withTransport { $0.hostServices }.readFileSlice(range)
        }
    }

    func modelContextWindowResolver() -> ModelContextWindowResolver {
        { _ in nil }
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
            },
            queryOpenCode: nil)
    }

    func remoteHomeDirectory() async throws -> String {
        try await session.withTransport { $0.hostServices }.hostHomeDirectory()
    }

    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing {
        throw unavailable("New Workspace")
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
        throw HeelerPluginUnavailableError.herdrCore
    }
}
