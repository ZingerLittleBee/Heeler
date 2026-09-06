import SwiftUI

/// Console card for a Host's current rows, driven by the real Agent card.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String

    var body: some View {
        AgentCardView(agent: Self.sampleAgent(hostName: hostName), layout: layout)
    }

    /// Deterministic sample values for the built-in tokens; not a live Agent.
    private static func sampleAgent(hostName: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: sampleHostID,
            hostName: hostName,
            agent: Agent(
                terminalID: "preview-terminal",
                kind: "claude",
                title: "fix sidebar sync",
                status: .idle,
                workspaceID: "preview-workspace",
                tabID: "preview-tab",
                paneID: "preview-pane",
                cwd: "/work/heeler",
                revision: 1,
                name: "claude",
                terminalTitle: "fix sidebar sync",
                terminalTitleStripped: "fix sidebar sync",
                paneTitle: "claude"),
            workspaceLabel: "heeler",
            repositoryCheckout: nil,
            tabLabel: "1",
            tabPosition: 1,
            workspaceTabCount: 1)
    }

    private static let sampleHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))
}
