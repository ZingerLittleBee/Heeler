/// Builds the Console's rows from one Host's inventory, in the snapshot shape
/// every Server Kind fills (ADR 0032). Where the inventory lists an id twice,
/// its first entry wins.
struct ConsolePaneRowBuilder {
    let host: Host
    let inventory: SessionSnapshot
    let workspaceByID: [String: WorkspaceInfo]

    private let paneByID: [String: PaneInfo]
    private let tabByID: [String: TabInfo]
    private let tabCounts: [String: Int]
    private let tabPositions: [String: Int]
    private let tabPaneIDs: [String: Set<String>]

    init(host: Host, inventory: SessionSnapshot) {
        self.host = host
        self.inventory = inventory
        paneByID = Dictionary(inventory.panes.map { ($0.paneID, $0) }) { first, _ in first }
        workspaceByID = Dictionary(
            inventory.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        tabByID = Dictionary(
            inventory.tabs.map { ($0.tabID, $0) }) { first, _ in first }
        var tabCounts: [String: Int] = [:]
        var tabPositions: [String: Int] = [:]
        for tab in inventory.tabs where tabPositions[tab.tabID] == nil {
            tabCounts[tab.workspaceID, default: 0] += 1
            tabPositions[tab.tabID] = tabCounts[tab.workspaceID]
        }
        var tabPaneIDs: [String: Set<String>] = [:]
        for pane in inventory.panes {
            tabPaneIDs[pane.tabID, default: []].insert(pane.paneID)
        }
        for agent in inventory.agents {
            tabPaneIDs[agent.tabID, default: []].insert(agent.paneID)
        }
        self.tabCounts = tabCounts
        self.tabPositions = tabPositions
        self.tabPaneIDs = tabPaneIDs
    }

    /// One row per listed Agent, keyed by Pane. `lastOutputSnippet` carries a
    /// row's snippet over from before this inventory. `liveChange` is a Pane
    /// value observed while the inventory was on its way, newer than it, even
    /// when the inventory has no Terminal entry for that Pane.
    func agentRows(
        lastOutputSnippet: (String) -> String?,
        liveChange: (String) -> PaneInfo?
    ) -> [String: ConsoleAgent] {
        var rows: [String: ConsoleAgent] = [:]
        for (snapshotOrder, info) in inventory.agents.enumerated() {
            let agent = Agent(info)
            let workspace = workspaceByID[agent.workspaceID]
            let tab = tabByID[agent.tabID].flatMap {
                $0.workspaceID == agent.workspaceID ? $0 : nil
            }
            var row = ConsoleAgent(
                hostID: host.id,
                hostName: host.displayName,
                agent: agent,
                workspaceLabel: workspace?.label,
                repositoryCheckout: workspace?.worktree.map(RepositoryCheckout.init),
                lastOutputSnippet: lastOutputSnippet(agent.paneID),
                hostUsername: host.username,
                tabLabel: tab?.label,
                tabPosition: tab.flatMap { tabPositions[$0.tabID] },
                workspaceTabCount: max(workspace?.tabCount ?? 0, tabCounts[agent.workspaceID] ?? 0),
                tabPaneCount: max(tab?.paneCount ?? 0, tabPaneIDs[agent.tabID]?.count ?? 0),
                snapshotOrder: snapshotOrder,
                paneLabel: paneByID[agent.paneID].flatMap {
                    $0.tabID == agent.tabID && $0.workspaceID == agent.workspaceID ? $0.label : nil
                })
            if let pane = paneByID[agent.paneID] {
                row.updateDirectory(from: pane)
            }
            if let change = liveChange(agent.paneID) {
                row.updateDirectory(from: change)
            }
            rows[agent.paneID] = row
        }
        return rows
    }

    /// One row per listed Pane, keyed by Pane. `agents` names the Panes that
    /// hold an Agent. A live change applies only while it still describes the
    /// same Terminal in the same Tab.
    func terminalRows(
        agents: [String: ConsoleAgent],
        liveChange: (String) -> PaneInfo?
    ) -> [String: ConsoleTerminal] {
        let workspacePositions = Dictionary(
            inventory.workspaces.enumerated().map { ($0.element.workspaceID, $0.offset) }
        ) { first, _ in first }
        var rows: [String: ConsoleTerminal] = [:]
        for (order, listedPane) in inventory.panes.enumerated() {
            let pane: PaneInfo
            if let change = liveChange(listedPane.paneID),
                change.terminalID == listedPane.terminalID,
                change.workspaceID == listedPane.workspaceID,
                change.tabID == listedPane.tabID
            {
                pane = change
            } else {
                pane = listedPane
            }
            let tab = tabByID[pane.tabID].flatMap {
                $0.workspaceID == pane.workspaceID ? $0 : nil
            }
            rows[pane.paneID] = ConsoleTerminal(
                hostID: host.id, hostName: host.displayName, hostUsername: host.username,
                pane: pane, workspaceLabel: workspaceByID[pane.workspaceID]?.label,
                tabLabel: tab?.label,
                workspaceOrder: workspacePositions[pane.workspaceID] ?? Int.max,
                tabPosition: tab.flatMap { tabPositions[$0.tabID] }, snapshotOrder: order,
                snapshotAgentKind: agents[pane.paneID]?.agent.kind)
        }
        return rows
    }

    /// The Workspaces by label, each keeping its listed position as `order`.
    func workspaceRows() -> [ConsoleWorkspace] {
        inventory.workspaces.enumerated()
            .map { order, workspace in
                ConsoleWorkspace(
                    id: workspace.workspaceID, label: workspace.label, order: order,
                    checkoutPath: workspace.worktree?.checkoutPath)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
