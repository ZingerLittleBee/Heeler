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
/// An Agent's status is its Pane's `@heeler-status` (ADR 0044), and Done is
/// per device: this device's seen marks and each Pane's turns are kept by
/// server instance, beside it, with no Helper to hold them.
///
/// A Pane opens live, through `terminalRunner`. New Agent, New Terminal, New
/// Workspace, Rename Workspace and Close run through `TmuxLaunch`. A Worktree
/// is the same git as a herdr-core Host, under `~/.heeler`, and its session
/// opens through `TmuxLaunch` too. Nothing can be typed into a Pane yet, an
/// Agent is not renamed, and a Terminal is not taken over.
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
    private(set) var leakedEnvironmentNames: Set<String> = []
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    private(set) var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    private(set) var statusExplanations: [String: HerdrCoreStatusExplanation] = [:]
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
    /// The last inventory folded, which a seen mark folds again.
    private var inventory: TmuxInventory?
    /// OpenCode's version from the last discovery, for the next launch's `-s`.
    private var openCodeVersion: String?
    /// The Panes this device shows now, whose finished turns are seen as they end.
    private var shownAgents: Set<String> = []
    /// Where Heeler's Claude Code hook script goes, read once per connection's projection.
    private var hookLocations: HostHelperProbe.Locations?
    /// The Host's one git turn at a time, shared with every other git read.
    private let gitGate: GitExecGate
    /// Checkouts git has named, by the directory that was asked and by the checkout root.
    private var knownCheckouts: [String: HostCheckout] = [:]
    /// A newer inventory supersedes a checkout read still on its way.
    private var checkoutRefresh = 0
    private var worktreesBeingRemoved: Set<WorktreeIdentity> = []

    /// `onPathsResolved` hears the paths a connection resolved again, after
    /// `host` already carries them.
    init(
        host: Host,
        session: TmuxHostSession,
        memory: HerdrCoreHostMemory,
        pins: PinnedAgentsStore,
        gitGate: GitExecGate,
        onPathsResolved: @escaping @MainActor (TmuxPaths) -> Void,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.gitGate = gitGate
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
            Task { [weak self] in await self?.refreshStoredPaths(paths) }
        case .inventory(let inventory):
            guard status == .connected, server != nil else { return }
            replaceInventory(with: inventory)
        case .environment(let names):
            guard status == .connected, server != nil else { return }
            leakedEnvironmentNames = names
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
    /// them, its turns and seen marks with the memory's core id. A detail
    /// still open shows the last server's Pane, so it sees none of the new
    /// one's turns. Pins go first, so a crash in between still finds another
    /// instance next time.
    private func noteInstance(_ instance: TmuxServerInstance) {
        if let known = memory.coreID(for: host.id), known != instance.id {
            pins.removePins(hostID: host.id)
            lastKnownAgentsByPane = [:]
            shownAgents = []
            inventory = nil
        }
        memory.noteCore(instance.id, for: host.id)
    }

    private func invalidateInventory() {
        isAwaitingSnapshot = true
        inventory = nil
        workspaces = []
        terminalsByPane = [:]
        agentsByPane = [:]
        statusExplanations = [:]
        leakedEnvironmentNames = []
    }

    /// Each snapshot is the whole inventory, so nothing is carried over. Its
    /// rows name their server, which the loop asked later than `server` did.
    private func replaceInventory(with inventory: TmuxInventory) {
        if let instance = inventory.instance { noteInstance(instance) }
        let listed = Set(inventory.panes.map(\.paneID))
        pins.retainPins(hostID: host.id, paneIDs: listed)
        memory.retainTmuxPanes(listed, for: host.id)
        noteTurns(in: inventory)
        self.inventory = inventory
        rebuildRows()
        refreshMissingCheckouts(in: inventory)
    }

    /// One look at each Pane's `@heeler-status`. A Pane with no Agent is
    /// remembered only once it has a turn to forget, so a shell costs nothing.
    private func noteTurns(in inventory: TmuxInventory) {
        var noted: Set<String> = []
        let known = memory.tmuxTurnStates(for: host.id)
        for pane in inventory.panes where noted.insert(pane.paneID).inserted {
            let status = TmuxProgramStatus(option: pane.status)
            if let kind = TmuxAgentRule.agentKind(in: pane) {
                let isShown = shownAgents.contains(pane.paneID)
                memory.updateTmuxTurnState(of: pane.paneID, for: host.id) {
                    $0.noteSample(status, kind: kind, isShown: isShown)
                }
            } else if known[pane.paneID] != nil || status.turn > 0 {
                memory.updateTmuxTurnState(of: pane.paneID, for: host.id) { $0.noteNoAgent(status) }
            }
        }
    }

    private func rebuildRows() {
        guard let inventory else { return }
        let statuses = memory.tmuxTurnStates(for: host.id).mapValues(\.agentStatus)
        let organization = TmuxOrganization.build(inventory, statuses: statuses, checkouts: knownCheckouts)
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
        statusExplanations = Dictionary(
            uniqueKeysWithValues: organization.panes.compactMap { pane in
                guard rows[pane.paneID]?.isAgent == true else { return nil }
                let status = statuses[pane.paneID] ?? .unknown
                return HerdrCoreStatusExplanation(pane: pane, agentStatus: status).map { (pane.paneID, $0) }
            })
        workspaces = builder.workspaceRows()
        isAwaitingSnapshot = false
        sidebarRevision &+= 1
    }

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}

    // MARK: Done per device

    /// Marks each newly shown Agent seen. A turn that ends while one stays
    /// shown is marked at the look that finds it, so it never reads Done.
    func setShownAgents(_ paneIDs: Set<String>) {
        let opened = paneIDs.subtracting(shownAgents)
        shownAgents = paneIDs
        let known = memory.tmuxTurnStates(for: host.id)
        let opening = opened.filter { known[$0] != nil }
        guard !opening.isEmpty else { return }
        let wasDone = doneAgents
        for paneID in opening {
            memory.updateTmuxTurnState(of: paneID, for: host.id) { $0.markSeen() }
        }
        guard doneAgents != wasDone else { return }
        rebuildRows()
        onChange()
    }

    private var doneAgents: Set<String> {
        Set(memory.tmuxTurnStates(for: host.id).filter(\.value.isDone).keys)
    }

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Launches, rename and close

    private var unavailable: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "This action on a tmux Host"))
    }

    /// Through the user's interactive shell, as a herdr-core Host does, so the
    /// picker lists what an Agent launched that way would find (ADR 0032).
    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        let facts = try await session.withTransport { await $0.hostFacts() }
        let shell = facts.shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
        let nonce = HostProcessReader.makeNonce()
        guard case .posixScript(let script) = HerdrCoreLaunch.discovery(shell: shell, nonce: nonce) else {
            throw unavailable
        }
        let result = try await session.withTransport { transport in
            try await transport.runTmuxScript(script, throughLoginShell: true)
        }
        guard result.exitStatus == 0,
            let installed = try? HerdrCoreLaunch.installedAgents(stdout: result.stdout, nonce: nonce)
        else {
            throw TransportError.malformedResponse(
                String(localized: "The Host's shell did not finish looking for Agents."))
        }
        openCodeVersion = installed.openCodeVersion
        return installed.kinds
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        let server = try await launchServer()
        let hooks = await hookSettings(for: request)
        let made = try await created(
            try command { try TmuxLaunch.agentWindow(request, on: server, hookSettings: hooks) })
        return Agent(
            terminalID: made.paneID, kind: request.kind, title: "", status: .unknown,
            workspaceID: request.workspaceID ?? "", tabID: made.windowID, paneID: made.paneID,
            cwd: request.cwd ?? "", revision: 0, name: request.name)
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        let directory = try sourceDirectory(for: request)
        let server = try await launchServer()
        let hooks = await hookSettings(for: request)
        let created = try await worktreeGit().create(branch: worktree.branch ?? "", from: directory)
        // Before the session's first row, so it already reads as the Worktree it is.
        knownCheckouts[created.path] = HostCheckout(
            root: created.path, mainCheckout: created.mainCheckout, isLinkedWorktree: true)
        knownCheckouts[created.mainCheckout] = HostCheckout(
            root: created.mainCheckout, mainCheckout: created.mainCheckout, isLinkedWorktree: false)
        let made: TmuxLaunch.Created
        do {
            made = try await openWorktreeSession(
                request, directory: created.path, branch: worktree.branch ?? "", on: server, hookSettings: hooks)
        } catch {
            throw WorktreeAgentStartFailure(checkoutPath: created.path, underlying: error)
        }
        guard let sessionID = made.sessionID else {
            await endOpened(made)
            throw WorktreeAgentStartFailure(
                checkoutPath: created.path,
                underlying: TransportError.malformedResponse(
                    String(localized: "tmux: The command printed no session.")))
        }
        do {
            _ = try await perform(
                TmuxLaunch.setWorktree(session: sessionID, path: created.path, paths: server.paths))
        } catch {
            await endOpened(made)
            throw WorktreeAgentStartFailure(checkoutPath: created.path, underlying: error)
        }
        return Agent(
            terminalID: made.paneID, kind: request.kind, title: "", status: .unknown,
            workspaceID: sessionID, tabID: made.windowID, paneID: made.paneID,
            cwd: created.path, revision: 0, name: request.name)
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        let server = try await launchServer()
        let hooks = await hookSettings(for: request)
        let made = try await created(
            try command { try TmuxLaunch.agentSession(request, workspace: workspace, on: server, hookSettings: hooks) })
        return Agent(
            terminalID: made.paneID, kind: request.kind, title: "", status: .unknown,
            workspaceID: made.sessionID ?? "", tabID: made.windowID, paneID: made.paneID,
            cwd: workspace.directory, revision: 0, name: request.name)
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        let server = try await launchServer()
        let made = try await created(try command { try TmuxLaunch.shellWindow(request, on: server) })
        return ShellTerminalIdentity(paneID: made.paneID, tabID: made.windowID, terminalID: made.paneID)
    }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity {
        let server = try await launchServer()
        let made = try await created(try command { try TmuxLaunch.shellSession(workspace, on: server) })
        return ShellTerminalIdentity(paneID: made.paneID, tabID: made.windowID, terminalID: made.paneID)
    }

    func closePane(_ paneID: String) async throws {
        _ = try await perform(TmuxLaunch.killPane(paneID, paths: try runningPaths()))
    }

    func closeTab(_ tabID: String) async throws {
        _ = try await perform(TmuxLaunch.killWindow(tabID, paths: try runningPaths()))
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        guard let path = workspaces.first(where: { $0.id == workspaceID })?.checkoutPath,
            let checkout = knownCheckouts[path], let main = checkout.mainCheckout
        else { throw WorktreeRemovalError.staleIdentity }
        let entries = try await worktreeGit().list(in: path)
        let panes = inventory?.panes ?? []
        return WorktreeListResponse(
            source: WorktreeSourceInfo(
                repoKey: main, repoName: HerdrCoreWorktrees.repositoryName(mainCheckout: main),
                repoRoot: main, sourceCheckoutPath: path, sourceWorkspaceID: workspaceID),
            worktrees: entries.map { entry in
                let open = workspaces.first { $0.checkoutPath == entry.path }?.id
                    ?? panes.first { $0.worktree == entry.path }?.sessionID
                return WorktreeInfo(
                    isBare: entry.isBare, isDetached: entry.isDetached,
                    isLinkedWorktree: entry.isLinkedWorktree, isPrunable: entry.isPrunable,
                    label: entry.label, path: entry.path, branch: entry.branch, openWorkspaceID: open)
            })
    }

    func worktreeRemovalRisk(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        try await worktreeGit().removalRisk(ofCheckout: request.identity.checkoutPath)
    }

    /// Every Pane of each session carrying this checkout ends first, found by
    /// `@heeler-worktree`, never by the session's name. git then removes the
    /// checkout. What the checkout would lose is checked against the confirmation
    /// before anything ends, and again once the Panes have ended.
    func removeWorktree(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt {
        let identity = request.identity
        guard identity.hostID == host.id else { throw WorktreeRemovalError.staleIdentity }
        guard !isAwaitingSnapshot else {
            throw TransportError.sshUnreachable(detail: String(localized: "The Host is not connected."))
        }
        guard worktreesBeingRemoved.insert(identity).inserted else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        defer { worktreesBeingRemoved.remove(identity) }

        let git = try await beforeEnding { try await worktreeGit() }
        if let workspace = workspaces.first(where: { $0.id == identity.workspaceID }),
            workspace.checkoutPath != identity.checkoutPath
        {
            throw WorktreeRemovalError.staleIdentity
        }
        let mainCheckout = try await beforeEnding { try await git.verifiedMainCheckout(of: identity) }
        let risk = try await beforeEnding { try await git.removalRisk(ofCheckout: identity.checkoutPath) }
        guard risk.isCovered(by: request.toldRisk) else {
            throw WorktreeRemovalError.changedSinceConfirmation
        }

        let sessions = sessionsCarrying(identity.checkoutPath)
        let affected = Set(
            agentsByPane.values.filter { sessions.contains($0.agent.workspaceID) }.map(\.id))
        try await endPanes(ofCheckout: identity.checkoutPath)
        let settled = try await git.riskOnceTerminalsEnded(ofCheckout: identity.checkoutPath)
        guard settled.isCovered(by: request.toldRisk) else {
            throw WorktreeRemovalError.changedWhileTerminalsEnded
        }
        try await git.remove(
            path: identity.checkoutPath, mainCheckout: mainCheckout, force: settled.requiresForce)

        let receipt = WorktreeRemovalReceipt(request: request, affectedAgentIDs: affected)
        knownCheckouts[identity.checkoutPath] = nil
        for agent in affected { removedWorktreesByAgent[agent] = receipt }
        rebuildRows()
        onChange()
        return receipt
    }

    /// The directory the Worktree is branched from: the launch's own, else the
    /// session's checkout, else its first Pane's path.
    private func sourceDirectory(for request: AgentLaunchRequest) throws -> String {
        if let cwd = request.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return cwd
        }
        guard let workspaceID = request.workspaceID, let inventory else {
            throw HerdrCoreWorktreeError.notInGitRepository
        }
        if let marked = inventory.panes.first(where: { $0.sessionID == workspaceID && !$0.worktree.isEmpty }) {
            return marked.worktree
        }
        if let path = inventory.panes.first(where: { $0.sessionID == workspaceID && !$0.path.isEmpty })?.path {
            return path
        }
        throw HerdrCoreWorktreeError.notInGitRepository
    }

    /// Up to eight names. A session created between the read and `new-session`
    /// comes back as a duplicate, and the next number is tried.
    private func openWorktreeSession(
        _ request: AgentLaunchRequest, directory: String, branch: String, on server: TmuxLaunch.Server,
        hookSettings: String?
    ) async throws -> TmuxLaunch.Created {
        var taken = Set(inventory?.panes.map(\.sessionName) ?? [])
        var name = TmuxLaunch.sessionName(forBranch: branch, taken: taken)
        var lastDuplicate: TransportError?
        for _ in 0..<8 {
            do {
                return try await created(
                    try command {
                        try TmuxLaunch.agentSession(
                            request, workspace: NewWorkspaceSpec(directory: directory, label: name),
                            on: server, hookSettings: hookSettings)
                    })
            } catch let error as TransportError {
                guard case .malformedResponse(let message) = error, message.contains("duplicate session") else {
                    throw error
                }
                taken.insert(name)
                name = TmuxLaunch.sessionName(forBranch: branch, taken: taken)
                lastDuplicate = error
            }
        }
        throw lastDuplicate
            ?? TransportError.malformedResponse(String(localized: "tmux: The session name is already taken."))
    }

    /// The session Heeler opened and could not mark. The checkout stays.
    private func endOpened(_ made: TmuxLaunch.Created) async {
        guard let paths = try? runningPaths() else { return }
        _ = try? await perform(TmuxLaunch.killPane(made.paneID, paths: paths))
    }

    private func worktreeGit() async throws -> HerdrCoreWorktreeGit {
        let services = try await session.withTransport { $0.hostServices }
        return HerdrCoreWorktreeGit(services: services, gate: gitGate, checkoutRoot: ".heeler")
    }

    /// A link lost while the checkout is read has ended nothing yet.
    private func beforeEnding<T>(_ read: () async throws -> T) async throws -> T {
        do {
            return try await read()
        } catch let error as TransportError where error.isRetryable && error != .cancelled {
            throw WorktreeRemovalError.connectionFailedBeforeEnding
        }
    }

    private func sessionsCarrying(_ path: String) -> Set<String> {
        Set(inventory?.panes.filter { $0.worktree == path }.map(\.sessionID) ?? [])
    }

    /// A Pane that joined while the kills were on their way ends too. One that
    /// tmux has already dropped is already ended. After a few rounds of new
    /// Panes, this stops and says so.
    private func endPanes(ofCheckout path: String) async throws {
        var ended: Set<String> = []
        for _ in 0..<Self.paneEndingRounds {
            guard !isAwaitingSnapshot, let inventory else { throw WorktreeRemovalError.terminalsNotEnded }
            let sessions = Set(inventory.panes.filter { $0.worktree == path }.map(\.sessionID))
            var left: [String] = []
            var seen: Set<String> = []
            for pane in inventory.panes where sessions.contains(pane.sessionID) {
                guard seen.insert(pane.paneID).inserted, !ended.contains(pane.paneID) else { continue }
                left.append(pane.paneID)
            }
            guard !left.isEmpty else { return }
            let paths: TmuxPaths
            do {
                paths = try runningPaths()
            } catch {
                throw WorktreeRemovalError.terminalsNotEnded
            }
            for paneID in left {
                do {
                    _ = try await perform(TmuxLaunch.killPane(paneID, paths: paths))
                } catch let error as TransportError {
                    guard case .malformedResponse(let message) = error, message.contains("can't find pane") else {
                        throw WorktreeRemovalError.terminalsNotEnded
                    }
                } catch {
                    throw WorktreeRemovalError.terminalsNotEnded
                }
                ended.insert(paneID)
            }
        }
        throw WorktreeRemovalError.terminalsNotEnded
    }

    private static let paneEndingRounds = 4

    /// Paths an inventory names and git has not. One read, then the rows; it does
    /// not ask again from the rows it just built.
    private func refreshMissingCheckouts(in inventory: TmuxInventory) {
        let missing = Array(Set(inventory.panes.compactMap { pane -> String? in
            let path = pane.worktree
            guard !path.isEmpty, knownCheckouts[path] == nil else { return nil }
            return path
        })).sorted()
        guard !missing.isEmpty else { return }
        checkoutRefresh &+= 1
        let generation = checkoutRefresh
        Task { [weak self] in
            await self?.fetchCheckouts(missing, generation: generation)
        }
    }

    private func fetchCheckouts(_ directories: [String], generation: Int) async {
        guard !hasEnded else { return }
        guard let services = try? await session.withTransport({ $0.hostServices }) else { return }
        let answers = try? await gitGate.run { try await services.checkouts(for: directories) }
        guard let answers, generation == checkoutRefresh, !hasEnded else { return }
        var noted = false
        for (asked, checkout) in answers {
            knownCheckouts[asked] = checkout
            knownCheckouts[checkout.root] = checkout
            noted = true
        }
        guard noted else { return }
        rebuildRows()
        onChange()
    }

    func focusAgent(_ paneID: String) async throws {}
    func renameAgent(_ paneID: String, name: String?) async throws { throw unavailable }

    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        _ = try await perform(TmuxLaunch.renameSession(id: workspaceID, label: label, paths: try runningPaths()))
    }

    /// Paths, kernel and shell for a launch. The shell defaults when the probe
    /// saw none. No paths means the Host has not been asked yet.
    private func launchServer() async throws -> TmuxLaunch.Server {
        let facts = try await session.withTransport { await $0.hostFacts() }
        guard let paths = facts.paths else {
            throw TransportError.tmuxServerNotRunning(socketName: host.tmuxSocketName)
        }
        let shell = facts.shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
        return TmuxLaunch.Server(
            paths: paths, shell: shell, kernel: facts.kernel, running: server != nil,
            openCodeVersion: openCodeVersion)
    }

    /// Keeps `<Helper dir>/tmux/<socket>/paths.json` current when `tmux` moves,
    /// where the Host already holds the Helper or placed Claude Code hooks.
    private func refreshStoredPaths(_ paths: TmuxPaths) async {
        let socket = TmuxSocketName.normalized(host.tmuxSocketName)
        let stored = String(decoding: TmuxClaudeCodeHooks.storedPaths(paths), as: UTF8.self)
        let script = HostHelperScript(
            .refreshTmuxPaths(socket: socket, storedPaths: stored), nonce: HostProcessReader.makeNonce())
        _ = try? await session.withTransport { transport in
            try await transport.hostHelperHost.runHostHelperScript(script)
        }
    }

    // MARK: Claude Code hooks (ADR 0044)

    /// Places Heeler's Claude Code hook script, the settings a launch passes and
    /// the stored tmux paths the script runs, and answers where they went.
    func placeClaudeCodeHooks() async throws -> HostHelperProbe.Locations {
        let paths = try await launchServer().paths
        let locations = try await claudeCodeHookLocations()
        let files = TmuxClaudeCodeHooks.files(
            script: try TmuxClaudeCodeHooks.bundledScript(), paths: paths, dataHome: locations.dataHome)
        let nonce = HostProcessReader.makeNonce()
        let script = TmuxClaudeCodeHooks.placeScript(files, nonce: nonce)
        let result = try await session.withTransport { transport in
            try await transport.runTmuxScript(script, throughLoginShell: false)
        }
        guard TmuxClaudeCodeHooks.isPlaced(result, nonce: nonce) else {
            throw TransportError.malformedResponse(String(localized: "The Host refused Heeler's hook script."))
        }
        return locations
    }

    /// The Host's home and data home, as the Helper's own script finds them.
    func claudeCodeHookLocations() async throws -> HostHelperProbe.Locations {
        if let hookLocations { return hookLocations }
        let nonce = HostProcessReader.makeNonce()
        let script = TmuxClaudeCodeHooks.locateScript(nonce: nonce)
        let result = try await session.withTransport { transport in
            try await transport.runTmuxScript(script, throughLoginShell: false)
        }
        guard result.exitStatus == 0,
            let locations = try? TmuxClaudeCodeHooks.locations(stdout: result.stdout, nonce: nonce)
        else {
            throw TransportError.malformedResponse(String(localized: "Heeler couldn't read where this Host keeps its files."))
        }
        hookLocations = locations
        return locations
    }

    /// The settings file a Claude Code launch passes with `--settings`: nil for
    /// any other program, under a root whose settings already run Heeler's
    /// script, or when the script couldn't be placed. The Agent starts either
    /// way. A root Heeler can't read with certainty gets them too, since one
    /// handler in two settings files runs once.
    private func hookSettings(for request: AgentLaunchRequest) async -> String? {
        guard request.kind == SupportedAgentKind.claude.rawValue,
            let locations = try? await placeClaudeCodeHooks()
        else { return nil }
        let settings = ClaudeCodeHooks.launchSettingsPath(dataHome: locations.dataHome)
        guard let root = TmuxClaudeCodeHooks.root(environment: request.environment, home: locations.home) else {
            return settings
        }
        let session = session
        let path = ClaudeCodeHooks.settingsPath(root: root)
        let current = try? await session.withTransport { transport in
            try await HarnessConfigEditor(files: transport.hostServices).read(path)
        }
        guard let current,
            ClaudeCodeHooks.presence(in: current, script: ClaudeCodeHooks.scriptPath(dataHome: locations.dataHome)) == .on
        else { return settings }
        return nil
    }

    /// Rename and close need a server. A window with none is `TmuxLaunch`'s own
    /// refusal, which stays `.tmuxServerNotRunning` on Linux too.
    private func runningPaths() throws -> TmuxPaths {
        guard let paths = server?.paths else {
            throw TransportError.tmuxServerNotRunning(socketName: host.tmuxSocketName)
        }
        return paths
    }

    /// `TmuxLaunch` refuses before any script. The rest are transport failures.
    private func command(_ make: () throws -> TmuxLaunch.Command) throws -> TmuxLaunch.Command {
        do {
            return try make()
        } catch let refusal as TmuxLaunch.Refusal {
            throw transportError(refusal)
        } catch {
            throw error
        }
    }

    private func transportError(_ refusal: TmuxLaunch.Refusal) -> TransportError {
        switch refusal {
        case .startTmuxOnMac: .tmuxStartOnMac
        case .serverNotRunning: .tmuxServerNotRunning(socketName: host.tmuxSocketName)
        case .missingTarget:
            .malformedResponse(String(localized: "tmux: A launch needs a directory."))
        }
    }

    private func perform(_ command: TmuxLaunch.Command) async throws -> GitExecResult {
        let result = try await session.withTransport { transport in
            try await transport.runTmuxScript(command.script, throughLoginShell: command.throughLoginShell)
        }
        guard result.exitStatus == 0 else {
            let detail = String(decoding: result.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            if let detail {
                throw TransportError.malformedResponse(String(localized: "tmux: \(detail)"))
            }
            throw TransportError.malformedResponse(String(localized: "tmux: The command failed."))
        }
        return result
    }

    private func created(_ command: TmuxLaunch.Command) async throws -> TmuxLaunch.Created {
        let result = try await perform(command)
        guard let created = TmuxLaunch.created(from: result.stdout) else {
            throw TransportError.malformedResponse(String(localized: "tmux: The command printed no pane."))
        }
        return created
    }

    func agentInfo(paneID: String) async throws -> Agent { throw unavailable }
    func processInfo(paneID: String) async throws -> PaneProcessInfo { throw unavailable }
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent { throw unavailable }
    func readAgentScreen(_ paneID: String) async throws -> ANSIScreen { throw unavailable }
    func sendAgentKeys(_ keys: [String], to paneID: String) async throws { throw unavailable }
    func pasteIntoAgent(_ text: String, paneID: String) async throws { throw unavailable }

    /// Each Attach is a control client in a session of Heeler's own (ADR 0043),
    /// on whichever server answers once the connection is up. Another instance
    /// than the one the Terminal first joined has only the same pane ids: that
    /// Terminal is as good as ended, as is one whose Pane is gone.
    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            do {
                try await session.withAttachTransport { transport, generation, server in
                    guard await handler.admitsCore(server.instance.id) else { throw TerminalProgramEnd.finished }
                    await handler.transportDidBecomeReady(generation)
                    var request = request
                    request.coreID = server.instance.id
                    let terminal = try await transport.attachPane(request.target.identifier, request: request)
                    try await handler.runEndingSession(terminal)
                }
            } catch TransportError.tmuxPaneGone, TransportError.tmuxServerGone {
                throw TerminalProgramEnd.finished
            }
        }
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

    /// One variable of the Grok Build process running in a Pane started at
    /// `paneProcessID`, or `.unavailable` when the process tree cannot name one.
    func grokBuildProcessVariable(_ name: String, paneProcessID: Int) async -> HostProcessReader.Variable {
        guard paneProcessID > 0 else { return .unavailable }
        let root = String(paneProcessID)
        let request = HostProcessReader.Request(pids: [root], valuesOf: [name], descendantsOf: root)
        guard let services = try? await session.withTransport({ $0.hostServices }),
            let facts = try? await services.readProcesses(request),
            let pid = Self.grokBuildProcess(in: facts, root: root)
        else { return .unavailable }
        return facts[pid]?.variables[name] ?? .unavailable
    }

    /// The nearest process to `root` named for Grok Build, or `root` itself when
    /// nothing runs below it and it is not a shell. Nil when two are equally near
    /// or the walk could not list the tree.
    static func grokBuildProcess(in facts: [String: HostProcessReader.Facts], root: String) -> String? {
        guard case .value(let descendants) = facts[root]?.descendants else { return nil }
        var children: [String: [String]] = [:]
        for pid in descendants {
            if let parent = facts[pid]?.parent { children[parent, default: []].append(pid) }
        }
        func isGrok(_ fact: HostProcessReader.Facts?) -> Bool {
            guard let name = fact?.name?.lowercased() else { return false }
            return name == "grok" || name == "grok-build"
        }
        var level = [root]
        while !level.isEmpty {
            let named = level.filter { isGrok(facts[$0]) }
            if named.count > 1 { return nil }
            if let found = named.first { return found }
            level = level.flatMap { children[$0] ?? [] }
        }
        guard descendants.isEmpty, let rootName = facts[root]?.name,
            HerdrCoreAgentRule.program(arguments: [], name: rootName) != .shell
        else { return nil }
        return root
    }

    /// The plugin's files belong to Herdr TUI Hosts, and its surfaces say so.
    func withNotificationTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.tmux
    }
}
