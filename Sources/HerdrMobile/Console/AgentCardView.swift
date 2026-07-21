import SwiftUI

/// One Console card (#8): agent name and status up front, Host, pane
/// address, and workspace as context, plus the last-output snippet.
struct AgentCardView: View {
    let agent: ConsoleAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent.agent.displayName)
                    .font(.headline)
                AgentStatusBadge(status: agent.agent.status)
                Spacer()
                Text(agent.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                if let context = workspaceContext {
                    Text(context)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(agent.agent.paneID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// The workspace context tag: label, with the worktree repo when it adds
    /// information the label does not already carry.
    private var workspaceContext: String? {
        switch (agent.workspaceLabel, agent.repoName) {
        case (nil, nil):
            return nil
        case (let label?, nil):
            return label
        case (nil, let repo?):
            return repo
        case (let label?, let repo?):
            return label == repo ? label : "\(label) · \(repo)"
        }
    }
}

/// Status rendered as a tinted capsule; Blocked gets the loudest color
/// because it is the one asking for the user.
struct AgentStatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .blocked: .orange
        case .working: .blue
        case .done: .green
        default: .secondary
        }
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
    }
}
