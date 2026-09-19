import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console terminal inventory")
struct ConsoleTerminalInventoryTests {
    @Test func includesShellAndAgentPanesAcrossTabsAndSeparatesHostIdentity() async throws {
        let first = Host.fixture(name: "alpha")
        let second = Host.fixture(name: "beta")
        let snapshot = snapshot(
            panes: [
                pane("agent", agent: "claude"),
                pane("shell"),
                pane("other-tab", tab: "w1:t2"),
                pane("other-workspace", workspace: "w2", tab: "w2:t1"),
            ], agents: [.fixture(paneID: "agent")])
        let firstTransport = ScriptedTransport(snapshot: snapshot)
        let secondTransport = ScriptedTransport(snapshot: snapshot)
        let store = makeStore([first.id: firstTransport, second.id: secondTransport])
        defer { store.setHosts([]) }
        store.setHosts([first, second])
        await store.resume()
        try await waitUntil { store.terminals.count == 8 }

        let local = store.terminals(on: first.id, workspaceID: "w1")
        #expect(local.map(\.paneID) == ["agent", "shell", "other-tab"])
        #expect(local.map(\.tabLabel) == ["Main", "Main", "Logs"])
        #expect(local.first?.agentID == ConsoleAgent.ID(hostID: first.id, paneID: "agent"))
        #expect(local.dropFirst().allSatisfy { !$0.isAgent })
        #expect(Set(store.terminals.map(\.id)).count == 8)
        #expect(local.last?.workspaceLabel == "Project")
        #expect(local.last?.cwd == "/home/user/project")
    }

    @Test func shellPaneCreationAndClosureConvergeFromLifecycleEvents() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.terminals.count == 1 }
        #expect(
            await transport.capturedSubscriptions.first?.contains(.global(.paneCreated)) == true)
        await transport.setSnapshot(snapshot(panes: [pane("shell"), pane("split")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:])))
                == true)
        try await waitUntil { store.terminals.count == 2 }
        await transport.setSnapshot(snapshot(panes: [pane("split")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:])))
                == true)
        try await waitUntil { store.terminals.map(\.paneID) == ["split"] }
    }

    @Test func frequentPaneUpdatesRefreshMetadataWithoutSnapshotRequests() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.terminals.count == 1 }
        let count = await transport.snapshotFetchCount
        for index in 0..<20 {
            let changed = pane("shell", title: "Build \(index)", foregroundCwd: "/work/\(index)")
            #expect(await transport.emit(try update(changed)) == true)
        }
        try await waitUntil { store.terminals.first?.displayTitle == "Build 19" }
        #expect(store.terminals.first?.cwd == "/work/19")
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test func paneUpdateDuringSnapshotSurvivesItsOlderResponse() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.terminals.count == 1 }
        let gate = ScriptedTransportCallGate()
        await transport.setSnapshot(snapshot(panes: [pane("shell")], workspaceLabel: "Renamed"))
        await transport.gateNextSnapshot(using: gate)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                == true
        )
        try await waitUntil { await gate.entryCount == 1 }
        #expect(
            await transport.emit(
                try update(pane("shell", title: "New title", foregroundCwd: "/new")))
                == true)
        try await waitUntil { store.terminals.first?.cwd == "/new" }
        await gate.open()
        try await waitUntil { store.terminals.first?.workspaceLabel == "Renamed" }
        #expect(store.terminals.first?.displayTitle == "New title")
        #expect(store.terminals.first?.cwd == "/new")
    }

    @Test func suspensionClearsInventoryAndRejectsAnInflightSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.terminals.count == 1 }
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: gate)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:])))
                == true)
        try await waitUntil { await gate.entryCount == 1 }
        await store.suspend()
        try await waitUntil { store.terminals.isEmpty }
        await gate.open()
        #expect(store.terminals.isEmpty)
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
    }

    private func pane(
        _ id: String, workspace: String = "w1", tab: String = "w1:t1",
        agent: String? = nil, title: String = "Shell", foregroundCwd: String? = nil
    ) -> PaneInfo {
        PaneInfo(
            agentStatus: .idle, focused: false, paneID: id, revision: 1,
            tabID: tab, terminalID: "terminal_\(id)", workspaceID: workspace,
            agent: agent, cwd: "/home/user/project", foregroundCwd: foregroundCwd,
            terminalTitleStripped: title)
    }

    private func snapshot(
        panes: [PaneInfo], agents: [AgentInfo] = [], workspaceLabel: String = "Project"
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 22,
            tabs: [
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Main", number: 1, paneCount: 2,
                    tabID: "w1:t1", workspaceID: "w1"),
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Logs", number: 2, paneCount: 1,
                    tabID: "w1:t2", workspaceID: "w1"),
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Other", number: 1, paneCount: 1,
                    tabID: "w2:t1", workspaceID: "w2"),
            ], version: "0.9.0",
            workspaces: [
                .fixture(workspaceID: "w1", label: workspaceLabel),
                .fixture(workspaceID: "w2", label: "Other project"),
            ])
    }

    private func update(_ pane: PaneInfo) throws -> HerdrEvent {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(pane))
        return HerdrEvent(kind: GlobalEventKind.paneUpdated.kind, data: .object(["pane": value]))
    }

    private func makeStore(_ transports: [Host.ID: ScriptedTransport]) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { host, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                keepalive: nil)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
