import Foundation

/// One Host's Console projection. It owns snapshot-then-delta convergence,
/// subscription changes, retry, snippet coalescing, Host RPC follow-ups and
/// the EventsSession that supplies them. ConsoleStore only aggregates the
/// resulting rows and observable Host state.
@MainActor
final class HostConsoleProjection {
    let host: Host
    let session: EventsSession

    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var status: EventsSessionStatus?
    private(set) var syncError: String?
    private(set) var transportGeneration: UInt64 = 0

    private let snapshotRetryDelay: Duration
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var resyncRetryTask: Task<Void, Never>?
    private var resyncPending = false
    private var statusChangeRevision: UInt64 = 0
    private var latestStatusChanges: [
        String: (revision: UInt64, status: AgentStatus)
    ] = [:]
    private var snippetFetchesInFlight: Set<String> = []
    private var pendingSnippetRefreshes: Set<String> = []
    private var hasEnded = false

    init(
        host: Host,
        session: EventsSession,
        snapshotRetryDelay: Duration,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.snapshotRetryDelay = snapshotRetryDelay
        self.onChange = onChange
    }

    func start(isActive: Bool) {
        consumeTask = Task { [weak self] in
            guard let self else { return }
            for await update in session.updates {
                guard !Task.isCancelled else { return }
                self.handle(update)
            }
        }
        if isActive {
            Task { await session.resume() }
        }
    }

    func resume() async {
        await session.resume()
    }

    func suspend() async {
        await session.suspend()
    }

    func retry() async {
        guard case .failed = status else { return }
        await session.retry()
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        resyncPending = false
        resyncTask?.cancel()
        resyncRetryTask?.cancel()
        consumeTask?.cancel()
        resyncTask = nil
        resyncRetryTask = nil
        consumeTask = nil
        Task { await session.end() }
    }

    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            try await session.withTerminalTransport { transport in
                let terminal = try await transport.attachTerminal(request)
                do {
                    try await handler.run(terminal)
                    await terminal.end()
                } catch {
                    await terminal.end()
                    throw error
                }
            }
        }
    }

    func imageStager() -> ImageStager {
        let session = session
        return { image, reporter in
            try await session.withTransport { transport in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            }
        }
    }

    @discardableResult
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        let agent = try await session.withTransport { transport in
            try await transport.startAgent(request)
        }
        scheduleResync()
        return agent
    }

    @discardableResult
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        let agent = try await session.withTransport { transport in
            try await transport.startAgentInNewWorktree(request, worktree: worktree)
        }
        scheduleResync()
        return agent
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        try await session.withTransport { transport in
            try await transport.availableAgentKinds()
        }
    }

    func closePane(_ paneID: String) async throws {
        try await session.withTransport { transport in
            try await transport.closePane(PaneTarget(paneID: paneID))
        }
        scheduleResync()
    }

    /// Renames a workspace (#98). `workspace.renamed` is already a
    /// membership event, so renames from other clients converge too; the
    /// post-RPC resync just makes our own rename land without waiting on the
    /// event round trip.
    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        try await session.withTransport { transport in
            try await transport.renameWorkspace(
                WorkspaceRenameParams(label: label, workspaceID: workspaceID))
        }
        scheduleResync()
    }

    private func handle(_ update: EventsSessionUpdate) {
        guard !hasEnded else { return }
        switch update {
        case .status(let status):
            self.status = status
            publish()
            if status == .connected {
                Task { [weak self] in
                    guard let self else { return }
                    let generation = await session.transportGeneration
                    guard !hasEnded else { return }
                    // These reads race across quick `.connected` bursts and
                    // can land out of order; generations only grow, so the
                    // newest write must win regardless of arrival order — a
                    // regression here would spuriously replace a healthy
                    // terminal downstream.
                    transportGeneration = max(transportGeneration, generation)
                    publish()
                }
                scheduleResync()
            }
        case .event(let event):
            if event.kind == PaneEventKind.agentStatusChanged.kind {
                applyStatusChange(event.data)
            } else if Self.resyncEventKinds.contains(event.kind) {
                scheduleResync()
            }
        }
    }

    /// Runs one re-snapshot at a time; signals arriving mid-run coalesce into
    /// one follow-up run.
    private func scheduleResync() {
        guard !hasEnded else { return }
        if resyncTask != nil {
            resyncPending = true
            return
        }
        resyncTask = Task { [weak self] in
            guard let self else { return }
            await runResync()
            guard !hasEnded else { return }
            resyncTask = nil
            if resyncPending {
                resyncPending = false
                scheduleResync()
            }
        }
    }

    private func runResync() async {
        let statusRevisionBeforeSnapshot = statusChangeRevision
        do {
            let snapshot = try await session.withTransport { transport in
                try await transport.sessionSnapshot()
            }
            guard !hasEnded else { return }
            resyncRetryTask?.cancel()
            resyncRetryTask = nil
            syncError = nil
            apply(
                snapshot,
                preservingStatusChangesAfter: statusRevisionBeforeSnapshot)
            await session.updateSubscriptions(
                Self.subscriptions(paneIDs: agentsByPane.keys))
            refreshSnippets()
        } catch {
            guard !hasEnded else { return }
            syncError = Self.snapshotErrorMessage(error)
            publish()
            scheduleSnapshotRetry()
        }
    }

    private func scheduleSnapshotRetry() {
        guard resyncRetryTask == nil, !hasEnded else { return }
        resyncRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: snapshotRetryDelay)
            } catch {
                return
            }
            guard !hasEnded else { return }
            resyncRetryTask = nil
            scheduleResync()
        }
    }

    private func apply(
        _ snapshot: SessionSnapshot,
        preservingStatusChangesAfter snapshotStartRevision: UInt64
    ) {
        let workspaceByID = Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        var nextAgents: [String: ConsoleAgent] = [:]
        for info in snapshot.agents {
            let agent = Agent(info)
            let workspace = workspaceByID[agent.workspaceID]
            nextAgents[agent.paneID] = ConsoleAgent(
                hostID: host.id,
                hostName: host.displayName,
                agent: agent,
                workspaceLabel: workspace?.label,
                repoName: workspace?.worktree?.repoName,
                lastOutputSnippet: agentsByPane[agent.paneID]?.lastOutputSnippet)
        }
        for (paneID, change) in latestStatusChanges
        where change.revision > snapshotStartRevision {
            guard var row = nextAgents[paneID] else { continue }
            row.agent.status = change.status
            nextAgents[paneID] = row
        }
        latestStatusChanges.removeAll(keepingCapacity: true)
        agentsByPane = nextAgents
        workspaces = snapshot.workspaces
            .map { ConsoleWorkspace(id: $0.workspaceID, label: $0.label) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        publish()
    }

    private func applyStatusChange(_ data: JSONValue) {
        guard
            let paneID = data["pane_id"]?.stringValue,
            let rawStatus = data["agent_status"]?.stringValue
        else { return }
        let status = AgentStatus(rawValue: rawStatus)
        statusChangeRevision &+= 1
        latestStatusChanges[paneID] = (statusChangeRevision, status)
        guard var row = agentsByPane[paneID] else { return }
        row.agent.status = status
        agentsByPane[paneID] = row
        publish()
        Task { [weak self] in
            self?.refreshSnippet(paneID: paneID)
        }
    }

    private func refreshSnippets() {
        for paneID in agentsByPane.keys {
            refreshSnippet(paneID: paneID)
        }
    }

    private func refreshSnippet(paneID: String) {
        guard snippetFetchesInFlight.insert(paneID).inserted else {
            pendingSnippetRefreshes.insert(paneID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let read = try? await session.withTransport { transport in
                try await transport.readPane(
                    PaneReadParams(
                        paneID: paneID,
                        source: .recent,
                        lines: Self.snippetReadLines,
                        stripANSI: true))
            }
            snippetFetchesInFlight.remove(paneID)
            guard !hasEnded else { return }
            if let read, var row = agentsByPane[paneID] {
                row.lastOutputSnippet = Self.snippet(fromPaneText: read.text)
                agentsByPane[paneID] = row
                publish()
            }
            guard
                pendingSnippetRefreshes.remove(paneID) != nil,
                agentsByPane[paneID] != nil
            else { return }
            refreshSnippet(paneID: paneID)
        }
    }

    private func publish() {
        guard !hasEnded else { return }
        onChange()
    }

    private static let snippetReadLines = 6

    static func snippet(fromPaneText text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func snapshotErrorMessage(_ error: any Error) -> String {
        switch error {
        case TransportError.timedOut:
            "The Host did not answer while syncing Agents. Retrying…"
        case let apiError as HerdrAPIError:
            "herdr rejected the Console sync: \(apiError.message). Retrying…"
        default:
            "Could not sync this Host's Agents. Retrying…"
        }
    }

    private static let membershipKinds: [GlobalEventKind] = [
        .paneAgentDetected, .paneClosed, .paneExited,
        .workspaceCreated, .workspaceRenamed, .workspaceMetadataUpdated, .workspaceClosed,
    ]

    private static let resyncEventKinds =
        Set(membershipKinds.map(\.kind)).union([HerdrEventKind.eventsDropped])

    static func subscriptions(
        paneIDs: some Sequence<String>
    ) -> [EventSubscription] {
        membershipKinds.map(EventSubscription.global)
            + paneIDs.sorted().map { EventSubscription.pane(.agentStatusChanged, paneID: $0) }
    }
}
