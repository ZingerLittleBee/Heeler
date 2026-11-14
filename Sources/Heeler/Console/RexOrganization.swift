import Foundation

/// Fills the Console's snapshot shape from a Rex server's inventory (ADR 0048).
/// A session is a Workspace, a window a Tab and a terminal block a Pane, named
/// and ordered as Rex lists them: Heeler keeps no organization of its own. A
/// session's detached terminals, in none of its windows, share one Tab of
/// their own after its windows. Every Pane is a Terminal: a Rex Host reports
/// no Agents.
enum RexOrganization {
    /// The Tab a session's detached terminals share. Its id cannot be a
    /// window's, which Rex never writes with a `/`.
    static func detachedTabID(ofSession sessionID: String) -> String {
        "\(sessionID)/detached"
    }

    static func build(_ inventory: RexInventory) -> SessionSnapshot {
        var workspaces: [WorkspaceInfo] = []
        var tabs: [TabInfo] = []
        var panes: [PaneInfo] = []
        for (position, session) in inventory.sessions.enumerated() {
            var sessionTabs: [(id: String, label: String, terminals: [RexInventory.Terminal])] = session.windows.map {
                ($0.id, $0.label ?? "", $0.terminals)
            }
            if !session.detached.isEmpty {
                sessionTabs.append(
                    (detachedTabID(ofSession: session.id), String(localized: "Detached"), session.detached))
            }
            workspaces.append(
                WorkspaceInfo(
                    activeTabID: session.activeWindowID ?? sessionTabs.first?.id ?? "", agentStatus: .unknown,
                    focused: false, label: session.label, number: position + 1,
                    paneCount: session.terminals.count, tabCount: sessionTabs.count, workspaceID: session.id,
                    worktree: nil))
            for (number, tab) in sessionTabs.enumerated() {
                tabs.append(
                    TabInfo(
                        agentStatus: .unknown, focused: false, label: tab.label, number: number + 1,
                        paneCount: tab.terminals.count, tabID: tab.id, workspaceID: session.id))
                for terminal in tab.terminals {
                    let paneID = RexPaneAddress(sessionID: session.id, blockID: terminal.blockID).paneID
                    let details = terminal.details
                    panes.append(
                        PaneInfo(
                            agentStatus: .unknown, focused: false, paneID: paneID, revision: 0, tabID: tab.id,
                            terminalID: paneID, workspaceID: session.id, agent: nil, cwd: details.directory,
                            foregroundCwd: details.directory, label: terminal.label,
                            terminalTitle: details.title, terminalTitleStripped: details.title,
                            title: details.program))
                }
            }
        }
        return SessionSnapshot(
            agents: [], layouts: [], panes: panes, protocolVersion: 0, tabs: tabs, version: "",
            workspaces: workspaces)
    }
}
