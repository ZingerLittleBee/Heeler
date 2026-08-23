import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Worktree detail store")
struct WorktreeDetailStoreTests {
    @Test func snapshotMetadataAndScopedListPresentTheBranch() async {
        let recorder = WorktreeRemoveRecorder()
        let store = makeStore(
            list: { workspaceID in
                #expect(workspaceID == "w1")
                return Self.list(branch: "feat/issue-99")
            },
            remove: { request in
                await recorder.record(request)
                return WorktreeRemovalReceipt(
                    request: request, affectedAgentIDs: [])
            })

        await store.loadBranchIfNeeded()

        #expect(store.checkout.repoName == "Heeler")
        #expect(store.checkout.checkoutPath == "/work/Heeler-wt")
        #expect(store.branch == .named("feat/issue-99"))
    }

    @Test func cancelLeavesStateUnchangedAndSendsNoRemoval() async {
        let recorder = WorktreeRemoveRecorder()
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { request in
                await recorder.record(request)
                return WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])
            })

        store.prepareConfirmation()
        store.cancelConfirmation()

        #expect(store.confirmation == nil)
        #expect(store.removalPhase == .idle)
        #expect(await recorder.requests.isEmpty)
    }

    @Test func rapidRepeatedConfirmationDispatchesExactlyOnce() async throws {
        let gate = ScriptedTransportCallGate()
        let recorder = WorktreeRemoveRecorder()
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { request in
                await recorder.record(request)
                await gate.waitUntilOpen()
                return WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])
            })
        store.prepareConfirmation()

        let first = Task { await store.confirmRemoval() }
        try await waitUntil("the first removal should start") {
            await recorder.requests.count == 1
        }
        await store.confirmRemoval()
        #expect(await recorder.requests.count == 1)
        await gate.open()
        await first.value
        guard case .removed = store.removalPhase else {
            Issue.record("removal should succeed")
            return
        }
    }

    @Test func serverFailureStaysOnTheDetailAndCanRetry() async {
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in
                throw HerdrAPIError(
                    code: "dirty_worktree_requires_force",
                    message: "dirty")
            })
        store.prepareConfirmation()

        await store.confirmRemoval()

        guard case .failed(let message) = store.removalPhase else {
            Issue.record("server rejection should be a stable failure")
            return
        }
        #expect(message.contains("modified or untracked files"))
        store.dismissFeedback()
        #expect(store.removalPhase == .idle)
    }

    @Test func transportUncertaintyIsNotReportedAsSuccess() async {
        let store = makeStore(
            list: { _ in Self.list(branch: nil, detached: true) },
            remove: { _ in throw WorktreeRemovalError.outcomeUnconfirmed })
        store.prepareConfirmation()

        await store.confirmRemoval()

        #expect(store.removalPhase == .unconfirmed)
    }

    @Test func staleConfirmationFailsClosedUntilTheDetailIsReopened() async {
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/old") },
            remove: { _ in throw WorktreeRemovalError.staleIdentity })
        store.prepareConfirmation()

        await store.confirmRemoval()

        #expect(store.removalPhase == .stale(WorktreeRemovalError.staleIdentity.message))
        store.dismissFeedback()
        #expect(!store.canRemove)
    }

    private func makeStore(
        list: @escaping (String) async throws -> WorktreeListResponse,
        remove: @escaping (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt
    ) -> WorktreeDetailStore {
        let checkout = RepositoryCheckout(
            repoKey: "/work/Heeler/.git",
            repoName: "Heeler",
            repoRoot: "/work/Heeler",
            checkoutPath: "/work/Heeler-wt",
            isLinkedWorktree: true)
        return WorktreeDetailStore(
            request: WorktreeRemovalRequest(
                identity: WorktreeIdentity(
                    hostID: UUID(), workspaceID: "w1", checkout: checkout)),
            workspaceLabel: "issue-99",
            checkout: checkout,
            list: list,
            remove: remove,
            hasWorkingAgent: { true })
    }

    private static func list(
        branch: String?, detached: Bool = false
    ) -> WorktreeListResponse {
        WorktreeListResponse(
            source: WorktreeSourceInfo(
                repoKey: "/work/Heeler/.git",
                repoName: "Heeler",
                repoRoot: "/work/Heeler",
                sourceCheckoutPath: "/work/Heeler"),
            worktrees: [
                WorktreeInfo(
                    isBare: false,
                    isDetached: detached,
                    isLinkedWorktree: true,
                    isPrunable: false,
                    label: "issue-99",
                    path: "/work/Heeler-wt",
                    branch: branch,
                    openWorkspaceID: "w1")
            ])
    }

    private func waitUntil(
        _ comment: Comment,
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

private actor WorktreeRemoveRecorder {
    private(set) var requests: [WorktreeRemovalRequest] = []

    func record(_ request: WorktreeRemovalRequest) {
        requests.append(request)
    }
}
