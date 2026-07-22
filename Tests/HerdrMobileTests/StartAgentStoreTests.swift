import Foundation
import Testing

@testable import HerdrMobile

/// New-agent form logic (#12) against a scripted start closure: command
/// tokenizing, host/workspace selection, param assembly, and outcome
/// mapping — no SSH, no ConsoleStore.
@MainActor
@Suite("Start agent store")
struct StartAgentStoreTests {
    /// Records the starts the store dispatches and scripts their outcome.
    private final class StartRecorder {
        var params: [AgentLaunchRequest] = []
        var hostIDs: [Host.ID] = []
        var error: (any Error)?
        var agent = Agent(.fixture(paneID: "w1:pnew", status: .working))

        func record(_ params: AgentLaunchRequest, _ hostID: Host.ID) throws -> Agent {
            self.params.append(params)
            hostIDs.append(hostID)
            if let error { throw error }
            return agent
        }
    }

    private func makeStore(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace] = { _ in [] },
        recorder: StartRecorder
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts, workspaces: workspaces,
            start: { params, hostID in try recorder.record(params, hostID) })
    }

    @Test func tokenizeSplitsOnWhitespaceAndDropsEmpties() {
        #expect(StartAgentStore.tokenize("  claude   --continue \n") == ["claude", "--continue"])
        #expect(StartAgentStore.tokenize("   ").isEmpty)
        #expect(StartAgentStore.tokenize("").isEmpty)
    }

    @Test func preSelectsTheOnlyHost() {
        let host = Host.fixture()
        let single = makeStore(hosts: [host], recorder: StartRecorder())
        #expect(single.selectedHostID == host.id)

        let many = makeStore(
            hosts: [host, .fixture(address: "b.example")], recorder: StartRecorder())
        #expect(many.selectedHostID == nil)
    }

    @Test func canSubmitRequiresAHostAndACommand() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(hosts: [hostA, hostB], recorder: StartRecorder())

        #expect(store.canSubmit == false)
        store.command = "claude"
        #expect(store.canSubmit == false)  // still no host
        store.selectedHostID = hostA.id
        #expect(store.canSubmit == false)  // still no unique agent name
        store.name = "reviewer"
        #expect(store.canSubmit == true)
        store.command = "   "
        #expect(store.canSubmit == false)  // whitespace is no command
    }

    @Test func switchingHostClearsAStaleWorkspacePick() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { $0 == hostA.id ? [ConsoleWorkspace(id: "w1", label: "Proj")] : [] },
            recorder: StartRecorder())

        store.selectedHostID = hostA.id
        store.selectedWorkspaceID = "w1"
        #expect(store.workspaces.map(\.id) == ["w1"])

        store.selectedHostID = hostB.id
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.workspaces.isEmpty)
    }

    @Test func submitForwardsTheAssembledParamsAndSucceeds() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        store.selectedWorkspaceID = "w1"
        store.name = "reviewer"
        store.command = "claude --continue"

        await store.submit()

        #expect(store.state == .started)
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.kind == "claude")
        #expect(recorder.params.first?.name == "reviewer")
        #expect(recorder.params.first?.arguments == ["--continue"])
        #expect(recorder.params.first?.workspaceID == "w1")
    }

    @Test func submitOmitsTheWorkspaceWhenTargetingTheCurrentOne() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        store.name = "writer"
        store.command = "codex"

        await store.submit()

        #expect(recorder.params.first?.workspaceID == nil)
    }

    @Test func submitSurfacesAServerRejection() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(hosts: [host], recorder: recorder)
        store.name = "reviewer"
        store.command = "claude"

        await store.submit()

        #expect(store.state == .failed("herdr rejected the command: no such workspace"))
    }

    @Test func submitIsANoOpWithoutAHostOrCommand() async {
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [.fixture(address: "a.example"), .fixture(address: "b.example")],
            recorder: recorder)
        store.command = "claude"  // host still unselected

        await store.submit()

        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }
}
