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
    var transportGeneration: UInt64 { get }
    var isAwaitingSnapshot: Bool { get }
    var workspaces: [ConsoleWorkspace] { get }
    var removedWorktreesByAgent: [ConsoleAgent.ID: WorktreeRemovalReceipt] { get }
    var terminalsByPane: [String: ConsoleTerminal] { get }
    var agentsByPane: [String: ConsoleAgent] { get }
    var sidebarRevision: UInt64 { get }
    var terminalLabelKeys: [String] { get }

    // MARK: Lifecycle

    func start(isActive: Bool)
    func resume() async
    func revalidate() async
    func suspend() async
    func retry() async
    func cancelConnecting() async
    func end()

    // MARK: Inventory

    func refreshTerminalInventory() async
    func refreshSidebarMetadata() async

    // MARK: Host-scoped actions

    func availableAgentKinds() async throws -> [SupportedAgentKind]
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
    func focusAgent(_ paneID: String) async throws
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
    func imageStager() -> ImageStager
    func fileStager() -> FileStager
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
