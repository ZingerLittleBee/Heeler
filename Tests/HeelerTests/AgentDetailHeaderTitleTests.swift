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

    @Test func namesTheTaskHarnessAndLaunchFolder() {
        let title = AgentDetailHeaderTitle(makeAgent())
        #expect(title == AgentDetailHeaderTitle(
            title: "Harden webhook retries", kind: "codex",
            directory: "/Users/bee/workspace/payments-api"))
        #expect(title.folder == "payments-api")
    }

    @Test(arguments: [
        ("/Users/bee", "bee"), ("/home/dev/payments-api/", "payments-api"),
        ("C:\\Users\\dev\\payments-api\\", "payments-api"), ("/", "/"),
    ])
    func folderUsesTheHostsLastPathComponent(path: String, name: String) {
        #expect(AgentDetailHeaderTitle(makeAgent(cwd: path)).folder == name)
    }

    /// A custom Agent name stands in for an empty task title but never for
    /// the harness kind, which still identifies its mark.
    @Test func customNameFillsAnEmptyTitleButNotTheHarness() {
        let title = AgentDetailHeaderTitle(makeAgent(kind: "grok", title: "", name: "grokcapa"))
        #expect(title.title == "grokcapa")
        #expect(title.kind == "grok")
    }

    @Test func unknownKindIsPreservedAndEmptyDirectoryIsLeftOut() {
        let title = AgentDetailHeaderTitle(makeAgent(kind: "mystery", cwd: ""))
        #expect(title.kind == "mystery")
        #expect(title.directory == nil)
        #expect(title.folder == nil)
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
