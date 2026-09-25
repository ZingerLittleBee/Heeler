import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("New Terminal store")
struct NewTerminalStoreTests {
    /// Records what the sheet dispatches without a transport.
    @MainActor
    final class Recorder {
        var destinations: [NewTerminalStore.Destination] = []
        var homeProbes = 0
    }

    private let host = Host.fixture(name: "studio")
    private let identity = ShellTerminalIdentity(paneID: "w1:p9", tabID: "w1:t9", terminalID: "t9")

    private func terminal(for host: Host) -> ConsoleTerminal {
        ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: identity.paneID, revision: 1,
                tabID: identity.tabID, terminalID: identity.terminalID, workspaceID: "w1"),
            workspaceLabel: "api", tabLabel: nil, workspaceOrder: 0, tabPosition: 1,
            snapshotOrder: 0, snapshotAgentKind: nil)
    }

    private func makeStore(
        hosts: [Host]? = nil,
        workspaces: [ConsoleWorkspace] = [
            ConsoleWorkspace(id: "w2", label: "docs", order: 1),
            ConsoleWorkspace(id: "w1", label: "api", order: 0),
        ],
        directories: [String: String] = ["w1": "/srv/api"],
        home: String = "/home/dev",
        refreshes: Bool = true,
        recorder: Recorder
    ) -> NewTerminalStore {
        let terminal = terminal(for: host)
        return NewTerminalStore(
            hosts: hosts ?? [host],
            workspaces: { _ in workspaces },
            directory: { _, id in directories[id] },
            remoteHome: { _ in
                recorder.homeProbes += 1
                return home
            },
            create: { destination, _ in
                recorder.destinations.append(destination)
                return identity
            },
            awaitTerminal: { _, _ in refreshes ? terminal : nil })
    }

    @Test func singleHostIsPreselectedWithItsFirstWorkspaceInOrder() {
        let store = makeStore(recorder: Recorder())
        #expect(store.selectedHostID == host.id)
        #expect(store.workspaces.map(\.id) == ["w1", "w2"])
        #expect(store.selectedWorkspaceID == "w1")
        #expect(store.canSubmit)
    }

    @Test func severalHostsWaitForAChoice() {
        let store = makeStore(hosts: [host, Host.fixture(name: "other")], recorder: Recorder())
        #expect(store.selectedHostID == nil)
        #expect(!store.canSubmit)
    }

    @Test func existingWorkspaceOpensInItsDirectoryWithATrimmedTabName() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.tabLabel = "  logs  "
        await store.submit()
        #expect(
            recorder.destinations == [
                .existing(ShellTerminalCreationRequest(workspaceID: "w1", cwd: "/srv/api", label: "logs"))
            ])
        #expect(recorder.homeProbes == 0)
        #expect(store.state == .created(terminal(for: host).id))
    }

    @Test func workspaceWithoutADirectoryFallsBackToHome() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.selectExistingWorkspace("w2")
        store.tabLabel = "   "
        await store.submit()
        #expect(
            recorder.destinations == [
                .existing(ShellTerminalCreationRequest(workspaceID: "w2", cwd: "/home/dev", label: nil))
            ])
        #expect(recorder.homeProbes == 1)
    }

    @Test func newWorkspaceUsesTheBrowsedDirectoryAndName() async {
        let recorder = Recorder()
        let store = makeStore(recorder: recorder)
        store.applyBrowsedDirectory("relative/path")
        #expect(store.target == .existingWorkspace)
        store.applyBrowsedDirectory("/srv/new")
        store.newWorkspaceLabel = " scratch "
        store.tabLabel = "shell"
        await store.submit()
        #expect(
            recorder.destinations == [
                .newWorkspace(NewWorkspaceSpec(directory: "/srv/new", label: "scratch"), tabLabel: "shell")
            ])
    }

    @Test func nameOnlyNewWorkspaceOpensInHome() async {
        let recorder = Recorder()
        let store = makeStore(workspaces: [], recorder: recorder)
        #expect(!store.canSubmit)
        store.selectNewWorkspace()
        #expect(store.canSubmit)
        await store.submit()
        #expect(
            recorder.destinations == [
                .newWorkspace(NewWorkspaceSpec(directory: "/home/dev", label: nil), tabLabel: nil)
            ])
    }

    @Test func unusableHomeFailsBeforeCreating() async {
        let recorder = Recorder()
        let store = makeStore(directories: [:], home: "relative", recorder: recorder)
        await store.submit()
        #expect(recorder.destinations.isEmpty)
        guard case .failed(let message) = store.state else {
            Issue.record("expected a failure, got \(store.state)")
            return
        }
        #expect(message.contains("relative"))
    }

    @Test func createdTerminalThatNeverAppearsIsReported() async {
        let store = makeStore(refreshes: false, recorder: Recorder())
        await store.submit()
        #expect(store.state == .failed("The terminal was created, but its Workspace hasn't refreshed yet."))
    }

    @Test func switchingHostsResetsTheWorkspaceChoice() {
        let other = Host.fixture(name: "other")
        let store = makeStore(hosts: [host, other], recorder: Recorder())
        store.selectedHostID = host.id
        store.selectExistingWorkspace("w2")
        store.applyBrowsedDirectory("/srv/new")
        store.newWorkspaceLabel = "scratch"
        store.selectedHostID = other.id
        #expect(store.target == .existingWorkspace)
        #expect(store.newWorkspaceDirectory.isEmpty)
        #expect(store.newWorkspaceLabel.isEmpty)
        #expect(store.selectedWorkspaceID == "w1")
    }
}

@Suite("Terminal close scope")
struct TerminalCloseScopeTests {
    private let host = Host.fixture()

    private func shell(_ paneID: String, tab: String, workspace: String = "w1") -> ConsoleTerminal {
        ConsoleTerminal(
            hostID: host.id, hostName: host.displayName, hostUsername: host.username,
            pane: PaneInfo(
                agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
                tabID: tab, terminalID: "terminal-\(paneID)", workspaceID: workspace),
            workspaceLabel: nil, tabLabel: nil, workspaceOrder: 0, tabPosition: 1,
            snapshotOrder: 0, snapshotAgentKind: nil)
    }

    private func agent(_ paneID: String, workspace: String = "w1") -> ConsoleAgent {
        // The fixture puts an Agent in its Workspace's first tab, `<ws>:t1`.
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, workspaceID: workspace)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    @Test func loneShellClosesItsTabAndItsWorkspace() {
        let only = shell("p1", tab: "w1:t1")
        #expect(ConsoleStore.closesTab(of: only, terminals: [only], agents: []))
        #expect(ConsoleStore.closesWorkspaceWithTab(of: only, terminals: [only], agents: []))
    }

    @Test func splitShellClosesOnlyItsPane() {
        let left = shell("p1", tab: "w1:t1")
        let right = shell("p2", tab: "w1:t1")
        #expect(!ConsoleStore.closesTab(of: left, terminals: [left, right], agents: []))
        #expect(!ConsoleStore.closesWorkspaceWithTab(of: left, terminals: [left, right], agents: []))
    }

    @Test func anAgentSharingTheTabKeepsItOpen() {
        let shell = shell("p1", tab: "w1:t1")
        #expect(!ConsoleStore.closesTab(of: shell, terminals: [shell], agents: [agent("p2")]))
    }

    @Test func anotherTabKeepsTheWorkspaceOpen() {
        let closing = shell("p1", tab: "w1:t2")
        let otherTab = [closing, shell("p2", tab: "w1:t3")]
        #expect(ConsoleStore.closesTab(of: closing, terminals: otherTab, agents: []))
        #expect(!ConsoleStore.closesWorkspaceWithTab(of: closing, terminals: otherTab, agents: []))
        // An Agent's tab counts too, while another Workspace's does not.
        #expect(
            !ConsoleStore.closesWorkspaceWithTab(of: closing, terminals: [closing], agents: [agent("p3")]))
        #expect(
            ConsoleStore.closesWorkspaceWithTab(
                of: closing, terminals: [closing, shell("p4", tab: "w2:t1", workspace: "w2")],
                agents: [agent("p5", workspace: "w2")]))
    }
}
