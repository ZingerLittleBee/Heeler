import CryptoKit
import Foundation

/// Fills the Console's snapshot shape from a core's Terminals (ADR 0032). A
/// core has no Workspaces or Tabs, so each Terminal lands in a derived Workspace
/// keyed by the directory this device first saw it launched in, as its own Tab.
/// That directory, not the Terminal's current launch directory, is the key: a
/// kept Terminal that restarts elsewhere stays where it is.
enum HerdrCoreOrganization {
    /// Finished Terminals stay out of the snapshot, though the core keeps
    /// their records until they are removed.
    static func snapshot(
        terminals: [HerdrCoreTerminalRecord], firstSeenDirectories: [String: String]
    ) -> SessionSnapshot {
        var workspaces: [WorkspaceInfo] = []
        var tabs: [TabInfo] = []
        var panes: [PaneInfo] = []
        let shown = terminals.filter { !$0.hasFinished }
        // By first appearance, so the Workspaces' order is stable as Terminals come and go.
        var directories: [String] = []
        for record in shown {
            let directory = firstSeenDirectories[record.address] ?? record.cwd
            if !directories.contains(directory) { directories.append(directory) }
        }
        for (position, directory) in directories.enumerated() {
            let workspaceID = workspaceID(directory: directory)
            let members = shown.filter {
                (firstSeenDirectories[$0.address] ?? $0.cwd) == directory
            }
            for (tabPosition, record) in members.enumerated() {
                let tabID = "tab-\(record.address)"
                tabs.append(
                    TabInfo(
                        agentStatus: .unknown, focused: false, label: "", number: tabPosition + 1,
                        paneCount: 1, tabID: tabID, workspaceID: workspaceID))
                panes.append(pane(record, tabID: tabID, workspaceID: workspaceID))
            }
            workspaces.append(
                WorkspaceInfo(
                    activeTabID: members.first.map { "tab-\($0.address)" } ?? "",
                    agentStatus: .unknown, focused: false, label: label(directory: directory),
                    number: position + 1, paneCount: members.count, tabCount: members.count,
                    workspaceID: workspaceID))
        }
        return SessionSnapshot(
            agents: [], layouts: [], panes: panes, protocolVersion: 0, tabs: tabs, version: "",
            workspaces: workspaces)
    }

    /// Stable and opaque: the same directory is the same Workspace on every
    /// reconnect and relaunch.
    static func workspaceID(directory: String) -> String {
        let digest = SHA256.hash(data: Data(directory.utf8))
        return "d-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func label(directory: String) -> String {
        directory.isEmpty ? "No directory" : (directory as NSString).lastPathComponent
    }

    private static func pane(
        _ record: HerdrCoreTerminalRecord, tabID: String, workspaceID: String
    ) -> PaneInfo {
        let terminalTitle = record.title.isEmpty ? nil : record.title
        return PaneInfo(
            agentStatus: .unknown, focused: false, paneID: record.address, revision: 0, tabID: tabID,
            terminalID: record.address, workspaceID: workspaceID, cwd: record.cwd,
            foregroundCwd: record.foreground?.cwd, label: record.name,
            terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitle.map(TerminalTitleGlyphs.strip),
            title: programName(record))
    }

    /// What runs in the Terminal now, else what it launched.
    private static func programName(_ record: HerdrCoreTerminalRecord) -> String? {
        if let foreground = record.foreground?.name, !foreground.isEmpty { return foreground }
        return record.argv.first.map { ($0 as NSString).lastPathComponent }
    }
}
