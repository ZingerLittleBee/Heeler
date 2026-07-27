import Foundation
import Observation

/// The new-agent flow's form logic (#12, User Story 8): pick a Host, pick a
/// workspace (or the Host's current one), type a command, and dispatch it via
/// the Transport launch flow. The started pane surfaces in the Console through the store's
/// normal snapshot/delta machinery — this screen only fires the RPC and
/// reports its outcome.
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

    /// The Hosts the user can dispatch to — the Host picker's options.
    let hosts: [Host]

    var selectedHostID: Host.ID? {
        didSet {
            // A workspace belongs to one Host; switching Hosts drops a stale
            // pick so it can never target the wrong session.
            if selectedHostID != oldValue { pickedWorkspaceID = nil }
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
    /// The unique live-agent name required by herdr protocol 17.
    var name: String = ""
    /// The command line, tokenized into argv on submit.
    var command: String = ""

    private(set) var state: State = .editing

    private let workspacesProvider: (Host.ID) -> [ConsoleWorkspace]
    private let start: (AgentLaunchRequest, Host.ID) async throws -> Agent
    @ObservationIgnored private let recents: RecentWorkspaceStore
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot dispatch the same command twice through the window
    /// before `state == .starting` disables the button.
    private var isStarting = false

    init(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        start: @escaping (AgentLaunchRequest, Host.ID) async throws -> Agent,
        recents: RecentWorkspaceStore = RecentWorkspaceStore()
    ) {
        self.hosts = hosts
        self.workspacesProvider = workspaces
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

    /// The command split into an agent kind followed by native arguments.
    var argv: [String] {
        Self.tokenize(command)
    }

    /// Whether the form is complete enough to dispatch.
    var canSubmit: Bool {
        selectedHostID != nil && selectedWorkspaceID != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !argv.isEmpty && state != .starting
    }

    /// Whether the sheet may be dismissed without abandoning an in-flight
    /// launch whose server-side outcome may already be committed.
    var canDismiss: Bool {
        state != .starting
    }

    /// Dispatches the command via `agent.start`. Incomplete forms are ignored;
    /// on success the state flips to `.started` for the screen to dismiss.
    func submit() async {
        guard
            !isStarting,
            let hostID = selectedHostID,
            let workspaceID = selectedWorkspaceID
        else { return }
        let tokens = argv
        guard let kind = tokens.first else { return }
        let agentName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agentName.isEmpty else { return }
        isStarting = true
        state = .starting
        defer { isStarting = false }
        let request = AgentLaunchRequest(
            kind: kind,
            name: agentName,
            arguments: Array(tokens.dropFirst()),
            workspaceID: workspaceID)
        do {
            _ = try await start(request, hostID)
            recents.remember(workspaceID, for: hostID)
            state = .started
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Splits a command line into argv on whitespace. Deliberately simple —
    /// no quote or escape handling; a command needing shell quoting is an
    /// edge the Attach terminal covers.
    static func tokenize(_ command: String) -> [String] {
        command.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let apiError as HerdrAPIError:
            "herdr rejected the command: \(apiError.message)"
        default:
            "Starting the agent failed: \(error)"
        }
    }
}
