import Foundation

/// The app-side abstraction that executes herdr API requests over SSH.
/// UI code talks to Transport, never to SSH primitives (ADR 0011).
protocol Transport: Sendable {
    /// Verifies the server speaks a protocol version we support and returns
    /// its identity. Must be the first herdr API call on every new connection
    /// path; Host-local session discovery may run before it.
    func ping() async throws -> ServerInfo

    /// Lists the local herdr sessions visible to this SSH account. This is a
    /// Host-level capability and does not depend on the currently selected
    /// API socket, so onboarding can recover from a stale manual selection.
    func listSessions() async throws -> [HerdrSession]

    /// Lists the Agents herdr has detected across all workspaces.
    func listAgents() async throws -> [Agent]

    /// Lists the supported Agent kinds whose canonical executables are
    /// currently available on this Host. SSH transports probe the Host's
    /// effective PATH; alternative transports without a Host process
    /// environment report no detected kinds by default.
    func availableAgentKinds() async throws -> [SupportedAgentKind]

    /// The full session tree in one call: agents plus the workspace context
    /// (labels, worktrees) that `listAgents()` lacks. The Console's snapshot
    /// source (#8) — re-fetched on every events-session `.connected`.
    func sessionSnapshot() async throws -> SessionSnapshot

    /// Reads a Pane's recent terminal output for the Console card snippet.
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult

    /// Reads an Agent's terminal output. Unlike `pane.read`, this preserves
    /// history semantics for alternate-screen Agents: history-capable sources
    /// fail honestly while the Agent is working instead of silently degrading
    /// to the visible screen.
    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult

    /// Delivers one complete local draft through `agent.prompt`. The request
    /// deliberately omits `wait`: the response acknowledges delivery into
    /// the Agent's pane, while Agent Status events report subsequent work.
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent

    /// Sends control keys to an Agent (`agent.send_keys`). Key names are
    /// herdr's own spellings, shared with `pane.send_keys` / `pane.send_input`.
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws

    /// Types text into a Pane (`pane.send_input`), bracketed as a paste when
    /// the program enabled bracketed paste. herdr passes it on unchecked, so
    /// callers send one line of safe text and never keys this way.
    func sendPaneInput(_ params: PaneSendInputParams) async throws

    /// Starts a new Agent: the new-agent flow (#12, User Story 8 — dispatch
    /// work from the road). Creates a fresh herdr tab in the chosen workspace,
    /// starts the requested agent in its root pane, and returns the Agent once
    /// the server acknowledges. The new pane also surfaces in the
    /// Console through the normal snapshot/delta machinery (a membership
    /// event triggers a re-snapshot), so callers do not thread the return
    /// value into the list themselves.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent

    /// Creates one ordinary shell tab in an existing Workspace. The concrete
    /// directory is mandatory so herdr cannot inherit an unrelated focused
    /// Pane's cwd. The returned identity is sufficient to attach the shell;
    /// no Agent is started and the Pane is not projected into the Console.
    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity

    /// Opens a new Workspace at a remote directory and returns its root
    /// pane, which `workspace.create` already starts as the user's shell, so
    /// no `tab.create` follows. `tabLabel` renames that first tab; nil keeps
    /// herdr's default.
    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity

    /// Starts a new Agent in a fresh git worktree (#97): `worktree.create`
    /// resolves the repository from the source workspace's cwd (a non-git cwd
    /// fails with `not_git_worktree`) and returns a new workspace whose root
    /// pane already runs a shell, so this variant skips `tab.create` and
    /// starts the agent in that pane directly (the `agent_pane_busy`
    /// readiness retry still applies). `request.workspaceID` is the *source*
    /// workspace; the started agent lives in the returned worktree workspace
    /// and surfaces through the normal snapshot/delta machinery.
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec
    ) async throws -> Agent

    /// Starts a new Agent in a freshly created Workspace (#230):
    /// `workspace.create` opens the remote directory as its own Workspace
    /// (no existing Workspace required) and returns a root pane already
    /// running a shell, so this variant skips `tab.create` and starts the
    /// agent in that pane directly (the `agent_pane_busy` readiness retry
    /// still applies). `request.workspaceID` is unused; the started agent
    /// lives in the returned Workspace and surfaces through the normal
    /// snapshot/delta machinery.
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent

    /// Closes a Pane (`pane.close`): the Agent detail screen's destructive
    /// close action (#13, User Story 9 — a Done agent must not be destroyed
    /// by a stray swipe, so the UI gates this behind an explicit
    /// confirmation). herdr removes the pane and its agent everywhere; the
    /// removal surfaces in the Console through the normal snapshot/delta
    /// machinery (a `pane.closed` membership event triggers a re-snapshot),
    /// so callers do not prune the list themselves. Targeted by the Pane's
    /// id; returns once the server acknowledges.
    func closePane(_ params: PaneTarget) async throws

    /// Closes a Tab (`tab.close`): the Console row's swipe-to-close action.
    /// herdr removes the tab and every pane in it; when it was the
    /// workspace's last tab, herdr also closes the workspace server-side, so
    /// no compensation call is needed. The removal surfaces in the Console
    /// through the normal snapshot/delta machinery. Targeted by the Tab's
    /// id; returns once the server acknowledges.
    func closeTab(_ params: TabTarget) async throws

    /// Lists git worktrees for the repository containing `workspaceID`.
    /// Console detail uses this only to obtain branch presentation because
    /// `session.snapshot` already carries repository and checkout identity.
    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse

    /// Removes one exact confirmed linked Worktree. `authorize` is invoked
    /// after the stream-local channel opens but before its first request byte;
    /// `onDispatched` runs only after the complete request line is written.
    /// Both receive the immutable request that crosses this Transport seam.
    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse

    /// Marks the viewed Agent seen through `agent.focus`. herdr 0.9.0 also
    /// focuses its Tab and marks every Pane in that Tab seen. Callers must
    /// refresh the entire Host rather than synthesize a selected-row status.
    func focusAgent(_ target: AgentTarget) async throws

    /// Renames an Agent (`agent.rename`): the Console management action
    /// (#98). A nil name clears the custom name back to the detected kind
    /// (verified live against herdr 0.7.5: omitting the key clears). The
    /// server enforces `^[a-z][a-z0-9_-]{0,31}$` on non-nil names and
    /// rejects violations with `invalid_agent_name`; non-agent targets fail
    /// with `agent_not_found`. The new name does NOT travel on events — the
    /// `pane.updated` this fires omits the agent name (verified live) — so
    /// consumers re-snapshot after the call instead of mutating local state
    /// or waiting on a delta.
    func renameAgent(_ params: AgentRenameParams) async throws

    /// Renames a workspace (`workspace.rename`): the Console management
    /// action (#98). The server accepts any label — empty, whitespace, and
    /// very long labels all pass (verified live against herdr 0.7.5); the
    /// only rejection is `workspace_not_found`. The new label surfaces
    /// through `workspace.renamed`, so callers do not mutate local state
    /// themselves.
    func renameWorkspace(_ params: WorkspaceRenameParams) async throws

    /// Opens this Host's dedicated long-lived events channel and subscribes.
    /// Returns once the server acknowledges the subscription; the stream then
    /// carries events in canonical naming until `end()` closes the channel
    /// explicitly. One events channel per Host: a second call while one is
    /// live throws `.eventsChannelAlreadyOpen`.
    ///
    /// Await subscription acknowledgement before requesting the initial
    /// snapshot, and consume events throughout the snapshot request. Repeat
    /// this sequence after reconnect or subscription replacement. herdr 0.9.0
    /// lifecycle subscriptions are live-only (version-tagged source review);
    /// they do not replay retained events from before request acceptance.
    /// The live-observed replay on 0.7.5 (absent on 0.7.4) is historical, not
    /// a recovery guarantee. Use snapshots for authoritative convergence.
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream

    /// Opens an interactive PTY Attach. Each target permits one live channel;
    /// a duplicate target throws `.terminalChannelAlreadyOpen`. Distinct
    /// targets share the bounded Host channel admission budget.
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession

    /// Stages one normalized app-owned image in private Host temporary
    /// storage. Concrete transports own destination selection, restrictive
    /// permissions, partial-file handling, and atomic completion (ADR 0006).
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage

    /// Stages one app-owned file in private Host temporary storage. The file
    /// follows the same SFTP, permission, and atomic-completion policy as images.
    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile

    /// Reads the Notification Registration file (v1, `plugin/README.md`)
    /// from the Heeler plugin's config dir on this Host; nil when no
    /// device has registered yet. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin is
    /// absent, so the ceremony can tell "install the plugin" apart from a
    /// broken read (#72).
    func readNotificationRegistration() async throws -> Data?

    /// Atomically replaces the Notification Registration file with
    /// `contents` (temp file + rename per the v1 contract), creating it when
    /// absent. Same plugin gate as the read.
    func replaceNotificationRegistration(_ contents: Data) async throws

    /// Reads the plugin's `notify.json` config from this Host's Heeler
    /// plugin config dir (the registration file's sibling; `plugin/README.md`);
    /// nil when the plugin has no config file yet. Same plugin gate as the
    /// registration read. Carries the custom Push Relay base URL (#76).
    func readNotificationConfig() async throws -> Data?

    /// Atomically replaces the plugin's `notify.json` config with `contents`
    /// (temp file + rename), creating it when absent. Same plugin gate as the
    /// registration write.
    func replaceNotificationConfig(_ contents: Data) async throws

    /// Reads the plugin's `sidebar.json` snapshot (v1, `plugin/README.md`)
    /// from this Host's Heeler plugin config dir; nil when the file is
    /// absent, including Hosts whose plugin predates the snapshot. Throws
    /// `NotificationRegistrationError.pluginNotInstalled` when the plugin
    /// itself is absent, matching the other plugin-config reads.
    func readSidebarLayout() async throws -> Data?

    /// Reads the Heeler plugin's entry from herdr's `plugin.list`, under its
    /// current id or a legacy one; nil when neither is installed. Disabled
    /// plugins are still reported. Throws `TransportError.hostFeatureUnavailable`
    /// on Hosts the plugin does not support (native Windows).
    func readHeelerPlugin() async throws -> HeelerPluginInstallation?

    /// Lists the skills / custom slash commands installed for a kind on this
    /// Host: global sources under the remote home plus project sources under
    /// the query's project root, per `SkillSourceCatalog`. Kinds without a
    /// catalog entry return empty. Reads the filesystem over exec, so
    /// alternative transports without a Host process environment report
    /// nothing by default.
    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill]

    /// Reads one skill document in full (capped) for the on-demand content
    /// view; `path` is what the skills probe reported. Same transport caveat
    /// as `listSkills`.
    func readSkillFile(atPath path: String) async throws -> String

    /// Reads one byte range of a Host file. A file that only ever grows — an
    /// Agent's session transcript — is followed by asking for what has not
    /// been read yet, so a screen can show a running figure without pulling
    /// the whole file on every look.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice

    /// Reads one byte range of an Agent transcript for Chat. Unlike
    /// `readFileSlice`, a read past its deadline throws `.hostFileTimedOut`
    /// rather than the link-failure `.timedOut`, so a slow read on a weak link
    /// never redials the Host; a refused read throws `.hostFileUnreadable`.
    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice

    /// Stats one Host path for Chat, following symlinks. Nil when the path
    /// does not exist. Errors follow `readHostFileRange`.
    func fileStatus(atPath path: String) async throws -> RemoteFileStatus?

    /// Lists the matching entries of one Host directory for Chat. Nil when
    /// the directory does not exist. Errors follow `readHostFileRange`.
    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing?

    /// The Host's home directory as its SSH account sees it, for Chat to
    /// find transcripts under. A probe past its deadline throws
    /// `.hostFileTimedOut`, like the file operations.
    func hostHomeDirectory() async throws -> String

    /// The Host's operating system family, known once the transport has
    /// resolved the remote environment.
    func hostPlatform() async throws -> HostPlatform

    /// Reads one Agent's current record (`agent.get`). Chat re-reads it to
    /// notice the Agent's session changing, which no event reports.
    func agentInfo(_ target: AgentTarget) async throws -> Agent

    /// The context window, in tokens, of the model an Agent's session names
    /// as `provider/model`, as the Agent's own CLI on the Host reports it.
    /// `nil` when the CLI is absent or does not know the model; a session
    /// figure is then shown without its window (#325).
    func modelContextWindow(selector: String) async throws -> Int?

    /// Lists the files inside one untracked directory: one git script over
    /// one exec, using the top level from the latest Changes read. Entries
    /// carry no line counts. Git-level outcomes throw `ChangesReadError`; a
    /// git read past its deadline throws `TransportError.gitTimedOut`.
    /// Transports that cannot run git on a Host throw
    /// `ChangesReadError.unavailable` by default.
    func listUntrackedDirectory(
        _ request: UntrackedDirectoryRequest
    ) async throws -> UntrackedDirectoryListing

    /// Reads the Changes of the Checkout containing `request.directory`:
    /// one git script over one exec, resolved and parsed by `GitProbe`.
    /// Git-level outcomes throw `ChangesReadError`; a git read past its
    /// deadline throws `TransportError.gitTimedOut`. Transports that cannot
    /// run git on a Host throw `ChangesReadError.unavailable` by default.
    func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead

    /// Reads one file's patch in its resolved Checkout, including both paths
    /// for a rename and an empty-file comparison for an untracked file.
    /// Transports without Host git throw `ChangesReadError.unavailable`.
    func readFilePatch(_ request: FilePatchRequest) async throws -> FilePatch

    /// Whether the underlying connection to the Host is still alive. The
    /// reconnect machinery (#18) decides "re-subscribe on this connection or
    /// re-establish it" from this flag.
    var isConnected: Bool { get async }

    /// Tears the connection down explicitly, ending every channel it
    /// carries. Terminal: a closed Transport is not reusable.
    func close() async throws
}

extension Transport {
    /// Test doubles and alternative transports that do not expose Host-level
    /// session discovery can opt out without inventing sessions.
    func listSessions() async throws -> [HerdrSession] { [] }

    func availableAgentKinds() async throws -> [SupportedAgentKind] {
        []
    }

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        throw TransportError.channelFailed(
            detail: "This transport cannot create shell terminals.")
    }

    func createShellWorkspace(
        _ workspace: NewWorkspaceSpec, tabLabel: String?
    ) async throws -> ShellTerminalIdentity {
        throw TransportError.channelFailed(
            detail: "This transport cannot create shell terminals.")
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        []
    }

    func readSkillFile(atPath path: String) async throws -> String {
        throw TransportError.channelFailed(
            detail: "This transport cannot read skill files.")
    }

    /// Test doubles and alternative transports without Host files can decline
    /// without emulating an SSH library; a follower then shows only what the
    /// Host reports elsewhere.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw TransportError.channelFailed(
            detail: "This transport cannot read Host files.")
    }

    /// A transport without Host commands knows no model windows.
    func modelContextWindow(selector: String) async throws -> Int? { nil }

    /// Transports without Host files decline Chat outright, never with a
    /// link-failure error that would make the Host reconnect.
    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func hostHomeDirectory() async throws -> String {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func hostPlatform() async throws -> HostPlatform { .posix }

    func agentInfo(_ target: AgentTarget) async throws -> Agent {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    /// A transport without Host commands cannot list an untracked directory.
    func listUntrackedDirectory(
        _ request: UntrackedDirectoryRequest
    ) async throws -> UntrackedDirectoryListing {
        throw ChangesReadError.unavailable
    }

    /// A transport without Host commands cannot run git, and says so
    /// rather than reporting an empty Checkout.
    func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead {
        throw ChangesReadError.unavailable
    }

    /// A transport without Host commands cannot read a file's patch.
    func readFilePatch(_ request: FilePatchRequest) async throws -> FilePatch {
        throw ChangesReadError.unavailable
    }

    /// Non-SSH test doubles and alternative transports can state that SFTP is
    /// unavailable without importing or emulating an SSH library.
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        throw AttachmentStagingError.sftpUnavailable
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        throw AttachmentStagingError.sftpUnavailable
    }

    /// Test doubles and alternative transports without a Host-side plugin
    /// can report its absence without emulating the plugin CLI.
    func readNotificationRegistration() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func readNotificationConfig() async throws -> Data? {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        throw NotificationRegistrationError.pluginNotInstalled
    }

    /// Test doubles and alternative transports without a Host-side plugin
    /// report an absent snapshot rather than emulating the plugin CLI.
    func readSidebarLayout() async throws -> Data? { nil }

    /// A transport without herdr's plugin registry cannot tell whether the
    /// plugin is installed, which is not the same as reporting it absent.
    func readHeelerPlugin() async throws -> HeelerPluginInstallation? {
        throw TransportError.channelFailed(
            detail: "This transport cannot list herdr plugins.")
    }

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        throw TransportError.channelFailed(
            detail: "This transport cannot list worktrees.")
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        throw TransportError.channelFailed(
            detail: "This transport cannot remove worktrees.")
    }
}

/// Heeler's catalog of interactive Agent kinds.
///
/// The raw value is the canonical `agent.start.kind`; `executable` mirrors
/// the command herdr launches for that kind. Keeping both explicit matters
/// for kinds such as Cursor and Kiro whose executable is not their canonical
/// protocol label.
enum SupportedAgentKind: String, CaseIterable, Identifiable, Sendable, Equatable {
    case pi
    case claude
    case codex
    case gemini
    case cursor
    case devin
    case antigravity = "agy"
    case cline
    case omp
    case mastracode
    case opencode
    case copilot
    case kimi
    case kiro
    case droid
    case amp
    case grok
    case hermes
    case kilo
    case qodercli
    case maki
    case muse
    case qwen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pi: "Pi"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .cursor: "Cursor Agent"
        case .devin: "Devin CLI"
        case .antigravity: "Antigravity"
        case .cline: "Cline"
        case .omp: "OMP"
        case .mastracode: "Mastra Code"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot CLI"
        case .kimi: "Kimi CLI"
        case .kiro: "Kiro CLI"
        case .droid: "Droid"
        case .amp: "Amp"
        case .grok: "Grok Build"
        case .hermes: "Hermes Agent"
        case .kilo: "Kilo Code"
        case .qodercli: "Qoder CLI"
        case .maki: "Maki"
        case .muse: "Muse"
        case .qwen: "Qwen Code"
        }
    }

    var executable: String {
        switch self {
        case .cursor: "cursor-agent"
        case .kiro: "kiro-cli"
        default: rawValue
        }
    }
}

/// App-domain request for launching a fresh coding agent.
///
/// herdr protocol 17 split the old topology-changing `agent.start` into
/// `tab.create` followed by a pane-targeted `agent.start`. Keeping that wire
/// choreography behind `Transport` prevents UI code from depending on the
/// server's transport-level request shapes.
struct AgentLaunchRequest: Sendable, Equatable {
    let kind: String
    let name: String
    let arguments: [String]
    let workspaceID: String?
    /// Working directory for the fresh tab, carried when the launch starts
    /// from another agent's screen and should land in the same place. Nil
    /// lets herdr fall back to the workspace's own directory.
    let cwd: String?
    /// Label for the tab the launch creates. Nil labels the tab with the
    /// agent's name; see `resolvedTabLabel`. Kept separate from `name`
    /// because herdr constrains agent names to a lowercase slug while a tab
    /// label accepts any text.
    let tabLabel: String?

    init(
        kind: String, name: String, arguments: [String] = [], workspaceID: String? = nil,
        cwd: String? = nil, tabLabel: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.arguments = arguments
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.tabLabel = tabLabel
    }

    /// The label the launch's tab should carry: the explicit tab label when
    /// one was given, otherwise the agent's name.
    var resolvedTabLabel: String { tabLabel ?? name }
}

/// The one-shot API request behind Open Terminal and New Terminal. `cwd` is
/// concrete by construction; callers disable the action when they cannot
/// resolve one honestly. `label` names the new tab; nil keeps herdr's
/// positional default.
struct ShellTerminalCreationRequest: Sendable, Equatable {
    let workspaceID: String
    let cwd: String
    let label: String?

    init(workspaceID: String, cwd: String, label: String? = nil) {
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.label = label
    }
}

/// Stable remote identity retained after `tab.create` succeeds. Attach retry
/// and Host-generation replacement use `terminalID`; Pane and Tab ids remain
/// available without inventing a `ConsoleAgent` for the shell.
struct ShellTerminalIdentity: Sendable, Equatable, Hashable {
    let paneID: String
    let tabID: String
    let terminalID: String

    init(paneID: String, tabID: String, terminalID: String) {
        self.paneID = paneID
        self.tabID = tabID
        self.terminalID = terminalID
    }
}

/// What the skills probe needs to know: whose sources to walk and where the
/// agent's project lives. The project root is the *launch* directory context
/// (worktree checkout or agent cwd), deliberately not the live foreground
/// cwd — agents load project skills from where they started, and a `cd`
/// inside the session does not change that set.
struct SkillListQuery: Sendable, Equatable {
    let kind: SupportedAgentKind
    /// Absolute project root, or nil when the agent's project is unknown;
    /// nil skips project sources rather than failing the probe.
    let projectRoot: String?

    init(kind: SupportedAgentKind, projectRoot: String? = nil) {
        self.kind = kind
        self.projectRoot = projectRoot
    }
}

/// A byte range of one Host file, addressed from its start.
struct RemoteFileRange: Sendable, Equatable {
    let path: String
    let offset: UInt64
    let maxBytes: Int

    init(path: String, offset: UInt64, maxBytes: Int) {
        self.path = path
        self.offset = offset
        self.maxBytes = maxBytes
    }
}

/// One ranged read's answer: the bytes that range holds, and the file's size
/// at that moment. `length` is nil only when the file is absent, which is how
/// a follower tells "nothing appended yet" from "the file is gone".
struct RemoteFileSlice: Sendable, Equatable {
    let data: Data
    let length: UInt64?

    init(data: Data, length: UInt64?) {
        self.data = data
        self.length = length
    }
}

/// A late-bound ranged read. Resolved per call rather than captured, so a
/// reconnect cannot leave a follower reading through a dead transport.
typealias SessionFileReader = @Sendable (RemoteFileRange) async throws -> RemoteFileSlice

/// A late-bound `modelContextWindow(selector:)`, resolved per call for the
/// same reason as `SessionFileReader`.
typealias ModelContextWindowResolver = @Sendable (String) async throws -> Int?

/// App-domain refinements for the fresh-worktree launch variant (#97). Nil
/// fields use herdr's defaults, verified live against 0.7.5: branch
/// `worktree/<generated-name>` off HEAD, checkout under herdr's worktree
/// root. An existing branch is checked out, not rejected; it only fails when
/// another worktree already has it checked out.
struct WorktreeSpec: Sendable, Equatable {
    let branch: String?
    let base: String?

    init(branch: String? = nil, base: String? = nil) {
        self.branch = branch
        self.base = base
    }
}

/// App-domain refinements for the new-Workspace launch variant (#230).
/// `directory` is the remote path `workspace.create` opens; `label` is
/// optional and omitted on the wire when nil so herdr applies its default.
struct NewWorkspaceSpec: Sendable, Equatable {
    let directory: String
    let label: String?

    init(directory: String, label: String? = nil) {
        self.directory = directory
        self.label = label
    }
}

/// herdr server identity as reported by `ping`.
struct ServerInfo: Sendable, Equatable {
    let version: String
    let protocolVersion: Int
    /// The Host speaks a protocol newer than the schema snapshot this build
    /// was generated against. Purely advisory: the connection is usable, and
    /// herdr's additions have been additive, but features introduced after
    /// this build cannot be driven. Consumers surface it, never refuse on it.
    let exceedsGeneratedProtocol: Bool

    init(version: String, protocolVersion: Int, exceedsGeneratedProtocol: Bool = false) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.exceedsGeneratedProtocol = exceedsGeneratedProtocol
    }
}

/// One entry from `herdr session list --json` on a Host.
struct HerdrSession: Sendable, Equatable, Decodable {
    let name: String
    let isDefault: Bool
    let isRunning: Bool

    init(name: String, isDefault: Bool, isRunning: Bool) {
        self.name = name
        self.isDefault = isDefault
        self.isRunning = isRunning
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isDefault = "default"
        case isRunning = "running"
    }
}

/// The grammar enforced by herdr 0.7.4 for named sessions. Keeping it at the
/// transport boundary prevents malformed discovery output from becoming part
/// of a remote socket path; forms reuse it for immediate feedback.
enum HerdrSessionName {
    static let maximumUTF8Length = 64

    static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard name.utf8.count <= maximumUTF8Length else { return false }
        return name.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }
}

/// Paths passed through the Host's login shell use the conservative quoting
/// subset shared by POSIX shells and fish. Spaces are safe inside single
/// quotes; quote, backslash, and control characters are refused because their
/// single-quote behavior differs across those shells.
enum RemoteShellPath {
    static func quotedAbsolute(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard path.unicodeScalars.allSatisfy(isQuotable) else { return nil }
        return "'\(path)'"
    }

    static func isQuotableAbsolute(_ path: String) -> Bool {
        quotedAbsolute(path) != nil
    }

    private static func isQuotable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
            && scalar.value != 0x27 && scalar.value != 0x5C
    }
}

/// Absolute paths in a Host's filesystem, independent of the iOS filesystem.
/// Windows drive and UNC paths travel as literal values; POSIX paths retain
/// the existing conservative login-shell quoting policy.
enum RemoteHostPath {
    static func isAbsolute(_ path: String) -> Bool {
        if windowsRoot(of: path) != nil { return isSafeWindowsPath(path) }
        return RemoteShellPath.isQuotableAbsolute(path)
    }

    static func isWindowsAbsolute(_ path: String) -> Bool {
        windowsRoot(of: path) != nil && isSafeWindowsPath(path)
    }

    static func childPath(_ parent: String, name: String) -> String {
        let separator = windowsRoot(of: parent)?.separator ?? "/"
        if let last = parent.last, isSeparator(last, windows: windowsRoot(of: parent) != nil) {
            return parent + name
        }
        return parent + String(separator) + name
    }

    static func parentPath(of path: String) -> String? {
        guard isAbsolute(path) else { return nil }
        guard let root = windowsRoot(of: path) else {
            guard path != "/" else { return nil }
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard trimmed != "/", !trimmed.isEmpty else { return nil }
            let parent = (trimmed as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }
        let trimmed = trimmingSeparators(in: path, after: root.end, windows: true)
        guard trimmed.endIndex > root.end else { return nil }
        guard let separator = trimmed.lastIndex(where: { isSeparator($0, windows: true) }) else {
            return nil
        }
        let end = max(separator, root.end)
        return String(path[..<end])
    }

    /// A folder label that recognizes the Host's separators rather than the
    /// local device's POSIX path conventions. Roots keep their useful name.
    static func lastComponent(of path: String) -> String {
        let root = windowsRoot(of: path)
        let rootEnd = root?.end ?? (path.hasPrefix("/") ? path.index(after: path.startIndex) : path.startIndex)
        let trimmed = trimmingSeparators(in: path, after: rootEnd, windows: root != nil)
        if trimmed.endIndex == rootEnd { return String(trimmed) }
        return trimmed.split(whereSeparator: { isSeparator($0, windows: root != nil) })
            .last.map(String.init) ?? path
    }

    private struct WindowsRoot {
        let end: String.Index
        let separator: Character
    }

    private static func windowsRoot(of path: String) -> WindowsRoot? {
        let prefix = Array(path.prefix(3))
        if prefix.count == 3,
            prefix[0].asciiValue.map({ (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }) == true,
            prefix[1] == ":", isSeparator(prefix[2], windows: true)
        {
            return WindowsRoot(end: path.index(path.startIndex, offsetBy: 3), separator: prefix[2])
        }
        // UNC paths stop at the share root. Device namespaces are deliberately
        // excluded, so Back cannot turn a filesystem path into a device path.
        guard path.hasPrefix("\\\\") else { return nil }
        let serverStart = path.index(path.startIndex, offsetBy: 2)
        guard let serverEnd = path[serverStart...].firstIndex(where: { isSeparator($0, windows: true) }),
            serverEnd > serverStart
        else { return nil }
        let server = path[serverStart..<serverEnd]
        guard server != ".", server != "..", server != "?" else { return nil }
        let shareStart = path.index(after: serverEnd)
        let shareEnd = path[shareStart...].firstIndex(where: { isSeparator($0, windows: true) }) ?? path.endIndex
        let share = path[shareStart..<shareEnd]
        guard !share.isEmpty, share != ".", share != ".." else { return nil }
        return WindowsRoot(end: shareEnd, separator: "\\")
    }

    private static func isSafeWindowsPath(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7F && $0.value != 0x27 && $0.value != 0x22
        }
    }

    private static func isSeparator(_ character: Character, windows: Bool) -> Bool {
        character == "/" || (windows && character == "\\")
    }

    private static func trimmingSeparators(
        in path: String, after rootEnd: String.Index, windows: Bool
    ) -> Substring {
        var end = path.endIndex
        while end > rootEnd {
            let previous = path.index(before: end)
            guard isSeparator(path[previous], windows: windows) else { break }
            end = previous
        }
        return path[..<end]
    }
}

/// Directories-only listing of one remote directory, for the remote
/// directory browser (#280). Names are sorted; `truncated` reports that more
/// directories exist than fit in the surfaced cap.
struct RemoteDirectoryListing: Sendable, Equatable {
    let directories: [String]
    let truncated: Bool
}

/// A coding agent process running inside a herdr Pane.
///
/// The domain view of the generated wire type `AgentInfo`: only the fields
/// the app consumes, with wire-level optionality resolved. `AgentStatus` is
/// the generated raw-string wrapper; Blocked drives sort order and (later)
/// notifications.
struct Agent: Sendable, Equatable {
    let terminalID: String
    /// The agent program herdr detected: "claude", "codex", ... Behavior
    /// stays keyed off this; labels prefer `displayName`.
    let kind: String
    /// The server-reported agent name the herdr TUI shows (`display_agent`,
    /// falling back to `name`); nil when the server reports neither.
    let name: String?
    /// Terminal title with spinner/status glyphs stripped.
    let title: String
    /// Raw OSC title, kept separately from the legacy `title` presentation.
    let terminalTitle: String?
    /// herdr's stripped title; an explicitly empty wire value stays empty.
    let terminalTitleStripped: String?
    /// Pane presentation/manual title (`AgentInfo.title`), not a pane id.
    let paneTitle: String?
    /// Where herdr says this Agent's own session lives, when it detects one.
    /// For `omp` that is the session transcript (#325).
    let agentSession: AgentSessionInfo?
    let tokens: [String: String]
    let stateLabels: [String: String]
    /// Snapshot ordering metadata for Agent panel sort consumers.
    let stateChangeSeq: Int?
    /// Mutable: the Console applies `pane.agent_status_changed` deltas in
    /// place between snapshots.
    var status: AgentStatus
    let workspaceID: String
    let tabID: String
    /// The Pane address used for per-pane subscriptions and attach.
    let paneID: String
    let cwd: String
    /// The Agent process's directory in the last snapshot, separate from
    /// the launch directory used by Open Terminal, Skills and Agent rows.
    let foregroundCwd: String?
    let revision: Int

    /// The card's primary label (#41): the server-reported name when present,
    /// otherwise the detected kind.
    var displayName: String { name ?? kind }

    init(
        terminalID: String, kind: String, title: String, status: AgentStatus,
        workspaceID: String, tabID: String, paneID: String, cwd: String, revision: Int,
        name: String? = nil,
        terminalTitle: String? = nil, terminalTitleStripped: String? = nil,
        paneTitle: String? = nil, agentSession: AgentSessionInfo? = nil,
        tokens: [String: String] = [:],
        stateLabels: [String: String] = [:], stateChangeSeq: Int? = nil,
        foregroundCwd: String? = nil
    ) {
        self.terminalID = terminalID
        self.kind = kind
        self.name = name
        self.title = title
        self.terminalTitle = terminalTitle
        self.terminalTitleStripped = terminalTitleStripped
            ?? terminalTitle.map(Self.strippedSidebarTitle)
        self.paneTitle = paneTitle
        self.agentSession = agentSession
        self.tokens = tokens
        self.stateLabels = stateLabels
        self.stateChangeSeq = stateChangeSeq
        self.status = status
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.paneID = paneID
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.revision = revision
    }

    /// Maps the generated wire type onto the domain view. Wire-optional
    /// fields degrade instead of failing: herdr's API has no stability
    /// guarantee, and a missing title must not drop the Agent from the list.
    init(_ info: AgentInfo) {
        self.init(
            terminalID: info.terminalID,
            kind: info.agent ?? "unknown",
            title: TerminalTitleGlyphs.strip(
                info.terminalTitleStripped ?? info.terminalTitle ?? ""),
            status: info.agentStatus,
            workspaceID: info.workspaceID,
            tabID: info.tabID,
            paneID: info.paneID,
            cwd: info.cwd ?? "",
            revision: info.revision,
            name: Self.nonEmpty(info.displayAgent) ?? Self.nonEmpty(info.name),
            terminalTitle: info.terminalTitle,
            terminalTitleStripped: info.terminalTitleStripped,
            paneTitle: info.title,
            agentSession: info.agentSession,
            tokens: info.tokens ?? [:],
            stateLabels: info.stateLabels ?? [:],
            stateChangeSeq: info.stateChangeSeq,
            foregroundCwd: info.foregroundCwd
        )
    }

    /// herdr 0.8.2 removes one activity glyph only when followed by whitespace
    /// or end-of-title. Keep legacy `title` consumers on TerminalTitleGlyphs.
    private static func strippedSidebarTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first,
            (0x2800...0x28ff).contains(first.value) || "·✢✳✶✻✽◐◓◑◒".unicodeScalars.contains(first)
        else { return trimmed }
        let rest = String(trimmed.unicodeScalars.dropFirst())
        let startsWithWhitespace = rest.unicodeScalars.first.map {
            CharacterSet.whitespacesAndNewlines.contains($0)
        } ?? false
        guard rest.isEmpty || startsWithWhitespace
        else { return trimmed }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty wire string carries no name; treating it as missing keeps the
    /// fallback chain from rendering a blank card label.
    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Where the herdr API socket lives on a Host. Home-relative locations are
/// resolved against the remote home directory, which the Transport resolves
/// over exec once per Host and caches.
enum HerdrSocketLocation: Sendable, Equatable {
    /// The default herdr session: `~/.config/herdr/herdr.sock`.
    case defaultSession
    /// A named session: `~/.config/herdr/sessions/<name>/herdr.sock`.
    case namedSession(String)
    /// An absolute path known in advance; needs no remote resolution.
    case absolutePath(String)

    /// The absolute socket path, given the Host's home directory.
    func path(homeDirectory: String) -> String {
        let home =
            homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        switch self {
        case .defaultSession:
            return "\(home)/.config/herdr/herdr.sock"
        case .namedSession(let name):
            return "\(home)/.config/herdr/sessions/\(name)/herdr.sock"
        case .absolutePath(let path):
            return path
        }
    }
}

/// Transport-level failures: a closed taxonomy so every screen maps errors to
/// user guidance consistently instead of string-matching.
indirect enum TransportError: Error, Sendable, Equatable {
    /// The SSH server could not be reached: connection refused, no route,
    /// or the connection died before authentication.
    case sshUnreachable(detail: String)
    /// The first hop failed: the Host may be perfectly healthy, but the
    /// Jump Host in front of it is unreachable, rejected our key, or presented
    /// an unexpected host key. Carries the underlying failure so screens can
    /// reuse the existing guidance while naming the Jump Host as the culprit.
    case jumpHostFailed(TransportError)
    /// The Jump Host accepted SSH authentication but its server or key policy
    /// prohibits the direct-tcpip channel required to reach the Host.
    case tcpForwardingUnavailable
    /// The Host rejected our credentials (key not authorized, wrong
    /// password, or the offered auth method is unavailable).
    case authenticationFailed
    /// The device's stored Ed25519 private key cannot be decoded. Reconnecting
    /// cannot repair it; the user must explicitly replace the Device Key.
    case deviceKeyCorrupt
    /// The stored RSA identity cannot be decoded. It must be replaced
    /// explicitly and the replacement public key registered with every Host.
    case rsaKeyCorrupt
    /// RSA Key authentication found no RSA-SHA2-512 signature the Host would
    /// take: it advertised only other RSA signature algorithms, or none at
    /// all. No signature was sent, so registering the key again cannot help.
    case rsaSignatureUnsupported
    /// First connect to an unknown Host and the user declined its key
    /// fingerprint; nothing was stored.
    case hostKeyRejected(presented: HostKeyFingerprint)
    /// The Host presented a key that differs from the trusted fingerprint —
    /// possibly a man-in-the-middle. Hard failure; the stored fingerprint is
    /// left untouched.
    case hostKeyMismatch(known: HostKeyFingerprint, presented: HostKeyFingerprint)
    /// The herdr API socket path does not exist on the Host: herdr is not
    /// installed there, or the socket path is wrong.
    case socketNotFound(path: String)
    /// The herdr CLI is not on the SSH session's PATH and was not found in
    /// the well-known install prefixes. The API socket can still work — that
    /// is why the Console may list Agents while Attach fails (#206).
    case herdrBinaryNotFound
    /// libssh2 cannot distinguish a listening Unix socket rejected by SSH
    /// policy from a stale socket file. The Host needs either herdr started or
    /// stream-local forwarding enabled; presenting a narrower cause would be
    /// fabricated precision.
    case streamLocalOpenFailed(path: String)
    /// The server speaks a herdr protocol version this build does not support.
    case protocolVersionMismatch(server: Int, supported: Int)
    /// The remote home directory could not be resolved, so a home-relative
    /// socket location has no path.
    case homeDirectoryUnresolvable(detail: String)
    /// A directory-browsing request carried a path that cannot be passed to
    /// the Host's login shell: empty, relative, or holding NUL, quote,
    /// backslash, or control characters. Rejected before any channel opens.
    case invalidDirectoryPath(path: String)
    /// A second events channel was requested while one is live; each Host
    /// keeps exactly one dedicated events channel (ADR 0011 headroom).
    case eventsChannelAlreadyOpen
    /// A second terminal channel was requested while one is live, or a
    /// second reader tried to consume a terminal session that already has
    /// one; each Host keeps exactly one interactive terminal surface at a
    /// time, and each session serves exactly one of them.
    case terminalChannelAlreadyOpen
    /// The request exceeded its per-request deadline; the channel it held was
    /// closed.
    case timedOut
    /// A Changes script exceeded its own deadline. This says nothing about
    /// link health and must not trigger a redial or an automatic retry: the
    /// exec can remain alive until its remote watchdog ends the process group.
    case gitTimedOut
    /// A Chat transcript operation exceeded its own deadline. Like
    /// `.gitTimedOut` this says nothing about link health: a slow file read
    /// over a weak link must not redial the Host and rebuild its terminals.
    case hostFileTimedOut
    /// The Host refused a Chat transcript operation with an SFTP status other
    /// than "no such file", such as permission denied.
    case hostFileUnreadable(status: UInt64)
    /// The request's task was cancelled before completing. Resource cleanup
    /// may outlive the caller; a dispatched git exec waits for its bounded
    /// remote exit instead of abandoning the channel.
    case cancelled
    /// The channel produced bytes that do not decode as a herdr response.
    case malformedResponse(String)
    /// herdr answered with an error envelope: the request arrived intact and
    /// the server rejected it on its own terms.
    case apiRejected(code: String, message: String)
    /// The channel failed outside the known failure shapes; carries the
    /// underlying description for diagnostics.
    case channelFailed(detail: String)
    case hostFeatureUnavailable(feature: String)

    /// Whether reconnecting without user intervention can plausibly recover.
    /// Configuration, trust, authentication, and protocol failures instead
    /// stop so the UI can explain the required action.
    /// `.streamLocalOpenFailed` is configuration-class: neither of the two
    /// causes it cannot tell apart — a stopped herdr, disabled stream-local
    /// forwarding — resolves without the user acting on the Host (ADR 0011).
    var isRetryable: Bool {
        switch self {
        // A rejection is retryable because herdr's error codes are open-ended
        // and most of them describe a target that moved, not a broken setup.
        case .sshUnreachable, .timedOut, .cancelled, .channelFailed,
            .apiRejected:
            true
        case .authenticationFailed, .tcpForwardingUnavailable,
            .deviceKeyCorrupt, .rsaKeyCorrupt, .rsaSignatureUnsupported,
            .hostKeyRejected, .hostKeyMismatch,
            .socketNotFound, .herdrBinaryNotFound, .protocolVersionMismatch,
            .streamLocalOpenFailed, .gitTimedOut, .hostFileTimedOut, .hostFileUnreadable,
            .hostFeatureUnavailable,
            .homeDirectoryUnresolvable, .invalidDirectoryPath,
            .eventsChannelAlreadyOpen,
            .terminalChannelAlreadyOpen, .malformedResponse:
            false
        // A Jump Host is retryable exactly when the failure behind it is: a
        // rebooting VPS should reconnect on its own, a rejected key should not.
        case .jumpHostFailed(let underlying):
            underlying.isRetryable
        }
    }
}

/// An error returned by the herdr server inside a response envelope.
struct HerdrAPIError: Error, Sendable, Equatable {
    /// Normalized to a string; the wire schema promises `{"code","message"}`
    /// without pinning the code's JSON type.
    let code: String
    let message: String
}
