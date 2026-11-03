import Testing

@testable import Heeler

@MainActor
@Suite("Agent detail header title")
struct AgentDetailHeaderTitleTests {
    private func makeAgent(
        kind: String = "codex", title: String = "Harden webhook retries", name: String? = nil,
        cwd: String = "/Users/bee/workspace/payments-api", hostUsername: String? = "bee"
    ) -> ConsoleAgent {
        let agent = Agent(
            terminalID: "term_w1:p1", kind: kind, title: title, status: .working,
            workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: cwd, revision: 1,
            name: name)
        return ConsoleAgent(
            hostID: Host.fixture(name: "studio").id, hostName: "studio", agent: agent,
            workspaceLabel: nil, repositoryCheckout: nil, hostUsername: hostUsername)
    }

    @Test func namesTheTaskHarnessAndHomeRelativeDirectory() {
        let title = AgentDetailHeaderTitle(makeAgent())
        #expect(title == AgentDetailHeaderTitle(
            title: "Harden webhook retries", harness: "Codex",
            directory: "~/workspace/payments-api"))
    }

    /// A custom Agent name stands in for an empty task title but never for
    /// the harness, which keeps its product name.
    @Test func customNameFillsAnEmptyTitleButNotTheHarness() {
        let title = AgentDetailHeaderTitle(makeAgent(kind: "grok", title: "", name: "grokcapa"))
        #expect(title.title == "grokcapa")
        #expect(title.harness == "Grok Build")
    }

    @Test func unknownKindShowsAsReportedAndEmptyDirectoryIsLeftOut() {
        let title = AgentDetailHeaderTitle(makeAgent(kind: "mystery", cwd: ""))
        #expect(title.harness == "mystery")
        #expect(title.directory == nil)
    }
}

@Suite("Agent detail header controls")
struct AgentDetailHeaderControlPlacementTests {
    @Test func followsTheResolvedSystemBar() {
        #expect(AgentDetailHeaderControlPlacement(
            headerSharesBar: false, usesVerticalToolbar: false) == .floating)
        #expect(AgentDetailHeaderControlPlacement(
            headerSharesBar: true, usesVerticalToolbar: false) == .horizontalToolbar)
        #expect(AgentDetailHeaderControlPlacement(
            headerSharesBar: false, usesVerticalToolbar: true) == .verticalToolbar)
        #expect(AgentDetailHeaderControlPlacement(
            headerSharesBar: true, usesVerticalToolbar: true) == .verticalToolbar)
        #expect(AgentDetailHeaderControlPlacement.floating.reservesHorizontalControlWidth)
        #expect(AgentDetailHeaderControlPlacement.horizontalToolbar.reservesHorizontalControlWidth)
        #expect(!AgentDetailHeaderControlPlacement.verticalToolbar.reservesHorizontalControlWidth)
    }
}
