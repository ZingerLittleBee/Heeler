import Foundation

/// One row of the Console (#8): an Agent joined with its Host identity and
/// workspace context. The list is flat across Hosts; the workspace is a
/// context tag only, never a grouping level.
struct ConsoleAgent: Identifiable, Sendable, Equatable {
    /// Pane addresses are unique per herdr session, not across Hosts; the
    /// row identity pairs them.
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
    }

    let hostID: Host.ID
    let hostName: String
    var agent: Agent
    /// Workspace label from the session snapshot; nil when the snapshot did
    /// not carry the workspace.
    let workspaceLabel: String?
    /// Worktree repo name where the workspace has one — sharper context than
    /// a raw checkout path.
    let repoName: String?
    /// Worktree checkout path where the workspace has one: the directory
    /// whose files the agent actually sees, which for a linked worktree is
    /// the checkout rather than the main repository root.
    let checkoutPath: String?
    /// Trailing terminal output (`pane.read`, ANSI stripped), fetched after
    /// snapshots and status changes; nil until the first read lands.
    var lastOutputSnippet: String?

    var id: ID { ID(hostID: hostID, paneID: agent.paneID) }

    init(
        hostID: Host.ID,
        hostName: String,
        agent: Agent,
        workspaceLabel: String?,
        repoName: String?,
        checkoutPath: String? = nil,
        lastOutputSnippet: String? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.agent = agent
        self.workspaceLabel = workspaceLabel
        self.repoName = repoName
        self.checkoutPath = checkoutPath
        self.lastOutputSnippet = lastOutputSnippet
    }

    /// The keyboard switcher's chip label. The project leads, as it does on
    /// the card, but without the card's `label · repo` pairing: a chip has
    /// room for one word, and a console full of `claude` is told apart by
    /// where each one is working.
    var switcherLabel: String {
        workspaceLabel ?? repoName ?? agent.displayName
    }

    /// The directory the skills probe treats as the agent's project root:
    /// the worktree checkout when the workspace has one, else the agent's
    /// launch cwd. Deliberately not the live foreground cwd — agents load
    /// project skills from where they started.
    var skillsProjectRoot: String? {
        if let checkoutPath, !checkoutPath.isEmpty { return checkoutPath }
        return agent.cwd.isEmpty ? nil : agent.cwd
    }
}

/// A workspace known for a Host from its latest session snapshot, offered as
/// a target in the new-agent flow (#12). Identity is herdr's opaque
/// `workspace_id`; the label is what the picker shows.
struct ConsoleWorkspace: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}

extension AgentStatus {
    /// Console sort bucket: Blocked > Done > Working > Idle. The order tracks
    /// how much of the user's attention each status is asking for — Blocked
    /// has stopped and is waiting on an answer, Done has a result to read,
    /// Working needs nothing, Idle least of all. Unknown and any status this
    /// build does not recognize (herdr's API has no stability guarantee)
    /// share the bottom bucket — a status we cannot interpret is not
    /// actionable, so it must not outrank one we can.
    var consoleSortBucket: Int {
        switch self {
        case .blocked: 0
        case .done: 1
        case .working: 2
        case .idle: 3
        default: 4
        }
    }
}

extension [ConsoleAgent] {
    /// The Console order: status bucket first, then stable Host/workspace/
    /// pane keys so rows never jitter between equal statuses.
    func consoleSorted() -> [ConsoleAgent] {
        sorted { lhs, rhs in
            let lhsBucket = lhs.agent.status.consoleSortBucket
            let rhsBucket = rhs.agent.status.consoleSortBucket
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            let lhsWorkspace = lhs.workspaceLabel ?? ""
            let rhsWorkspace = rhs.workspaceLabel ?? ""
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            return lhs.agent.paneID < rhs.agent.paneID
        }
    }
}
