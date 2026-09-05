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
    /// The failure that last stopped automatic recovery, retained after the
    /// next activation begins and discarded when that activation resolves.
    /// See Standing Failure in `CONTEXT.md`.
    private(set) var standingFailure: TransportError?
    /// The last herdr `ping` round trip measured on the Host's *current*
    /// connection, mirrored from `EventsSession.currentLatency` so a
    /// measurement never outlives the connection that proved it.
    private(set) var latency: Duration?
    private(set) var syncError: String?
    private(set) var transportGeneration: UInt64 = 0
    private(set) var sidebarRevision: UInt64 = 0
    /// Whether the Host's current connection generation has produced a
    /// snapshot. `.connected` arrives before that request completes, so an
    /// empty projection in this window means "unknown", not "no Agents".
    private(set) var isAwaitingSnapshot = true
    /// Stable success surfaces keyed by every Agent that belonged to the
    /// exact validated worktree at dispatch.
    var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] {
        worktreeRemovalReceiptsByAgent.mapValues(\.receipt)
    }

    private struct WorktreeRemovalReceiptRecord {
        let receipt: WorktreeRemovalReceipt
        let snapshotRequestGeneration: UInt64
    }

    private struct WorktreeRemovalOperation {
        enum Phase {
            case preparing
            case dispatched(snapshotRequestGeneration: UInt64)
            case unconfirmed(snapshotRequestGeneration: UInt64)
        }

        let request: WorktreeRemovalRequest
        var affectedAgentIDs: Set<ConsoleAgent.ID> = []
        var phase: Phase = .preparing
    }

    private let snapshotRetryDelay: Duration
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var terminalTransportTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var resyncRetryTask: Task<Void, Never>?
    private var resyncPending = false
    /// Invalidates snapshot work that crossed a disconnected state. A request
    /// already in flight may still return after its Host drops, but its stale
    /// rows must never repopulate the Console.
    private var snapshotEpoch: UInt64 = 0
    /// Request-start order, used only after a complete remove request line was
    /// written. A snapshot already in flight cannot resolve its outcome.
    private var snapshotRequestGeneration: UInt64 = 0
    private var workspacesByID: [String: WorkspaceInfo] = [:]
    private var worktreeRemovalOperations: [UUID: WorktreeRemovalOperation] = [:]
    private var worktreeRemovalReceiptsByAgent: [
        ConsoleAgent.ID: WorktreeRemovalReceiptRecord
    ] = [:]
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
        // The stream is only the wake-up: `latencyUpdates` and `updates` are
        // consumed by two tasks whose order against each other is undefined,
        // so the sample it carries could be one this Host's connection no
        // longer stands behind. `session.currentLatency` is the value ordered
        // against the status updates the other task folds.
        latencyTask = Task { [weak self] in
            guard let self else { return }
            for await _ in session.latencyUpdates {
                guard !Task.isCancelled else { return }
                self.latency = session.currentLatency
                self.publish()
            }
        }
        terminalTransportTask = Task { [weak self] in
            guard let self else { return }
            for await generation in session.terminalTransportGenerations {
                guard !Task.isCancelled else { return }
                // Transport installation is the terminal readiness edge. It
                // intentionally precedes events subscription and snapshot work.
                transportGeneration = max(transportGeneration, generation)
                publish()
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
    /// reports `.connecting` while that attempt runs, and the Standing
    /// Failure keeps every status-derived surface presenting the same
    /// guidance until the activation answers.
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

    /// Makes the new activation visible on this projection before the
    /// session hops into teardown, so an in-flight resync cannot observe
    /// `.connected` after `currentTransport` is already gone.
    ///
    /// The latency is dropped outright rather than re-read from the session:
    /// this decision is what ends the old connection, and the session has not
    /// yet been asked to publish the status that clears its own copy.
    private func beginNewActivation() {
        status = .connecting
        latency = nil
        invalidateSnapshot()
        publish()
    }

    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        resyncPending = false
        resyncTask?.cancel()
        resyncRetryTask?.cancel()
        consumeTask?.cancel()
        latencyTask?.cancel()
        terminalTransportTask?.cancel()
        resyncTask = nil
        resyncRetryTask = nil
        consumeTask = nil
        latencyTask = nil
        terminalTransportTask = nil
        Task { await session.end() }
    }

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

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        try await session.withTransport { transport in
            try await transport.createShellTerminal(request)
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

    @discardableResult
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        let agent = try await session.withTransport { transport in
            try await transport.startAgentInNewWorkspace(request, workspace: workspace)
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

    /// Whether a Pane is still alive on the Host, probed with a minimal
    /// `pane.read`. A server rejection means the Pane is gone (closed on the
    /// desktop, or the server restarted and lost every tab); a transport
    /// failure proves nothing and is rethrown so the caller does not mistake
    /// an outage for a missing Pane.
    func paneExists(_ paneID: String) async throws -> Bool {
        do {
            _ = try await session.withTransport { transport in
                try await transport.readPane(
                    PaneReadParams(paneID: paneID, source: .visible, lines: 1))
            }
            return true
        } catch is HerdrAPIError {
            return false
        } catch TransportError.apiRejected {
            return false
        }
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        try await session.withTransport { transport in
            try await transport.listWorktrees(forWorkspaceID: workspaceID)
        }
    }

    /// One operation record per immutable request prevents repeated taps and
    /// concurrent removals from replacing one another. Exact identity is
    /// checked again inside the Transport's write boundary, after channel
    /// admission and immediately before the first request byte.
    func removeWorktree(
        _ request: WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalReceipt {
        guard request.identity.hostID == host.id else {
            throw WorktreeRemovalError.staleIdentity
        }
        guard worktreeRemovalOperations[request.id] == nil else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        guard !worktreeRemovalOperations.values.contains(where: {
            $0.request.identity == request.identity
        }) else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        worktreeRemovalOperations[request.id] = WorktreeRemovalOperation(request: request)

        do {
            let response = try await session.withTransport { transport in
                try await transport.removeWorktree(
                    request,
                    authorize: { request in
                        try await self.authorizeWorktreeRemoval(request)
                    },
                    onDispatched: { request in
                        await self.worktreeRemovalWasDispatched(request)
                    })
            }
            guard response.workspaceID == request.identity.workspaceID else {
                try markWorktreeRemovalUnconfirmed(request)
                scheduleResync()
                throw WorktreeRemovalError.outcomeUnconfirmed
            }
            let receipt = try finishSuccessfulWorktreeRemoval(request)
            scheduleResync()
            publish()
            return receipt
        } catch let error as WorktreeRemovalError {
            if error != .outcomeUnconfirmed {
                worktreeRemovalOperations[request.id] = nil
            }
            publish()
            throw error
        } catch {
            if Self.isDefiniteWorktreeRejection(error) {
                worktreeRemovalOperations[request.id] = nil
                publish()
                throw error
            }
            guard let operation = worktreeRemovalOperations[request.id],
                case .dispatched = operation.phase
            else {
                worktreeRemovalOperations[request.id] = nil
                publish()
                throw error
            }
            try markWorktreeRemovalUnconfirmed(request)
            scheduleResync()
            publish()
            throw WorktreeRemovalError.outcomeUnconfirmed
        }
    }

    private func authorizeWorktreeRemoval(_ request: WorktreeRemovalRequest) throws {
        guard
            var operation = worktreeRemovalOperations[request.id],
            operation.request == request,
            case .preparing = operation.phase,
            let workspace = workspacesByID[request.identity.workspaceID],
            let checkout = workspace.worktree.map(RepositoryCheckout.init),
            request.identity.matches(checkout)
        else {
            throw WorktreeRemovalError.staleIdentity
        }
        operation.affectedAgentIDs = Set(
            agentsByPane.values.lazy
                .filter {
                    $0.agent.workspaceID == request.identity.workspaceID
                        && $0.repositoryCheckout.map(request.identity.matches) == true
                }
                .map(\.id))
        worktreeRemovalOperations[request.id] = operation
    }

    private func worktreeRemovalWasDispatched(_ request: WorktreeRemovalRequest) {
        guard var operation = worktreeRemovalOperations[request.id],
            operation.request == request,
            case .preparing = operation.phase
        else { return }
        operation.phase = .dispatched(
            snapshotRequestGeneration: snapshotRequestGeneration)
        worktreeRemovalOperations[request.id] = operation
    }

    private func markWorktreeRemovalUnconfirmed(
        _ request: WorktreeRemovalRequest
    ) throws {
        guard var operation = worktreeRemovalOperations[request.id],
            operation.request == request,
            case .dispatched(let generation) = operation.phase
        else { throw WorktreeRemovalError.staleIdentity }
        operation.phase = .unconfirmed(snapshotRequestGeneration: generation)
        worktreeRemovalOperations[request.id] = operation
    }

    private func finishSuccessfulWorktreeRemoval(
        _ request: WorktreeRemovalRequest
    ) throws -> WorktreeRemovalReceipt {
        guard let operation = worktreeRemovalOperations.removeValue(forKey: request.id),
            operation.request == request
        else { throw WorktreeRemovalError.staleIdentity }
        let receipt = WorktreeRemovalReceipt(
            request: request, affectedAgentIDs: operation.affectedAgentIDs)
        record(receipt, atSnapshotRequestGeneration: snapshotRequestGeneration)
        return receipt
    }

    private func record(
        _ receipt: WorktreeRemovalReceipt,
        atSnapshotRequestGeneration generation: UInt64
    ) {
        let record = WorktreeRemovalReceiptRecord(
            receipt: receipt,
            snapshotRequestGeneration: generation)
        for agentID in receipt.affectedAgentIDs {
            worktreeRemovalReceiptsByAgent[agentID] = record
        }
    }

    private static func isDefiniteWorktreeRejection(_ error: any Error) -> Bool {
        switch error {
        case is HerdrAPIError:
            true
        case TransportError.apiRejected(_, _):
            true
        default:
            false
        }
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
            // A latency belongs to the connection that measured it, and the
            // session clears this before publishing any status that ends one.
            // Reading it here rather than tracking the latency stream's
            // payload is what makes the pairing exact: a status that ends a
            // connection can only ever be folded against nil, and the sample
            // a new connection proved before announcing itself is already
            // here when its `.connected` lands.
            latency = session.currentLatency
            switch status {
            case .failed(let failure):
                standingFailure = failure
            case .connected, .reconnecting:
                standingFailure = nil
            case .connecting, .suspended, .ended:
                break
            }
            if status == .connected {
                publish()
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
        snapshotRequestGeneration &+= 1
        let requestGeneration = snapshotRequestGeneration
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
                preservingStatusChangesAfter: statusRevisionBeforeSnapshot,
                requestGeneration: requestGeneration)
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
        workspacesByID.removeAll(keepingCapacity: true)
    }

    private func apply(
        _ snapshot: SessionSnapshot,
        preservingStatusChangesAfter snapshotStartRevision: UInt64,
        requestGeneration: UInt64
    ) {
        sidebarRevision &+= 1
        let paneByID = Dictionary(snapshot.panes.map { ($0.paneID, $0) }) { first, _ in first }
        let workspaceByID = Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        let tabByID = Dictionary(
            snapshot.tabs.map { ($0.tabID, $0) }) { first, _ in first }
        var tabCounts: [String: Int] = [:]
        var tabPositions: [String: Int] = [:]
        for tab in snapshot.tabs where tabPositions[tab.tabID] == nil {
            tabCounts[tab.workspaceID, default: 0] += 1
            tabPositions[tab.tabID] = tabCounts[tab.workspaceID]
        }
        var nextAgents: [String: ConsoleAgent] = [:]
        for (snapshotOrder, info) in snapshot.agents.enumerated() {
            let agent = Agent(info)
            let workspace = workspaceByID[agent.workspaceID]
            let tab = tabByID[agent.tabID].flatMap {
                $0.workspaceID == agent.workspaceID ? $0 : nil
            }
            nextAgents[agent.paneID] = ConsoleAgent(
                hostID: host.id,
                hostName: host.displayName,
                agent: agent,
                workspaceLabel: workspace?.label,
                repositoryCheckout: workspace?.worktree.map(RepositoryCheckout.init),
                lastOutputSnippet: agentsByPane[agent.paneID]?.lastOutputSnippet,
                hostUsername: host.username,
                tabLabel: tab?.label,
                tabPosition: tab.flatMap { tabPositions[$0.tabID] },
                workspaceTabCount: max(workspace?.tabCount ?? 0, tabCounts[agent.workspaceID] ?? 0),
                snapshotOrder: snapshotOrder,
                paneLabel: paneByID[agent.paneID].flatMap {
                    $0.tabID == agent.tabID && $0.workspaceID == agent.workspaceID ? $0.label : nil
                })
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
        workspacesByID = workspaceByID
        workspaces = snapshot.workspaces
            .map { ConsoleWorkspace(id: $0.workspaceID, label: $0.label) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        pruneReceiptsReintroducedByCurrentSnapshot(
            requestGeneration: requestGeneration)
        reconcileUnconfirmedWorktreeRemovals(requestGeneration: requestGeneration)
        publish()
    }

    /// A later snapshot is the source of truth for existence. If the exact
    /// removed identity appears again, it is a recreated/live worktree and
    /// must not inherit an older success surface.
    private func pruneReceiptsReintroducedByCurrentSnapshot(
        requestGeneration: UInt64
    ) {
        worktreeRemovalReceiptsByAgent = worktreeRemovalReceiptsByAgent.filter {
            agentID, record in
            guard requestGeneration > record.snapshotRequestGeneration else {
                return true
            }
            guard let agent = agentsByPane[agentID.paneID], agent.id == agentID else {
                return true
            }
            let identity = record.receipt.request.identity
            return agent.agent.workspaceID != identity.workspaceID
                || agent.repositoryCheckout.map(identity.matches) != true
        }
    }

    private func reconcileUnconfirmedWorktreeRemovals(requestGeneration: UInt64) {
        for (id, operation) in worktreeRemovalOperations {
            guard case .unconfirmed(let dispatchGeneration) = operation.phase,
                requestGeneration > dispatchGeneration
            else { continue }
            let stillPresent = workspacesByID[operation.request.identity.workspaceID]
                .flatMap(\.worktree)
                .map(RepositoryCheckout.init)
                .map(operation.request.identity.matches) == true
            worktreeRemovalOperations[id] = nil
            if !stillPresent {
                record(
                    WorktreeRemovalReceipt(
                        request: operation.request,
                        affectedAgentIDs: operation.affectedAgentIDs),
                    atSnapshotRequestGeneration: requestGeneration)
            }
        }
    }

    private func applyStatusChange(_ data: JSONValue) -> AgentStatus? {
        guard
            let paneID = data["pane_id"]?.stringValue,
            let rawStatus = data["agent_status"]?.stringValue
        else { return nil }
        let status = AgentStatus(rawValue: rawStatus)
        statusChangeRevision &+= 1
        sidebarRevision &+= 1
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
