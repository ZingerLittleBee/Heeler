import Foundation

/// One row of the Console (#8): an Agent joined with its Host identity and
/// workspace context. The list is flat across Hosts; the workspace is a
/// context tag only, never a grouping level.
struct ConsoleAgent: Identifiable, Sendable, Equatable {
    /// Pane addresses are unique per herdr session, not across Hosts; the
    /// row identity pairs them.
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let paneID: String
    }

    let hostID: Host.ID
    let hostName: String
    var agent: Agent
    /// Workspace label from the session snapshot; nil when the snapshot did
    /// not carry the workspace.
    let workspaceLabel: String?
    /// Worktree repo name where the workspace has one — sharper context than
    /// a raw checkout path.
    let repoName: String?
    /// Trailing terminal output (`pane.read`, ANSI stripped), fetched after
    /// snapshots and status changes; nil until the first read lands.
    var lastOutputSnippet: String?

    var id: ID { ID(hostID: hostID, paneID: agent.paneID) }
}

extension AgentStatus {
    /// Console sort bucket: Blocked > Working > everything else. Idle, Done,
    /// Unknown, and any status this build does not recognize (herdr's API
    /// has no stability guarantee) share the bottom bucket — a status we
    /// cannot interpret is not actionable, so it must not outrank one we can.
    var consoleSortBucket: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        default: 2
        }
    }
}

extension [ConsoleAgent] {
    /// The Console order: status bucket first, then stable Host/workspace/
    /// pane keys so rows never jitter between equal statuses.
    func consoleSorted() -> [ConsoleAgent] {
        sorted { lhs, rhs in
            let lhsBucket = lhs.agent.status.consoleSortBucket
            let rhsBucket = rhs.agent.status.consoleSortBucket
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.hostName != rhs.hostName { return lhs.hostName < rhs.hostName }
            if lhs.hostID != rhs.hostID {
                return lhs.hostID.uuidString < rhs.hostID.uuidString
            }
            let lhsWorkspace = lhs.workspaceLabel ?? ""
            let rhsWorkspace = rhs.workspaceLabel ?? ""
            if lhsWorkspace != rhsWorkspace { return lhsWorkspace < rhsWorkspace }
            return lhs.agent.paneID < rhs.agent.paneID
        }
    }
}
