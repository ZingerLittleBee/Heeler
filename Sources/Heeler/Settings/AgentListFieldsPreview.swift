import SwiftUI

/// Console card for a Host's current rows, driven by the real Agent card.
/// Empty layouts keep Console's Agent-name fallback, not an illustrative
/// "Status only" label. Token fg/bold/dim stay on the shared presentation;
/// `AgentCardView` still uses semantic headline and caption styling.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String

    var body: some View {
        AgentCardView(agent: Self.sampleAgent(hostName: hostName), layout: layout)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRespondsToUserInteraction(false)
    }

    /// Same presentation the Console card uses for this sample.
    static func presentation(layout: AgentRowLayout, hostName: String) -> AgentCardPresentation {
        AgentCardPresentation(agent: sampleAgent(hostName: hostName), layout: layout)
    }

    /// Deterministic sample values for built-in and custom tokens; not a live Agent.
    static func sampleAgent(hostName: String) -> ConsoleAgent {
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
                paneTitle: "claude",
                tokens: ["branch": "feat/sidebar"]),
            workspaceLabel: "heeler",
            repositoryCheckout: nil,
            tabLabel: "1",
            tabPosition: 1,
            workspaceTabCount: 2)
    }

    private static let sampleHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))
}
