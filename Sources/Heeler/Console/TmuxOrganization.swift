import Foundation

/// Fills the Console's snapshot shape from a tmux server's panes (ADR 0043). A
/// session is a Workspace, a window a Tab and a pane a Pane, named and ordered
/// as tmux lists them: Heeler keeps no organization of its own.
///
/// A window that several sessions share, grouped or linked, shows once, under
/// the session with the lowest id, so its Panes and Agents are not doubled.
/// Heeler's own sessions, marked `@heeler-attach`, never show, and neither
/// does the copy of a window they link. A session left with no window of its
/// own to show is not listed. An Agent reads the status `statuses` holds for
/// its Pane, and Unknown without one. A session marked `@heeler-worktree` is
/// that checkout when `checkouts` has named the path.
enum TmuxOrganization {
    struct Result: Sendable {
        let snapshot: SessionSnapshot
        /// The panes shown, each once, in the snapshot's order.
        let panes: [TmuxInventory.Pane]
    }

    static func build(
        _ inventory: TmuxInventory, statuses: [String: AgentStatus] = [:],
        checkouts: [String: HostCheckout] = [:]
    ) -> Result {
        let shown = shownPanes(inventory.panes)

        var workspaceOrder: [String] = []
        var workspaceNames: [String: String] = [:]
        var tabOrder: [String: [String]] = [:]
        var tabOf: [String: TmuxInventory.Pane] = [:]
        var paneCounts: [String: Int] = [:]
        for pane in shown {
            if workspaceNames[pane.sessionID] == nil {
                workspaceNames[pane.sessionID] = pane.sessionName
                workspaceOrder.append(pane.sessionID)
            }
            if tabOf[pane.windowID] == nil {
                tabOf[pane.windowID] = pane
                tabOrder[pane.sessionID, default: []].append(pane.windowID)
            }
            paneCounts[pane.windowID, default: 0] += 1
        }

        var workspaces: [WorkspaceInfo] = []
        var tabs: [TabInfo] = []
        for (position, sessionID) in workspaceOrder.enumerated() {
            let windows = tabOrder[sessionID] ?? []
            let marked = shown.first { $0.sessionID == sessionID && !$0.worktree.isEmpty }?.worktree
            let checkout = marked.flatMap { checkouts[$0] }
            workspaces.append(
                WorkspaceInfo(
                    activeTabID: windows.first ?? "", agentStatus: .unknown, focused: false,
                    label: workspaceNames[sessionID] ?? "", number: position + 1,
                    paneCount: windows.reduce(0) { $0 + (paneCounts[$1] ?? 0) }, tabCount: windows.count,
                    workspaceID: sessionID, worktree: checkout.flatMap(Self.workspaceInfo)))
            for windowID in windows {
                guard let window = tabOf[windowID] else { continue }
                tabs.append(
                    TabInfo(
                        agentStatus: .unknown, focused: false, label: window.windowName,
                        number: window.windowIndex, paneCount: paneCounts[windowID] ?? 0, tabID: windowID,
                        workspaceID: sessionID))
            }
        }

        var panes: [PaneInfo] = []
        var agents: [AgentInfo] = []
        for pane in shown {
            let kind = TmuxAgentRule.agentKind(in: pane)
            let status = kind == nil ? .unknown : statuses[pane.paneID] ?? .unknown
            let directory = pane.path.isEmpty ? nil : pane.path
            panes.append(
                PaneInfo(
                    agentStatus: status, focused: false, paneID: pane.paneID, revision: 0,
                    tabID: pane.windowID, terminalID: pane.paneID, workspaceID: pane.sessionID, agent: kind,
                    cwd: pane.path, foregroundCwd: directory, label: nil, terminalTitle: nil,
                    terminalTitleStripped: nil, title: pane.command.isEmpty ? nil : pane.command))
            if let kind {
                // A pane's title changes on its own and is not listed, so the
                // Agent reads as its program.
                agents.append(
                    AgentInfo(
                        agentStatus: status, focused: false, paneID: pane.paneID, revision: 0,
                        tabID: pane.windowID, terminalID: pane.paneID, workspaceID: pane.sessionID,
                        agent: kind, cwd: pane.path, foregroundCwd: directory, name: nil, terminalTitle: nil,
                        terminalTitleStripped: AgentNotificationIdentity.kindLabel(kind), tokens: [:]))
            }
        }
        return Result(
            snapshot: SessionSnapshot(
                agents: agents, layouts: [], panes: panes, protocolVersion: 0, tabs: tabs, version: "",
                workspaces: workspaces),
            panes: shown)
    }

    /// The main checkout is the repository's identity, as a tmux server has no other.
    private static func workspaceInfo(_ checkout: HostCheckout) -> WorkspaceWorktreeInfo? {
        checkout.mainCheckout.map { mainCheckout in
            WorkspaceWorktreeInfo(
                checkoutPath: checkout.root, isLinkedWorktree: checkout.isLinkedWorktree,
                repoKey: mainCheckout,
                repoName: HerdrCoreWorktrees.repositoryName(mainCheckout: mainCheckout),
                repoRoot: mainCheckout)
        }
    }

    /// The rows the Console shows: none of Heeler's own sessions, each window
    /// under the lowest session id that lists it, and each pane once, where a
    /// session links one window at two indexes.
    private static func shownPanes(_ listed: [TmuxInventory.Pane]) -> [TmuxInventory.Pane] {
        let users = listed.filter { !$0.isInHeelerSession }
        var owners: [String: (number: Int, sessionID: String)] = [:]
        for pane in users {
            let number = sessionNumber(pane.sessionID)
            if let owner = owners[pane.windowID], owner.number <= number { continue }
            owners[pane.windowID] = (number, pane.sessionID)
        }
        var seen: Set<String> = []
        var windowIndexes: [String: Int] = [:]
        return users.filter { pane in
            guard owners[pane.windowID]?.sessionID == pane.sessionID else { return false }
            // The first index a session lists a window at is where it shows.
            guard windowIndexes[pane.windowID, default: pane.windowIndex] == pane.windowIndex else { return false }
            windowIndexes[pane.windowID] = pane.windowIndex
            return seen.insert(pane.paneID).inserted
        }
    }

    /// `$12` is session 12: ids order as numbers, not as text.
    private static func sessionNumber(_ id: String) -> Int {
        Int(id.dropFirst()) ?? Int.max
    }
}
