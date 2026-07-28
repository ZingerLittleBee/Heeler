import Foundation
import Observation

/// The new-agent flow's form logic (#12, User Story 8): pick a Host, pick a
/// workspace (or the Host's current one), detect and select an installed
/// Agent, parse its native arguments, and dispatch it via the Transport launch
/// flow. The started pane surfaces in the Console through the store's normal
/// snapshot/delta machinery — this screen only fires the RPC and reports its
/// outcome.
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
        /// The start succeeded; the screen dismisses.
        case started
    }

    enum AgentDiscoveryState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
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

    var selectedHostID: Host.ID? {
        didSet {
            // A workspace belongs to one Host; switching Hosts drops a stale
            // pick so it can never target the wrong session.
            if selectedHostID != oldValue {
                pickedWorkspaceID = nil
                availableAgentKinds = []
                selectedAgentKind = nil
                agentDiscoveryState = .idle
                startsInNewWorktree = false
                worktreeBranch = ""
                worktreeBase = ""
            }
        }
    }

    /// The workspace the agent starts in: what the user picked, else the one
    /// they last started an agent in on this Host, else the Host's first.
    ///
    /// Nil while the Host reports no workspaces at all. The form cannot submit
    /// until a concrete workspace is available, so the launch target is always
    /// visible to the user.
    var selectedWorkspaceID: String? {
        get {
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
    /// Optional native arguments, parsed into argv without invoking a shell.
    /// Smart punctuation is normalized back to ASCII on every edit: the iOS
    /// keyboard turns `--` into an em dash and straight quotes into curly
    /// ones (`.autocorrectionDisabled` does not cover them, and SwiftUI has
    /// no smart-punctuation trait), which silently corrupts flags like
    /// `--yolo` before they reach the Host.
    var arguments: String = "" {
        didSet {
            let normalized = Self.normalizeSmartPunctuation(arguments)
            if normalized != arguments { arguments = normalized }
        }
    }
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
    /// A non-nil `WorktreeSpec` routes the launch through the fresh-worktree
    /// choreography; nil starts in the workspace itself.
    private let start: (AgentLaunchRequest, WorktreeSpec?, Host.ID) async throws -> Agent
    @ObservationIgnored private let recents: RecentWorkspaceStore
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot dispatch the same command twice through the window
    /// before `state == .starting` disables the button.
    private var isStarting = false

    init(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        existingAgentNames: @escaping (Host.ID) -> Set<String>,
        discoverAgentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind],
        start: @escaping (AgentLaunchRequest, WorktreeSpec?, Host.ID) async throws -> Agent,
        recents: RecentWorkspaceStore = RecentWorkspaceStore()
    ) {
        self.hosts = hosts
        self.workspacesProvider = workspaces
        self.existingAgentNames = existingAgentNames
        self.discoverAgentKinds = discoverAgentKinds
        self.start = start
        self.recents = recents
        // Pre-select when there is no choice to make.
        self.selectedHostID = hosts.count == 1 ? hosts.first?.id : nil
    }

    /// The workspaces the selected Host knows; empty when no Host is picked.
    var workspaces: [ConsoleWorkspace] {
        guard let selectedHostID else { return [] }
        return workspacesProvider(selectedHostID)
    }

    var parsedArguments: Result<[String], ArgumentError> {
        Self.parseArguments(arguments)
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
        guard let selectedHostID, let kind = selectedAgentKind else { return nil }
        return Self.defaultAgentName(for: kind, taken: existingAgentNames(selectedHostID))
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
        selectedHostID != nil && selectedWorkspaceID != nil
            && nameErrorMessage == nil
            && selectedAgentKind != nil
            && parsedArguments.isSuccess
            && worktreeBranchErrorMessage == nil
            && agentDiscoveryState == .loaded
            && state != .starting
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
            selectedAgentKind = kinds.first
            agentDiscoveryState = .loaded
        } catch is CancellationError {
            guard selectedHostID == hostID else { return }
            agentDiscoveryState = .idle
        } catch {
            guard selectedHostID == hostID else { return }
            agentDiscoveryState = .failed(Self.discoveryMessage(for: error))
        }
    }

    /// Dispatches the command via `agent.start`. Incomplete forms are ignored;
    /// on success the state flips to `.started` for the screen to dismiss.
    func submit() async {
        guard
            !isStarting,
            let hostID = selectedHostID,
            let workspaceID = selectedWorkspaceID,
            let kind = selectedAgentKind,
            case .success(let arguments) = parsedArguments,
            worktreeBranchErrorMessage == nil,
            nameErrorMessage == nil
        else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName =
            trimmedName.isEmpty
            ? Self.defaultAgentName(for: kind, taken: existingAgentNames(hostID))
            : trimmedName
        isStarting = true
        state = .starting
        defer { isStarting = false }
        let request = AgentLaunchRequest(
            kind: kind.rawValue,
            name: agentName,
            arguments: arguments,
            workspaceID: workspaceID)
        let worktree: WorktreeSpec? =
            startsInNewWorktree
            ? WorktreeSpec(
                branch: Self.nonEmptyTrimmed(worktreeBranch),
                base: Self.nonEmptyTrimmed(worktreeBase))
            : nil
        do {
            _ = try await start(request, worktree, hostID)
            recents.remember(workspaceID, for: hostID)
            state = .started
        } catch {
            state = .failed(Self.message(for: error))
        }
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

    /// Reverses the iOS keyboard's smart punctuation, which rewrites
    /// hand-typed shell arguments: `--` becomes an em dash and quotes become
    /// their curly variants, so `--yolo` reaches the agent as a single
    /// garbage argument. The em dash maps back to the `--` that produced it;
    /// curly quotes map to the straight quotes the argument parser
    /// understands.
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

    private static func message(for error: any Error) -> String {
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
        case let apiError as HerdrAPIError:
            "herdr rejected the command: \(apiError.message)"
        default:
            "Starting the agent failed: \(error)"
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
