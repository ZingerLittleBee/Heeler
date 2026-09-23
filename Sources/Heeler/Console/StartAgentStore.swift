import Foundation
import Observation
import SwiftUI

/// The new-agent flow's form logic (#12, User Story 8): pick a Host, pick a
/// launch target (an existing Workspace, or a new one at a remote directory),
/// detect and select an installed Agent, parse its native arguments, and
/// dispatch it via the Transport launch flow. The started pane surfaces in
/// the Console through the store's normal snapshot/delta machinery; on
/// success the store reports the started Agent's Console identity so the
/// owning screen can open it right away.
///
/// Kept off the SSH types (standing repo rule): it talks to injected closures
/// over the `ConsoleStore`, so it is testable against a scripted transport.

/// The launched pane's Console identity. An Agent row keys off host + pane;
/// a plain shell pane additionally says so, because the Console routes it to
/// the terminal surface rather than Agent detail.
struct ConsoleLaunchIdentity: Equatable, Sendable {
    let hostID: Host.ID
    let paneID: String
    let isAgent: Bool

    init(hostID: Host.ID, paneID: String, isAgent: Bool = true) {
        self.hostID = hostID
        self.paneID = paneID
        self.isAgent = isAgent
    }

    /// The identity an Agent launch produces; the Console opens Agent detail
    /// for it.
    var agentID: ConsoleAgent.ID? {
        isAgent ? ConsoleAgent.ID(hostID: hostID, paneID: paneID) : nil
    }
}

@MainActor
@Observable
final class StartAgentStore {
    enum State: Equatable {
        /// Editing the form; no start in flight.
        case editing
        /// An `agent.start` RPC is in flight.
        case starting
        /// The last start failed; the message is user-facing.
        case failed(String)
        /// The launch succeeded; the payload is the launched pane's Console
        /// identity — an Agent's, or a plain shell pane's — which the owner
        /// opens after the screen dismisses.
        case started(ConsoleLaunchIdentity)
    }

    enum AgentDiscoveryState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// Context inherited when the flow opens from an agent's own screen: the
    /// launch reuses that agent's Host, workspace, and working directory
    /// instead of asking for all three again. The new agent lands in a fresh
    /// tab beside the one it was started from, in the same directory.
    struct LaunchOrigin: Equatable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
        let cwd: String
    }

    /// Where a Console-originated launch should create the Agent (#230).
    /// Origin launches skip this choice: they inherit the origin Workspace.
    enum LaunchTarget: Equatable, Hashable {
        case existingWorkspace
        case newWorkspace
    }

    /// The Transport variant `submit()` dispatches. Invalid combinations
    /// (a Worktree of a Workspace that does not exist yet) cannot be
    /// represented.
    enum LaunchDestination: Equatable, Sendable {
        case existingWorkspace
        case newWorktree(WorktreeSpec)
        case newWorkspace(NewWorkspaceSpec)
    }

    /// What the "Agent" picker selects: a plain shell or a detected Agent
    /// kind.
    enum LaunchSelection: Hashable {
        case shell
        case agent(SupportedAgentKind)
    }

    /// What `submit()` assembled from the form: one Transport variant and
    /// the launch it targets. A plain shell dispatches the shell variants
    /// (no `agent.start` follows); an Agent dispatches the agent ones.
    struct Dispatch: Equatable, Sendable {
        let destination: LaunchDestination
        let launch: LaunchSelection
    }

    enum ArgumentError: Error, Equatable {
        case danglingEscape
        case unclosedSingleQuote
        case unclosedDoubleQuote
        case controlCharacter

        var message: String {
            switch self {
            case .danglingEscape:
                "Arguments end with an unfinished escape."
            case .unclosedSingleQuote:
                "Arguments contain an unclosed single quote."
            case .unclosedDoubleQuote:
                "Arguments contain an unclosed double quote."
            case .controlCharacter:
                "Arguments contain an unsupported control character."
            }
        }
    }

    /// The Hosts the user can dispatch to — the Host picker's options.
    let hosts: [Host]

    /// Non-nil when the flow was opened from an agent rather than the
    /// Console: Host, workspace, and working directory are already decided,
    /// so the form collapses to the agent fields.
    let origin: LaunchOrigin?

    var selectedHostID: Host.ID? {
        didSet {
            // A workspace belongs to one Host; switching Hosts drops a stale
            // pick so it can never target the wrong session.
            if selectedHostID != oldValue {
                pickedWorkspaceID = nil
                availableAgentKinds = []
                selectedAgentKind = nil
                selectedLaunchIsShell = false
                agentDiscoveryState = .idle
                launchTarget = .existingWorkspace
                newWorkspaceDirectory = ""
                newWorkspaceLabel = ""
                startsInNewWorktree = false
                worktreeBranch = ""
                worktreeBase = ""
            }
        }
    }

    /// The existing Workspace the agent starts in: what the user picked, else
    /// the one they last started an agent in on this Host, else the Host's
    /// first.
    ///
    /// Nil while the Host reports no Workspaces at all. Existing-Workspace
    /// and origin launches cannot submit until a concrete Workspace is
    /// available; New Workspace does not use this pick.
    var selectedWorkspaceID: String? {
        get {
            // The origin agent is living proof its workspace exists, so it
            // wins outright rather than being filtered against a snapshot
            // that may not have landed yet.
            if let origin { return origin.workspaceID }
            let available = workspaces
            if let pickedWorkspaceID,
                available.contains(where: { $0.id == pickedWorkspaceID })
            {
                return pickedWorkspaceID
            }
            if let selectedHostID, let remembered = recents.workspaceID(for: selectedHostID),
                available.contains(where: { $0.id == remembered })
            {
                return remembered
            }
            return available.first?.id
        }
        set { pickedWorkspaceID = newValue }
    }

    /// The user's explicit pick; nil means "follow the default above". Kept
    /// separate so a snapshot arriving after the sheet opens still gets to
    /// supply the default.
    private var pickedWorkspaceID: String?
    /// The unique live-agent name required by herdr protocol 17. Optional in
    /// the form: empty falls back to a kind-derived name (`claude`,
    /// `claude-2`, …), mirroring how the herdr TUI labels unnamed agents.
    var name: String = ""
    /// The canonical kind selected from the Host availability probe.
    var selectedAgentKind: SupportedAgentKind?
    /// Whether the "Agent" picker currently targets a plain shell rather
    /// than a detected Agent kind. Shell needs no detection, so the picker
    /// offers it even while the probe is loading, failed, or empty.
    var selectedLaunchIsShell = false
    /// Optional native arguments, parsed into argv without invoking a shell.
    /// The editor disables smart punctuation at the UIKit input-trait layer;
    /// parsing still normalizes any smart characters supplied by paste or a
    /// third-party keyboard without mutating the live editing buffer.
    var arguments: String = ""
    /// Existing Workspace vs New Workspace on the Console-originated form.
    /// Switching target drops an incompatible Worktree request so it cannot
    /// ride along with a launch that has no source Workspace.
    var launchTarget: LaunchTarget = .existingWorkspace {
        didSet {
            if launchTarget != oldValue {
                startsInNewWorktree = false
                worktreeBranch = ""
                worktreeBase = ""
            }
        }
    }
    /// Remote directory for a New Workspace launch. Optional: empty resolves
    /// to the Host's home directory at submit. Trimmed before use.
    var newWorkspaceDirectory: String = ""
    /// Selecting a directory switches the draft destination without starting
    /// an Agent. Dismissing the browser never changes the current selection.
    func applyBrowsedDirectory(_ path: String) {
        guard offersNewWorkspace, RemoteShellPath.isQuotableAbsolute(path) else { return }
        newWorkspaceDirectory = path
        selectNewWorkspace()
    }

    /// Switches the draft destination to a New Workspace launch. Allowed
    /// without a browsed directory: a name-only workspace resolves to the
    /// Host's home directory at submit.
    func selectNewWorkspace() {
        guard offersNewWorkspace else { return }
        launchTarget = .newWorkspace
    }

    func selectExistingWorkspace(_ id: String) {
        guard origin == nil, workspaces.contains(where: { $0.id == id }) else { return }
        selectedWorkspaceID = id
        launchTarget = .existingWorkspace
    }
    /// Optional label for a New Workspace launch. Empty or whitespace
    /// becomes nil so herdr applies its default.
    var newWorkspaceLabel: String = ""
    /// Whether the launch targets a fresh git worktree of the selected
    /// workspace's repository instead of the workspace itself (#97).
    var startsInNewWorktree = false
    /// Optional branch for the new worktree; empty uses herdr's generated
    /// `worktree/<name>` branch. Validated client-side because herdr folds
    /// every git failure into one raw-stderr error code.
    var worktreeBranch: String = ""
    /// Optional base commit-ish for the new branch; empty branches off HEAD.
    /// Not validated: any rev syntax is legal here, so the server's message
    /// passthrough is the honest feedback.
    var worktreeBase: String = ""

    private(set) var state: State = .editing
    private(set) var agentDiscoveryState: AgentDiscoveryState = .idle
    private(set) var availableAgentKinds: [SupportedAgentKind] = []

    private let workspacesProvider: (Host.ID) -> [ConsoleWorkspace]
    /// The agent names already live on a Host, so a generated default never
    /// collides with them. Names only: herdr's duplicate check ignores
    /// detected kind labels, but the Console reports those as names too, and
    /// skipping them merely bumps the suffix.
    private let existingAgentNames: (Host.ID) -> Set<String>
    private let discoverAgentKinds: (Host.ID) async throws -> [SupportedAgentKind]
    /// Resolves the Host's home directory for a name-only New Workspace
    /// launch; fetched at submit so an unreachable Host never blocks editing.
    private let remoteHome: (Host.ID) async throws -> String
    /// Dispatches the assembled request through the matching Transport
    /// launch variant.
    private let start: (AgentLaunchRequest, LaunchDestination, Host.ID) async throws -> Agent
    /// Dispatches a plain-shell launch through the matching Transport shell
    /// variant. Separate from `start` so the shell path never needs the
    /// Agent-only closure's signature.
    private let startShell: (ShellLaunchRequest, LaunchDestination, Host.ID) async throws ->
        ShellLaunchResult
    /// Suspends (bounded) until the started Agent is visible in the Console.
    /// The row the owner navigates to exists only after the post-start resync
    /// lands; waiting here keeps the opened detail from flashing its
    /// missing-Agent placeholder over a launch that just succeeded.
    private let awaitAgentVisible: (ConsoleAgent.ID) async -> Void
    /// The shell launch's counterpart: waits until the Host's terminal
    /// inventory reports the created pane, for the same reason.
    private let awaitPaneVisible: (String, Host.ID) async -> Void
    @ObservationIgnored private let recents: RecentWorkspaceStore
    @ObservationIgnored private let selections: RecentSelectionsStore
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot dispatch the same command twice through the window
    /// before `state == .starting` disables the button.
    private var isStarting = false

    init(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        existingAgentNames: @escaping (Host.ID) -> Set<String>,
        discoverAgentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind],
        remoteHome: @escaping (Host.ID) async throws -> String,
        start: @escaping (AgentLaunchRequest, LaunchDestination, Host.ID) async throws -> Agent,
        startShell: ((ShellLaunchRequest, LaunchDestination, Host.ID) async throws ->
            ShellLaunchResult)? = nil,
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void,
        awaitPaneVisible: ((String, Host.ID) async -> Void)? = nil,
        origin: LaunchOrigin? = nil,
        recents: RecentWorkspaceStore = RecentWorkspaceStore(),
        selections: RecentSelectionsStore = RecentSelectionsStore()
    ) {
        self.hosts = hosts
        self.origin = origin
        self.workspacesProvider = workspaces
        self.existingAgentNames = existingAgentNames
        self.discoverAgentKinds = discoverAgentKinds
        self.remoteHome = remoteHome
        self.start = start
        self.startShell =
            startShell
            ?? { _, _, _ in
                throw TransportError.channelFailed(
                    detail: "This flow cannot launch shells.")
            }
        self.awaitAgentVisible = awaitAgentVisible
        self.awaitPaneVisible = awaitPaneVisible ?? { _, _ in }
        self.recents = recents
        self.selections = selections
        // Pre-select when there is no choice to make; with several Hosts, the
        // last-used one wins if it still exists.
        self.selectedHostID =
            origin?.hostID
            ?? (hosts.count == 1
                ? hosts.first?.id
                : hosts.first(where: { $0.id == selections.lastHostID })?.id)
    }

    /// Whether the fresh-worktree variant is offered. An origin launch is
    /// defined by landing in the origin agent's directory, and a worktree
    /// launch lands in a brand-new checkout instead — the two cannot both
    /// hold, so the origin flow drops the option rather than silently
    /// ignoring the requested directory. New Workspace likewise has no
    /// source Workspace to branch from.
    var offersWorktree: Bool { origin == nil && launchTarget == .existingWorkspace }

    /// Whether the form offers Existing vs New Workspace. Origin launches
    /// inherit the origin agent's Workspace and directory, so the choice
    /// would contradict that inheritance.
    var offersNewWorkspace: Bool { origin == nil }

    /// The workspaces the selected Host knows; empty when no Host is picked.
    var workspaces: [ConsoleWorkspace] {
        guard let selectedHostID else { return [] }
        return workspacesProvider(selectedHostID)
    }

    var parsedArguments: Result<[String], ArgumentError> {
        Self.parseArguments(Self.normalizeSmartPunctuation(arguments))
    }

    var argumentErrorMessage: String? {
        guard case .failure(let error) = parsedArguments else { return nil }
        return error.message
    }

    /// User-facing name feedback; nil while the field is empty (empty means
    /// "use the generated default"). A shell launch's name is a tab label,
    /// not an agent name: herdr's agent-name rule does not govern it, so
    /// any non-empty label is accepted.
    var nameErrorMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if selectedLaunchIsShell { return nil }
        return AgentName.validationError(trimmed)
    }

    /// The name `submit()` falls back to while the field is empty; nil until
    /// a Host and Agent are selected. Shown as the field's placeholder so the
    /// fallback is never a surprise.
    var defaultAgentName: String? {
        guard let selectedHostID, let kind = selectedAgentKind else { return nil }
        return Self.defaultAgentName(for: kind, taken: existingAgentNames(selectedHostID))
    }

    /// The tab label a plain-shell launch falls back to while the field is
    /// empty: "Default Shell", then "Default Shell 2", "Default Shell 3", …
    /// skipping tab labels already live on the Host.
    var defaultShellName: String? {
        guard let selectedHostID else { return nil }
        return Self.defaultShellName(taken: existingAgentNames(selectedHostID))
    }

    /// User-facing branch feedback; nil while the toggle is off or the field
    /// is empty (empty means "use herdr's generated branch").
    var worktreeBranchErrorMessage: String? {
        guard startsInNewWorktree else { return nil }
        let branch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return nil }
        return GitBranchName.validationError(branch)
    }

    /// Whether the form is complete enough to dispatch.
    var canSubmit: Bool {
        selectedHostID != nil && hasLaunchTarget
            && nameErrorMessage == nil
            && worktreeBranchErrorMessage == nil
            && state != .starting
            && (selectedLaunchIsShell
                || (parsedArguments.isSuccess && selectedAgentKind != nil
                    && agentDiscoveryState == .loaded))
    }

    /// Existing Workspace and origin launches need a reported Workspace;
    /// a New Workspace launch is complete as chosen, because a name-only
    /// launch resolves its directory at submit.
    private var hasLaunchTarget: Bool {
        if origin != nil { return selectedWorkspaceID != nil }
        switch launchTarget {
        case .existingWorkspace:
            return selectedWorkspaceID != nil
        case .newWorkspace:
            // Directory is optional: a name-only launch falls back to the
            // Host's home directory at submit.
            return true
        }
    }

    /// Whether the sheet may be dismissed without abandoning an in-flight
    /// launch whose server-side outcome may already be committed.
    var canDismiss: Bool {
        state != .starting
    }

    func discoverAgents() async {
        guard let hostID = selectedHostID else {
            availableAgentKinds = []
            selectedAgentKind = nil
            agentDiscoveryState = .idle
            return
        }
        availableAgentKinds = []
        selectedAgentKind = nil
        agentDiscoveryState = .loading
        do {
            let kinds = try await discoverAgentKinds(hostID)
            guard selectedHostID == hostID else { return }
            availableAgentKinds = kinds
            if selections.lastSelectionWasShell {
                selectedLaunchIsShell = true
            } else {
                selectedAgentKind =
                    kinds.first(where: { $0 == selections.lastAgentKind }) ?? kinds.first
            }
            agentDiscoveryState = .loaded
        } catch is CancellationError {
            guard selectedHostID == hostID else { return }
            agentDiscoveryState = .idle
        } catch {
            guard selectedHostID == hostID else { return }
            agentDiscoveryState = .failed(Self.discoveryMessage(for: error))
        }
    }

    /// Dispatches the assembled launch — an `agent.start` for a detected
    /// Agent kind, or a plain shell (the same fresh pane, no `agent.start`)
    /// for "Default Shell". Incomplete forms are ignored; on success the
    /// state flips to `.started` carrying the new Console identity for the
    /// screen to dismiss and open.
    func submit() async {
        guard
            !isStarting,
            let hostID = selectedHostID,
            worktreeBranchErrorMessage == nil,
            nameErrorMessage == nil
        else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Agent launches need parseable arguments; a shell launch carries
        // none, so stale text left in the hidden Arguments field must not
        // block it.
        let launchArguments: [String]
        if selectedLaunchIsShell {
            launchArguments = []
        } else {
            guard case .success(let arguments) = parsedArguments else { return }
            launchArguments = arguments
        }
        isStarting = true
        defer { isStarting = false }
        // A name-only New Workspace launch has no browsed directory: fall
        // back to the Host's home directory, resolved at submit so an
        // unreachable Host is reported here instead of blocking the form.
        // isStarting flips before the first await so a double-tap cannot
        // dispatch twice while the probe is in flight.
        if origin == nil, launchTarget == .newWorkspace,
            Self.nonEmptyTrimmed(newWorkspaceDirectory) == nil
        {
            state = .starting
            do {
                let home = try await remoteHome(hostID)
                // The form stays editable while the probe is in flight;
                // discard the answer if it no longer applies.
                guard selectedHostID == hostID,
                    launchTarget == .newWorkspace,
                    Self.nonEmptyTrimmed(newWorkspaceDirectory) == nil
                else {
                    state = .editing
                    return
                }
                guard RemoteShellPath.isQuotableAbsolute(home) else {
                    state = .failed(
                        "The Host's home directory is not a usable path: \(home)")
                    return
                }
                newWorkspaceDirectory = home
            } catch {
                state = .failed(Self.homeProbeMessage(for: error))
                return
            }
        }
        guard let dispatch = launchDispatch else { return }
        state = .starting
        let workspaceID: String?
        switch dispatch.destination {
        case .newWorkspace:
            workspaceID = nil
        case .existingWorkspace, .newWorktree:
            workspaceID = selectedWorkspaceID
        }
        switch dispatch.launch {
        case .agent(let kind):
            let agentName =
                trimmedName.isEmpty
                ? Self.defaultAgentName(for: kind, taken: existingAgentNames(hostID))
                : trimmedName
            let request = AgentLaunchRequest(
                kind: kind.rawValue,
                name: agentName,
                arguments: launchArguments,
                workspaceID: workspaceID,
                cwd: origin?.cwd)
            do {
                let agent = try await start(request, dispatch.destination, hostID)
                selections.remember(hostID: hostID, kind: kind)
                if case .newWorkspace = dispatch.destination {
                    recents.remember(agent.workspaceID, for: hostID)
                } else if let workspaceID {
                    recents.remember(workspaceID, for: hostID)
                }
                let startedID = ConsoleLaunchIdentity(hostID: hostID, paneID: agent.paneID)
                // The wait is bounded; on timeout the owner still navigates and
                // the row catches up with the next resync.
                await awaitAgentVisible(startedID.agentID ?? ConsoleAgent.ID(
                    hostID: hostID, paneID: agent.paneID))
                state = .started(startedID)
            } catch {
                state = .failed(Self.message(for: error, launchedKind: kind))
            }
        case .shell:
            // A tab label is cosmetic on a shell pane: nil lets herdr apply
            // its default rather than minting a unique agent-style name.
            let shellName = Self.nonEmptyTrimmed(trimmedName)
            let request = ShellLaunchRequest(
                name: shellName,
                workspaceID: workspaceID,
                cwd: origin?.cwd)
            do {
                let result = try await startShell(request, dispatch.destination, hostID)
                selections.rememberShell(hostID: hostID)
                if case .newWorkspace = dispatch.destination {
                    recents.remember(result.workspaceID, for: hostID)
                } else if let workspaceID {
                    recents.remember(workspaceID, for: hostID)
                }
                // The wait is bounded; on timeout the owner still navigates
                // and the terminal row catches up with the next resync.
                await awaitPaneVisible(result.paneID, hostID)
                state = .started(
                    ConsoleLaunchIdentity(
                        hostID: hostID, paneID: result.paneID, isAgent: false))
            } catch {
                state = .failed(Self.message(for: error, launchedKind: nil))
            }
        }
    }

    /// Assembles the Transport variant from the current form. Nil when the
    /// chosen target is incomplete, so `submit()` is a no-op rather than
    /// inventing a Workspace id.
    private var launchDispatch: Dispatch? {
        let destination: LaunchDestination
        if origin != nil {
            guard selectedWorkspaceID != nil else { return nil }
            destination = .existingWorkspace
        } else {
            switch launchTarget {
            case .existingWorkspace:
                guard selectedWorkspaceID != nil else { return nil }
                if offersWorktree && startsInNewWorktree {
                    destination = .newWorktree(
                        WorktreeSpec(
                            branch: Self.nonEmptyTrimmed(worktreeBranch),
                            base: Self.nonEmptyTrimmed(worktreeBase)))
                } else {
                    destination = .existingWorkspace
                }
            case .newWorkspace:
                guard let directory = Self.nonEmptyTrimmed(newWorkspaceDirectory) else {
                    return nil
                }
                destination = .newWorkspace(
                    NewWorkspaceSpec(
                        directory: directory,
                        label: Self.nonEmptyTrimmed(newWorkspaceLabel)))
            }
        }
        if selectedLaunchIsShell {
            return Dispatch(destination: destination, launch: .shell)
        }
        guard let kind = selectedAgentKind else { return nil }
        return Dispatch(destination: destination, launch: .agent(kind))
    }

    /// The SwiftUI binding behind the "Agent" picker. Optional on purpose:
    /// a nil selection (detection failed or found nothing, and the user has
    /// not chosen Default Shell) must read as "nothing chosen" rather than
    /// pretending an Agent kind is picked while Start stays disabled.
    var launchSelection: Binding<LaunchSelection?> {
        Binding(
            get: { [self] in
                if selectedLaunchIsShell { return .shell }
                return selectedAgentKind.map(LaunchSelection.agent)
            },
            set: { [self] selection in
                switch selection {
                case .shell:
                    selectedLaunchIsShell = true
                case .agent(let kind):
                    selectedLaunchIsShell = false
                    selectedAgentKind = kind
                case nil:
                    break
                }
            })
    }

    /// Parses a familiar shell-like argument string into argv without ever
    /// passing it through a shell. Quotes group whitespace, adjacent quoted
    /// and unquoted segments join one argument, and backslash escapes the next
    /// character. Empty quoted arguments are preserved.
    static func parseArguments(_ input: String) -> Result<[String], ArgumentError> {
        enum Quote {
            case single
            case double
        }

        var result: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Quote?
        var escaping = false

        for character in input {
            if escaping {
                guard !isControl(character) else {
                    return .failure(.controlCharacter)
                }
                current.append(character)
                hasCurrent = true
                escaping = false
                continue
            }

            switch quote {
            case .single:
                if character == "'" {
                    quote = nil
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                }
                hasCurrent = true
            case .double:
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    escaping = true
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                }
                hasCurrent = true
            case nil:
                if character == "'" {
                    quote = .single
                    hasCurrent = true
                } else if character == "\"" {
                    quote = .double
                    hasCurrent = true
                } else if character == "\\" {
                    escaping = true
                    hasCurrent = true
                } else if character.isWhitespace {
                    if hasCurrent {
                        result.append(current)
                        current = ""
                        hasCurrent = false
                    }
                } else {
                    guard !isControl(character) else {
                        return .failure(.controlCharacter)
                    }
                    current.append(character)
                    hasCurrent = true
                }
            }
        }

        guard !escaping else { return .failure(.danglingEscape) }
        switch quote {
        case .single: return .failure(.unclosedSingleQuote)
        case .double: return .failure(.unclosedDoubleQuote)
        case nil: break
        }
        if hasCurrent {
            result.append(current)
        }
        return .success(result)
    }

    /// The fallback for an empty name field: the kind itself, then `kind-2`,
    /// `kind-3`, … skipping names already live on the Host. Kind identifiers
    /// are lowercase ASCII, so the result always passes herdr's name rule.
    static func defaultAgentName(for kind: SupportedAgentKind, taken: Set<String>) -> String {
        guard taken.contains(kind.rawValue) else { return kind.rawValue }
        var suffix = 2
        while taken.contains("\(kind.rawValue)-\(suffix)") { suffix += 1 }
        return "\(kind.rawValue)-\(suffix)"
    }

    /// The fallback for an empty name field on a shell launch: "Default
    /// Shell", then "Default Shell 2", "Default Shell 3", … skipping names
    /// already carried by Agent tabs on the Host (an Agent's tab is labeled
    /// with its name), so the suggested label never reads as a second
    /// Agent. Tab labels are their own namespace on the wire — the dedup is
    /// purely against visual confusion.
    static func defaultShellName(taken: Set<String>) -> String {
        let base = "Default Shell"
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    /// Normalizes smart punctuation that arrives through paste or a
    /// third-party keyboard. The editor itself disables these substitutions;
    /// this is a defensive parse-boundary fallback, never an edit-time write.
    static func normalizeSmartPunctuation(_ text: String) -> String {
        guard text.contains(where: Self.isSmartPunctuation) else { return text }
        var result = ""
        result.reserveCapacity(text.count + 2)
        for character in text {
            switch character {
            case "\u{201C}", "\u{201D}":  // curly double quotes
                result.append("\"")
            case "\u{2018}", "\u{2019}":  // curly single quotes
                result.append("'")
            case "\u{2014}":  // em dash, iOS's replacement for "--"
                result.append("--")
            case "\u{2013}":  // en dash
                result.append("-")
            default:
                result.append(character)
            }
        }
        return result
    }

    private static func isSmartPunctuation(_ character: Character) -> Bool {
        switch character {
        case "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", "\u{2014}", "\u{2013}":
            true
        default:
            false
        }
    }

    private static func nonEmptyTrimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func discoveryMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "Agent detection timed out."
        default:
            "Detecting Agents failed: \(error)"
        }
    }

    /// User-facing copy for a failed home-directory probe: the same
    /// TransportError arms the launch path maps, with the probe's subject.
    private static func homeProbeMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected, so its home directory could not be resolved."
        case TransportError.timedOut:
            "Resolving the Host's home directory timed out."
        default:
            "Could not determine the Host's home directory: \(error)"
        }
    }

    private static func message(
        for error: any Error, launchedKind: SupportedAgentKind?
    ) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let apiError as HerdrAPIError where apiError.code == "not_git_worktree":
            // The one dedicated worktree.create error code (#97); everything
            // else collapses into worktree_create_failed with raw git stderr,
            // which the passthrough below surfaces as-is.
            "This workspace is not inside a Git repository, so no worktree can be created from it."
        case let apiError as HerdrAPIError where apiError.code == "worktree_create_failed":
            "Creating the worktree failed: \(apiError.message)"
        case let apiError as HerdrAPIError
            where apiError.code == "unsupported_agent_kind" && launchedKind == .muse:
            // Kind captured at submit, not the picker after await. Discovery
            // does not prove herdr supports Muse (#289); keep the server
            // reason and tell the user how to recover.
            "herdr rejected the command: \(apiError.message). "
                + "Update herdr on this Host to v0.9.0 or later for Muse support, "
                + "or choose another supported Agent."
        case let apiError as HerdrAPIError:
            "herdr rejected the command: \(apiError.message)"
        default:
            // A shell launch has no agent to blame: the failure is the Host
            // refusing the tab or workspace itself.
            launchedKind == nil
                ? "Starting the shell failed: \(error)"
                : "Starting the agent failed: \(error)"
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
