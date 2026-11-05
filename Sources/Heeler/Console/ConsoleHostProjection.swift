import Foundation

/// One Host's share of the Console, whichever Server Kind it runs. Each
/// conforming type owns its connection and convergence and fills the Console's
/// models; `ConsoleStore` aggregates what it publishes and forwards Host-scoped
/// actions to it (ADR 0032).
@MainActor
protocol ConsoleHostProjection: AnyObject, Sendable {
    var host: Host { get }

    // MARK: What the Console's rebuild reads

    var status: EventsSessionStatus? { get }
    var standingFailure: TransportError? { get }
    var latency: Duration? { get }
    var routeID: UUID? { get }
    var syncError: String? { get }
    /// What the connected core inherited, by name only (ADR 0034).
    var leakedEnvironmentNames: Set<String> { get }
    var transportGeneration: UInt64 { get }
    var isAwaitingSnapshot: Bool { get }
    /// Whether input must wait: unlike `isAwaitingSnapshot`, this also covers a
    /// connection replaced without any non-connected status.
    var isAwaitingFreshSnapshot: Bool { get }
    /// A slow connection is being probed, so input pauses.
    var isCheckingConnection: Bool { get }
    var workspaces: [ConsoleWorkspace] { get }
    var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] { get }
    var terminalsByPane: [String: ConsoleTerminal] { get }
    var agentsByPane: [String: ConsoleAgent] { get }
    /// Agents off the list whose program was lost or ended, for a detail open
    /// on one to say so (ADR 0032).
    var departedAgentsByPane: [String: ConsoleAgent] { get }
    /// Display-only metadata for a selected detail during recovery. Never used
    /// as live inventory, and replaced even by an empty fresh snapshot.
    var lastKnownAgentsByPane: [String: ConsoleAgent] { get }
    var sidebarRevision: UInt64 { get }
    var terminalLabelKeys: [String] { get }

    // MARK: Lifecycle

    func start(isActive: Bool)
    func resume() async
    func revalidate() async
    func suspend() async
    func pauseHealthChecks() async
    func retry() async
    func cancelConnecting() async
    func end()

    // MARK: Inventory

    func refreshTerminalInventory() async
    func refreshSidebarMetadata() async

    // MARK: Host-scoped actions

    func availableAgentKinds() async throws -> [SupportedAgentKind]
    /// The Host's Templates, which only a herdr-core Host has.
    func availableTemplates() async throws -> [AgentTemplate]
    @discardableResult func startTemplate(_ request: TemplateLaunchRequest) async throws -> Agent
    /// How the program at `paneID` ended, once it has for good and the Host still
    /// knows it. Only a herdr-core Host keeps that.
    func programExit(ofPane paneID: String) -> ProgramExit?
    /// The names the Host's live Terminals hold, beyond those its Agents show.
    /// A herdr-core Host refuses to give any of them out again.
    var heldTerminalNames: Set<String> { get }
    @discardableResult func startAgent(_ request: AgentLaunchRequest) async throws -> Agent
    @discardableResult func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent
    @discardableResult func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent
    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity
    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity
    func paneExists(_ paneID: String) async throws -> Bool
    func closePane(_ paneID: String) async throws
    func closeTab(_ tabID: String) async throws
    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse
    func removeWorktree(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt
    /// What removing this Worktree would lose, to warn of. Nil where the Host
    /// refuses such a removal instead.
    func worktreeRemovalRisk(_ request: WorktreeRemovalRequest) async throws -> WorktreeRemovalRisk?
    /// Where a launch asked into this directory of this Workspace would start.
    func launchDirectory(ofWorkspace workspaceID: String, asked: String) -> String
    func focusAgent(_ paneID: String) async throws
    /// The Agents some Agent detail on this device shows now.
    func setShownAgents(_ paneIDs: Set<String>)
    func renameAgent(_ paneID: String, name: String?) async throws
    func renameWorkspace(_ workspaceID: String, label: String) async throws

    // MARK: One Agent

    func agentInfo(paneID: String) async throws -> Agent
    func processInfo(paneID: String) async throws -> PaneProcessInfo
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent
    func readAgentScreen(_ paneID: String) async throws -> ANSIScreen
    func sendAgentKeys(_ keys: [String], to paneID: String) async throws
    func pasteIntoAgent(_ text: String, paneID: String) async throws

    // MARK: The live connection

    func terminalRunner() -> TerminalSessionRunner
    /// `paneID` and `corePin` are for a Host whose files go through the Terminal.
    func imageStager(beside paneID: String, keepingTo corePin: TerminalCorePin) -> ImageStager
    func fileStager(beside paneID: String, keepingTo corePin: TerminalCorePin) -> FileStager
    func sessionFileReader() -> SessionFileReader
    func modelContextWindowResolver() -> ModelContextWindowResolver
    func chatHostFiles() -> ChatHostFiles
    func remoteHomeDirectory() async throws -> String
    func listRemoteDirectories(at path: String) async throws -> RemoteDirectoryListing

    /// Borrows the Host's exec and SFTP services, whichever Server Kind runs.
    func withHostServices<Value: Sendable>(
        _ operation: @escaping @Sendable (any HostServices) async throws -> Value
    ) async throws -> Value

    /// Borrows the connection for the plugin's Notification, Usage and sidebar
    /// files, which only a Herdr TUI Host has.
    func withNotificationTransport<Value: Sendable>(
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value
}

extension ConsoleHostProjection {
    var departedAgentsByPane: [String: ConsoleAgent] { [:] }

    /// Until a snapshot proves what the Host runs, its Console rows may be saved
    /// Chat entries, on a Host that offers Chat at all.
    var showsSavedChats: Bool {
        host.capabilities.chat && (status != .connected || isAwaitingSnapshot)
    }

    /// A Host without a health probe has a link that goes with its inventory.
    var isAwaitingFreshSnapshot: Bool { isAwaitingSnapshot }

    var isCheckingConnection: Bool { false }

    func pauseHealthChecks() async {}

    func availableTemplates() async throws -> [AgentTemplate] { [] }

    func launchDirectory(ofWorkspace workspaceID: String, asked: String) -> String { asked }

    func startTemplate(_ request: TemplateLaunchRequest) async throws -> Agent {
        throw TransportError.hostFeatureUnavailable(feature: "Templates")
    }

    func programExit(ofPane paneID: String) -> ProgramExit? { nil }

    var heldTerminalNames: Set<String> { [] }
}
