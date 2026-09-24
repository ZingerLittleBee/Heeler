import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Shell terminal creation")
struct ShellTerminalCreationTests {
    @Test func creationUsesAgentDirectoryBeforeLinkedWorktreeCheckout() {
        let agent = makeAgent(
            cwd: "/agent/launch",
            checkout: makeCheckout(path: "/worktree/checkout", isLinked: true))

        #expect(
            agent.shellTerminalCreationRequest
                == ShellTerminalCreationRequest(
                    workspaceID: "workspace-1",
                    cwd: "/agent/launch"))
    }

    @Test func creationFallsBackToLinkedWorktreeCheckout() {
        let agent = makeAgent(
            cwd: "",
            checkout: makeCheckout(path: "/worktree/checkout", isLinked: true))

        #expect(
            agent.shellTerminalCreationRequest
                == ShellTerminalCreationRequest(
                    workspaceID: "workspace-1",
                    cwd: "/worktree/checkout"))
    }

    @Test func creationIsUnavailableWithoutAnAbsoluteAgentDirectoryOrLinkedCheckout() {
        #expect(makeAgent(cwd: "relative/path").shellTerminalCreationRequest == nil)
        #expect(
            makeAgent(
                cwd: "",
                checkout: makeCheckout(path: "/main/checkout", isLinked: false)
            )
            .shellTerminalCreationRequest == nil)
    }

    /// A definitive rejection created nothing and says why; an unclear
    /// outcome may have left a tab behind, so it must not read as a
    /// rejection the user can blindly retry.
    @Test func definitiveRejectionAndAmbiguousFailureAreToldApart() {
        let rejected = AgentDetailView.terminalCreationFailureMessage(
            for: HerdrAPIError(code: "workspace_not_found", message: "workspace is gone"))
        let ambiguous = AgentDetailView.terminalCreationFailureMessage(
            for: TransportError.timedOut)

        #expect(rejected.contains("workspace is gone"))
        #expect(ambiguous.contains("may already exist"))
        #expect(!ambiguous.contains("couldn't create"))
    }

    private func makeAgent(
        cwd: String = "/repo",
        checkout: RepositoryCheckout? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: Host.ID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            hostName: "Host",
            agent: Agent(
                terminalID: "term-agent",
                kind: "claude",
                title: "Task",
                status: .idle,
                workspaceID: "workspace-1",
                tabID: "w1:t-agent",
                paneID: "w1:p-agent",
                cwd: cwd,
                revision: 1),
            workspaceLabel: "Workspace",
            repositoryCheckout: checkout)
    }

    private func makeCheckout(path: String, isLinked: Bool) -> RepositoryCheckout {
        RepositoryCheckout(
            repoKey: "/repo/.git",
            repoName: "repo",
            repoRoot: "/repo",
            checkoutPath: path,
            isLinkedWorktree: isLinked)
    }
}
