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
        let snapshotGate = ScriptedTransportCallGate()
        let subscriptionGate = ScriptedTransportCallGate()
        defer {
            Task {
                await snapshotGate.open()
                await subscriptionGate.open()
            }
        }
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { await snapshotGate.entryCount == 1 }
        await transport.gateNextSubscription(using: subscriptionGate)
        await snapshotGate.open()
        try await waitUntil { store.terminals.count == 1 }
        try await waitUntil { await subscriptionGate.entryCount == 1 }
        let initialCount = await transport.snapshotFetchCount
        #expect(initialCount == 1)
        await subscriptionGate.open()
        try await waitUntil { await transport.snapshotFetchCount > initialCount }
        await store.refreshSidebarLayouts()
        let count = await transport.snapshotFetchCount
        for index in 0..<20 {
            let changed = pane("shell", title: "Build \(index)", foregroundCwd: "/work/\(index)")
            #expect(await transport.emit(try update(changed)) == true)
        }
        try await waitUntil { store.terminals.first?.displayTitle == "Build 19" }
        #expect(store.terminals.first?.cwd == "/work/19")
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test func agentDirectoryFollowsPaneUpdatesWithoutChangingLaunchDirectoryUsers() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: snapshot(
                panes: [pane("agent", foregroundCwd: "/first-checkout")],
                agents: [agent(cwd: "/launch", foregroundCwd: "/snapshot-checkout")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.first?.directory == "/first-checkout" }
        await store.refreshSidebarLayouts()
        let count = await transport.snapshotFetchCount

        #expect(
            await transport.emit(try update(pane("agent", foregroundCwd: "/second-checkout")))
                == true)
        try await waitUntil { store.agents.first?.directory == "/second-checkout" }

        let row = try #require(store.agents.first)
        #expect(row.agent.cwd == "/launch")
        #expect(row.displayCwd == "/launch")
        #expect(row.skillsProjectRoot == "/launch")
        #expect(row.shellTerminalCreationRequest?.cwd == "/launch")
        #expect(row.matchesAgentSearch("/launch"))
        #expect(!row.matchesAgentSearch("/second-checkout"))
        #expect(
            AgentRowRenderer.render(layout: AgentRowLayout(rows: [[.init(.directory)]]), agent: row)
                .flatMap { $0 }.map(\.text) == ["/launch"])
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test(arguments: [true, false])
    func agentDirectoryUpdateDuringSnapshotSurvivesItsOlderResponse(includesPane: Bool) async throws {
        let host = Host.fixture()
        let panes = includesPane ? [pane("agent", foregroundCwd: "/old-pane")] : []
        let agents = [agent(foregroundCwd: "/old-snapshot")]
        let transport = ScriptedTransport(snapshot: snapshot(panes: panes, agents: agents))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.count == 1 }
        await store.refreshSidebarLayouts()
        let count = await transport.snapshotFetchCount
        let gate = ScriptedTransportCallGate()
        defer { Task { await gate.open() } }
        await transport.setSnapshot(snapshot(panes: panes, agents: agents, workspaceLabel: "Renamed"))
        await transport.gateNextSnapshot(using: gate)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                == true)
        try await waitUntil { await gate.entryCount == 1 }
        #expect(await transport.emit(try update(pane("agent", foregroundCwd: "/new-checkout"))) == true)
        try await waitUntil { store.agents.first?.directory == "/new-checkout" }
        await gate.open()
        try await waitUntil { store.agents.first?.workspaceLabel == "Renamed" }

        #expect(store.agents.first?.directory == "/new-checkout")
        #expect(store.agents.first?.agent.cwd == "/launch")
        #expect(await transport.snapshotFetchCount == count + 1)

        // A subsequent snapshot replaces the earlier live directory.
        await transport.setSnapshot(snapshot(
            panes: [], agents: [agent(foregroundCwd: "/later-snapshot")]))
        await store.refreshSidebarLayouts()
        #expect(store.agents.first?.directory == "/later-snapshot")
    }

    @Test func agentDirectoryUsesPaneThenSnapshotThenCheckoutFallbacks() async throws {
        let cases: [(pane: PaneInfo?, agent: AgentInfo, checkout: String?, expected: String?)] = [
            (pane("agent", foregroundCwd: "/pane-process"),
             agent(foregroundCwd: "/snapshot-process"), "/checkout", "/pane-process"),
            (pane("agent", foregroundCwd: "", cwd: "/pane-shell"),
             agent(foregroundCwd: "/snapshot-process"), "/checkout", "/pane-shell"),
            (pane("agent", cwd: nil),
             agent(foregroundCwd: "/snapshot-process"), "/checkout", "/snapshot-process"),
            (pane("agent", foregroundCwd: "", cwd: ""),
             agent(foregroundCwd: ""), "/checkout", "/launch"),
            (nil, agent(foregroundCwd: "/snapshot-process"), "/checkout", "/snapshot-process"),
            (nil, agent(), "/checkout", "/launch"),
            (nil, agent(cwd: nil), "/checkout", "/checkout"),
            (pane("agent", foregroundCwd: "", cwd: ""),
             agent(cwd: "", foregroundCwd: ""), "/checkout", "/checkout"),
            (nil, agent(cwd: nil), nil, nil),
            (pane("agent", cwd: ""), agent(cwd: "", foregroundCwd: ""), "", nil),
            (pane("agent", workspace: "w2", foregroundCwd: "/wrong-workspace"),
             agent(), nil, "/launch"),
            (pane("agent", tab: "w1:t2", foregroundCwd: "/wrong-tab"),
             agent(), nil, "/launch"),
            (pane("agent", foregroundCwd: "/reused-pane", terminalID: "replacement"),
             agent(), nil, "/launch"),
            // A remote path is not trimmed: spaces can be part of its name.
            (pane("agent", foregroundCwd: "/checkout/space "), agent(), nil, "/checkout/space "),
        ]
        for testCase in cases {
            let host = Host.fixture()
            let transport = ScriptedTransport(snapshot: snapshot(
                panes: testCase.pane.map { [$0] } ?? [], agents: [testCase.agent],
                checkoutPath: testCase.checkout))
            let store = makeStore([host.id: transport])
            defer { store.setHosts([]) }
            store.setHosts([host])
            await store.resume()
            try await waitUntil { store.agents.count == 1 }
            #expect(store.agents.first?.directory == testCase.expected)
        }
    }

    @Test(arguments: [true, false])
    func agentDirectoryDropsMissingLiveFieldsInsteadOfKeepingAnOlderPaneDirectory(
        includesPane: Bool
    ) async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(
            panes: includesPane ? [pane("agent", foregroundCwd: "/old")] : [],
            agents: [agent(foregroundCwd: "/snapshot-process")], checkoutPath: "/checkout"))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.count == 1 }
        await store.refreshSidebarLayouts()
        let count = await transport.snapshotFetchCount

        #expect(await transport.emit(try update(pane("agent", foregroundCwd: "/new"))) == true)
        try await waitUntil { store.agents.first?.directory == "/new" }
        #expect(
            await transport.emit(try update(pane("agent", foregroundCwd: "", cwd: "/pane-shell")))
                == true)
        try await waitUntil { store.agents.first?.directory == "/pane-shell" }
        #expect(await transport.emit(try update(pane("agent", cwd: nil))) == true)
        try await waitUntil { store.agents.first?.directory == "/snapshot-process" }

        #expect(store.agents.first?.skillsProjectRoot == "/checkout")
        #expect(store.agents.first?.shellTerminalCreationRequest?.cwd == "/launch")
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test func unrelatedPaneUpdatesCannotChangeAgentDirectory() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(
            panes: [pane("agent", foregroundCwd: "/current"), pane("shell")], agents: [agent()]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.count == 1 }
        await store.refreshSidebarLayouts()
        let count = await transport.snapshotFetchCount
        let unrelated = [
            pane("agent", workspace: "w2", foregroundCwd: "/wrong-workspace"),
            pane("agent", tab: "w1:t2", foregroundCwd: "/wrong-tab"),
            pane("agent", foregroundCwd: "/reused-pane", terminalID: "replacement"),
            pane("other-agent", foregroundCwd: "/wrong-agent"),
        ]
        for (index, changed) in unrelated.enumerated() {
            #expect(await transport.emit(try update(changed)) == true)
            // A later event on the same stream proves the rejected one was consumed.
            #expect(await transport.emit(try update(pane("shell", title: "Processed \(index)"))) == true)
            try await waitUntil {
                store.terminals.first { $0.paneID == "shell" }?.displayTitle == "Processed \(index)"
            }
            #expect(store.agents.first?.directory == "/current")
        }
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test func titleOnlyPaneUpdatesKeepAgentValuesEqual() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(
            panes: [pane("agent", foregroundCwd: "/current")], agents: [agent()]))
        // Let the initial snippet settle before comparing complete Agent values.
        await transport.setPaneText("Ready for input\n", paneID: "agent")
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.first?.lastOutputSnippet == "Ready for input" }
        await store.refreshSidebarLayouts()
        let before = store.agents
        let count = await transport.snapshotFetchCount
        for index in 0..<20 {
            #expect(
                await transport.emit(try update(
                    pane("agent", title: "Title \(index)", foregroundCwd: "/current"))) == true)
        }
        try await waitUntil { store.terminals.first?.displayTitle == "Title 19" }
        #expect(store.agents == before)
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
        agent: String? = nil, title: String = "Shell", foregroundCwd: String? = nil,
        cwd: String? = "/home/user/project", terminalID: String? = nil
    ) -> PaneInfo {
        PaneInfo(
            agentStatus: .idle, focused: false, paneID: id, revision: 1,
            tabID: tab, terminalID: terminalID ?? "terminal_\(id)", workspaceID: workspace,
            agent: agent, cwd: cwd, foregroundCwd: foregroundCwd,
            terminalTitleStripped: title)
    }

    private func agent(cwd: String? = "/launch", foregroundCwd: String? = nil) -> AgentInfo {
        AgentInfo(
            agentStatus: .idle, focused: false, paneID: "agent", revision: 1,
            tabID: "w1:t1", terminalID: "terminal_agent", workspaceID: "w1",
            agent: "claude", cwd: cwd, foregroundCwd: foregroundCwd)
    }

    private func snapshot(
        panes: [PaneInfo], agents: [AgentInfo] = [], workspaceLabel: String = "Project",
        checkoutPath: String? = nil
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
                .fixture(
                    workspaceID: "w1", label: workspaceLabel,
                    repoName: checkoutPath.map { _ in "Project" }, checkoutPath: checkoutPath),
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
