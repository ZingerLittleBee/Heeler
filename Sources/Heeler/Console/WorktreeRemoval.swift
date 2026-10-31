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
    /// What the confirmation warned would be lost, which is all a forced removal
    /// may cover. Reading a risk does not set this; showing it does.
    let toldRisk: WorktreeRemovalRisk?

    init(id: UUID = UUID(), identity: WorktreeIdentity, toldRisk: WorktreeRemovalRisk? = nil) {
        self.id = id
        self.identity = identity
        self.toldRisk = toldRisk
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
    /// A Terminal of the Workspace may still run, so the checkout stayed.
    case terminalsNotEnded
    /// The checkout now holds what the confirmation did not warn about.
    case changedSinceConfirmation
    /// The Terminals ended, and the checkout then held what the confirmation did
    /// not warn about, so it stayed.
    case changedWhileTerminalsEnded
    /// git could not say what the checkout holds, before anything ended.
    case riskUnread(String)
    case removeRefused(String)
    case removeUnconfirmed(path: String)

    /// The next confirmation has to warn of what stopped this removal.
    var isNewerThanConfirmation: Bool {
        self == .changedSinceConfirmation || self == .changedWhileTerminalsEnded
    }

    var message: String {
        switch self {
        case .staleIdentity:
            "This is no longer the same linked worktree. Nothing was removed."
        case .alreadyInProgress:
            "This worktree already has a removal in progress."
        case .outcomeUnconfirmed:
            "The Host did not confirm whether removal completed. Close this sheet, wait for the Console to refresh, then reopen Worktree Details."
        case .terminalsNotEnded:
            "A Terminal in this worktree could not be confirmed ended, so the checkout was not removed. Others may have ended. Check the Host, then try again."
        case .changedSinceConfirmation:
            "This worktree changed since you confirmed, and nothing was removed. Removing it again deletes what it holds now."
        case .changedWhileTerminalsEnded:
            "The worktree's Terminals have ended, but it changed since you confirmed, so the checkout was not removed. Removing it again deletes what it holds now."
        case .riskUnread(let reason):
            "git could not read this worktree, so this attempt ended no Terminal and did not remove the checkout: \(reason)"
        case .removeRefused(let reason):
            "The worktree's Terminals have ended, but git did not remove the checkout: \(reason)"
        case .removeUnconfirmed(let path):
            "The worktree's Terminals have ended, but the Host did not confirm the removal. Check whether \(path) is still on the Host before trying again."
        }
    }
}

/// What removing a core Host's Worktree would lose, which is what forces it.
/// Herdr TUI Hosts refuse these removals instead, and have none.
struct WorktreeRemovalRisk: Equatable, Hashable, Sendable {
    let hasChanges: Bool
    let hasSubmodules: Bool

    var requiresForce: Bool { hasChanges || hasSubmodules }

    /// Whether the user heard about all of this.
    func isCovered(by told: WorktreeRemovalRisk?) -> Bool {
        (!hasChanges || told?.hasChanges == true) && (!hasSubmodules || told?.hasSubmodules == true)
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
        hasWorkingAgent: Bool,
        risk: WorktreeRemovalRisk? = nil
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
        if risk?.hasChanges == true {
            sentences.append("Its uncommitted changes will be lost.")
        }
        if risk?.hasSubmodules == true {
            sentences.append("Its submodules go with it, with any commits in them that were not pushed.")
        }
        sentences.append("This can't be undone.")
        return WorktreeRemovalConfirmation(
            request: WorktreeRemovalRequest(
                id: request.id, identity: request.identity, toldRisk: risk),
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
            self.init(
                message: removal.message, offersChanges: removal.isNewerThanConfirmation)
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
