import SwiftUI
import UIKit

/// One Console card (#8): the project and status up front, Host, agent kind,
/// and pane address as context, plus the last-output snippet. The project
/// leads because a console full of agents is usually a console full of
/// `claude` — the workspace is what tells the rows apart.
struct AgentCardView: View {
    let agent: ConsoleAgent
    var isPinned: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: 8)
                AgentStatusBadge(status: agent.agent.status)
            }
            if !agent.agent.title.isEmpty {
                Text(agent.agent.title)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            if let snippet = agent.lastOutputSnippet {
                Text(snippet)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                if agent.isLinkedWorktree {
                    Label("Worktree", systemImage: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("Linked worktree")
                }
                if let kind = agentKindTag {
                    Text(kind)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(agent.agent.paneID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(agent.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// The card's lead line: the project the agent works in, falling back to
    /// the agent's own name when the snapshot carried no workspace.
    private var headline: String {
        workspaceContext ?? agent.agent.displayName
    }

    /// The agent name, tagged at the foot of the card — dropped when the
    /// headline already fell back to it.
    private var agentKindTag: String? {
        workspaceContext == nil ? nil : agent.agent.displayName
    }

    /// The workspace context: label, with the worktree repo when it adds
    /// information the label does not already carry.
    private var workspaceContext: String? {
        agent.workspaceContext
    }
}

/// Status rendered as a tinted capsule; Blocked gets the loudest color
/// because it is the one asking for the user. Working keeps a live solving
/// orb inside the capsule — a still badge cannot tell a busy Agent from a
/// finished one at a glance.
struct AgentStatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 12)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(status.tintUIColor).opacity(0.15), in: Capsule())
        .foregroundStyle(Color(status.inkUIColor))
    }
}

#Preview {
    List {
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
                    status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                    cwd: "/work/proj", revision: 3),
                workspaceLabel: "proj",
                repoName: "proj",
                lastOutputSnippet: "Allow Claude to run rm -rf? 1. Yes 2. No"))
        // No workspace in the snapshot: the agent name takes the lead line
        // and the foot tag drops.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "claude", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repoName: nil,
                lastOutputSnippet: nil))
    }
}
