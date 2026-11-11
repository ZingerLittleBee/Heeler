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

    @Test func anOfferedStopRunsInsteadOfEsc() async {
        let rig = makeRig(offersSend: false, kind: "grok", stop: .interrupt)
        defer { rig.store.setHosts([]) }
        var pressedEsc = false
        let interrupt = rig.store.terminalInterrupt(for: rig.agent) {
            pressedEsc = true
            return .sent
        }

        let outcome = await interrupt?.perform()

        #expect(interrupt?.accessibilityHint == "Stops through the projection")
        #expect(interrupt?.wait == .coreInterrupt)
        #expect(outcome == .sent)
        #expect(rig.projection.stopped)
        #expect(!pressedEsc)
    }

    @Test func aProjectionThatKeepsSendOffersNoInterrupt() {
        let rig = makeRig(offersSend: false, kind: "claude", stop: .keepSend)
        defer { rig.store.setHosts([]) }
        var pressedEsc = false
        let interrupt = rig.store.terminalInterrupt(for: rig.agent) {
            pressedEsc = true
            return .sent
        }

        #expect(interrupt == nil)
        #expect(!pressedEsc)
    }

    @Test func aProjectionWithoutStopPressesEsc() async {
        let rig = makeRig(offersSend: false, kind: "claude")
        defer { rig.store.setHosts([]) }
        var pressedEsc = false
        let interrupt = rig.store.terminalInterrupt(for: rig.agent) {
            pressedEsc = true
            return .sent
        }

        let outcome = await interrupt?.perform()

        #expect(interrupt?.accessibilityHint == AgentComposerInterrupt.escapeHint)
        #expect(interrupt?.wait == .escape)
        #expect(outcome == .sent)
        #expect(pressedEsc)
        #expect(!rig.projection.stopped)
    }

    @Test func aProjectionWithoutStopKeepsSendForGrok() {
        let rig = makeRig(offersSend: false, kind: "grok")
        defer { rig.store.setHosts([]) }
        var pressedEsc = false
        let interrupt = rig.store.terminalInterrupt(for: rig.agent) {
            pressedEsc = true
            return .sent
        }

        #expect(interrupt == nil)
        #expect(!pressedEsc)
    }

    @Test func checkedStopAsksForTheProjectionLive() async {
        let rig = makeRig(offersSend: false, stop: .interrupt)
        defer { rig.store.setHosts([]) }
        let interrupt = rig.store.terminalInterrupt(for: rig.agent) { .sent }
        let replacement = ScriptedInputProjection(host: rig.host, offersSend: false, stop: .interrupt)
        rig.installed.current = replacement
        var edited = rig.host
        edited.name = "renamed"
        rig.store.setHosts([edited])

        let outcome = await interrupt?.perform()

        #expect(outcome == .sent)
        #expect(rig.projection.stopped)
        #expect(!replacement.stopped)
        #expect(rig.projection.liveAtStop === replacement)
    }

    @Test func anOfferedChatTypingReplacesThePaneScreen() async throws {
        let rig = makeRig(offersSend: false, kind: "claude", offersChatTyping: true)
        defer { rig.store.setHosts([]) }
        let chat = try #require(rig.store.chatStore(for: rig.agent, program: .claude))

        let screen = try await chat.screenIO.readScreen()

        #expect(screen.rows.first?.text == "offered")
        #expect(rig.projection.screenReads == 0)
    }

    @Test func aProjectionWithoutChatTypingReadsThePane() async throws {
        let rig = makeRig(offersSend: false, kind: "claude")
        defer { rig.store.setHosts([]) }
        let chat = try #require(rig.store.chatStore(for: rig.agent, program: .claude))

        let screen = try await chat.screenIO.readScreen()

        #expect(screen.rows.first?.text == "host")
        #expect(rig.projection.screenReads == 1)
    }

    @Test func checkedSendDoesNotTurnTransportErrorsIntoStagingMessages() async throws {
        let rig = makeRig(offersSend: true)
        defer { rig.store.setHosts([]) }
        rig.projection.fileStagingError = .timedOut
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let staging = rig.store.composerSession(for: rig.agent).staging

        await staging.beginAll([.file(file)])

        #expect(
            staging.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: .file, message: "File preparation failed.", isRetryable: false)))
    }

    @Test func aProjectionMaySayTransportErrorsInStaging() async throws {
        let rig = makeRig(offersSend: false)
        defer { rig.store.setHosts([]) }
        rig.projection.stagingSaysTransportFailures = true
        rig.projection.fileStagingError = .timedOut
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("projection-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let staging = rig.store.composerSession(for: rig.agent).staging

        await staging.beginAll([.file(file)])

        #expect(
            staging.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: .file, message: TransportError.timedOut.presentation.message,
                        isRetryable: true)))
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
private func makeRig(
    offersSend: Bool, kind: String = "shell", stop: ScriptedInputProjection.Stop = .none,
    offersChatTyping: Bool = false
) -> InputRig {
    let host = Host.fixture()
    let projection = ScriptedInputProjection(
        host: host, offersSend: offersSend, stop: stop, offersChatTyping: offersChatTyping)
    let agent = ConsoleAgent(
        hostID: host.id, hostName: host.displayName,
        agent: Agent(.fixture(paneID: "w1:p1", kind: kind)),
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

/// A Host projection with no Server Kind of its own. It offers checked Send,
/// terminal Stop and Chat typing when asked, and records the plain paths.
@MainActor
private final class ScriptedInputProjection: ConsoleHostProjection {
    enum Stop {
        case none
        case keepSend
        case interrupt
    }

    var host: Host
    let offersSend: Bool
    let stop: Stop
    let offersChatTyping: Bool
    var sent: [String] = []
    var prompted: [String] = []
    var liveAtSend: (any ConsoleHostProjection)?
    var stopped = false
    var liveAtStop: (any ConsoleHostProjection)?
    var screenReads = 0
    var fileStagingError: TransportError = .cancelled
    var stagingSaysTransportFailures = false

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

    init(host: Host, offersSend: Bool, stop: Stop = .none, offersChatTyping: Bool = false) {
        self.host = host
        self.offersSend = offersSend
        self.stop = stop
        self.offersChatTyping = offersChatTyping
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

    func checkedTerminalStop(
        for _: String,
        keepingTo _: TerminalCorePin,
        live: @escaping @MainActor () -> (any ConsoleHostProjection)?
    ) -> TerminalStopOffer? {
        switch stop {
        case .none: return nil
        case .keepSend: return .keepSend
        case .interrupt:
            return .interrupt(
                AgentComposerInterrupt(
                    wait: .coreInterrupt, accessibilityHint: "Stops through the projection",
                    perform: { [weak self] in
                        guard let self else { return .failed("gone") }
                        self.stopped = true
                        self.liveAtStop = live()
                        return .sent
                    }))
        }
    }

    func checkedChatTyping(at _: String) -> (any CheckedChatTyping)? {
        guard offersChatTyping else { return nil }
        return ScriptedChatTyping(text: "offered")
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
    func readAgentScreen(_: String) async throws -> ANSIScreen {
        screenReads += 1
        return InputScreen.row("host")
    }
    func sendAgentKeys(_: [String], to _: String) async throws {}
    func pasteIntoAgent(_: String, paneID _: String) async throws {}

    func terminalRunner() -> TerminalSessionRunner { { _, _ in } }
    func imageStager(beside _: String, keepingTo _: TerminalCorePin) -> ImageStager {
        { _, _ in throw TransportError.cancelled }
    }
    func fileStager(beside _: String, keepingTo _: TerminalCorePin) -> FileStager {
        let error = fileStagingError
        return { _, _ in throw error }
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

private enum InputScreen {
    static func row(_ text: String) -> ANSIScreen {
        ANSIScreen(rows: [
            ScreenRow(
                index: 0,
                runs: [ScreenRun(text: text, style: .plain, column: 0, width: text.count)])
        ])
    }
}

@MainActor
private final class ScriptedChatTyping: CheckedChatTyping {
    let blockedScreen: BlockedScreenIO

    init(text: String) {
        let screen = InputScreen.row(text)
        blockedScreen = BlockedScreenIO(
            readScreen: { screen },
            sendKeys: { _ in },
            paste: { _ in })
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
