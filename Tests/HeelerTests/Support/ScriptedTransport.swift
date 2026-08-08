import Foundation

@testable import Heeler

/// Scripted `Transport` for Console and EventsSession protocol-level tests:
/// the test scripts the snapshot and pane text, and drives the event stream
/// by hand. No SSH anywhere.
final actor ScriptedTransport: Transport {
    private(set) var isClosed = false
    /// Every subscription set received, in order; the Console's
    /// resubscribe-on-membership-change behavior asserts on this.
    private(set) var capturedSubscriptions: [[EventSubscription]] = []
    private(set) var paneReadParams: [PaneReadParams] = []
    /// Every `agent.start` received, in order; the new-agent flow (#12)
    /// asserts on the params it forwarded.
    private(set) var agentStarts: [AgentLaunchRequest] = []
    /// Every worktree launch received, in order; the new-worktree flow (#97)
    /// asserts on the request/spec pairs it forwarded.
    private(set) var worktreeStarts: [(request: AgentLaunchRequest, worktree: WorktreeSpec)] = []
    private(set) var agentDiscoveryCount = 0
    private var availableKinds = SupportedAgentKind.allCases
    private var agentDiscoveryFailure: TransportError?
    /// Every `pane.close` received, in order; the close-pane flow (#13)
    /// asserts on the pane it targeted (and that the cancel path never
    /// appends here).
    private(set) var closedPanes: [PaneTarget] = []
    private var closeFailure: TransportError?
    /// Every `agent.rename` / `workspace.rename` received, in order; the
    /// rename flows (#98) assert on the params they forwarded.
    private(set) var agentRenames: [AgentRenameParams] = []
    private(set) var workspaceRenames: [WorkspaceRenameParams] = []
    private var renameFailure: TransportError?
    private var startFailure: TransportError?
    private var startedAgent: AgentInfo?
    private(set) var snapshotFetchCount = 0
    /// Every attach request received, in order; the Attach store's
    /// open-once behavior asserts on this.
    private(set) var attachRequests: [TerminalAttachRequest] = []
    /// Everything sent down the live attach session, in order — keystrokes
    /// and resizes interleaved exactly as the store issued them.
    private(set) var attachInputs: [TerminalAttachInput] = []

    /// Every `ping` received, in order of arrival; the keepalive tests assert
    /// on how many the idle loop generated.
    private(set) var pingCount = 0
    private var pingFailures: [Int: TransportError] = [:]
    private var pingGate: ScriptedTransportCallGate?
    private var closeGate: ScriptedTransportCallGate?

    private var serverInfo: ServerInfo
    private var snapshot: SessionSnapshot
    private var snapshotFailure: TransportError?
    private var nextSnapshotGate: ScriptedTransportCallGate?
    private var paneTexts: [String: String] = [:]
    private var paneReadFailure: TransportError?
    private var nextPaneReadGate: ScriptedTransportCallGate?
    private var missingPaneIDs: Set<String> = []
    private var nextStreamID: UInt64 = 0
    private var liveStreamID: UInt64?
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var nextAttachID: UInt64 = 0
    private var liveAttachID: UInt64?
    private var attachContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var attachInputTask: Task<Void, Never>?
    private var nextAttachEndGate: ScriptedTransportCallGate?
    private(set) var stageRequests: [PreparedImage] = []
    private var stageOutcomes: [Result<StagedImage, ImageStagingError>] = []
    private var stageGate: ScriptedTransportCallGate?
    /// The Host's current Notification Registration file bytes; nil scripts
    /// "no device registered yet".
    private(set) var notificationRegistration: Data?
    /// Every whole-file replace received, in order; the ceremony tests
    /// assert on what would have landed on the Host.
    private(set) var replacedNotificationRegistrations: [Data] = []
    private(set) var notificationRegistrationReads = 0
    private var notificationRegistrationReadFailure: NotificationRegistrationError?
    private var notificationRegistrationWriteFailure: NotificationRegistrationError?
    /// The Host's current `notify.json` bytes; nil scripts "no config yet".
    /// The relay-URL write path (#76) asserts on what the ceremony merged in.
    private(set) var notificationConfig: Data?
    /// Every `notify.json` replace received, in order.
    private(set) var replacedNotificationConfigs: [Data] = []
    private(set) var notificationConfigReads = 0

    init(
        snapshot: SessionSnapshot = .fixture(),
        serverInfo: ServerInfo = ServerInfo(version: "0.7.5-fake", protocolVersion: 17)
    ) {
        self.snapshot = snapshot
        self.serverInfo = serverInfo
    }

    // MARK: Scripting

    /// Replaces the snapshot subsequent `sessionSnapshot()` calls return.
    func setSnapshot(_ snapshot: SessionSnapshot) {
        self.snapshot = snapshot
    }

    /// Makes every subsequent `sessionSnapshot` throw `failure`.
    func setSnapshotFailure(_ failure: TransportError?) {
        snapshotFailure = failure
    }

    /// Pauses the next snapshot after capturing its response, so tests can
    /// deterministically deliver events while that stale response is in flight.
    func gateNextSnapshot(using gate: ScriptedTransportCallGate) {
        nextSnapshotGate = gate
    }

    /// Scripts the text `readPane` returns for `paneID`.
    func setPaneText(_ text: String, paneID: String) {
        paneTexts[paneID] = text
    }

    /// Makes every subsequent `readPane` throw `failure`.
    func setPaneReadFailure(_ failure: TransportError?) {
        paneReadFailure = failure
    }

    /// Pauses the next pane read after capturing its response.
    func gateNextPaneRead(using gate: ScriptedTransportCallGate) {
        nextPaneReadGate = gate
    }

    /// Scripts the `AgentInfo` `startAgent` returns; without it the fake
    /// synthesizes a Working agent from the start params.
    func setStartedAgent(_ agent: AgentInfo) {
        startedAgent = agent
    }

    /// Makes every subsequent `startAgent` throw `failure`.
    func setStartFailure(_ failure: TransportError?) {
        startFailure = failure
    }

    func setAvailableAgentKinds(
        _ kinds: [SupportedAgentKind],
        failure: TransportError? = nil
    ) {
        availableKinds = kinds
        agentDiscoveryFailure = failure
    }

    /// Makes every subsequent `closePane` throw `failure`.
    func setCloseFailure(_ failure: TransportError?) {
        closeFailure = failure
    }

    /// Makes every subsequent rename (agent or workspace) throw `failure`.
    func setRenameFailure(_ failure: TransportError?) {
        renameFailure = failure
    }

    func configureImageStaging(
        outcomes: [Result<StagedImage, ImageStagingError>],
        gate: ScriptedTransportCallGate? = nil
    ) {
        stageOutcomes = outcomes
        stageGate = gate
    }

    func gateNextAttachEnd(on gate: ScriptedTransportCallGate) {
        nextAttachEndGate = gate
    }

    /// Pushes one event onto the live stream; false if none is live.
    @discardableResult
    func emit(_ event: HerdrEvent) -> Bool {
        guard let eventContinuation else { return false }
        eventContinuation.yield(event)
        return true
    }

    /// Kills the live stream with `failure`, as a remotely dropped events
    /// channel would.
    func failEventStream(_ failure: TransportError) {
        eventContinuation?.finish(throwing: failure)
        eventContinuation = nil
        liveStreamID = nil
    }

    /// Pushes raw PTY bytes onto the live attach session; false if none is
    /// live.
    @discardableResult
    func emitAttachOutput(_ bytes: Data) -> Bool {
        guard let attachContinuation else { return false }
        attachContinuation.yield(bytes)
        return true
    }

    /// Ends the live attach session gracefully, as the remote attach exiting
    /// cleanly (the user detached inside the TUI) would.
    func endAttachFromRemote() {
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
    }

    /// Kills the live attach session with `failure`, as a remotely dropped
    /// terminal channel would.
    func failAttachStream(_ failure: TransportError) {
        attachContinuation?.finish(throwing: failure)
        attachContinuation = nil
        liveAttachID = nil
    }

    /// Whether an attach session is currently live.
    var hasLiveAttachSession: Bool {
        attachContinuation != nil
    }

    /// Scripts the registration file the Host currently holds.
    func setNotificationRegistration(_ data: Data?) {
        notificationRegistration = data
    }

    /// Makes every subsequent registration read throw `failure`.
    func setNotificationRegistrationReadFailure(_ failure: NotificationRegistrationError?) {
        notificationRegistrationReadFailure = failure
    }

    /// Makes every subsequent registration replace throw `failure`.
    func setNotificationRegistrationWriteFailure(_ failure: NotificationRegistrationError?) {
        notificationRegistrationWriteFailure = failure
    }

    /// Scripts the `notify.json` config the Host currently holds.
    func setNotificationConfig(_ data: Data?) {
        notificationConfig = data
    }

    /// Makes the `ordinal`-th `ping` on this transport throw `failure`. A real
    /// Transport turns a request the connection never answers into
    /// `.timedOut` at its deadline, so scripting that outcome exercises the
    /// same seam the session sees without putting a test on the clock.
    func failPing(atCall ordinal: Int, with failure: TransportError) {
        pingFailures[ordinal] = failure
    }

    /// Parks the next `ping` on `gate`, after counting it, so a test can hold
    /// one Host's liveness proof in flight while inspecting another's.
    func gateNextPing(using gate: ScriptedTransportCallGate) {
        pingGate = gate
    }

    /// Parks the next `close()` on `gate` — which records the entry before
    /// waiting — so a test can pin a session teardown mid-flight.
    func gateNextClose(using gate: ScriptedTransportCallGate) {
        closeGate = gate
    }

    /// Scripts panes that no longer exist on the Host. herdr fails an entire
    /// `events.subscribe` when one pane-scoped entry names a pane that has
    /// exited (verified against a live 0.7.5 server), so the fake rejects the
    /// same way instead of quietly skipping the entry.
    func setMissingPanes(_ paneIDs: Set<String>) {
        missingPaneIDs = paneIDs
    }

    // MARK: Transport

    func ping() async throws -> ServerInfo {
        pingCount += 1
        let failure = pingFailures[pingCount]
        let gate = pingGate
        pingGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        return serverInfo
    }

    func listAgents() async throws -> [Agent] {
        snapshot.agents.map(Agent.init)
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        agentDiscoveryCount += 1
        if let agentDiscoveryFailure { throw agentDiscoveryFailure }
        return availableKinds
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        snapshotFetchCount += 1
        let response = snapshot
        let failure = snapshotFailure
        let gate = nextSnapshotGate
        nextSnapshotGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        return response
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        paneReadParams.append(params)
        let responseText = paneTexts[params.paneID] ?? ""
        let failure = paneReadFailure
        let gate = nextPaneReadGate
        nextPaneReadGate = nil
        await gate?.waitUntilOpen()
        if let failure { throw failure }
        return PaneReadResult(
            format: .text, paneID: params.paneID, revision: 0,
            source: params.source, tabID: "t", text: responseText,
            truncated: false, workspaceID: "w")
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        agentStarts.append(request)
        if let startFailure { throw startFailure }
        if let startedAgent { return Agent(startedAgent) }
        // Synthesize a freshly-Working agent so the caller and the follow-up
        // snapshot see the same pane the real server would report.
        return Agent(
            .fixture(
                paneID: "\(request.workspaceID ?? "w1"):pnew", status: .working,
                workspaceID: request.workspaceID ?? "w1", kind: request.kind,
                title: request.name))
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        worktreeStarts.append((request, worktree))
        if let startFailure { throw startFailure }
        if let startedAgent { return Agent(startedAgent) }
        // The real server answers with an agent in the *new* worktree
        // workspace, not the source one.
        return Agent(
            .fixture(
                paneID: "wt1:pnew", status: .working, workspaceID: "wt1",
                kind: request.kind, title: request.name))
    }

    func closePane(_ params: PaneTarget) async throws {
        if let closeFailure { throw closeFailure }
        closedPanes.append(params)
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        if let renameFailure { throw renameFailure }
        agentRenames.append(params)
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        if let renameFailure { throw renameFailure }
        workspaceRenames.append(params)
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard liveStreamID == nil else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        capturedSubscriptions.append(subscriptions)
        if let missing = subscriptions.firstMissingPane(in: missingPaneIDs) {
            throw HerdrAPIError(code: "pane_not_found", message: "pane \(missing) not found")
        }
        nextStreamID += 1
        let streamID = nextStreamID
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        liveStreamID = streamID
        eventContinuation = continuation
        return HerdrEventStream(events: events) {
            await self.endStream(id: streamID)
        }
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        guard liveAttachID == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        attachRequests.append(request)
        nextAttachID += 1
        let attachID = nextAttachID
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let endGate = nextAttachEndGate
        nextAttachEndGate = nil
        liveAttachID = attachID
        attachContinuation = outputContinuation
        attachInputTask = Task {
            while let item = await input.next() {
                self.recordAttachInput(item)
            }
        }
        return TerminalAttachSession(output: output, input: input) {
            await endGate?.waitUntilOpen()
            await self.endAttach(id: attachID)
        }
    }

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (ImageStageProgress) async -> Void
    ) async throws -> StagedImage {
        stageRequests.append(image)
        await progress(
            ImageStageProgress(transferredBytes: 0, totalBytes: image.byteCount))
        let gate = stageGate
        stageGate = nil
        await gate?.waitUntilOpen()
        try Task.checkCancellation()
        await progress(
            ImageStageProgress(
                transferredBytes: image.byteCount,
                totalBytes: image.byteCount))
        guard !stageOutcomes.isEmpty else {
            throw ImageStagingError.transferFailed
        }
        return try stageOutcomes.removeFirst().get()
    }

    func readNotificationRegistration() async throws -> Data? {
        notificationRegistrationReads += 1
        if let failure = notificationRegistrationReadFailure { throw failure }
        return notificationRegistration
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        if let failure = notificationRegistrationWriteFailure { throw failure }
        notificationRegistration = contents
        replacedNotificationRegistrations.append(contents)
    }

    func readNotificationConfig() async throws -> Data? {
        notificationConfigReads += 1
        if let failure = notificationRegistrationReadFailure { throw failure }
        return notificationConfig
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        if let failure = notificationRegistrationWriteFailure { throw failure }
        notificationConfig = contents
        replacedNotificationConfigs.append(contents)
    }

    var isConnected: Bool {
        !isClosed
    }

    func close() async throws {
        let gate = closeGate
        closeGate = nil
        await gate?.waitUntilOpen()
        isClosed = true
        eventContinuation?.finish()
        eventContinuation = nil
        liveStreamID = nil
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
    }

    /// Explicit `end()` on the stream: finishes it gracefully, exactly like
    /// the real channel closed by its consumer.
    private func endStream(id: UInt64) {
        guard liveStreamID == id else { return }
        eventContinuation?.finish()
        eventContinuation = nil
        liveStreamID = nil
    }

    private func recordAttachInput(_ input: TerminalAttachInput) {
        attachInputs.append(input)
    }

    /// Explicit `end()` on the session: finishes it gracefully, exactly like
    /// the real channel closed by its consumer. Drains the input recording
    /// first — `end()` finishes the input queue before calling this — so
    /// tests can assert on `attachInputs` without polling.
    private func endAttach(id: UInt64) async {
        await attachInputTask?.value
        attachInputTask = nil
        guard liveAttachID == id else { return }
        attachContinuation?.finish()
        attachContinuation = nil
        liveAttachID = nil
    }
}

private extension Sequence<EventSubscription> {
    /// The first pane-scoped entry naming a pane in `missing`, if any.
    func firstMissingPane(in missing: Set<String>) -> String? {
        for subscription in self {
            guard case .pane(_, let paneID) = subscription, missing.contains(paneID) else {
                continue
            }
            return paneID
        }
        return nil
    }
}

/// Hands scripted transports to an `EventsSession`'s `connect` closure in
/// order, one per dial, and counts the dials. The last entry repeats if the
/// session reconnects more often than the test scripted.
actor SequencedTransportConnector {
    private let transports: [ScriptedTransport]
    private(set) var connectCount = 0

    init(_ transports: [ScriptedTransport]) {
        precondition(!transports.isEmpty)
        self.transports = transports
    }

    func connect() async throws -> any Transport {
        let transport = transports[min(connectCount, transports.count - 1)]
        connectCount += 1
        return transport
    }
}

/// A one-shot test gate that exposes when a scripted transport call has
/// captured its response, then holds that response until the test releases it.
actor ScriptedTransportCallGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var entryCount = 0

    func waitUntilOpen() async {
        entryCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}

// MARK: Fixtures

extension SessionSnapshot {
    static func fixture(
        agents: [AgentInfo] = [], workspaces: [WorkspaceInfo] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: [], protocolVersion: 17, tabs: [],
            version: "0.7.5-fake", workspaces: workspaces)
    }
}

extension AgentInfo {
    static func fixture(
        paneID: String,
        status: AgentStatus = .idle,
        workspaceID: String = "w1",
        kind: String = "claude",
        title: String = "Task",
        revision: Int = 1,
        name: String? = nil
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: paneID, revision: revision,
            tabID: "\(workspaceID):t1", terminalID: "term_\(paneID)",
            workspaceID: workspaceID, agent: kind, cwd: "/work/\(workspaceID)",
            name: name, terminalTitleStripped: title)
    }
}

extension WorkspaceInfo {
    static func fixture(
        workspaceID: String, label: String, repoName: String? = nil
    ) -> WorkspaceInfo {
        WorkspaceInfo(
            activeTabID: "\(workspaceID):t1", agentStatus: .unknown, focused: false,
            label: label, number: 1, paneCount: 1, tabCount: 1, workspaceID: workspaceID,
            worktree: repoName.map { name in
                WorkspaceWorktreeInfo(
                    checkoutPath: "/work/\(name)", isLinkedWorktree: false,
                    repoKey: "/work/\(name)/.git", repoName: name, repoRoot: "/work/\(name)")
            })
    }
}

extension HerdrEvent {
    /// A `pane.agent_status_changed` event line as the live wire delivers it.
    static func agentStatusChanged(paneID: String, status: AgentStatus) -> HerdrEvent {
        HerdrEvent(
            kind: PaneEventKind.agentStatusChanged.kind,
            data: .object([
                "pane_id": .string(paneID),
                "agent_status": .string(status.rawValue),
                "state_labels": .object([:]),
            ]))
    }
}
