import Foundation
import Observation

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
        /// The start succeeded; the payload is the started Agent's Console
        /// identity, which the owner opens after the screen dismisses.
        case started(ConsoleAgent.ID)
        /// A Template started a program that is running and is no Agent until it
        /// reports. Its row is in the Terminals list, and an Agent detail would
        /// read as gone.
        case startedAsTerminal
    }

    enum AgentDiscoveryState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What the form's Agent picker can hold.
    enum AgentChoice: Hashable {
        case kind(SupportedAgentKind)
        case template(AgentTemplate)
    }

    /// A complete choice, with what it starts under, read once at submit.
    private enum Launch {
        case kind(SupportedAgentKind, arguments: [String], name: String)
        case template(AgentTemplate, name: String?)
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

    enum ArgumentError: Error, Equatable {
        case danglingEscape
        case unclosedSingleQuote
        case unclosedDoubleQuote
        case controlCharacter

        var message: String {
            switch self {
            case .danglingEscape:
                String(localized: "Arguments end with an unfinished escape.")
            case .unclosedSingleQuote:
                String(localized: "Arguments contain an unclosed single quote.")
            case .unclosedDoubleQuote:
                String(localized: "Arguments contain an unclosed double quote.")
            case .controlCharacter:
                String(localized: "Arguments contain an unsupported control character.")
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
                availableTemplates = []
                selectedTemplate = nil
                selectedPresetID = nil
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
    /// The canonical kind selected from the Host availability probe. Each
    /// probe defaults it to the kind last started, when this Host has it,
    /// else the Host's first.
    var selectedAgentKind: SupportedAgentKind? {
        didSet {
            if selectedAgentKind != nil { selectedTemplate = nil }
            // Another harness leaves the preset behind.
            if let selectedPreset, selectedPreset.kind != selectedAgentKind { selectedPresetID = nil }
        }
    }
    /// The Launch Preset the Agent starts from (#622); nil starts the
    /// harness as the form describes it. Picking one picks its harness.
    var selectedPresetID: LaunchPreset.ID? {
        didSet {
            if let selectedPreset, selectedAgentKind != selectedPreset.kind { selectedAgentKind = selectedPreset.kind }
        }
    }
    /// The Template selected in place of a kind.
    var selectedTemplate: AgentTemplate? {
        didSet { if selectedTemplate != nil { selectedAgentKind = nil } }
    }
    /// Either one, as the form's picker holds it.
    var selectedAgent: AgentChoice? {
        get {
            selectedTemplate.map(AgentChoice.template) ?? selectedAgentKind.map(AgentChoice.kind)
        }
        set {
            switch newValue {
            case .kind(let kind): selectedAgentKind = kind
            case .template(let template): selectedTemplate = template
            case nil:
                selectedAgentKind = nil
                selectedTemplate = nil
            }
        }
    }
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
        guard offersNewWorkspace, RemoteHostPath.isAbsolute(path) else { return }
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
    /// Optional label for the tab the launch creates. Empty or whitespace
    /// becomes nil so herdr or a title plugin names the tab. Unlike the
    /// agent's name it is free text: herdr's slug rule applies to agents,
    /// not tabs.
    var tabLabel: String = ""
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
    /// The Host's Templates, offered beside the kinds.
    private(set) var availableTemplates: [AgentTemplate] = []

    private let workspacesProvider: (Host.ID) -> [ConsoleWorkspace]
    /// The names already live on a Host, so a generated default never collides
    /// with them. A herdr-core Host's Terminals hold theirs whether or not they
    /// are Agents. herdr's duplicate check ignores detected kind labels, but the
    /// Console reports those as names too, and skipping them merely bumps the
    /// suffix.
    private let existingAgentNames: (Host.ID) -> Set<String>
    private let discoverAgentKinds: (Host.ID) async throws -> [SupportedAgentKind]
    private let discoverTemplates: (Host.ID) async throws -> [AgentTemplate]
    /// Resolves the Host's home directory for a name-only New Workspace
    /// launch; fetched at submit so an unreachable Host never blocks editing.
    private let remoteHome: (Host.ID) async throws -> String
    /// Whether a Host's desktop app could apply a typed Workspace name now.
    private let offersDesktopAppNames: (Host.ID) -> Bool
    /// Whether a connected Host serves Worktrees, which a herdr-core Host's
    /// platform decides.
    private let offersConnectedWorktrees: (Host.ID) -> Bool
    /// Dispatches the assembled request through the matching Transport
    /// launch variant.
    private let start: (AgentLaunchRequest, LaunchDestination, Host.ID) async throws -> Agent
    private let startTemplate: (TemplateLaunchRequest, Host.ID) async throws -> Agent
    /// Suspends (bounded) until the started Agent is visible in the Console.
    /// The row the owner navigates to exists only after the post-start resync
    /// lands; waiting here keeps the opened detail from flashing its
    /// missing-Agent placeholder over a launch that just succeeded.
    private let awaitAgentVisible: (ConsoleAgent.ID) async -> Void
    private let isAgentListed: (ConsoleAgent.ID) -> Bool
    private let programExit: (ConsoleAgent.ID) -> ProgramExit?
    @ObservationIgnored private let recents: RecentLaunchStore
    /// The device's Launch Presets, read when the form shows them.
    private let presetsProvider: () -> [LaunchPreset]
    /// The variable a harness's Accounts set on a Host (its Accounts'
    /// `variable`, else the harness's own); nil when neither is known.
    private let accountVariable: (Host.ID, SupportedAgentKind) async throws -> String?
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot dispatch the same command twice through the window
    /// before `state == .starting` disables the button.
    private var isStarting = false

    init(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        existingAgentNames: @escaping (Host.ID) -> Set<String>,
        discoverAgentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind],
        discoverTemplates: @escaping (Host.ID) async throws -> [AgentTemplate] = { _ in [] },
        startTemplate: @escaping (TemplateLaunchRequest, Host.ID) async throws -> Agent = { _, _ in
            throw TransportError.hostFeatureUnavailable(feature: String(localized: "Templates"))
        },
        remoteHome: @escaping (Host.ID) async throws -> String,
        start: @escaping (AgentLaunchRequest, LaunchDestination, Host.ID) async throws -> Agent,
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void,
        isAgentListed: @escaping (ConsoleAgent.ID) -> Bool = { _ in true },
        programExit: @escaping (ConsoleAgent.ID) -> ProgramExit? = { _ in nil },
        origin: LaunchOrigin? = nil,
        recents: RecentLaunchStore = RecentLaunchStore(),
        offersDesktopAppNames: @escaping (Host.ID) -> Bool = { _ in false },
        offersConnectedWorktrees: @escaping (Host.ID) -> Bool = { _ in false },
        presets: @escaping () -> [LaunchPreset] = { [] },
        accountVariable: @escaping (Host.ID, SupportedAgentKind) async throws -> String? = { _, kind in
            kind.configDirectoryVariable
        }
    ) {
        self.offersDesktopAppNames = offersDesktopAppNames
        self.offersConnectedWorktrees = offersConnectedWorktrees
        self.presetsProvider = presets
        self.accountVariable = accountVariable
        self.hosts = hosts
        self.origin = origin
        self.workspacesProvider = workspaces
        self.existingAgentNames = existingAgentNames
        self.discoverAgentKinds = discoverAgentKinds
        self.discoverTemplates = discoverTemplates
        self.remoteHome = remoteHome
        self.start = start
        self.startTemplate = startTemplate
        self.awaitAgentVisible = awaitAgentVisible
        self.isAgentListed = isAgentListed
        self.programExit = programExit
        self.recents = recents
        // Pre-select when there is no choice to make.
        self.selectedHostID = origin?.hostID ?? (hosts.count == 1 ? hosts.first?.id : nil)
    }

    /// Whether the fresh-worktree variant is offered. An origin launch is
    /// defined by landing in the origin agent's directory, and a worktree
    /// launch lands in a brand-new checkout instead — the two cannot both
    /// hold, so the origin flow drops the option rather than silently
    /// ignoring the requested directory. New Workspace likewise has no
    /// source Workspace to branch from.
    var offersWorktree: Bool {
        origin == nil && launchTarget == .existingWorkspace
            && (selectedHost?.capabilities.worktrees != false
                || selectedHostID.map(offersConnectedWorktrees) == true)
    }

    /// A herdr-core Host has no generated branch or base: Heeler makes the
    /// Worktree as the Herdr desktop app does, on the branch the user names, from
    /// the Workspace's HEAD (ADR 0032).
    var worktreeNeedsBranch: Bool {
        selectedHost?.serverKind == .herdrCore
    }

    /// Whether the form asks for Workspace and tab names. Its Agent name is
    /// independent of them.
    var offersWorkspaceAndTabNames: Bool {
        selectedHost?.capabilities.tabNames != false
    }

    /// Whether New Workspace asks for a name. A herdr-core Host has none of its
    /// own, so only while its desktop app can apply one.
    var offersWorkspaceName: Bool {
        offersWorkspaceAndTabNames || selectedHostID.map(offersDesktopAppNames) == true
    }

    /// A herdr-core Host, and a tmux Host, find Agents through the user's
    /// interactive shell (ADR 0032), not the Host's PATH.
    var discoversThroughUserShell: Bool {
        selectedHost?.serverKind == .herdrCore || selectedHost?.serverKind == .tmux
    }

    private var selectedHost: Host? {
        hosts.first(where: { $0.id == selectedHostID })
    }

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
    /// "use the generated default").
    var nameErrorMessage: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return AgentName.validationError(trimmed)
    }

    /// The name `submit()` falls back to while the field is empty; nil until
    /// a Host and Agent are selected. Shown as the field's placeholder so the
    /// fallback is never a surprise.
    var defaultAgentName: String? {
        guard let selectedHostID else { return nil }
        let taken = existingAgentNames(selectedHostID)
        if let selectedTemplate {
            return Self.defaultAgentName(forTemplate: selectedTemplate.name, taken: taken)
        }
        guard let kind = selectedAgentKind else { return nil }
        let base = selectedPreset.flatMap(Self.agentNameBase) ?? kind.rawValue
        return Self.defaultAgentName(base: base, taken: taken)
    }

    /// The presets of the harnesses the selected Host has.
    var availablePresets: [LaunchPreset] {
        presetsProvider().filter { availableAgentKinds.contains($0.kind) }
    }

    var selectedPreset: LaunchPreset? {
        guard let selectedPresetID else { return nil }
        return presetsProvider().first { $0.id == selectedPresetID }
    }

    /// A preset's name as an Agent name when herdr accepts it lowercased
    /// (`Work` gives `work`); nil otherwise.
    private static func agentNameBase(_ preset: LaunchPreset) -> String? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AgentName.validationError(name) == nil ? name : nil
    }

    /// A Template's command is its own, so the form asks for no arguments.
    var offersArguments: Bool { selectedTemplate == nil }

    /// A Template's start can wait out the program's first report, long enough
    /// for the form to say so.
    var isStartingTemplate: Bool { state == .starting && selectedTemplate != nil }

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
            && hasCompleteAgentChoice
            && worktreeBranchErrorMessage == nil
            && !isMissingNeededBranch
            && state != .starting
    }

    private var isMissingNeededBranch: Bool {
        offersWorktree && startsInNewWorktree && worktreeNeedsBranch
            && Self.nonEmptyTrimmed(worktreeBranch) == nil
    }

    /// A Template goes through no shell, so it stays open when discovery failed.
    private var hasCompleteAgentChoice: Bool {
        if selectedTemplate != nil { return true }
        return selectedAgentKind != nil && parsedArguments.isSuccess
            && agentDiscoveryState == .loaded
    }

    private var pendingLaunch: Launch? {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedName = typed.isEmpty ? nil : typed
        if let selectedTemplate {
            return .template(selectedTemplate, name: typedName ?? defaultAgentName)
        }
        guard let selectedAgentKind, case .success(let arguments) = parsedArguments,
            let agentName = typedName ?? defaultAgentName
        else { return nil }
        return .kind(selectedAgentKind, arguments: arguments, name: agentName)
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
        availableAgentKinds = []
        selectedAgentKind = nil
        availableTemplates = []
        selectedTemplate = nil
        guard let hostID = selectedHostID else {
            agentDiscoveryState = .idle
            return
        }
        agentDiscoveryState = .loading
        // Heeler's own list does not depend on this one, so an ask that fails
        // leaves the form with Heeler's agents.
        let templates = (try? await discoverTemplates(hostID)) ?? []
        guard selectedHostID == hostID else { return }
        availableTemplates = templates
        do {
            let kinds = try await discoverAgentKinds(hostID)
            guard selectedHostID == hostID else { return }
            availableAgentKinds = kinds
            if let remembered = recents.agentKind, kinds.contains(remembered) {
                selectedAgentKind = remembered
            } else {
                selectedAgentKind = kinds.first
            }
            if kinds.isEmpty { selectedTemplate = templates.first }
            agentDiscoveryState = .loaded
        } catch is CancellationError {
            guard selectedHostID == hostID else { return }
            agentDiscoveryState = .idle
        } catch {
            guard selectedHostID == hostID else { return }
            selectedTemplate = templates.first
            agentDiscoveryState = .failed(Self.discoveryMessage(for: error))
        }
    }

    /// Dispatches the command via `agent.start`. Incomplete forms are ignored;
    /// on success the state flips to `.started` carrying the new Agent's
    /// Console identity for the screen to dismiss and open.
    func submit() async {
        guard
            !isStarting,
            let hostID = selectedHostID,
            let launch = pendingLaunch,
            worktreeBranchErrorMessage == nil,
            !isMissingNeededBranch,
            nameErrorMessage == nil
        else { return }
        let preset = selectedPreset
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
                guard RemoteHostPath.isAbsolute(home) else {
                    state = .failed(
                        String(localized: "The Host's home directory is not a usable path: \(home)"))
                    return
                }
                newWorkspaceDirectory = home
            } catch {
                state = .failed(Self.homeProbeMessage(for: error))
                return
            }
        }
        guard let destination = launchDestination else { return }
        // A preset may await the Host below while the form stays editable:
        // what the launch is sent to is fixed here, and a form changed
        // meanwhile is not launched.
        let target = SubmittedTarget(destination: destination, workspaceID: selectedWorkspaceID, tabLabel: tabLabel)
        state = .starting
        var launchArguments: [String] = []
        if case .kind(_, let arguments, _) = launch { launchArguments = arguments }
        var environment: [String: String] = [:]
        if let preset {
            do {
                let home = preset.needsHome ? try await remoteHome(hostID) : nil
                let variable: String?
                do {
                    variable = preset.accountDirectory == nil ? nil : try await accountVariable(hostID, preset.kind)
                } catch {
                    state = .failed(HostAccountsStore.changeMessage(for: error))
                    return
                }
                guard selectedHostID == hostID, selectedPresetID == preset.id,
                    launchDestination.map({
                        SubmittedTarget(destination: $0, workspaceID: selectedWorkspaceID, tabLabel: tabLabel)
                    }) == target
                else {
                    state = .editing
                    return
                }
                let presetLaunch = try preset.launch(formArguments: launchArguments, home: home, accountVariable: variable)
                launchArguments = presetLaunch.arguments
                environment = presetLaunch.environment
            } catch let problem as LaunchPreset.Problem {
                state = .failed(problem.message)
                return
            } catch {
                state = .failed(Self.homeProbeMessage(for: error))
                return
            }
        }
        let workspaceID: String?
        switch destination {
        case .newWorkspace:
            workspaceID = nil
        case .existingWorkspace, .newWorktree:
            workspaceID = target.workspaceID
        }
        do {
            let agent: Agent
            switch launch {
            case .kind(let kind, _, let agentName):
                agent = try await start(
                    AgentLaunchRequest(
                        kind: kind.rawValue,
                        name: agentName,
                        arguments: launchArguments,
                        workspaceID: workspaceID,
                        cwd: origin?.cwd,
                        tabLabel: offersWorkspaceAndTabNames ? Self.nonEmptyTrimmed(target.tabLabel) : nil,
                        environment: environment),
                    destination, hostID)
            case .template(let template, let agentName):
                var newWorkspace: NewWorkspaceSpec?
                if case .newWorkspace(let spec) = destination { newWorkspace = spec }
                var worktree: WorktreeSpec?
                if case .newWorktree(let spec) = destination { worktree = spec }
                agent = try await startTemplate(
                    TemplateLaunchRequest(
                        template: template.name, name: agentName, workspaceID: workspaceID,
                        cwd: origin?.cwd, newWorkspace: newWorkspace, worktree: worktree),
                    hostID)
            }
            if case .newWorkspace = destination {
                recents.rememberWorkspace(agent.workspaceID, for: hostID)
            } else if let workspaceID {
                recents.rememberWorkspace(workspaceID, for: hostID)
            }
            if case .kind(let kind, _, _) = launch { recents.rememberAgentKind(kind) }
            let startedID = ConsoleAgent.ID(hostID: hostID, paneID: agent.paneID)
            // The wait is bounded; on timeout the owner still navigates and
            // the row catches up with the next resync.
            await awaitAgentVisible(startedID)
            switch launch {
            case .template(let template, _):
                if let exit = programExit(startedID) {
                    state = .failed(Self.message(forTemplate: template.name, endedWith: exit))
                } else {
                    state = isAgentListed(startedID) ? .started(startedID) : .startedAsTerminal
                }
            case .kind(let kind, _, _):
                if let exit = programExit(startedID) {
                    state = .failed(Self.message(forKind: kind, endedWith: exit))
                } else {
                    state = .started(startedID)
                }
            }
        } catch {
            var kind: SupportedAgentKind?
            if case .kind(let launched, _, _) = launch { kind = launched }
            state = .failed(Self.message(for: error, launchedKind: kind))
        }
    }

    /// Where a submitted launch goes, as the form said when it was submitted.
    private struct SubmittedTarget: Equatable {
        let destination: LaunchDestination
        let workspaceID: String?
        let tabLabel: String
    }

    /// Assembles the Transport variant from the current form. Nil when the
    /// chosen target is incomplete, so `submit()` is a no-op rather than
    /// inventing a Workspace id.
    private var launchDestination: LaunchDestination? {
        if origin != nil {
            guard selectedWorkspaceID != nil else { return nil }
            return .existingWorkspace
        }
        switch launchTarget {
        case .existingWorkspace:
            guard selectedWorkspaceID != nil else { return nil }
            if offersWorktree && startsInNewWorktree {
                return .newWorktree(
                    WorktreeSpec(
                        branch: Self.nonEmptyTrimmed(worktreeBranch),
                        base: worktreeNeedsBranch ? nil : Self.nonEmptyTrimmed(worktreeBase)))
            }
            return .existingWorkspace
        case .newWorkspace:
            guard let directory = Self.nonEmptyTrimmed(newWorkspaceDirectory) else {
                return nil
            }
            return .newWorkspace(
                NewWorkspaceSpec(
                    directory: directory,
                    label: offersWorkspaceName ? Self.nonEmptyTrimmed(newWorkspaceLabel) : nil))
        }
    }

    /// Parses a familiar shell-like argument string into argv without ever
    /// passing it through a shell. Quotes group whitespace, adjacent quoted
    /// and unquoted segments join one argument, and backslash escapes the next
    /// character. Empty quoted arguments are preserved.
    nonisolated static func parseArguments(_ input: String) -> Result<[String], ArgumentError> {
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
        defaultAgentName(base: kind.rawValue, taken: taken)
    }

    /// A Template's file name may be no agent name, or leave no room for a
    /// suffix: that Agent goes unnamed, and its row shows what it runs.
    static func defaultAgentName(forTemplate template: String, taken: Set<String>) -> String? {
        let name = defaultAgentName(base: template, taken: taken)
        // A suffix that would shorten the Template's name names no Agent.
        guard name.hasPrefix(template) else { return nil }
        return AgentName.validationError(name) == nil ? name : nil
    }

    static func defaultAgentName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains(suffixed(base, suffix)) { suffix += 1 }
        return suffixed(base, suffix)
    }

    /// `base-n`, the base shortened so the whole stays within herdr's
    /// 32-character name limit (a preset's name can use all 32).
    private static func suffixed(_ base: String, _ suffix: Int) -> String {
        let tail = "-\(suffix)"
        return String(base.prefix(max(1, agentNameLimit - tail.count))) + tail
    }

    private static let agentNameLimit = 32

    /// Normalizes smart punctuation that arrives through paste or a
    /// third-party keyboard. The editor itself disables these substitutions;
    /// this is a defensive parse-boundary fallback, never an edit-time write.
    nonisolated static func normalizeSmartPunctuation(_ text: String) -> String {
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

    private nonisolated static func isSmartPunctuation(_ character: Character) -> Bool {
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

    private nonisolated static func isControl(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func discoveryMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        case TransportError.timedOut:
            String(localized: "Agent detection timed out.")
        case TransportError.hostFeatureUnavailable(let feature):
            feature
        case TransportError.malformedResponse(let detail):
            detail
        default:
            TransportError.herdrCoreLinkMessage(for: error)
                ?? String(localized: "Detecting Agents failed: \(String(describing: error))")
        }
    }

    /// User-facing copy for a failed home-directory probe: the same
    /// TransportError arms the launch path maps, with the probe's subject.
    static func homeProbeMessage(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected, so its home directory could not be resolved.")
        case TransportError.timedOut:
            String(localized: "Resolving the Host's home directory timed out.")
        default:
            String(localized: "Could not determine the Host's home directory: \(String(describing: error))")
        }
    }

    /// The core reports a command `sh -c` could not find as exit code 127.
    private static func message(forTemplate template: String, endedWith exit: ProgramExit) -> String {
        message(
            for: template, endedWith: exit,
            commandNotFound: String(localized: "That code means its command was not found: a Template runs without your shell, so it needs a full path or a PATH of its own."))
    }

    /// A kind goes through the Host's login shell, so its 127 is that shell's.
    private static func message(forKind kind: SupportedAgentKind, endedWith exit: ProgramExit) -> String {
        message(
            for: kind.displayName, endedWith: exit,
            commandNotFound: String(localized: "That code means the Host's shell could not find its command."))
    }

    private static func message(
        for program: String, endedWith exit: ProgramExit, commandNotFound: String
    ) -> String {
        switch exit.code {
        case 0:
            String(localized: "\(program) finished right after it started, so no Agent is running.")
        case 127:
            String(localized: "\(program) ended right after it started, with exit code 127, so no Agent is running. \(commandNotFound)")
        case let code?:
            String(localized: "\(program) ended right after it started, with exit code \(code), so no Agent is running.")
        case nil:
            String(localized: "\(program) ended right after it started, so no Agent is running.")
        }
    }

    private static func message(
        for error: any Error, launchedKind: SupportedAgentKind?
    ) -> String {
        switch error {
        case TransportError.sshUnreachable:
            String(localized: "The Host is not connected.")
        case TransportError.timedOut:
            String(localized: "The Host did not answer in time.")
        case TransportError.gitTimedOut:
            String(localized: "The Host's git did not answer in time.")
        case TransportError.coreMutationOutcomeUnknown:
            String(localized: "The Host did not confirm the launch. The Agent may still have started, so check the Host before trying again.")
        case TransportError.hostFeatureUnavailable(let feature):
            feature
        case let worktree as HerdrCoreWorktreeError:
            worktree.message
        case let template as HerdrCoreTemplateError:
            template.message
        case let failure as WorktreeAgentStartFailure:
            String(localized: "The worktree is ready at \(failure.checkoutPath), but the Agent did not start. \(message(for: failure.underlying, launchedKind: launchedKind))")
        case let apiError as HerdrAPIError where apiError.code == "not_git_worktree":
            // The one dedicated worktree.create error code (#97); everything
            // else collapses into worktree_create_failed with raw git stderr,
            // which the passthrough below surfaces as-is.
            String(localized: "This workspace is not inside a Git repository, so no worktree can be created from it.")
        case let apiError as HerdrAPIError where apiError.code == "worktree_create_failed":
            String(localized: "Creating the worktree failed: \(apiError.message)")
        case let apiError as HerdrAPIError
            where apiError.code == "unsupported_agent_kind" && launchedKind == .muse:
            // Kind captured at submit, not the picker after await. Discovery
            // does not prove herdr supports Muse (#289); keep the server
            // reason and tell the user how to recover.
            String(localized: "herdr rejected the command: \(apiError.message). Update herdr on this Host to v0.9.0 or later for Muse support, or choose another supported Agent.")
        case let apiError as HerdrAPIError where apiError.isCanonicalModeRefusal:
            // The Transport resends this refusal for its whole shell-readiness
            // wait, so it lands here only once that wait ran out; "10 seconds"
            // mirrors `HeelerSSHTransport.shellReadinessBudget`.
            String(localized: "The Host's shell didn't accept a launch command this long within 10 seconds. On a Mac, herdr accepts at most 1,024 bytes until the shell's line editor starts, and some shells, such as dash, never start one. Shorten the arguments and try again.")
        case let apiError as HerdrAPIError:
            String(localized: "herdr rejected the command: \(apiError.message)")
        default:
            TransportError.herdrCoreLinkMessage(for: error)
                ?? String(localized: "Starting the agent failed: \(String(describing: error))")
        }
    }
}

extension StartAgentStore.LaunchOrigin {
    /// Beside `agent`: its Host, Workspace, and the directory a launch there
    /// starts in, which for a derived core Workspace is the Workspace's own.
    @MainActor init(beside agent: ConsoleAgent, in console: ConsoleStore) {
        self.init(
            hostID: agent.hostID, workspaceID: agent.agent.workspaceID,
            cwd: console.launchDirectory(
                ofWorkspace: agent.agent.workspaceID, asked: agent.agent.cwd, on: agent.hostID))
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
