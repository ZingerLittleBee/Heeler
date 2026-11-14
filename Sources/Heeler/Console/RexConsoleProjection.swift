import Foundation

/// A Rex Host's share of the Console (ADR 0047), before this build connects to
/// Rex. It never dials, lists nothing, and reads as a Host Heeler cannot
/// connect to yet, which no retry changes. Every action fails with that same
/// reason, and nothing reaches herdr, herdr-core or tmux.
///
/// The connection, the inventory and Rex's own answers to what a detail keeps
/// to replace this as they are built.
@MainActor
final class RexConsoleProjection: ConsoleHostProjection {
    let host: Host

    /// Why the Host has no connection, for every surface that asks.
    private nonisolated static let reason = TransportError.rexNotConnectableYet

    let status: EventsSessionStatus? = .failed(RexConsoleProjection.reason)
    let standingFailure: TransportError? = RexConsoleProjection.reason
    let latency: Duration? = nil
    let routeID: UUID? = nil
    let syncError: String? = nil
    let leakedEnvironmentNames: Set<String> = []
    let transportGeneration: UInt64 = 0
    /// Nothing is on its way: the list is empty because nothing was asked.
    let isAwaitingSnapshot = false
    let workspaces: [ConsoleWorkspace] = []
    let removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] = [:]
    let terminalsByPane: [String: ConsoleTerminal] = [:]
    let agentsByPane: [String: ConsoleAgent] = [:]
    let lastKnownAgentsByPane: [String: ConsoleAgent] = [:]
    let sidebarRevision: UInt64 = 0
    let terminalLabelKeys: [String] = []

    /// No inventory, so no detail keeps to one. Every action says why instead.
    let keepsDetailsToInventory = false
    var leftInventoryMessage: String { Self.reason.presentation.message }
    let leftInventoryError = RexConsoleProjection.reason

    init(host: Host) {
        self.host = host
    }

    // MARK: Lifecycle

    func start(isActive _: Bool) {}
    func resume() async {}
    func revalidate() async {}
    func suspend() async {}
    func retry() async {}
    func cancelConnecting() async {}
    func end() {}

    // MARK: Inventory

    func refreshTerminalInventory() async {}
    func refreshSidebarMetadata() async {}
    func setShownAgents(_: Set<String>) {}

    // MARK: Actions

    func availableAgentKinds() async throws -> [SupportedAgentKind] { throw Self.reason }
    func startAgent(_: AgentLaunchRequest) async throws -> Agent { throw Self.reason }
    func startAgentInNewWorktree(_: AgentLaunchRequest, worktree _: WorktreeSpec) async throws -> Agent {
        throw Self.reason
    }
    func startAgentInNewWorkspace(_: AgentLaunchRequest, workspace _: NewWorkspaceSpec) async throws -> Agent {
        throw Self.reason
    }
    func createShellTerminal(_: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        throw Self.reason
    }
    func createShellWorkspace(_: NewWorkspaceSpec, tabLabel _: String?) async throws -> ShellTerminalIdentity {
        throw Self.reason
    }
    func paneExists(_: String) async throws -> Bool { throw Self.reason }
    func closePane(_: String) async throws { throw Self.reason }
    func closeTab(_: String) async throws { throw Self.reason }
    func listWorktrees(forWorkspaceID _: String) async throws -> WorktreeListResponse { throw Self.reason }
    func removeWorktree(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt { throw Self.reason }
    func worktreeRemovalRisk(_: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk? { throw Self.reason }
    func focusAgent(_: String) async throws { throw Self.reason }
    func renameAgent(_: String, name _: String?) async throws { throw Self.reason }
    func renameWorkspace(_: String, label _: String) async throws { throw Self.reason }

    // MARK: One Agent

    func agentInfo(paneID _: String) async throws -> Agent { throw Self.reason }
    func processInfo(paneID _: String) async throws -> PaneProcessInfo { throw Self.reason }
    func promptAgent(_: AgentPromptParams) async throws -> Agent { throw Self.reason }
    func readAgentScreen(_: String) async throws -> ANSIScreen { throw Self.reason }
    func sendAgentKeys(_: [String], to _: String) async throws { throw Self.reason }
    func pasteIntoAgent(_: String, paneID _: String) async throws { throw Self.reason }

    // MARK: The live connection

    func terminalRunner() -> TerminalSessionRunner { { _, _ in throw Self.reason } }
    func imageStager(beside _: String, keepingTo _: TerminalCorePin) -> ImageStager {
        { _, _ in throw Self.reason }
    }
    func fileStager(beside _: String, keepingTo _: TerminalCorePin) -> FileStager {
        { _, _ in throw Self.reason }
    }
    func sessionFileReader() -> SessionFileReader { { _ in throw Self.reason } }
    func modelContextWindowResolver() -> ModelContextWindowResolver { { _ in throw Self.reason } }
    func chatHostFiles() -> ChatHostFiles {
        ChatHostFiles(
            status: { _ in throw Self.reason },
            list: { _ in throw Self.reason },
            read: { _ in throw Self.reason },
            home: { throw Self.reason })
    }
    func remoteHomeDirectory() async throws -> String { throw Self.reason }
    func listRemoteDirectories(at _: String) async throws -> RemoteDirectoryListing { throw Self.reason }

    func withHostServices<Value: Sendable>(
        _: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value {
        throw Self.reason
    }

    /// A Rex Host has no plugin, Notifications or Usage files, and its plugin
    /// surfaces say it is the Server Kind's doing.
    func withNotificationTransport<Value: Sendable>(
        _: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        throw HeelerPluginUnavailableError.rex
    }
}
