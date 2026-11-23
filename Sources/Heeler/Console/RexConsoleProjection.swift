import Foundation

/// A Rex Host's share of the Console (ADRs 0049 and 0050): its connection, the
/// server that answers on its socket, and the terminals that server lists. A
/// session is a Workspace, a window a Tab and a terminal block a Pane, as
/// `RexOrganization` reads them, and a terminal running a known agent program
/// is an Agent with the status it reported to Rex (ADR 0054).
///
/// A Pane keeps to its server instance, as a tmux Pane does: another instance
/// leaves every detail open on the last one's terminals, and its Pins go. A
/// terminal opens from the server's redraw (ADR 0051) and takes input from its
/// first paint (ADR 0052), whether it is a Terminal or the Terminal surface of
/// an Agent's detail. Nothing is started, closed or renamed on a Rex Host, and
/// nothing runs on it but Chat's reads and the staging of what the user
/// attaches: what Chat needs of the Host it reads over the same SSH
/// connection (`RexHostReads`), and two things are written there, each only
/// when the user asks: a file or image staged for a message
/// (`RexHostStaging`), and Heeler's extension in the folder a Pi or Oh My Pi
/// Agent loads from (`RexHostExtensionPlacing`, ADR 0056). Chat and the
/// Composer read a terminal's screen and type into it on the control link,
/// one checked request at a time (`RexChatTyping`, `RexComposerSend`, ADR
/// 0055), the staged paths with the message.
///
/// Done is per device, as on a tmux Host: each terminal's turns and this
/// device's seen marks (`RexTurnState`) are kept by server instance on this
/// device only, and an Agent's detail on either surface is looking at it.
@MainActor
final class RexConsoleProjection: ConsoleHostProjection {
    private(set) var host: Host
    let session: RexHostSession

    private(set) var status: EventsSessionStatus?
    private(set) var standingFailure: TransportError?
    private(set) var latency: Duration?
    private(set) var routeID: UUID?
    private(set) var transportGeneration: UInt64 = 0
    /// The server on the Host's socket, while one answers.
    private(set) var server: RexServerStatus?
    /// The instance whose terminals a detail keeps to: the last that answered,
    /// kept through a reconnect until another one answers.
    private(set) var inventoryCore: String?
    /// Until the server that answered has listed its terminals, nothing says
    /// what the Host runs.
    private(set) var isAwaitingSnapshot = true
    /// Listed terminals whose foreground this connection has yet to read. The
    /// first inventory lists every terminal before its details answer, so
    /// one of these may host the Agent a restored detail names.
    private(set) var panesAwaitingForeground: Set<String> = []
    private(set) var workspaces: [ConsoleWorkspace] = []
    private(set) var terminalsByPane: [String: ConsoleTerminal] = [:]
    private(set) var agentsByPane: [String: ConsoleAgent] = [:]
    /// The Agents as last listed, for a detail open on one while the Host
    /// recovers. Another instance's are not these.
    private(set) var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    private(set) var sidebarRevision: UInt64 = 0
    /// The last inventory folded into rows.
    private(set) var inventory: RexInventory?
    /// The Host's kernel as `uname -s` names it, kept in the Host memory as a
    /// tmux Host's is. A Host whose memory holds none takes the one its socket
    /// lookup printed, else the one `server.version` names: one read on the
    /// control link, and no exec.
    private(set) var kernel: String?

    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let terminalLabelKeys: [String] = []

    /// What this device keeps of the Host by server instance, and its Pins.
    private let memory: HerdrCoreHostMemory
    private let pins: PinnedAgentsStore
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var kernelTask: Task<Void, Never>?
    private var hasEnded = false
    /// The Panes this device shows now, whose finished turns are seen as
    /// they are noted.
    private var shownAgents: Set<String> = []
    /// What says a Chat check could answer differently now: every terminal
    /// with each new list after none and with a newly known kernel, one
    /// terminal with a change a check reads (`TerminalSessionSignature`) and
    /// with a pick made or dropped here.
    private var inventoryReplacements: UInt64 = 0
    private var sessionEventCounts: [String: UInt64] = [:]
    /// Picks a send guard dropped, which a check already under way may still
    /// hold, by terminal.
    private var droppedPicks: [String: Set<String>] = [:]

    /// How long Chat's reads of a block wait on the control link.
    private let chatReadDeadline: RexDeliveryDeadline
    /// Time as Composer Send's submit window counts it.
    private let sendClock: BlockedCardClock
    /// Chat's typing by Pane, kept so the screen it last read is the one its
    /// keys are checked against. Another instance's Panes are other Panes.
    private var chatTypings: [String: RexChatTyping] = [:]

    init(
        host: Host, session: RexHostSession, memory: HerdrCoreHostMemory = HerdrCoreHostMemory(),
        pins: PinnedAgentsStore, chatReadDeadline: RexDeliveryDeadline = RexConsoleProjection.chatReadDeadline,
        sendClock: BlockedCardClock = .live, onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.chatReadDeadline = chatReadDeadline
        self.sendClock = sendClock
        self.onChange = onChange
        kernel = memory.kernel(for: host.id)
    }

    /// A read the lab answered in milliseconds, with room for a redraw page
    /// queued ahead of it on the link.
    nonisolated static let chatReadDeadline = RexDeliveryDeadline(silence: .seconds(5), limit: .seconds(10))

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

    func handleNetworkPathChange() async {
        switch status {
        case .connected:
            await session.revalidate(timeout: RexHostSession.networkChangeProbeTimeout)
        case .reconnecting:
            beginNewActivation()
            await session.retry()
        default:
            break
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

    /// Leaves for good: the session closes its control link with a close
    /// frame, so the server forgets this client at once.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        consumeTask?.cancel()
        latencyTask?.cancel()
        kernelTask?.cancel()
        consumeTask = nil
        latencyTask = nil
        kernelTask = nil
        Task { [session] in await session.end() }
    }

    /// The catalog's Host changed. A socket noted where the record had none is
    /// what a connection looked up, here or on the Server page: it is taken as
    /// it is, and the connection stays, since the session keeps the socket it
    /// found and looks one up on each dial (ADR 0049). Anything else, another
    /// socket included, is another Host.
    func adoptSocket(of catalogHost: Host) {
        guard host.rexSocket == nil, catalogHost.rexSocket != nil else { return }
        var noted = host
        noted.rexSocket = catalogHost.rexSocket
        guard noted == catalogHost else { return }
        host = catalogHost
    }

    private func beginNewActivation() {
        status = .connecting
        latency = nil
        routeID = nil
        server = nil
        invalidateInventory()
        onChange()
    }

    private func handle(_ update: RexHostSessionUpdate) {
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
            // What was listed came from the server that answered before, and
            // its Pane ids may repeat under this one.
            if inventoryCore != server.instanceID {
                invalidateInventory()
                if inventoryCore != nil {
                    pins.removePins(hostID: host.id)
                    lastKnownAgentsByPane = [:]
                    shownAgents = []
                    sessionEventCounts = [:]
                    droppedPicks = [:]
                    chatTypings = [:]
                }
            }
            self.server = server
            inventoryCore = server.instanceID
            // Turns, seen marks and picks this device kept of another
            // instance, in this run or an earlier one, go with it.
            memory.noteCore(server.instanceID, for: host.id)
            learnKernel()
        case .inventory(let inventory):
            guard status == .connected, server != nil else { return }
            noteSessionEvidence(in: inventory, previous: self.inventory)
            self.inventory = inventory
            noteTurns(in: inventory)
            notePicks(in: inventory)
            rebuildRows()
        }
        onChange()
    }

    /// The kernel for a Host whose memory holds none, once a server answers:
    /// the one the socket lookup printed, else `server.version`'s platform.
    /// A server that cannot say leaves it unknown until the next connection,
    /// and nothing waits for it.
    private func learnKernel() {
        guard kernel == nil, kernelTask == nil else { return }
        let session = session
        kernelTask = Task { [weak self] in
            let found = try? await session.withConnection { connection -> String? in
                if let found = connection.transport.foundKernel { return found }
                let answer = try await connection.control.call("server.version")
                return RexServerPlatform.kernel(reading: try answer.result(JSONValue.self))
            }
            guard let self else { return }
            kernelTask = nil
            guard !hasEnded, kernel == nil, let found else { return }
            kernel = found
            memory.noteKernel(found, for: host.id)
            // A check made before could read a Mac's processes as another system's.
            inventoryReplacements &+= 1
            onChange()
        }
    }

    // MARK: Inventory

    /// A Pane belongs to its server: a detail open on another instance's
    /// terminal has left the inventory.
    var keepsDetailsToInventory: Bool { true }

    var leftInventoryMessage: String { TerminalStatusPresentation.rexServerGoneMessage }

    var leftInventoryError: TransportError { .rexServerGone }

    private func invalidateInventory() {
        isAwaitingSnapshot = true
        panesAwaitingForeground = []
        inventory = nil
        workspaces = []
        terminalsByPane = [:]
        agentsByPane = [:]
    }

    /// Each inventory is the server's whole list, so Pins on Panes it no
    /// longer lists go.
    private func rebuildRows() {
        guard let inventory else { return }
        let builder = ConsolePaneRowBuilder(
            host: host, inventory: RexOrganization.build(inventory, doneTerminals: doneTerminals))
        let agents = builder.agentRows(liveChange: { _ in nil })
        terminalsByPane = builder.terminalRows(agents: agents, liveChange: { _ in nil })
        agentsByPane = agents
        lastKnownAgentsByPane = agents
        panesAwaitingForeground = Set(
            inventory.sessions.flatMap { session in
                session.terminals.lazy.filter(\.details.awaitsForeground)
                    .map { RexPaneAddress(sessionID: session.id, blockID: $0.blockID).paneID }
            })
        pins.retainPins(hostID: host.id, paneIDs: Set(terminalsByPane.keys))
        chatTypings = chatTypings.filter { terminalsByPane[$0.key] != nil }
        workspaces = builder.workspaceRows()
        isAwaitingSnapshot = false
        sidebarRevision &+= 1
    }

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}

    // MARK: Done per device

    /// Each listed terminal's record, folded into this device's turns, and
    /// the turns of terminals the server no longer lists forgotten. A record
    /// this link has yet to read, or one removed, changes nothing; one that is
    /// not its Agent's, or a foreground read as no Agent, ends a finished
    /// turn's Done. A terminal whose foreground this link has yet to read, as
    /// on a new connection before its details answer, says neither, so a turn
    /// left unseen before a relaunch still reads Done after it. A terminal
    /// never known to host an Agent costs nothing.
    private func noteTurns(in inventory: RexInventory) {
        let known = memory.rexTurnStates(for: host.id)
        var listed: Set<String> = []
        for session in inventory.sessions {
            for terminal in session.terminals {
                let paneID = RexPaneAddress(sessionID: session.id, blockID: terminal.blockID).paneID
                listed.insert(paneID)
                let details = terminal.details
                let kind = RexAgentRule.agentKind(in: details)
                if let kind, let report = RexAgentRule.report(of: details, heldBy: kind) {
                    let isShown = shownAgents.contains(paneID)
                    memory.updateRexTurnState(of: paneID, for: host.id) { state in
                        state.note(report, kind: kind)
                        if isShown { state.markSeen() }
                    }
                } else if known[paneID] != nil, kind == nil ? details.program != nil : details.status != nil {
                    memory.updateRexTurnState(of: paneID, for: host.id) { $0.noteNoAgent() }
                }
            }
        }
        memory.retainRexPanes(listed, for: host.id)
    }

    private var doneTerminals: Set<String> {
        Set(memory.rexTurnStates(for: host.id).filter(\.value.isDone).keys)
    }

    /// Marks each newly shown Agent's finished turn seen. A turn that ends
    /// while one stays shown is seen as it is noted, so it never reads Done.
    func setShownAgents(_ paneIDs: Set<String>) {
        let opened = paneIDs.subtracting(shownAgents)
        shownAgents = paneIDs
        let known = memory.rexTurnStates(for: host.id)
        let opening = opened.filter { known[$0] != nil }
        guard !opening.isEmpty else { return }
        let wasDone = doneTerminals
        for paneID in opening {
            memory.updateRexTurnState(of: paneID, for: host.id) { $0.markSeen() }
        }
        guard doneTerminals != wasDone, inventory != nil else { return }
        rebuildRows()
        onChange()
    }

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Process-bound Chat (ADRs 0034 and 0054)

    let usesProcessBoundChat = true

    /// Another instance's terminals are other Agents, whose Transcripts are
    /// cached apart.
    var chatCacheScope: String? {
        memory.coreID(for: host.id).map(ChatCacheKey.rexScope(instanceID:))
    }

    func sessionEventRevision(of paneID: String) -> UInt64 {
        inventoryReplacements &+ (sessionEventCounts[paneID] ?? 0)
    }

    /// A Pi or Oh My Pi's reason is the one that offers Heeler's extension,
    /// as its binder's is (ADR 0056).
    func chatCannotTell(_ program: ChatProgram) -> ChatUnavailableReason {
        program.namesItsSessionThroughHeelersExtension
            ? .cannotTellSessionOnRex(program, extensionInPlace: false)
            : HerdrCoreHostSystem(kernel: kernel).cannotTellSession(program)
    }

    /// One exec from the foreground Rex names, then the program's own files.
    /// A program a Rex Host does not bind, or a terminal no longer listed,
    /// cannot tell.
    func checkChatSession(paneID: String, program: ChatProgram) async throws -> ChatSessionEvidence {
        guard !isAwaitingSnapshot, inventory != nil else { throw TransportError.cancelled }
        guard HostCapabilities.rexChatPrograms.contains(program), let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return .unavailable(chatCannotTell(program)) }
        let details = await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        return try await chatBinder(at: address, details: details, program: program, server: activeServer)
            .check(chatRecord(at: address, details: details))
    }

    func claudePermissionLaunch(paneID: String) async throws -> ClaudePermissionMode.Launch? {
        guard !isAwaitingSnapshot, let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return nil }
        let details = await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        let binder = chatBinder(at: address, details: details, program: .claude, server: activeServer)
        let ask = HerdrCoreSessionBinder.ProcessAsk(
            namesOf: [ChatTranscriptOffVariable.childSession.rawValue],
            arguments: ClaudePermissionMode.argumentWords, preservesArgumentOrder: true)
        guard
            let tree = try await binder.readTerminalProcesses(of: chatRecord(at: address, details: details), ask: ask),
            let pid = binder.agentProcess(in: tree), let facts = tree.facts[pid],
            inventoryCore == activeServer.instanceID
        else { return nil }
        return ClaudePermissionMode.Launch(pid: pid, facts: facts)
    }

    func chatCandidates(paneID: String, program: ChatProgram) async throws -> ChatCandidatesAnswer {
        guard !isAwaitingSnapshot, inventory != nil else { throw TransportError.cancelled }
        guard HostCapabilities.rexChatPrograms.contains(program), let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return .noProcess }
        let details = await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        let answer = try await chatBinder(at: address, details: details, program: program, server: activeServer)
            .candidates(of: chatRecord(at: address, details: details))
        guard case .listed(var list) = answer else { return answer }
        list.core = activeServer.instanceID
        return .listed(list)
    }

    /// Kept on this device for the terminal and its server instance, with
    /// the foreground and Agent kind it was made on: nothing is written on
    /// the Host or the server.
    func writeChatPick(
        _ candidate: ChatSessionCandidate, of list: ChatSessionCandidates, paneID: String
    ) async throws {
        guard
            let value = HerdrCoreSessionHint.pickLabelValue(
                session: candidate.sessionID, file: candidate.file, pid: list.pid, start: list.start)
        else { throw TransportError.cancelled }
        guard let activeServer = server, inventoryCore == activeServer.instanceID,
            list.core == nil || list.core == activeServer.instanceID
        else { throw TransportError.rexServerGone }
        guard let address = RexPaneAddress(paneID: paneID), let details = listedDetails(at: address),
            let kind = RexAgentRule.agentKind(in: details)
        else { throw TransportError.cancelled }
        droppedPicks[paneID]?.remove(value)
        memory.setRexChatPick(
            HerdrCoreHostMemory.RexChatPick(label: value, foregroundPID: details.processID, kind: kind),
            of: paneID, for: host.id)
        sessionEventCounts[paneID, default: 0] &+= 1
        onChange()
    }

    /// A pick still kept is checked once more, which forgets it if it no
    /// longer holds.
    func settleChatPick(paneID: String, program: ChatProgram) {
        guard memory.rexChatPicks(for: host.id)[paneID] != nil else { return }
        Task { [weak self] in
            _ = try? await self?.checkChatSession(paneID: paneID, program: program)
        }
    }

    /// A send guard's word that the pick no longer holds: it goes from this
    /// device at once, and a check already under way finds it dropped.
    func dropChatPick(paneID: String, scope: String?, program _: ChatProgram) {
        guard chatCacheScope == scope, let pick = memory.rexChatPicks(for: host.id)[paneID] else { return }
        droppedPicks[paneID, default: []].insert(pick.label)
        memory.setRexChatPick(nil, of: paneID, for: host.id)
        sessionEventCounts[paneID, default: 0] &+= 1
        // The guard is still on its way out; the Console hears of it after.
        Task { [weak self] in self?.onChange() }
    }

    /// A terminal's details with the foreground Rex names now, read on the
    /// control link as typing reads it (ADR 0055). Rex announces a foreground
    /// once, as it starts, and a program that takes its name after that, as
    /// Pi does under Node, is never announced again: the listed name would
    /// match nothing a process read finds, for as long as the terminal stays
    /// listed (rex-compatibility.md). A read that fails, or one another
    /// server answers, leaves the listed foreground.
    private func detailsWithCurrentForeground(
        at address: RexPaneAddress, listed: RexTerminalDetails, server activeServer: RexServerStatus
    ) async -> RexTerminalDetails {
        guard let requests = try? await session.blockRequests(at: address, readDeadline: chatReadDeadline),
            requests.server.instanceID == activeServer.instanceID,
            let answer = try? await requests.read(.process)
        else { return listed }
        var details = listed
        details.noteForeground(RexInventoryWire.process(answer))
        return details
    }

    private func chatBinder(
        at address: RexPaneAddress, details: RexTerminalDetails, program: ChatProgram,
        server activeServer: RexServerStatus
    ) -> HerdrCoreSessionBinder {
        let session = session
        let paneID = address.paneID
        let instance = activeServer.instanceID
        return HerdrCoreSessionBinder(
            program: program,
            processes: { request in try await Self.reads(session).readProcesses(request) },
            files: chatHostFiles(),
            clearLabels: { stale in await self.clearStalePick(stale, at: paneID, on: instance) },
            currentLabels: { await self.pickLabels(at: paneID, on: instance) },
            isDroppedPick: { value in await self.droppedPicks[paneID]?.contains(value) == true },
            hostSystem: HerdrCoreHostSystem(kernel: kernel),
            processScope: .rex(
                sessionID: address.sessionID, blockID: address.blockID,
                foregroundNames: Self.foregroundNames(details)))
    }

    /// What Rex named of a terminal's foreground: its name, and its first
    /// argument's last path part.
    private static func foregroundNames(_ details: RexTerminalDetails) -> Set<String> {
        let firstArgument = details.argv0.flatMap { $0.split(separator: "/").last.map(String.init) }
        return Set([details.program, firstArgument].compactMap { $0 }.filter { !$0.isEmpty })
    }

    private func chatRecord(at address: RexPaneAddress, details: RexTerminalDetails) -> HerdrCoreTerminalRecord {
        HerdrCoreTerminalRecord(
            rexTerminal: details, paneID: address.paneID,
            chatPick: memory.rexChatPicks(for: host.id)[address.paneID]?.label)
    }

    private func listedDetails(at address: RexPaneAddress) -> RexTerminalDetails? {
        inventory?.sessions.first { $0.id == address.sessionID }?.terminals
            .first { $0.blockID == address.blockID }?.details
    }

    /// The terminal's pick as it stands now; nil once its server or the
    /// terminal is gone, which says nothing newer.
    private func pickLabels(at paneID: String, on instance: String) -> [String: String]? {
        guard inventoryCore == instance, let address = RexPaneAddress(paneID: paneID),
            listedDetails(at: address) != nil
        else { return nil }
        return memory.rexChatPicks(for: host.id)[paneID].map { [HerdrCoreSessionHint.pickLabel: $0.label] } ?? [:]
    }

    /// A pick the binder found stale goes, if it is still the one kept. The
    /// check that found it already answers without it.
    private func clearStalePick(_ stale: [String: String], at paneID: String, on instance: String) {
        guard inventoryCore == instance, let value = stale[HerdrCoreSessionHint.pickLabel],
            memory.rexChatPicks(for: host.id)[paneID]?.label == value
        else { return }
        memory.setRexChatPick(nil, of: paneID, for: host.id)
    }

    /// What a check reads of a terminal from the inventory: its foreground
    /// and the Program Status its programs reported. A title, and when Rex
    /// took a report, say nothing a check reads.
    private struct TerminalSessionSignature: Equatable {
        let processID: Int?
        let program: String?
        let argv0: String?
        let script: String?
        let directory: String?
        let state: String?
        let app: String?
        let ownerProcessID: Int?
        let ownerName: String?

        init(_ details: RexTerminalDetails) {
            processID = details.processID
            program = details.program
            argv0 = details.argv0
            script = details.script
            directory = details.directory
            state = details.status?.state
            app = details.status?.app
            ownerProcessID = details.status?.ownerProcessID
            ownerName = details.status?.ownerName
        }
    }

    private static func signatures(in inventory: RexInventory) -> [String: TerminalSessionSignature] {
        var signatures: [String: TerminalSessionSignature] = [:]
        for session in inventory.sessions {
            for terminal in session.terminals {
                signatures[RexPaneAddress(sessionID: session.id, blockID: terminal.blockID).paneID] =
                    TerminalSessionSignature(terminal.details)
            }
        }
        return signatures
    }

    /// Rex says nothing of a process that took another's pid under the same
    /// name, of one that ran another program in place, or of a new file, so
    /// those wait for the next change it does say (rex-compatibility.md).
    private func noteSessionEvidence(in inventory: RexInventory, previous: RexInventory?) {
        let current = Self.signatures(in: inventory)
        let picks = memory.rexChatPicks(for: host.id)
        droppedPicks = droppedPicks.filter { current[$0.key] != nil }
        for (paneID, dropped) in droppedPicks {
            let kept = dropped.filter { $0 == picks[paneID]?.label }
            droppedPicks[paneID] = kept.isEmpty ? nil : kept
        }
        guard let previous else {
            inventoryReplacements &+= 1
            return
        }
        let prior = Self.signatures(in: previous)
        sessionEventCounts = sessionEventCounts.filter { current[$0.key] != nil }
        for (paneID, signature) in current where prior[paneID] != signature {
            sessionEventCounts[paneID, default: 0] &+= 1
        }
    }

    /// A pick holds while its terminal runs what it was made on: one with
    /// another foreground process, or another program, voids it, as a
    /// relaunch ends a turn's Done. A terminal whose foreground this link
    /// has yet to read says neither.
    private func notePicks(in inventory: RexInventory) {
        let picks = memory.rexChatPicks(for: host.id)
        guard !picks.isEmpty else { return }
        for session in inventory.sessions {
            for terminal in session.terminals {
                let paneID = RexPaneAddress(sessionID: session.id, blockID: terminal.blockID).paneID
                guard let pick = picks[paneID] else { continue }
                let details = terminal.details
                let anotherProcess = details.processID.map { $0 != pick.foregroundPID } ?? false
                let anotherProgram = details.program != nil && RexAgentRule.agentKind(in: details) != pick.kind
                if anotherProcess || anotherProgram {
                    memory.setRexChatPick(nil, of: paneID, for: host.id)
                }
            }
        }
    }

    // MARK: Actions

    /// Nothing is started, closed or renamed on a Rex Host (ADR 0049).
    private nonisolated static var unavailable: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "This action on a Rex Host"))
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] { throw Self.unavailable }
    func startAgent(_: AgentLaunchRequest) async throws -> Agent { throw Self.unavailable }
    func startAgentInNewWorktree(_: AgentLaunchRequest, worktree _: WorktreeSpec) async throws -> Agent {
        throw Self.unavailable
    }
    func startAgentInNewWorkspace(_: AgentLaunchRequest, workspace _: NewWorkspaceSpec) async throws -> Agent {
        throw Self.unavailable
    }
    func createShellTerminal(_: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        throw Self.unavailable
    }
    func createShellWorkspace(_: NewWorkspaceSpec, tabLabel _: String?) async throws -> ShellTerminalIdentity {
        throw Self.unavailable
    }
    func closePane(_: String) async throws { throw Self.unavailable }
    func closeTab(_: String) async throws { throw Self.unavailable }
    func listWorktrees(forWorkspaceID _: String) async throws -> WorktreeListResponse { throw Self.unavailable }
    func removeWorktree(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt { throw Self.unavailable }
    func worktreeRemovalRisk(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        throw Self.unavailable
    }
    /// Done is per device, as `setAgentShown` reads it: nothing to tell the
    /// server.
    func focusAgent(_: String) async throws {}
    func renameAgent(_: String, name _: String?) async throws { throw Self.unavailable }
    func renameWorkspace(_: String, label _: String) async throws { throw Self.unavailable }

    // MARK: One Agent

    func agentInfo(paneID _: String) async throws -> Agent { throw Self.unavailable }
    func processInfo(paneID _: String) async throws -> PaneProcessInfo { throw Self.unavailable }
    func promptAgent(_: AgentPromptParams) async throws -> Agent { throw Self.unavailable }

    // MARK: Chat's typing (ADR 0055)

    /// The screen on the control link, decoded only where its shape is known.
    func readAgentScreen(_ paneID: String) async throws -> ANSIScreen {
        try await chatTyping(at: paneID).readScreen()
    }

    /// Keys checked against the Agent holding the terminal, on the control link.
    func sendAgentKeys(_ keys: [String], to paneID: String) async throws {
        try await chatTyping(at: paneID).press(keys)
    }

    func pasteIntoAgent(_ text: String, paneID: String) async throws {
        try await chatTyping(at: paneID).paste(text)
    }

    /// Checked Composer Send on the control link, from the terminal or from
    /// Chat. Stop has no checked way of its own: Chat's Stop presses its plan's
    /// keys through `sendAgentKeys`, as on a herdr-core Host, and the terminal
    /// Composer's Stop presses Esc the same way. `live` follows a projection
    /// replaced after the Composer was opened.
    func checkedComposerSend(
        for paneID: String,
        keepingTo corePin: TerminalCorePin,
        live: @escaping @MainActor () -> (any ConsoleHostProjection)?
    ) -> (any CheckedComposerSend)? {
        guard let address = RexPaneAddress(paneID: paneID) else { return nil }
        return RexComposerSend(
            address: address, projection: { live() as? RexConsoleProjection }, corePin: corePin, clock: sendClock)
    }

    /// The terminal Composer's Stop: one Esc, checked as Chat's keys are, so it
    /// reaches only the Agent that leads the foreground, in the block's lane on
    /// the control link. An unlisted block is a shell the Agent left, which
    /// must not take the Agent's stop key; Grok Build keeps Send, as anywhere.
    /// `live` follows a projection replaced after the Composer was opened.
    func checkedTerminalStop(
        for paneID: String,
        keepingTo corePin: TerminalCorePin,
        live: @escaping @MainActor () -> (any ConsoleHostProjection)?
    ) -> TerminalStopOffer? {
        guard let listed = agentsByPane[paneID] else { return .keepSend }
        let stop = AgentComposerInterrupt.terminal(forAgentKind: listed.agent.kind) {
            guard let projection = live() as? RexConsoleProjection, projection.admits(corePin) else {
                return .failed(TransportError.rexServerGone.presentation.message)
            }
            do {
                try await projection.chatTyping(at: paneID).press(["esc"])
                return .sent
            } catch let refusal as RexChatTyping.Refusal {
                return .failed(refusal.message)
            } catch {
                return .failed(ChatStopPlan.unreachableMessage)
            }
        }
        return stop.map(TerminalStopOffer.interrupt) ?? .keepSend
    }

    /// Chat's checked typing for this Pane; nil for an id that names no block.
    func checkedChatTyping(at paneID: String) -> (any CheckedChatTyping)? {
        try? chatTyping(at: paneID)
    }

    func chatTyping(at paneID: String) throws -> RexChatTyping {
        if let typing = chatTypings[paneID] { return typing }
        guard let address = RexPaneAddress(paneID: paneID) else { throw Self.unavailable }
        let typing = RexChatTyping(address: address, projection: self)
        chatTypings[paneID] = typing
        return typing
    }

    /// Whether what keeps to `pin` still means this inventory's terminals.
    func admits(_ pin: TerminalCorePin) -> Bool {
        inventoryCore.map(pin.admits) ?? true
    }

    /// Chat's requests to the block at `address`, on the server `pin` keeps
    /// to: no other server's block gets them, nor one on a later connection.
    /// Throws `TransportError.rexServerGone` for another server, and what the
    /// session throws while no connection is up.
    func blockRequests(at address: RexPaneAddress, keepingTo pin: TerminalCorePin) async throws -> RexBlockRequests {
        guard admits(pin) else { throw TransportError.rexServerGone }
        let requests = try await session.blockRequests(at: address, readDeadline: chatReadDeadline)
        guard pin.admits(requests.server.instanceID) else { throw TransportError.rexServerGone }
        return requests
    }

    /// The Agent Status of `holder`'s Agent: the record the inventory holds,
    /// read against the foreground just read rather than the listed one.
    func agentStatus(at address: RexPaneAddress, heldBy holder: RexAgentHolder) -> AgentStatus {
        var details = listedDetails(at: address) ?? RexTerminalDetails()
        details.noteForeground(holder.process)
        return RexAgentRule.status(of: details, heldBy: holder.kind)
    }

    // MARK: The live connection

    /// Opens a Rex terminal (ADRs 0051 to 0053): its session is attached,
    /// the block's size is taken for a view that shows it, its block's
    /// stream paints the view and follows its output, the view's grid is
    /// asked for, and the view's input goes out from the first paint. A block
    /// that closed, a program that exited and another server end the
    /// terminal; a connection that went or was replaced reattaches, and the
    /// next attach paints afresh. Input that may have reached the program
    /// unanswered ends it as a failed input write.
    func terminalRunner() -> TerminalSessionRunner {
        let session = session
        return { request, handler in
            guard let address = RexPaneAddress(paneID: request.target.identifier) else {
                throw TerminalProgramEnd.finished
            }
            do {
                try await session.withTerminal(address) { connection in
                    guard await handler.admitsCore(connection.server.instanceID) else {
                        throw TerminalProgramEnd.finished
                    }
                    await handler.transportDidBecomeReady(connection.generation)
                    try await connection.attachSession()
                    let fitting = await handler.takesSizeOnOpen()
                    let terminal = await RexTerminalAttach.session(
                        on: connection, columns: request.cols, rows: request.rows, fitting: fitting)
                    try await handler.runEndingSession(terminal)
                }
            } catch let ending as RexTerminalEnding {
                switch ending {
                case .finished, .serverGone: throw TerminalProgramEnd.finished
                case .connectionReset: throw TransportError.cancelled
                case .outputUnavailable: throw TransportError.rexTerminalOutputUnavailable
                case .historyTooLong: throw TransportError.rexTerminalHistoryTooLong
                case .inputFailed:
                    // As the other Server Kinds say an input write failed.
                    throw TransportError.channelFailed(detail: String(localized: "attach input failed"))
                }
            }
        }
    }
    // MARK: Staging what the user attaches (ADR 0056)

    /// Stages the image over the Host's SSH connection (`RexHostStaging`), as
    /// a tmux Host stages one, for the Agent on the server `corePin` keeps
    /// to. The path goes into the draft; Send types it with the message.
    func imageStager(beside _: String, keepingTo corePin: TerminalCorePin) -> ImageStager {
        { image, reporter in
            let staging = try await self.staging(keepingTo: corePin)
            return try await staging.stageImage(image) { await reporter.report($0) }
        }
    }

    func fileStager(beside _: String, keepingTo corePin: TerminalCorePin) -> FileStager {
        { file, reporter in
            let staging = try await self.staging(keepingTo: corePin)
            return try await staging.stageFile(file) { await reporter.report($0) }
        }
    }

    /// Says `rexServerGone` in its own words: an upload begun for an Agent of
    /// a server that is gone stages nothing.
    var stagingSaysTransportFailures: Bool { true }

    /// The live connection's staging, while its server is the instance `pin`
    /// keeps to; another instance throws `TransportError.rexServerGone`
    /// before anything is staged, as Chat's block requests do. What the
    /// session throws while no server answers passes through.
    private func staging(keepingTo pin: TerminalCorePin) async throws -> any RexHostStaging {
        guard admits(pin) else { throw TransportError.rexServerGone }
        let (staging, instanceID) = try await session.withConnection { ($0.transport.staging, $0.server.instanceID) }
        guard admits(pin), pin.admits(instanceID) else { throw TransportError.rexServerGone }
        return staging
    }

    // MARK: Heeler's extension, when Chat offers it (ADR 0056)

    /// The folder the Pi or Oh My Pi in this terminal loads its extensions
    /// from, by that process's own environment: one bounded process read,
    /// and nothing written.
    func chatExtensionFolder(paneID: String) async throws -> String {
        guard !isAwaitingSnapshot, inventory != nil else { throw TransportError.cancelled }
        guard let address = RexPaneAddress(paneID: paneID), let listed = listedDetails(at: address),
            let activeServer = server
        else { throw Self.extensionFolderUnknown }
        let details = await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        guard let program = RexAgentRule.agentKind(in: details).flatMap(ChatProgram.init(rawValue:)),
            program.namesItsSessionThroughHeelersExtension,
            let folder = try await chatBinder(at: address, details: details, program: program, server: activeServer)
                .piFamilyExtensionFolder(of: chatRecord(at: address, details: details))
        else { throw Self.extensionFolderUnknown }
        return folder
    }

    /// Writes Heeler's extension into `folder` over the Host's SSH connection
    /// (`RexHostExtensionPlacing`), for the Agent on the server `corePin`
    /// keeps to, then has its Chat look again. Another instance throws
    /// `TransportError.rexServerGone` before anything is written.
    func placeChatExtension(_ contents: Data, inFolder folder: String, keepingTo pin: TerminalCorePin?) async throws {
        if let pin { guard admits(pin) else { throw TransportError.rexServerGone } }
        let (placing, instanceID) = try await session.withConnection {
            ($0.transport.extensionPlacing, $0.server.instanceID)
        }
        if let pin { guard admits(pin), pin.admits(instanceID) else { throw TransportError.rexServerGone } }
        try await placing.placeHeelersExtension(contents, inFolder: folder)
        inventoryReplacements &+= 1
        onChange()
    }

    private nonisolated static var extensionFolderUnknown: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "Heeler's extension for this Agent"))
    }

    // MARK: The Host's files, on the same SSH connection

    /// Chat's reads of the Host, on the connection the server's links use:
    /// `RexHostReads`, which writes nothing.
    private nonisolated static func reads(_ session: RexHostSession) async throws -> any RexHostReads {
        try await session.withConnection { $0.transport.reads }
    }

    func sessionFileReader() -> SessionFileReader {
        let session = session
        return { range in try await Self.reads(session).readFileSlice(range) }
    }

    func modelContextWindowResolver() -> ModelContextWindowResolver { { _ in nil } }

    /// Chat's file reads. With no Host Helper there is no Usage account file,
    /// so the Default Account's directories are the only ones.
    func chatHostFiles() -> ChatHostFiles {
        let session = session
        return ChatHostFiles(
            status: { path in try await Self.reads(session).fileStatus(atPath: path) },
            list: { request in try await Self.reads(session).listFiles(request) },
            read: { range in try await Self.reads(session).readHostFileRange(range) },
            home: { try await Self.reads(session).hostHomeDirectory() })
    }

    /// New Agent and New Terminal browse with these, and a Rex Host offers
    /// neither.
    func remoteHomeDirectory() async throws -> String { throw Self.unavailable }
    func listRemoteDirectories(at _: String) async throws -> RemoteDirectoryListing { throw Self.unavailable }

    /// Chat reads the Host's files and processes through `RexHostReads`, an
    /// attachment is staged through `RexHostStaging`, and Heeler's extension
    /// goes where the user asks through `RexHostExtensionPlacing`; nothing
    /// else runs on it over SSH: Changes, Skills, harness edits, the agy
    /// model list and the platform probe stay out, and the Host is POSIX
    /// without asking it (ADR 0056).
    func withHostServices<Value: Sendable>(
        _: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        throw Self.unavailable
    }

    /// A Rex Host has no plugin, Notifications or Usage files, and its plugin
    /// surfaces say it is the Server Kind's doing.
    func withNotificationTransport<Value: Sendable>(
        _: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.rex
    }
}
