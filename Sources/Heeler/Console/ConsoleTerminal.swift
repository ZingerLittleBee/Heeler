import Foundation

/// A terminal Pane joined with its Host, Workspace and Tab from the current
/// session snapshot. Includes Agent panes so each surface can choose its scope.
struct ConsoleTerminal: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
    }

    let hostID: Host.ID
    let hostName: String
    let hostUsername: String?
    var pane: PaneInfo
    let workspaceLabel: String?
    let tabLabel: String?
    let workspaceOrder: Int
    let tabPosition: Int?
    let snapshotOrder: Int
    let snapshotAgentKind: String?

    var id: ID { ID(hostID: hostID, paneID: paneID) }
    var paneID: String { pane.paneID }
    var terminalID: String { pane.terminalID }
    var workspaceID: String { pane.workspaceID }
    var tabID: String { pane.tabID }
    var paneLabel: String? { pane.label }
    var agentKind: String? { nonempty(pane.agent) ?? nonempty(snapshotAgentKind) }
    var isAgent: Bool { snapshotAgentKind != nil || agentKind != nil }
    var agentID: ConsoleAgent.ID? {
        isAgent ? ConsoleAgent.ID(hostID: hostID, paneID: paneID) : nil
    }
    var title: String? {
        nonempty(pane.terminalTitleStripped) ?? nonempty(pane.title)
    }
    var displayTitle: String {
        nonempty(paneLabel) ?? title ?? nonempty(tabLabel) ?? "Terminal"
    }
    /// Foreground cwd follows `cd`; launch cwd remains the fallback.
    var cwd: String { nonempty(pane.foregroundCwd) ?? nonempty(pane.cwd) ?? "" }
    var displayCwd: String {
        guard let hostUsername, !hostUsername.isEmpty else { return cwd }
        let homes =
            hostUsername == "root"
            ? ["/root"] : ["/Users/\(hostUsername)", "/home/\(hostUsername)"]
        guard let home = homes.first(where: { cwd == $0 || cwd.hasPrefix("\($0)/") })
        else { return cwd }
        return cwd == home ? "~" : "~\(cwd.dropFirst(home.count))"
    }

    func matchesSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [hostName, workspaceLabel, tabLabel, paneLabel, title, cwd, agentKind]
            .contains { $0?.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
