import Foundation

/// Fills the Console's snapshot shape from a Rex server's inventory (ADR 0050).
/// A session is a Workspace, a window a Tab and a terminal block a Pane, named
/// and ordered as Rex lists them: Heeler keeps no organization of its own. A
/// session's detached terminals, in none of its windows, share one Tab of
/// their own after its windows. A terminal whose foreground is a known agent
/// program is an Agent too, with the status `RexAgentRule` reads (ADR 0054),
/// Done where this device has not seen the turn it finished.
enum RexOrganization {
    /// The Tab a session's detached terminals share. Its id cannot be a
    /// window's, which Rex never writes with a `/`.
    static func detachedTabID(ofSession sessionID: String) -> String {
        "\(sessionID)/detached"
    }

    /// `doneTerminals` are the panes whose Agent finished a turn this device
    /// has not seen (`RexTurnState`); one reads Done while it reads Idle.
    static func build(_ inventory: RexInventory, doneTerminals: Set<String> = []) -> SessionSnapshot {
        var workspaces: [WorkspaceInfo] = []
        var tabs: [TabInfo] = []
        var panes: [PaneInfo] = []
        var agents: [AgentInfo] = []
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
                    let kind = RexAgentRule.agentKind(in: details)
                    var status = kind.map { RexAgentRule.status(of: details, heldBy: $0) } ?? .unknown
                    if status == .idle, doneTerminals.contains(paneID) { status = .done }
                    panes.append(
                        PaneInfo(
                            agentStatus: status, focused: false, paneID: paneID, revision: 0, tabID: tab.id,
                            terminalID: paneID, workspaceID: session.id, agent: kind, cwd: details.directory,
                            foregroundCwd: details.directory, label: terminal.label,
                            terminalTitle: details.title, terminalTitleStripped: details.title,
                            title: details.program))
                    if let kind {
                        agents.append(
                            agentInfo(
                                terminal, kind: kind, status: status, paneID: paneID, tabID: tab.id,
                                workspaceID: session.id))
                    }
                }
            }
        }
        return SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 0, tabs: tabs, version: "",
            workspaces: workspaces)
    }

    /// An Agent reads as its terminal's title, or before the program sets one
    /// as its kind, and is named as its block is, as a herdr-core Agent is.
    /// Its directory is where its program runs.
    private static func agentInfo(
        _ terminal: RexInventory.Terminal, kind: String, status: AgentStatus, paneID: String, tabID: String,
        workspaceID: String
    ) -> AgentInfo {
        let details = terminal.details
        let stripped = details.title.map(TerminalTitleGlyphs.strip).flatMap { $0.isEmpty ? nil : $0 }
        return AgentInfo(
            agentStatus: status, focused: false, paneID: paneID, revision: 0, tabID: tabID, terminalID: paneID,
            workspaceID: workspaceID, agent: kind, cwd: details.directory, foregroundCwd: details.directory,
            name: terminal.label, terminalTitle: details.title,
            terminalTitleStripped: stripped ?? AgentNotificationIdentity.kindLabel(kind), tokens: [:])
    }
}
