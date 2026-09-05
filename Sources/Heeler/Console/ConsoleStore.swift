import Foundation
import Observation

/// The Console aggregate: reconciles the Host catalog and publishes one
/// Agent list with independent Pin and per-Host sidebar ordering. Each HostConsoleProjection
/// owns its own convergence, retry, snippets and Host-scoped RPC behavior.
@MainActor
@Observable
final class ConsoleStore {
    struct AgentStatusUpdate: Sendable, Equatable {
        let status: AgentStatus?
        let liveUpdatesAvailable: Bool
    }

    private(set) var agents: [ConsoleAgent] = []
    private(set) var hostStatuses: [Host.ID: EventsSessionStatus] = [:]
    private(set) var hostStandingFailures: [Host.ID: TransportError] = [:]
    private(set) var hostLatencies: [Host.ID: Duration] = [:]
    private(set) var hostSyncErrors: [Host.ID: String] = [:]
    private(set) var hostConnectionGenerations: [Host.ID: UInt64] = [:]
    /// Hosts whose current connection has not produced its first snapshot.
    /// Their empty Agent projection is loading state, not proof that a pane
    /// disappeared.
    private(set) var hostsAwaitingSnapshot: Set<Host.ID> = []
    /// Latest snapshot workspaces by Host. This is observable state rather
    /// than a projection lookup so an open New Agent picker refreshes when a
    /// snapshot arrives or a workspace membership event resyncs the Host.
    private(set) var workspacesByHost: [Host.ID: [ConsoleWorkspace]] = [:]
    /// Successful or snapshot-reconciled removals keyed by the exact Agents
    /// that belonged to the validated worktree. This survives their rows
    /// disappearing so Agent detail can show a stable result.
    private(set) var removedWorktreesByAgent: [
        ConsoleAgent.ID: WorktreeRemovalReceipt
    ] = [:]

    @ObservationIgnored private var projections: [
        Host.ID: HostConsoleProjection
    ] = [:]
    /// Skills probed per Host connection: keyed on the connection generation
    /// so a reconnect naturally invalidates, and evicted per Host on insert
    /// so stale generations cannot accumulate.
    @ObservationIgnored private var skillsCache: [SkillsCacheKey: [AgentSkill]] = [:]
    /// Status events already converge through each Host's one pane-scoped
    /// subscription. Composers consume this fan-out instead of opening a
    /// second events channel that could outlive the connection snapshot.
    @ObservationIgnored private var agentStatusObservers: [
        ConsoleAgent.ID: [UUID: AsyncStream<AgentStatusUpdate>.Continuation]
    ] = [:]
    /// Composer ownership sits above the detail branch so a transient
    /// missing-Agent placeholder during reconnect cannot destroy a draft.
    @ObservationIgnored private var composerStores: [
        ConsoleAgent.ID: AgentComposerStore
    ] = [:]
    /// The shell tab this app created per Workspace, so Open Terminal
    /// reattaches to it instead of accumulating a new tab per visit.
    /// In-memory on purpose: tabs die with the herdr server, and reuse
    /// verifies liveness before attaching, so persistence would only add
    /// stale state. Deliberately kept across reconnects — tabs survive them.
    @ObservationIgnored private var shellTerminals: [
        ShellTerminalKey: ShellTerminalIdentity
    ] = [:]

    private struct ShellTerminalKey: Hashable {
        let hostID: Host.ID
        let workspaceID: String
    }
    @ObservationIgnored private let makeSession:
        @Sendable (Host, [EventSubscription]) -> EventsSession
    @ObservationIgnored private let snapshotRetryDelay: Duration
    @ObservationIgnored private var isActive = false
    /// The most recently enqueued lifecycle transition. Suspend and resume
    /// are each several awaits long, so without a chain a resume racing a
    /// suspend can finish first and leave every Host suspended with nothing
    /// left to re-activate it.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    /// Shared with the Console list: a pin toggle must re-sort `agents` in
    /// the same turn, so the store lives here rather than only on the view.
    let pins: PinnedAgentsStore
    let rowLayouts: AgentRowLayoutStore
    let sidebarSnapshots = HerdrSidebarSnapshotStore()

    init(
        snapshotRetryDelay: Duration = .seconds(2),
        pins: PinnedAgentsStore = PinnedAgentsStore(),
        rowLayouts: AgentRowLayoutStore = AgentRowLayoutStore(),
        makeSession: @escaping @Sendable (Host, [EventSubscription]) -> EventsSession =
            ConsoleStore.sshSessionFactory()
    ) {
        self.snapshotRetryDelay = snapshotRetryDelay
        self.pins = pins
        self.rowLayouts = rowLayouts
        self.makeSession = makeSession
    }

    /// Pins or unpins the Agent and re-sorts the published list in the same
    /// turn — a pin must not wait on a reconnect to move.
    func togglePin(hostID: Host.ID, paneID: String) {
        pins.togglePin(hostID: hostID, paneID: paneID)
        rebuild()
    }

    /// Aligns Host projections with the catalog. Editing a Host replaces its
    /// projection because its connection coordinates may have changed.
    func setHosts(_ hosts: [Host]) {
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        composerStores = composerStores.filter { incoming[$0.key.hostID] != nil }
        for (id, projection) in projections where incoming[id] != projection.host {
            sidebarSnapshots.invalidate(id)
            projection.end()
            projections[id] = nil
        }
        for host in hosts where projections[host.id] == nil {
            startProjection(for: host)
        }
        rebuild()
    }

    func resume() async {
        await activate(revalidating: false)
    }

    /// Foreground activation: activates whatever is suspended, and re-proves
    /// whatever is not. A session the app was still holding when it went away
    /// comes back believing it is connected even when its link died in the
    /// meantime, and `resume()` has nothing to re-activate on it — so without
    /// the second half the Console shows a connection that is already gone
    /// until the keepalive gets round to noticing, up to its interval plus a
    /// request timeout later (#142). A Host already stopped on a
    /// non-retryable failure is asked once more here too: `resume()` no-ops on
    /// it as well, so on a return that no suspension preceded, nothing else
    /// would ask it again (#147).
    func reactivate() async {
        await activate(revalidating: true)
    }

    private func activate(revalidating: Bool) async {
        await enqueueLifecycleTransition { [self] in
            isActive = true
            let projections = Array(self.projections.values)
            for projection in projections {
                await projection.resume()
            }
            guard revalidating else { return }
            // Every Host, not only one the user has navigated to: recovery
            // that depends on navigation just trades the Retry button for
            // another hidden step, and the Console is a single list across
            // all Hosts anyway, so it has no notion of one being on screen.
            // The population this costs anything for is the Hosts currently
            // *failed*, which is normally none (#147).
            //
            // All at once: re-proving is one bounded round trip per Host, but
            // its only bound is the Transport's request timeout, and a Host
            // frozen with the app is exactly the case that runs it out.
            // Serially that is N timeouts holding the lifecycle chain, and
            // behind that chain sits any suspend() the user triggers by
            // leaving again — including the didFinishSuspending() that
            // releases the background assertion.
            await withTaskGroup(of: Void.self) { group in
                for projection in projections {
                    group.addTask { await projection.revalidate() }
                }
            }
        }
    }

    func suspend() async {
        await enqueueLifecycleTransition { [self] in
            isActive = false
            sidebarSnapshots.invalidateAll()
            rebuild()
            for projection in projections.values {
                await projection.suspend()
            }
        }
    }

    /// Chains `transition` behind the previously enqueued one and waits for
    /// it. Enqueueing is synchronous on the main actor, so the chain order is
    /// the call order.
    private func enqueueLifecycleTransition(
        _ transition: @escaping @MainActor () async -> Void
    ) async {
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await transition()
        }
        lifecycleTask = task
        await task.value
    }

    func retryFailedHosts() async {
        for projection in projections.values {
            await projection.retry()
        }
    }

    /// Restarts one Host without disturbing other Hosts that may be connected,
    /// reconnecting, or waiting for their own repair.
    func retryHost(_ id: Host.ID) async {
        await projections[id]?.retry()
    }

    /// The returned runner resolves the Host's live projection on every
    /// call: editing a Host replaces its projection (and session), and a
    /// runner captured by a long-lived Attach screen must follow it there
    /// instead of staying bound to the ended session.
    func terminalRunner(for hostID: Host.ID) -> TerminalSessionRunner {
        { [weak self] request, handler in
            guard let runner = await self?.liveTerminalRunner(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            try await runner(request, handler)
        }
    }

    /// Late-bound for the same reason as `terminalRunner(for:)`: a retryable
    /// upload taken before a Host edit must stage over the new session.
    func imageStager(for hostID: Host.ID) -> ImageStager {
        { [weak self] image, reporter in
            guard let stager = await self?.liveImageStager(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await stager(image, reporter)
        }
    }

    func fileStager(for hostID: Host.ID) -> FileStager {
        { [weak self] file, reporter in
            guard let stager = await self?.liveFileStager(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: "The Host is not connected.")
            }
            return try await stager(file, reporter)
        }
    }

    private func liveTerminalRunner(for hostID: Host.ID) -> TerminalSessionRunner? {
        projections[hostID]?.terminalRunner()
    }

    private func liveImageStager(for hostID: Host.ID) -> ImageStager? {
        projections[hostID]?.imageStager()
    }

    private func liveFileStager(for hostID: Host.ID) -> FileStager? {
        projections[hostID]?.fileStager()
    }

    func workspaces(for hostID: Host.ID) -> [ConsoleWorkspace] {
        workspacesByHost[hostID] ?? []
    }

    /// The projection behind every Host-scoped RPC; an unconnected Host
    /// fails loudly instead of silently dropping the action.
    private func projection(for hostID: Host.ID) throws -> HostConsoleProjection {
        guard let projection = projections[hostID] else {
            throw TransportError.sshUnreachable(
                detail: "The Host is not connected.")
        }
        return projection
    }

    func availableAgentKinds(on hostID: Host.ID) async throws -> [SupportedAgentKind] {
        try await projection(for: hostID).availableAgentKinds()
    }

    private struct SkillsCacheKey: Hashable {
        let hostID: Host.ID
        let generation: UInt64
        let kind: SupportedAgentKind
        let projectRoot: String?
    }

    /// The Skills pane's data source: probes the Host over its live Console
    /// connection, cached per (connection, kind, project root) until the
    /// connection is replaced. `forceRefresh` is the pane's manual refresh.
    func fetchSkills(
        kind: SupportedAgentKind,
        projectRoot: String?,
        on hostID: Host.ID,
        forceRefresh: Bool = false
    ) async throws -> [AgentSkill] {
        let generation = hostConnectionGenerations[hostID] ?? 0
        let key = SkillsCacheKey(
            hostID: hostID, generation: generation, kind: kind, projectRoot: projectRoot)
        if !forceRefresh, let cached = skillsCache[key] {
            return cached
        }
        let query = SkillListQuery(kind: kind, projectRoot: projectRoot)
        let skills = try await projection(for: hostID).session.withTransport { transport in
            try await transport.listSkills(query)
        }
        skillsCache = skillsCache.filter {
            $0.key.hostID != hostID || $0.key.generation == generation
        }
        skillsCache[key] = skills
        return skills
    }

    /// The skill content sheet's data source: reads one skill document over
    /// the Host's live Console connection. Uncached — it is user-triggered,
    /// one file at a time.
    func readSkillFile(path: String, on hostID: Host.ID) async throws -> String {
        try await projection(for: hostID).session.withTransport { transport in
            try await transport.readSkillFile(atPath: path)
        }
    }

    /// Composer's one-shot delivery source. Prompts borrow the Host's current
    /// Console connection rather than dialing a parallel connection or holding
    /// an RPC open for Agent completion.
    func promptAgent(_ params: AgentPromptParams, on hostID: Host.ID) async throws -> Agent {
        try await projection(for: hostID).session.withTransport { transport in
            try await transport.promptAgent(params)
        }
    }

    /// One Composer per selected Agent for the lifetime of its Host catalog
    /// entry. The Console detail may be replaced by a reconnect placeholder;
    /// retaining the store here keeps its entirely local draft intact.
    func composerStore(for agent: ConsoleAgent) -> AgentComposerStore {
        if let existing = composerStores[agent.id] { return existing }
        let hostID = agent.hostID
        let store = AgentComposerStore(
            target: agent.agent.paneID,
            initialStatus: agent.agent.status,
            statusUpdates: agentStatusUpdates(for: agent.id)
        ) { [weak self] params in
            guard let self else { throw TransportError.cancelled }
            return try await self.promptAgent(params, on: hostID)
        }
        composerStores[agent.id] = store
        return store
    }

    /// A latest-value view of the existing `pane.agent_status_changed`
    /// subscription for one Agent. Composer consumes it for delivery
    /// transitions without opening another event channel.
    func agentStatusUpdates(for id: ConsoleAgent.ID) -> AsyncStream<AgentStatusUpdate> {
        let observerID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentStatusUpdate.self, bufferingPolicy: .bufferingNewest(1))
        agentStatusObservers[id, default: [:]][observerID] = continuation
        continuation.yield(agentStatusUpdate(for: id))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeAgentStatusObserver(observerID, for: id)
            }
        }
        return stream
    }

    @discardableResult
    func startAgent(
        _ request: AgentLaunchRequest,
        on hostID: Host.ID
    ) async throws -> Agent {
        try await projection(for: hostID).startAgent(request)
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest,
        on hostID: Host.ID
    ) async throws -> ShellTerminalIdentity {
        try await projection(for: hostID).createShellTerminal(request)
    }

    func recallShellTerminal(
        forWorkspaceID workspaceID: String, on hostID: Host.ID
    ) -> ShellTerminalIdentity? {
        shellTerminals[ShellTerminalKey(hostID: hostID, workspaceID: workspaceID)]
    }

    func rememberShellTerminal(
        _ identity: ShellTerminalIdentity,
        forWorkspaceID workspaceID: String,
        on hostID: Host.ID
    ) {
        shellTerminals[ShellTerminalKey(hostID: hostID, workspaceID: workspaceID)] =
            identity
    }

    func forgetShellTerminal(
        forWorkspaceID workspaceID: String, on hostID: Host.ID
    ) {
        shellTerminals[ShellTerminalKey(hostID: hostID, workspaceID: workspaceID)] = nil
    }

    func shellTerminalStillExists(
        _ identity: ShellTerminalIdentity, on hostID: Host.ID
    ) async throws -> Bool {
        try await projection(for: hostID).paneExists(identity.paneID)
    }

    @discardableResult
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest,
        worktree: WorktreeSpec,
        on hostID: Host.ID
    ) async throws -> Agent {
        try await projection(for: hostID).startAgentInNewWorktree(request, worktree: worktree)
    }

    @discardableResult
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest,
        workspace: NewWorkspaceSpec,
        on hostID: Host.ID
    ) async throws -> Agent {
        try await projection(for: hostID).startAgentInNewWorkspace(
            request, workspace: workspace)
    }

    /// Suspends until `id` is reported by its Host's sync machinery, or the
    /// timeout elapses. The new-agent flow (#12) opens the started Agent's
    /// terminal, and the row it navigates to exists only once the post-start
    /// resync lands — waiting keeps the detail column from flashing its
    /// missing-Agent placeholder over a launch that just succeeded.
    func waitForAgent(_ id: ConsoleAgent.ID, timeout: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !agents.contains(where: { $0.id == id }) {
            guard clock.now < deadline,
                (try? await Task.sleep(for: .milliseconds(50))) != nil
            else { return }
        }
    }

    func closePane(_ paneID: String, on hostID: Host.ID) async throws {
        try await projection(for: hostID).closePane(paneID)
    }

    func listWorktrees(
        forWorkspaceID workspaceID: String, on hostID: Host.ID
    ) async throws -> WorktreeListResponse {
        try await projection(for: hostID).listWorktrees(forWorkspaceID: workspaceID)
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest, on hostID: Host.ID
    ) async throws -> WorktreeRemovalReceipt {
        try await projection(for: hostID).removeWorktree(request)
    }

    func renameAgent(
        _ paneID: String, name: String?, on hostID: Host.ID
    ) async throws {
        try await projection(for: hostID).renameAgent(paneID, name: name)
    }

    func renameWorkspace(
        _ workspaceID: String, label: String, on hostID: Host.ID
    ) async throws {
        try await projection(for: hostID).renameWorkspace(workspaceID, label: label)
    }

    private func startProjection(for host: Host) {
        let session = makeSession(
            host,
            HostConsoleProjection.subscriptions(paneIDs: []))
        let projection = HostConsoleProjection(
            host: host,
            session: session,
            snapshotRetryDelay: snapshotRetryDelay
        ) { [weak self] in
            self?.rebuild()
        }
        projections[host.id] = projection
        projection.start(isActive: isActive)
    }

    private func rebuild() {
        let current = Array(projections.values)
        hostStatuses = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.status.map { (projection.host.id, $0) }
            })
        hostStandingFailures = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.standingFailure.map { (projection.host.id, $0) }
            })
        hostLatencies = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.latency.map { (projection.host.id, $0) }
            })
        hostSyncErrors = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.syncError.map { (projection.host.id, $0) }
            })
        hostConnectionGenerations = Dictionary(
            uniqueKeysWithValues: current.map {
                ($0.host.id, $0.transportGeneration)
            })
        hostsAwaitingSnapshot = Set(
            current.lazy.filter(\.isAwaitingSnapshot).map(\.host.id))
        let nextWorkspacesByHost = Dictionary(
            uniqueKeysWithValues: current.map {
                ($0.host.id, $0.workspaces)
            })
        if workspacesByHost != nextWorkspacesByHost {
            workspacesByHost = nextWorkspacesByHost
        }
        let nextRemovedWorktreesByAgent = current.reduce(into: [:]) { result, projection in
            result.merge(projection.removedWorktreesByAgent) { _, latest in latest }
        }
        if removedWorktreesByAgent != nextRemovedWorktreesByAgent {
            removedWorktreesByAgent = nextRemovedWorktreesByAgent
        }
        let sidebarConnections = Dictionary(uniqueKeysWithValues: current.compactMap { projection
            -> (Host.ID, HerdrSidebarSnapshotStore.Connection)? in
            guard isActive, projection.status == .connected, !projection.isAwaitingSnapshot,
                let generation = hostConnectionGenerations[projection.host.id]
            else { return nil }
            return (projection.host.id, HerdrSidebarSnapshotStore.Connection(
                generation: generation, revision: projection.sidebarRevision))
        })
        sidebarSnapshots.reconcile(sidebarConnections, transports: self) { [weak self] in
            self?.rebuildAgentOrder()
        }
        rebuildAgentOrder()
        publishAgentStatuses()
    }

    func rowLayout(for hostID: Host.ID) -> AgentRowLayout {
        rowLayouts.resolvedLayout(
            for: hostID, pluginSnapshot: sidebarSnapshots.snapshot(for: hostID))
    }

    func refreshSidebarLayouts() async {
        await sidebarSnapshots.refresh(transports: self) { [weak self] in
            self?.rebuildAgentOrder()
        }
    }

    private func rebuildAgentOrder() {
        let unsorted = projections.values.flatMap { $0.agentsByPane.values }
        let sorts = Dictionary(uniqueKeysWithValues: projections.keys.compactMap { id in
            sidebarSnapshots.snapshot(for: id).map { (id, $0.agentPanelSort) }
        })
        let pinRanks = Dictionary(uniqueKeysWithValues: unsorted.compactMap { agent in
            pins.pinRank(hostID: agent.hostID, paneID: agent.agent.paneID)
                .map { (agent.id, $0) }
        })
        agents = unsorted.consoleSorted(sortByHost: sorts) { pinRanks[$0.id] }
    }

    private func publishAgentStatuses() {
        for (id, observers) in agentStatusObservers {
            let update = agentStatusUpdate(for: id)
            for continuation in observers.values {
                continuation.yield(update)
            }
        }
    }

    private func agentStatusUpdate(for id: ConsoleAgent.ID) -> AgentStatusUpdate {
        let status = agents.first(where: { $0.id == id })?.agent.status
        return AgentStatusUpdate(
            status: status,
            liveUpdatesAvailable: status != nil
                && hostStatuses[id.hostID] == .connected
                && !hostsAwaitingSnapshot.contains(id.hostID))
    }

    private func removeAgentStatusObserver(_ observerID: UUID, for id: ConsoleAgent.ID) {
        agentStatusObservers[id]?[observerID] = nil
        if agentStatusObservers[id]?.isEmpty == true {
            agentStatusObservers[id] = nil
        }
    }
}

extension ConsoleStore: NotificationTransportProvider {
    /// Notification Registration work borrows the Host's live Console
    /// connection (#75) instead of dialing a second one; an unconnected Host
    /// fails loudly like every other Host-scoped RPC here.
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        try await projection(for: hostID).session.withTransport(operation)
    }
}

extension ConsoleStore {
    /// The production session factory: SSH transports built from the Host
    /// catalog's credentials. TOFU is restricted to already-trusted
    /// fingerprints; the Console never prompts.
    static func sshSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider()
    ) -> @Sendable (Host, [EventSubscription]) -> EventsSession {
        { host, subscriptions in
            EventsSession(subscriptions: subscriptions) {
                let resolved: SSHCredentials
                do {
                    resolved = try credentials.credentials(for: host)
                } catch HostCredentialsError.passwordNotSet {
                    throw TransportError.authenticationFailed
                }
                let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
                return try await connector.connect(
                    settings: SSHTransportSettings(
                        host: host,
                        credentials: resolved,
                        hostKeyPolicy: policy))
            }
        }
    }
}
