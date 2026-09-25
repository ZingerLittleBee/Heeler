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

    /// A plain shell tab projected as a row (`Agent.isShell`). Everything
    /// keyed on a ConsoleAgent — rows, pins, moves, close, switcher — applies
    /// to it unchanged; only Agent-only API calls are gated on this.
    var isShell: Bool { agent.isShell }

    /// What an Attach resolves for this row. `agent attach` refuses a pane
    /// with no Agent, so a shell attaches by terminal id (ADR 0015).
    var attachTarget: TerminalAttachTarget {
        isShell ? .terminal(agent.terminalID) : .agentPane(agent.paneID)
    }

    /// The one Agent whose session file `AgentSessionUsage` knows how to
    /// fold. Another Agent that came to report a path would only have its
    /// file downloaded and parsed for nothing.
    static let sessionFileAgent = "omp"

    /// The Agent's own session transcript on the Host, when herdr reports one
    /// by path for `sessionFileAgent` (#325). A reference herdr resolves
    /// itself carries no path to read, so those stay nil rather than being
    /// guessed at.
    var sessionFilePath: String? {
        guard
            let session = agent.agentSession, session.kind == .path,
            session.agent == Self.sessionFileAgent
        else { return nil }
        return session.value.isEmpty ? nil : session.value
    }

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

    /// Client-side Agents search (#292): a trimmed, case-insensitive
    /// substring match over the working directory and the title/visible
    /// text. An empty query matches every agent.
    func matchesAgentSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let candidates: [String?] = [
            agent.cwd,
            workspaceLabel,
            tabLabel,
            paneLabel,
            agent.title,
            agent.paneTitle,
            agent.displayName,
            agent.terminalTitle,
            agent.terminalTitleStripped,
        ]
        return candidates.contains {
            guard let field = $0, !field.isEmpty else { return false }
            return field.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    /// The launch directory as a Console row should print it. The snapshot
    /// carries the expanded remote path but not `$HOME`, so only the
    /// account's conventional macOS/Linux homes are shortened to `~`; every
    /// other path stays exactly as the Agent reported it.
    var displayCwd: String {
        guard let hostUsername, !hostUsername.isEmpty else { return agent.cwd }
        let homes =
            hostUsername == "root"
            ? ["/root"]
            : ["/Users/\(hostUsername)", "/home/\(hostUsername)"]
        guard let home = homes.first(where: { agent.cwd == $0 || agent.cwd.hasPrefix("\($0)/") })
        else { return agent.cwd }
        return agent.cwd == home ? "~" : "~\(agent.cwd.dropFirst(home.count))"
    }
}

extension Agent {
    /// A plain shell pane as a Console row's Agent (`Agent.shellKind`). It
    /// carries the pane's own identity — terminal, pane, tab, Workspace —
    /// and its terminal title. The cwd follows the shell's `cd`, falling
    /// back to its launch directory. Status is `.shellTerminal`: neutral,
    /// presentation only, in the bottom sort bucket.
    init(shellPane pane: PaneInfo, name: String?) {
        let foregroundCwd = pane.foregroundCwd.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            terminalID: pane.terminalID,
            kind: Agent.shellKind,
            title: TerminalTitleGlyphs.strip(
                pane.terminalTitleStripped ?? pane.terminalTitle ?? ""),
            status: .shellTerminal,
            workspaceID: pane.workspaceID,
            tabID: pane.tabID,
            paneID: pane.paneID,
            cwd: foregroundCwd ?? pane.cwd ?? "",
            revision: pane.revision,
            name: name,
            terminalTitle: pane.terminalTitle,
            terminalTitleStripped: pane.terminalTitleStripped,
            paneTitle: pane.title)
    }
}

extension ConsoleAgent {
    /// A shell must open in a directory tied to the selected row. A missing
    /// directory disables Open Terminal and New Terminal instead of letting
    /// herdr inherit some other focused Pane's cwd.
    var shellTerminalCreationRequest: ShellTerminalCreationRequest? {
        if Self.isAbsoluteNonEmptyPath(agent.cwd) {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: agent.cwd)
        }
        if isLinkedWorktree,
            let checkoutPath,
            Self.isAbsoluteNonEmptyPath(checkoutPath)
        {
            return ShellTerminalCreationRequest(
                workspaceID: agent.workspaceID,
                cwd: checkoutPath)
        }
        return nil
    }

    private static func isAbsoluteNonEmptyPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// The workspace's git checkout identity from the snapshot, when reported.
    /// Linked worktrees share their repo's `repoKey` with the main checkout's
    /// workspace, which is how the index nests them under it (herdr's sidebar
    /// grouping).
    let checkout: RepositoryCheckout?

    init(id: String, label: String, checkout: RepositoryCheckout? = nil) {
        self.id = id
        self.label = label
        self.checkout = checkout
    }
}

extension AgentStatus {
    /// Console sort bucket: Blocked > Working > Done > Idle. Blocked has
    /// stopped and is waiting on the user's reply, Working is producing one,
    /// Done has a result waiting to be read, and Idle asks for nothing. The
    /// order tracks how soon each status needs the user, so an agent waiting
    /// on a reply always outranks one that is merely busy. Unknown and any
    /// status this build does not recognize (herdr's API has no stability
    /// guarantee) share the bottom bucket — a status we cannot interpret is
    /// not actionable, so it must not outrank one we can.
    var consoleSortBucket: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        default: 4
        }
    }
}

extension [ConsoleAgent] {
    /// The rows with an Agent Status: everything but projected shells.
    /// Status-driven surfaces — notifications, Live Activities, Host status
    /// counts — read this; row surfaces read every row.
    var excludingShells: [ConsoleAgent] { filter { !$0.isShell } }

    /// Pins always lead by recency. Every Host shares one default attention
    /// order: Blocked > Working > Done > Idle buckets, newest activity first
    /// inside each bucket (the `stateChangeSeq` comment at the comparator).
    /// A Host whose plugin snapshot asks for `spaces` keeps that order
    /// instead of the buckets. Space order uses stable Host blocks even in
    /// the flat presentation.
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
            // Recency inside a bucket is `stateChangeSeq`, newest first: the
            // highest monotonic counter herdr exposes on an Agent, and the
            // only one updated by status events. Comparisons reach this line
            // only after Host name and id tie, so the counter is compared
            // within its one Host. Hosts without a plugin snapshot get the
            // same default as `.priority` Hosts (previously they fell
            // straight to workspace/pane ties); a plugin's own
            // `snapshotOrder` then only refines ties for Hosts that publish
            // a sidebar snapshot.
            if policy == .priority {
                let lhsSequence = lhs.agent.stateChangeSeq ?? 0
                let rhsSequence = rhs.agent.stateChangeSeq ?? 0
                if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            }
            if sortByHost[lhs.hostID] != nil {
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
