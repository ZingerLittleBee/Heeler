import SwiftUI
import UIKit

/// One Console card (#8): the same workspace label and Agent kind herdr uses,
/// plus launch directory, Host, and status. Terminal titles, trailing TUI
/// output, and opaque pane ids are deliberately absent: none identifies the
/// Agent in herdr's own Agents pane.
struct AgentCardView: View {
    let agent: ConsoleAgent
    var isPinned: Bool = false

    private var presentation: AgentCardPresentation {
        AgentCardPresentation(agent: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.headline)
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
            if let context = presentation.context {
                Text(context)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                if let agentType = presentation.agentType {
                    Text(agentType)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(agent.hostName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AgentCardPresentation: Equatable {
    let headline: String
    let context: String?
    let agentType: String?

    init(agent: ConsoleAgent) {
        headline = agent.switcherLabel
        context = Self.nonEmpty(agent.agent.cwd).map {
            Self.abbreviatingStandardHome(in: $0, username: agent.hostUsername)
        }

        let kind = switch SupportedAgentKind(rawValue: agent.agent.kind) {
        case .some(.claude): "Claude"
        case let supported?: supported.displayName
        case nil: agent.agent.kind
        }
        agentType = headline.caseInsensitiveCompare(kind) == .orderedSame
            ? nil
            : kind
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// The snapshot carries an expanded remote path but not `$HOME`. Standard
    /// macOS/Linux SSH-account homes can still be shortened without guessing
    /// that an arbitrary path prefix is a home directory.
    private static func abbreviatingStandardHome(
        in path: String, username: String?
    ) -> String {
        guard let username, !username.isEmpty else { return path }
        let homes = username == "root"
            ? ["/root"]
            : ["/Users/\(username)", "/home/\(username)"]
        guard let home = homes.first(where: { path == $0 || path.hasPrefix("\($0)/") })
        else { return path }
        return path == home ? "~" : "~\(path.dropFirst(home.count))"
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
                repositoryCheckout: RepositoryCheckout(
                    repoKey: "/work/proj/.git",
                    repoName: "proj",
                    repoRoot: "/work/proj",
                    checkoutPath: "/work/proj-wt",
                    isLinkedWorktree: true),
                lastOutputSnippet: "Allow Claude to run rm -rf? 1. Yes 2. No"))
        // No workspace in the snapshot: the Agent's own name takes the lead.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "claude", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repositoryCheckout: nil,
                lastOutputSnippet: nil))
    }
}
