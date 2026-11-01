import Foundation

/// What an event says of a Terminal's program.
enum HerdrCoreProgramChange: Equatable, Sendable {
    /// A sample of its foreground; nil when the core can no longer name one.
    case sample(HerdrCoreForeground?)
    /// The program lost, finished or removed, or replaced by a new shell.
    case ended
}

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
    /// Stays through `invalidateInventory`, for a detail open while the link
    /// recovers. A snapshot replaces it, from whichever core answers.
    private(set) var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var status: EventsSessionStatus?
    /// See Standing Failure in `CONTEXT.md`.
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var leakedEnvironmentNames: Set<String> = []
    /// As `uname -s` prints it, once a link has located the core.
    private(set) var kernel: String?
    /// Why each Agent reading Unknown does, by Terminal address.
    private(set) var statusExplanations: [String: HerdrCoreStatusExplanation] = [:]
    private(set) var transportGeneration: UInt64 = 0
    private(set) var sidebarRevision: UInt64 = 0
    /// `.connected` precedes the subscribe snapshot, so an empty projection in
    /// this window means "unknown", not "no Terminals".
    private(set) var isAwaitingSnapshot = true

    let syncError: String? = nil
    /// What a removed Worktree's Agents show. An address is never reused, so no
    /// later row can inherit one.
    private(set) var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
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
    /// Events that may mean a Terminal's session changed, for Chat (ADR 0034).
    private var sessionEventCounts: [String: UInt64] = [:]
    private var inventoryReplacements: UInt64 = 0
    /// Leak checks that found a variable, which a Chat's reason depends on.
    private var leakAnswers: UInt64 = 0

    private let gitGate: GitExecGate
    private var document: HerdrCoreDesktopDocument?
    private var documentVersion: Int?
    private var documentRead: Task<Void, Never>?
    private var readsDocumentAgain = false
    /// A directory's Checkout. Its root is itself when it is in no checkout.
    private var checkouts: [String: HostCheckout] = [:]
    private var workspacesByID: [String: WorkspaceInfo] = [:]
    /// What a removal in progress on each Worktree began with: the Agents it
    /// ends. It stays after a failure, when its Workspace may have no Terminal
    /// left to be found by, so that trying again still can.
    private var worktreeRemovals: [WorktreeIdentity: Set<ConsoleAgent.ID>] = [:]
    private var worktreesBeingRemoved: Set<WorktreeIdentity> = []
    private var askedCheckouts: Set<String> = []
    private var queuedCheckouts: [String] = []
    private var checkoutTask: Task<Void, Never>?
    private var home: String?
    private var hasAskedHome = false
    /// Whether `records` is this link's inventory, not yet another's emptied one.
    private var hasInventory = false
    /// Moves with every event or snapshot that speaks of a foreground.
    private var foregroundChanges = 0
    /// Terminals waiting to hear what became of a program.
    private var programWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var programWatches:
        [UUID: (address: String, onChange: @MainActor (HerdrCoreProgramChange) -> Void)] = [:]
    /// OpenCode's own words from the last discovery, which decide its `-s`.
    private var openCodeVersion: String?
    /// Whether Rename and applying a typed name are offered at all (ADR 0032).
    private let herdrAppRename: Bool
    private let chatTypingClock: BlockedCardClock
    private var chatTypings: [String: HerdrCoreChatTyping] = [:]
    /// What the last `herdr-app status` on this link said.
    private var isDesktopAppRunning = false
    private var desktopAppCheck: Task<Void, Never>?
    /// Names typed for new Workspaces, by space, until the app adopts the space.
    private var typedSpaceNames: [String: String] = [:]
    /// Hears every seen mark of this Host when one changes, for its Host Helper.
    private let onSeenMarksChanged: @MainActor (String, [String: HerdrCoreTurnState.Mark]) -> Void

    init(
        host: Host,
        session: HerdrCoreHostSession,
        memory: HerdrCoreHostMemory,
        pins: PinnedAgentsStore,
        gitGate: GitExecGate,
        herdrAppRename: Bool,
        chatTypingClock: BlockedCardClock = .live,
        onSeenMarksChanged: @escaping @MainActor (String, [String: HerdrCoreTurnState.Mark]) -> Void = { _, _ in },
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.gitGate = gitGate
        self.herdrAppRename = herdrAppRename
        self.chatTypingClock = chatTypingClock
        self.onSeenMarksChanged = onSeenMarksChanged
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
                // A Chat that checked before this answer named the wrong fix.
                if !self.leakedEnvironmentNames.isEmpty { self.leakAnswers &+= 1 }
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
                chatTypings = [:]
            }
            memory.noteCore(coreID, for: host.id)
            readKernelOnce()
            replaceInventory(with: snapshot)
        case .event(let event):
            apply(event)
        }
    }

    /// The locator already ran for this link, so this reads no Host.
    private func readKernelOnce() {
        guard kernel == nil else { return }
        Task { [weak self, session] in
            let kernel = try? await session.withTransport { await $0.lastLocation()?.kernel }
            guard let self, let kernel, self.kernel != kernel else { return }
            self.kernel = kernel
            self.publish()
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
        workspacesByID = [:]
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
        inventoryReplacements += 1
        memory.noteInventory(snapshot.terminals, for: host.id)
        pins.retainPins(hostID: host.id, paneIDs: Set(snapshot.terminals.map(\.address)))
        records = snapshot.terminals
        foregroundChanges &+= 1
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
        for watch in programWatches.values {
            let record = records.first { $0.address == watch.address }
            if let record, !record.hasFinished, !record.isRestarting {
                watch.onChange(.sample(record.foreground))
            } else {
                watch.onChange(.ended)
            }
        }
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
            if case .restarted = event { notifyProgramWatches(of: record.address, .ended) }
        case .size(let terminal, let columns, let rows):
            update(terminal) {
                $0.columns = columns
                $0.rows = rows
            }
        case .title(let terminal, let title):
            update(terminal) { $0.title = title }
        case .foreground(let terminal, let foreground):
            sessionEventCounts[terminal, default: 0] += 1
            foregroundChanges &+= 1
            update(terminal) { $0.noteForeground(foreground) }
            noteTurns(of: terminal) { _, _ in }
            notifyProgramWatches(of: terminal, .sample(foreground))
        case .status(let terminal, let status, let records, let reported):
            sessionEventCounts[terminal, default: 0] += 1
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
            sessionEventCounts[terminal, default: 0] += 1
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
            notifyProgramWatches(of: terminal, .ended)
        case .finished(let terminal, let end):
            update(terminal) {
                $0.state = "finished"
                $0.pid = nil
                $0.foreground = nil
                $0.exitCode = end.exitCode
            }
            noteTurns(of: terminal) { _, _ in }
            sidebarRevision &+= 1
            notifyProgramWatches(of: terminal, .ended)
        case .removed(let terminal):
            memory.forgetTerminal(terminal, for: host.id)
            pins.removePin(hostID: host.id, paneID: terminal)
            records.removeAll { $0.address == terminal }
            chatTypings[terminal] = nil
            sidebarRevision &+= 1
            notifyProgramWatches(of: terminal, .ended)
        case .missed(let snapshot):
            replaceInventory(with: snapshot)
            return
        case .dropped:
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
        case .heartbeat, .unknown:
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
        let marksBefore = seenMarks
        for address in opened {
            memory.updateTurnState(of: address, for: host.id) { $0.markSeen() }
        }
        reportSeenMarks(ifChangedFrom: marksBefore)
        guard doneTerminals != wasDone else { return }
        rebuildRows()
        publish()
    }

    private var doneTerminals: Set<String> {
        Set(memory.turnStates(for: host.id).filter(\.value.isDone).keys)
    }

    private var seenMarks: [String: HerdrCoreTurnState.Mark] {
        memory.turnStates(for: host.id).compactMapValues(\.seen)
    }

    /// Every mark this device holds, for a new registration's first file.
    var currentSeenMarks: (core: String, marks: [String: HerdrCoreTurnState.Mark])? {
        memory.coreID(for: host.id).map { ($0, seenMarks) }
    }

    private func reportSeenMarks(ifChangedFrom before: [String: HerdrCoreTurnState.Mark]) {
        let marks = seenMarks
        guard marks != before, let core = memory.coreID(for: host.id) else { return }
        onSeenMarksChanged(core, marks)
    }

    /// Folds one change into a Terminal's turns, with its record already updated.
    private func noteTurns(
        of address: String, _ change: (inout HerdrCoreTurnState, _ kind: String?) -> Void
    ) {
        guard let record = records.first(where: { $0.address == address }) else { return }
        let kind = HerdrCoreAgentRule.agent(in: record)?.kind
        let isShown = shownAgents.contains(address)
        let marksBefore = isShown ? seenMarks : [:]
        memory.updateTurnState(of: address, for: host.id) { state in
            change(&state, kind)
            if kind == nil { state.noteNoAgent() }
            if isShown { state.markEndedTurnSeen() }
        }
        if isShown { reportSeenMarks(ifChangedFrom: marksBefore) }
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
        workspacesByID = builder.workspaceByID
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
            let answers = try? await gitGate.run { try await services.checkouts(for: batch) }
            guard !Task.isCancelled else { return }
            if let answers {
                for directory in batch {
                    checkouts[directory] = answers[directory] ?? HostCheckout(root: directory)
                }
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
        if !isAwaitingSnapshot { lastKnownAgentsByPane = agentsByPane }
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

    func availableTemplates() async throws -> [AgentTemplate] {
        try await session.withTransport { $0 }.listTemplates()
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

    /// Placed as any other launch is, and started by the core with neither the
    /// shell nor a kind of Heeler's, so the Agent's kind comes from its record.
    /// A program Heeler does not know is no Agent until it reports. The core runs
    /// a name with no file as a program, and no call of its asks for a Template
    /// only, so the list is read again before anything happens and the answer is
    /// checked after: the file can still go in between.
    func startTemplate(_ request: TemplateLaunchRequest) async throws -> Agent {
        let templates = try await session.withTransport { $0 }.listTemplates()
        guard templates.contains(where: { $0.name == request.template }) else {
            throw HerdrCoreTemplateError.gone(request.template)
        }
        if let worktree = request.worktree {
            return try await inNewWorktree(worktree, of: request.workspaceID) { placement in
                try await runTemplate(request, placement: placement)
            }
        }
        if let workspace = request.newWorkspace {
            return try await inNewSpace(workspace) { placement in
                try await runTemplate(request, placement: placement)
            }
        }
        return try await runTemplate(
            request,
            placement: try await placement(workspaceID: request.workspaceID, directory: request.cwd))
    }

    private func runTemplate(
        _ request: TemplateLaunchRequest, placement: HerdrCoreLaunch.Placement
    ) async throws -> Agent {
        let transport = try await session.withTransport { $0 }
        let record = try fold(
            runReply: try await transport.runTemplate(
                params: HerdrCoreLaunch.templateRequest(
                    template: request.template, name: request.name, placement: placement)))
        guard record.template == request.template else {
            throw HerdrCoreTemplateError.ranAsProgram(request.template, directory: record.cwd)
        }
        return agent(at: record, kind: HerdrCoreAgentRule.agent(in: record)?.kind ?? "unknown")
    }

    /// An exit is final even for a kept Terminal, and a lost program is not.
    func programExit(ofPane paneID: String) -> ProgramExit? {
        guard let record = records.first(where: { $0.address == paneID }), record.hasFinished else {
            return nil
        }
        return ProgramExit(code: record.exitCode)
    }

    /// A name stays with its Terminal for as long as the core calls it live,
    /// which covers a kept one between programs.
    var heldTerminalNames: Set<String> {
        Set(records.lazy.filter { !$0.hasFinished }.compactMap(\.name))
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
        let record = try fold(
            runReply: try await transport.runTerminal(
                params: HerdrCoreLaunch.agentRequest(
                    kind: kind, name: request.name, arguments: request.arguments, shell: shell,
                    openCodeVersion: openCodeVersion, placement: placement)))
        return agent(at: record, kind: kind.rawValue)
    }

    /// The row a launch made, or one to stand in until it shows.
    private func agent(at record: HerdrCoreTerminalRecord, kind: String) -> Agent {
        agentsByPane[record.address]?.agent
            ?? Agent(
                terminalID: record.address, kind: kind, title: "", status: .unknown,
                workspaceID: HerdrCoreOrganization.workspaceID(
                    of: record, firstSeenDirectories: memory.firstSeenDirectories(for: host.id)),
                tabID: "tab-\(record.address)", paneID: record.address, cwd: record.cwd, revision: 0,
                name: record.name)
    }

    private func startShell(
        placement: HerdrCoreLaunch.Placement
    ) async throws -> ShellTerminalIdentity {
        let transport = try await session.withTransport { $0 }
        let record = try fold(
            runReply: try await transport.runTerminal(
                params: HerdrCoreLaunch.terminalRequest(placement: placement)))
        return ShellTerminalIdentity(
            paneID: record.address,
            tabID: terminalsByPane[record.address]?.tabID ?? "tab-\(record.address)",
            terminalID: record.address)
    }

    /// One `terminal.run`'s answer. It shows at once, so the row a caller opens
    /// next exists, and the core's own `created` event then changes nothing. An
    /// answer past reading started something all the same, so it is not a refusal.
    private func fold(runReply reply: JSONValue) throws -> HerdrCoreTerminalRecord {
        guard let record = try? HerdrCoreWire.typed(reply) as HerdrCoreTerminalRecord else {
            throw TransportError.coreMutationOutcomeUnknown
        }
        if !hasEnded, !records.contains(where: { $0.address == record.address }) {
            apply(.created(record))
        }
        return record
    }

    /// The directory a launch from an Agent would land in, for the form to show.
    /// Only a derived Workspace overrides the Agent's directory, as `placement` does.
    func launchDirectory(ofWorkspace workspaceID: String, asked: String) -> String {
        guard HerdrCoreOrganization.desktopSpace(ofWorkspace: workspaceID) == nil,
            let key = HerdrCoreOrganization.keyDirectory(
                ofWorkspace: workspaceID, terminals: records,
                firstSeenDirectories: memory.firstSeenDirectories(for: host.id)),
            !key.isEmpty
        else { return asked }
        return key
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
        do {
            try await endTerminals(
                records.map(\.address).filter { terminalsByPane[$0]?.tabID == tabID }
            ) { [pins, host] address in
                pins.removePin(hostID: host.id, paneID: address)
            }
        } catch {
            // The caller drops no Pin on a throw, and this may have.
            publish()
            throw error
        }
    }

    /// Each Terminal gets its one kill whatever became of the others, so a kill
    /// nobody answered leaves no Terminal unasked. That uncertainty is what the
    /// caller hears over any refusal, since it is what to check before trying again.
    private func endTerminals(
        _ addresses: [String], onEnded: (String) -> Void = { _ in }
    ) async throws {
        let transport = try await inventoryTransport()
        var failure: (any Error)?
        for address in addresses {
            do {
                try await transport.killTerminal(address)
                onEnded(address)
            } catch TransportError.coreMutationOutcomeUnknown {
                failure = TransportError.coreMutationOutcomeUnknown
            } catch let refusal as HerdrAPIError {
                failure = failure ?? HerdrCoreCloseRefusal(message: refusal.message)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    // MARK: Composer Stop (ADR 0035)

    func interruptTerminal(at address: String, timeout: Duration) async throws {
        let transport = try await inventoryTransport()
        try await transport.interruptTerminal(address, timeout: timeout)
    }

    /// Reads whether the Terminal's program still runs and folds the answer, so a
    /// program that left stops being the Agent without waiting for the next sample.
    /// Nothing orders a reply against the events, so whatever spoke of the
    /// foreground while this was on its way is at least as new.
    func readForeground(at address: String) async throws {
        let changes = foregroundChanges
        let record = try await inventoryTransport().terminalRecord(address)
        guard !hasEnded, foregroundChanges == changes, let foreground = record.foreground else {
            return
        }
        apply(.foreground(terminal: address, foreground))
    }

    // MARK: Worktrees

    /// Off on native Windows until one passes a test there (ADR 0032).
    private func worktreeGit() async throws -> HerdrCoreWorktreeGit {
        let services = try await session.withTransport { $0.hostServices }
        guard try await services.hostPlatform() == .posix else { throw unavailable("Worktrees") }
        return HerdrCoreWorktreeGit(services: services, gate: gitGate)
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        try await inNewWorktree(worktree, of: request.workspaceID) { placement in
            try await launch(request, placement: placement)
        }
    }

    /// The checkout comes first, then a new Workspace there as New Workspace
    /// opens one. No git command is sent twice.
    private func inNewWorktree(
        _ worktree: WorktreeSpec, of workspaceID: String?,
        start: (HerdrCoreLaunch.Placement) async throws -> Agent
    ) async throws -> Agent {
        let git = try await worktreeGit()
        let source = try await placement(workspaceID: workspaceID, directory: nil).cwd
        let created = try await git.create(branch: worktree.branch ?? "", from: source)
        // Before the first row shows, so it already reads as the Worktree it is.
        checkouts[created.path] = HostCheckout(
            root: created.path, mainCheckout: created.mainCheckout, isLinkedWorktree: true)
        askedCheckouts.insert(created.path)
        do {
            return try await inNewSpace(NewWorkspaceSpec(directory: created.path), start: start)
        } catch TransportError.coreMutationOutcomeUnknown {
            throw TransportError.coreMutationOutcomeUnknown
        } catch let started as HerdrCoreTemplateError {
            throw started
        } catch {
            throw WorktreeAgentStartFailure(checkoutPath: created.path, underlying: error)
        }
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        guard let checkout = workspacesByID[workspaceID]?.worktree else {
            throw WorktreeRemovalError.staleIdentity
        }
        let entries = try await worktreeGit().list(in: checkout.checkoutPath)
        return WorktreeListResponse(
            source: WorktreeSourceInfo(
                repoKey: checkout.repoKey, repoName: checkout.repoName, repoRoot: checkout.repoRoot,
                sourceCheckoutPath: checkout.checkoutPath, sourceWorkspaceID: workspaceID),
            worktrees: entries.map { entry in
                let workspace = workspacesByID.values.first {
                    $0.worktree?.checkoutPath == entry.path
                }
                return WorktreeInfo(
                    isBare: entry.isBare, isDetached: entry.isDetached,
                    isLinkedWorktree: entry.isLinkedWorktree, isPrunable: entry.isPrunable,
                    label: entry.label, path: entry.path, branch: entry.branch,
                    openWorkspaceID: workspace?.workspaceID)
            })
    }

    func worktreeRemovalRisk(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        try await worktreeGit().removalRisk(ofCheckout: request.identity.checkoutPath)
    }

    /// Every Terminal of the Workspace ends first, and only then does git remove
    /// the checkout, so nothing keeps running in a deleted folder. Which Terminals
    /// comes from the membership computed here, never from labels alone: any
    /// process can rewrite those. What the checkout would lose is checked against
    /// what the request's confirmation named before anything ends, and again once
    /// the Terminals have ended, since they can write on their way out. That last
    /// read is what forces the removal, so force covers only what the user heard.
    func removeWorktree(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt {
        let identity = request.identity
        guard identity.hostID == host.id else { throw WorktreeRemovalError.staleIdentity }
        guard !isAwaitingSnapshot else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        guard worktreesBeingRemoved.insert(identity).inserted else {
            throw WorktreeRemovalError.alreadyInProgress
        }
        defer { worktreesBeingRemoved.remove(identity) }

        let git = try await worktreeGit()
        if worktreeRemovals[identity] == nil {
            guard
                let checkout = workspacesByID[identity.workspaceID]?.worktree
                    .map(RepositoryCheckout.init),
                identity.matches(checkout)
            else { throw WorktreeRemovalError.staleIdentity }
        }
        let mainCheckout = try await git.verifiedMainCheckout(of: identity)
        let risk = try await git.removalRisk(ofCheckout: identity.checkoutPath)
        guard risk.isCovered(by: request.toldRisk) else {
            throw WorktreeRemovalError.changedSinceConfirmation
        }

        let agents = agentsByPane.values.filter { $0.agent.workspaceID == identity.workspaceID }
        worktreeRemovals[identity, default: []].formUnion(agents.map(\.id))
        try await endTerminals(ofWorkspace: identity.workspaceID)
        let settled = try await git.riskOnceTerminalsEnded(ofCheckout: identity.checkoutPath)
        guard settled.isCovered(by: request.toldRisk) else {
            throw WorktreeRemovalError.changedWhileTerminalsEnded
        }
        try await git.remove(
            path: identity.checkoutPath, mainCheckout: mainCheckout, force: settled.requiresForce)

        let receipt = WorktreeRemovalReceipt(
            request: request, affectedAgentIDs: worktreeRemovals[identity] ?? [])
        worktreeRemovals[identity] = nil
        checkouts[identity.checkoutPath] = nil
        askedCheckouts.remove(identity.checkoutPath)
        for agent in receipt.affectedAgentIDs { removedWorktreesByAgent[agent] = receipt }
        publish()
        return receipt
    }

    /// A Terminal that joined while the kills were on their way ends too. How
    /// many more can join is up to whatever starts them, so this stops asking and
    /// says so after a few rounds. With no inventory, nothing says who is left.
    private func endTerminals(ofWorkspace workspaceID: String) async throws {
        var ended: Set<String> = []
        for _ in 0..<Self.terminalEndingRounds {
            guard !isAwaitingSnapshot else { throw WorktreeRemovalError.terminalsNotEnded }
            let left = records.map(\.address).filter {
                !ended.contains($0) && terminalsByPane[$0]?.workspaceID == workspaceID
            }
            guard !left.isEmpty else { return }
            do {
                try await endTerminals(left)
            } catch {
                throw WorktreeRemovalError.terminalsNotEnded
            }
            ended.formUnion(left)
        }
        throw WorktreeRemovalError.terminalsNotEnded
    }

    private static let terminalEndingRounds = 4

    // MARK: Actions not built yet

    private func unavailable(_ feature: String) -> TransportError {
        .hostFeatureUnavailable(feature: "\(feature) on a herdr-core Host")
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
        try await chatTyping(at: paneID).readScreen()
    }

    func sendAgentKeys(_ keys: [String], to paneID: String) async throws {
        try await chatTyping(at: paneID).press(keys)
    }

    func pasteIntoAgent(_ text: String, paneID: String) async throws {
        try await chatTyping(at: paneID).paste(text)
    }

    /// How Chat reads and types in a Terminal (ADR 0035), kept so the screen it
    /// last read is the one its keys are checked against.
    func chatTyping(at address: String) -> HerdrCoreChatTyping {
        if let typing = chatTypings[address] { return typing }
        let typing = HerdrCoreChatTyping(address: address, projection: self, clock: chatTypingClock)
        chatTypings[address] = typing
        return typing
    }

    /// A viewer of Chat's own on the Host's one link, joining at the size the
    /// Terminal has. It reports no display facts and takes no focus.
    func openChatViewer(at address: String, as role: TerminalViewerRole) async throws -> TerminalAttachSession {
        var record = terminalRecord(at: address)
        if record == nil { record = try await readTerminalRecord(at: address) }
        guard let record else { throw TransportError.cancelled }
        let request = TerminalAttachRequest(
            target: .terminal(address), viewer: role, surfaceHasHistory: true,
            cols: record.columns, rows: record.rows)
        return try await session.withTerminalTransport { transport, _, _ in
            try await transport.attachTerminal(request)
        }
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
                try await session.withTerminalTransport { transport, generation, coreID in
                    // Another core at this socket has its own Terminal at this
                    // address. This one is as good as ended (ADR 0031).
                    guard await handler.admitsCore(coreID) else { throw TerminalProgramEnd.finished }
                    await handler.transportDidBecomeReady(generation)
                    #if DEBUG
                    await handler.attachRequestDidStart()
                    #endif
                    var request = request
                    request.coreID = coreID
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

    // MARK: What Composer Send checks (ADR 0035)

    /// A Terminal's record as this link's events left it. Nil between links.
    func terminalRecord(at address: String) -> HerdrCoreTerminalRecord? {
        records.first { $0.address == address }
    }

    /// The Terminal's record as the core knows it now. Waits for a link, and
    /// refuses one whose core is not the one these records came from.
    func readTerminalRecord(at address: String) async throws -> HerdrCoreTerminalRecord {
        try await inventoryTransport().terminalRecord(address)
    }

    /// For anything sent to an address this inventory lists, which means another
    /// Terminal on any other core.
    private func inventoryTransport() async throws -> any HerdrCoreTransport {
        try await session.withTransport(servingCore: inventoryCore) { $0 }
    }

    /// The core this inventory's addresses mean.
    var inventoryCore: String? {
        memory.coreID(for: host.id)
    }

    /// Whether what keeps to `pin` still means this inventory's Terminals.
    func admits(_ pin: TerminalCorePin) -> Bool {
        inventoryCore.map(pin.admits) ?? true
    }

    /// Calls `onChange` with what the events say of `address`'s program until
    /// `endProgramWatch`.
    func watchProgram(
        at address: String, onChange: @escaping @MainActor (HerdrCoreProgramChange) -> Void
    ) -> UUID {
        let id = UUID()
        programWatches[id] = (address, onChange)
        return id
    }

    func endProgramWatch(_ id: UUID) {
        programWatches[id] = nil
    }

    private func notifyProgramWatches(of address: String, _ change: HerdrCoreProgramChange) {
        for watch in programWatches.values where watch.address == address {
            watch.onChange(change)
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

    // MARK: Chat

    /// Moves with each status, turn or foreground event of the Terminal, each
    /// fresh inventory, since those events may have been missed, and each leak
    /// check that found something, since a reason names what the core carries.
    /// Chat checks the Agent's process again when it moves (ADR 0034).
    func sessionEventRevision(of address: String) -> UInt64 {
        inventoryReplacements &+ leakAnswers &+ (sessionEventCounts[address] ?? 0)
    }

    /// Keys Chat's cache: nil before the first link named its core.
    var chatCacheScope: String? {
        memory.coreID(for: host.id).map { ChatCacheKey.coreScope(session: host.sessionName, coreID: $0) }
    }

    /// One check of the Agent's process: one exec and at most one SFTP read.
    func checkChatSession(paneID: String, program: ChatProgram) async throws -> ChatSessionEvidence {
        // No inventory is no evidence either way: a Chat keeps what it shows and
        // the snapshot's fresh inventory asks again. A Send here says it couldn't
        // check.
        guard hasInventory else { throw TransportError.cancelled }
        // An Agent that left has no process to look at, and nothing it left says
        // which conversation it was in. Its Chat says what became of it.
        guard departedAgentsByPane[paneID] == nil else { throw TransportError.cancelled }
        guard let record = terminalRecord(at: paneID) else {
            return .unavailable(.cannotTellSession(program))
        }
        let session = session
        let core = inventoryCore
        let binder = HerdrCoreSessionBinder(
            program: program,
            processes: { request in
                try await session.withTransport { try await $0.readProcesses(request) }
            },
            files: chatHostFiles(),
            clearLabels: { stale in
                try await self.clearStaleLabels(stale, at: paneID, on: core)
            },
            currentLabels: {
                await self.terminalLabels(at: paneID, on: core)
            })
        return try await binder.check(record, coreCarries: leakedEnvironmentNames)
    }

    /// The Terminal's labels while these records are still the core's a check began on.
    private func terminalLabels(at paneID: String, on core: String?) -> [String: String]? {
        guard inventoryCore == core else { return nil }
        return terminalRecord(at: paneID)?.labels
    }

    /// Removes the labels a check found stale, except any that has changed since,
    /// which is the next Agent's own. `terminal.label` replaces by name with no
    /// compare, so a label the core took within one round trip of this call still
    /// goes, and only that Agent's next write brings it back (herdr compatibility).
    func clearStaleLabels(_ stale: [String: String], at paneID: String, on core: String?) async throws {
        // The check takes a while, and this record is the core's it began on.
        let transport = try await session.withTransport(servingCore: core) { $0 }
        let current = terminalLabels(at: paneID, on: core)
        let names = stale.keys.filter { current?[$0] == stale[$0] }
        guard !names.isEmpty else { return }
        let params = JSONValue.object([
            "terminal": .string(paneID),
            "labels": .object(Dictionary(uniqueKeysWithValues: names.map { ($0, JSONValue.string("")) })),
        ])
        _ = try await transport.call("terminal.label", params: params, isMutation: true)
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
            queryOpenCode: { query in
                try await session.withTransport { $0.hostServices }.queryOpenCode(query)
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
