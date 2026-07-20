import Foundation

@testable import HerdrMobile

/// Scripted `Transport` for Console and EventsSession protocol-level tests:
/// the test scripts the snapshot and pane text, and drives the event stream
/// by hand. No SSH anywhere.
final actor ScriptedTransport: Transport {
    private(set) var isClosed = false
    /// Every subscription set received, in order; the Console's
    /// resubscribe-on-membership-change behavior asserts on this.
    private(set) var capturedSubscriptions: [[EventSubscription]] = []
    private(set) var paneReadParams: [PaneReadParams] = []
    /// Every atomic text-and-key batch sent through `pane.send_input`.
    private(set) var sentInputs: [PaneSendInputParams] = []
    /// Every key batch sent through `pane.send_keys`, in order; the input
    /// store's quick-key behavior asserts on this.
    private(set) var sentKeys: [PaneSendKeysParams] = []
    /// Every `agent.start` received, in order; the new-agent flow (#12)
    /// asserts on the params it forwarded.
    private(set) var agentStarts: [AgentStartParams] = []
    /// Every `pane.close` received, in order; the close-pane flow (#13)
    /// asserts on the pane it targeted (and that the cancel path never
    /// appends here).
    private(set) var closedPanes: [PaneTarget] = []
    private var closeFailure: TransportError?
    private var startFailure: TransportError?
    private var startedAgent: AgentInfo?
    private var sendFailure: TransportError?
    private(set) var snapshotFetchCount = 0
    /// Every observe request received, in order; the Observe store's
    /// restart-on-resize/gap behavior asserts on this.
    private(set) var observeRequests: [TerminalObserveRequest] = []
    /// Every attach request received, in order; the Attach store's
    /// open-once behavior asserts on this.
    private(set) var attachRequests: [TerminalAttachRequest] = []
    /// Everything sent down the live attach session, in order — keystrokes
    /// and resizes interleaved exactly as the store issued them.
    private(set) var attachInputs: [TerminalAttachInput] = []

    private var serverInfo: ServerInfo
    private var snapshot: SessionSnapshot
    private var snapshotFailure: TransportError?
    private var paneTexts: [String: String] = [:]
    private var paneReadFailure: TransportError?
    private var nextStreamID: UInt64 = 0
    private var liveStreamID: UInt64?
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var nextFrameStreamID: UInt64 = 0
    private var liveFrameStreamID: UInt64?
    private var frameContinuation: AsyncThrowingStream<TerminalFrame, any Error>.Continuation?
    private var nextAttachID: UInt64 = 0
    private var liveAttachID: UInt64?
    private var attachContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var attachInputTask: Task<Void, Never>?

    init(
        snapshot: SessionSnapshot = .fixture(),
        serverInfo: ServerInfo = ServerInfo(version: "0.7.4-fake", protocolVersion: 16)
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

    /// Scripts the text `readPane` returns for `paneID`.
    func setPaneText(_ text: String, paneID: String) {
        paneTexts[paneID] = text
    }

    /// Makes every subsequent `readPane` throw `failure`.
    func setPaneReadFailure(_ failure: TransportError?) {
        paneReadFailure = failure
    }

    /// Makes every subsequent `sendInput`/`sendKeys` throw `failure`.
    func setSendFailure(_ failure: TransportError?) {
        sendFailure = failure
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

    /// Makes every subsequent `closePane` throw `failure`.
    func setCloseFailure(_ failure: TransportError?) {
        closeFailure = failure
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

    /// Pushes one frame onto the live observe stream; false if none is live.
    @discardableResult
    func emitFrame(_ frame: TerminalFrame) -> Bool {
        guard let frameContinuation else { return false }
        frameContinuation.yield(frame)
        return true
    }

    /// Kills the live observe stream with `failure`, as a remotely dropped
    /// terminal channel would.
    func failFrameStream(_ failure: TransportError) {
        frameContinuation?.finish(throwing: failure)
        frameContinuation = nil
        liveFrameStreamID = nil
    }

    /// Whether an observe stream is currently live.
    var hasLiveFrameStream: Bool {
        frameContinuation != nil
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

    // MARK: Transport

    func ping() async throws -> ServerInfo {
        serverInfo
    }

    func listAgents() async throws -> [Agent] {
        snapshot.agents.map(Agent.init)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        snapshotFetchCount += 1
        if let snapshotFailure { throw snapshotFailure }
        return snapshot
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        paneReadParams.append(params)
        if let paneReadFailure {
            throw paneReadFailure
        }
        return PaneReadResult(
            format: .text, paneID: params.paneID, revision: 0,
            source: params.source, tabID: "t", text: paneTexts[params.paneID] ?? "",
            truncated: false, workspaceID: "w")
    }

    func startAgent(_ params: AgentStartParams) async throws -> Agent {
        agentStarts.append(params)
        if let startFailure { throw startFailure }
        if let startedAgent { return Agent(startedAgent) }
        // Synthesize a freshly-Working agent so the caller and the follow-up
        // snapshot see the same pane the real server would report.
        return Agent(
            .fixture(
                paneID: "\(params.workspaceID ?? "w1"):pnew", status: .working,
                workspaceID: params.workspaceID ?? "w1", kind: params.name,
                title: params.name))
    }

    func sendInput(_ params: PaneSendInputParams) async throws {
        if let sendFailure { throw sendFailure }
        sentInputs.append(params)
    }

    func sendKeys(_ params: PaneSendKeysParams) async throws {
        if let sendFailure { throw sendFailure }
        sentKeys.append(params)
    }

    func closePane(_ params: PaneTarget) async throws {
        if let closeFailure { throw closeFailure }
        closedPanes.append(params)
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        guard liveStreamID == nil else {
            throw TransportError.eventsChannelAlreadyOpen
        }
        capturedSubscriptions.append(subscriptions)
        nextStreamID += 1
        let streamID = nextStreamID
        let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
        liveStreamID = streamID
        eventContinuation = continuation
        return HerdrEventStream(events: events) {
            await self.endStream(id: streamID)
        }
    }

    func observeTerminal(_ request: TerminalObserveRequest) async throws -> TerminalFrameStream {
        guard liveFrameStreamID == nil, liveAttachID == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        observeRequests.append(request)
        nextFrameStreamID += 1
        let streamID = nextFrameStreamID
        let (frames, continuation) = AsyncThrowingStream<TerminalFrame, any Error>.makeStream()
        liveFrameStreamID = streamID
        frameContinuation = continuation
        return TerminalFrameStream(frames: frames) {
            await self.endFrameStream(id: streamID)
        }
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        // Observe and Attach share the one terminal channel, like the real
        // transport.
        guard liveFrameStreamID == nil, liveAttachID == nil else {
            throw TransportError.terminalChannelAlreadyOpen
        }
        attachRequests.append(request)
        nextAttachID += 1
        let attachID = nextAttachID
        let (output, outputContinuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let (input, inputContinuation) = AsyncStream<TerminalAttachInput>.makeStream()
        liveAttachID = attachID
        attachContinuation = outputContinuation
        attachInputTask = Task {
            for await item in input {
                self.recordAttachInput(item)
            }
        }
        return TerminalAttachSession(output: output, input: inputContinuation) {
            await self.endAttach(id: attachID)
        }
    }

    var isConnected: Bool {
        !isClosed
    }

    func close() async throws {
        isClosed = true
        eventContinuation?.finish()
        eventContinuation = nil
        liveStreamID = nil
        frameContinuation?.finish()
        frameContinuation = nil
        liveFrameStreamID = nil
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

    private func endFrameStream(id: UInt64) {
        guard liveFrameStreamID == id else { return }
        frameContinuation?.finish()
        frameContinuation = nil
        liveFrameStreamID = nil
    }

    private func recordAttachInput(_ input: TerminalAttachInput) {
        attachInputs.append(input)
    }

    /// Explicit `end()` on the session: finishes it gracefully, exactly like
    /// the real channel closed by its consumer. Drains the input recording
    /// first — `end()` finishes the input stream before calling this — so
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

// MARK: Fixtures

extension SessionSnapshot {
    static func fixture(
        agents: [AgentInfo] = [], workspaces: [WorkspaceInfo] = []
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: [], protocolVersion: 16, tabs: [],
            version: "0.7.4-fake", workspaces: workspaces)
    }
}

extension AgentInfo {
    static func fixture(
        paneID: String,
        status: AgentStatus = .idle,
        workspaceID: String = "w1",
        kind: String = "claude",
        title: String = "Task",
        revision: Int = 1
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: paneID, revision: revision,
            tabID: "\(workspaceID):t1", terminalID: "term_\(paneID)",
            workspaceID: workspaceID, agent: kind, cwd: "/work/\(workspaceID)",
            terminalTitleStripped: title)
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
