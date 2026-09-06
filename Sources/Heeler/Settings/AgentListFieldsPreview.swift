import SwiftUI

/// Compact Console preview body for a Host's current rows.
///
/// Reuses `AgentCardPresentation` / `AgentRowRenderer` so resolved text and
/// the empty-layout Agent-name fallback stay truthful. The Host section owns
/// the strip label, tint, and padding; this view does not draw Agent card
/// chrome (Idle badge, Host footer) or a Section of its own.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String

    var body: some View {
        let presentation = Self.presentation(layout: layout, hostName: hostName)
        let agent = Self.sampleAgent(hostName: hostName)
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color(agent.agent.status.inkUIColor))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: presentation.headline)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                ForEach(Array(presentation.additionalRows.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
