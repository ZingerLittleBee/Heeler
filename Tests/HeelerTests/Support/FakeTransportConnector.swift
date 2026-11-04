import Foundation

@testable import Heeler

/// Scripted `Transport` for store tests: protocol-level, no SSH.
final actor FakeTransport: Transport {
    private let pingResult: Result<ServerInfo, TransportError>
    private let sessions: [HerdrSession]
    /// nil leaves the plugin read unscripted, like a transport without
    /// herdr's plugin registry.
    private var plugin: Result<HeelerPluginInstallation?, TransportError>?
    private let pluginSteps: FakePluginSteps
    private(set) var isClosed = false
    /// Whether the connection was still open at each plugin read.
    private(set) var pluginReadsWhileOpen: [Bool] = []
    /// The plugin steps run, in order.
    private(set) var ranPluginSteps: [HeelerPluginStep] = []
    private(set) var pluginBranchReads = 0

    init(
        pingResult: Result<ServerInfo, TransportError>, sessions: [HerdrSession] = [],
        plugin: Result<HeelerPluginInstallation?, TransportError>? = nil,
        pluginSteps: FakePluginSteps = FakePluginSteps()
    ) {
        self.pingResult = pingResult
        self.sessions = sessions
        self.plugin = plugin
        self.pluginSteps = pluginSteps
    }

    func runHeelerPluginStep(_ step: HeelerPluginStep) async throws {
        ranPluginSteps.append(step)
        if let after = pluginSteps.pluginAfterStep[ranPluginSteps.count - 1] {
            plugin = after
        }
        if let failure = pluginSteps.failures[ranPluginSteps.count - 1] {
            throw failure
        }
    }

    func readPluginBranchVersion() async throws -> PluginVersion {
        pluginBranchReads += 1
        return try pluginSteps.branchVersion.get()
    }

    func readHeelerPlugin() async throws -> HeelerPluginInstallation? {
        pluginReadsWhileOpen.append(!isClosed)
        guard let plugin else {
            throw TransportError.channelFailed(detail: "FakeTransport does not script plugins")
        }
        return try plugin.get()
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

    /// Ranged Host-file reads (#325): scripted answers, in order.
    private var scriptedFileSlices: [RemoteFileSlice] = []
    private(set) var fileRanges: [RemoteFileRange] = []

    func setFileSlices(_ slices: [RemoteFileSlice]) {
        scriptedFileSlices = slices
    }

    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        fileRanges.append(range)
        guard !scriptedFileSlices.isEmpty else {
            throw TransportError.channelFailed(
                detail: "FakeTransport does not script file slices")
        }
        return scriptedFileSlices.removeFirst()
    }

    /// Model window lookups (#325): scripted per selector; unscripted ones
    /// are unknown, as with a model omp does not list.
    private var scriptedContextWindows: [String: Int] = [:]
    private(set) var contextWindowSelectors: [String] = []

    func setContextWindows(_ windows: [String: Int]) {
        scriptedContextWindows = windows
    }

    func modelContextWindow(selector: String) async throws -> Int? {
        contextWindowSelectors.append(selector)
        return scriptedContextWindows[selector]
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

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script Agent send-keys")
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

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        throw TransportError.channelFailed(detail: "FakeTransport does not script agent starts")
    }

    func closePane(_ params: PaneTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script closes")
    }

    func closeTab(_ params: TabTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script closes")
    }

    func focusAgent(_ target: AgentTarget) async throws {
        throw TransportError.channelFailed(detail: "FakeTransport does not script focus")
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
        /// The connect ignores cancellation for this long (an Overlay
        /// Network still coming up), then times out.
        case hangs(Duration)
    }

    private let outcome: Outcome
    /// The host key the fake "server" presents; nil skips host key
    /// evaluation entirely.
    private let presentedKeyBlob: Data?
    /// The key the first route's Jump Host presents, evaluated before the
    /// Host's under the Jump Host's endpoint; nil skips it.
    private let presentedJumpKeyBlob: Data?
    private let sessions: [HerdrSession]
    private let plugin: Result<HeelerPluginInstallation?, TransportError>?
    private let pluginSteps: FakePluginSteps
    private(set) var capturedSettings: [SSHTransportSettings] = []
    private(set) var transports: [FakeTransport] = []

    init(
        outcome: Outcome, presentedKeyBlob: Data? = nil, presentedJumpKeyBlob: Data? = nil,
        sessions: [HerdrSession] = [],
        plugin: Result<HeelerPluginInstallation?, TransportError>? = nil,
        pluginSteps: FakePluginSteps = FakePluginSteps()
    ) {
        self.outcome = outcome
        self.presentedKeyBlob = presentedKeyBlob
        self.presentedJumpKeyBlob = presentedJumpKeyBlob
        self.sessions = sessions
        self.plugin = plugin
        self.pluginSteps = pluginSteps
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        capturedSettings.append(settings)
        if let presentedJumpKeyBlob, let jump = settings.routes.first?.jump {
            let presented = HostKeyFingerprint(publicKeyBlob: presentedJumpKeyBlob)
            if let known = await settings.hostKeyPolicy.knownHosts.fingerprint(
                host: jump.host, port: jump.port), known != presented
            {
                throw TransportError.jumpHostFailed(
                    .hostKeyMismatch(known: known, presented: presented))
            }
        }
        if let presentedKeyBlob {
            try await evaluateHostKey(
                HostKeyFingerprint(publicKeyBlob: presentedKeyBlob), settings: settings)
        }
        switch outcome {
        case .connectFails(let error):
            throw error
        case .hangs(let duration):
            await Task.detached { try? await Task.sleep(for: duration) }.value
            throw TransportError.timedOut
        case .connects(let pingResult):
            let transport = FakeTransport(
                pingResult: pingResult, sessions: sessions, plugin: plugin,
                pluginSteps: pluginSteps)
            transports.append(transport)
            return transport
        }
    }

    /// Mirrors `HeelerSSHHostKeyVerifier.verify` at the policy level,
    /// including a catalog Host adopting its endpoint's pre-Routes trust.
    private func evaluateHostKey(
        _ fingerprint: HostKeyFingerprint, settings: SSHTransportSettings
    ) async throws {
        let policy = settings.hostKeyPolicy
        let key = settings.hostKeyTrust.storageKey(host: settings.host, port: settings.port)
        if settings.hostKeyTrust != .endpoint,
           await policy.knownHosts.fingerprints(host: key.host, port: key.port).isEmpty
        {
            for adopted in await policy.knownHosts.fingerprints(
                host: settings.host, port: settings.port)
            {
                await policy.knownHosts.setFingerprint(adopted, host: key.host, port: key.port)
            }
        }
        if let known = await policy.knownHosts.fingerprint(host: key.host, port: key.port) {
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
        await policy.knownHosts.setFingerprint(fingerprint, host: key.host, port: key.port)
    }
}

/// How a `FakeTransport` answers plugin steps, by the step's index on
/// that connection: the plugin a step leaves on the Host, and the error it
/// throws after. `branchVersion` answers the plugin branch read.
struct FakePluginSteps: Sendable {
    var pluginAfterStep: [Int: Result<HeelerPluginInstallation?, TransportError>] = [:]
    var failures: [Int: any Error] = [:]
    var branchVersion: Result<PluginVersion, any Error> = .success(HeelerPluginCompatibility.bundled)
}

extension KnownHostsStore {
    /// The fingerprint trusted for `host` itself, whichever route reached it.
    func fingerprint(trustedFor host: Host) async -> HostKeyFingerprint? {
        let key = HostKeyTrust.hostKey(host.id)
        return await fingerprint(host: key.host, port: key.port)
    }
}
