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
    /// SSH account name, used only for conservative presentation of standard
    /// macOS/Linux home paths as `~`. The actual remote path stays unchanged.
    let hostUsername: String?
    var agent: Agent
    /// Workspace label from the session snapshot; nil when the snapshot did
    /// not carry the workspace.
    let workspaceLabel: String?
    let tabLabel: String?
    let paneLabel: String?
    /// One-based position within the snapshot's workspace tabs. herdr's
    /// automatic label uses position, not TabInfo.number's stable identity.
    let tabPosition: Int?
    let workspaceTabCount: Int
    /// Collection order from session.snapshot.agents for the `spaces` sort.
    let snapshotOrder: Int?
    /// Snapshot git metadata when the workspace reported any. Presence does
    /// not mean this is removable: the main checkout is reported with
    /// `isLinkedWorktree == false` too.
    let repositoryCheckout: RepositoryCheckout?
    /// Trailing terminal output (`pane.read`, ANSI stripped), fetched after
    /// snapshots and status changes; nil until the first read lands.
    var lastOutputSnippet: String?

    var id: ID { ID(hostID: hostID, paneID: agent.paneID) }

    init(
        hostID: Host.ID,
        hostName: String,
        agent: Agent,
        workspaceLabel: String?,
        repositoryCheckout: RepositoryCheckout?,
        lastOutputSnippet: String? = nil,
        hostUsername: String? = nil,
        tabLabel: String? = nil,
        tabPosition: Int? = nil,
        workspaceTabCount: Int = 0,
        snapshotOrder: Int? = nil,
        paneLabel: String? = nil
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostUsername = hostUsername
        self.agent = agent
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
        self.paneLabel = paneLabel
        self.tabPosition = tabPosition
        self.workspaceTabCount = workspaceTabCount
        self.snapshotOrder = snapshotOrder
        self.repositoryCheckout = repositoryCheckout
        self.lastOutputSnippet = lastOutputSnippet
    }

    var repoName: String? { repositoryCheckout?.repoName }

    /// Protocol 20 has no custom-name bit. A manual name equal to the
    /// automatic position cannot be distinguished from an automatic name.
    var showsTabLabel: Bool {
        guard let tabLabel, !tabLabel.isEmpty else { return false }
        if workspaceTabCount > 1 { return true }
        guard let tabPosition else { return true }
        return tabLabel != String(tabPosition)
    }

    var checkoutPath: String? { repositoryCheckout?.checkoutPath }

    /// Console badge and destructive-action eligibility come only from the
    /// latest session snapshot's explicit linkage bit.
    var isLinkedWorktree: Bool { repositoryCheckout?.isLinkedWorktree == true }

    var workspaceContext: String? {
        switch (workspaceLabel, repoName) {
        case (nil, nil): nil
        case (let label?, nil): label
        case (nil, let repo?): repo
        case (let label?, let repo?): label == repo ? label : "\(label) · \(repo)"
        }
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

/// The snapshot's exact git checkout identity for one workspace. Workspace
/// ids are reusable slots, so destructive actions match this tuple too.
struct RepositoryCheckout: Sendable, Equatable, Hashable {
    let repoKey: String
    let repoName: String
    let repoRoot: String
    let checkoutPath: String
    let isLinkedWorktree: Bool

    init(
        repoKey: String,
        repoName: String,
        repoRoot: String,
        checkoutPath: String,
        isLinkedWorktree: Bool
    ) {
        self.repoKey = repoKey
        self.repoName = repoName
        self.repoRoot = repoRoot
        self.checkoutPath = checkoutPath
        self.isLinkedWorktree = isLinkedWorktree
    }

    init(_ info: WorkspaceWorktreeInfo) {
        self.init(
            repoKey: info.repoKey,
            repoName: info.repoName,
            repoRoot: info.repoRoot,
            checkoutPath: info.checkoutPath,
            isLinkedWorktree: info.isLinkedWorktree)
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
    /// Pins always lead by recency. Snapshot policy controls each Host's
    /// remaining Agents; absent snapshots retain the legacy priority order.
    /// Space order uses stable Host blocks even in the flat presentation.
    func consoleSorted(
        sortByHost: [Host.ID: AgentPanelSort] = [:],
        pinRank: (ConsoleAgent) -> Int? = { _ in nil }
    ) -> [ConsoleAgent] {
        // Space order is meaningful only within a Host. If any Host uses it,
        // compare Host identities before local policy; selecting a comparator
        // from just one operand would violate transitivity across mixed Hosts.
        let usesSpaceOrder = contains { sortByHost[$0.hostID] == .spaces }
        return sorted { lhs, rhs in
            let lhsRank = pinRank(lhs)
            let rhsRank = pinRank(rhs)
            switch (lhsRank, rhsRank) {
            case (let lhsRank?, let rhsRank?):
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            if usesSpaceOrder && lhs.hostID != rhs.hostID {
                if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            let policy = sortByHost[lhs.hostID] ?? .priority
            if !usesSpaceOrder || policy == .priority {
                let lhsBucket = lhs.agent.status.consoleSortBucket
                let rhsBucket = rhs.agent.status.consoleSortBucket
                if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            if sortByHost[lhs.hostID] != nil {
                // State sequences are comparable only within their Host.
                if policy == .priority {
                    let lhsSequence = lhs.agent.stateChangeSeq ?? 0
                    let rhsSequence = rhs.agent.stateChangeSeq ?? 0
                    if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
                }
                let lhsOrder = lhs.snapshotOrder ?? Int.max
                let rhsOrder = rhs.snapshotOrder ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            }
            let lhsWorkspace = lhs.workspaceLabel ?? ""
            let rhsWorkspace = rhs.workspaceLabel ?? ""
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            return lhs.agent.paneID < rhs.agent.paneID
        }
    }
}
