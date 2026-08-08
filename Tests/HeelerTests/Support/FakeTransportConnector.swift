import Foundation

@testable import Heeler

/// Scripted `Transport` for store tests: protocol-level, no SSH.
final actor FakeTransport: Transport {
    private let pingResult: Result<ServerInfo, TransportError>
    private let sessions: [HerdrSession]
    private(set) var isClosed = false

    init(pingResult: Result<ServerInfo, TransportError>, sessions: [HerdrSession] = []) {
        self.pingResult = pingResult
        self.sessions = sessions
    }

    func ping() async throws -> ServerInfo {
        try pingResult.get()
    }

    func listSessions() async throws -> [HerdrSession] {
        sessions
    }

    func listAgents() async throws -> [Agent] {
        []
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        SessionSnapshot(
            agents: [], layouts: [], panes: [], protocolVersion: 17, tabs: [],
            version: "0.7.5-fake", workspaces: [])
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(detail: "FakeTransport does not script pane reads")
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent reads")
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent prompts")
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        throw TransportError.channelFailed(detail: "FakeTransport does not script events")
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        throw TransportError.channelFailed(detail: "FakeTransport does not script attach")
    }

    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func closePane(_ params: PaneTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script closes")
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script renames")
    }

    func renameWorkspace(_ params: WorkspaceRenameParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script renames")
    }

    var isConnected: Bool {
        !isClosed
    }

    func close() async throws {
        isClosed = true
    }
}

/// Scripted `TransportConnector` that replays the TOFU dance the real
/// validator performs — evaluate the presented key against the known-hosts
/// store, prompt via `confirmFirstConnect` when unknown, persist on trust —
/// so onboarding tests exercise the fingerprint flow without sshd.
final actor FakeTransportConnector: TransportConnector {
    enum Outcome: Sendable {
        case connectFails(TransportError)
        case connects(pingResult: Result<ServerInfo, TransportError>)
    }

    private let outcome: Outcome
    /// The host key the fake "server" presents; nil skips host key
    /// evaluation entirely.
    private let presentedKeyBlob: Data?
    private let sessions: [HerdrSession]
    private(set) var capturedSettings: [SSHTransportSettings] = []
    private(set) var transports: [FakeTransport] = []

    init(
        outcome: Outcome, presentedKeyBlob: Data? = nil,
        sessions: [HerdrSession] = []
    ) {
        self.outcome = outcome
        self.presentedKeyBlob = presentedKeyBlob
        self.sessions = sessions
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        capturedSettings.append(settings)
        if let presentedKeyBlob {
            try await evaluateHostKey(
                HostKeyFingerprint(publicKeyBlob: presentedKeyBlob), settings: settings)
        }
        switch outcome {
        case .connectFails(let error):
            throw error
        case .connects(let pingResult):
            let transport = FakeTransport(pingResult: pingResult, sessions: sessions)
            transports.append(transport)
            return transport
        }
    }

    /// Mirrors `HeelerSSHHostKeyVerifier.verify` at the policy level.
    private func evaluateHostKey(
        _ fingerprint: HostKeyFingerprint, settings: SSHTransportSettings
    ) async throws {
        let policy = settings.hostKeyPolicy
        if let known = await policy.knownHosts.fingerprint(
            host: settings.host, port: settings.port)
        {
            guard known == fingerprint else {
                throw TransportError.hostKeyMismatch(known: known, presented: fingerprint)
            }
            return
        }
        let candidate = HostKeyCandidate(
            host: settings.host, port: settings.port, fingerprint: fingerprint)
        guard await policy.confirmFirstConnect(candidate) else {
            throw TransportError.hostKeyRejected(presented: fingerprint)
        }
        await policy.knownHosts.setFingerprint(
            fingerprint, host: settings.host, port: settings.port)
    }
}
