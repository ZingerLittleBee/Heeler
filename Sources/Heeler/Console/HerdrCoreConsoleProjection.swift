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
    private(set) var departedAgentsByPane: [String: ConsoleAgent] = [:]
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
    private var shownAgents: Set<String> = []

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
    /// Whether `records` is this link's inventory, not yet another's emptied one.
    private var hasInventory = false
    /// Terminals waiting to hear what became of a program.
    private var programWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// OpenCode's own words from the last discovery, which decide its `-s`.
    private var openCodeVersion: String?
    /// Whether Rename and applying a typed name are offered at all (ADR 0032).
    private let herdrAppRename: Bool
    /// What the last `herdr-app status` on this link said.
    private var isDesktopAppRunning = false
    private var desktopAppCheck: Task<Void, Never>?
    /// Names typed for new Workspaces, by space, until the app adopts the space.
    private var typedSpaceNames: [String: String] = [:]

    init(
        host: Host,
        session: HerdrCoreHostSession,
        memory: HerdrCoreHostMemory,
        pins: PinnedAgentsStore,
        gitGate: GitExecGate,
        herdrAppRename: Bool,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.gitGate = gitGate
        self.herdrAppRename = herdrAppRename
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
            await checkDesktopApp()
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
        desktopAppCheck?.cancel()
        consumeTask = nil
        latencyTask = nil
        environmentTask = nil
        wakeProgramWaiters()
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
        hasInventory = false
        records = []
        terminalsByPane = [:]
        agentsByPane = [:]
        departedAgentsByPane = [:]
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
        desktopAppCheck?.cancel()
        desktopAppCheck = nil
        isDesktopAppRunning = false
    }

    private func replaceInventory(with snapshot: HerdrCoreSnapshot) {
        memory.noteInventory(snapshot.terminals, for: host.id)
        pins.retainPins(hostID: host.id, paneIDs: Set(snapshot.terminals.map(\.address)))
        records = snapshot.terminals
        hasInventory = true
        for record in records {
            noteTurns(of: record.address) { state, kind in
                state.noteSnapshot(
                    turn: record.turn, word: record.status?.state, kind: kind,
                    reported: record.reported)
            }
        }
        transportGeneration = max(transportGeneration, session.currentConnectionGeneration)
        sidebarRevision &+= 1
        readDocument()
        rebuildRows()
        publish()
        if herdrAppRename { Task { await checkDesktopApp() } }
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
            noteTurns(of: record.address) { state, kind in
                if case .restarted = event { state.noteRestart(turn: record.turn) }
                state.noteSnapshot(
                    turn: record.turn, word: record.status?.state, kind: kind,
                    reported: record.reported)
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
            noteTurns(of: terminal) { _, _ in }
        case .status(let terminal, let status, let records, let reported):
            let turn = self.records.first { $0.address == terminal }?.turn ?? 0
            update(terminal) {
                $0.status = status
                $0.records = records
                $0.reported = reported
            }
            noteTurns(of: terminal) { state, kind in
                state.noteStatus(word: status?.state, turn: turn, kind: kind)
            }
        case .turn(let terminal, let turn, _):
            update(terminal) { $0.turn = turn }
            noteTurns(of: terminal) { state, _ in state.noteTurn(turn) }
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
            noteTurns(of: terminal) { _, _ in }
        case .finished(let terminal, _):
            update(terminal) {
                $0.state = "finished"
                $0.pid = nil
                $0.foreground = nil
            }
            noteTurns(of: terminal) { _, _ in }
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

    // MARK: Done per device

    /// Marks each newly shown Agent seen. A turn that ends while one stays shown
    /// is marked as it ends, so it never reads Done.
    func setShownAgents(_ paneIDs: Set<String>) {
        let opened = paneIDs.subtracting(shownAgents)
        shownAgents = paneIDs
        guard !opened.isEmpty else { return }
        // An Agent's menu may be about to offer Rename Workspace.
        if herdrAppRename { Task { await checkDesktopApp() } }
        let wasDone = doneTerminals
        for address in opened {
            memory.updateTurnState(of: address, for: host.id) { $0.markSeen() }
        }
        guard doneTerminals != wasDone else { return }
        rebuildRows()
        publish()
    }

    private var doneTerminals: Set<String> {
        Set(memory.turnStates(for: host.id).filter(\.value.isDone).keys)
    }

    /// Folds one change into a Terminal's turns, with its record already updated.
    private func noteTurns(
        of address: String, _ change: (inout HerdrCoreTurnState, _ kind: String?) -> Void
    ) {
        guard let record = records.first(where: { $0.address == address }) else { return }
        let kind = HerdrCoreAgentRule.agent(in: record)?.kind
        let isShown = shownAgents.contains(address)
        memory.updateTurnState(of: address, for: host.id) { state in
            change(&state, kind)
            if kind == nil { state.noteNoAgent() }
            if isShown { state.markEndedTurnSeen() }
        }
    }

    /// Nothing shows until a link's first document read has settled, so a
    /// desktop Terminal never flashes through a Workspace it does not belong in.
    /// A read nobody answers settles at the link's call deadline.
    private func rebuildRows() {
        guard !isAwaitingSnapshot else { return }
        let organization = HerdrCoreOrganization.build(
            terminals: records, document: document,
            firstSeenDirectories: memory.firstSeenDirectories(for: host.id),
            checkouts: checkouts, home: home, doneTerminals: doneTerminals)
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
        noteDepartedAgents(listed: agents)
        agentsByPane = agents
        statusExplanations = Dictionary(
            uniqueKeysWithValues: records.lazy.filter { rows[$0.address]?.isAgent == true }
                .compactMap { record in
                    HerdrCoreStatusExplanation(record: record).map { (record.address, $0) }
                })
        workspaces = builder.workspaceRows()
        askForCheckouts(organization.checkoutDirectories)
    }

    /// A Terminal between programs hosts no Agent, nor does one that ended, but
    /// a detail open on it stays to show what happens next. An Agent that left
    /// its shell running only left, so nothing stays. One stays until an Agent
    /// is back at the address or the core forgets the Terminal.
    private func noteDepartedAgents(listed agents: [String: ConsoleAgent]) {
        for (address, agent) in agentsByPane where agents[address] == nil {
            guard let record = records.first(where: { $0.address == address }),
                record.hasFinished || record.isRestarting
            else { continue }
            var departed = agent
            departed.agent.status = .unknown
            departedAgentsByPane[address] = departed
        }
        departedAgentsByPane = departedAgentsByPane.filter { address, _ in
            agents[address] == nil && records.contains { $0.address == address }
        }
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
            applyTypedNames()
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

    // MARK: Naming through the desktop app

    /// What the app can name now. A space it shows is one its document lists:
    /// until then there is nothing for `space.rename` to find.
    var desktopAppNaming: HerdrAppNaming? {
        guard herdrAppRename, isDesktopAppRunning else { return nil }
        return HerdrAppNaming(
            workspaceIDs: Set(
                (document?.spaces ?? []).map { HerdrCoreOrganization.spaceWorkspaceID($0.id) }))
    }

    /// One `herdr-app status` at a time. It samples: the app may quit right after,
    /// and a rename sent then fails and asks again.
    func checkDesktopApp() async {
        guard herdrAppRename, !hasEnded else { return }
        if let desktopAppCheck {
            await desktopAppCheck.value
            return
        }
        let check = Task { [weak self, session] in
            let transport = try? await session.withTransport { $0 }
            let isRunning = await transport?.desktopAppIsRunning() ?? false
            guard !Task.isCancelled else { return }
            self?.finishDesktopAppCheck(isRunning: isRunning)
        }
        desktopAppCheck = check
        await check.value
    }

    private func finishDesktopAppCheck(isRunning: Bool) {
        desktopAppCheck = nil
        guard isDesktopAppRunning != isRunning else { return }
        isDesktopAppRunning = isRunning
        publish()
    }

    /// The name is dropped before the one call, so nothing can send it twice. A
    /// failed call leaves the space named after its folder.
    private func applyTypedNames() {
        guard !typedSpaceNames.isEmpty, let document else { return }
        for space in document.spaces {
            guard let name = typedSpaceNames.removeValue(forKey: space.id) else { continue }
            Task { [session] in
                let transport = try? await session.withTransport { $0 }
                try? await transport?.renameDesktopSpace(space.id, name: name)
            }
        }
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
        wakeProgramWaiters()
        onChange()
    }

    // MARK: Inventory

    /// The snapshot and its deltas are the inventory: nothing to ask for.
    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Launches

    /// Through the user's interactive shell, so it finds what an Agent launched
    /// through that shell would find (ADR 0032).
    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        let transport = try await session.withTransport { $0 }
        let shell = try await transport.launchShell()
        let nonce = HostProcessReader.makeNonce()
        let result = try await transport.runAgentDiscovery(
            HerdrCoreLaunch.discoveryScript(shell: shell, nonce: nonce))
        guard
            let installed = try? HerdrCoreLaunch.installedAgents(stdout: result.stdout, nonce: nonce)
        else {
            throw TransportError.malformedResponse("The Host's shell did not finish looking for Agents.")
        }
        openCodeVersion = installed.openCodeVersion
        return installed.kinds
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        try await launch(
            request,
            placement: try await placement(workspaceID: request.workspaceID, directory: request.cwd))
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        try await inNewSpace(workspace) { placement in
            try await launch(request, placement: placement)
        }
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        let placement = try await placement(workspaceID: request.workspaceID, directory: request.cwd)
        return try await startShell(placement: placement)
    }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity {
        try await inNewSpace(workspace) { placement in
            try await startShell(placement: placement)
        }
    }

    /// A core has no Workspace to create: a Terminal labeled with a new space is
    /// one, which a desktop app on this core adopts (ADR 0032). A name goes
    /// through that app afterwards, only if it was offered.
    private func inNewSpace<Started>(
        _ workspace: NewWorkspaceSpec,
        start: (HerdrCoreLaunch.Placement) async throws -> Started
    ) async throws -> Started {
        let name = desktopAppNaming == nil ? nil : workspace.label.flatMap { $0.isEmpty ? nil : $0 }
        let space = HerdrCoreLaunch.Placement.newDesktopSpaceID()
        let started = try await start(.desktopSpace(space, cwd: workspace.directory))
        if let name {
            typedSpaceNames[space] = name
            applyTypedNames()
        }
        return started
    }

    private func launch(
        _ request: AgentLaunchRequest, placement: HerdrCoreLaunch.Placement
    ) async throws -> Agent {
        guard let kind = SupportedAgentKind(rawValue: request.kind) else {
            throw unavailable("Starting \(request.kind)")
        }
        let transport = try await session.withTransport { $0 }
        let shell = try await transport.launchShell()
        let record = try await run(
            HerdrCoreLaunch.agentRequest(
                kind: kind, name: request.name, arguments: request.arguments, shell: shell,
                openCodeVersion: openCodeVersion, placement: placement),
            on: transport)
        return agentsByPane[record.address]?.agent
            ?? Agent(
                terminalID: record.address, kind: kind.rawValue, title: "", status: .unknown,
                workspaceID: HerdrCoreOrganization.workspaceID(
                    of: record, firstSeenDirectories: memory.firstSeenDirectories(for: host.id)),
                tabID: "tab-\(record.address)", paneID: record.address, cwd: record.cwd, revision: 0,
                name: record.name)
    }

    private func startShell(
        placement: HerdrCoreLaunch.Placement
    ) async throws -> ShellTerminalIdentity {
        let transport = try await session.withTransport { $0 }
        let record = try await run(HerdrCoreLaunch.terminalRequest(placement: placement), on: transport)
        return ShellTerminalIdentity(
            paneID: record.address,
            tabID: terminalsByPane[record.address]?.tabID ?? "tab-\(record.address)",
            terminalID: record.address)
    }

    /// One `terminal.run`. Its answer shows at once, so the row a caller opens
    /// next exists, and the core's own `created` event then changes nothing. An
    /// answer past reading started something all the same, so it is not a refusal.
    private func run(
        _ params: JSONValue, on transport: any HerdrCoreTransport
    ) async throws -> HerdrCoreTerminalRecord {
        let reply = try await transport.runTerminal(params: params)
        guard let record = try? HerdrCoreWire.typed(reply) as HerdrCoreTerminalRecord else {
            throw TransportError.coreMutationOutcomeUnknown
        }
        if !hasEnded, !records.contains(where: { $0.address == record.address }) {
            apply(.created(record))
        }
        return record
    }

    /// A desktop space takes the directory asked for, else its own. A derived
    /// Workspace is its key directory and nothing else, or the Terminal would
    /// land in another Workspace. A launch that names no Workspace is a derived one.
    private func placement(
        workspaceID: String?, directory: String?
    ) async throws -> HerdrCoreLaunch.Placement {
        let asked = directory.flatMap { $0.isEmpty ? nil : $0 }
        guard let workspaceID else {
            return HerdrCoreLaunch.Placement(cwd: try await directoryOrHome(asked))
        }
        if let space = HerdrCoreOrganization.desktopSpace(ofWorkspace: workspaceID) {
            let cwd =
                asked
                ?? HerdrCoreOrganization.directory(ofSpace: space, terminals: records, document: document)
            return .desktopSpace(space, cwd: try await directoryOrHome(cwd))
        }
        guard
            let key = HerdrCoreOrganization.keyDirectory(
                ofWorkspace: workspaceID, terminals: records,
                firstSeenDirectories: memory.firstSeenDirectories(for: host.id))
        else {
            throw TransportError.hostFeatureUnavailable(
                feature: "This Workspace has no Terminals left")
        }
        return HerdrCoreLaunch.Placement(cwd: try await directoryOrHome(key.isEmpty ? nil : key))
    }

    private func directoryOrHome(_ directory: String?) async throws -> String {
        if let directory { return directory }
        return try await remoteHomeDirectory()
    }

    // MARK: Closing

    /// The core reports the end in a `finished` event, which takes the row away.
    func closePane(_ paneID: String) async throws {
        try await endTerminals([paneID])
    }

    /// With no inventory, as across a reconnect, nothing says what the Tab holds.
    func closeTab(_ tabID: String) async throws {
        guard !isAwaitingSnapshot else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        try await endTerminals(
            records.map(\.address).filter { terminalsByPane[$0]?.tabID == tabID })
    }

    /// Each Terminal gets its one kill whatever became of the others, so a kill
    /// nobody answered leaves no Terminal unasked. That uncertainty is what the
    /// caller hears over any refusal, since it is what to check before trying again.
    private func endTerminals(_ addresses: [String]) async throws {
        let transport = try await session.withTransport { $0 }
        var failure: (any Error)?
        for address in addresses {
            do {
                try await transport.killTerminal(address)
            } catch TransportError.coreMutationOutcomeUnknown {
                failure = TransportError.coreMutationOutcomeUnknown
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    // MARK: Actions not built yet

    private func unavailable(_ feature: String) -> TransportError {
        .hostFeatureUnavailable(feature: "\(feature) on a herdr-core Host")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        throw unavailable("Worktrees")
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

    /// One `do`, whatever comes of it. A failure asks whether the app still runs,
    /// so a Rename it can no longer serve goes away.
    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        guard desktopAppNaming?.workspaceIDs.contains(workspaceID) == true,
            let space = HerdrCoreOrganization.desktopSpace(ofWorkspace: workspaceID)
        else { throw unavailable("Rename Workspace") }
        let transport = try await session.withTransport { $0 }
        do {
            try await transport.renameDesktopSpace(space, name: label)
        } catch {
            Task { await checkDesktopApp() }
            throw error
        }
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
    ///
    /// The core reports a program's end apart from its attach, so what follows a
    /// CLOSE comes from the events: a lost program takes the attach with it and
    /// restarts, an exited one ends the Terminal (ADR 0032).
    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { [weak self] request, handler in
            let address = request.target.identifier
            let program = try await self?.programToAttach(at: address, handler: handler)
            do {
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
            } catch let refusal as HerdrAPIError
                where refusal.code == "finished" || refusal.code == "not_found"
            {
                throw TerminalProgramEnd.finished
            } catch let refusal as HerdrAPIError where refusal.code == "unavailable" {
                // Between a loss and its shell, before word of the loss got here.
            }
            try await self?.followProgram(
                at: address, attachedTo: program ?? .unknown, handler: handler)
        }
    }

    // MARK: A Terminal's program

    private enum ProgramState: Equatable {
        /// No inventory on this link yet.
        case unknown
        case absent
        case running(pid: Int?)
        case restarting
        case finished
    }

    /// How long a CLOSE waits for the event that explains it. The core sends the
    /// event first on the same connection (`runtime.rs` `record_finish`), so only
    /// this side's scheduling stands between them. A CLOSE nothing explains then
    /// reads as a session that ended, which offers Reattach.
    private static let programEndGrace: Duration = .seconds(2)

    private func programState(of address: String) -> ProgramState {
        guard hasInventory else { return .unknown }
        guard let record = records.first(where: { $0.address == address }) else { return .absent }
        if record.hasFinished { return .finished }
        return record.isRestarting ? .restarting : .running(pid: record.pid)
    }

    /// What an attach is about to join. A Terminal between programs takes none
    /// until its new shell, so opening one waits here.
    private func programToAttach(
        at address: String, handler: TerminalSessionHandler
    ) async throws -> ProgramState {
        while true {
            try checkStillWaiting()
            let state = programState(of: address)
            switch state {
            case .finished:
                throw TerminalProgramEnd.finished
            case .restarting:
                handler.programWasLost()
                await nextProgramChange(before: nil)
            case .unknown, .absent, .running:
                return state
            }
        }
    }

    /// The core closed an attach on `program`, or refused one. Returning means
    /// nothing explains it.
    private func followProgram(
        at address: String, attachedTo program: ProgramState, handler: TerminalSessionHandler
    ) async throws {
        var deadline: ContinuousClock.Instant? = .now + Self.programEndGrace
        while true {
            try checkStillWaiting()
            switch programState(of: address) {
            case .finished:
                throw TerminalProgramEnd.finished
            case .absent:
                // Removed, unless this Terminal was never listed to begin with.
                if case .running = program { throw TerminalProgramEnd.finished }
                if deadline == nil { throw TerminalProgramEnd.finished }
                return
            case .restarting:
                handler.programWasLost()
                deadline = nil
            case .running(let pid):
                // Another process means the restart went by before this CLOSE.
                if deadline == nil { throw TerminalProgramEnd.restarted }
                if case .running(let attached) = program, attached != pid {
                    throw TerminalProgramEnd.restarted
                }
            case .unknown:
                break
            }
            if let deadline, .now >= deadline { return }
            await nextProgramChange(before: deadline)
        }
    }

    private func checkStillWaiting() throws {
        try Task.checkCancellation()
        guard !hasEnded else { throw TransportError.cancelled }
        if case .failed(let failure) = status { throw failure }
    }

    private func nextProgramChange(before deadline: ContinuousClock.Instant?) async {
        let id = UUID()
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                self?.programWaiters.removeValue(forKey: id)?.resume()
            }
        }
        defer { timer?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    programWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.programWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func wakeProgramWaiters() {
        let waiters = programWaiters.values
        programWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    func imageStager() -> ImageStager {
        let session = session
        return { image, reporter in
            try await session.withTransport { $0.hostServices }.stageImage(image) { progress in
                await reporter.report(progress)
            }
        }
    }

    func fileStager() -> FileStager {
        let session = session
        return { file, reporter in
            try await session.withTransport { $0.hostServices }.stageFile(file) { progress in
                await reporter.report(progress)
            }
        }
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
        try await session.withTransport { $0.hostServices }.listDirectories(at: path)
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
