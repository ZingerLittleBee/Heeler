import Foundation
import Testing

@testable import Heeler

/// A projection other than herdr-core supplies Composer Send, or declines it.
/// `ConsoleStore` must take that answer instead of testing the projection's type.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConsoleProjectionInputTests {
    @Test func anOfferedCheckedSendSubmitsWithoutPrompting() async {
        let rig = makeRig(offersSend: true)
        defer { rig.store.setHosts([]) }
        let composer = rig.store.composerSession(for: rig.agent).composer
        composer.replaceDraft(with: "hello")

        let result = await composer.send()

        #expect(result == .submittedViaAttach)
        #expect(rig.projection.sent == ["hello"])
        #expect(rig.projection.prompted.isEmpty)
    }

    @Test func aProjectionThatOffersNoCheckedSendPrompts() async {
        let rig = makeRig(offersSend: false)
        defer { rig.store.setHosts([]) }
        let composer = rig.store.composerSession(for: rig.agent).composer
        composer.replaceDraft(with: "hello")

        let result = await composer.send()

        #expect(result == .deliveredViaPrompt)
        #expect(rig.projection.prompted == ["hello"])
        #expect(rig.projection.sent.isEmpty)
    }

    /// Editing a Host replaces its projection and keeps the Composer. Send must
    /// ask for the projection that is current then, not the one it opened on.
    @Test func checkedSendAsksForTheProjectionLive() async {
        let rig = makeRig(offersSend: true)
        defer { rig.store.setHosts([]) }
        let session = rig.store.composerSession(for: rig.agent)
        let replacement = ScriptedInputProjection(host: rig.host, offersSend: true)
        rig.installed.current = replacement
        var edited = rig.host
        edited.name = "renamed"
        rig.store.setHosts([edited])
        #expect(rig.store.composerSession(for: rig.agent) === session)
        session.composer.replaceDraft(with: "hello")

        let result = await session.composer.send()

        #expect(result == .submittedViaAttach)
        #expect(rig.projection.sent == ["hello"])
        #expect(replacement.sent.isEmpty)
        #expect(rig.projection.liveAtSend === replacement)
    }
}

// MARK: - Rig

@MainActor
private struct InputRig {
    let store: ConsoleStore
    let host: Host
    let agent: ConsoleAgent
    let projection: ScriptedInputProjection
    let installed: InstalledProjection
}

@MainActor
private final class InstalledProjection {
    var current: ScriptedInputProjection
    init(_ current: ScriptedInputProjection) { self.current = current }
}

@MainActor
private func makeRig(offersSend: Bool) -> InputRig {
    let host = Host.fixture()
    let projection = ScriptedInputProjection(host: host, offersSend: offersSend)
    let agent = ConsoleAgent(
        hostID: host.id, hostName: host.displayName,
        agent: Agent(.fixture(paneID: "w1:p1", kind: "shell")),
        workspaceLabel: "Proj", repositoryCheckout: nil)
    projection.agentsByPane = [agent.agent.paneID: agent]
    let installed = InstalledProjection(projection)
    let defaults = UserDefaults(suiteName: "projection-input-\(UUID().uuidString)") ?? .standard
    let store = ConsoleStore(
        pins: PinnedAgentsStore(defaults: defaults),
        makeProjection: { host in
            installed.current.host = host
            return installed.current
        })
    store.setHosts([host])
    return InputRig(
        store: store, host: host, agent: agent, projection: projection, installed: installed)
}

/// A Host projection with no Server Kind of its own. It offers checked Send
/// when asked, and records `promptAgent` for the path that declines it.
@MainActor
private final class ScriptedInputProjection: ConsoleHostProjection {
    var host: Host
    let offersSend: Bool
    var sent: [String] = []
    var prompted: [String] = []
    var liveAtSend: (any ConsoleHostProjection)?

    var status: EventsSessionStatus? = .connected
    var standingFailure: TransportError?
    var latency: Duration?
    var routeID: UUID?
    var syncError: String?
    var leakedEnvironmentNames: Set<String> = []
    var transportGeneration: UInt64 = 0
    var isAwaitingSnapshot = false
    var workspaces: [ConsoleWorkspace] = []
    var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    var terminalsByPane: [String: ConsoleTerminal] = [:]
    var agentsByPane: [String: ConsoleAgent] = [:]
    var lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    var sidebarRevision: UInt64 = 0
    var terminalLabelKeys: [String] = []

    init(host: Host, offersSend: Bool) {
        self.host = host
        self.offersSend = offersSend
    }

    func checkedComposerSend(
        for _: String,
        keepingTo _: TerminalCorePin,
        live: @escaping @MainActor () -> (any ConsoleHostProjection)?
    ) -> (any CheckedComposerSend)? {
        guard offersSend else { return nil }
        return ScriptedCheckedSend { [weak self] text in
            guard let self else { return }
            self.sent.append(text)
            self.liveAtSend = live()
        }
    }

    func start(isActive _: Bool) {}
    func resume() async {}
    func revalidate() async {}
    func suspend() async {}
    func retry() async {}
    func cancelConnecting() async {}
    func end() {}
    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}
    func setShownAgents(_: Set<String>) {}

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        prompted.append(params.text)
        return Agent(.fixture(paneID: params.target, kind: "shell"))
    }

    func availableAgentKinds() async throws -> [SupportedAgentKind] { throw TransportError.cancelled }
    func startAgent(_: AgentLaunchRequest) async throws -> Agent { throw TransportError.cancelled }
    func startAgentInNewWorktree(_: AgentLaunchRequest, worktree _: WorktreeSpec) async throws -> Agent {
        throw TransportError.cancelled
    }
    func startAgentInNewWorkspace(_: AgentLaunchRequest, workspace _: NewWorkspaceSpec) async throws -> Agent {
        throw TransportError.cancelled
    }
    func createShellTerminal(_: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        throw TransportError.cancelled
    }
    func createShellWorkspace(_: NewWorkspaceSpec, tabLabel _: String?) async throws -> ShellTerminalIdentity {
        throw TransportError.cancelled
    }
    func paneExists(_: String) async throws -> Bool { throw TransportError.cancelled }
    func closePane(_: String) async throws {}
    func closeTab(_: String) async throws {}
    func listWorktrees(forWorkspaceID _: String) async throws -> WorktreeListResponse {
        throw TransportError.cancelled
    }
    func removeWorktree(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt {
        throw TransportError.cancelled
    }
    func worktreeRemovalRisk(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? {
        throw TransportError.cancelled
    }
    func focusAgent(_: String) async throws {}
    func renameAgent(_: String, name _: String?) async throws {}
    func renameWorkspace(_: String, label _: String) async throws {}
    func agentInfo(paneID _: String) async throws -> Agent { throw TransportError.cancelled }
    func processInfo(paneID _: String) async throws -> PaneProcessInfo { throw TransportError.cancelled }
    func readAgentScreen(_: String) async throws -> ANSIScreen { throw TransportError.cancelled }
    func sendAgentKeys(_: [String], to _: String) async throws {}
    func pasteIntoAgent(_: String, paneID _: String) async throws {}

    func terminalRunner() -> TerminalSessionRunner { { _, _ in } }
    func imageStager(beside _: String, keepingTo _: TerminalCorePin) -> ImageStager {
        { _, _ in throw TransportError.cancelled }
    }
    func fileStager(beside _: String, keepingTo _: TerminalCorePin) -> FileStager {
        { _, _ in throw TransportError.cancelled }
    }
    func sessionFileReader() -> SessionFileReader { { _ in throw TransportError.cancelled } }
    func modelContextWindowResolver() -> ModelContextWindowResolver { { _ in throw TransportError.cancelled } }
    func chatHostFiles() -> ChatHostFiles {
        ChatHostFiles(
            status: { _ in throw TransportError.cancelled },
            list: { _ in throw TransportError.cancelled },
            read: { _ in throw TransportError.cancelled },
            home: { throw TransportError.cancelled })
    }
    func remoteHomeDirectory() async throws -> String { throw TransportError.cancelled }
    func listRemoteDirectories(at _: String) async throws -> RemoteDirectoryListing {
        throw TransportError.cancelled
    }
    func withHostServices<Value: Sendable>(
        _: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        throw TransportError.cancelled
    }
    func withNotificationTransport<Value: Sendable>(
        _: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw TransportError.cancelled
    }
}

@MainActor
private final class ScriptedCheckedSend: CheckedComposerSend {
    private let deliver: @MainActor (String) -> Void

    init(deliver: @escaping @MainActor (String) -> Void) {
        self.deliver = deliver
    }

    func send(
        _ text: String, route _: ComposerRoute, attach _: AgentAttachStore?
    ) async -> CheckedSendOutcome {
        deliver(text)
        return .submitted
    }
}
