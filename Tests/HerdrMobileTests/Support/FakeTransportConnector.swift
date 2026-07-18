import Foundation

@testable import HerdrMobile

/// Scripted `Transport` for store tests: protocol-level, no SSH.
final actor FakeTransport: Transport {
    private let pingResult: Result<ServerInfo, TransportError>
    private(set) var isClosed = false

    init(pingResult: Result<ServerInfo, TransportError>) {
        self.pingResult = pingResult
    }

    func ping() async throws -> ServerInfo {
        try pingResult.get()
    }

    func listAgents() async throws -> [Agent] {
        []
    }

    func sessionSnapshot() async throws -> SessionSnapshot {
        SessionSnapshot(
            agents: [], layouts: [], panes: [], protocolVersion: 16, tabs: [],
            version: "0.7.4-fake", workspaces: [])
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        throw TransportError.channelFailed(detail: "FakeTransport does not script pane reads")
    }

    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        throw TransportError.channelFailed(detail: "FakeTransport does not script events")
    }

    func observeTerminal(_ request: TerminalObserveRequest) async throws -> TerminalFrameStream {
        throw TransportError.channelFailed(detail: "FakeTransport does not script observe")
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
    private(set) var capturedSettings: [SSHTransportSettings] = []
    private(set) var transports: [FakeTransport] = []

    init(outcome: Outcome, presentedKeyBlob: Data? = nil) {
        self.outcome = outcome
        self.presentedKeyBlob = presentedKeyBlob
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
            let transport = FakeTransport(pingResult: pingResult)
            transports.append(transport)
            return transport
        }
    }

    /// Mirrors `TOFUHostKeyValidator.evaluate` at the policy level.
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
