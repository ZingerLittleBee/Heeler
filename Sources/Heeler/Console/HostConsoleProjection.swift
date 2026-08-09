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
    private(set) var latency: Duration?
    private(set) var syncError: String?
    private(set) var transportGeneration: UInt64 = 0
    /// Whether the Host's current connection generation has produced a
    /// snapshot. `.connected` arrives before that request completes, so an
    /// empty projection in this window means "unknown", not "no Agents".
    private(set) var isAwaitingSnapshot = true

    private let snapshotRetryDelay: Duration
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var resyncRetryTask: Task<Void, Never>?
    private var resyncPending = false
    /// Invalidates snapshot work that crossed a disconnected state. A request
    /// already in flight may still return after its Host drops, but its stale
    /// rows must never repopulate the Console.
    private var snapshotEpoch: UInt64 = 0
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
        latencyTask = Task { [weak self] in
            guard let self else { return }
            for await latency in session.latencyUpdates {
                guard !Task.isCancelled else { return }
                self.latency = latency
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

    /// Re-proves this Host on a foreground return, by whatever means its
    /// current state calls for.
    ///
    /// A session that was never told to suspend — the app froze before its
    /// teardown ran, or the trip out was short enough that the grace period
    /// absorbed it — comes back believing it is still connected. `resume()`
    /// is a no-op on such a session, so without this nothing asks it until
    /// the keepalive's next turn (#142). That case is a ping.
    ///
    /// A session already stopped on a non-retryable failure is restarted
    /// instead (#147). Its reconnect loop returned while the phase stayed
    /// `.active`, so `resume()` no-ops and no live channel remains to ping.
    /// The gap that leaves is the same one #142 covers for connected Hosts,
    /// and it is exactly that narrow: an absence longer than
    /// `AppActivityCoordinator.defaultGracePeriod` does run `suspend()` — the
    /// phase is still `.active`, so `deactivate()` proceeds — and the return's
    /// `resume()` then restarts the run loop on its own. What was left
    /// stranded is a return *inside* the grace period, or one where the
    /// process froze before its teardown could run. Inside that window a user
    /// who went and restarted herdr came back to the same failure until they
    /// found the Retry button.
    ///
    /// This is deliberately not a retry cadence. The classification that
    /// stopped the loop stands — retrying a stopped herdr on reconnect timing
    /// would be a hot loop against a server that is not there, and would bury
    /// the guidance the user needs. It is one attempt on an explicit user
    /// action, and coming back to the app is one. A Host that is still broken
    /// lands straight back on `.failed` carrying the same guidance, having
    /// emitted nothing in between that could read as recovery.
    func revalidate() async {
        if case .failed = status {
            await session.retry()
        } else {
            await session.revalidate()
        }
    }

    func suspend() async {
        await session.suspend()
    }

    func retry() async {
        await session.retry()
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        resyncPending = false
        resyncTask?.cancel()
        resyncRetryTask?.cancel()
        consumeTask?.cancel()
        latencyTask?.cancel()
        resyncTask = nil
        resyncRetryTask = nil
        consumeTask = nil
        latencyTask = nil
        Task { await session.end() }
    }

    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            try await session.withTerminalTransport { transport in
                let terminal = try await transport.attachTerminal(request)
                try await handler.runEndingSession(terminal)
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

    func fileStager() -> FileStager {
        let session = session
        return { file, reporter in
            try await session.withTransport { transport in
                try await transport.stageFile(file) { progress in
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

    /// Renames an Agent (#98); a nil name clears back to the detected kind.
    /// The new name lands via the post-RPC resync, not an event delta:
    /// `pane.updated` does not carry the agent name and fires on every
    /// terminal-title change (measured live: 34 events in 6s on a working
    /// host), so subscribing to it as a resync trigger would re-snapshot
    /// continuously. Renames made by other clients therefore surface only on
    /// the next resync.
    func renameAgent(_ paneID: String, name: String?) async throws {
        try await session.withTransport { transport in
            try await transport.renameAgent(AgentRenameParams(target: paneID, name: name))
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
            if status == .connected {
                publish()
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
            } else {
                invalidateSnapshot()
                publish()
            }
        case .event(let event):
            if event.kind == PaneEventKind.agentStatusChanged.kind {
                if applyStatusChange(event.data) == .unknown {
                    // A released Agent can leave its Pane alive as a normal
                    // shell. Unknown is therefore not only a status delta: it
                    // may mean the Agent no longer belongs in the snapshot.
                    scheduleResync()
                }
            } else if Self.resyncEventKinds.contains(event.kind) {
                scheduleResync()
            }
        }
    }

    /// Runs one re-snapshot at a time; signals arriving mid-run coalesce into
    /// one follow-up run.
    private func scheduleResync() {
        guard !hasEnded, status == .connected else { return }
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
        let epochBeforeSnapshot = snapshotEpoch
        let statusRevisionBeforeSnapshot = statusChangeRevision
        do {
            let snapshot = try await session.withTransport { transport in
                try await transport.sessionSnapshot()
            }
            guard
                !hasEnded,
                status == .connected,
                snapshotEpoch == epochBeforeSnapshot
            else { return }
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
            guard
                !hasEnded,
                status == .connected,
                snapshotEpoch == epochBeforeSnapshot
            else { return }
            syncError = Self.snapshotErrorMessage(error)
            publish()
            scheduleSnapshotRetry()
        }
    }

    private func scheduleSnapshotRetry() {
        guard resyncRetryTask == nil, !hasEnded, status == .connected else { return }
        resyncRetryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: snapshotRetryDelay)
            } catch {
                return
            }
            guard !hasEnded, status == .connected else { return }
            resyncRetryTask = nil
            scheduleResync()
        }
    }

    private func invalidateSnapshot() {
        snapshotEpoch &+= 1
        isAwaitingSnapshot = true
        resyncPending = false
        resyncRetryTask?.cancel()
        resyncRetryTask = nil
        syncError = nil
        latestStatusChanges.removeAll(keepingCapacity: true)
        pendingSnippetRefreshes.removeAll(keepingCapacity: true)
        agentsByPane.removeAll(keepingCapacity: true)
        workspaces.removeAll(keepingCapacity: true)
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
                checkoutPath: workspace?.worktree?.checkoutPath,
                lastOutputSnippet: agentsByPane[agent.paneID]?.lastOutputSnippet)
        }
        for (paneID, change) in latestStatusChanges
        where change.revision > snapshotStartRevision {
            guard var row = nextAgents[paneID] else { continue }
            row.agent.status = change.status
            nextAgents[paneID] = row
        }
        latestStatusChanges.removeAll(keepingCapacity: true)
        isAwaitingSnapshot = false
        agentsByPane = nextAgents
        workspaces = snapshot.workspaces
            .map { ConsoleWorkspace(id: $0.workspaceID, label: $0.label) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        publish()
    }

    private func applyStatusChange(_ data: JSONValue) -> AgentStatus? {
        guard
            let paneID = data["pane_id"]?.stringValue,
            let rawStatus = data["agent_status"]?.stringValue
        else { return nil }
        let status = AgentStatus(rawValue: rawStatus)
        statusChangeRevision &+= 1
        latestStatusChanges[paneID] = (statusChangeRevision, status)
        guard var row = agentsByPane[paneID] else { return status }
        row.agent.status = status
        agentsByPane[paneID] = row
        publish()
        Task { [weak self] in
            self?.refreshSnippet(paneID: paneID)
        }
        return status
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
