import Foundation
import Testing

@testable import Heeler

@Suite("Worktree removal value model")
struct WorktreeRemovalTests {
    @Test func identityRequiresRepositoryAndCheckoutPath() {
        let hostID = UUID()
        let checkout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/wt/one", isLinkedWorktree: true)
        let identity = WorktreeIdentity(
            hostID: hostID, workspaceID: "w1", checkout: checkout)

        #expect(identity.matches(checkout))
        #expect(
            !identity.matches(
                RepositoryCheckout(
                    repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
                    checkoutPath: "/wt/two", isLinkedWorktree: true)))
        #expect(
            !identity.matches(
                RepositoryCheckout(
                    repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
                    checkoutPath: "/wt/one", isLinkedWorktree: false)))
    }

    @Test func onlySnapshotLinkedCheckoutsAreEligibleForTheBadgeAndAction() {
        let hostID = UUID()
        let agent = Agent(
            terminalID: "term", kind: "codex", title: "task", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
            cwd: "/repo", revision: 1)
        let mainCheckout = ConsoleAgent(
            hostID: hostID,
            hostName: "host",
            agent: agent,
            workspaceLabel: "repo",
            repositoryCheckout: RepositoryCheckout(
                repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
                checkoutPath: "/repo", isLinkedWorktree: false))
        let linked = ConsoleAgent(
            hostID: hostID,
            hostName: "host",
            agent: agent,
            workspaceLabel: "repo-wt",
            repositoryCheckout: RepositoryCheckout(
                repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
                checkoutPath: "/wt/repo", isLinkedWorktree: true))

        #expect(!mainCheckout.isLinkedWorktree)
        #expect(linked.isLinkedWorktree)
    }

    @Test func confirmationNamesBlastRadiusAndPreservedBranch() {
        let checkout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/wt/one", isLinkedWorktree: true)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: UUID(), workspaceID: "w1", checkout: checkout))

        let confirmation = WorktreeRemovalConfirmation.make(
            request: request,
            workspaceLabel: "issue-99",
            branch: .named("feat/issue-99"),
            hasWorkingAgent: true)

        #expect(confirmation.request == request)
        #expect(confirmation.message.contains("ending every Agent and closing every Pane"))
        #expect(confirmation.message.contains("local branch feat/issue-99 is kept"))
        #expect(confirmation.message.contains("An Agent is still working"))
    }

    @Test func resultSurfaceMatchesAffectedAbsentSelectionExactly() {
        let hostID = UUID()
        let selectedID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        let otherID = ConsoleAgent.ID(hostID: hostID, paneID: "w2:p1")
        let checkout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/wt/one", isLinkedWorktree: true)
        let receipt = WorktreeRemovalReceipt(
            request: WorktreeRemovalRequest(
                identity: WorktreeIdentity(
                    hostID: hostID, workspaceID: "w1", checkout: checkout)),
            affectedAgentIDs: [selectedID])

        #expect(
            RemovedWorktreeSelection.receipt(
                for: selectedID, agents: [], receipts: [selectedID: receipt]) == receipt)
        #expect(
            RemovedWorktreeSelection.receipt(
                for: otherID, agents: [], receipts: [selectedID: receipt]) == nil)

        let stillProjected = ConsoleAgent(
            hostID: hostID,
            hostName: "host",
            agent: Agent(
                terminalID: "term", kind: "codex", title: "task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/wt/one", revision: 1),
            workspaceLabel: "one",
            repositoryCheckout: checkout)
        #expect(
            RemovedWorktreeSelection.receipt(
                for: selectedID,
                agents: [stillProjected],
                receipts: [selectedID: receipt]) == receipt)
    }

    @Test func reusedPaneSelectionDoesNotInheritAnOldRemovalResult() {
        let hostID = UUID()
        let selectedID = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        let removedCheckout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/wt/old", isLinkedWorktree: true)
        let receipt = WorktreeRemovalReceipt(
            request: WorktreeRemovalRequest(
                identity: WorktreeIdentity(
                    hostID: hostID, workspaceID: "w1", checkout: removedCheckout)),
            affectedAgentIDs: [selectedID])
        let replacement = ConsoleAgent(
            hostID: hostID,
            hostName: "host",
            agent: Agent(
                terminalID: "term", kind: "codex", title: "replacement",
                status: .idle, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/wt/new", revision: 1),
            workspaceLabel: "new",
            repositoryCheckout: RepositoryCheckout(
                repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
                checkoutPath: "/wt/new", isLinkedWorktree: true))

        #expect(
            RemovedWorktreeSelection.receipt(
                for: selectedID,
                agents: [replacement],
                receipts: [selectedID: receipt]) == nil)
    }
}
