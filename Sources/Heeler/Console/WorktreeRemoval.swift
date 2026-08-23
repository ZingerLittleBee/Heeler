import Foundation

/// Exact linked-worktree identity shown to the user. The workspace id alone
/// cannot authorize a destructive request because herdr may reuse it.
struct WorktreeIdentity: Equatable, Hashable, Sendable {
    let hostID: Host.ID
    let workspaceID: String
    let repoKey: String
    let checkoutPath: String

    init(hostID: Host.ID, workspaceID: String, checkout: RepositoryCheckout) {
        self.hostID = hostID
        self.workspaceID = workspaceID
        repoKey = checkout.repoKey
        checkoutPath = checkout.checkoutPath
    }

    func matches(_ checkout: RepositoryCheckout) -> Bool {
        checkout.isLinkedWorktree
            && checkout.repoKey == repoKey
            && checkout.checkoutPath == checkoutPath
    }
}

/// Immutable request carried from confirmation through the Transport seam.
/// `id` keeps concurrent operations distinct even when their timing overlaps.
struct WorktreeRemovalRequest: Equatable, Hashable, Sendable {
    let id: UUID
    let identity: WorktreeIdentity

    init(id: UUID = UUID(), identity: WorktreeIdentity) {
        self.id = id
        self.identity = identity
    }
}

/// Stable post-removal state. The affected Agent ids are captured from the
/// validated snapshot, so a later missing selection is never matched by Host
/// or workspace id alone.
struct WorktreeRemovalReceipt: Equatable, Sendable {
    let request: WorktreeRemovalRequest
    let affectedAgentIDs: Set<ConsoleAgent.ID>
}

enum RemovedWorktreeSelection {
    static func receipt(
        for selectedID: ConsoleAgent.ID,
        agents: [ConsoleAgent],
        receipts: [ConsoleAgent.ID: WorktreeRemovalReceipt]
    ) -> WorktreeRemovalReceipt? {
        guard let receipt = receipts[selectedID] else { return nil }
        guard let live = agents.first(where: { $0.id == selectedID }) else {
            return receipt
        }
        let identity = receipt.request.identity
        guard live.agent.workspaceID == identity.workspaceID,
            live.repositoryCheckout.map(identity.matches) == true
        else { return nil }
        return receipt
    }
}

enum WorktreeRemovalError: Error, Equatable, Sendable {
    case staleIdentity
    case alreadyInProgress
    case outcomeUnconfirmed

    var message: String {
        switch self {
        case .staleIdentity:
            "This is no longer the same linked worktree. Nothing was removed."
        case .alreadyInProgress:
            "This worktree already has a removal in progress."
        case .outcomeUnconfirmed:
            "The Host did not confirm whether removal completed. Close this sheet, wait for the Console to refresh, then reopen Worktree Details."
        }
    }
}

struct WorktreeRemovalConfirmation: Equatable, Sendable {
    enum Branch: Equatable, Sendable {
        case named(String)
        case detached
        case unavailable
    }

    let request: WorktreeRemovalRequest
    let title: String
    let message: String

    static func make(
        request: WorktreeRemovalRequest,
        workspaceLabel: String,
        branch: Branch,
        hasWorkingAgent: Bool
    ) -> WorktreeRemovalConfirmation {
        var sentences = [
            "This deletes \(request.identity.checkoutPath) and closes the whole workspace, ending every Agent and closing every Pane in it."
        ]
        switch branch {
        case .named(let name):
            sentences.append("The local branch \(name) is kept.")
        case .detached:
            break
        case .unavailable:
            sentences.append("Any local branch is kept.")
        }
        if hasWorkingAgent {
            sentences.append("An Agent is still working in this worktree.")
        }
        sentences.append("This can't be undone.")
        return WorktreeRemovalConfirmation(
            request: request,
            title: "Remove \(workspaceLabel) worktree?",
            message: sentences.joined(separator: " "))
    }
}

enum WorktreeRemovalRefusal {
    static func message(for error: any Error) -> String {
        switch error {
        case let removal as WorktreeRemovalError:
            removal.message
        case let api as HerdrAPIError:
            apiMessage(code: api.code, serverMessage: api.message)
        case let TransportError.apiRejected(code, message):
            apiMessage(code: code, serverMessage: message)
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.cancelled:
            "Worktree removal was cancelled."
        default:
            "Removing the worktree failed: \(error)"
        }
    }

    private static func apiMessage(code: String, serverMessage: String) -> String {
        switch code {
        case "dirty_worktree_requires_force":
            "herdr couldn't remove this worktree because it has modified or untracked files. Commit or discard those changes on the Host, then retry."
        case "not_linked_worktree":
            "herdr couldn't remove this worktree because the workspace is not a linked worktree."
        case "workspace_not_found":
            "herdr couldn't remove this worktree because the workspace is no longer on the Host."
        case "worktree_operation_in_progress":
            "herdr is already changing a worktree on this Host. Wait a moment, then retry."
        default:
            "herdr couldn't remove this worktree: \(serverMessage)"
        }
    }
}
