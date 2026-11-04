import Foundation
import Observation

@MainActor
@Observable
final class WorktreeDetailStore {
    enum BranchPresentation: Equatable {
        case loading
        case named(String)
        case detached
        case unavailable
    }

    enum RemovalPhase: Equatable {
        case idle
        case removing
        case removed(WorktreeRemovalReceipt)
        case failed(String)
        case stale(String)
        case unconfirmed
    }

    let request: WorktreeRemovalRequest
    let workspaceLabel: String
    let checkout: RepositoryCheckout

    private(set) var branch: BranchPresentation = .loading
    private(set) var confirmation: WorktreeRemovalConfirmation?
    private(set) var removalPhase: RemovalPhase = .idle
    private(set) var showsFeedback = false
    /// The refusal leaves uncommitted work possible, so its alert can offer
    /// Changes.
    private(set) var refusalOffersChanges = false
    /// The command that forces the refused removal, for the alert's Copy
    /// Command.
    private(set) var refusalCommand: String?

    /// Recovery commands target the same endpoint or session as the removal.
    private let sessionName: String
    private let endpoint: HerdrEndpoint?
    private let list: (String) async throws -> WorktreeListResponse
    private let remove: (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt
    private let hasWorkingAgent: () -> Bool
    private let showChangesHandler: ((String) -> Void)?
    private var didLoadBranch = false
    /// A token captured synchronously by the confirmation action and consumed
    /// exactly once when its asynchronous removal task starts.
    private var pendingRemovalRequestID: UUID?

    init(
        request: WorktreeRemovalRequest,
        workspaceLabel: String,
        checkout: RepositoryCheckout,
        sessionName: String,
        endpoint: HerdrEndpoint? = nil,
        list: @escaping (String) async throws -> WorktreeListResponse,
        remove: @escaping (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt,
        hasWorkingAgent: @escaping () -> Bool,
        showChanges: ((String) -> Void)? = nil
    ) {
        self.request = request
        self.workspaceLabel = workspaceLabel
        self.checkout = checkout
        self.sessionName = sessionName
        self.endpoint = endpoint
        self.list = list
        self.remove = remove
        self.hasWorkingAgent = hasWorkingAgent
        showChangesHandler = showChanges
    }

    var canRemove: Bool {
        checkout.isLinkedWorktree && removalPhase == .idle
    }

    /// The Worktree's own directory, not the Agent's current directory.
    var changesDirectory: String { checkout.checkoutPath }

    /// Show Changes is available except while a removal is in flight or done,
    /// and only when something can open Changes after the sheet dismisses.
    var canShowChanges: Bool {
        guard showChangesHandler != nil else { return false }
        return switch removalPhase {
        case .removing, .removed: false
        case .idle, .failed, .stale, .unconfirmed: true
        }
    }

    /// Hands `changesDirectory` to the sheet owner, which dismisses first.
    /// Clears a refusal so the alert does not stay up over that dismissal.
    func showChanges() {
        guard canShowChanges else { return }
        showsFeedback = false
        refusalOffersChanges = false
        refusalCommand = nil
        if case .failed = removalPhase {
            removalPhase = .idle
        }
        showChangesHandler?(changesDirectory)
    }

    func loadBranchIfNeeded() async {
        guard !didLoadBranch else { return }
        didLoadBranch = true
        branch = .loading
        do {
            let response = try await list(request.identity.workspaceID)
            guard response.source.repoKey == request.identity.repoKey else {
                branch = .unavailable
                return
            }
            let entry = response.worktrees.first {
                $0.openWorkspaceID == request.identity.workspaceID
                    && $0.path == request.identity.checkoutPath
                    && $0.isLinkedWorktree
            }
            guard let entry else {
                branch = .unavailable
                return
            }
            if let name = entry.branch, !name.isEmpty {
                branch = .named(name)
            } else if entry.isDetached {
                branch = .detached
            } else {
                branch = .unavailable
            }
        } catch is CancellationError {
            didLoadBranch = false
            branch = .loading
        } catch TransportError.cancelled {
            didLoadBranch = false
            branch = .loading
        } catch {
            branch = .unavailable
        }
    }

    func retryBranch() async {
        didLoadBranch = false
        await loadBranchIfNeeded()
    }

    /// Captures one immutable request in the dialog. Final authorization is
    /// deliberately later, immediately before the wire begins writing.
    func prepareConfirmation() {
        guard canRemove else { return }
        confirmation = WorktreeRemovalConfirmation.make(
            request: request,
            workspaceLabel: workspaceLabel,
            branch: confirmationBranch,
            hasWorkingAgent: hasWorkingAgent())
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    /// Captures and transitions the exact confirmed request synchronously.
    /// SwiftUI may clear the dialog binding immediately after this returns;
    /// the asynchronous dispatch no longer reads that mutable dialog state.
    func beginRemoval() -> WorktreeRemovalRequest? {
        guard canRemove, let confirmation else { return nil }
        removalPhase = .removing
        self.confirmation = nil
        pendingRemovalRequestID = confirmation.request.id
        return confirmation.request
    }

    func finishRemoval(_ request: WorktreeRemovalRequest) async {
        guard pendingRemovalRequestID == request.id, request == self.request else { return }
        pendingRemovalRequestID = nil
        do {
            removalPhase = .removed(try await remove(request))
        } catch WorktreeRemovalError.staleIdentity {
            removalPhase = .stale(WorktreeRemovalError.staleIdentity.message)
            showsFeedback = true
        } catch WorktreeRemovalError.outcomeUnconfirmed {
            removalPhase = .unconfirmed
            showsFeedback = true
        } catch is CancellationError {
            removalPhase = .idle
        } catch TransportError.cancelled {
            removalPhase = .idle
        } catch {
            let refusal = WorktreeRemovalRefusal(
                error, request: request, sessionName: sessionName, endpoint: endpoint)
            refusalOffersChanges = showChangesHandler != nil && refusal.offersChanges
            refusalCommand = refusal.command
            removalPhase = .failed(refusal.message)
            showsFeedback = true
        }
    }

    func dismissFeedback() {
        showsFeedback = false
        refusalOffersChanges = false
        refusalCommand = nil
        if case .failed = removalPhase {
            removalPhase = .idle
        }
    }

    private var confirmationBranch: WorktreeRemovalConfirmation.Branch {
        switch branch {
        case .named(let name): .named(name)
        case .detached: .detached
        case .loading, .unavailable: .unavailable
        }
    }
}
