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
    private(set) var snapshotFetchCount = 0
    /// Every observe request received, in order; the Observe store's
    /// restart-on-resize/gap behavior asserts on this.
    private(set) var observeRequests: [TerminalObserveRequest] = []

    private var serverInfo: ServerInfo
    private var snapshot: SessionSnapshot
    private var paneTexts: [String: String] = [:]
    private var paneReadFailure: TransportError?
    private var nextStreamID: UInt64 = 0
    private var liveStreamID: UInt64?
    private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
    private var nextFrameStreamID: UInt64 = 0
    private var liveFrameStreamID: UInt64?
    private var frameContinuation: AsyncThrowingStream<TerminalFrame, any Error>.Continuation?

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

    /// Scripts the text `readPane` returns for `paneID`.
    func setPaneText(_ text: String, paneID: String) {
        paneTexts[paneID] = text
    }

    /// Makes every subsequent `readPane` throw `failure`.
    func setPaneReadFailure(_ failure: TransportError?) {
        paneReadFailure = failure
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

    // MARK: Transport

    func ping() async throws -> ServerInfo {
        serverInfo
    }

    func listAgents() async throws -> [Agent] {
        snapshot.agents.map(Agent.init)
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        snapshotFetchCount += 1
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
        guard liveFrameStreamID == nil else {
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
