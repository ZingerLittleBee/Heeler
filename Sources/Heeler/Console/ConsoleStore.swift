import Foundation
import Observation

/// The Console aggregate: reconciles the Host catalog and publishes one
/// Agent list with independent Pin and per-Host sidebar ordering. Each ConsoleHostProjection
/// owns its own convergence, retry, snippets and Host-scoped RPC behavior.
/// How a close or a removal ended, for the Console to say with its screen gone.
struct ConsoleOutcomeNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class ConsoleStore {
    struct AgentStatusUpdate: Sendable, Equatable {
        let status: AgentStatus?
        let liveUpdatesAvailable: Bool
        /// The Host connection the status came over; a new one may follow
        /// turns that ran while no connection could see them.
        var connectionGeneration: UInt64? = nil
    }

    private(set) var agents: [ConsoleAgent] = []
    /// Who `agents` lists. A view that only asks whether an Agent is there
    /// reads this, and is left alone by every change to what an Agent is doing.
    private(set) var listedAgentIDs: Set<ConsoleAgent.ID> = []
    /// Agents off the list whose program was lost or ended. Only a detail
    /// already open on one reads them, through `detailAgent(for:)`.
    private(set) var departedAgents: [ConsoleAgent] = []
    private(set) var terminals: [ConsoleTerminal] = []
    /// See `sceneDidEnd`.
    @ObservationIgnored private var endedScenes: Set<UUID> = []
    private struct AgentViewer {
        let agent: ConsoleAgent.ID
        let scene: UUID?
    }
    /// See `setAgentShown`.
    @ObservationIgnored private var agentViewers: [UUID: AgentViewer] = [:]
    private(set) var hostStatuses: [Host.ID: EventsSessionStatus] = [:]
    private(set) var hostStandingFailures: [Host.ID: TransportError] = [:]
    private(set) var hostLatencies: [Host.ID: Duration] = [:]
    private(set) var hostsCheckingConnection: Set<Host.ID> = []
    /// The route each connected Host's current connection reached.
    private(set) var hostRouteIDs: [Host.ID: HostRoute.ID] = [:]
    private(set) var hostSyncErrors: [Host.ID: String] = [:]
    /// Connected Hosts whose server inherited variables that break things.
    private(set) var hostCoreEnvironmentNotices: [Host.ID: HerdrCoreEnvironmentNotice] = [:]
    /// Why each core Agent reading Unknown does (ADR 0034). No Herdr TUI Agent is here.
    private(set) var coreStatusExplanations: [ConsoleAgent.ID: HerdrCoreStatusExplanation] = [:]
    /// The harness configuration edits this device applied (ADR 0033).
    let harnessEdits: HarnessConfigEditStore
    private let hostHelperBundle: @Sendable () throws -> HostHelperBundle
    private(set) var hostConnectionGenerations: [Host.ID: UInt64] = [:]
    /// Hosts whose current connection has not produced its first snapshot.
    /// Their empty Agent projection is loading state, not proof that a pane
    /// disappeared.
    private(set) var hostsAwaitingSnapshot: Set<Host.ID> = []
    /// Hosts whose inventory predates their current connection, including one
    /// replaced silently. Their rows stay listed, but input waits.
    private(set) var hostsAwaitingFreshSnapshot: Set<Host.ID> = []
    /// Latest snapshot workspaces by Host. This is observable state rather
    /// than a projection lookup so an open New Agent picker refreshes when a
    /// snapshot arrives or a workspace membership event resyncs the Host.
    private(set) var workspacesByHost: [Host.ID: [ConsoleWorkspace]] = [:]
    /// Successful or snapshot-reconciled removals keyed by the exact Agents
    /// that belonged to the validated worktree. This survives their rows
    /// disappearing so Agent detail can show a stable result.
    /// Outcomes whose screen had gone by the time they came. Off the Console's
    /// projections on purpose: a reconnect that clears an inventory leaves these.
    private(set) var outcomeNotices: [ConsoleOutcomeNotice] = []
    private(set) var removedWorktreesByAgent: [
        ConsoleAgent.ID: WorktreeRemovalReceipt
    ] = [:]
    /// Each Host's platform as its connection reported it; a core Host's Chat and
    /// uploads wait for it, and what they offer then follows `HostCapabilities`. Kept
    /// across reconnects of one catalog entry, so a reconnect does not take an
    /// open Chat away, and asked again on each new connection.
    private(set) var hostPlatforms: [Host.ID: HostPlatform] = [:]
    /// What each core Host's desktop app can name right now.
    private(set) var hostDesktopAppNaming: [Host.ID: HerdrAppNaming] = [:]
    /// Each core Host's kernel, as its locator prints it, once a link has located its core.
    private(set) var hostCoreKernels: [Host.ID: String] = [:]
    /// The core each core Host's inventory comes from, and the server instance
    /// each tmux Host's does. A detail reads it, so it redraws once the Host no
    /// longer serves what it opened on.
    private(set) var hostCores: [Host.ID: String] = [:]
    /// Per-Host capabilities, published only when a Host's effective capabilities
    /// actually change so connection retries do not invalidate observers of Herdr TUI
    /// or already-identified core Hosts.
    private(set) var hostCapabilities: [Host.ID: HostCapabilities] = [:]
    /// Actionable Host status rows for `catalog`, published only when a presentation
    /// changes so list passes reuse the built copy.
    private(set) var hostIssues: [ConsoleHostStatusPresentation] = []
    /// Live rows plus saved Chat entry points while a Host is unproven. The
    /// separate `agents` property remains the only realtime inventory.
    private(set) var chatDisplayAgents: [ConsoleAgent] = []
    /// The saved entries among `chatDisplayAgents`, each with its Host's
    /// readiness, so its row reads as saved rather than as an Agent that is
    /// running. Live Agents have no entry.
    private(set) var savedChatEntries: [ConsoleAgent.ID: HostReadiness] = [:]
    /// The Workspace structure each Host's last snapshot reported, for the
    /// Hosts whose rows may be saved Chat entries, so By Workspace groups
    /// those entries as it grouped the live Agents.
    private(set) var savedWorkspaceStructures: [Host.ID: [ChatCachedWorkspace]] = [:]
    /// The connection each Host's platform was last asked on.
    @ObservationIgnored private var hostPlatformGenerations: [Host.ID: UInt64] = [:]

    @ObservationIgnored private var projections: [
        Host.ID: any ConsoleHostProjection
    ] = [:]
    /// Skills probed per Host connection: keyed on the connection generation
    /// so a reconnect naturally invalidates, and evicted per Host on insert
    /// so stale generations cannot accumulate.
    @ObservationIgnored private var skillsCache: [SkillsCacheKey: [AgentSkill]] = [:]
    @ObservationIgnored private var agyModelsCache: [Host.ID: (generation: UInt64, models: [AgyModelCatalog.Choice])] = [:]
    /// Status events already converge through each Host's one pane-scoped
    /// subscription. Composers consume this fan-out instead of opening a
    /// second events channel that could outlive the connection snapshot.
    @ObservationIgnored private var agentStatusObservers: [
        ConsoleAgent.ID: [UUID: AsyncStream<AgentStatusUpdate>.Continuation]
    ] = [:]
    @ObservationIgnored private var gitExecGates: [Host.ID: GitExecGate] = [:]
    /// The Agents list's Changes totals, one store per Agent, shared by
    /// every window's rows and by nothing else.
    @ObservationIgnored private(set) lazy var rowChanges = AgentRowChanges { [unowned self] agent in
        let store = makeChangesStore(
            agentID: agent.id, hostID: agent.hostID, openingDirectory: agent.directory)
        store.onLoaded = { [weak self] changes in
            guard let self, let host = projections[agent.hostID]?.host else { return }
            cachedChats.record(
                changes.head.branch, atCheckoutPath: String(decoding: changes.checkout.topLevel, as: UTF8.self),
                on: host)
        }
        return store
    }
    /// Composer ownership sits above the detail branch so a failed Host's
    /// missing-Agent placeholder cannot destroy a draft, and
    /// no view's lifetime decides an upload's.
    @ObservationIgnored private var composerSessions: [
        ConsoleAgent.ID: AgentComposerSession
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
    @ObservationIgnored private let makeCoreSession: @Sendable (Host) -> HerdrCoreHostSession
    @ObservationIgnored private let makeTmuxSession: @Sendable (Host) -> TmuxHostSession
    /// Hears the paths a tmux Host's connection resolved again, for the catalog.
    @ObservationIgnored var onTmuxPathsResolved: (@MainActor (Host.ID, TmuxPaths) -> Void)?
    /// A test supplies each Host's projection. Production leaves the choice to
    /// the Server Kind.
    @ObservationIgnored private let makeProjection: (@MainActor (Host) -> any ConsoleHostProjection)?
    @ObservationIgnored private let herdrAppRename: Bool
    @ObservationIgnored private let coreSendClock: BlockedCardClock
    @ObservationIgnored private let coreHostMemory: HerdrCoreHostMemory
    @ObservationIgnored private let coreStopClock: BlockedCardClock
    @ObservationIgnored private let coreLinuxChatPrograms: Set<ChatProgram>
    @ObservationIgnored private let coreMacOSChatPrograms: Set<ChatProgram>
    @ObservationIgnored private let chatTiming: AgentChatStore.Timing
    @ObservationIgnored private let chatNow: @Sendable () -> Date
    @ObservationIgnored private let coreWindowsChatPrograms: Set<ChatProgram>
    /// A core Host's connection for the files rooted at its Host Helper, dialed
    /// for each use and apart from the session its projection holds.
    @ObservationIgnored private let connectCore: @Sendable (Host) async throws -> any HerdrCoreTransport
    /// The tmux Hosts' equivalent, dialed when no live tmux session is up.
    @ObservationIgnored private let connectTmux: @Sendable (Host) async throws -> any TmuxTransport
    @ObservationIgnored private let snapshotRetryDelay: Duration
    @ObservationIgnored private let chatPrefetchRetryDelay: Duration
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
    let pluginStatuses = HeelerPluginStatusStore()
    /// Made on demand while a view reads them, so not observed: each store
    /// is observable itself.
    @ObservationIgnored private var agentUsageStores: [Host.ID: AgentUsageStore] = [:]
    /// Hosts that share a plugin config directory share its Account file,
    /// so every Host's Account changes take turns.
    @ObservationIgnored private let usageAccountFileGate = GitExecGate()
    /// Hears what this device has seen on a core Host, for its Host Helper.
    @ObservationIgnored var onCoreSeenMarksChanged:
        (@MainActor (Host.ID, String, [String: HerdrCoreTurnState.Mark]) -> Void)?
    @ObservationIgnored private var hostAccountsStores: [Host.ID: HostAccountsStore] = [:]
    /// The device's Launch Presets (#622).
    let launchPresets = LaunchPresetStore()
    /// Writes the widgets' snapshot of those readings. Only the app passes
    /// one: demo mode and tests must not replace the real widgets' figures.
    @ObservationIgnored let usageWidgets: AgentUsageWidgetPublisher?
    @ObservationIgnored private let usageSettings: AgentUsageSettings
    /// Reads made only because a widget's figures went stale, per Host.
    @ObservationIgnored private var widgetUsageRefreshes: [Host.ID: (id: UUID, task: Task<Void, Never>)] = [:]
    /// The catalog in its order, which the widgets' snapshot keeps.
    @ObservationIgnored private var catalog: [Host] = []
    let terminalConnections: TerminalConnectionPool
    let agentTerminals: AgentTerminalCache
    /// Chat's saved conversations. Volatile unless the app passes the file
    /// cache: demo mode and tests build Console stores in the app's own
    /// container, and their `setHosts` would otherwise clear the real one.
    @ObservationIgnored let chatCache: any ChatTranscriptCache
    let cachedChats: ConsoleChatCache
    @ObservationIgnored private var chatPrefetchTasks: [Host.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var chatPrefetched: [ConsoleAgent.ID: String] = [:]
    /// Prefetches that found no conversation yet, by the key they ran for.
    @ObservationIgnored private var chatPrefetchRetries: [ConsoleAgent.ID: (key: String, count: Int)] = [:]
    /// The connection whose saved Chat bindings were last re-proved, per Host.
    @ObservationIgnored private var chatCacheValidatedGenerations: [Host.ID: UInt64] = [:]
    @ObservationIgnored private var chatCacheRetention: Task<Void, Never>?
    /// How Chat reads each program's transcripts; nil leaves the program
    /// without Chat: not offered, not prefetched, and no reason to ask for
    /// its Host's platform.
    @ObservationIgnored private let chatAdapter: @Sendable (ChatProgram) -> ChatTranscriptAdapter?
    /// One Chat per Agent whose detail has shown it, kept like the Composer
    /// so leaving and returning keeps the conversation and its position.
    @ObservationIgnored private var chatStores: [ConsoleAgent.ID: AgentChatStore] = [:]
    /// The last session event each core Agent's Chat has heard of.
    @ObservationIgnored private var chatSessionEventRevisions: [ConsoleAgent.ID: UInt64] = [:]
    @ObservationIgnored private var terminalSnapshotRevisions: [Host.ID: UInt64] = [:]
    @ObservationIgnored private var terminalTransportGenerations: [Host.ID: UInt64] = [:]
    @ObservationIgnored private lazy var agyTitles = AgyAnnotationTitleStore(
        retryDelay: chatPrefetchRetryDelay
    ) { [weak self] in
        self?.rebuild()
    }

    init(
        snapshotRetryDelay: Duration = .seconds(2),
        chatPrefetchRetryDelay: Duration = .seconds(5),
        pins: PinnedAgentsStore = PinnedAgentsStore(),
        rowLayouts: AgentRowLayoutStore = AgentRowLayoutStore(),
        chatCache: any ChatTranscriptCache = VolatileChatTranscriptCache(),
        usageWidgets: AgentUsageWidgetPublisher? = nil,
        usageSettings: AgentUsageSettings = AgentUsageSettings(),
        makeSession: @escaping @Sendable (Host, [EventSubscription]) -> EventsSession =
            ConsoleStore.sshSessionFactory(),
        connectCore: @escaping @Sendable (Host) async throws -> any HerdrCoreTransport =
            ConsoleStore.sshCoreConnector(),
        connectTmux: @escaping @Sendable (Host) async throws -> any TmuxTransport =
            ConsoleStore.sshTmuxConnector(),
        chatAdapter: @escaping @Sendable (ChatProgram) -> ChatTranscriptAdapter? = {
            ChatTranscriptAdapter.standard(for: $0)
        },
        makeCoreSession: @escaping @Sendable (Host) -> HerdrCoreHostSession =
            ConsoleStore.coreSessionFactory(),
        makeTmuxSession: @escaping @Sendable (Host) -> TmuxHostSession =
            ConsoleStore.tmuxSessionFactory(),
        makeProjection: (@MainActor (Host) -> any ConsoleHostProjection)? = nil,
        coreStopClock: BlockedCardClock = .live,
        coreHostMemory: HerdrCoreHostMemory = HerdrCoreHostMemory(),
        harnessEdits: HarnessConfigEditStore = HarnessConfigEditStore(),
        hostHelperBundle: @escaping @Sendable () throws -> HostHelperBundle = { try HostHelperBundle.load() },
        herdrAppRename: Bool = HerdrAppControl.isRenameOn,
        coreSendClock: BlockedCardClock = .live,
        coreLinuxChatPrograms: Set<ChatProgram> = HostCapabilities.confirmedLinuxCoreChatPrograms,
        coreMacOSChatPrograms: Set<ChatProgram> = HostCapabilities.confirmedMacOSCoreChatPrograms,
        coreWindowsChatPrograms: Set<ChatProgram> = HostCapabilities.confirmedWindowsCoreChatPrograms,
        chatTiming: AgentChatStore.Timing = AgentChatStore.Timing(),
        chatNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.coreLinuxChatPrograms = coreLinuxChatPrograms
        self.coreMacOSChatPrograms = coreMacOSChatPrograms
        self.coreWindowsChatPrograms = coreWindowsChatPrograms
        self.chatTiming = chatTiming
        self.chatNow = chatNow
        self.coreSendClock = coreSendClock
        self.makeCoreSession = makeCoreSession
        self.makeTmuxSession = makeTmuxSession
        self.makeProjection = makeProjection
        self.coreStopClock = coreStopClock
        self.herdrAppRename = herdrAppRename
        self.coreHostMemory = coreHostMemory
        self.harnessEdits = harnessEdits
        self.hostHelperBundle = hostHelperBundle
        self.chatCache = chatCache
        cachedChats = ConsoleChatCache(cache: chatCache)
        self.usageWidgets = usageWidgets
        self.usageSettings = usageSettings
        self.chatAdapter = chatAdapter
        let terminalBudget = TerminalRetentionBudget()
        terminalConnections = TerminalConnectionPool(budget: terminalBudget)
        agentTerminals = AgentTerminalCache(budget: terminalBudget)
        self.snapshotRetryDelay = snapshotRetryDelay
        self.chatPrefetchRetryDelay = chatPrefetchRetryDelay
        self.pins = pins
        self.rowLayouts = rowLayouts
        self.makeSession = makeSession
        self.connectCore = connectCore
        self.connectTmux = connectTmux
        cachedChats.onChange = { [weak self] in
            self?.rebuildChatDisplayAgents()
        }
    }

    /// Pins or unpins the Agent and re-sorts the published list in the same
    /// turn — a pin must not wait on a reconnect to move.
    func togglePin(hostID: Host.ID, paneID: String) {
        pins.togglePin(hostID: hostID, paneID: paneID)
        rebuild()
    }

    /// Aligns Host projections with the catalog. Editing a Host replaces its
    /// projection because its connection coordinates may have changed. A Host
    /// waiting for its Server Kind is not the Console's yet.
    ///
    /// `hostsOutOfSight` is `HostStore.hostsOutOfSight`: Hosts in the catalog that
    /// are not listed, whose device memory stays. Nil says the catalog could not be
    /// read, so nobody can say which Hosts went and none of that memory is swept.
    func setHosts(_ catalogHosts: [Host], hostsOutOfSight: Set<Host.ID>? = []) {
        let hosts = catalogHosts.filter(\.serverKind.isConfirmed)
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        catalog = hosts
        // A tmux Host's stored paths are what a connection last resolved (ADR
        // 0044): they move without making it another Host.
        for (id, projection) in projections {
            guard let tmux = projection as? TmuxConsoleProjection, let host = incoming[id] else { continue }
            tmux.adoptPaths(of: host)
        }
        if let hostsOutOfSight {
            let retained = hostsOutOfSight.union(hosts.lazy.filter { $0.serverKind == .herdrCore }.map(\.id))
            // A tmux Host's server instance is kept where a core Host's core id is.
            coreHostMemory.retainHosts(retained.union(hosts.lazy.filter { $0.serverKind == .tmux }.map(\.id)))
            harnessEdits.retainHosts(retained)
        }
        cachedChats.setHosts(hosts)
        for id in projections.keys where incoming[id] != projections[id]?.host {
            chatPrefetchTasks[id]?.cancel()
            chatPrefetchTasks[id] = nil
            chatPrefetched = chatPrefetched.filter { $0.key.hostID != id }
            chatPrefetchRetries = chatPrefetchRetries.filter { $0.key.hostID != id }
            chatCacheValidatedGenerations[id] = nil
        }
        for (id, session) in composerSessions where incoming[id.hostID] == nil {
            session.leaveStaging()
            composerSessions[id] = nil
        }
        // A changed Host may name another herdr session, which keys Chat's
        // cache: its Chats start over.
        for (id, store) in chatStores where incoming[id.hostID] != projections[id.hostID]?.host {
            store.end()
            chatStores[id] = nil
            chatSessionEventRevisions[id] = nil
        }
        // Also the launch-time sweep: a Host removed while the app was not
        // running leaves a cache no one else would delete. Chained, so the
        // cache ends on the latest catalog whatever order tasks start in.
        let hostIDs = Set(incoming.keys)
        chatCacheRetention = Task { [previous = chatCacheRetention, chatCache] in
            await previous?.value
            await chatCache.retainHosts(hostIDs)
        }
        for (id, projection) in projections where incoming[id] != projection.host {
            sidebarSnapshots.invalidate(id)
            pluginStatuses.invalidate(id)
            agyTitles.invalidateHost(id)
            agentUsageStores.removeValue(forKey: id)?.invalidate()
            widgetUsageRefreshes.removeValue(forKey: id)?.task.cancel()
            terminalSnapshotRevisions[id] = nil
            terminalTransportGenerations[id] = nil
            hostPlatforms[id] = nil
            hostPlatformGenerations[id] = nil
            Task {
                await terminalConnections.removeHost(id)
                await agentTerminals.removeHost(id)
            }
            projection.end()
            projections[id] = nil
        }
        for host in hosts where projections[host.id] == nil {
            startProjection(for: host)
        }
        rebuild()
        publishUsageWidgets()
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
            for store in chatStores.values { store.resume() }
            let projections = Array(self.projections.values)
            for projection in projections {
                await projection.resume()
            }
            agyTitles.bumpRefreshEpoch()
            reconcileAgyAnnotationTitles()
            guard revalidating else {
                // A core Host with no connection never reports coming up.
                refreshStaleWidgetUsage()
                return
            }
            // Every Host, not only one the user has navigated to: recovery
            // that depends on navigation just trades the Retry button for
            // another hidden step, and the Console is a single list across
            // all Hosts anyway, so it has no notion of one being on screen.
            // The population this costs anything for is the Hosts currently
            // *failed*, which is normally none (#147).
            //
            // Revalidation schedules connection-owned probes without waiting
            // for their replies. Leaving again must still reach suspend() at
            // the existing grace deadline. Failed Hosts enqueue their restart
            // here, before a later lifecycle transition can overtake it.
            await withTaskGroup(of: Void.self) { group in
                for projection in projections {
                    group.addTask { await projection.revalidate() }
                }
            }
            // A connection held through the absence never reports coming
            // up, so the widgets' figures are checked here as well.
            refreshStaleWidgetUsage()
        }
    }

    func suspend() async {
        await enqueueLifecycleTransition { [self] in
            isActive = false
            for refresh in widgetUsageRefreshes.values { refresh.task.cancel() }
            widgetUsageRefreshes.removeAll()
            for store in chatStores.values { store.suspend() }
            // Before the terminals go: an upload ends interrupted, with
            // Retry, rather than cancelled by the teardown.
            for session in composerSessions.values { session.didSuspend() }
            for projection in projections.values {
                await projection.pauseHealthChecks()
            }
            await terminalConnections.suspend()
            await agentTerminals.suspend()
            agyTitles.suspendAll()
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

    /// Stops one Host's connection attempt (or its reconnect backoff) at
    /// once instead of waiting for it to time out; a connected Host is left
    /// alone. The Host reads Paused until it is retried or the app returns
    /// to the foreground.
    func cancelHostConnection(_ id: Host.ID) async {
        await projections[id]?.cancelConnecting()
    }

    /// The returned runner resolves the Host's live projection on every
    /// call: editing a Host replaces its projection (and session), and a
    /// runner captured by a long-lived Attach screen must follow it there
    /// instead of staying bound to the ended session. Its pipeline keeps to one
    /// core, for a Server Kind that has them, however many projections it sees.
    func terminalRunner(
        for hostID: Host.ID, keepingTo corePin: TerminalCorePin? = nil
    ) -> TerminalSessionRunner {
        let pin = corePin ?? TerminalCorePin()
        return { [weak self] request, handler in
            guard let runner = await self?.liveTerminalRunner(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: String(localized: "The Host is not connected."))
            }
            try await runner(request, handler.keeping(to: pin))
        }
    }

    /// A pin naming the core whose inventory this Host shows now, for a detail
    /// opening on one of its rows. A Herdr TUI Host has no core to name.
    func coreProjection(on hostID: Host.ID) -> HerdrCoreConsoleProjection? {
        projections[hostID] as? HerdrCoreConsoleProjection
    }

    func tmuxProjection(on hostID: Host.ID) -> TmuxConsoleProjection? {
        projections[hostID] as? TmuxConsoleProjection
    }

    /// Whether an address on this Host can come to mean another Terminal: a
    /// herdr-core Host's under another core, a tmux Host's under another server
    /// instance. A detail there keeps to the one it opened on.
    func keepsDetailsToCores(on hostID: Host.ID) -> Bool {
        projections[hostID] is HerdrCoreConsoleProjection || projections[hostID] is TmuxConsoleProjection
    }

    func corePin(on hostID: Host.ID) -> TerminalCorePin {
        TerminalCorePin(joined: hostCores[hostID])
    }

    /// Whether this Host has moved on from the core `pin` keeps to. An address then
    /// means another Terminal, so nothing a detail holding `pin` does may go by it.
    func hasLeftCore(_ pin: TerminalCorePin?, on hostID: Host.ID) -> Bool {
        guard let pin, let core = hostCores[hostID] else { return false }
        return !pin.admits(core)
    }

    /// What an ended terminal says in a detail that keeps to `corePin`, or nil for
    /// its own words.
    func terminalEndedMessage(keepingTo corePin: TerminalCorePin?, on hostID: Host.ID) -> String? {
        guard hasLeftCore(corePin, on: hostID) else { return nil }
        return projections[hostID] is TmuxConsoleProjection
            ? TerminalStatusPresentation.tmuxServerGoneMessage : TerminalStatusPresentation.coreGoneMessage
    }

    /// What an action from a detail that `hasLeftCore` throws: a tmux Host's
    /// Pane belongs to a server, a core Host's Terminal to a core.
    func leftCoreError(on hostID: Host.ID) -> TransportError {
        projections[hostID] is TmuxConsoleProjection ? .tmuxServerGone : .herdrCoreTerminalGone
    }

    /// What Agent Ended says for `id`, when it has more to say than its plain
    /// words: another core's exit at the address is no word about this Terminal.
    func agentEndedMessage(of id: ConsoleAgent.ID, keepingTo corePin: TerminalCorePin?) -> String? {
        if let message = terminalEndedMessage(keepingTo: corePin, on: id.hostID) { return message }
        // The exit lives in the inventory, which a reconnect empties for a while.
        // Its rows are what say it changed, so the open dialog redraws.
        _ = terminals
        return programExit(of: id)?.code.map(TerminalStatusPresentation.finishedMessage(exitCode:))
    }

    /// Late-bound for the same reason as `terminalRunner(for:)`: a retryable
    /// upload taken before a Host edit must stage over the new session.
    func imageStager(
        for hostID: Host.ID, beside paneID: String, keepingTo corePin: TerminalCorePin
    ) -> ImageStager {
        { [weak self] image, reporter in
            guard let stager = await self?.projections[hostID]?.imageStager(beside: paneID, keepingTo: corePin) else {
                throw TransportError.sshUnreachable(
                    detail: String(localized: "The Host is not connected."))
            }
            return try await stager(image, reporter)
        }
    }

    func fileStager(
        for hostID: Host.ID, beside paneID: String, keepingTo corePin: TerminalCorePin
    ) -> FileStager {
        { [weak self] file, reporter in
            guard let stager = await self?.projections[hostID]?.fileStager(beside: paneID, keepingTo: corePin) else {
                throw TransportError.sshUnreachable(
                    detail: String(localized: "The Host is not connected."))
            }
            return try await stager(file, reporter)
        }
    }

    private func liveTerminalRunner(for hostID: Host.ID) -> TerminalSessionRunner? {
        projections[hostID]?.terminalRunner()
    }

    /// Ranged Host-file reads for the terminal usage strip (#325). Late-bound
    /// for the same reason as `imageStager(for:beside:keepingTo:)`: the strip refreshes on a
    /// timer, and a reconnect between two refreshes must not leave it reading
    /// through the transport that was replaced.
    func sessionFileReader(for hostID: Host.ID) -> SessionFileReader {
        { [weak self] range in
            guard let reader = await self?.liveSessionFileReader(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: String(localized: "The Host is not connected."))
            }
            return try await reader(range)
        }
    }

    private func liveSessionFileReader(for hostID: Host.ID) -> SessionFileReader? {
        projections[hostID]?.sessionFileReader()
    }

    /// Model window lookups for the terminal usage strip (#325), late-bound
    /// like `sessionFileReader(for:)`.
    func modelContextWindowResolver(for hostID: Host.ID) -> ModelContextWindowResolver {
        { [weak self] selector in
            guard let resolver = await self?.liveModelContextWindowResolver(for: hostID) else {
                throw TransportError.sshUnreachable(
                    detail: String(localized: "The Host is not connected."))
            }
            return try await resolver(selector)
        }
    }

    private func liveModelContextWindowResolver(
        for hostID: Host.ID
    ) -> ModelContextWindowResolver? {
        projections[hostID]?.modelContextWindowResolver()
    }

    func workspaces(for hostID: Host.ID) -> [ConsoleWorkspace] {
        workspacesByHost[hostID] ?? []
    }

    /// The projection behind every Host-scoped RPC; an unconnected Host
    /// fails loudly instead of silently dropping the action.
    private func projection(for hostID: Host.ID) throws -> any ConsoleHostProjection {
        guard let projection = projections[hostID] else {
            throw TransportError.sshUnreachable(
                detail: String(localized: "The Host is not connected."))
        }
        return projection
    }

    /// Learns the Host's platform on its current connection, at most once
    /// per connection. A failure keeps the last answer and lets the next
    /// call ask again.
    func resolveHostPlatform(_ hostID: Host.ID) async {
        guard let projection = projections[hostID] else { return }
        let generation = projection.transportGeneration
        guard hostPlatformGenerations[hostID] != generation else { return }
        hostPlatformGenerations[hostID] = generation
        let platform: HostPlatform
        do {
            platform = try await projection.withHostServices { services in
                try await services.hostPlatform()
            }
        } catch {
            if projections[hostID] === projection, hostPlatformGenerations[hostID] == generation {
                hostPlatformGenerations[hostID] = nil
            }
            return
        }
        guard projections[hostID] === projection else { return }
        if hostPlatforms[hostID] != platform {
            hostPlatforms[hostID] = platform
            rebuildCapabilities()
        }
        reconcileChatCache()
        reconcileAgyAnnotationTitles()
    }

    func availableAgentKinds(on hostID: Host.ID) async throws -> [SupportedAgentKind] {
        try await projection(for: hostID).availableAgentKinds()
    }

    func availableTemplates(on hostID: Host.ID) async throws -> [AgentTemplate] {
        try await projection(for: hostID).availableTemplates()
    }

    @discardableResult
    func startTemplate(
        _ request: TemplateLaunchRequest, on hostID: Host.ID
    ) async throws -> Agent {
        try await projection(for: hostID).startTemplate(request)
    }

    /// See `ConsoleHostProjection.launchDirectory(ofWorkspace:asked:)`.
    func launchDirectory(ofWorkspace workspaceID: String, asked: String, on hostID: Host.ID) -> String {
        projections[hostID]?.launchDirectory(ofWorkspace: workspaceID, asked: asked) ?? asked
    }

    /// See `ConsoleHostProjection.programExit(ofPane:)`.
    func programExit(of id: ConsoleAgent.ID) -> ProgramExit? {
        projections[id.hostID]?.programExit(ofPane: id.paneID)
    }

    /// The names a new Agent's generated default keeps clear of on `hostID`.
    func takenAgentNames(on hostID: Host.ID) -> Set<String> {
        Set(agents.filter { $0.hostID == hostID }.compactMap { $0.agent.name })
            .union(projections[hostID]?.heldTerminalNames ?? [])
    }

    /// Resolves the Host's remote home directory for the New Workspace
    /// directory browser (#280). Throws the error's own presentation,
    /// including homeDirectoryUnresolvable when the probe fails.
    func remoteHomeDirectory(on hostID: Host.ID) async throws -> String {
        try await projection(for: hostID).remoteHomeDirectory()
    }

    /// Lists one absolute remote path's subdirectories for the New Workspace
    /// directory browser (#280).
    func listRemoteDirectories(at path: String, on hostID: Host.ID) async throws -> RemoteDirectoryListing {
        try await projection(for: hostID).listRemoteDirectories(at: path)
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
        let skills = try await projection(for: hostID).withHostServices { services in
            try await services.listSkills(query)
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
        try await projection(for: hostID).withHostServices { services in
            try await services.readSkillFile(atPath: path)
        }
    }

    /// Antigravity CLI's model catalog on a Host (`agy models`), cached per
    /// Host connection once non-empty so subsequent agy Chats open the menu
    /// immediately while an unauthenticated or transient empty read retries.
    func fetchAgyModels(on hostID: Host.ID) async throws -> [AgyModelCatalog.Choice] {
        let generation = hostConnectionGenerations[hostID] ?? 0
        if let cached = agyModelsCache[hostID], cached.generation == generation {
            return cached.models
        }
        let models = try await projection(for: hostID).withHostServices { services in
            try await services.listAgyModels()
        }
        if !models.isEmpty {
            agyModelsCache[hostID] = (generation, models)
        }
        return models
    }

    /// Shared across Changes presentations and the Agents list's row reads
    /// for the same Host, including ones for different Agents or windows.
    func gitExecGate(for hostID: Host.ID) -> GitExecGate {
        if let gate = gitExecGates[hostID] { return gate }
        let gate = GitExecGate()
        gitExecGates[hostID] = gate
        return gate
    }

    /// The Changes view's listing for one untracked directory. Uncached, like
    /// the document itself: the expansion lives only in the view's store.
    func listUntrackedDirectory(
        _ request: UntrackedDirectoryRequest, on hostID: Host.ID
    ) async throws -> UntrackedDirectoryListing {
        try await projection(for: hostID).withHostServices { services in
            try await services.listUntrackedDirectory(request)
        }
    }

    /// The Changes view's and the Agents list's data source: one git read
    /// over the Host's live Console connection. Uncached: each document
    /// lives only in the store that asked for it.
    func readChanges(
        _ request: ChangesReadRequest, on hostID: Host.ID
    ) async throws -> CheckoutChangesRead {
        try await projection(for: hostID).withHostServices { services in
            try await services.readChanges(request)
        }
    }

    /// Reads only the open file through the Host's existing connection.
    func readFilePatch(
        _ request: FilePatchRequest, on hostID: Host.ID
    ) async throws -> FilePatch {
        try await projection(for: hostID).withHostServices { services in
            try await services.readFilePatch(request)
        }
    }

    /// Composer's one-shot delivery source. Prompts borrow the Host's current
    /// Console connection rather than dialing a parallel connection or holding
    /// an RPC open for Agent completion.
    func promptAgent(_ params: AgentPromptParams, on hostID: Host.ID) async throws -> Agent {
        try requireNoTitleRename(.init(hostID: hostID, paneID: params.target))
        return try await projection(for: hostID).promptAgent(params)
    }

    /// The Agent's screen as herdr renders it now, colors kept
    /// (`agent.read`). Chat reads it around a send instead of the Attach
    /// PTY, which it never touches.
    func readAgentScreen(
        _ paneID: String, on hostID: Host.ID, keepingTo corePin: TerminalCorePin? = nil
    ) async throws -> ANSIScreen {
        guard !hasLeftCore(corePin, on: hostID) else { throw leftCoreError(on: hostID) }
        return try await projection(for: hostID).readAgentScreen(paneID)
    }

    /// Presses keys in the Agent's program (`agent.send_keys`): a Blocked
    /// card's answers and the Agent controls, never through the Attach PTY.
    func sendAgentKeys(
        _ keys: [String], to paneID: String, on hostID: Host.ID, keepingTo corePin: TerminalCorePin? = nil
    ) async throws {
        try requireNoTitleRename(.init(hostID: hostID, paneID: paneID))
        guard !hasLeftCore(corePin, on: hostID) else {
            throw HerdrCoreChatTyping.Refusal(message: leftCoreError(on: hostID).presentation.message)
        }
        try requireReadyForInput(hostID)
        let currentAgent = (projections[hostID] as? TmuxConsoleProjection)?.agentsByPane[paneID]?.agent
        let declines =
            keys == ["esc"]
            && TmuxConsoleProjection.toolsEscapeDeclines(
                kind: currentAgent?.kind, status: currentAgent?.status ?? .unknown)
        try await projection(for: hostID).sendAgentKeys(keys, to: paneID)
        if declines, !hasLeftCore(corePin, on: hostID),
            let tmux = projections[hostID] as? TmuxConsoleProjection
        {
            _ = await tmux.recordHeelerAnswer(declines: true, on: paneID)
        }
    }

    /// Types one line of text into the Agent's pane (`pane.send_input`): a
    /// Blocked card's note or typed answer.
    func pasteIntoAgent(_ text: String, paneID: String, on hostID: Host.ID) async throws {
        try requireNoTitleRename(.init(hostID: hostID, paneID: paneID))
        try requireReadyForInput(hostID)
        try await projection(for: hostID).pasteIntoAgent(text, paneID: paneID)
    }

    /// Recovery rejects new input rather than holding it for the replacement.
    /// Nothing left Heeler, which a core Host's Chat tells from a key that may have gone.
    private func requireReadyForInput(_ hostID: Host.ID) throws {
        guard isHostReadyForInput(hostID) else {
            if projections[hostID]?.usesProcessBoundChat == true {
                throw HerdrCoreChatTyping.Refusal(message: String(localized: "The Host is not ready."))
            }
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not ready."))
        }
    }

    /// One Composer and staging per selected Agent for the lifetime of its
    /// Host catalog entry. A failed Host's placeholder may replace the Console
    /// detail; retaining the session here keeps its entirely local draft intact.
    func composerSession(for agent: ConsoleAgent) -> AgentComposerSession {
        let hostID = agent.hostID
        // Another core's Agent is another Agent. A detail still open on the old
        // one keeps its own session, which keeps to the old core (`ConsoleDetailCores`).
        if let existing = composerSessions[agent.id] {
            if !hasLeftCore(existing.corePin, on: hostID) { return existing }
            existing.leaveStaging()
        }
        let corePin = self.corePin(on: hostID)
        let checkedSend = projections[hostID]?.checkedComposerSend(
            for: agent.agent.paneID, keepingTo: corePin,
            live: { [weak self] in self?.projections[hostID] })
        let composer = AgentComposerStore(
            target: agent.agent.paneID,
            initialStatus: agent.agent.status,
            statusUpdates: agentStatusUpdates(for: agent.id),
            checkedSend: checkedSend
        ) { [weak self] params in
            guard let self else { throw TransportError.cancelled }
            return try await self.promptAgent(params, on: hostID)
        }
        composer.offersStopWhileBlocked = catalog.first(where: { $0.id == hostID })?.serverKind == .tmux
        composer.isConnectionAvailable = isHostReadyForInput(hostID)
        let paneID = agent.agent.paneID
        let session = AgentComposerSession(
            composer: composer,
            stageImage: imageStager(for: hostID, beside: paneID, keepingTo: corePin),
            stageFile: fileStager(for: hostID, beside: paneID, keepingTo: corePin),
            corePin: corePin,
            saysTransportFailures: projections[hostID]?.stagingSaysTransportFailures == true,
            filePreparer: WindowsCoreFilePreparer(isOnWindows: { [weak self] in
                self?.capabilities(for: hostID).isNativeWindowsCore == true
            }),
            // Weak: the store holds the session, which holds the keys.
            sendAgentKeys: { [weak self] keys in
                guard let self else { throw TransportError.cancelled }
                try await self.sendAgentKeys(keys, to: paneID, on: hostID, keepingTo: corePin)
            })
        composerSessions[agent.id] = session
        requestHostPlatforms(Array(projections.values))
        return session
    }

    /// Whether this Host keeps Program Status on its own tmux socket, so a
    /// decline or another answer from Heeler can write it.
    func recordsHeelerAnswers(on hostID: Host.ID) -> Bool {
        projections[hostID] is TmuxConsoleProjection
    }

    /// Writes idle when `declines`, otherwise working. A Host that does not
    /// record answers writes nothing.
    @discardableResult
    func recordHeelerAnswer(declines: Bool, for agent: ConsoleAgent) async -> TmuxStatusWrite.Outcome {
        guard let tmux = projections[agent.hostID] as? TmuxConsoleProjection else { return .failed }
        return await tmux.recordHeelerAnswer(declines: declines, on: agent.agent.paneID)
    }

    /// The terminal Composer's Stop, or nil to keep Send. A projection that
    /// supplies Stop says whether this Pane gets one. One that does not keeps
    /// Esc, which Grok Build does not take. `pressEsc` is that Esc.
    func terminalInterrupt(
        for agent: ConsoleAgent,
        keepingTo corePin: TerminalCorePin? = nil,
        attach: AgentAttachStore? = nil,
        pressEsc: @escaping @MainActor () async -> AgentInterruptOutcome
    ) -> AgentComposerInterrupt? {
        guard capabilities(for: agent.hostID).composerStop else { return nil }
        let hostID = agent.hostID
        let pin = corePin ?? TerminalCorePin()
        if let tmux = projections[hostID] as? TmuxConsoleProjection {
            return tmux.terminalStop(
                for: agent.agent.paneID, keepingTo: pin, attach: attach,
                live: { [weak self] in self?.projections[hostID] })
        }
        switch projections[hostID]?.checkedTerminalStop(
            for: agent.agent.paneID, keepingTo: pin,
            live: { [weak self] in self?.projections[hostID] }
        ) {
        case .interrupt(let interrupt): return interrupt
        case .keepSend: return nil
        case nil: return .terminal(forAgentKind: agent.agent.kind, pressEsc)
        }
    }

    func composerStore(for agent: ConsoleAgent) -> AgentComposerStore {
        composerSession(for: agent).composer
    }

    /// The live process's opt-in, never a saved transcript or a terminal's launch command.
    func claudePermissionLaunch(
        for agent: ConsoleAgent, corePin: TerminalCorePin
    ) async throws -> ClaudePermissionMode.Launch? {
        let projection = try projection(for: agent.hostID)
        if projection.usesProcessBoundChat {
            guard !hasLeftCore(corePin, on: agent.hostID) else { return nil }
            return try await projection.claudePermissionLaunch(paneID: agent.agent.paneID)
        }
        let info = try await projection.processInfo(paneID: agent.agent.paneID)
        guard let pid = ClaudePermissionMode.processID(in: info) else { return nil }
        let facts = try await projection.withHostServices {
            try await $0.readProcesses(ClaudePermissionMode.request(pid: pid))
        }
        let current = try await projection.processInfo(paneID: agent.agent.paneID)
        guard ClaudePermissionMode.processID(in: current) == pid, let process = facts[pid] else { return nil }
        return ClaudePermissionMode.Launch(pid: pid, facts: process)
    }

    /// The Agent's Chat (ADR 0024), made on first use and kept while the
    /// Agent and its Host entry last. Nil when the Host is not in the
    /// catalog or the program has no transcript adapter.
    func chatStore(for agent: ConsoleAgent, program: ChatProgram) -> AgentChatStore? {
        guard capabilities(for: agent.hostID).offersChat(for: program) else { return nil }
        if let existing = chatStores[agent.id], existing.program == program { return existing }
        guard let hostProjection = projections[agent.hostID], let adapter = chatAdapter(program) else {
            return nil
        }
        let host = hostProjection.host
        let processBound = hostProjection.usesProcessBoundChat ? hostProjection : nil
        if let processBound, processBound.chatCacheScope == nil { return nil }
        chatStores[agent.id]?.end()
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        var source = AgentChatSource(
            hostID: hostID, socketLocation: host.socketLocation,
            files: chatHostFiles(for: hostID),
            agentInfo: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.liveChatAgentInfo(hostID: hostID, paneID: paneID)
            },
            cache: chatCache, adapter: adapter,
            cachedSession: { [weak self] agent in
                guard let self else { return nil }
                return await self.cachedChats.cachedSession(for: agent, on: host)
            },
            processInfo: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.projection(for: hostID).processInfo(paneID: paneID)
            },
            screen: BlockedScreenIO(
                readScreen: { [weak self] in
                    guard let self else { throw TransportError.cancelled }
                    return try await self.readAgentScreen(paneID, on: hostID)
                },
                sendKeys: { [weak self] keys in
                    guard let self else { throw TransportError.cancelled }
                    try await self.sendAgentKeys(keys, to: paneID, on: hostID)
                },
                paste: { [weak self] text in
                    guard let self else { throw TransportError.cancelled }
                    try await self.pasteIntoAgent(text, paneID: paneID, on: hostID)
                }))
        if let typing = hostProjection.checkedChatTyping(at: paneID) {
            source.screen = typing.blockedScreen
        }
        if let processBound {
            // No record names a session here.
            source.processInfo = nil
            source.coreScope = processBound.chatCacheScope
            source.sessionEvidence = { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.checkChatSession(paneID: paneID, program: program, on: hostID)
            }
            source.picks = chatPicks(paneID: paneID, program: program, on: hostID, scope: processBound.chatCacheScope)
            // Only events after this store exists are news to it.
            chatSessionEventRevisions[agent.id] = processBound.sessionEventRevision(of: paneID)
        }
        if program == .agy {
            source.onAgyConversationBound = { [weak self] root, rootID in
                guard let self, let projection = self.projections[hostID],
                    let current = projection.agentsByPane[paneID] ?? projection.departedAgentsByPane[paneID]
                else { return }
                self.agyTitles.noteChatBinding(
                    for: agent.id, agent: current.agent,
                    generation: projection.transportGeneration,
                    root: root, rootID: rootID)
                self.reconcileAgyAnnotationTitles()
            }
        }
        let store = AgentChatStore(
            agentID: agent.id, agent: agent.agent, program: program, source: source, timing: chatTiming, now: chatNow)
        if !isActive { store.suspend() }
        chatStores[agent.id] = store
        return store
    }

    /// Chat's Stop for this Agent (ADR 0024). On a herdr-core Template's Terminal
    /// it presses the Template's stop key (ADR 0035).
    func chatStopPlan(for agent: ConsoleAgent, program: ChatProgram) -> ChatStopPlan {
        let plan = ChatStopPlan.standard(for: program)
        guard let core = projections[agent.hostID] as? HerdrCoreConsoleProjection,
            let stopKey = core.terminalRecord(at: agent.agent.paneID)?.stop
        else { return plan }
        return plan.pressing(templateStopKey: stopKey)
    }

    /// Chat's Stop interrupt for this Agent, keeping to `corePin`.
    func chatInterrupt(
        for agent: ConsoleAgent,
        program: ChatProgram,
        keepingTo corePin: TerminalCorePin,
        context: @escaping @MainActor () async throws -> ChatStopContext,
        agentKeys: ChatAgentKeysStore,
        followThrough: (@MainActor () -> ChatStopFollowThrough?)? = nil
    ) -> AgentComposerInterrupt {
        let hostID = agent.hostID
        if let stop = projections[hostID]?.checkedChatStop(
            for: agent.agent.paneID,
            program: program,
            keepingTo: corePin,
            agentKeys: agentKeys,
            followThrough: followThrough,
            live: { [weak self] in self?.projections[hostID] })
        {
            return stop
        }
        return chatStopPlan(for: agent, program: program).composerInterrupt(
            context: context, agentKeys: agentKeys, followThrough: followThrough)
    }

    /// A confirmation is an action a detail takes on an address, so it keeps to the
    /// detail's core (ADR 0031).
    private func chatPicks(paneID: String, program: ChatProgram, on hostID: Host.ID, scope: String?) -> ChatPickIO {
        ChatPickIO(
            list: { [weak self] pin in
                guard let self, let projection = self.projections[hostID], projection.usesProcessBoundChat else {
                    throw TransportError.cancelled
                }
                guard !self.hasLeftCore(pin, on: hostID) else { throw self.leftCoreError(on: hostID) }
                return try await projection.chatCandidates(paneID: paneID, program: program)
            },
            confirm: { [weak self] candidate, list, pin in
                guard let self, let projection = self.projections[hostID], projection.usesProcessBoundChat else {
                    throw TransportError.cancelled
                }
                guard !self.hasLeftCore(pin, on: hostID) else { throw self.leftCoreError(on: hostID) }
                try await projection.writeChatPick(candidate, of: list, paneID: paneID)
            },
            drop: { [weak self] in
                guard let projection = self?.projections[hostID], projection.usesProcessBoundChat else { return }
                projection.dropChatPick(paneID: paneID, scope: scope, program: program)
            },
            cannotTell: { [weak self] in
                guard let projection = self?.projections[hostID], projection.usesProcessBoundChat else {
                    return .cannotTellSession(program)
                }
                return projection.chatCannotTell(program)
            })
    }

    private func checkChatSession(
        paneID: String, program: ChatProgram, on hostID: Host.ID
    ) async throws -> ChatSessionEvidence {
        guard let projection = projections[hostID], projection.usesProcessBoundChat else {
            throw TransportError.cancelled
        }
        return try await projection.checkChatSession(paneID: paneID, program: program)
    }

    /// Chat's transcript reads and store queries on the Host's live
    /// connection, resolved on every call like `sessionFileReader(for:)`.
    func chatHostFiles(for hostID: Host.ID) -> ChatHostFiles {
        ChatHostFiles(
            status: { [weak self] path in
                guard let self else { throw TransportError.cancelled }
                return try await liveChatHostFiles(for: hostID).status(path)
            },
            list: { [weak self] request in
                guard let self else { throw TransportError.cancelled }
                return try await liveChatHostFiles(for: hostID).list(request)
            },
            read: { [weak self] range in
                guard let self else { throw TransportError.cancelled }
                return try await liveChatHostFiles(for: hostID).read(range)
            },
            home: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await liveChatHostFiles(for: hostID).home()
            },
            queryOpenCode: { [weak self] query in
                guard let self else { throw TransportError.cancelled }
                guard let queryOpenCode = try await liveChatHostFiles(for: hostID).queryOpenCode else {
                    throw TransportError.hostFeatureUnavailable(feature: String(localized: "Chat"))
                }
                return try await queryOpenCode(query)
            },
            accountDirectories: { [weak self] kind in
                guard let self else { throw TransportError.cancelled }
                return try await liveChatHostFiles(for: hostID).accountDirectories(kind)
            })
    }

    private func liveChatHostFiles(for hostID: Host.ID) throws -> ChatHostFiles {
        try projection(for: hostID).chatHostFiles()
    }

    private func liveChatAgentInfo(hostID: Host.ID, paneID: String) async throws -> Agent {
        let origin = try projection(for: hostID)
        let generation = origin.transportGeneration
        let snapshot = origin.agentsByPane[paneID]
        let fresh = try await origin.agentInfo(paneID: paneID)
        guard projections[hostID] === origin, origin.transportGeneration == generation,
            !origin.isAwaitingSnapshot else { throw TransportError.cancelled }
        let enriched = await readAgyTitleForRename(
            fresh: fresh, paneID: paneID, hostID: hostID, generation: generation)
        guard projections[hostID] === origin, origin.transportGeneration == generation,
            !origin.isAwaitingSnapshot else { throw TransportError.cancelled }
        if hostPlatforms[hostID] == .posix, let snapshot,
            origin.agentsByPane[paneID]?.agent.agentSession == snapshot.agent.agentSession,
            origin.agentsByPane[paneID]?.agent.terminalID == snapshot.agent.terminalID,
            origin.agentsByPane[paneID]?.agent.workspaceID == snapshot.agent.workspaceID,
            origin.agentsByPane[paneID]?.agent.tabID == snapshot.agent.tabID {
            cachedChats.confirm(enriched, for: snapshot, on: origin.host)
        }
        return enriched
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

    func refreshTerminalInventory(on hostID: Host.ID) async {
        await projections[hostID]?.refreshTerminalInventory()
        agyTitles.bumpRefreshEpoch(for: hostID)
        reconcileAgyAnnotationTitles()
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest,
        on hostID: Host.ID
    ) async throws -> ShellTerminalIdentity {
        try await projection(for: hostID).createShellTerminal(request)
    }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?, on hostID: Host.ID
    ) async throws -> ShellTerminalIdentity {
        try await projection(for: hostID).createShellWorkspace(workspace, tabLabel: tabLabel)
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

    /// Suspends until `id` is reported by its Host's sync machinery, its program
    /// has ended for good, or the timeout elapses. The new-agent flow (#12) opens the started Agent's
    /// terminal, and the row it navigates to exists only once the post-start
    /// resync lands — waiting keeps the detail column from flashing its
    /// missing-Agent placeholder over a launch that just succeeded.
    func waitForAgent(_ id: ConsoleAgent.ID, timeout: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !agents.contains(where: { $0.id == id }), programExit(of: id) == nil {
            guard clock.now < deadline,
                (try? await Task.sleep(for: .milliseconds(50))) != nil
            else { return }
        }
    }

    /// Suspends until a shell created on `hostID` is in the terminal
    /// inventory, or the timeout elapses; nil then. Creation already
    /// refreshes the inventory, so this only covers a snapshot that lands
    /// late, which would otherwise open a terminal with no row behind it.
    func waitForTerminal(
        _ identity: ShellTerminalIdentity, on hostID: Host.ID,
        timeout: Duration = .seconds(5)
    ) async -> ConsoleTerminal? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let terminal = terminals.first(where: {
                $0.hostID == hostID && $0.terminalID == identity.terminalID
            }) {
                return terminal
            }
            guard clock.now < deadline,
                (try? await Task.sleep(for: .milliseconds(50))) != nil
            else { return nil }
        }
    }

    /// `corePin` is a detail's: a row acts on the inventory it came from.
    func closePane(
        _ paneID: String, on hostID: Host.ID, keepingTo corePin: TerminalCorePin? = nil
    ) async throws {
        guard !hasLeftCore(corePin, on: hostID) else { throw leftCoreError(on: hostID) }
        try await projection(for: hostID).closePane(paneID)
    }

    /// Whether the Console row's close takes the Agent's whole tab: only
    /// when its pane is the tab's last one. Beside other panes (shells
    /// count), only the Agent's own pane closes.
    func closesTab(of agent: ConsoleAgent) -> Bool {
        agent.tabPaneCount <= 1
    }

    /// Whether the Console row's close also closes the Workspace: it takes
    /// the whole tab and that tab is the workspace's last one (shell tabs
    /// count), which herdr turns into a workspace close.
    func closesWorkspaceWithTab(of agent: ConsoleAgent) -> Bool {
        closesTab(of: agent) && agent.workspaceTabCount <= 1
    }

    /// Closes the Agent from its Console row's swipe action: its pane when
    /// the tab holds others, otherwise the whole tab. Every agent on the
    /// Host that closes with it loses its pin — a deliberate close must not
    /// leave a pin that would re-pin a herdr-reused id. The projection's
    /// resync refreshes the list.
    func closeAgent(_ agent: ConsoleAgent) async throws {
        let hostID = agent.hostID
        guard closesTab(of: agent) else {
            let paneID = agent.agent.paneID
            try await projection(for: hostID).closePane(paneID)
            pins.removePin(hostID: hostID, paneID: paneID)
            rebuild()
            return
        }
        let tabID = agent.agent.tabID
        let pinnedPaneIDs = agents
            .filter { $0.hostID == hostID && $0.agent.tabID == tabID }
            .map(\.agent.paneID)
            .filter { pins.isPinned(hostID: hostID, paneID: $0) }
        try await projection(for: hostID).closeTab(tabID)
        for paneID in pinnedPaneIDs {
            pins.removePin(hostID: hostID, paneID: paneID)
        }
        rebuild()
    }

    /// What a Close Agent dialog opened now asks for.
    func closeRequest(for id: ConsoleAgent.ID) -> AgentCloseRequest {
        isSavedChat(id) ? .removeSavedChat : .closeAgent
    }

    /// Removes a saved Chat entry from this device, which needs no Host and
    /// never asks one to close anything. False, with nothing changed, once
    /// the entry is no longer saved: a Host that connected behind the
    /// confirmation lists the live Agent, which only `closeAgent` closes.
    @discardableResult
    func removeSavedChat(_ agent: ConsoleAgent) -> Bool {
        guard isSavedChat(agent.id), let host = projections[agent.hostID]?.host else { return false }
        chatStores.removeValue(forKey: agent.id)?.end()
        cachedChats.remove(paneID: agent.agent.paneID, on: host)
        pins.removePin(hostID: agent.hostID, paneID: agent.agent.paneID)
        rebuild()
        return true
    }

    /// Whether a Terminals row's close takes the shell's whole tab: only when
    /// no other pane, Agent or shell, shares it.
    func closesTab(of terminal: ConsoleTerminal) -> Bool {
        Self.closesTab(of: terminal, terminals: terminals, agents: agents)
    }

    /// Whether that close also ends the Workspace: herdr closes a Workspace
    /// with its last tab.
    func closesWorkspaceWithTab(of terminal: ConsoleTerminal) -> Bool {
        Self.closesWorkspaceWithTab(of: terminal, terminals: terminals, agents: agents)
    }

    nonisolated static func closesTab(
        of terminal: ConsoleTerminal, terminals: [ConsoleTerminal], agents: [ConsoleAgent]
    ) -> Bool {
        let panes = Set(
            terminals.filter { $0.hostID == terminal.hostID && $0.tabID == terminal.tabID }
                .map(\.paneID)
                + agents.filter { $0.hostID == terminal.hostID && $0.agent.tabID == terminal.tabID }
                .map(\.agent.paneID))
        return panes.subtracting([terminal.paneID]).isEmpty
    }

    nonisolated static func closesWorkspaceWithTab(
        of terminal: ConsoleTerminal, terminals: [ConsoleTerminal], agents: [ConsoleAgent]
    ) -> Bool {
        guard closesTab(of: terminal, terminals: terminals, agents: agents) else { return false }
        let tabs = Set(
            terminals.filter {
                $0.hostID == terminal.hostID && $0.workspaceID == terminal.workspaceID
            }.map(\.tabID)
                + agents.filter {
                    $0.hostID == terminal.hostID && $0.agent.workspaceID == terminal.workspaceID
                }.map(\.agent.tabID))
        return tabs.subtracting([terminal.tabID]).isEmpty
    }

    /// Closes a shell from its Terminals row: its pane beside others, else
    /// its tab. A retained connection to it is dropped rather than left to
    /// expire against a pane that no longer exists.
    func closeTerminal(_ terminal: ConsoleTerminal) async throws {
        let projection = try projection(for: terminal.hostID)
        if closesTab(of: terminal) {
            try await projection.closeTab(terminal.tabID)
        } else {
            try await projection.closePane(terminal.paneID)
        }
        await terminalConnections.remove(
            hostID: terminal.hostID,
            identity: ShellTerminalIdentity(
                paneID: terminal.paneID, tabID: terminal.tabID, terminalID: terminal.terminalID))
    }

    /// A close nobody answered may have happened, so it is left to the user to
    /// check, and nothing sends it again.
    static let closeUnconfirmedMessage =
        String(localized: "The Host did not confirm the close. The Terminal may already have ended, so check it before trying again.")

    /// User-facing copy for a failed `tab.close`. `TransportError` is not a
    /// `LocalizedError`, so `localizedDescription` would read as an opaque
    /// Foundation code; mirror the rename path's mapping instead.
    static func tabCloseFailureMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        case TransportError.timedOut:
            String(localized: "The Host did not answer in time.")
        case TransportError.coreMutationOutcomeUnknown:
            closeUnconfirmedMessage
        case let refusal as HerdrCoreCloseRefusal:
            String(localized: "herdr-core rejected the close: \(refusal.message)")
        case let apiError as HerdrAPIError:
            String(localized: "herdr rejected the close: \(apiError.message)")
        case TransportError.apiRejected(_, let message):
            String(localized: "herdr rejected the close: \(message)")
        default:
            TransportError.herdrCoreLinkMessage(for: error)
                ?? String(localized: "Closing failed: \(String(describing: error))")
        }
    }

    func listWorktrees(
        forWorkspaceID workspaceID: String, on hostID: Host.ID
    ) async throws -> WorktreeListResponse {
        try await projection(for: hostID).listWorktrees(forWorkspaceID: workspaceID)
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest, on hostID: Host.ID, keepingTo corePin: TerminalCorePin? = nil
    ) async throws -> WorktreeRemovalReceipt {
        guard !hasLeftCore(corePin, on: hostID) else { throw leftCoreError(on: hostID) }
        return try await projection(for: hostID).removeWorktree(request)
    }

    /// Where a core Host's close or removal says how it ended once the screen that
    /// asked has gone. Nil on a Herdr TUI Host, whose screens stay as they were.
    func outcomeReporter(on hostID: Host.ID, title: String) -> ((String) -> Void)? {
        guard catalog.contains(where: { $0.id == hostID && $0.serverKind == .herdrCore }) else {
            return nil
        }
        return { [weak self] message in
            self?.outcomeNotices.append(ConsoleOutcomeNotice(title: title, message: message))
        }
    }

    func dismissOutcomeNotice(_ notice: ConsoleOutcomeNotice) {
        outcomeNotices.removeAll { $0.id == notice.id }
    }

    /// The other Workspaces on this Worktree's checkout. Removing it ends only its
    /// own Workspace (ADR 0032), so the confirmation names these.
    func workspaceLabels(sharingCheckoutOf identity: WorktreeIdentity) -> [String] {
        workspaces(for: identity.hostID)
            .filter { $0.id != identity.workspaceID && $0.checkoutPath == identity.checkoutPath }
            .map(\.label)
    }

    func worktreeRemovalRisk(
        _ request: WorktreeRemovalRequest, on hostID: Host.ID
    ) async throws -> WorktreeRemovalRisk? {
        try await projection(for: hostID).worktreeRemovalRisk(request)
    }

    func focusAgent(_ paneID: String, on hostID: Host.ID) async throws {
        try await projection(for: hostID).focusAgent(paneID)
    }

    /// Which Agent one Agent detail shows now, nil once it shows none. On a core
    /// Host this is what Done per device reads: a shown Agent's turns are seen as
    /// they end, whichever window shows it.
    func setAgentShown(_ agent: ConsoleAgent.ID?, viewer: UUID, scene: UUID?) {
        // A window that ended may still run a late update.
        let shown = scene.map(endedScenes.contains) == true ? nil : agent
        let previous = agentViewers[viewer]?.agent
        guard previous != shown else { return }
        agentViewers[viewer] = shown.map { AgentViewer(agent: $0, scene: scene) }
        for hostID in Set([previous?.hostID, shown?.hostID].compactMap(\.self)) {
            projections[hostID]?.setShownAgents(shownAgents(on: hostID))
        }
    }

    private func shownAgents(on hostID: Host.ID) -> Set<String> {
        Set(agentViewers.values.lazy.filter { $0.agent.hostID == hostID }.map(\.agent.paneID))
    }

    private var titleRenamesInFlight: Set<ConsoleAgent.ID> = []

    private func requireNoTitleRename(_ id: ConsoleAgent.ID) throws {
        guard !titleRenamesInFlight.contains(id) else {
            throw AgentTitleRenameError(message: String(localized: "Wait for the title rename to finish before sending input."))
        }
    }

    func offersTitleRename(for agent: ConsoleAgent) -> Bool {
        capabilities(for: agent.hostID).renameAgent
            && ChatProgram(rawValue: agent.agent.kind).map(AgentTitleNaming.supportsRename) == true
    }

    func titleRenameStore(for agent: ConsoleAgent) -> AgentTitleRenameStore? {
        guard offersTitleRename(for: agent), let program = ChatProgram(rawValue: agent.agent.kind),
            let origin = try? projection(for: agent.hostID) else { return nil }
        let generation = origin.transportGeneration
        func connection() throws -> any ConsoleHostProjection {
            try requireReadyForInput(agent.hostID)
            let current = try projection(for: agent.hostID)
            guard current === origin, current.transportGeneration == generation else {
                throw AgentTitleRenameError(message: String(localized: "The Host connection changed. Reopen Rename."))
            }
            return current
        }
        var seeded = agyTitles.applying(to: agent).agent
        if agyTitles.isKnownUntitled(for: agent) {
            seeded = seeded.clearingUntrackedConversationTitle()
        }
        return AgentTitleRenameStore(
            agent: seeded, program: program,
            io: AgentTitleRenameIO(
                agent: { [weak self] in
                    guard let self else { throw TransportError.cancelled }
                    let current = try connection()
                    let fresh = try await current.agentInfo(paneID: agent.agent.paneID)
                    return await self.readAgyTitleForRename(
                        fresh: fresh, paneID: agent.agent.paneID,
                        hostID: agent.hostID, generation: generation)
                },
                screen: { try await connection().readAgentScreen(agent.agent.paneID) },
                prompt: { text in
                    _ = try await connection().promptAgent(AgentPromptParams(
                        target: agent.agent.paneID, text: text))
                },
                keys: { try await connection().sendAgentKeys($0, to: agent.agent.paneID) },
                paste: { try await connection().pasteIntoAgent($0, paneID: agent.agent.paneID) },
                refresh: { [weak self] in
                    self?.agyTitles.bumpRefreshEpoch(for: agent.hostID)
                    self?.reconcileAgyAnnotationTitles()
                    await origin.refreshSidebarMetadata()
                },
                initialTitle: program == .agy ? { [weak self] in
                    guard let self, let current = try? connection() else { return nil }
                    guard let fresh = try? await current.agentInfo(paneID: agent.agent.paneID) else {
                        return nil
                    }
                    let updated = await self.readAgyTitleForRename(
                        fresh: fresh, paneID: agent.agent.paneID,
                        hostID: agent.hostID, generation: generation)
                    return AgentTitleNaming.title(of: updated, program: .agy)
                } : nil,
                acquire: { self.titleRenamesInFlight.insert(agent.id).inserted },
                release: { self.titleRenamesInFlight.remove(agent.id) }))
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

    /// Asks a core Host whether its desktop app is running now, for a surface
    /// about to offer a name.
    func checkDesktopApp(on hostID: Host.ID) async {
        await (projections[hostID] as? HerdrCoreConsoleProjection)?.checkDesktopApp()
    }

    /// What New Agent offers a core Host waits on its platform (Worktrees) and
    /// its desktop app (names), so the form asks for both as it opens.
    func checkNewAgentOffers(on hostID: Host.ID) async {
        guard projections[hostID] is HerdrCoreConsoleProjection else { return }
        await resolveHostPlatform(hostID)
        await checkDesktopApp(on: hostID)
    }

    /// Each Server Kind has its own projection, behind one seam (ADR 0032).
    private func startProjection(for host: Host) {
        let onChange: @MainActor @Sendable () -> Void = { [weak self] in self?.rebuild() }
        let projection: any ConsoleHostProjection =
            if let makeProjection {
                makeProjection(host)
            } else {
                switch host.serverKind {
                case .herdrCore:
                    HerdrCoreConsoleProjection(
                        host: host, session: makeCoreSession(host), memory: coreHostMemory, pins: pins,
                        gitGate: gitExecGate(for: host.id), herdrAppRename: herdrAppRename,
                        chatTypingClock: coreSendClock,
                        isNativeWindows: { [weak self] in
                            self?.capabilities(for: host.id).isNativeWindowsCore == true
                        },
                        stopClock: coreStopClock,
                        onSeenMarksChanged: { [weak self, id = host.id] core, marks in
                            self?.onCoreSeenMarksChanged?(id, core, marks)
                        },
                        onChange: onChange)
                case .tmux:
                    TmuxConsoleProjection(
                        host: host, session: makeTmuxSession(host), memory: coreHostMemory, pins: pins,
                        gitGate: gitExecGate(for: host.id),
                        sendClock: coreSendClock,
                        onPathsResolved: { [weak self, id = host.id] paths in
                            self?.onTmuxPathsResolved?(id, paths)
                        },
                        onSeenMarksChanged: { [weak self, id = host.id] core, marks in
                            self?.onCoreSeenMarksChanged?(id, core, marks)
                        },
                        onChange: onChange)
                case .herdrTUI, .unconfirmed:
                    HostConsoleProjection(
                        host: host,
                        session: makeSession(host, HostConsoleProjection.subscriptions(paneIDs: [])),
                        snapshotRetryDelay: snapshotRetryDelay,
                        onChange: onChange)
                }
            }
        projections[host.id] = projection
        projection.setShownAgents(shownAgents(on: host.id))
        projection.start(isActive: isActive)
    }

    private func rebuild() {
        let span = PerfTrace.begin("console.rebuild")
        defer { PerfTrace.end(span) }
        let current = Array(projections.values)
        let nextCoreKernels = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.kernel.map { (projection.host.id, $0) }
            })
        if hostCoreKernels != nextCoreKernels { hostCoreKernels = nextCoreKernels }
        let nextCores = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.inventoryCore.map { (projection.host.id, $0) }
            })
        if hostCores != nextCores { hostCores = nextCores }
        reconcileTerminalConnections(current)
        requestHostPlatforms(current)
        // A configured Host without a session update is awaiting its first
        // activation, not gone. Publish that pending connection to every
        // surface, including the list and saved Chat banners. Removed Hosts
        // have no projection; explicit ended and suspended states stay intact.
        let previousStatuses = hostStatuses
        let nextStatuses = Dictionary(
            uniqueKeysWithValues: current.map { projection in
                (projection.host.id, projection.status ?? .connecting)
            })
        if hostStatuses != nextStatuses { hostStatuses = nextStatuses }
        for (id, store) in agentUsageStores
        where nextStatuses[id] == .connected && previousStatuses[id] != .connected {
            store.connectionBecameUsable()
        }
        // A Host the widgets have no figures for names why: connected or not.
        if nextStatuses.mapValues({ $0 == .connected }) != previousStatuses.mapValues({ $0 == .connected }) {
            publishUsageWidgets()
            refreshStaleWidgetUsage()
        }
        let nextStandingFailures = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.standingFailure.map { (projection.host.id, $0) }
            })
        if hostStandingFailures != nextStandingFailures {
            hostStandingFailures = nextStandingFailures
        }
        let nextLatencies = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.latency.map { (projection.host.id, $0) }
            })
        if hostLatencies != nextLatencies { hostLatencies = nextLatencies }
        let nextCheckingConnection = Set(current.filter(\.isCheckingConnection).map(\.host.id))
        if hostsCheckingConnection != nextCheckingConnection {
            hostsCheckingConnection = nextCheckingConnection
        }
        let nextRouteIDs = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.routeID.map { (projection.host.id, $0) }
            })
        if hostRouteIDs != nextRouteIDs { hostRouteIDs = nextRouteIDs }
        let nextSyncErrors = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                projection.syncError.map { (projection.host.id, $0) }
            })
        if hostSyncErrors != nextSyncErrors { hostSyncErrors = nextSyncErrors }
        let nextEnvironmentNotices = Dictionary(
            uniqueKeysWithValues: current.compactMap { projection in
                HerdrCoreEnvironmentNotice(names: projection.leakedEnvironmentNames)
                    .map { (projection.host.id, $0) }
            })
        if hostCoreEnvironmentNotices != nextEnvironmentNotices {
            hostCoreEnvironmentNotices = nextEnvironmentNotices
        }
        let nextExplanations = Dictionary(
            uniqueKeysWithValues: current.lazy.flatMap { projection in
                projection.statusExplanations.map {
                    (ConsoleAgent.ID(hostID: projection.host.id, paneID: $0.key), $0.value)
                }
            })
        if coreStatusExplanations != nextExplanations {
            coreStatusExplanations = nextExplanations
        }
        let nextDesktopAppNaming = Dictionary(
            uniqueKeysWithValues: current.lazy.compactMap { $0 as? HerdrCoreConsoleProjection }
                .compactMap { projection in
                    projection.desktopAppNaming.map { (projection.host.id, $0) }
                })
        if hostDesktopAppNaming != nextDesktopAppNaming {
            hostDesktopAppNaming = nextDesktopAppNaming
        }
        let nextGenerations = Dictionary(
            uniqueKeysWithValues: current.map {
                ($0.host.id, $0.transportGeneration)
            })
        if hostConnectionGenerations != nextGenerations {
            hostConnectionGenerations = nextGenerations
        }
        let nextAwaitingSnapshot = Set(
            current.lazy.filter(\.isAwaitingSnapshot).map(\.host.id))
        if hostsAwaitingSnapshot != nextAwaitingSnapshot {
            hostsAwaitingSnapshot = nextAwaitingSnapshot
        }
        let nextAwaitingFreshSnapshot = Set(
            current.lazy.filter(\.isAwaitingFreshSnapshot).map(\.host.id))
        if hostsAwaitingFreshSnapshot != nextAwaitingFreshSnapshot {
            hostsAwaitingFreshSnapshot = nextAwaitingFreshSnapshot
        }
        rebuildCapabilities()
        rebuildHostIssues()
        for (id, session) in composerSessions {
            session.composer.isConnectionAvailable = isHostReadyForInput(id.hostID)
        }
        for entry in agentTerminals.entries.values {
            entry.attach.input.isEnabled = isHostReadyForInput(entry.agentID.hostID)
        }
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
            guard projection.host.capabilities.syncLayoutFromPlugin, isActive,
                projection.status == .connected, !projection.isAwaitingSnapshot,
                let generation = hostConnectionGenerations[projection.host.id]
            else { return nil }
            return (projection.host.id, HerdrSidebarSnapshotStore.Connection(
                generation: generation, revision: projection.sidebarRevision))
        })
        sidebarSnapshots.reconcile(sidebarConnections, transports: self) { [weak self] in
            self?.rebuildAgentOrder()
        }
        let nextTerminals = current.flatMap { $0.terminalsByPane.values }.sorted { lhs, rhs in
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID { return lhs.hostID.uuidString < rhs.hostID.uuidString }
            if lhs.workspaceOrder != rhs.workspaceOrder {
                return lhs.workspaceOrder < rhs.workspaceOrder
            }
            if lhs.tabPosition != rhs.tabPosition {
                return (lhs.tabPosition ?? Int.max) < (rhs.tabPosition ?? Int.max)
            }
            if lhs.snapshotOrder != rhs.snapshotOrder {
                return lhs.snapshotOrder < rhs.snapshotOrder
            }
            return lhs.paneID < rhs.paneID
        }
        if terminals != nextTerminals { terminals = nextTerminals }
        // Ahead of the Agents: a detail must never find its Agent in neither.
        let nextDeparted = current.flatMap { $0.departedAgentsByPane.values }
            .map { agyTitles.applying(to: $0) }
            .sorted { ($0.hostID.uuidString, $0.agent.paneID) < ($1.hostID.uuidString, $1.agent.paneID) }
        if departedAgents != nextDeparted { departedAgents = nextDeparted }
        rebuildAgentOrder()
        publishAgentStatuses()
        publishChatAgents()
        reconcileChatCache()
        reconcileAgyAnnotationTitles()
        // A reconnecting Host's empty projection is not proof its Agents
        // exited, so their row totals stay until its snapshot says so.
        let liveAgents = Set(agents.map(\.id))
        let awaiting = hostsAwaitingSnapshot
        rowChanges.retain { liveAgents.contains($0) || awaiting.contains($0.hostID) }
    }

    private func reconcileTerminalConnections(_ current: [any ConsoleHostProjection]) {
        for projection in current {
            let hostID = projection.host.id
            let generation = projection.transportGeneration
            if terminalTransportGenerations[hostID] != generation {
                terminalTransportGenerations[hostID] = generation
                Task { [weak self, weak projection] in
                    guard let self, let projection, projections[hostID] === projection,
                        projection.transportGeneration == generation
                    else { return }
                    let isCurrent: @MainActor () -> Bool = { [weak self, weak projection] in
                        guard let self, let projection else { return false }
                        return projections[hostID] === projection
                            && projection.transportGeneration == generation
                    }
                    await terminalConnections.transportGenerationDidChange(
                        generation, for: hostID, isCurrent: isCurrent)
                    await agentTerminals.transportGenerationDidChange(
                        generation, for: hostID, isCurrent: isCurrent)
                }
            }
            guard !projection.isAwaitingSnapshot,
                projection.status == .connected,
                terminalSnapshotRevisions[hostID] != projection.sidebarRevision
            else { continue }
            terminalSnapshotRevisions[hostID] = projection.sidebarRevision
            let identities = Set(
                projection.terminalsByPane.values.filter { !$0.isAgent }.map {
                    ShellTerminalIdentity(
                        paneID: $0.paneID, tabID: $0.tabID, terminalID: $0.terminalID)
                })
            let revision = projection.sidebarRevision
            // Only a tmux Host can restart its server on the same SSH connection and
            // reuse an address such as `%0` without bumping `transportGeneration`.
            let tmuxServerInstance = projection.host.serverKind == .tmux ? projection.inventoryCore : nil
            // A detail stays on a departed Agent, and so does its terminal.
            let agents = Array(projection.agentsByPane.values)
                + Array(projection.departedAgentsByPane.values)
            let isCurrent: @MainActor () -> Bool = { [weak self, weak projection] in
                guard let self, let projection else { return false }
                return projections[hostID] === projection && !projection.isAwaitingSnapshot
                    && projection.status == .connected && projection.sidebarRevision == revision
            }
            Task {
                await terminalConnections.reconcile(
                    hostID: hostID, identities: identities, tmuxServerInstance: tmuxServerInstance,
                    isCurrent: isCurrent)
                await agentTerminals.reconcile(
                    hostID: hostID, agents: agents, tmuxServerInstance: tmuxServerInstance, isCurrent: isCurrent)
            }
        }
    }

    /// Chat needs each Host's platform before it can offer itself. Asking as
    /// soon as a connection lists a Claude or Codex Agent means a detail
    /// opening on Chat rarely has to show the terminal first. The answer is
    /// usually already known to the transport, which learned it connecting.
    /// A core Host's Add needs it too, once an Agent has a Composer to show it.
    private func requestHostPlatforms(_ current: [any ConsoleHostProjection]) {
        for projection in current
        where projection.status == .connected && !projection.isAwaitingSnapshot {
            let hostID = projection.host.id
            guard hostPlatformGenerations[hostID] != projection.transportGeneration,
                mayOfferChat(on: projection)
                    || (projection.host.serverKind == .herdrCore
                        && (herdrAppRename || composerSessions.keys.contains { $0.hostID == hostID }))
            else { continue }
            Task { [weak self] in await self?.resolveHostPlatform(hostID) }
        }
    }

    private func mayOfferChat(on projection: any ConsoleHostProjection) -> Bool {
        projection.host.capabilities.chat
            && projection.agentsByPane.values.contains(where: {
                AgentChatAvailability.mayOfferChat(for: $0.agent, hasAdapter: { chatAdapter($0) != nil })
            })
    }

    /// All current terminal Panes, including Agents, across the Workspace's Tabs.
    func terminals(on hostID: Host.ID, workspaceID: String) -> [ConsoleTerminal] {
        terminals.filter { $0.hostID == hostID && $0.workspaceID == workspaceID }
    }

    func rowLayout(for hostID: Host.ID) -> AgentRowLayout {
        rowLayouts.resolvedLayout(
            for: hostID, pluginSnapshot: sidebarSnapshots.snapshot(for: hostID),
            followsPlugin: coreHost(hostID) == nil)
    }

    /// The fields this Host's Live Activity carries. Label fields are only for
    /// a core Host, whose Helper reads them: a Herdr TUI Host has no label to
    /// show, and plugin 0.8.0 reads a field it does not know as a malformed
    /// layout, which costs that Host all of its Live Activity rows.
    func liveActivityRowLayout(for hostID: Host.ID) -> AgentRowLayout {
        let layout = rowLayout(for: hostID)
        return coreHost(hostID) == nil ? layout.droppingTerminalLabels() : layout
    }

    /// The labels on the Host's Terminals right now, offered as row fields.
    func terminalLabelKeys(on hostID: Host.ID) -> [String] {
        projections[hostID]?.terminalLabelKeys ?? []
    }

    func refreshSidebarLayouts() async {
        let current = Array(projections.values)
        await withTaskGroup(of: Void.self) { group in
            for projection in current {
                group.addTask { await projection.refreshSidebarMetadata() }
            }
        }
        agyTitles.bumpRefreshEpoch()
        reconcileAgyAnnotationTitles()
        await sidebarSnapshots.refresh(transports: self) { [weak self] in
            self?.rebuildAgentOrder()
        }
    }

    func agentUsageStore(for hostID: Host.ID) -> AgentUsageStore {
        if let store = agentUsageStores[hostID] { return store }
        let store = AgentUsageStore(hostID: hostID, reader: .init { [weak self] timeZone, claudeLimits in
            guard let self else { throw TransportError.cancelled }
            if let host = self.coreHost(hostID) {
                return try await self.withCoreConnection(host) { transport in
                    try await AgentUsageStore.reading(
                        overHelper: transport.hostHelperHost, session: host.sessionName,
                        timeZone: timeZone, claudeLimits: claudeLimits)
                }
            }
            if let host = self.tmuxHost(hostID) {
                return try await self.withTmuxConnection(host) { transport in
                    try await AgentUsageStore.reading(
                        overHelper: transport.hostHelperHost, tmuxSocket: host.tmuxSocketName,
                        tmuxPaths: host.storedTmuxPaths, timeZone: timeZone, claudeLimits: claudeLimits)
                }
            }
            return try await self.withNotificationTransport(for: hostID) { transport in
                try await AgentUsageStore.reading(
                    over: transport, timeZone: timeZone, claudeLimits: claudeLimits)
            }
        })
        store.didChange = { [weak self] in self?.publishUsageWidgets() }
        agentUsageStores[hostID] = store
        return store
    }

    /// One Host as the Usage tab reads it.
    func agentUsageEntry(for host: Host) -> AgentUsageHostEntry {
        let store = agentUsageStore(for: host.id)
        return AgentUsageHostEntry(
            id: host.id, name: host.displayName, store: store,
            isConnected: usageHasConnection(host, state: store.state),
            readsOverHostHelper: host.serverKind == .herdrCore || host.serverKind == .tmux)
    }

    /// Whether a Host's Usage has a connection to answer over. A Herdr TUI Host
    /// borrows the Console's. A core or tmux Host's read dials one when the
    /// Console has none: its Helper answers with the server stopped, and a
    /// native Windows Host says why it has none though its session never
    /// connects. So only a read that could not reach the Host makes it not connected.
    private func usageHasConnection(_ host: Host, state: AgentUsageStore.State) -> Bool {
        if hostStatuses[host.id] == .connected { return true }
        return (host.serverKind == .herdrCore || host.serverKind == .tmux) && !state.couldNotReachHost
    }

    /// The Host's Accounts for every harness (#621), kept for as long as
    /// the Console runs. Usage joins in while it is on.
    func hostAccountsStore(for hostID: Host.ID) -> HostAccountsStore {
        if let store = hostAccountsStores[hostID] { return store }
        let store = HostAccountsStore(
            hostID: hostID,
            onHost: { [weak self] operation in
                guard let self else { throw TransportError.cancelled }
                try await self.withUsageHost(for: hostID, operation)
            },
            fileGate: usageAccountFileGate,
            usage: { [weak self] in
                guard let self, self.isUsageEnabled else { return nil }
                return self.agentUsageStore(for: hostID)
            })
        hostAccountsStores[hostID] = store
        return store
    }

    /// The variable `kind`'s Accounts set on a Host, for a Launch Preset
    /// with an Account: the Host's Accounts name it, else the harness does.
    func accountVariable(for kind: SupportedAgentKind, on hostID: Host.ID) async throws -> String? {
        let store = hostAccountsStore(for: hostID)
        try await store.load()
        return store.variable(for: kind)
    }

    /// One Account a Launch Preset can name: its folder with `~` for the
    /// home, so one preset serves every Host that keeps it there.
    struct PresetAccountChoice: Hashable, Identifiable {
        let name: String
        let directory: String
        let hostName: String
        var id: String { directory }
    }

    /// Loads every Host's Accounts, for a preset's Account picker.
    func loadAllHostAccounts() async {
        for host in catalog { try? await hostAccountsStore(for: host.id).load() }
    }

    /// The Accounts of `kind` the Hosts loaded so far keep, each folder once.
    func presetAccountChoices(for kind: SupportedAgentKind) -> [PresetAccountChoice] {
        var choices: [PresetAccountChoice] = []
        for host in catalog {
            guard let store = hostAccountsStores[host.id] else { continue }
            for account in store.file.accounts(for: kind) {
                let directory = AccountsListing.displayDirectory(account.directory, home: store.hostHome)
                guard !choices.contains(where: { $0.directory == directory }) else { continue }
                choices.append(.init(name: account.name, directory: directory, hostName: host.displayName))
            }
        }
        return choices
    }

    /// Whether Usage is on: its tab, its Host section, and its reads.
    var isUsageEnabled: Bool { usageSettings.isEnabled }

    /// Turning Usage off ends its reads and forgets its figures, here and in
    /// the widgets. Each Host's Claude Code limits consent stays for when it
    /// returns, and the widgets read again then if any is installed.
    func setUsageEnabled(_ enabled: Bool) {
        guard enabled != isUsageEnabled else { return }
        usageSettings.setEnabled(enabled)
        if !enabled {
            for refresh in widgetUsageRefreshes.values { refresh.task.cancel() }
            widgetUsageRefreshes.removeAll()
            for store in agentUsageStores.values { store.invalidate() }
            agentUsageStores.removeAll()
        }
        publishUsageWidgets()
        refreshStaleWidgetUsage()
    }

    /// Hands every catalog Host's current Usage reading to the widgets.
    private func publishUsageWidgets() {
        guard let usageWidgets else { return }
        guard isUsageEnabled else {
            usageWidgets.publishUsageOff(hosts: usageCatalog)
            return
        }
        usageWidgets.publish(usageCatalog.map { host in
            let store = agentUsageStores[host.id]
            let state = store?.state ?? .idle
            return AgentUsageWidgetReading(
                id: host.id, name: host.displayName, state: state, readAt: store?.readAt,
                isConnected: usageHasConnection(host, state: state),
                keepsLastAnswerUntilRead: host.serverKind == .herdrCore || host.serverKind == .tmux)
        })
    }

    /// The catalog's Hosts that have Usage to read, in its order.
    private var usageCatalog: [Host] {
        catalog.filter(\.serverKind.hasHostIntegrations)
    }

    /// Whether a read for the widgets can run now. A Herdr TUI Host borrows the
    /// Console's connection. A core or tmux Host's read dials one when the
    /// Console has none, so a stopped server or a native Windows Host still
    /// gets its answer.
    private func canReadUsageForWidgets(_ id: Host.ID) -> Bool {
        hostStatuses[id] == .connected || coreHost(id) != nil || tmuxHost(id) != nil
    }

    /// Reads Usage again for each Host that can be read and whose widget figures
    /// went stale, so returning to the app updates the widgets without opening
    /// Usage. Nothing is read while no Usage widget is installed.
    private func refreshStaleWidgetUsage() {
        guard let usageWidgets, isActive, isUsageEnabled else { return }
        let hostIDs = usageCatalog.map(\.id).filter { id in
            canReadUsageForWidgets(id) && widgetUsageRefreshes[id] == nil
                && agentUsageStores[id]?.isLoading != true
                && usageWidgets.isStale(id, readAt: agentUsageStores[id]?.figuresReadAt)
        }
        for id in hostIDs {
            let refresh = UUID()
            let task = Task { [weak self] in
                defer {
                    if self?.widgetUsageRefreshes[id]?.id == refresh { self?.widgetUsageRefreshes[id] = nil }
                }
                guard await usageWidgets.widgetsInstalled(), !Task.isCancelled, let self,
                    canReadUsageForWidgets(id)
                else { return }
                await agentUsageStore(for: id).refresh()
            }
            widgetUsageRefreshes[id] = (refresh, task)
        }
    }

    /// Settings' plugin requirement notes: each Host's plugin, read on its
    /// current connection.
    func refreshPluginStatuses(for hostIDs: [Host.ID]) async {
        await pluginStatuses.refresh(hostIDs, transports: self)
    }

    /// Settings' Sync from plugin: one Host's layout file, on its current
    /// connection. nil means the Host has no connection to read from.
    func refreshSidebarLayout(for hostID: Host.ID) async -> HerdrSidebarSnapshotStore.HostState? {
        await sidebarSnapshots.refresh(hostID, transports: self) { [weak self] in
            self?.rebuildAgentOrder()
        }
    }

    private func rebuildAgentOrder() {
        let span = PerfTrace.begin("console.rebuild.order")
        defer { PerfTrace.end(span) }
        let unsorted = projections.values.flatMap { $0.agentsByPane.values }
            .map { agyTitles.applying(to: $0) }
        // A Host with no plugin has no snapshot to say: it keeps status priority,
        // and within a status the order its projection lists, the desktop app's.
        let sorts = Dictionary(uniqueKeysWithValues: projections.compactMap { id, projection in
            projection.host.capabilities.syncLayoutFromPlugin
                ? sidebarSnapshots.snapshot(for: id).map { (id, $0.agentPanelSort) }
                : (id, AgentPanelSort.priority)
        })
        let pinRanks = Dictionary(uniqueKeysWithValues: unsorted.compactMap { agent in
            pins.pinRank(hostID: agent.hostID, paneID: agent.agent.paneID)
                .map { (agent.id, $0) }
        })
        let nextAgents = unsorted.consoleSorted(sortByHost: sorts) { pinRanks[$0.id] }
        if agents != nextAgents { agents = nextAgents }
        let listed = Set(unsorted.map(\.id))
        if listedAgentIDs != listed { listedAgentIDs = listed }
        rebuildChatDisplayAgents()
    }

    private func rebuildCapabilities() {
        var next: [Host.ID: HostCapabilities] = [:]
        next.reserveCapacity(catalog.count)
        for host in catalog {
            next[host.id] = HostCapabilities(
                serverKind: host.serverKind,
                platform: hostPlatforms[host.id],
                desktopAppNaming: hostDesktopAppNaming[host.id],
                coreKernel: hostCoreKernels[host.id],
                coreLinuxChatPrograms: coreLinuxChatPrograms,
                coreMacOSChatPrograms: coreMacOSChatPrograms,
                coreWindowsChatPrograms: coreWindowsChatPrograms,
                isLocatingCore: hostStatuses[host.id] == .connecting)
        }
        if hostCapabilities != next {
            hostCapabilities = next
        }
    }

    private func rebuildHostIssues() {
        let next = PerfTrace.span("console.host-issues") {
            catalog.compactMap { host in
                ConsoleHostStatusPresentation(
                    host: host,
                    status: hostStatuses[host.id],
                    standingFailure: hostStandingFailures[host.id],
                    isAwaitingSnapshot: hostsAwaitingSnapshot.contains(host.id),
                    syncError: hostSyncErrors[host.id])
            }
        }
        if hostIssues != next {
            hostIssues = next
        }
    }

    /// Actionable status presentations for `hosts`, reusing `hostIssues` when
    /// `hosts` matches the synced `catalog`.
    func hostIssues(for hosts: [Host]) -> [ConsoleHostStatusPresentation] {
        if hosts == catalog {
            return hostIssues
        }
        return PerfTrace.span("console.host-issues") {
            hosts.compactMap { host in
                ConsoleHostStatusPresentation(
                    host: host,
                    status: hostStatuses[host.id],
                    standingFailure: hostStandingFailures[host.id],
                    isAwaitingSnapshot: hostsAwaitingSnapshot.contains(host.id),
                    syncError: hostSyncErrors[host.id])
            }
        }
    }

    private func rebuildChatDisplayAgents() {
        let span = PerfTrace.begin("console.chat-display-agents")
        defer { PerfTrace.end(span) }
        let live = listedAgentIDs
        let savedPairs = projections.values.flatMap {
            projection -> [(agent: ConsoleAgent, readiness: HostReadiness)] in
            guard projection.showsSavedChats else { return [] }
            let saved = cachedChats.agents(on: projection.host).filter { !live.contains($0.id) }
            guard !saved.isEmpty else { return [] }
            let hostReadiness = readiness(of: projection.host)
            return saved.map { ($0, hostReadiness) }
        }
        let nextDisplay: [ConsoleAgent]
        let nextSavedEntries: [ConsoleAgent.ID: HostReadiness]
        if savedPairs.isEmpty {
            nextDisplay = agents
            nextSavedEntries = [:]
        } else {
            nextDisplay =
                agents
                + savedPairs.map(\.agent).consoleSorted(sortByHost: [:]) { [pins] in
                    pins.pinRank(hostID: $0.id.hostID, paneID: $0.id.paneID)
                }
            nextSavedEntries = Dictionary(savedPairs.map { ($0.agent.id, $0.readiness) }) {
                first, _ in first
            }
        }
        if chatDisplayAgents != nextDisplay { chatDisplayAgents = nextDisplay }
        if savedChatEntries != nextSavedEntries { savedChatEntries = nextSavedEntries }
        var nextStructures: [Host.ID: [ChatCachedWorkspace]] = [:]
        for projection in projections.values where projection.showsSavedChats {
            let structure = cachedChats.structure(on: projection.host)
            if !structure.isEmpty { nextStructures[projection.host.id] = structure }
        }
        if savedWorkspaceStructures != nextStructures {
            savedWorkspaceStructures = nextStructures
        }
    }

    /// What a detail column shows for this selection: an Agent on the list, the
    /// Agent as last listed while its Host recovers, a saved Chat, or a departed
    /// Agent, which no list shows. A selected terminal stays mounted through
    /// automatic recovery, without stale metadata reading as live inventory on
    /// other surfaces.
    func detailAgent(for id: ConsoleAgent.ID) -> ConsoleAgent? {
        if let live = agents.first(where: { $0.id == id }) { return live }
        if let projection = projections[id.hostID] {
            let isRecovering: Bool
            switch hostStatuses[id.hostID] {
            // Leaving past the grace period tears the terminal down, not the
            // screen: the detail acquires a new one when the app is active.
            case .connecting, .reconnecting, .suspended:
                isRecovering = true
            case .connected:
                isRecovering = hostsAwaitingSnapshot.contains(id.hostID)
            default:
                isRecovering = false
            }
            if isRecovering, let previous = projection.lastKnownAgentsByPane[id.paneID] {
                return agyTitles.applying(to: previous)
            }
        }
        return chatDisplayAgents.first { $0.id == id } ?? departedAgents.first { $0.id == id }
    }

    /// What became of an Agent a detail stays open on, for its Chat to say. Nil
    /// while the Agent is there.
    func chatDeparture(of id: ConsoleAgent.ID) -> ChatAgentDeparture? {
        guard departedAgents.contains(where: { $0.id == id }) else { return nil }
        // The Console hides a finished Terminal.
        guard let terminal = terminals.first(where: { $0.hostID == id.hostID && $0.paneID == id.paneID }) else {
            return .ended
        }
        return terminal.isRestarting ? .restarting : .shell
    }

    func isHostReadyForInput(_ hostID: Host.ID) -> Bool {
        hostStatuses[hostID] == .connected && !hostsCheckingConnection.contains(hostID)
            && !hostsAwaitingFreshSnapshot.contains(hostID)
    }

    /// Replaces a detail's title while its Host is not ready for input.
    func connectionRecoveryTitle(for hostID: Host.ID) -> String? {
        if hostsCheckingConnection.contains(hostID) { return String(localized: "Connection slow…") }
        switch hostStatuses[hostID] {
        case .connecting, .reconnecting:
            return String(localized: "Reconnecting…")
        case .connected where hostsAwaitingFreshSnapshot.contains(hostID):
            return String(localized: "Updating session…")
        default:
            return nil
        }
    }

    /// One row's answer to `savedChatEntries`, cheap enough for a detail
    /// screen to ask on every render. It asks who is listed, not what they
    /// are doing, so a detail that asks is left alone by other Agents'
    /// status changes.
    func isSavedChat(_ id: ConsoleAgent.ID) -> Bool {
        guard let projection = projections[id.hostID], projection.showsSavedChats,
            !listedAgentIDs.contains(id)
        else { return false }
        return cachedChats.agents(on: projection.host).contains { $0.id == id }
    }

    /// The branch the latest Changes read of the Host's checkout at `path`
    /// found, saved with the Workspace structure, so a card titles the
    /// checkout as it last did until a read of this launch lands.
    func savedBranch(on hostID: Host.ID, atCheckoutPath path: String?) -> CheckoutHead.Branch? {
        guard let path, let host = projections[hostID]?.host else { return nil }
        return cachedChats.structure(on: host).first { $0.checkout.checkoutPath == path }?.branch
    }

    /// What the Host's section header says of it, from the same inputs.
    private func readiness(of host: Host) -> HostReadiness {
        let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
        let issue = ConsoleHostStatusPresentation(
            host: host, status: hostStatuses[host.id],
            standingFailure: hostStandingFailures[host.id],
            isAwaitingSnapshot: isAwaitingSnapshot, syncError: hostSyncErrors[host.id])
        return ConsoleHostSectionHeaderPresentation.readiness(
            connectionStatus: hostStatuses[host.id], isAwaitingSnapshot: isAwaitingSnapshot,
            statusSeverity: issue?.severity, isEmpty: false, inventoryNoun: "Agents")
    }

    /// A window closed, or the system disconnected it. What it shows still
    /// reads as selected, so its screens never let go of a core Terminal on
    /// their own, and one that did not would stay a viewer the Terminal sizes
    /// to. A Herdr TUI Host keeps its window rules, which go through
    /// `HostTerminalOwnership`.
    func sceneDidEnd(_ sceneID: UUID) {
        endedScenes.insert(sceneID)
        for (viewer, shown) in agentViewers where shown.scene == sceneID {
            setAgentShown(nil, viewer: viewer, scene: sceneID)
        }
        agentTerminals.sceneDidEnd(sceneID)
        terminalConnections.sceneDidEnd(sceneID) { [self] hostID in
            !capabilities(for: hostID).takeOver
        }
    }

    /// SwiftUI can pair a window's root `onDisappear` with an `onAppear`.
    func sceneDidStart(_ sceneID: UUID) {
        endedScenes.remove(sceneID)
    }

    /// A window that ended may still run a load it started or a late update.
    /// Its screens ask this before showing a core Terminal again.
    func hasSceneEnded(_ sceneID: UUID?, on hostID: Host.ID) -> Bool {
        guard let sceneID, endedScenes.contains(sceneID) else { return false }
        return !capabilities(for: hostID).takeOver
    }

    /// What the Host offers. A detail can outlive its Host's catalog entry for
    /// a moment; its actions stay as they were and fail as not connected.
    func capabilities(for hostID: Host.ID) -> HostCapabilities {
        hostCapabilities[hostID] ?? HostCapabilities(serverKind: .herdrTUI)
    }

    func capabilities(for host: Host) -> HostCapabilities {
        hostCapabilities[host.id] ?? HostCapabilities(serverKind: host.serverKind)
    }

    /// Add Host found a native Windows machine here. A Unix Host says nothing until
    /// its first attempt has, as nothing could start before that attempt. This one's
    /// first attempt may never reach it, and offers must not wait.
    func noteWindowsCore(on hostID: Host.ID) {
        coreHostMemory.noteKernel(HerdrCoreLocator.windowsKernel, for: hostID)
    }

    // MARK: Harness configuration edits

    /// The Grok Build edit an Unknown Grok Build Agent offers. `process` is the
    /// Agent's, whose `GROK_HOME` says which file its program reads.
    /// The edit this explanation may offer, where its Host can make it: it reads
    /// the Agent's environment and writes a POSIX path, neither of which a native
    /// Windows core Host serves (ADRs 0033 and 0046).
    func grokBuildEditFlow(
        for explanation: HerdrCoreStatusExplanation, on hostID: Host.ID
    ) -> HarnessConfigEditFlow? {
        guard explanation.offersGrokBuildEdit, capabilities(for: hostID).hostScripts else {
            return nil
        }
        return grokBuildEditFlow(on: hostID, process: explanation.agentProcess)
    }

    func grokBuildEditFlow(on hostID: Host.ID, process: Int?) -> HarnessConfigEditFlow {
        HarnessConfigEditFlow(
            hostID: hostID, editID: GrokBuildProgramStatusEdit.id, store: harnessEdits,
            services: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.harnessEditServices(on: hostID)
            },
            makeEdit: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.grokBuildEdit(on: hostID, process: process)
            })
    }

    /// Heeler's extension on a native Windows core Host (ADR 0033). A detail keeps to
    /// its own core: a Host that has moved on writes nothing more, even part way.
    func windowsExtensionFlow(
        for agentID: ConsoleAgent.ID, keepingTo corePin: TerminalCorePin? = nil
    ) -> HerdrCoreWindowsExtensionFlow {
        let hostID = agentID.hostID
        func core(of store: ConsoleStore) throws -> HerdrCoreConsoleProjection {
            guard !store.hasLeftCore(corePin, on: hostID) else { throw store.leftCoreError(on: hostID) }
            guard let core = store.projections[hostID] as? HerdrCoreConsoleProjection else {
                throw TransportError.cancelled
            }
            return core
        }
        return HerdrCoreWindowsExtensionFlow(
            locate: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await core(of: self).windowsExtensionFolders()
            },
            write: { [weak self] folders in
                guard let self else { throw TransportError.cancelled }
                guard let contents = try self.hostHelperBundle().files[HerdrCoreWindowsExtensions.bundlePath] else {
                    throw HostHelperBundle.LoadError.unreadable(HerdrCoreWindowsExtensions.bundlePath)
                }
                for folder in folders {
                    try await core(of: self).writeWindowsExtension(contents, to: folder)
                }
            })
    }

    /// The OpenCode edit a Chat that can't bind offers. It keeps to `corePin`, as
    /// anything a detail does: past that core there is no Agent left to do it for.
    func openCodePluginEditFlow(
        for agentID: ConsoleAgent.ID, keepingTo corePin: TerminalCorePin? = nil
    ) -> HarnessConfigEditFlow {
        let hostID = agentID.hostID
        return HarnessConfigEditFlow(
            hostID: hostID, editID: OpenCodePluginEdit.id, store: harnessEdits,
            services: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                guard !self.hasLeftCore(corePin, on: hostID) else { throw self.leftCoreError(on: hostID) }
                return try await self.harnessEditServices(on: hostID)
            },
            makeEdit: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                guard !self.hasLeftCore(corePin, on: hostID) else { throw self.leftCoreError(on: hostID) }
                return try await self.openCodePluginEdit(paneID: agentID.paneID, on: hostID)
            })
    }

    /// A Host detail row's own way to its edit, which can only undo it.
    func harnessEditFlow(for edit: HarnessConfigAppliedEdit, on hostID: Host.ID) -> HarnessConfigEditFlow {
        HarnessConfigEditFlow(
            hostID: hostID, listing: edit, store: harnessEdits,
            services: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.harnessEditServices(on: hostID)
            })
    }

    /// Host detail's Claude Code hooks on a tmux Host (ADR 0046): it reads and
    /// writes through the harness edit seam, and finds and places Heeler's script
    /// through the Host's tmux projection.
    func claudeCodeHooksFlow(on hostID: Host.ID) -> ClaudeCodeHooksFlow {
        func tmux(of store: ConsoleStore) throws -> TmuxConsoleProjection {
            guard let tmux = store.projections[hostID] as? TmuxConsoleProjection else {
                throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
            }
            return tmux
        }
        return ClaudeCodeHooksFlow(
            services: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await self.harnessEditServices(on: hostID)
            },
            locate: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                return try await tmux(of: self).claudeCodeHookLocations()
            },
            place: { [weak self] in
                guard let self else { throw TransportError.cancelled }
                _ = try await tmux(of: self).placeClaudeCodeHooks()
            })
    }

    private func harnessEditServices(on hostID: Host.ID) async throws -> any HostServices {
        try await projection(for: hostID).withHostServices { $0 }
    }

    private func reconcileAgyAnnotationTitles() {
        agyTitles.reconcile(
            projections: projections,
            isActive: isActive,
            hostPlatforms: hostPlatforms,
            offersAgyChat: { [weak self] hostID in
                self?.capabilities(for: hostID).offersChat(for: .agy) == true
            },
            files: { [weak self] hostID in
                guard let self else {
                    return ChatHostFiles(
                        status: { _ in throw TransportError.cancelled },
                        list: { _ in throw TransportError.cancelled },
                        read: { _ in throw TransportError.cancelled },
                        home: { throw TransportError.cancelled })
                }
                return self.chatHostFiles(for: hostID)
            },
            isProjectionCurrent: { [weak self] hostID, expected, generation in
                guard let self else { return false }
                return self.isActive
                    && self.projections[hostID] === expected
                    && expected.status == .connected
                    && !expected.isAwaitingSnapshot
                    && expected.transportGeneration == generation
            },
            onReconcileNeeded: { [weak self] in
                self?.reconcileAgyAnnotationTitles()
            })
    }

    private func readAgyTitleForRename(
        fresh: Agent, paneID: String, hostID: Host.ID, generation: UInt64
    ) async -> Agent {
        guard fresh.kind == ChatProgram.agy.rawValue,
            capabilities(for: hostID).offersChat(for: .agy),
            hostPlatforms[hostID] == .posix
        else { return fresh }
        let files = chatHostFiles(for: hostID)
        do {
            let outcome = try await agyTitles.readLive(
                for: fresh, paneID: paneID, hostID: hostID, generation: generation, files: files,
                isCurrent: { [weak self] in
                    guard let self, let projection = self.projections[hostID] else { return false }
                    return projection.transportGeneration == generation
                        && !projection.isAwaitingSnapshot
                })
            switch outcome {
            case .titled(_, _, let title):
                return fresh.applyingConversationTitle(title)
            case .untitled:
                return fresh.clearingUntrackedConversationTitle()
            case .unresolved:
                return fresh
            }
        } catch {
            return fresh
        }
    }

    private func grokBuildEdit(on hostID: Host.ID, process: Int?) async throws -> HarnessConfigEdit {
        let grokHome: String?
        if let core = projections[hostID] as? HerdrCoreConsoleProjection {
            // Only an environment that was read can say `GROK_HOME` is unset. Taking an
            // unreadable one for unset would edit a file this Agent may not read.
            guard let process else { throw HarnessConfigEditError.agentEnvironmentUnavailable }
            switch await core.processVariable("GROK_HOME", pid: process) {
            case .value(let value): grokHome = value
            case .unset: grokHome = nil
            case .unavailable: throw HarnessConfigEditError.agentEnvironmentUnavailable
            }
        } else if let tmux = projections[hostID] as? TmuxConsoleProjection {
            guard let process else { throw HarnessConfigEditError.agentEnvironmentUnavailable }
            switch await tmux.grokBuildProcessVariable("GROK_HOME", paneProcessID: process) {
            case .value(let value): grokHome = value
            case .unset: grokHome = nil
            case .unavailable: throw HarnessConfigEditError.agentEnvironmentUnavailable
            }
        } else {
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Editing Host files"))
        }
        let home = try await harnessEditServices(on: hostID).hostHomeDirectory()
        guard let path = GrokBuildProgramStatusEdit.configPath(grokHome: grokHome, home: home) else {
            throw HarnessConfigEditError.unresolvedPath
        }
        return GrokBuildProgramStatusEdit.edit(path: path)
    }

    private func openCodePluginEdit(paneID: String, on hostID: Host.ID) async throws -> HarnessConfigEdit {
        guard let core = projections[hostID] as? HerdrCoreConsoleProjection else {
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Editing Host files"))
        }
        // Only an environment that was read can say a variable is unset.
        guard let foreground = core.foreground(of: paneID), let process = foreground.pid else {
            throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        // The release is the Agent's own, which its PATH found, and not the login
        // shell's (herdr compatibility, OpenCode on a signed-in Linux core).
        let path: String?
        switch await core.processVariable("PATH", pid: process) {
        case .value(let value): path = value
        case .unset: path = nil
        case .unavailable: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        let version = try await core.openCodeVersion(
            running: OpenCodePluginEdit.program(running: foreground.argv), path: path, directory: foreground.cwd)
        guard let form = OpenCodePluginEdit.ConfigForm.of(version: version) else {
            throw HarnessConfigEditError.openCodeVersionUnknown
        }
        let services = try await harnessEditServices(on: hostID)
        let home: String
        switch await core.processVariable("HOME", pid: process) {
        case .value(let value): home = value
        case .unset: home = try await services.hostHomeDirectory()
        case .unavailable: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        let xdgConfigHome: String?
        switch await core.processVariable("XDG_CONFIG_HOME", pid: process) {
        case .value(let value): xdgConfigHome = value
        case .unset: xdgConfigHome = nil
        case .unavailable: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        guard let directory = OpenCodePluginEdit.configDirectory(xdgConfigHome: xdgConfigHome, home: home) else {
            throw HarnessConfigEditError.unresolvedPath
        }
        return OpenCodePluginEdit.edit(
            configDirectory: directory,
            fileName: try await OpenCodePluginEdit.fileName(in: directory, form: form, over: services),
            form: form, files: try OpenCodePluginEdit.pluginFiles(from: try hostHelperBundle()))
    }

    func chatProgram(for agent: ConsoleAgent, keepingTo corePin: TerminalCorePin? = nil) -> ChatProgram? {
        // Chat goes on to the address's new Agent. A detail stays with the old one,
        // which has no Chat left to show.
        guard !hasLeftCore(corePin, on: agent.hostID) else { return nil }
        let capabilities = capabilities(for: agent.hostID)
        guard capabilities.chat else { return nil }
        if let program = ChatProgram(rawValue: agent.agent.kind), !capabilities.offersChat(for: program) {
            return nil
        }
        let platform =
            hostPlatforms[agent.hostID]
            ?? (catalog.first(where: { $0.id == agent.hostID })?.serverKind == .tmux ? .posix : nil)
        if let platform {
            return AgentChatAvailability.program(
                for: agent.agent, platform: platform, isNativeWindowsCore: capabilities.isNativeWindowsCore,
                hasAdapter: { chatAdapter($0) != nil })
        }
        guard let host = projections[agent.hostID]?.host,
            cachedChats.agents(on: host).contains(where: { $0.id == agent.id }) else { return nil }
        return AgentChatAvailability.program(
            for: agent.agent, platform: .posix, hasAdapter: { chatAdapter($0) != nil })
    }

    private func reconcileChatCache() {
        let span = PerfTrace.begin("console.rebuild.chat-cache")
        defer { PerfTrace.end(span) }
        for projection in projections.values {
            let host = projection.host
            guard host.capabilities.chat, isActive,
                projection.status == .connected, !projection.isAwaitingSnapshot else {
                chatPrefetchTasks[host.id]?.cancel()
                chatPrefetchTasks[host.id] = nil
                chatPrefetched = chatPrefetched.filter { $0.key.hostID != host.id }
                chatPrefetchRetries = chatPrefetchRetries.filter { $0.key.hostID != host.id }
                continue
            }
            guard hostPlatforms[host.id] == .posix else { continue }
            if chatCacheValidatedGenerations[host.id] != projection.transportGeneration {
                chatCacheValidatedGenerations[host.id] = projection.transportGeneration
                cachedChats.revalidate(on: host)
            }
            cachedChats.observe(
                projection.agentsByPane.values.map { agyTitles.applying(to: $0) },
                on: host)
            guard chatPrefetchTasks[host.id] == nil else { continue }
            let generation = projection.transportGeneration
            let candidates = projection.agentsByPane.values.filter { agent in
                guard AgentChatAvailability.mayOfferChat(for: agent.agent, hasAdapter: { chatAdapter($0) != nil })
                else { return false }
                // A conversation read by query costs an exec on the Host,
                // and the key changes with every status (ADR 0025): only an
                // open Chat reads it.
                guard ChatProgram(rawValue: agent.agent.kind).flatMap(chatAdapter)?.readsByQuery != true
                else { return false }
                return chatPrefetched[agent.id] != chatPrefetchKey(agent, generation: generation)
            }
            guard !candidates.isEmpty else { continue }
            chatPrefetchTasks[host.id] = Task { [weak self, weak projection] in
                guard let self, let projection else { return }
                var needsRetry = false
                for agent in candidates {
                    guard !Task.isCancelled, isActive, projections[host.id] === projection,
                        projection.status == .connected, !projection.isAwaitingSnapshot,
                        projection.transportGeneration == generation else { break }
                    guard let program = ChatProgram(rawValue: agent.agent.kind),
                        let chat = chatStore(for: agent, program: program) else { continue }
                    let key = chatPrefetchKey(agent, generation: generation)
                    chatPrefetched[agent.id] = key
                    let read = PerfTrace.beginInterval("chat.prefetch", "pane=\(agent.agent.paneID)")
                    let prefetched = await chat.prefetch()
                    PerfTrace.endInterval(
                        read, "ok=\(prefetched) entries=\(chat.conversation.transcript.entries.count)")
                    guard !Task.isCancelled else { return }
                    let snapshot = chat.conversation
                    let retries = chatPrefetchRetries[agent.id].flatMap { $0.key == key ? $0.count : nil } ?? 0
                    chatPrefetchRetries[agent.id] =
                        Self.chatPrefetchWaits(on: snapshot.phase) ? (key, retries + 1) : nil
                    if !prefetched || snapshot.readFailure != nil
                        || Self.chatPrefetchRetries(after: retries, phase: snapshot.phase)
                    {
                        chatPrefetched[agent.id] = nil
                        needsRetry = true
                    }
                }
                if needsRetry { try? await Task.sleep(for: chatPrefetchRetryDelay) }
                guard !Task.isCancelled, projections[host.id] === projection else { return }
                chatPrefetchTasks[host.id] = nil
                reconcileChatCache()
            }
        }
    }

    /// Whether a prefetch that ended in `phase` looks again in a while: the
    /// session or its transcript may still appear. A new conversation's file
    /// comes only with a turn, whose status change prefetches again.
    nonisolated static func chatPrefetchWaits(on phase: ChatConversationSnapshot.Phase) -> Bool {
        switch phase {
        case .locating: true
        case .unavailable(.noSession), .unavailable(.notFound): true
        default: false
        }
    }

    /// Whether a prefetch that ended in `phase`, after `retries` earlier
    /// ones for the same key, looks again. A conversation still missing
    /// after a few looks waits for a change to its Agent, a new connection,
    /// or its Chat, which keeps looking while it shows.
    nonisolated static func chatPrefetchRetries(after retries: Int, phase: ChatConversationSnapshot.Phase) -> Bool {
        chatPrefetchWaits(on: phase) && retries < 3
    }

    private func chatPrefetchKey(_ agent: ConsoleAgent, generation: UInt64) -> String {
        "\(generation):\(agent.agent.terminalID):\(agent.agent.kind):\(agent.agent.status):\(agent.agent.agentSession?.value ?? "")"
    }

    /// Hands each Chat its Agent's latest record, and ends the Chats of
    /// Agents a current snapshot no longer lists. A departed Agent's detail
    /// stays open, and its Chat with it, until the Agent is back or gone.
    private func publishChatAgents() {
        guard !chatStores.isEmpty else { return }
        let span = PerfTrace.begin("console.rebuild.chat-agents")
        defer { PerfTrace.end(span) }
        let current = Dictionary(agents.map { ($0.id, $0.agent) }) { first, _ in first }
        for (id, store) in chatStores {
            let processBound = projections[id.hostID].flatMap { $0.usesProcessBoundChat ? $0 : nil }
            // Another core's or server instance's Agents are other Agents: its
            // Transcripts are keyed apart, and this store is keyed to the last one.
            if let processBound, store.coreScope != processBound.chatCacheScope {
                let viewers = store.viewerTokens
                store.end()
                chatStores[id] = nil
                chatSessionEventRevisions[id] = nil
                // A Chat on screen says so only once, when it appears, and it
                // stays on screen across this.
                if !viewers.isEmpty, let agent = agents.first(where: { $0.id == id }),
                    let next = chatStore(for: agent, program: store.program)
                {
                    for viewer in viewers { next.show(viewer) }
                }
                continue
            }
            if let processBound {
                let revision = processBound.sessionEventRevision(of: id.paneID)
                if chatSessionEventRevisions.updateValue(revision, forKey: id) != revision {
                    store.sessionEvidenceMayHaveChanged()
                }
            }
            if let agent = current[id] ?? departedAgents.first(where: { $0.id == id })?.agent {
                store.agentDidChange(agent)
            } else if hostStatuses[id.hostID] == .connected,
                !hostsAwaitingSnapshot.contains(id.hostID)
            {
                store.end()
                chatStores[id] = nil
                chatSessionEventRevisions[id] = nil
                processBound?.settleChatPick(paneID: id.paneID, program: store.program)
            }
        }
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
                && !hostsAwaitingSnapshot.contains(id.hostID),
            connectionGeneration: hostConnectionGenerations[id.hostID])
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
    /// fails loudly like every other Host-scoped RPC here. A herdr-core Host's
    /// projection says it has no plugin, and its plugin surfaces say so.
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        try await projection(for: hostID).withNotificationTransport(operation)
    }

    /// The root follows the Server Kind: a herdr-core or tmux Host's files are
    /// the Host Helper's, every other Host's the plugin's, over its live connection.
    func withNotificationFiles<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any HostNotificationFiles) async throws -> Value
    ) async throws -> Value {
        if let host = coreHost(hostID) {
            return try await withCoreConnection(host) { transport in
                try await operation(HostHelperFiles(host: transport.hostHelperHost, session: host.sessionName))
            }
        }
        if let host = tmuxHost(hostID) {
            let projectionPaths = (projections[hostID] as? TmuxConsoleProjection)?.host.storedTmuxPaths
            return try await withTmuxConnection(host) { transport in
                let paths = await transport.hostFacts().paths ?? projectionPaths ?? host.storedTmuxPaths
                return try await operation(
                    HostHelperFiles(
                        host: transport.hostHelperHost, tmuxSocket: host.tmuxSocketName,
                        tmuxPaths: paths))
            }
        }
        return try await projection(for: hostID).withNotificationTransport { transport in
            try await operation(transport)
        }
    }

    /// What Usage's Account changes run over. It follows the Server Kind too.
    fileprivate func withUsageHost(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any HostServices & HostNotificationFiles) async throws -> Void
    ) async throws {
        if let host = coreHost(hostID) {
            try await withCoreConnection(host) { transport in
                try await operation(HostHelperUsageHost(
                    services: transport.hostServices,
                    files: HostHelperFiles(host: transport.hostHelperHost, session: host.sessionName)))
            }
            return
        }
        if let host = tmuxHost(hostID) {
            let projectionPaths = (projections[hostID] as? TmuxConsoleProjection)?.host.storedTmuxPaths
            try await withTmuxConnection(host) { transport in
                let paths = await transport.hostFacts().paths ?? projectionPaths ?? host.storedTmuxPaths
                try await operation(HostHelperUsageHost(
                    services: transport.hostServices,
                    files: HostHelperFiles(
                        host: transport.hostHelperHost, tmuxSocket: host.tmuxSocketName,
                        tmuxPaths: paths)))
            }
            return
        }
        try await withNotificationTransport(for: hostID) { try await operation($0) }
    }

    /// What this device has seen on a core or tmux Host. Nil on any other Host.
    func coreSeenMarks(on hostID: Host.ID) -> (core: String, marks: [String: HerdrCoreTurnState.Mark])? {
        if let core = (projections[hostID] as? HerdrCoreConsoleProjection)?.currentSeenMarks {
            return core
        }
        return (projections[hostID] as? TmuxConsoleProjection)?.currentSeenMarks
    }

    /// Whether this Host's notification files can be asked for now. A stopped
    /// core or tmux server leaves the Host's SSH up and its Helper's files in
    /// reach, and it reads as reconnecting for as long as it stays stopped.
    func canReachNotificationFiles(_ hostID: Host.ID) -> Bool {
        switch hostStatuses[hostID] {
        case .connected: true
        case .reconnecting(_, _, .herdrCoreNotRunning): coreHost(hostID) != nil
        case .reconnecting(_, _, .tmuxServerNotRunning): tmuxHost(hostID) != nil
        default: false
        }
    }

    /// The server a tmux Host's socket answers with, while one does. Nil on any
    /// other Host.
    func tmuxServer(on hostID: Host.ID) -> TmuxServerStatus? {
        (projections[hostID] as? TmuxConsoleProjection)?.server
    }

    fileprivate func coreHost(_ hostID: Host.ID) -> Host? {
        catalog.first { $0.id == hostID && $0.serverKind == .herdrCore }
    }

    fileprivate func tmuxHost(_ hostID: Host.ID) -> Host? {
        catalog.first { $0.id == hostID && $0.serverKind == .tmux }
    }

    /// A core Host's connection for one operation: the Console's own while it
    /// has one, else one dialed for the operation, since a Helper answers
    /// whether or not a core runs.
    fileprivate func withCoreConnection<Value: Sendable>(
        _ host: Host,
        _ operation: @escaping @Sendable (any HerdrCoreTransport) async throws -> Value
    ) async throws -> Value {
        if let session = (projections[host.id] as? HerdrCoreConsoleProjection)?.session,
            let live = try? await session.withTransport({ $0 }), await live.isConnected
        {
            return try await operation(live)
        }
        let transport = try await connectCore(host)
        do {
            let value = try await operation(transport)
            try? await transport.close()
            return value
        } catch {
            try? await transport.close()
            throw error
        }
    }

    /// The tmux Hosts' equivalent: the Console's connection while it has one,
    /// else one dialed for the operation, since a Helper answers whether or not
    /// a tmux server runs.
    fileprivate func withTmuxConnection<Value: Sendable>(
        _ host: Host,
        _ operation: @escaping @Sendable (any TmuxTransport) async throws -> Value
    ) async throws -> Value {
        if let session = (projections[host.id] as? TmuxConsoleProjection)?.session,
            let live = try? await session.withTransport({ $0 }), await live.isConnected
        {
            return try await operation(live)
        }
        let transport = try await connectTmux(host)
        do {
            let value = try await operation(transport)
            try? await transport.close()
            return value
        } catch {
            try? await transport.close()
            throw error
        }
    }
}

extension ConsoleStore {
    /// A core Host's connection, from the catalog's credentials. As for the
    /// session factory, a key that still needs trusting is declined.
    static func sshCoreConnector(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) -> @Sendable (Host) async throws -> any HerdrCoreTransport {
        { host in
            try await connector.connectCore(
                settings: consoleSettings(
                    for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays))
        }
    }

    /// The tmux Hosts' equivalent, with the same trust rules.
    static func sshTmuxConnector(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) -> @Sendable (Host) async throws -> any TmuxTransport {
        { host in
            try await connector.connectTmux(
                settings: consoleSettings(
                    for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays))
        }
    }

    /// The production session factory: SSH transports built from the Host
    /// catalog's credentials. TOFU is restricted to already-trusted
    /// fingerprints; the Console never prompts.
    static func sshSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) -> @Sendable (Host, [EventSubscription]) -> EventsSession {
        { host, subscriptions in
            EventsSession(subscriptions: subscriptions) {
                try await connector.connect(
                    settings: consoleSettings(
                        for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays))
            }
        }
    }

    /// The herdr-core Hosts' equivalent, with the same trust rules.
    static func coreSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) -> @Sendable (Host) -> HerdrCoreHostSession {
        { host in
            HerdrCoreHostSession {
                try await connector.connectCore(
                    settings: consoleSettings(
                        for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays))
            }
        }
    }

    /// The tmux Hosts' equivalent, with the same trust rules. Each connection
    /// starts from the paths the session holds, which it keeps as they move.
    static func tmuxSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared
    ) -> @Sendable (Host) -> TmuxHostSession {
        { host in
            TmuxHostSession(storedPaths: host.storedTmuxPaths) { paths in
                var settings = try consoleSettings(
                    for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays)
                settings.tmuxPaths = paths
                return try await connector.connectTmux(settings: settings)
            }
        }
    }

    nonisolated private static func consoleSettings(
        for host: Host, knownHosts: any KnownHostsStore, credentials: HostCredentialsProvider,
        overlays: OverlayNetworkRuntime
    ) throws -> SSHTransportSettings {
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch HostCredentialsError.passwordNotSet {
            throw TransportError.authenticationFailed
        }
        return SSHTransportSettings(
            host: host,
            credentials: resolved,
            hostKeyPolicy: HostKeyPolicy(knownHosts: knownHosts) { _ in false },
            overlays: overlays)
    }
}
