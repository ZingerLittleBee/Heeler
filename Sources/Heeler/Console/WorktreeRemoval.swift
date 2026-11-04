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

/// How Worktree Details explains a removal that failed.
struct WorktreeRemovalRefusal {
    let message: String
    /// The Worktree may hold uncommitted work, so the alert offers Changes.
    let offersChanges: Bool
    /// The herdr command that forces the removal, for the user to run on the
    /// Host.
    let command: String?

    /// herdr's code for a removal that only `--force` can do.
    private static let forceRequiredCode = "dirty_worktree_requires_force"
    /// git's refusal for a Worktree with checked-out submodules, which herdr
    /// also sends under `forceRequiredCode` since 0.9.1. herdr finds it in
    /// git's message ignoring case (`is_dirty_worktree_remove_error`), and so
    /// does this.
    private static let submodulesRefusal =
        "working trees containing submodules cannot be moved or removed"

    /// The endpoint overrides the Host's session, as it does for API requests.
    init(
        _ error: any Error, request: WorktreeRemovalRequest, sessionName: String,
        endpoint: HerdrEndpoint? = nil
    ) {
        switch error {
        case let removal as WorktreeRemovalError:
            self.init(message: removal.message)
        case let api as HerdrAPIError:
            self.init(
                code: api.code, serverMessage: api.message,
                request: request, sessionName: sessionName, endpoint: endpoint)
        case let TransportError.apiRejected(code, message):
            self.init(
                code: code, serverMessage: message,
                request: request, sessionName: sessionName, endpoint: endpoint)
        case TransportError.sshUnreachable:
            self.init(message: "The Host is not connected.")
        case TransportError.timedOut:
            self.init(message: "The Host did not answer in time.")
        case TransportError.cancelled:
            self.init(message: "Worktree removal was cancelled.")
        default:
            self.init(message: "Removing the worktree failed: \(error)")
        }
    }

    private init(message: String, offersChanges: Bool = false, command: String? = nil) {
        self.message = message
        self.offersChanges = offersChanges
        self.command = command
    }

    private init(
        code: String, serverMessage: String,
        request: WorktreeRemovalRequest, sessionName: String, endpoint: HerdrEndpoint?
    ) {
        switch code {
        case Self.forceRequiredCode
        where serverMessage.range(of: Self.submodulesRefusal, options: .caseInsensitive) != nil:
            let workspaceID = request.identity.workspaceID
            let warning =
                "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes \(request.identity.checkoutPath) and any uncommitted changes in it, so check its Changes first."
            if HerdrCommandLine.readsAsGlobalOption(workspaceID) {
                // herdr would take this id as its own option, so no command
                // can hand it to `--workspace`.
                self.init(message: warning, offersChanges: true)
            } else {
                let command = HerdrCommandLine.render(
                    session: sessionName, endpoint: endpoint,
                    arguments: ["worktree", "remove", "--workspace", workspaceID, "--force"])
                self.init(
                    message: "\(warning) To force it, run on the Host: \(command)",
                    offersChanges: true,
                    command: command)
            }
        case Self.forceRequiredCode:
            self.init(
                message: "herdr couldn't remove this worktree because it has modified or untracked files. Commit or discard those changes on the Host, then retry.",
                offersChanges: true)
        case "not_linked_worktree":
            self.init(message: "herdr couldn't remove this worktree because the workspace is not a linked worktree.")
        case "workspace_not_found":
            self.init(message: "herdr couldn't remove this worktree because the workspace is no longer on the Host.")
        default:
            self.init(message: "herdr couldn't remove this worktree: \(serverMessage)")
        }
    }
}

/// Sequences Show Changes so the Worktree sheet finishes dismissing before
/// Changes opens. Back builds a new handoff with nothing pending, and the
/// sheet state is created with Agent detail, so the sheet stays closed.
final class WorktreeChangesHandoff {
    /// The Worktree directory waiting for the sheet to finish dismissing.
    private(set) var pendingDirectory: String?

    /// Remembers `directory` and reports that the sheet is no longer
    /// presented. Does not open Changes; the sheet's `onDismiss` does.
    func stage(_ directory: String) -> Bool {
        pendingDirectory = directory
        return false
    }

    /// The sheet's `onDismiss`. Opens Changes only for a directory staged
    /// by Show Changes, then forgets it. Done, a swipe, or a completed
    /// removal opens nothing.
    func openChangesAfterDismissal(open: (String) -> Void) {
        guard let directory = pendingDirectory else { return }
        pendingDirectory = nil
        open(directory)
    }
}
