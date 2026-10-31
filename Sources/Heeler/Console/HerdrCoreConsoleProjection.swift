import Foundation

/// A herdr-core Host's share of the Console (ADR 0032). It folds the Host
/// session's subscribe snapshots and deltas into the Console's models: a snapshot
/// or `missed` replaces the inventory wholesale, and deltas change one Terminal
/// in place without asking the core again. It reads the desktop app's document on
/// each snapshot and on each `doc` event, and never writes it, and it asks for
/// the checkout root of a directory that names an unnamed space once.
///
/// Actions a core Host does not offer yet are hidden by `HostCapabilities`. The
/// ones here that throw are for callers that went around it.
@MainActor
final class HerdrCoreConsoleProjection: ConsoleHostProjection {
    let host: Host
    let session: HerdrCoreHostSession

    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var status: EventsSessionStatus?
    /// See Standing Failure in `CONTEXT.md`.
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var leakedEnvironmentNames: Set<String> = []
    /// Why each Agent reading Unknown does, by Terminal address.
    private(set) var statusExplanations: [String: HerdrCoreStatusExplanation] = [:]
    private(set) var transportGeneration: UInt64 = 0
    private(set) var sidebarRevision: UInt64 = 0
    /// `.connected` precedes the subscribe snapshot, so an empty projection in
    /// this window means "unknown", not "no Terminals".
    private(set) var isAwaitingSnapshot = true

    let syncError: String? = nil
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    var terminalLabelKeys: [String] {
        Set(records.flatMap(\.labels.keys)).sorted()
    }

    private let memory: HerdrCoreHostMemory
    private let pins: PinnedAgentsStore
    private let onChange: @MainActor @Sendable () -> Void
    private var records: [HerdrCoreTerminalRecord] = []
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var environmentTask: Task<Void, Never>?
    private var hasEnded = false

    private let gitGate: GitExecGate
    private var document: HerdrCoreDesktopDocument?
    private var documentVersion: Int?
    private var documentRead: Task<Void, Never>?
    private var readsDocumentAgain = false
    /// A directory's checkout root, itself when it is in no checkout.
    private var checkouts: [String: String] = [:]
    private var askedCheckouts: Set<String> = []
    private var queuedCheckouts: [String] = []
    private var checkoutTask: Task<Void, Never>?
    private var home: String?
    private var hasAskedHome = false

    init(
        host: Host,
        session: HerdrCoreHostSession,
        memory: HerdrCoreHostMemory,
        pins: PinnedAgentsStore,
        gitGate: GitExecGate,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.gitGate = gitGate
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
        environmentTask = Task { [weak self, session] in
            for await _ in session.leakedEnvironmentUpdates {
                guard !Task.isCancelled, let self else { return }
                self.leakedEnvironmentNames = session.currentLeakedEnvironment
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
        documentRead?.cancel()
        checkoutTask?.cancel()
        environmentTask?.cancel()
        consumeTask = nil
        latencyTask = nil
        environmentTask = nil
        Task { [session] in await session.end() }
    }

    private func beginNewActivation() {
        status = .connecting
        latency = nil
        routeID = nil
        leakedEnvironmentNames = []
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
            leakedEnvironmentNames = session.currentLeakedEnvironment
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
            // Pins go first: a crash in between still finds another core next time.
            if let known = memory.coreID(for: host.id), known != coreID {
                pins.removePins(hostID: host.id)
            }
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
        agentsByPane = [:]
        workspaces = []
        documentRead?.cancel()
        documentRead = nil
        readsDocumentAgain = false
        // What this link did not answer gets one more ask on the next.
        checkoutTask?.cancel()
        checkoutTask = nil
        queuedCheckouts = []
        askedCheckouts = Set(checkouts.keys)
        hasAskedHome = home != nil
    }

    private func replaceInventory(with snapshot: HerdrCoreSnapshot) {
        memory.noteInventory(snapshot.terminals, for: host.id)
        pins.retainPins(hostID: host.id, paneIDs: Set(snapshot.terminals.map(\.address)))
        records = snapshot.terminals
        transportGeneration = max(transportGeneration, session.currentConnectionGeneration)
        sidebarRevision &+= 1
        readDocument()
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
            update(terminal) { $0.noteForeground(foreground) }
        case .status(let terminal, let status, let records, let reported):
            update(terminal) {
                $0.status = status
                $0.records = records
                $0.reported = reported
            }
        case .turn(let terminal, let turn, _):
            update(terminal) { $0.turn = turn }
        case .labels(let terminal, let labels):
            update(terminal) { $0.labels = labels }
            sidebarRevision &+= 1
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
            pins.removePin(hostID: host.id, paneID: terminal)
            records.removeAll { $0.address == terminal }
            sidebarRevision &+= 1
        case .missed(let snapshot):
            replaceInventory(with: snapshot)
            return
        case .dropped, .unknown:
            // These deltas can no longer be trusted: start over from a snapshot.
            Task { [session] in await session.resubscribe() }
            return
        case .document(let name, let version, let machine):
            // A read can already be newer than the event that follows it.
            if name == HerdrCoreDesktopDocument.name, machine == nil,
                version > documentVersion ?? -1
            {
                readDocument()
            }
            return
        case .heartbeat:
            return
        }
        rebuildRows()
        publish()
    }

    private func update(_ address: String, _ change: (inout HerdrCoreTerminalRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.address == address }) else { return }
        change(&records[index])
    }

    /// Nothing shows until a link's first document read has settled, so a
    /// desktop Terminal never flashes through a Workspace it does not belong in.
    /// A read nobody answers settles at the link's call deadline.
    private func rebuildRows() {
        guard !isAwaitingSnapshot else { return }
        let organization = HerdrCoreOrganization.build(
            terminals: records, document: document,
            firstSeenDirectories: memory.firstSeenDirectories(for: host.id),
            checkouts: checkouts, home: home)
        let builder = ConsolePaneRowBuilder(host: host, inventory: organization.snapshot)
        // Every value comes from the rebuilt records: nothing is carried over.
        let agents = builder.agentRows(lastOutputSnippet: { _ in nil }, liveChange: { _ in nil })
        var rows = builder.terminalRows(agents: agents, liveChange: { _ in nil })
        for record in records where rows[record.address] != nil {
            rows[record.address]?.isRestarting = record.isRestarting
            rows[record.address]?.gridColumns = record.columns
            rows[record.address]?.gridRows = record.rows
        }
        terminalsByPane = rows
        agentsByPane = agents
        statusExplanations = Dictionary(
            uniqueKeysWithValues: records.lazy.filter { rows[$0.address]?.isAgent == true }
                .compactMap { record in
                    HerdrCoreStatusExplanation(record: record).map { (record.address, $0) }
                })
        workspaces = builder.workspaceRows()
        askForCheckouts(organization.checkoutDirectories)
    }

    // MARK: The desktop app's document

    /// One read at a time. A change seen meanwhile takes one more, so a burst
    /// of layout writes costs two reads.
    private func readDocument() {
        guard documentRead == nil else {
            readsDocumentAgain = true
            return
        }
        documentRead = Task { [weak self, session] in
            var read: HerdrCoreDesktopDocumentRead?
            if let transport = try? await session.withTransport({ $0 }) {
                read = try? await transport.readDesktopDocument()
            }
            guard !Task.isCancelled else { return }
            self?.finishDocumentRead(read)
        }
    }

    /// A failed read keeps what was known: labels still place the Terminals,
    /// and the next `doc` event or link reads again.
    private func finishDocumentRead(_ read: HerdrCoreDesktopDocumentRead?) {
        documentRead = nil
        guard !hasEnded else { return }
        if let read {
            documentVersion = read.version
            if document != read.document {
                document = read.document
                sidebarRevision &+= 1
            }
        }
        if readsDocumentAgain {
            readsDocumentAgain = false
            readDocument()
            guard isAwaitingSnapshot else { return }
        }
        isAwaitingSnapshot = false
        rebuildRows()
        publish()
    }

    // MARK: Checkout roots

    /// Each directory is asked about once. A failed ask waits for the next link.
    private func askForCheckouts(_ directories: [String]) {
        queuedCheckouts += directories.filter { askedCheckouts.insert($0).inserted }
        guard checkoutTask == nil, !queuedCheckouts.isEmpty else { return }
        checkoutTask = Task { [weak self] in await self?.resolveCheckouts() }
    }

    private func resolveCheckouts() async {
        let session = session
        let services = try? await session.withTransport { $0.hostServices }
        guard !Task.isCancelled else { return }
        guard let services else {
            checkoutTask = nil
            return
        }
        if !hasAskedHome {
            hasAskedHome = true
            home = try? await services.hostHomeDirectory()
            guard !Task.isCancelled else { return }
            // The desktop app does not ask git about the home folder either.
            queuedCheckouts.removeAll { $0 == home }
        }
        while !queuedCheckouts.isEmpty {
            let batch = Array(queuedCheckouts.prefix(GitProbe.checkoutRootsPerCall))
            queuedCheckouts.removeFirst(batch.count)
            let roots = try? await gitGate.run { try await services.checkoutRoots(for: batch) }
            guard !Task.isCancelled else { return }
            if let roots {
                for directory in batch { checkouts[directory] = roots[directory] ?? directory }
            }
            rebuildRows()
            publish()
        }
        checkoutTask = nil
        // A name that only the home folder changed still has to show.
        rebuildRows()
        publish()
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

    /// A core has no focused Agent to report: each attach says whether it is
    /// seen on its own channel.
    func focusAgent(_ paneID: String) async throws {}

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

    /// Every live terminal is a channel on the Host's one link (ADR 0031): no
    /// admission to wait for and no further SSH session.
    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            try await session.withTerminalTransport { transport, generation in
                await handler.transportDidBecomeReady(generation)
                #if DEBUG
                await handler.attachRequestDidStart()
                #endif
                let terminal = try await transport.attachTerminal(request)
                #if DEBUG
                await handler.attachChannelDidOpen()
                #endif
                try await handler.runEndingSession(terminal)
            }
        }
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

    /// One variable of one process on the Host, unavailable with no connection.
    func processVariable(_ name: String, pid: Int) async -> HostProcessReader.Variable {
        guard let transport = try? await session.withTransport({ $0 }) else { return .unavailable }
        return await transport.processVariable(name, pid: pid)
    }

    /// The plugin's files belong to Herdr TUI Hosts, and its surfaces say so.
    func withNotificationTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.herdrCore
    }
}
