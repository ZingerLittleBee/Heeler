import Foundation
import Observation
import Synchronization
import Testing
import SwiftUI
import UIKit

@testable import Heeler

@MainActor
@Suite("Sidebar Console integration", .timeLimit(.minutes(1)))
struct SidebarConsoleIntegrationTests {
    @Test func savingFieldsUpdatesTheMountedConsoleWithoutRefreshingAgents() async throws {
        let composition = DemoScreenshotComposition.make()
        let store = composition.console
        store.setHosts(composition.hosts.hosts)
        await store.resume()
        defer { store.setHosts([]) }
        let deadline = ContinuousClock.now + .seconds(3)
        while store.agents.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let agent = try #require(store.agents.first)
        // The Console reopens its last tab; the rows under test are on Agents.
        let lastTab = UserDefaults.standard.object(forKey: "console.last-list-tab")
        UserDefaults.standard.removeObject(forKey: "console.last-list-tab")
        defer { UserDefaults.standard.set(lastTab, forKey: "console.last-list-tab") }
        let view = ConsoleView(
            hosts: composition.hosts, console: store,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets),
            inputMode: composition.inputMode, detailSurface: composition.detailSurface,
            appearance: composition.appearance,
            pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences,
            relaySettings: composition.relaySettings,
            notificationRouter: composition.notificationRouter,
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity)
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let initial = AgentCardPresentation(agent: agent, layout: store.rowLayout(for: agent.hostID)).headline
        let expected = Array(repeating: agent.agent.displayName, count: 3).joined(separator: " · ")
        // iOS 26 does not materialize hosted SwiftUI accessibility without an
        // assistive client. AX rendering is verified only on iOS 27+; every
        // runtime still mounts the Console and checks Save and Observation.
        if #available(iOS 27, *) {
            let mountDeadline = ContinuousClock.now + .seconds(2)
            while !Self.labels(in: controller.view).contains(where: { $0.contains(initial) }),
                  ContinuousClock.now < mountDeadline {
                try await Task.sleep(for: .milliseconds(10))
                controller.view.layoutIfNeeded()
            }
            try #require(Self.labels(in: controller.view).contains(where: { $0.contains(initial) }))
            try #require(!Self.labels(in: controller.view).contains(where: { $0.contains(expected) }))
        }
        let agents = store.agents
        let snapshots = store.sidebarSnapshots.states
        let rowInvalidated = Mutex(false)
        // Track the same production read used by ConsoleView's AgentCardView.
        let beforeSave = withObservationTracking {
            AgentCardPresentation(agent: agent, layout: store.rowLayout(for: agent.hostID)).headline
        } onChange: {
            rowInvalidated.withLock { $0 = true }
        }
        try #require(beforeSave != expected)
        let editor = AgentListFieldsEditor(
            layouts: store.rowLayouts, snapshots: store.sidebarSnapshots, fetch: { _ in nil })
        editor.beginEditing()
        editor.update(agent.hostID) {
            $0 = AgentRowLayout(rows: [[.init(.agent), .init(.agent), .init(.agent)]])
        }
        #expect(!rowInvalidated.withLock { $0 })
        #expect(AgentCardPresentation(agent: agent, layout: store.rowLayout(for: agent.hostID)).headline == beforeSave)
        editor.save()
        #expect(!editor.isEditing)
        #expect(editor.errorMessage == nil)
        #expect(rowInvalidated.withLock { $0 }, "Save must invalidate the Console's observed row layout")
        #expect(AgentCardPresentation(agent: agent, layout: store.rowLayout(for: agent.hostID)).headline == expected)
        // No suspension or refresh separates the draft, Save, and these reads.
        #expect(store.agents == agents)
        #expect(store.sidebarSnapshots.states == snapshots)
        if #available(iOS 27, *) {
            let updateDeadline = ContinuousClock.now + .seconds(2)
            while !Self.labels(in: controller.view).contains(where: { $0.contains(expected) }),
                  ContinuousClock.now < updateDeadline {
                try await Task.sleep(for: .milliseconds(10))
                controller.view.layoutIfNeeded()
            }
            #expect(Self.labels(in: controller.view).contains(where: { $0.contains(expected) }),
                    "Saved headline must reach the mounted Console without a snapshot refresh")
        }
    }

    private static func labels(in root: UIView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel { labels.append(label) }
            for element in node.accessibilityElements ?? [] {
                if let object = element as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return labels
    }

    @Test func statusPriorityThenSnapshotOrderHoldsAndPinStillLeads() {
        let host = Host.fixture()
        let firstDone = row(host, pane: "firstDone", status: .done, order: 0, sequence: 1)
        let laterDone = row(host, pane: "laterDone", status: .done, order: 2, sequence: 7)
        let middleDone = row(host, pane: "middleDone", status: .done, order: 1, sequence: 7)
        let blocked = row(host, pane: "blocked", status: .blocked, order: 3, sequence: 0)
        let rows = [laterDone, firstDone, middleDone, blocked]
        #expect(rows.consoleSorted().map(\.agent.paneID)
            == ["blocked", "firstDone", "middleDone", "laterDone"])
        #expect(rows.consoleSorted {
            $0.id == laterDone.id ? 0 : nil
        }.map(\.agent.paneID) == ["laterDone", "blocked", "firstDone", "middleDone"])
    }

    @Test func statusPriorityAcrossHostsAndServersHasOneStableOrderAcrossInputPermutations() {
        let m3TUI = Host(name: "m3", address: "m3.example", username: "dev")
        let m3Tmux = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let beta = Host.fixture(name: "beta")
        let tuiIdle = row(m3TUI, pane: "tui-idle", status: .idle, order: 0)
        let tmuxWorking = row(m3Tmux, pane: "tmux-working", status: .working, order: 0)
        let tuiWorking = row(m3TUI, pane: "tui-working", status: .working, order: 1)
        let betaBlocked = row(beta, pane: "beta-blocked", status: .blocked, order: 0)
        let rows = [tuiIdle, tmuxWorking, tuiWorking, betaBlocked]
        let serverOrder: [Host.ID: Int] = [m3TUI.id: 0, m3Tmux.id: 1, beta.id: 2]
        for a in rows.indices {
            for b in rows.indices where b != a {
                for c in rows.indices where c != a && c != b {
                    let d = rows.indices.first { $0 != a && $0 != b && $0 != c }!
                    let permutation = [rows[a], rows[b], rows[c], rows[d]]
                    #expect(permutation.consoleSorted(serverOrder: serverOrder).map(\.agent.paneID)
                        == ["beta-blocked", "tui-working", "tmux-working", "tui-idle"])
                    #expect(permutation.consoleSorted(serverOrder: serverOrder) {
                        $0.id == tuiIdle.id ? 0 : nil
                    }.map(\.agent.paneID) == ["tui-idle", "beta-blocked", "tui-working", "tmux-working"])
                }
            }
        }
    }

    /// A Rex Agent takes its place in the same order as the other kinds':
    /// Blocked, Done (a finished turn this device has not looked at), Working,
    /// Idle, then Unknown, as `RexAgentRule` and `RexTurnState` read each
    /// terminal, whatever order Rex lists them in. The flat list, the Host
    /// filter, By Host and By Workspace agree, for a Host whose one Server is
    /// Rex and for one with a Herdr TUI Server on beside it, and a Pin on a
    /// Rex Agent leads as any Pin does.
    @Test func rexAgentsTakeTheirPlaceInTheOneStatusPriorityOrder() async throws {
        let suite = "sidebar-rex-order-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let socket = RexSocket(path: "/run/user/1000/rex/server.sock")
        let m3TUI = Host(name: "m3", address: "m3.example", username: "dev")
        let m3Rex = Host(name: "m3", address: "m3.example", username: "dev", serverKind: .rex, rexSocket: socket)
        let lab = Host(name: "lab", address: "lab.example", username: "dev", serverKind: .rex, rexSocket: socket)
        let records = HostStore(volatileHosts: [m3TUI, m3Rex, lab]).consoleHosts
        #expect(records.map(\.id) == [m3TUI.id, m3Rex.id, lab.id])

        let tui = ScriptedTransport(snapshot: .fixture(
            agents: [
                .fixture(paneID: "tui-working", status: .working, workspaceID: "w-api"),
                .fixture(paneID: "tui-done", status: .done, workspaceID: "w-web"),
                .fixture(paneID: "tui-idle", status: .idle, workspaceID: "w-api"),
            ],
            workspaces: [.fixture(workspaceID: "w-api", label: "api"), .fixture(workspaceID: "w-web", label: "web")]))
        /// One window of Codex terminals, each named for what its record
        /// reads, holding the record its last report left, or none.
        func rexSession(_ id: String, label: String, _ terminals: [(name: String, state: String?)])
            -> FakeRexWorld.Session
        {
            let blocks = terminals.enumerated().map { index, terminal in
                var block = FakeRexWorld.Block.running("block:\(terminal.name)", program: "codex")
                block.label = terminal.name
                block.processID = 5100 + index
                block.status = terminal.state.map { block.record($0, app: "codex") }
                return block
            }
            func tiled(_ ids: ArraySlice<String>) -> FakeRexWorld.Layout {
                let first = FakeRexWorld.Layout.block(ids[ids.startIndex])
                return ids.count == 1 ? first : .split(first, tiled(ids.dropFirst()))
            }
            return FakeRexWorld.Session(
                id: id, label: label, activeWindowID: "window:a",
                windows: [
                    FakeRexWorld.Window(
                        id: "window:a", label: "agents",
                        layers: [FakeRexWorld.Layer(layout: tiled(blocks.map(\.id)[...]), blocks: blocks)])
                ])
        }
        // A first sight of done is a turn this device has not looked at.
        let m3World = FakeRexWorld(sessions: [
            rexSession("session:studio", label: "studio", [
                ("rex-idle", "idle"), ("rex-working", "working"), ("rex-unknown", nil), ("rex-done", "done"),
                ("rex-blocked", "blocked"),
            ])
        ])
        let labWorld = FakeRexWorld(
            instanceID: "instance-0002",
            sessions: [rexSession("session:bench", label: "bench", [("lab-working", "working"), ("lab-done", "done")])])
        let m3Server = FakeRexServer()
        await m3World.install(on: m3Server)
        let labServer = FakeRexServer()
        await labWorld.install(on: labServer)
        let rexConnections = Mutex([
            m3Rex.id: ScriptedRexHost(control: [.server(m3Server)]),
            lab.id: ScriptedRexHost(control: [.server(labServer)]),
        ])
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults),
            makeSession: { host, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: {
                    guard host.id == m3TUI.id else { throw TransportError.cancelled }
                    return tui
                }, keepalive: nil)
            },
            makeRexSession: { host in
                RexHostSession(storedSocket: host.rexSocket) { socket, previous in
                    guard let connection = rexConnections.withLock({ $0.removeValue(forKey: host.id) }) else {
                        throw TransportError.sshUnreachable(detail: "no more scripted connections")
                    }
                    return try await RexSSHTransport.connect(
                        over: connection, socket: socket, resuming: previous, options: .testing)
                }
            })
        defer { store.setHosts([]) }
        store.setHosts(records)
        await store.resume()

        func name(_ agent: ConsoleAgent) -> String { agent.agent.name ?? agent.agent.paneID }
        let statuses: [String: AgentStatus] = [
            "rex-blocked": .blocked, "rex-done": .done, "rex-working": .working, "rex-idle": .idle,
            "rex-unknown": .unknown, "lab-done": .done, "lab-working": .working,
            "tui-done": .done, "tui-working": .working, "tui-idle": .idle,
        ]
        try await waitForConsole(store) {
            Dictionary(store.agents.map { (name($0), $0.agent.status) }) { first, _ in first } == statuses
        }
        let backends: [AgentBackend: Int] = Dictionary(grouping: store.agents.compactMap(\.backend)) { $0 }
            .mapValues(\.count)
        #expect(backends == [.rex: 7, .tui: 3])

        // Status first; a Host's name, then the catalog's Server order, for equals.
        let ordered = [
            "rex-blocked", "lab-done", "tui-done", "rex-done", "lab-working", "tui-working", "rex-working",
            "tui-idle", "rex-idle", "rex-unknown",
        ]
        #expect(store.agents.map(name) == ordered)
        #expect(store.chatDisplayAgents.map(name) == ordered)
        let m3 = Set([m3TUI.id, m3Rex.id])
        let m3Ordered = ordered.filter { !$0.hasPrefix("lab-") }
        #expect(store.chatDisplayAgents.filter { m3.contains($0.hostID) }.map(name) == m3Ordered)
        #expect(store.chatDisplayAgents.filter { $0.hostID == lab.id }.map(name) == ["lab-done", "lab-working"])

        let presentation = ConsoleListPresentationStore(defaults: defaults)
        let byHost = presentation.sections(hosts: records, console: store)
        #expect(byHost.map(\.hostName) == ["m3", "lab"])
        #expect(byHost.map { $0.agents.map(name) } == [m3Ordered, ["lab-done", "lab-working"]])
        // A Workspace follows its first Agent in that order, across the Host's Servers.
        let cards = presentation.workspaceSections(hosts: records, console: store)
        #expect(cards.map(\.title) == ["studio", "web", "api", "bench"])
        #expect(cards.map(\.hostName) == ["m3", "m3", "m3", "lab"])
        #expect(cards.map { $0.agents.map(name) } == [
            ["rex-blocked", "rex-done", "rex-working", "rex-idle", "rex-unknown"], ["tui-done"],
            ["tui-working", "tui-idle"], ["lab-done", "lab-working"],
        ])

        let unknown = try #require(store.agents.first { name($0) == "rex-unknown" })
        store.togglePin(hostID: m3Rex.id, paneID: unknown.agent.paneID)
        #expect(store.agents.map(name) == ["rex-unknown"] + Array(ordered.dropLast()))
        #expect(presentation.sections(hosts: records, console: store).first?.agents.map(name)
            == ["rex-unknown"] + Array(m3Ordered.dropLast()))
    }

    @Test func consoleBorrowsConnectionsIgnoresPluginSpacesSortAndKeepsGroupingIndependent() async throws {
        let suite = "sidebar-console-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = Host.fixture(name: "alpha", address: "alpha.example")
        let beta = Host.fixture(name: "beta", address: "beta.example")
        let a = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "a0", status: .idle), .fixture(paneID: "a1", status: .blocked),
        ]))
        let b = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "b0", status: .idle), .fixture(paneID: "b1", status: .blocked),
        ]))
        await a.setSidebarLayout(try snapshot(sort: "spaces"))
        await b.setSidebarLayout(try snapshot(sort: "priority"))
        let connects = Mutex(0)
        let transports = [alpha.id: a, beta.id: b]
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { host, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: {
                connects.withLock { $0 += 1 }
                guard let transport = transports[host.id] else { throw TransportError.cancelled }
                return transport
            }, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([alpha, beta])
        await store.resume()
        try await waitForSnapshots(store, hosts: [alpha.id, beta.id])
        // Plugin `agent_panel_sort = "spaces"` never overrides status-priority ordering.
        #expect(store.agents.map(\.agent.paneID) == ["a1", "b1", "a0", "b0"])
        #expect(connects.withLock { $0 } == 2)
        let plugin = store.rowLayout(for: alpha.id)
        // herdr's rows_by_agent is decoded but never applied in the Console.
        #expect(plugin.rows == [[.init(.terminalTitleStripped)], [], []])
        #expect(plugin.rowsByAgent.isEmpty)
        let first = try #require(store.agents.first)
        #expect(AgentCardPresentation(agent: first, layout: plugin).headline == "Task")
        let observed = Mutex(false)
        withObservationTracking {
            _ = store.rowLayout(for: alpha.id)
        } onChange: {
            observed.withLock { $0 = true }
        }
        try store.rowLayouts.setLayouts([alpha.id: AgentRowLayout(rows: []), beta.id: AgentRowLayout(rows: [[.init(.agent)]])])
        #expect(observed.withLock { $0 })
        #expect(store.rowLayout(for: alpha.id).rows.isEmpty)
        #expect(store.rowLayout(for: beta.id).rows == [[.init(.agent)]])
        #expect(store.agents.map(\.agent.paneID) == ["a1", "b1", "a0", "b0"])
        let switcher = TerminalAgentSwitcherItem(
            agent: first, pins: store.pins, layout: store.rowLayout(for: alpha.id))
        #expect(switcher.title == "claude")
        let presentation = ConsoleListPresentationStore(defaults: defaults)
        presentation.select(.grouped)
        #expect(presentation.sections(hosts: [alpha, beta], agents: store.agents).map { $0.agents.map(\.agent.paneID) }
            == [["a1", "a0"], ["b1", "b0"]])
        store.togglePin(hostID: beta.id, paneID: "b0")
        #expect(store.agents.map(\.agent.paneID) == ["b0", "a1", "b1", "a0"])
        await a.setSidebarLayout(try snapshot(sort: "priority"))
        await store.refreshSidebarLayouts()
        #expect(store.agents.map(\.agent.paneID) == ["b0", "a1", "b1", "a0"])
        #expect(connects.withLock { $0 } == 2)
        #expect(store.rowLayout(for: alpha.id).rows.isEmpty)
    }

    @Test func consoleSuspensionRejectsAnInFlightSnapshot() async throws {
        let suite = "sidebar-suspend-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "p")]))
        await transport.setSidebarLayout(try snapshot(sort: "spaces"))
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        // Hold the layout store's own borrowed read; the Settings action now
        // also refreshes Agent metadata before reading the layout file.
        let refresh = Task {
            await store.sidebarSnapshots.refresh(transports: store, didChange: {})
        }
        await gate.waitForEntry()
        await store.suspend()
        #expect(store.sidebarSnapshots.states.isEmpty)
        await gate.open()
        await refresh.value
        #expect(store.sidebarSnapshots.states.isEmpty)
        #expect(store.rowLayout(for: host.id) == .consoleDefault)
    }

    @Test func statusEventsReorderByStatusKeepSnapshotOrderAndRefreshLiteralRowsWithOneCoalescedFollowUp() async throws {
        let suite = "sidebar-live-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let b = metadata(pane: "b", status: .done, sequence: 2, title: "Other task", note: "other")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 1, title: "Task A", note: "old"), b,
        ]))
        await transport.setSidebarLayout(try snapshot(sort: "priority"))
        let store = liveStore(defaults: defaults, connect: { transport })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await transport.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        #expect(store.agents.map(\.agent.paneID) == ["a", "b"])
        try store.rowLayouts.setLayout(.init(rows: [
            [.init(.terminalTitleStripped)], [.init(.custom("note")), .init(.terminalTitle)],
        ]), for: host.id)

        let firstRead = ScriptedTransportCallGate()
        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .working, sequence: 3, title: "In progress", note: "pending"), b,
        ]))
        await transport.gateNextSnapshot(using: firstRead)
        #expect(await transport.emit(.agentStatusChanged(paneID: "a", status: .working)))
        await firstRead.waitForEntry()
        let countAtEntry = await transport.snapshotFetchCount
        try await waitForConsole(store) { store.agents.map(\.agent.paneID) == ["b", "a"] }

        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 4, title: "Task B", note: "**literal** [link](url)"), b,
        ]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "a", status: .done)))
        try await waitForConsole(store) { store.agents.map(\.agent.paneID) == ["a", "b"] }
        #expect(await transport.snapshotFetchCount == countAtEntry)
        await firstRead.open()
        try await waitForConsole(store) { store.agents.first?.agent.stateChangeSeq == 4 }
        #expect(await transport.snapshotFetchCount == countAtEntry + 1)
        #expect(store.agents.map(\.agent.paneID) == ["a", "b"])
        let agent = try #require(store.agents.first)
        let layout = store.rowLayout(for: host.id)
        let card = AgentCardPresentation(agent: agent, layout: layout)
        #expect(card.headline == "Task B")
        #expect(card.additionalRows == ["**literal** [link](url) · ◑ Task B"])
        #expect(TerminalAgentSwitcherItem(agent: agent, pins: store.pins, layout: layout).title == "Task B")
        store.togglePin(hostID: host.id, paneID: "b")
        #expect(store.agents.first?.agent.paneID == "b")

        // The explicit Settings refresh also refreshes values when no event
        // has occurred, not just the layout file's field names.
        await transport.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 5, title: "Task C", note: "manual"), b,
        ]))
        await store.refreshSidebarLayouts()
        let refreshed = try #require(store.agents.first(where: { $0.agent.paneID == "a" }))
        #expect(AgentCardPresentation(agent: refreshed, layout: layout).headline == "Task C")
        #expect(store.agents.first?.agent.paneID == "b")
    }

    @Test func subscriptionsAddReorderedOnlyAfterCurrentProtocolSupport() {
        for version in [nil, 17, 18] as [Int?] {
            let subscriptions = HostConsoleProjection.subscriptions(paneIDs: ["a"], protocolVersion: version)
            #expect(!subscriptions.contains(.global(.workspaceReordered)))
            #expect(subscriptions.contains(.global(.workspaceMoved)))
            #expect(subscriptions.contains(.pane(.agentStatusChanged, paneID: "a")))
        }
        for version in [19, 20] {
            #expect(HostConsoleProjection.subscriptions(paneIDs: ["a"], protocolVersion: version)
                .contains(.global(.workspaceReordered)))
        }
    }

    @Test func workspaceOrderEventsRefreshSpacesOrderThroughTheSubscribedStream() async throws {
        let suite = "sidebar-order-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let a = AgentInfo.fixture(paneID: "a", workspaceID: "wa")
        let b = AgentInfo.fixture(paneID: "b", workspaceID: "wb")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [a, b], protocolVersion: 20))
        await transport.setSidebarLayout(try snapshot(sort: "spaces"))
        let store = liveStore(defaults: defaults, connect: { transport })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await transport.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        let subscriptions = try #require(await transport.capturedSubscriptions.last)
        #expect(subscriptions.contains(.global(.workspaceReordered)))
        #expect(subscriptions.contains(.global(.workspaceMoved)))
        // Terminal titles and paths use local pane deltas; only membership
        // and Workspace ordering events request an authoritative resnapshot.
        #expect(subscriptions.contains(.global(.paneUpdated)))
        for (kind, remote) in [(GlobalEventKind.workspaceReordered, [b, a]), (.workspaceMoved, [a, b])] {
            await transport.setSnapshot(.fixture(agents: remote, protocolVersion: 20))
            #expect(await transport.emit(HerdrEvent(kind: kind.kind, data: .object([:]))))
            try await waitForConsole(store) { store.agents.map(\.agent.paneID) == remote.map(\.paneID) }
            #expect(store.agents.map(\.snapshotOrder) == [0, 1])
        }
    }

    @Test func statusDrivenSnapshotFromAnOldConnectionCannotPublishMetadataAfterResume() async throws {
        let suite = "sidebar-generation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host.fixture()
        let old = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 1, title: "Initial", note: "old"),
        ]))
        let fresh = ScriptedTransport(snapshot: .fixture(agents: [
            metadata(pane: "a", status: .done, sequence: 10, title: "Fresh", note: "new"),
        ]))
        await old.setSidebarLayout(try snapshot(sort: "priority"))
        await fresh.setSidebarLayout(try snapshot(sort: "priority"))
        let sequence = SequencedTransportConnector([old, fresh])
        let store = liveStore(defaults: defaults, connect: { try await sequence.connect() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitForSnapshots(store, hosts: [host.id])
        try await old.waitForLiveSubscription(containing: [.pane(.agentStatusChanged, paneID: "a")])
        await store.refreshSidebarLayouts()
        let generation = try #require(store.hostConnectionGenerations[host.id])
        let oldRead = ScriptedTransportCallGate()
        await old.setSnapshot(.fixture(agents: [
            metadata(pane: "a", status: .working, sequence: 2, title: "Stale", note: "stale"),
        ]))
        await old.gateNextSnapshot(using: oldRead)
        #expect(await old.emit(.agentStatusChanged(paneID: "a", status: .working)))
        await oldRead.waitForEntry()
        await store.suspend()
        let freshRead = ScriptedTransportCallGate()
        await fresh.gateNextSnapshot(using: freshRead)
        await store.resume()
        try await waitForConsole(store) { (store.hostConnectionGenerations[host.id] ?? 0) > generation }
        await oldRead.open()
        await freshRead.waitForEntry()
        // Entering the next read proves the old response has crossed the
        // production epoch guard; it did not repopulate the empty projection.
        #expect(store.agents.isEmpty)
        await freshRead.open()
        try await waitForConsole(store) { store.agents.first?.agent.stateChangeSeq == 10 }
        #expect(store.agents.first?.agent.terminalTitleStripped == "Fresh")
        #expect(store.agents.first?.agent.tokens["note"] == "new")
    }

    private func liveStore(
        defaults: UserDefaults,
        connect: @escaping @Sendable () async throws -> any Transport
    ) -> ConsoleStore {
        ConsoleStore(pins: PinnedAgentsStore(defaults: defaults), rowLayouts: AgentRowLayoutStore(defaults: defaults)) {
            _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: connect, keepalive: nil)
        }
    }

    private func metadata(pane: String, status: AgentStatus, sequence: Int, title: String, note: String) -> AgentInfo {
        AgentInfo(agentStatus: status, focused: false, paneID: pane, revision: sequence,
                  tabID: "w:t1", terminalID: "term_\(pane)", workspaceID: "w", agent: "claude",
                  stateChangeSeq: sequence, terminalTitle: "◑ \(title)", terminalTitleStripped: title,
                  tokens: ["note": note])
    }

    private func waitForConsole(_ store: ConsoleStore, until ready: () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            let changes = AsyncStream<Void>.makeStream()
            let isReady = withObservationTracking {
                ready()
            } onChange: {
                changes.continuation.yield(())
            }
            if isReady {
                changes.continuation.finish()
                return
            }
            var iterator = changes.stream.makeAsyncIterator()
            let change = await iterator.next()
            changes.continuation.finish()
            guard change != nil else { throw CancellationError() }
        }
    }

    private func snapshot(sort: String) throws -> Data {
        let data = Data("""
            {"v":1,"agent_panel_sort":"\(sort)","sidebar":{"agents":{"rows":[[{"token":"terminal_title_stripped"}]],"rows_by_agent":{"claude":[[{"token":"workspace"}]]}}}}
            """.utf8)
        _ = try #require(AgentRowLayoutSnapshot.decode(data))
        return data
    }

    private func row(_ host: Host, pane: String, status: AgentStatus, order: Int, sequence: Int = 0) -> ConsoleAgent {
        ConsoleAgent(hostID: host.id, hostName: host.hostName,
                     agent: Agent(terminalID: "t", kind: "claude", title: "", status: status,
                                  workspaceID: "w", tabID: "t", paneID: pane, cwd: "", revision: 1,
                                  stateChangeSeq: sequence),
                     workspaceLabel: nil, repositoryCheckout: nil, snapshotOrder: order)
    }

    /// Await terminal publication, then require a usable snapshot. Missing or
    /// invalid data is a diagnostic failure, never an unbounded success wait.
    private func waitForSnapshots(_ store: ConsoleStore, hosts: [Host.ID]) async throws {
        while hosts.contains(where: { id in
            switch store.sidebarSnapshots.states[id] {
            case nil, .loading: true
            default: false
            }
        }) {
            try Task.checkCancellation()
            let changes = AsyncStream<Void>.makeStream()
            withObservationTracking {
                _ = store.sidebarSnapshots.states
            } onChange: {
                changes.continuation.yield(())
            }
            var iterator = changes.stream.makeAsyncIterator()
            let change = await iterator.next()
            changes.continuation.finish()
            guard change != nil else { throw CancellationError() }
        }
        for id in hosts {
            _ = try #require(store.sidebarSnapshots.snapshot(for: id), "Host must publish a valid sidebar fixture")
        }
    }

    @Test func hostStatusRetriesIsolateIssueBannerWithoutRebuildingMountedConsoleOrAgentRows() async throws {
        let suite = "sidebar-issue-isolation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let healthy = Host.fixture(name: "Healthy", address: "healthy.example")
        let flaky = Host.fixture(name: "Flaky", address: "flaky.example")
        let healthyTransport = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "a1", workspaceID: "w1", title: "Alpha"),
            .fixture(paneID: "a2", workspaceID: "w1", title: "Beta"),
        ]))
        let flakyFirst = ScriptedTransport(snapshot: .fixture(agents: []))
        let flakyRecovered = ScriptedTransport(snapshot: .fixture(agents: []))
        let flakyConnector = FailingAfterFirstConnectConnector(
            first: flakyFirst, recovered: flakyRecovered)

        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults)
        ) { host, subscriptions in
            if host.id == healthy.id {
                return EventsSession(
                    subscriptions: subscriptions,
                    connect: { healthyTransport },
                    keepalive: nil)
            }
            return EventsSession(
                subscriptions: subscriptions,
                connect: { try await flakyConnector.connect() },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(30), multiplier: 1, maxDelay: .milliseconds(60)),
                keepalive: nil)
        }
        defer { store.setHosts([]) }

        let catalog = HostStore(volatileHosts: [healthy, flaky])
        store.setHosts(catalog.hosts)
        await store.resume()
        try await waitForConsole(store) {
            store.agents.count == 2
                && store.hostStatuses[healthy.id] == EventsSessionStatus.connected
                && store.hostStatuses[flaky.id] == EventsSessionStatus.connected
                && store.hostIssues.isEmpty
        }

        let lastTab = UserDefaults.standard.object(forKey: "console.last-list-tab")
        let lastMode = UserDefaults.standard.object(forKey: "console-list.presentation-mode")
        UserDefaults.standard.removeObject(forKey: "console.last-list-tab")
        UserDefaults.standard.removeObject(forKey: "console-list.presentation-mode")
        defer {
            UserDefaults.standard.set(lastTab, forKey: "console.last-list-tab")
            UserDefaults.standard.set(lastMode, forKey: "console-list.presentation-mode")
        }

        let composition = DemoScreenshotComposition.make()
        let view = ConsoleView(
            hosts: catalog, console: store,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets),
            inputMode: composition.inputMode, detailSurface: composition.detailSurface,
            appearance: composition.appearance,
            pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences,
            relaySettings: composition.relaySettings,
            notificationRouter: AgentNotificationRouter(),
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity)
        let controller = UIHostingController(rootView: view)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer { window.isHidden = true }

        // Wait for the List's UICollectionView to mount with exactly 2 Agent rows
        // (0 phantom rows when visibleHostIssues is empty).
        let mountDeadline = ContinuousClock.now + .seconds(3)
        while Self.totalListItems(in: controller.view) != 2, ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(15))
            controller.view.layoutIfNeeded()
        }
        #expect(Self.totalListItems(in: controller.view) == 2)
        await store.sidebarSnapshots.waitForPendingReads()
        try await Task.sleep(for: .milliseconds(30))
        controller.view.layoutIfNeeded()

        // Start counting ConsoleView evaluations after initial settle.
        var counts: [String: Int] = [:]
        PerfTrace.testCountObserver = { name, amount in
            counts[name.description, default: 0] += amount
        }
        defer { PerfTrace.testCountObserver = nil }

        // Drop the flaky Host and let it fail + retry across multiple attempts:
        // the floating corner badge mounts outside the List (total list items stay 2),
        // while ConsoleView.body, ConsoleView.content, and existing Agent rows never re-evaluate.
        await flakyFirst.setConnectionAlive(false)
        await flakyFirst.failEventStream(.sshUnreachable(detail: "offline"))
        let failDeadline = ContinuousClock.now + .seconds(3)
        while (await flakyConnector.failedAttempts < 2
            || !Self.hasCornerIssueBadge(in: controller.view)),
            ContinuousClock.now < failDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutIfNeeded()
        }
        #expect(await flakyConnector.failedAttempts >= 2)
        #expect(Self.hasCornerIssueBadge(in: controller.view))
        #expect(Self.totalListItems(in: controller.view) == 2)

        // Recover the flaky Host: the floating corner badge disappears cleanly,
        // list items remain 2 throughout, with zero ConsoleView.body / content / agentRow rebuilds.
        await flakyConnector.allowRecovery()
        let recoverDeadline = ContinuousClock.now + .seconds(3)
        while (!store.hostIssues.isEmpty || Self.hasCornerIssueBadge(in: controller.view)),
            ContinuousClock.now < recoverDeadline
        {
            try await Task.sleep(for: .milliseconds(20))
            controller.view.layoutIfNeeded()
        }
        #expect(store.hostIssues.isEmpty)
        #expect(!Self.hasCornerIssueBadge(in: controller.view))
        #expect(Self.totalListItems(in: controller.view) == 2)
        await store.sidebarSnapshots.waitForPendingReads()
        try await Task.sleep(for: .milliseconds(30))
        controller.view.layoutIfNeeded()
        #expect(counts["ConsoleView.body", default: 0] == 0)
        #expect(counts["ConsoleView.content", default: 0] == 0)
        #expect(counts["ConsoleView.agentRow", default: 0] == 0)
    }

    private static func hasCornerIssueBadge(in root: UIView) -> Bool {
        let getter = #selector(getter: UIAccessibilityIdentification.accessibilityIdentifier)
        return accessibleElements(in: root).contains { node in
            guard node.responds(to: getter) else { return false }
            return node.value(forKey: "accessibilityIdentifier") as? String
                == "agents.hostIssues.badge"
        }
    }

    private static func totalListItems(in root: UIView) -> Int? {
        guard let list = firstCollectionView(in: root) else { return nil }
        return (0..<list.numberOfSections).reduce(0) { $0 + list.numberOfItems(inSection: $1) }
    }

    private static func firstCollectionView(in root: UIView) -> UICollectionView? {
        if let collection = root as? UICollectionView { return collection }
        for subview in root.subviews {
            if let found = firstCollectionView(in: subview) { return found }
        }
        return nil
    }
}

private actor FailingAfterFirstConnectConnector {
    private let first: ScriptedTransport
    private let recovered: ScriptedTransport
    private var calls = 0
    private var recovers = false
    private(set) var failedAttempts = 0

    init(first: ScriptedTransport, recovered: ScriptedTransport) {
        self.first = first
        self.recovered = recovered
    }

    func allowRecovery() {
        recovers = true
    }

    func connect() throws -> any Transport {
        calls += 1
        if calls == 1 { return first }
        if recovers { return recovered }
        failedAttempts += 1
        throw TransportError.sshUnreachable(detail: "offline")
    }
}
