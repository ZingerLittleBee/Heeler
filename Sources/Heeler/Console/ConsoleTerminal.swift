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
    /// The Tab's label when the user named it. herdr's default label is the
    /// Tab's position, which it renumbers as Tabs close, so a label equal to
    /// the position reads as unnamed, as `ConsoleAgent.showsTabLabel` does.
    var customTabLabel: String? {
        guard let label = nonempty(tabLabel?.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return tabPosition.map { label == String($0) } == true ? nil : label
    }
    /// The Tab as the user named it, else its position, else its id.
    var displayTabTitle: String {
        if let customTabLabel { return "Tab \u{201C}\(customTabLabel)\u{201D}" }
        if let tabPosition { return "Tab \(tabPosition)" }
        return nonempty(tabLabel).map { "Tab \($0)" } ?? "Tab \(tabID)"
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

    /// Terminals search matching: trimmed, case-insensitive substring over what a
    /// Terminals row and its menu show. An empty query matches everything.
    func matchesSearch(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [hostName, workspaceLabel, tabLabel, paneLabel, title, cwd]
            .contains { $0?.range(of: needle, options: .caseInsensitive) != nil }
    }

    private func nonempty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
