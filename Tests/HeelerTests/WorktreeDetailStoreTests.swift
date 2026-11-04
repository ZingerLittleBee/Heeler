import Foundation
import SwiftUI
import Testing
import UIKit

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
        let request = try #require(store.beginRemoval())
        #expect(store.beginRemoval() == nil)

        let first = Task { await store.finishRemoval(request) }
        try await waitUntil("the first removal should start") {
            await recorder.requests.count == 1
        }
        await store.finishRemoval(request)
        #expect(await recorder.requests.count == 1)
        await gate.open()
        await first.value
        guard case .removed = store.removalPhase else {
            Issue.record("removal should succeed")
            return
        }
    }

    @Test func dialogDismissalAfterActionCannotClearCapturedRemoval() async throws {
        let recorder = WorktreeRemoveRecorder()
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { request in
                await recorder.record(request)
                return WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])
            })
        store.prepareConfirmation()

        // The button action runs synchronously, then SwiftUI may dismiss the
        // dialog through its binding before the queued Task begins.
        let request = try #require(store.beginRemoval())
        store.cancelConfirmation()
        await store.finishRemoval(request)

        #expect(await recorder.requests == [request])
        #expect(store.removalPhase == .removed(
            WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])))
    }

    @Test func serverFailureStaysOnTheDetailAndCanRetry() async throws {
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in
                throw HerdrAPIError(
                    code: "dirty_worktree_requires_force",
                    message: Self.dirtyMessage)
            })
        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())

        await store.finishRemoval(request)

        guard case .failed(let message) = store.removalPhase else {
            Issue.record("server rejection should be a stable failure")
            return
        }
        #expect(message.contains("modified or untracked files"))
        store.dismissFeedback()
        #expect(store.removalPhase == .idle)
    }

    @Test func transportUncertaintyIsNotReportedAsSuccess() async throws {
        let store = makeStore(
            list: { _ in Self.list(branch: nil, detached: true) },
            remove: { _ in throw WorktreeRemovalError.outcomeUnconfirmed })
        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())

        await store.finishRemoval(request)

        #expect(store.removalPhase == .unconfirmed)
    }

    @Test func staleConfirmationFailsClosedUntilTheDetailIsReopened() async throws {
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/old") },
            remove: { _ in throw WorktreeRemovalError.staleIdentity })
        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())

        await store.finishRemoval(request)

        #expect(store.removalPhase == .stale(WorktreeRemovalError.staleIdentity.message))
        store.dismissFeedback()
        #expect(!store.canRemove)
    }

    @Test func transportCancellationRestoresIdleWithoutFailureFeedback() async throws {
        let store = makeStore(
            list: { _ in throw TransportError.cancelled },
            remove: { _ in throw TransportError.cancelled })

        await store.loadBranchIfNeeded()
        #expect(store.branch == .loading)

        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())
        await store.finishRemoval(request)

        #expect(store.removalPhase == .idle)
        #expect(!store.showsFeedback)
    }

    @Test func showChangesFromDetailsHandsTheWorktreeDirectory() {
        var handed: [String] = []
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in throw CancellationError() },
            showChanges: { handed.append($0) })

        #expect(store.canShowChanges)
        #expect(store.changesDirectory == "/work/Heeler-wt")
        store.showChanges()

        #expect(handed == ["/work/Heeler-wt"])
        #expect(store.removalPhase == .idle)
    }

    @Test func worktreeDetailsShowsChangesForItsDirectory() async throws {
        var handed: [String] = []
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in throw CancellationError() },
            showChanges: { handed.append($0) })
        let controller = UIHostingController(
            rootView: WorktreeDetailView(store: store) { _ in })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }

        let shown = try await ChangesViewTests.eventually {
            ChangesViewTests.labels(in: controller).contains("Show Changes")
        }
        try #require(shown, "Show Changes never appeared")
        #expect(ChangesViewTests.activate("Show Changes", in: controller.view))
        #expect(handed == ["/work/Heeler-wt"])
    }

    @Test func aDirtyRefusalOffersChangesForTheWorktreeDirectory() async throws {
        var handed: [String] = []
        let store = try await refusedStore(
            showChanges: { handed.append($0) },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.dirtyMessage))

        #expect(store.refusalOffersChanges)
        #expect(store.showsFeedback)
        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has modified or untracked files. Commit or discard those changes on the Host, then retry."
                ))
        #expect(store.refusalCommand == nil)

        store.showChanges()

        #expect(handed == ["/work/Heeler-wt"])
        #expect(!store.showsFeedback)
        #expect(!store.refusalOffersChanges)
        #expect(store.removalPhase == .idle)
    }

    @Test func aDirtyRefusalOverTheTransportAlsoOffersChanges() async throws {
        var handed: [String] = []
        let store = try await refusedStore(
            showChanges: { handed.append($0) },
            error: TransportError.apiRejected(
                code: "dirty_worktree_requires_force", message: Self.dirtyMessage))

        #expect(store.refusalOffersChanges)
        #expect(store.refusalCommand == nil)
        store.showChanges()
        #expect(handed == ["/work/Heeler-wt"])
        #expect(store.removalPhase == .idle)
    }

    @Test func otherRefusalsDoNotOfferChanges() async throws {
        let missing = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(code: "workspace_not_found", message: "gone"))
        #expect(!missing.refusalOffersChanges)
        #expect(missing.showsFeedback)
        #expect(missing.canShowChanges)

        let unreachable = try await refusedStore(
            showChanges: { _ in },
            error: TransportError.sshUnreachable(detail: "down"))
        #expect(!unreachable.refusalOffersChanges)
        #expect(unreachable.canShowChanges)
    }

    @Test func dismissingTheRefusalWithdrawsTheOffer() async throws {
        let store = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.dirtyMessage))

        #expect(store.refusalOffersChanges)
        store.dismissFeedback()
        #expect(!store.refusalOffersChanges)
        #expect(!store.showsFeedback)
        #expect(store.removalPhase == .idle)
    }

    /// git refuses a Worktree with checked-out submodules before it looks for
    /// changes, so the refusal names the submodules, still points at Changes,
    /// and hands over the command that forces the removal.
    @Test func aSubmoduleRefusalNamesSubmodulesAndTheForcedRemoval() async throws {
        var handed: [String] = []
        let store = try await refusedStore(
            showChanges: { handed.append($0) },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes /work/Heeler-wt and any uncommitted changes in it, so check its Changes first. To force it, run on the Host: herdr worktree remove --workspace w1 --force"
                ))
        #expect(store.refusalCommand == "herdr worktree remove --workspace w1 --force")
        #expect(store.refusalOffersChanges)

        store.showChanges()

        #expect(handed == ["/work/Heeler-wt"])
        #expect(store.removalPhase == .idle)
        #expect(store.refusalCommand == nil)
    }

    @Test func aSubmoduleRefusalOverTheTransportReadsTheSame() async throws {
        var handed: [String] = []
        let store = try await refusedStore(
            showChanges: { handed.append($0) },
            error: TransportError.apiRejected(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes /work/Heeler-wt and any uncommitted changes in it, so check its Changes first. To force it, run on the Host: herdr worktree remove --workspace w1 --force"
                ))
        #expect(store.refusalCommand == "herdr worktree remove --workspace w1 --force")
        #expect(store.refusalOffersChanges)

        store.showChanges()

        #expect(handed == ["/work/Heeler-wt"])
    }

    /// herdr finds git's text in any case anywhere in the message, so the
    /// refusal is read the same way.
    @Test func theSubmoduleTextIsFoundInAnyCaseWithinTheMessage() async throws {
        let store = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force",
                message: "Removal failed. WORKING TREES Containing Submodules cannot be moved or removed!"
            ))

        #expect(store.refusalCommand == "herdr worktree remove --workspace w1 --force")
        #expect(store.refusalOffersChanges)
    }

    /// herdr 0.9.0 sends git's submodule refusal as a plain removal failure,
    /// which shows herdr's text and offers nothing more.
    @Test func theSubmoduleTextUnderAnotherCodeGetsHerdrsText() async throws {
        let store = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "worktree_remove_failed", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree: fatal: working trees containing submodules cannot be moved or removed"
                ))
        #expect(store.refusalCommand == nil)
        #expect(!store.refusalOffersChanges)
    }

    /// herdr's CLI asks the default session unless told otherwise, so a Host
    /// that targets a named session gets a command that names it.
    @Test func aNamedSessionScopesTheForcedRemoval() async throws {
        let store = try await refusedStore(
            sessionName: "work",
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes /work/Heeler-wt and any uncommitted changes in it, so check its Changes first. To force it, run on the Host: herdr --session work worktree remove --workspace w1 --force"
                ))
        #expect(
            store.refusalCommand
                == "herdr --session work worktree remove --workspace w1 --force")
    }

    @Test func anEndpointScopesTheForcedRemovalInsteadOfTheSession() async throws {
        let endpoint = try #require(HerdrEndpoint(
            socketPath: "/tmp/custom herdr/herdr/herdr.sock",
            executablePath: "/tmp/custom herdr/launch"))
        let store = try await refusedStore(
            sessionName: "wrong", endpoint: endpoint,
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))
        let command = #"/bin/sh -c 'export HERDR_SOCKET_PATH="$1"; shift; exec "$@"' herdr '/tmp/custom herdr/herdr/herdr.sock' '/tmp/custom herdr/launch' worktree remove --workspace w1 --force"#
        #expect(store.refusalCommand == command)
        guard case .failed(let message) = store.removalPhase else {
            Issue.record("Expected a refusal with a recovery command")
            return
        }
        #expect(message.contains(command))
        #expect(store.refusalOffersChanges)
    }

    @Test func dismissingASubmoduleRefusalWithdrawsTheCommand() async throws {
        let store = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))
        try #require(store.refusalCommand != nil, "the refusal should hand over a command")

        store.dismissFeedback()

        #expect(store.refusalCommand == nil)
        #expect(!store.refusalOffersChanges)
        #expect(store.removalPhase == .idle)
        #expect(store.canRemove)
    }

    /// herdr takes an id such as `--session=other` as its own option however
    /// it is quoted, so no command can name that workspace. The refusal still
    /// names the submodules and points at Changes.
    @Test(arguments: ["--session", "--session=other", "--handoff", "--remote=other"], ["", "work"])
    func aWorkspaceIDHerdrTakesAsAnOptionGetsNoCommand(
        workspaceID: String, sessionName: String
    ) async throws {
        var handed: [String] = []
        let store = try await refusedStore(
            workspaceID: workspaceID,
            sessionName: sessionName,
            showChanges: { handed.append($0) },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes /work/Heeler-wt and any uncommitted changes in it, so check its Changes first."
                ))
        #expect(store.refusalCommand == nil)
        #expect(store.refusalOffersChanges)

        store.showChanges()

        #expect(handed == ["/work/Heeler-wt"])
    }

    /// An id that only resembles one of herdr's options reaches
    /// `--workspace`, so its refusal still hands over the command.
    @Test func aWorkspaceIDThatOnlyResemblesAnOptionKeepsTheCommand() async throws {
        let store = try await refusedStore(
            workspaceID: "--sessions",
            showChanges: { _ in },
            error: HerdrAPIError(
                code: "dirty_worktree_requires_force", message: Self.submoduleMessage))

        #expect(
            store.removalPhase
                == .failed(
                    "herdr couldn't remove this worktree because it has checked-out submodules. Forcing the removal deletes /work/Heeler-wt and any uncommitted changes in it, so check its Changes first. To force it, run on the Host: herdr worktree remove --workspace --sessions --force"
                ))
        #expect(store.refusalCommand == "herdr worktree remove --workspace --sessions --force")
        #expect(store.refusalOffersChanges)
    }

    /// herdr sends one code both while another operation runs on the checkout
    /// and, since 0.9.4, while it re-validates restored Worktrees, so only its
    /// own message states the cause. Either way the removal can be retried.
    @Test(arguments: [
        (
            "worktree operation is already in progress for this checkout",
            "herdr couldn't remove this worktree: worktree operation is already in progress for this checkout"
        ),
        (
            "Restored worktree is still loading. Try again shortly.",
            "herdr couldn't remove this worktree: Restored worktree is still loading. Try again shortly."
        ),
    ])
    func anOperationInProgressShowsHerdrsReason(message: String, copy: String) async throws {
        let store = try await refusedStore(
            showChanges: { _ in },
            error: HerdrAPIError(code: "worktree_operation_in_progress", message: message))

        #expect(store.removalPhase == .failed(copy))
        #expect(store.refusalCommand == nil)
        #expect(!store.refusalOffersChanges)

        store.dismissFeedback()

        #expect(store.removalPhase == .idle)
        #expect(store.canRemove)
    }

    @Test func noChangesWhileRemovingOrWithoutAHandler() async throws {
        var handed: [String] = []
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { request in
                WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])
            },
            showChanges: { handed.append($0) })
        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())
        #expect(!store.canShowChanges)
        store.showChanges()
        #expect(handed.isEmpty)

        await store.finishRemoval(request)
        guard case .removed = store.removalPhase else {
            Issue.record("removal should succeed")
            return
        }
        #expect(!store.canShowChanges)
        store.showChanges()
        #expect(handed.isEmpty)

        let without = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in throw CancellationError() })
        #expect(!without.canShowChanges)
        without.showChanges()
    }

    /// Show Changes stages the Worktree directory and dismisses the sheet
    /// before Changes exists. Back is a new handoff beside Agent detail, so
    /// the sheet does not return and Changes is not opened again.
    @Test func theSheetDismissesBeforeChangesOpensAndBackLeavesItDismissed() async throws {
        let transport = ScriptedTransport()
        var handed: [String?] = []
        let presentation = AgentChangesPresentation(makeStoreIn: { fixed in
            handed.append(fixed)
            return ChangesStore(directory: { fixed }) { request in
                try await transport.readChanges(request)
            }
        })
        let handoff = WorktreeChangesHandoff()
        var sheetPresented = true
        let store = makeStore(
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in throw CancellationError() },
            showChanges: { directory in
                sheetPresented = handoff.stage(directory)
            })

        store.showChanges()
        #expect(!sheetPresented)
        #expect(handoff.pendingDirectory == "/work/Heeler-wt")
        #expect(presentation.store == nil)

        handoff.openChangesAfterDismissal { directory in
            presentation.open(directory: directory)
        }
        let changes = try #require(presentation.store)
        await changes.appear()
        #expect(handed == ["/work/Heeler-wt"])
        #expect(
            await transport.changesReadRequests
                == [ChangesReadRequest(directory: "/work/Heeler-wt")])

        presentation.close()
        #expect(presentation.store == nil)

        // Back builds a new terminal, so its handoff has nothing staged and
        // a dismissal opens nothing.
        let restored = WorktreeChangesHandoff()
        restored.openChangesAfterDismissal { directory in
            presentation.open(directory: directory)
        }
        #expect(restored.pendingDirectory == nil)
        #expect(presentation.store == nil)
        #expect(handed == ["/work/Heeler-wt"])
    }

    /// herdr's refusal for a Worktree with changes, in git's words, naming the
    /// checkout path.
    private static let dirtyMessage =
        "fatal: '/work/Heeler-wt' contains modified or untracked files, use --force to delete it"

    /// herdr's refusal for a Worktree with checked-out submodules since
    /// 0.9.1, in git's words, whether or not the Worktree has changes.
    private static let submoduleMessage =
        "fatal: working trees containing submodules cannot be moved or removed"

    /// A blank `sessionName` is the Host's default herdr session.
    private func refusedStore(
        workspaceID: String = "w1",
        sessionName: String = "",
        endpoint: HerdrEndpoint? = nil,
        showChanges: @escaping (String) -> Void,
        error: some Error
    ) async throws -> WorktreeDetailStore {
        let store = makeStore(
            workspaceID: workspaceID,
            sessionName: sessionName,
            endpoint: endpoint,
            list: { _ in Self.list(branch: "feat/issue-99") },
            remove: { _ in throw error },
            showChanges: showChanges)
        store.prepareConfirmation()
        let request = try #require(store.beginRemoval())
        await store.finishRemoval(request)
        return store
    }

    private func makeStore(
        workspaceID: String = "w1",
        sessionName: String = "",
        endpoint: HerdrEndpoint? = nil,
        list: @escaping (String) async throws -> WorktreeListResponse,
        remove: @escaping (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt,
        showChanges: ((String) -> Void)? = nil
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
                    hostID: UUID(), workspaceID: workspaceID, checkout: checkout)),
            workspaceLabel: "issue-99",
            checkout: checkout,
            sessionName: sessionName,
            endpoint: endpoint,
            list: list,
            remove: remove,
            hasWorkingAgent: { true },
            showChanges: showChanges)
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
