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

    private let list: (String) async throws -> WorktreeListResponse
    private let remove: (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt
    private let hasWorkingAgent: () -> Bool
    private var didLoadBranch = false
    private var isConfirming = false

    init(
        request: WorktreeRemovalRequest,
        workspaceLabel: String,
        checkout: RepositoryCheckout,
        list: @escaping (String) async throws -> WorktreeListResponse,
        remove: @escaping (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt,
        hasWorkingAgent: @escaping () -> Bool
    ) {
        self.request = request
        self.workspaceLabel = workspaceLabel
        self.checkout = checkout
        self.list = list
        self.remove = remove
        self.hasWorkingAgent = hasWorkingAgent
    }

    var canRemove: Bool {
        checkout.isLinkedWorktree && !isConfirming && removalPhase == .idle
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

    func confirmRemoval() async {
        guard !isConfirming, let confirmation else { return }
        isConfirming = true
        removalPhase = .removing
        self.confirmation = nil
        defer { isConfirming = false }
        do {
            removalPhase = .removed(try await remove(confirmation.request))
        } catch WorktreeRemovalError.staleIdentity {
            removalPhase = .stale(WorktreeRemovalError.staleIdentity.message)
            showsFeedback = true
        } catch WorktreeRemovalError.outcomeUnconfirmed {
            removalPhase = .unconfirmed
            showsFeedback = true
        } catch is CancellationError {
            removalPhase = .idle
        } catch {
            removalPhase = .failed(WorktreeRemovalRefusal.message(for: error))
            showsFeedback = true
        }
    }

    func dismissFeedback() {
        showsFeedback = false
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
