import Foundation

/// A Rex Host's share of the Console (ADRs 0049 and 0050): its connection, the
/// server that answers on its socket, and the terminals that server lists. A
/// session is a Workspace, a window a Tab and a terminal block a Pane, as
/// `RexOrganization` reads them, and a terminal running a known agent program
/// is an Agent with the status it reported to Rex (ADR 0054).
///
/// A Pane keeps to its server, as a tmux Pane does: another server leaves
/// every detail open on the last one's terminals, and its Pins go. A server
/// that restarted and restored its sessions is the same server under another
/// instance, and keeps them (ADR 0050). A terminal opens from the server's
/// redraw (ADR 0051) and takes input from its first paint (ADR 0052).
/// Project reads, worktrees, attachments and harness integrations use scoped
/// services on the existing SSH connection. Agent launches and input use the
/// Rex control link. Chat reads the block's screen and sends checked input
/// through RexChatTyping and RexComposerSend (ADR
/// 0055), the staged paths with the message.
///
/// Done is per device, as on a tmux Host: each terminal's turns and this
/// device's seen marks (`RexTurnState`) are kept by server on this device
/// only, and an Agent's detail on either surface is looking at it.
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
    /// The core of the server whose terminals a detail keeps to: the last
    /// that answered, kept through a reconnect until another server answers.
    private(set) var inventoryCore: String?
    /// The instance of it that answered last. Another instance of the same
    /// server runs every program anew.
    private var inventoryInstance: String?
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
    /// recovers. Another server's are not these.
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

    /// What this device keeps of the Host by server, and its Pins.
    private let memory: HerdrCoreHostMemory
    private let gitGate: GitExecGate
    private var openCodeVersion: String?
    private(set) var apiRevision: Int?
    private(set) var acceptsAgentCommand = false
    private var commandSchemaTask: Task<Void, Never>?
    private let pins: PinnedAgentsStore
    private let onLatencyChange: (@MainActor @Sendable () -> Void)?
    private let onChange: @MainActor @Sendable () -> Void
    private var consumeTask: Task<Void, Never>?
    private var latencyTask: Task<Void, Never>?
    private var kernelTask: Task<Void, Never>?
    private var hasEnded = false
    private var inventoryRefreshes: [UUID: CheckedContinuation<Void, Never>] = [:]
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
    /// keys are checked against. Another server's Panes are other Panes.
    private var chatTypings: [String: RexChatTyping] = [:]

    init(
        host: Host, session: RexHostSession, memory: HerdrCoreHostMemory = HerdrCoreHostMemory(),
        pins: PinnedAgentsStore, gitGate: GitExecGate = GitExecGate(), chatReadDeadline: RexDeliveryDeadline = RexConsoleProjection.chatReadDeadline,
        sendClock: BlockedCardClock = .live,
        onLatencyChange: (@MainActor @Sendable () -> Void)? = nil,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.session = session
        self.memory = memory
        self.pins = pins
        self.gitGate = gitGate
        self.chatReadDeadline = chatReadDeadline
        self.sendClock = sendClock
        self.onLatencyChange = onLatencyChange
        self.onChange = onChange
        kernel = memory.kernel(for: host.id)
        session.seedLineage(memory.rexServerLineage(for: host.id))
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
                guard !Task.isCancelled, let self, !self.hasEnded else { return }
                self.latency = session.currentLatency
                if let onLatencyChange = self.onLatencyChange {
                    onLatencyChange()
                } else {
                    self.onChange()
                }
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
        for refresh in inventoryRefreshes.values { refresh.resume() }
        inventoryRefreshes.removeAll()
        consumeTask?.cancel()
        latencyTask?.cancel()
        kernelTask?.cancel()
        commandSchemaTask?.cancel()
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
        case .inventoryRefreshFinished(let id):
            inventoryRefreshes.removeValue(forKey: id)?.resume()
            return
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
                commandSchemaTask?.cancel()
                apiRevision = nil
                acceptsAgentCommand = false
                openCodeVersion = nil
                server = nil
                invalidateInventory()
            }
        case .server(let server):
            // What was listed came from the server that answered before, and
            // its Pane ids may repeat under this one.
            if inventoryCore != server.coreID {
                invalidateInventory()
                if inventoryCore != nil {
                    pins.removePins(hostID: host.id)
                    lastKnownAgentsByPane = [:]
                    shownAgents = []
                    sessionEventCounts = [:]
                    droppedPicks = [:]
                    chatTypings = [:]
                }
            } else if inventoryInstance != server.instanceID {
                // The same server restarted: its terminals and Pins stay, but
                // each program in them runs anew, so no pick a send guard
                // dropped is the new one's. Chat's typing stays, as a Chat
                // holds its screen reads: it reads the program started again
                // as another holder, and types nothing over an earlier screen.
                droppedPicks = [:]
            }
            if let previous = memory.coreID(for: host.id), previous != server.coreID {
                kernelTask?.cancel()
                kernelTask = nil
                kernel = nil
                memory.noteKernel(nil, for: host.id)
            }
            self.server = server
            checkCommandSchema(on: server)
            inventoryCore = server.coreID
            inventoryInstance = server.instanceID
            // Turns, seen marks and picks this device kept of another
            // server, in this run or an earlier one, go with it.
            memory.noteCore(server.coreID, for: host.id)
            learnKernel()
        case .inventory(let inventory):
            guard status == .connected, let server else { return }
            memory.noteRexServerLineage(
                RexServerLineage(server, sessionIDs: inventory.sessions.map(\.id)), for: host.id)
            noteSessionEvidence(in: inventory, previous: self.inventory)
            self.inventory = inventory
            noteTurns(in: inventory)
            notePicks(in: inventory)
            rebuildRows()
        }
        onChange()
    }

    /// Older releases can negotiate the same revision while accepting fewer block options.
    /// Ask the connected server for its shell flavor before offering an Agent launch.
    private func checkCommandSchema(on expected: RexServerStatus) {
        commandSchemaTask?.cancel()
        acceptsAgentCommand = false
        openCodeVersion = nil
        commandSchemaTask = Task { [weak self, session] in
            let capabilities = try? await session.withConnection { connection in
                guard connection.server == expected else { throw TransportError.rexServerGone }
                let revision = connection.control.apiRevision
                guard connection.transport.projects != nil,
                    let reply = try? await connection.control.call("block_creator.list").result(JSONValue.self)
                else { return (revision, false) }
                return (revision, RexNewTerminal.acceptsAgentCommand(reply))
            }
            guard let self, !hasEnded, !Task.isCancelled, server == expected else { return }
            apiRevision = capabilities?.0
            acceptsAgentCommand = capabilities?.1 == true
            onChange()
        }
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
            guard let self, !Task.isCancelled else { return }
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

    /// A Pane belongs to its server: a detail open on another server's
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

    func refreshTerminalInventory() async {
        guard !hasEnded, status == .connected, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inventoryRefreshes[id] = continuation
                Task { await session.refreshInventory(id) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.inventoryRefreshes.removeValue(forKey: id)?.resume() }
        }
    }
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

    func programExit(ofPane paneID: String) -> ProgramExit? {
        guard let address = RexPaneAddress(paneID: paneID) else { return nil }
        return listedDetails(at: address)?.lastExit
    }

    func paneExists(_ paneID: String) async throws -> Bool {
        terminalsByPane[paneID] != nil
    }

    // MARK: Process-bound Chat (ADRs 0034 and 0054)

    let usesProcessBoundChat = true

    /// Another server's terminals are other Agents, whose Transcripts are
    /// cached apart.
    var chatCacheScope: String? {
        memory.coreID(for: host.id).map(ChatCacheKey.rexScope(coreID:))
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

    /// The published status must still belong to the Antigravity process
    /// named by this server's inventory. A bare shell never has a binding.
    func antigravityForeground(in paneID: String) -> Int? {
        guard (kernel == HerdrCoreLocator.linuxKernel || kernel == HerdrCoreLocator.macOSKernel),
              status == .connected, !isAwaitingSnapshot,
              let address = RexPaneAddress(paneID: paneID), let details = listedDetails(at: address),
              RexAgentRule.agentKind(in: details) == ChatProgram.agy.rawValue else { return nil }
        switch RexAgentRule.status(of: details, heldBy: ChatProgram.agy.rawValue) {
        case .idle, .done, .working: return details.processID
        default: return nil
        }
    }

    /// One exec from the foreground Rex names, then the program's own files.
    /// A program a Rex Host does not bind, or a terminal no longer listed,
    /// cannot tell.
    func checkChatSession(paneID: String, program: ChatProgram) async throws -> ChatSessionEvidence {
        guard !isAwaitingSnapshot, inventory != nil else { throw TransportError.cancelled }
        guard HostCapabilities(serverKind: .rex, coreKernel: kernel).offersChat(for: program), let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return .unavailable(chatCannotTell(program)) }
        let unavailable = ChatSessionEvidence.unavailable(chatCannotTell(program))
        let antigravityPID = program == .agy ? antigravityForeground(in: paneID) : nil
        guard program != .agy || antigravityPID != nil else { return unavailable }
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        if program == .agy {
            guard details.processID == antigravityPID,
                  RexAgentRule.agentKind(in: details) == program.rawValue else { return unavailable }
        }
        let evidence = try await chatBinder(at: address, details: details, program: program, server: activeServer)
            .check(chatRecord(at: address, details: details))
        if program == .agy {
            // After /clear the same PID can hold its next presence lock before
            // the first message publishes the official transcript.
            guard case .bound(let id, let root?, _) = evidence,
                  let uuid = ConversationReference.canonicalUUID(id) else { return unavailable }
            let path = AgyTranscriptLocator.transcriptPath(inFolder: AgyTranscriptLocator.folder(in: root, id: uuid))
            let head = try? await chatHostFiles().read(.init(path: path, offset: 0, maxBytes: 1))
            guard head?.data.first == 0x7B, details.processID == antigravityForeground(in: paneID) else { return unavailable }
        }
        guard server == activeServer else { throw TransportError.rexServerGone }
        return evidence
    }

    func droidDialogTarget(paneID: String) async throws -> DroidDialogTarget? {
        try await chatInputTarget(paneID: paneID, program: .droid)
    }

    func chatInputTarget(paneID: String, program: ChatProgram) async throws -> DroidDialogTarget? {
        guard program.pinsComposerToSession, !isAwaitingSnapshot, let address = RexPaneAddress(paneID: paneID), let listed = listedDetails(at: address),
              let active = server, let scope = chatCacheScope, (program == .devin || agentsByPane[paneID]?.agent.status != .unknown) else { return nil }
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: active)
        var target = try await chatBinder(at: address, details: details, program: program, server: active)
            .droidDialogTarget(chatRecord(at: address, details: details), scope: scope + "/" + paneID)
        target?.rexServerScope = scope
        if program == .devin, agentsByPane[paneID]?.agent.status == .unknown, target?.sessionID == nil { return nil }
        return server == active && chatCacheScope == scope ? target : nil
    }

    func claudePermissionLaunch(paneID: String) async throws -> ClaudePermissionMode.Launch? {
        guard !isAwaitingSnapshot, let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return nil }
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        let binder = chatBinder(at: address, details: details, program: .claude, server: activeServer)
        let ask = HerdrCoreSessionBinder.ProcessAsk(
            namesOf: [ChatTranscriptOffVariable.childSession.rawValue],
            arguments: ClaudePermissionMode.argumentWords, preservesArgumentOrder: true)
        guard
            let tree = try await binder.readTerminalProcesses(of: chatRecord(at: address, details: details), ask: ask),
            let pid = binder.agentProcess(in: tree), let facts = tree.facts[pid],
            server == activeServer
        else { return nil }
        return ClaudePermissionMode.Launch(pid: pid, facts: facts)
    }

    func chatCandidates(paneID: String, program: ChatProgram) async throws -> ChatCandidatesAnswer {
        guard program != .agy else { return .noProcess }
        guard !isAwaitingSnapshot, inventory != nil else { throw TransportError.cancelled }
        guard HostCapabilities(serverKind: .rex, coreKernel: kernel).offersChat(for: program), let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let activeServer = server
        else { return .noProcess }
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        let answer = try await chatBinder(at: address, details: details, program: program, server: activeServer)
            .candidates(of: chatRecord(at: address, details: details))
        guard server == activeServer else { throw TransportError.rexServerGone }
        guard case .listed(var list) = answer else { return answer }
        list.core = activeServer.coreID
        return .listed(list)
    }

    /// Kept on this device for the terminal and its server, with
    /// the foreground and Agent kind it was made on: nothing is written on
    /// the Host or the server.
    func writeChatPick(
        _ candidate: ChatSessionCandidate, of list: ChatSessionCandidates, paneID: String
    ) async throws {
        guard
            let value = HerdrCoreSessionHint.pickLabelValue(
                session: candidate.sessionID, file: candidate.file, pid: list.pid, start: list.start)
        else { throw TransportError.cancelled }
        guard let activeServer = server, inventoryCore == activeServer.coreID,
            list.core == nil || list.core == activeServer.coreID
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
    /// listed (rex-compatibility.md). An unanswered read cannot authorize input or a pick.
    private func detailsWithCurrentForeground(
        at address: RexPaneAddress, listed: RexTerminalDetails, server activeServer: RexServerStatus
    ) async throws -> RexTerminalDetails {
        let requests = try await session.blockRequests(at: address, readDeadline: chatReadDeadline)
        guard requests.server == activeServer else { throw TransportError.rexServerGone }
        let answer = try await requests.read(.process)
        guard server == activeServer, listedDetails(at: address) != nil else { throw TransportError.rexServerGone }
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
        let core = activeServer.coreID
        return HerdrCoreSessionBinder(
            program: program,
            processes: { request in try await Self.reads(session).readProcesses(request) },
            foregroundDroid: { pid, start, home, cwd in
                try await Self.reads(session).foregroundDroid(pid: pid, start: start, home: home, cwd: cwd)
            },
            files: chatHostFiles(),
            clearLabels: { stale in await self.clearStalePick(stale, at: paneID, on: core) },
            currentLabels: { await self.pickLabels(at: paneID, on: core) },
            isDroppedPick: { value in await self.droppedPicks[paneID]?.contains(value) == true },
            hostSystem: HerdrCoreHostSystem(kernel: kernel),
            processScope: .rex(
                sessionID: address.sessionID, blockID: address.blockID,
                foregroundNames: Self.foregroundNames(
                    details, onWindows: HerdrCoreHostSystem(kernel: kernel) == .windows)))
    }

    /// What Rex named of a terminal's foreground: its name, and its first
    /// argument's last path part. On Windows Rex names the image, such as
    /// `claude.exe`, and a path there may part at `\`, so each name takes
    /// the form a Windows process read gives (rex-compatibility.md).
    nonisolated static func foregroundNames(_ details: RexTerminalDetails, onWindows: Bool = false) -> Set<String> {
        let separators: Set<Character> = onWindows ? ["/", "\\"] : ["/"]
        let firstArgument = details.argv0.flatMap {
            $0.split(whereSeparator: separators.contains).last.map(String.init)
        }
        let names = [details.program, firstArgument].compactMap { $0 }.filter { !$0.isEmpty }
        return Set(onWindows ? names.map(HostProcessReader.windowsProgramName) : names)
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

    func bannerRecipient(for paneID: String) -> RexBannerRecipient? {
        guard RexBannerRecipient.isSupported(on: host, kernel: kernel), status == .connected,
            !isAwaitingSnapshot, let server, let address = RexPaneAddress(paneID: paneID),
            let details = listedDetails(at: address), let pid = details.processID,
            let kind = RexAgentRule.agentKind(in: details),
            let follow = RexAgentRule.report(of: details, heldBy: kind)?.follow else { return nil }
        return RexBannerRecipient(
            instanceID: server.instanceID, connectionGeneration: transportGeneration, followID: follow.id, pid: pid, kind: kind)
    }

    func verifyBannerRecipient(_ captured: RexBannerRecipient, for paneID: String) async -> Bool {
        guard bannerRecipient(for: paneID) == captured, let server, let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address),
            let fresh = try? await detailsWithCurrentForeground(at: address, listed: listed, server: server)
        else { return false }
        return fresh.processID == captured.pid && RexAgentRule.agentKind(in: fresh) == captured.kind
            && bannerRecipient(for: paneID) == captured
    }

    /// The terminal's pick as it stands now; nil once its server or the
    /// terminal is gone, which says nothing newer.
    private func pickLabels(at paneID: String, on core: String) -> [String: String]? {
        guard inventoryCore == core, let address = RexPaneAddress(paneID: paneID),
            listedDetails(at: address) != nil
        else { return nil }
        return memory.rexChatPicks(for: host.id)[paneID].map { [HerdrCoreSessionHint.pickLabel: $0.label] } ?? [:]
    }

    /// A pick the binder found stale goes, if it is still the one kept. The
    /// check that found it already answers without it.
    private func clearStalePick(_ stale: [String: String], at paneID: String, on core: String) {
        guard inventoryCore == core, let value = stale[HerdrCoreSessionHint.pickLabel],
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

    /// Actions without a Rex implementation stay unavailable at the projection boundary.
    private nonisolated static var unavailable: TransportError {
        .hostFeatureUnavailable(feature: String(localized: "This action on a Rex Host"))
    }

    private var supportsProjectOperations: Bool {
        kernel == HerdrCoreLocator.macOSKernel || kernel == HerdrCoreLocator.linuxKernel
    }

    private func projectConnection() async throws -> (RexServerStatus, any RexHostProjects) {
        guard supportsProjectOperations, let server, !isAwaitingSnapshot else { throw Self.unavailable }
        return try await session.withConnection { connection in
            guard connection.server == server else { throw TransportError.rexServerGone }
            guard let projects = connection.transport.projects else { throw Self.unavailable }
            return (server, projects)
        }
    }

    func withProjectReads<Value: Sendable>(
        _ operation: @escaping @Sendable (any HostProjectReading) async throws -> Value
    ) async throws -> Value {
        let (server, projects) = try await projectConnection()
        let value = try await operation(projects)
        guard self.server == server else { throw TransportError.rexServerGone }
        return value
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        guard acceptsAgentCommand else { throw Self.unavailable }
        let (server, projects) = try await projectConnection()
        let found = try await projects.discoverRexAgents()
        guard self.server == server else { throw TransportError.rexServerGone }
        openCodeVersion = found.openCodeVersion
        return found.kinds
    }

    func launchDirectory(ofWorkspace workspaceID: String, asked: String) -> String {
        if !asked.isEmpty { return asked }
        return inventory?.sessions.first { $0.id == workspaceID }?.launchDirectory ?? ""
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        guard let workspace = request.workspaceID, inventory?.sessions.contains(where: { $0.id == workspace }) == true,
            let server, supportsProjectOperations else { throw Self.unavailable }
        let cwd = launchDirectory(ofWorkspace: workspace, asked: request.cwd ?? "")
        return try await launch(request, cwd: cwd, placement: .window(sessionID: workspace), server: server)
    }

    func startAgentInNewWorkspace(_ request: AgentLaunchRequest, workspace: NewWorkspaceSpec) async throws -> Agent {
        guard let server, supportsProjectOperations, !isAwaitingSnapshot else { throw Self.unavailable }
        let label = workspace.label ?? RexNewTerminal.sessionLabel(for: workspace.directory)
        return try await launch(request, cwd: workspace.directory, placement: .session(label: label), server: server)
    }

    func startAgentInNewWorktree(_ request: AgentLaunchRequest, worktree: WorktreeSpec) async throws -> Agent {
        guard acceptsAgentCommand, let workspace = request.workspaceID,
            inventory?.sessions.contains(where: { $0.id == workspace }) == true
        else { throw Self.unavailable }
        let source = launchDirectory(ofWorkspace: workspace, asked: request.cwd ?? "")
        guard RemoteFilePath.isAcceptable(source) else { throw HerdrCoreWorktreeError.notInGitRepository }
        let (server, projects) = try await projectConnection()
        let git = HerdrCoreWorktreeGit(services: projects, gate: gitGate, checkoutRoot: ".heeler")
        let branch = worktree.branch ?? ""
        let checkout = try await git.create(branch: branch, from: source, startPoint: worktree.base)
        do {
            return try await launch(request, cwd: checkout.path, placement: .session(label: branch), server: server)
        } catch {
            throw WorktreeAgentStartFailure(checkoutPath: checkout.path, underlying: error)
        }
    }

    private func launch(
        _ request: AgentLaunchRequest, cwd: String, placement: RexNewTerminal.Placement, server: RexServerStatus
    ) async throws -> Agent {
        guard acceptsAgentCommand, self.server == server else { throw Self.unavailable }
        guard RemoteFilePath.isAcceptable(cwd) else { throw TransportError.invalidDirectoryPath(path: cwd) }
        let launchRequest = try await session.withConnection { [kernel] connection in
            guard connection.server == server else { throw TransportError.rexServerGone }
            let directory = try await connection.transport.reads.fileStatus(atPath: cwd)
            guard directory?.kind == .directory else {
                throw TransportError.rexRejected(code: "directory_missing", message: ChangesReadError.directoryMissing.message)
            }
            var launch = request
            if DroidChatHook.offersLaunchSettings(kind: request.kind, arguments: request.arguments, kernel: kernel),
                let settings = try? await connection.transport.extensionPlacing.prepareDroidChatHook(.launch) {
                launch.arguments = ["--settings", settings] + launch.arguments
            }
            return launch
        }
        let program = try RexNewTerminal.Program(request: launchRequest, cwd: cwd, openCodeVersion: openCodeVersion)
        let made = try await session.createTerminal(placement, cwd: cwd, program: program, keepingTo: server)
        guard self.server == server else { throw TransportError.rexServerGone }
        let pane = made.address.paneID
        return Agent(terminalID: pane, kind: request.kind, title: "", status: .unknown,
            workspaceID: made.address.sessionID, tabID: made.windowID, paneID: pane,
            cwd: cwd, revision: 0, name: request.name)
    }

    /// New Terminal: a shell in a new window of the Workspace's session, in
    /// the background, which lists once the server's events say so.
    func createShellTerminal(_ request: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        Self.identity(of: try await session.createTerminal(.window(sessionID: request.workspaceID), cwd: request.cwd,
                                                          windowLabel: supportsProjectOperations ? request.label : nil))
    }

    /// New Workspace: a new session whose one window holds the shell,
    /// labeled with the name given, else with its directory's name, as other
    /// Hosts name theirs. Its first window can carry its own label.
    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity {
        let label =
            workspace.label.flatMap { $0.isEmpty ? nil : $0 }
            ?? RexNewTerminal.sessionLabel(for: workspace.directory)
        return Self.identity(of: try await session.createTerminal(.session(label: label), cwd: workspace.directory,
                                                                 windowLabel: supportsProjectOperations ? tabLabel : nil))
    }

    /// A Rex terminal's Pane and Terminal ids are both its address, and its
    /// Tab is its window.
    private nonisolated static func identity(of created: RexNewTerminal.Created) -> ShellTerminalIdentity {
        ShellTerminalIdentity(
            paneID: created.address.paneID, tabID: created.windowID, terminalID: created.address.paneID)
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
    /// A Rex Agent name is its block label. A later program in the same block
    /// must not receive an edit prepared while another foreground was listed.
    func renameBlockAction(for paneID: String) -> ((String?) async throws -> Void)? {
        guard let server, supportsProjectOperations, let address = RexPaneAddress(paneID: paneID),
            let listed = listedDetails(at: address), let pid = listed.processID,
            let kind = RexAgentRule.agentKind(in: listed) else { return nil }
        return { [self] name in
            guard self.server == server,
                let current = self.listedDetails(at: address) else { throw TransportError.rexServerGone }
            let fresh = try await self.detailsWithCurrentForeground(at: address, listed: current, server: server)
            guard fresh.processID == pid, fresh.program == listed.program,
                RexAgentRule.agentKind(in: fresh) == kind else { throw TransportError.rexServerGone }
            try await self.session.withConnection { connection in
                guard connection.server == server else { throw TransportError.rexServerGone }
                _ = try await connection.control.call("session.set_block_label", payload: JSONValue.object([
                    "session_id": .string(address.sessionID), "block_id": .string(address.blockID),
                    "label": .string(name ?? ""),
                ]))
                let target = JSONValue.object(["session_id": .string(address.sessionID)])
                let list = try await connection.control.call("session.list_blocks", payload: target).result(JSONValue.self)
                guard let block = RexInventoryWire.blocks(list)?.first(where: { $0.facts.id == address.blockID }),
                    name.map({ $0 == block.facts.label }) ?? (block.facts.customLabel == nil)
                else { throw TransportError.rexAnswerUnreadable(String(localized: "Rex did not confirm the new block name. Check the terminal before renaming it again.")) }
            }
            // Detached blocks receive no label event on preview.25.
            await self.refreshTerminalInventory()
        }
    }

    func renameAgent(_ paneID: String, name: String?) async throws {
        guard let rename = renameBlockAction(for: paneID) else { throw Self.unavailable }
        try await rename(name)
    }

    func renameWorkspace(_ workspaceID: String, label: String) async throws {
        guard let server, supportsProjectOperations, inventory?.sessions.contains(where: { $0.id == workspaceID }) == true
        else { throw Self.unavailable }
        try await session.withConnection { connection in
            guard connection.server == server else { throw TransportError.rexServerGone }
            let target = JSONValue.object(["session_id": .string(workspaceID)])
            let view = try await connection.control.call("session.view", payload: target).result(JSONValue.self)
            guard view["session_id"]?.stringValue == workspaceID else { throw TransportError.rexServerGone }
            _ = try await connection.control.call("session.set_label", payload: JSONValue.object([
                "session_id": .string(workspaceID), "label": .string(label),
            ]))
            let renamed = try await connection.control.call("session.view", payload: target).result(JSONValue.self)
            guard renamed["session_id"]?.stringValue == workspaceID,
                renamed["label"]?.stringValue == label.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw TransportError.rexAnswerUnreadable(String(localized: "Rex did not confirm the new Workspace name. Check the Workspace before renaming it again."))
            }
        }
    }

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
                try await projection.chatTyping(at: paneID).press(["esc"], checksChatPick: false)
                return .sent
            } catch let refusal as RexChatTyping.Refusal {
                return .failed(refusal.message)
            } catch {
                return .failed(ChatStopPlan.unreachableMessage)
            }
        }
        return stop.map(TerminalStopOffer.interrupt) ?? .keepSend
    }

    /// Chat's Stop verifies the bound turn inside the block's input lane.
    /// Rex's own records can establish a working foreground, while a process
    /// can hold several conversations or start a new turn under the same PID.
    func checkedChatStop(
        for paneID: String, program: ChatProgram, keepingTo corePin: TerminalCorePin,
        agentKeys: ChatAgentKeysStore? = nil, followThrough: (@MainActor () -> ChatStopFollowThrough?)? = nil,
        confirmTarget: ChatStopVerification? = nil, live: @escaping @MainActor () -> (any ConsoleHostProjection)?
    ) -> AgentComposerInterrupt? {
        if program == .agy {
            return .escape { .failed(String(localized: "Use the Antigravity terminal to stop work.")) }
        }
        let plan = ChatStopPlan.standard(for: program)
        let address = RexPaneAddress(paneID: paneID)
        let listed = address.flatMap { listedDetails(at: $0) }
        let report = listed.flatMap { RexAgentRule.report(of: $0, heldBy: program.rawValue) }
        let perform: @MainActor () async -> AgentInterruptOutcome = { [weak self] in
            guard let self, let projection = live() as? RexConsoleProjection, projection === self,
                  self.admits(corePin), let pid = listed?.processID, let report,
                  HerdrCoreAgentRule.agentStatus(report.state) == .working, let confirmTarget
            else { return .failed(ChatStopPlan.changedDroidTurn) }
            do {
                let typing = try self.chatTyping(at: paneID)
                try await typing.press(plan.keys, checksChatPick: false, confirming: { requests, holder in
                    guard holder.pid == pid, holder.kind == program.rawValue, await confirmTarget(),
                          let active = RexInventoryWire.rootStatus(try await requests.read(.programStatus)),
                          active.isSameProgram(as: report), HerdrCoreAgentRule.agentStatus(active.state) == .working
                    else { throw RexChatTyping.Refusal(message: ChatStopPlan.changedDroidTurn) }
                    if let guardScreen = plan.screenGuard {
                        let screen = try await RexChatScreen.read(on: requests).screen
                        if case .refuse(let reason) = guardScreen(.init(screen: screen, activity: .working)) {
                            throw RexChatTyping.Refusal(message: reason)
                        }
                    }
                })
                return .sent
            } catch let refusal as RexChatTyping.Refusal {
                return .failed(refusal.message)
            } catch TransportError.coreMutationOutcomeUnknown {
                return .failed(TransportError.coreMutationOutcomeUnknown.presentation.message)
            } catch {
                return .failed(ChatStopPlan.unreachableMessage)
            }
        }
        return AgentComposerInterrupt(wait: plan.wait, accessibilityHint: plan.accessibilityHint) {
            let after = followThrough?()
            let outcome = if let agentKeys { await agentKeys.inOrder(perform) } else { await perform() }
            guard outcome == .sent, let after else { return outcome }
            let left = if let agentKeys { await agentKeys.afterQueued(after) } else { await after() }
            return left.map(AgentInterruptOutcome.sentLeavingWork) ?? .sent
        }
    }

    /// Keyboard controls have no transcript of their own. If a Chat pick is
    /// kept for this pane, only independent foreground evidence for that
    /// exact conversation authorizes typing beside its history.
    func admitsPickedChatInput(at address: RexPaneAddress, heldBy holder: RexAgentHolder) async -> Bool {
        guard let pick = memory.rexChatPicks(for: host.id)[address.paneID] else { return true }
        guard let program = ChatProgram(rawValue: holder.kind), holder.pid == pick.foregroundPID,
              let expected = HerdrCoreSessionHint(label: pick.label),
              case .bound(let id, _, _) = try? await checkChatSession(paneID: address.paneID, program: program)
        else { return false }
        return ConversationReference(program: program, sessionID: id).namesSameSession(as:
            ConversationReference(program: program, sessionID: expected.session))
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
        guard pin.admits(requests.server.coreID) else { throw TransportError.rexServerGone }
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
                    guard await handler.admitsCore(connection.server.coreID) else {
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

    /// The live connection's staging, while its server is the one `pin`
    /// keeps to; another server throws `TransportError.rexServerGone`
    /// before anything is staged, as Chat's block requests do. What the
    /// session throws while no server answers passes through.
    private func staging(keepingTo pin: TerminalCorePin) async throws -> any RexHostStaging {
        guard admits(pin) else { throw TransportError.rexServerGone }
        let (staging, core) = try await session.withConnection { ($0.transport.staging, $0.server.coreID) }
        guard admits(pin), pin.admits(core) else { throw TransportError.rexServerGone }
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
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        guard let program = RexAgentRule.agentKind(in: details).flatMap(ChatProgram.init(rawValue:)),
            program.namesItsSessionThroughHeelersExtension,
            let folder = try await chatBinder(at: address, details: details, program: program, server: activeServer)
                .piFamilyExtensionFolder(of: chatRecord(at: address, details: details))
        else { throw Self.extensionFolderUnknown }
        return folder
    }

    /// Writes Heeler's extension into `folder` over the Host's SSH connection
    /// (`RexHostExtensionPlacing`), for the Agent on the server `corePin`
    /// keeps to, then has its Chat look again. Another server throws
    /// `TransportError.rexServerGone` before anything is written.
    func configureDroidChatHook(_ action: DroidChatHook.Action, keepingTo pin: TerminalCorePin?) async throws {
        let (placing, core) = try await session.withConnection { ($0.transport.extensionPlacing, $0.server.coreID) }
        if let pin { guard admits(pin), pin.admits(core) else { throw TransportError.rexServerGone } }
        _ = try await placing.prepareDroidChatHook(action)
    }

    func placeChatExtension(_ contents: Data, inFolder folder: String, keepingTo pin: TerminalCorePin?) async throws {
        if let pin { guard admits(pin) else { throw TransportError.rexServerGone } }
        let (placing, core) = try await session.withConnection {
            ($0.transport.extensionPlacing, $0.server.coreID)
        }
        if let pin { guard admits(pin), pin.admits(core) else { throw TransportError.rexServerGone } }
        try await placing.placeHeelersExtension(contents, inFolder: folder)
        inventoryReplacements &+= 1
        onChange()
    }

    func openCodeEditServices() async throws -> any HarnessConfigFileAccess {
        try await session.withConnection { $0.transport.extensionPlacing }
    }

    func openCodeEditContext(paneID: String) async throws -> (version: String?, home: String, xdgConfigHome: String?) {
        guard !isAwaitingSnapshot, inventory != nil,
            let address = RexPaneAddress(paneID: paneID), let listed = listedDetails(at: address),
            let activeServer = server
        else { throw HarnessConfigEditError.agentEnvironmentUnavailable }
        let details = try await detailsWithCurrentForeground(at: address, listed: listed, server: activeServer)
        let record = chatRecord(at: address, details: details)
        let binder = chatBinder(at: address, details: details, program: .opencode, server: activeServer)
        let ask = HerdrCoreSessionBinder.ProcessAsk(values: ["PATH", "HOME", "XDG_CONFIG_HOME"])
        guard let tree = try await binder.readTerminalProcesses(of: record, ask: ask),
            let pid = binder.agentProcess(in: tree), let facts = tree.facts[pid],
            server == activeServer
        else { throw HarnessConfigEditError.agentEnvironmentUnavailable }
        let path: String?
        switch facts.variables["PATH"] {
        case .value(let value): path = value
        case .unset: path = nil
        case .unavailable, nil: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        let home: String
        switch facts.variables["HOME"] {
        case .value(let value): home = value
        case .unset: home = try await Self.reads(session).hostHomeDirectory()
        case .unavailable, nil: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        let xdgConfigHome: String?
        switch facts.variables["XDG_CONFIG_HOME"] {
        case .value(let value): xdgConfigHome = value
        case .unset: xdgConfigHome = nil
        case .unavailable, nil: throw HarnessConfigEditError.agentEnvironmentUnavailable
        }
        let program = OpenCodePluginEdit.program(running: [details.argv0 ?? details.program ?? SupportedAgentKind.opencode.executable])
        let nonce = HostProcessReader.makeNonce()
        let script = HerdrCoreShellLaunch.versionScript(
            program: program, path: path, directory: details.directory, nonce: nonce)
        let result = try await session.withConnection { link in
            guard link.server == activeServer else { throw TransportError.rexServerGone }
            return try await link.transport.extensionPlacing.runOpenCodeVersionScript(script)
        }
        guard let found = try? HerdrCoreShellLaunch.parseDiscovery(stdout: result.stdout, nonce: nonce) else {
            throw TransportError.malformedResponse(
                String(localized: "The Host's shell did not finish reading OpenCode's version."))
        }
        return (version: found.version, home: home, xdgConfigHome: xdgConfigHome)
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
            home: { try await Self.reads(session).hostHomeDirectory() },
            queryDevin: { try await Self.reads(session).queryDevin($0) },
            queryOpenCode: { try await Self.reads(session).queryOpenCode($0) })
    }

    /// New Terminal starts in the account's home directory and browses with
    /// these, on the connection the server's links use.
    func remoteHomeDirectory() async throws -> String {
        try await session.withConnection { $0.transport.browsing }.remoteHomeDirectory()
    }

    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing {
        try await session.withConnection { $0.transport.browsing }.listDirectories(at: path)
    }

    /// Chat reads the Host's files and processes through `RexHostReads`, an
    /// attachment is staged through `RexHostStaging`, and Heeler's extension
    /// goes where the user asks through `RexHostExtensionPlacing`, and the
    /// GitHub tab's gh and its checkout read run through `runGitHubScript`;
    /// nothing else runs on it over SSH: Changes, Skills, harness edits, the
    /// agy model list and the platform probe stay out, and the Host is POSIX
    /// without asking it (ADR 0056).
    func withHostServices<Value: Sendable>(
        _: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        throw Self.unavailable
    }

    /// The GitHub tab's gh runs, and its read of the Agents' checkouts, on
    /// the connection the server's links use (ADR 0065).
    func runGitHubScript(_ script: Data, isMutation: Bool) async throws -> GitExecResult {
        let gitHub = try await session.withConnection { $0.transport.gitHub }
        return try await gitHub.runGitHubScript(script, isMutation: isMutation)
    }

    /// A Rex Host has no plugin, Notifications or Usage files, and its plugin
    /// surfaces say it is the Server Kind's doing.
    func withNotificationTransport<Value: Sendable>(
        _: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.rex
    }
}

extension RexConsoleProjection: AmpChatProjection {
    /// Rex identifies the foreground process. Recheck the block after reading
    /// the process birth and configuration directory over SSH.
    func ampPluginLocation(in pane: String) async throws -> AmpPluginLocation {
        guard kernel == HerdrCoreLocator.linuxKernel || kernel == HerdrCoreLocator.macOSKernel,
              !isAwaitingSnapshot, let address = RexPaneAddress(paneID: pane), let listed = listedDetails(at: address),
              let currentServer = server else { throw AmpChatProblem.unidentified }
        let before = try await detailsWithCurrentForeground(at: address, listed: listed, server: currentServer)
        guard RexAgentRule.agentKind(in: before) == ChatProgram.amp.rawValue, let pid = before.processID, pid > 0
        else { throw AmpChatProblem.unidentified }
        let key = String(pid)
        let facts = try await session.withConnection { link in
            guard link.server == currentServer else { throw TransportError.rexServerGone }
            return try await link.transport.reads.readProcesses(.init(pids: [key], readsStart: true, valuesOf: ["HOME", "XDG_CONFIG_HOME"]))
        }
        let after = try await detailsWithCurrentForeground(at: address, listed: listed, server: currentServer)
        guard after.processID == pid, RexAgentRule.agentKind(in: after) == ChatProgram.amp.rawValue, let fact = facts[key],
              let place = AmpPluginLocation(pid: pid, facts: fact, serverInstance: currentServer.instanceID)
        else { throw AmpChatProblem.changed }
        return place
    }

    func exchangeAmp(_ request: AmpChatRequest, record: AmpPluginRecord, at place: AmpPluginLocation, in pane: String) async throws -> AmpChatReply {
        try await withAmp(at: place, in: pane) { endpoint in
            try await endpoint.exchangeAmpChat(request, record: record)
        }
    }

    func installAmp(at place: AmpPluginLocation, replacing previous: Data?, in pane: String) async throws {
        try await withAmp(at: place, in: pane) { endpoint in
            try await endpoint.installAmpChatPlugin(in: place.directory, replacing: previous)
        }
    }

    private func withAmp<Value: Sendable>(
        at place: AmpPluginLocation, in pane: String,
        operation: @escaping @Sendable (any AmpChatHost) async throws -> Value
    ) async throws -> Value {
        guard try await ampPluginLocation(in: pane) == place else { throw AmpChatProblem.changed }
        let result = try await session.withConnection { link in
            guard link.server.instanceID == place.serverInstance, let endpoint = link.transport.amp else {
                throw AmpChatProblem.changed
            }
            return try await operation(endpoint)
        }
        guard try await ampPluginLocation(in: pane) == place else { throw AmpChatProblem.changed }
        return result
    }
}
