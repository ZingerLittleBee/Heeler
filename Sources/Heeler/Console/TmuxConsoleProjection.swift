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
/// Workspace, Rename Workspace and Close run through `TmuxLaunch`. Nothing can
/// be typed into a Pane yet, an Agent is not renamed, and a Terminal is not
/// taken over.
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
    /// The last inventory folded, which a seen mark folds again.
    private var inventory: TmuxInventory?
    /// OpenCode's version from the last discovery, for the next launch's `-s`.
    private var openCodeVersion: String?
    /// The Panes this device shows now, whose finished turns are seen as they end.
    private var shownAgents: Set<String> = []
    /// Where Heeler's Claude Code hook script goes, read once per connection's projection.
    private var hookLocations: HostHelperProbe.Locations?

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
        let organization = TmuxOrganization.build(inventory, statuses: statuses)
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
    ) async throws -> Agent { throw unavailable }

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

    /// The plugin's files belong to Herdr TUI Hosts, and its surfaces say so.
    func withNotificationTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.tmux
    }
}
