import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import Heeler

/// What a Rex Host offers and how the Console shows it (ADRs 0049 to 0054):
/// nothing to start, close or rename, no integrations, its terminals listed
/// from the server, those running a known agent as Agents, and opened to view
/// and type into.
@MainActor
@Suite("Rex Console")
struct RexConsoleTests {
    private nonisolated static let kernels: [String?] = [
        nil, HerdrCoreLocator.linuxKernel, HerdrCoreLocator.macOSKernel, HerdrCoreLocator.windowsKernel,
    ]

    private var rex: Host {
        Host(
            name: "Rex", address: "rex.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: "/run/user/1000/rex/server.sock"))
    }

    @Test(arguments: [HostPlatform?.none, .posix, .nativeWindows], Self.kernels)
    func aRexHostOffersNoAction(platform: HostPlatform?, kernel: String?) {
        for isLocatingCore in [false, true] {
            let offers = HostCapabilities(
                serverKind: .rex, platform: platform, coreKernel: kernel, isLocatingCore: isLocatingCore)

            #expect(!offers.startsAgents)
            #expect(!offers.startsTerminals)
            #expect(!offers.renameAgent)
            #expect(!offers.renamesWorkspaces)
            #expect(!offers.namesNewWorkspaces)
            #expect(!offers.worktrees)
            #expect(!offers.uploads)
            #expect(!offers.composerSend)
            #expect(!offers.composerStop)
            #expect(!offers.chat)
            #expect(offers.chatPrograms == [])
            #expect(!offers.tabNames)
            #expect(!offers.closeTab)
            #expect(!offers.syncLayoutFromPlugin)
            #expect(!offers.takeOver)
            #expect(!offers.hostScripts)
            #expect(!offers.isNativeWindowsCore)
            // Its Agents open on their terminals, so a row offers only its pin.
            #expect(offers.agentsOpenAsTerminals)
            #expect(
                ConsoleAgentRowOffers(capabilities: offers, supportsMultipleWindows: true)
                    == ConsoleAgentRowOffers(opensInNewWindow: false, closes: false))
        }
        #expect(rex.capabilities == HostCapabilities(serverKind: .rex))
        #expect(!HostCapabilities(serverKind: .tmux).agentsOpenAsTerminals)
    }

    /// The Notifications, Live Activities and Usage surfaces each pick their
    /// Hosts by kind, and none of them picks a Rex Host, though it lists
    /// Agents (ADR 0054): a banner and a Live Activity fail closed for it.
    @Test func noIntegrationTreatsARexHostAsItsOwn() {
        #expect(!ServerKind.rex.hasHostIntegrations)
        #expect(PreflightCheck.cases(for: .rex) == [.connection, .herdrInstalled, .serverRunning, .protocolCompatible])
        #expect(PreflightCheck.herdrInstalled.title(for: .rex) == "Rex installed")
        #expect(PreflightCheck.serverRunning.title(for: .rex) == "Rex server running")

        let notifications = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [:]),
            deviceToken: { nil },
            ceremony: NotificationRegistrationCeremony(
                keys: NotificationKeyStore(secrets: InMemorySecretStore())))
        notifications.setHosts([rex])
        #expect(notifications.hosts.isEmpty)
        #expect(notifications.confirmedTriggers(for: rex.id) == nil)
        #expect(!HostStore(volatileHosts: [rex]).supportsLiveActivities(for: rex.id))

        // Usage and Accounts then have no Host, and say why instead of asking
        // for one; a Host with nothing on, or any other kind on, keeps asking.
        let tmux = Host(
            name: "tmux", address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let held = Host(name: "Held", address: "held.example", username: "dev", serverKind: .unconfirmed)
        #expect(HostStore(volatileHosts: [rex]).integratedHosts.isEmpty)
        #expect(HostStore(volatileHosts: [rex]).hasOnlyRexServersOn)
        #expect(HostStore(volatileHosts: [rex, held]).hasOnlyRexServersOn)
        #expect(!HostStore(volatileHosts: [rex, tmux]).hasOnlyRexServersOn)
        #expect(!HostStore(volatileHosts: [held]).hasOnlyRexServersOn)
        #expect(!HostStore(volatileHosts: []).hasOnlyRexServersOn)
    }

    /// What the Console dialed, in order.
    final class Dials: Sendable {
        private let entries = Mutex<[String]>([])

        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    /// A Console store whose Rex Hosts dial one SSH connection per server in
    /// `servers`, or `rexConnect` when given, and which records each Rex dial.
    private func store(
        servers: [FakeRexServer] = [], dials: Dials = Dials(),
        memory: HerdrCoreHostMemory = HerdrCoreHostMemory(),
        rexConnect: (@Sendable (RexSocket?, RexControlLink?) async throws -> any RexTransport)? = nil
    ) -> ConsoleStore {
        let hosts = Mutex(servers.map { ScriptedRexHost(control: [.server($0)]) })
        return ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            // Its own suite, so a Pin never reaches the test host's defaults.
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "rex-console-pins-\(UUID().uuidString)") ?? .standard),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") }, keepalive: nil)
            },
            makeCoreSession: { _ in
                HerdrCoreHostSession { throw TransportError.sshUnreachable(detail: "unscripted") }
            },
            makeTmuxSession: { host in
                TmuxHostSession(storedPaths: host.storedTmuxPaths) { _ in
                    throw TransportError.sshUnreachable(detail: "unscripted")
                }
            },
            makeRexSession: { host in
                dials.append("rex session \(host.displayName)")
                let scripted: RexHostSession.Connect = { socket, previous in
                    dials.append("rex connect")
                    guard let next = hosts.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) else {
                        throw TransportError.sshUnreachable(detail: "no more scripted connections")
                    }
                    return try await RexSSHTransport.connect(
                        over: next, socket: socket, resuming: previous, options: .testing)
                }
                return RexHostSession(
                    storedSocket: host.rexSocket, connect: rexConnect ?? scripted,
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)))
            },
            coreHostMemory: memory)
    }

    private func waitUntil(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func served(_ world: FakeRexWorld, count: Int = 1) async -> [FakeRexServer] {
        var servers: [FakeRexServer] = []
        for _ in 0..<count {
            let server = FakeRexServer()
            await world.install(on: server)
            servers.append(server)
        }
        return servers
    }

    /// Only a Rex Host gets a Rex session; the other kinds keep their own.
    @Test func onlyARexHostGetsARexSession() async throws {
        let dials = Dials()
        let store = store(dials: dials)
        defer { store.setHosts([]) }
        let tmux = Host(
            name: "tmux", address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")

        store.setHosts([rex, tmux])

        #expect(dials.all.filter { $0.hasPrefix("rex session") } == ["rex session Rex"])
    }

    /// A Rex Host's sessions, windows and terminal blocks list as Workspaces,
    /// Tabs and Terminals in Rex's order, its detached terminals under one Tab
    /// after its windows. None of them runs an agent, so none is an Agent.
    @Test func aRexHostListsItsTerminals() async throws {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let store = store(servers: await served(world))
        defer { store.setHosts([]) }
        let rex = rex

        store.setHosts([rex])
        await store.resume()
        try await waitUntil("the terminals with their details") {
            store.terminals.count == 5 && store.terminals.first?.title == "make test"
        }

        #expect(store.hostStatuses[rex.id] == .connected)
        #expect(store.agents.isEmpty)
        let terminals = store.terminals
        #expect(
            terminals.map(\.paneID)
                == ["block:left", "block:right", "block:solo", "block:float", "block:detached"].map {
                    RexPaneAddress(sessionID: "session:studio", blockID: $0).paneID
                })
        #expect(terminals.map(\.workspaceLabel) == Array(repeating: "studio", count: 5))
        #expect(terminals.map(\.tabLabel) == ["editor", "editor", "", "", "Detached"])
        #expect(terminals.map(\.tabPosition) == [1, 1, 2, 2, 3])
        #expect(terminals.map(\.paneLabel) == ["left", nil, nil, "scratch", nil])
        #expect(terminals.map(\.title) == ["make test", "zsh", "vim", "zsh", "tail"])
        #expect(terminals.map(\.cwd) == ["/home/dev/app", "/home/dev", "/home/dev/app/src", "/home/dev", "/home/dev"])
        #expect(terminals.allSatisfy { !$0.isAgent })
        #expect(store.workspacesByHost[rex.id]?.map(\.label) == ["studio"])
    }

    /// The studio with Codex in its left terminal, reporting `state`.
    private func studioRunningCodex(reporting state: String?) -> FakeRexWorld.Session {
        var studio = FakeRexWorld.studio()
        var codex = FakeRexWorld.Block.running("block:left", program: "codex")
        codex.label = "left"
        codex.directory = "/home/dev/app"
        codex.processID = 5150
        codex.status = state.map { codex.record($0, app: "codex") }
        studio.windows[0].layers[0].blocks[2] = codex
        return studio
    }

    private func blockEvent(_ name: String, _ payload: JSONValue, block: String = "block:left") -> JSONValue {
        ["block_id": .string(block), "creator_name": .string(RexInventoryWire.terminalCreator), "name": .string(name),
         "payload": payload]
    }

    /// What the inventory may ask of a Rex server: reads, never a write, an
    /// attach, a resize or a claim on a block (ADR 0054). `server.version`
    /// names the Host's kernel when this device keeps none.
    private static let inventoryMethods: Set<String> = [
        "server.status", "server.version", "session.attach_all", "session.view", "session.list_blocks",
        RexInventoryWire.terminalMethod("title"), RexInventoryWire.terminalMethod("process"),
        RexInventoryWire.terminalMethod("program_status"),
    ]

    /// A terminal running a known agent lists as an Agent of its Host, in its
    /// session's Workspace and its window's Tab, with the status its program
    /// reported to Rex, and leaves the Terminals list. The control link's
    /// events alone keep it current, and nothing is written to or attached on
    /// the server for it. When its program leaves, it is a Terminal again.
    @Test func aRexTerminalRunningAnAgentListsAsAnAgent() async throws {
        let world = FakeRexWorld(sessions: [studioRunningCodex(reporting: "working")])
        let servers = await served(world)
        let store = store(servers: servers)
        defer { store.setHosts([]) }
        let rex = rex

        store.setHosts([rex])
        await store.resume()
        try await waitUntil("the Agent with its status") { store.agents.first?.agent.status == .working }

        let paneID = RexPaneAddress(sessionID: "session:studio", blockID: "block:left").paneID
        let agent = try #require(store.agents.first)
        #expect(store.agents.count == 1)
        #expect(agent.agent.kind == "codex")
        #expect(agent.agent.paneID == paneID)
        #expect(agent.hostID == rex.id)
        #expect(agent.hostName == rex.displayName)
        #expect(agent.workspaceLabel == "studio")
        #expect(agent.tabLabel == "editor")
        #expect(agent.agent.name == "left")
        #expect(agent.agent.displayName == "left")
        #expect(agent.directory == "/home/dev/app")
        // Its row reads no Changes, which a Rex Host cannot serve.
        #expect(store.rowChanges.store(for: agent) == nil)
        #expect(store.terminals.filter(\.isAgent).map(\.paneID) == [paneID])
        #expect(store.terminals.filter { !$0.isAgent }.count == 4)

        await servers[0].push(
            "block_event",
            blockEvent(
                "program_status_changed",
                ["id": "", "record": world.sessions[0].windows[0].layers[0].blocks[2].record("blocked", app: "codex"),
                 "reason": "report"]),
            session: "session:studio")
        try await waitUntil("the new status") { store.agents.first?.agent.status == .blocked }

        // Leaving, the program takes its record with it, then the shell is named.
        await servers[0].push(
            "block_event", blockEvent("program_status_removed", ["ids": [""], "reason": "foreground"]),
            session: "session:studio")
        await servers[0].push(
            "block_event",
            blockEvent("process_changed", ["foreground": ["pid": 4242, "name": "zsh", "argv0": "-zsh", "cwd": "/home/dev/app"]]),
            session: "session:studio")
        try await waitUntil("the Agent gone") { store.agents.isEmpty }
        #expect(store.terminals.allSatisfy { !$0.isAgent })
        #expect(store.terminals.count == 5)

        let methods = Set(await servers[0].requests.map(\.method))
        #expect(methods.isSubset(of: Self.inventoryMethods))
    }

    /// A Rex Agent reads Done as the other kinds' do (ADR 0054): its program
    /// reported done and this device has not looked at it since. Opening its
    /// terminal looks at it; the same done reported again keeps it Idle; the
    /// next finished turn reads Done again; and both a turn left unseen and
    /// what this device saw survive a relaunch, whose first inventory lists
    /// the terminal before its details are read. The Done count and the
    /// status filter take it as any Done, and nothing of it reaches the
    /// server, a banner or a Host Helper.
    @Test func aRexAgentReadsDoneUntilThisDeviceLooksAtIt() async throws {
        let world = FakeRexWorld(sessions: [studioRunningCodex(reporting: "working")])
        let servers = await served(world, count: 3)
        let defaults = try #require(UserDefaults(suiteName: "rex-done-\(UUID().uuidString)"))
        let first = store(servers: [servers[0]], memory: HerdrCoreHostMemory(defaults: defaults))
        defer { first.setHosts([]) }
        let rex = rex
        let markedHosts = Dials()
        first.onCoreSeenMarksChanged = { hostID, _, _ in markedHosts.append(hostID.uuidString) }
        let notifications = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [:]),
            deviceToken: { nil },
            ceremony: NotificationRegistrationCeremony(
                keys: NotificationKeyStore(secrets: InMemorySecretStore())))
        notifications.setHosts([rex])
        let banners = AgentNotificationBannerStore(
            holdDuration: .zero, presentedAgent: { nil }, triggers: { notifications.confirmedTriggers(for: $0) },
            playSound: {})
        let block = world.sessions[0].windows[0].layers[0].blocks[2]
        func report(_ state: String, at second: Int, on server: FakeRexServer) async {
            let record = block.record(state, app: "codex", at: "2026-11-16T12:01:\(second < 10 ? "0" : "")\(second)+00:00")
            world.update { $0[0].windows[0].layers[0].blocks[2].status = record }
            await server.push(
                "block_event", blockEvent("program_status_changed", ["id": "", "record": record, "reason": "report"]),
                session: "session:studio")
        }
        /// Every event before it has reached the Console once its title shows.
        func settle(_ store: ConsoleStore, on server: FakeRexServer, title: String) async throws {
            await server.push("block_event", blockEvent("title_changed", ["title": .string(title)]), session: "session:studio")
            try await waitUntil("the title \(title)") { store.agents.first?.agent.terminalTitleStripped == title }
        }

        first.setHosts([rex])
        await first.resume()
        try await waitUntil("the Agent working") { first.agents.first?.agent.status == .working }
        banners.agentsDidChange(first.agents)
        await report("done", at: 2, on: servers[0])
        try await waitUntil("the Agent Done") { first.agents.first?.agent.status == .done }
        let agent = try #require(first.agents.first)
        #expect(ConsoleHostAgentStatusCounts(agents: first.agents).done == 1)
        #expect(Set([ConsoleAgentStatusFilter.done]).admits(agent))
        banners.agentsDidChange(first.agents)

        let viewer = UUID()
        first.setAgentShown(agent.id, viewer: viewer, scene: nil)
        try await waitUntil("the Agent seen") { first.agents.first?.agent.status == .idle }
        first.setAgentShown(nil, viewer: viewer, scene: nil)
        await report("done", at: 3, on: servers[0])
        try await settle(first, on: servers[0], title: "Same turn")
        #expect(first.agents.first?.agent.status == .idle)

        await report("working", at: 4, on: servers[0])
        try await waitUntil("the next turn") { first.agents.first?.agent.status == .working }
        await report("done", at: 5, on: servers[0])
        try await waitUntil("the next turn Done") { first.agents.first?.agent.status == .done }
        first.setAgentShown(agent.id, viewer: viewer, scene: nil)
        try await waitUntil("the next turn seen") { first.agents.first?.agent.status == .idle }
        first.setAgentShown(nil, viewer: viewer, scene: nil)

        try await Task.sleep(for: .milliseconds(50))
        #expect(banners.banner == nil)
        #expect(markedHosts.all.isEmpty)
        #expect(first.coreSeenMarks(on: rex.id) == nil)
        #expect(Set(await servers[0].requests.map(\.method)).isSubset(of: Self.inventoryMethods))

        // A turn finishes unseen, then the app goes, sweeping nothing, and
        // comes back to the same server: the turn still reads Done.
        await report("working", at: 6, on: servers[0])
        try await waitUntil("a turn before the relaunch") { first.agents.first?.agent.status == .working }
        await report("done", at: 7, on: servers[0])
        try await waitUntil("the turn left unseen") { first.agents.first?.agent.status == .done }
        first.setHosts([], hostsOutOfSight: nil)
        let relaunched = store(servers: [servers[1]], memory: HerdrCoreHostMemory(defaults: defaults))
        defer { relaunched.setHosts([]) }
        relaunched.setHosts([rex])
        await relaunched.resume()
        try await waitUntil("the unseen turn read again") { relaunched.agents.first?.agent.status == .done }
        try await settle(relaunched, on: servers[1], title: "Back")
        #expect(relaunched.agents.first?.agent.status == .done)
        #expect(ConsoleHostAgentStatusCounts(agents: relaunched.agents).done == 1)
        relaunched.setAgentShown(agent.id, viewer: viewer, scene: nil)
        try await waitUntil("the turn seen after the relaunch") { relaunched.agents.first?.agent.status == .idle }
        relaunched.setAgentShown(nil, viewer: viewer, scene: nil)

        // What this device saw survives the next relaunch.
        relaunched.setHosts([], hostsOutOfSight: nil)
        let again = store(servers: [servers[2]], memory: HerdrCoreHostMemory(defaults: defaults))
        defer { again.setHosts([]) }
        again.setHosts([rex])
        await again.resume()
        try await waitUntil("the Agent read again") { again.agents.first?.agent.status == .idle }
        try await settle(again, on: servers[2], title: "Again")
        #expect(again.agents.first?.agent.status == .idle)
        await report("working", at: 8, on: servers[2])
        await report("done", at: 9, on: servers[2])
        try await waitUntil("a turn finished after the relaunch") { again.agents.first?.agent.status == .done }
    }

    /// A Rex Agent's terminal screen is what looks at it: mounted, it marks
    /// the finished turn seen. A screen SwiftUI rebuilds while it stays
    /// selected lets go of the Agent with its old state, so once the user
    /// has left, the next finished turn reads Done again.
    @Test func aRexAgentsScreenLooksAtItUntilItGoesRebuiltOrNot() async throws {
        let world = FakeRexWorld(sessions: [studioRunningCodex(reporting: "working")])
        let servers = await served(world)
        let console = store(servers: servers)
        defer { console.setHosts([]) }
        let rex = rex
        let block = world.sessions[0].windows[0].layers[0].blocks[2]
        func report(_ state: String, at second: Int) async {
            let record = block.record(state, app: "codex", at: "2026-11-16T12:02:0\(second)+00:00")
            world.update { $0[0].windows[0].layers[0].blocks[2].status = record }
            await servers[0].push(
                "block_event", blockEvent("program_status_changed", ["id": "", "record": record, "reason": "report"]),
                session: "session:studio")
        }
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the Agent working") { console.agents.first?.agent.status == .working }
        await report("done", at: 1)
        try await waitUntil("the Agent Done") { console.agents.first?.agent.status == .done }
        let row = try #require(console.terminals.first { $0.isAgent })
        let defaults = try #require(UserDefaults(suiteName: "rex-seen-\(UUID().uuidString)"))
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults))
        let screen = RexScreenDriver()
        let controller = UIHostingController(
            rootView: RexAgentScreen(
                console: console, terminal: row, corePin: console.corePin(on: rex.id), settings: settings,
                activity: AppActivityCoordinator(), driver: screen
            )
            .defaultAppStorage(defaults))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        func frames() async throws {
            for _ in 0..<20 {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await waitUntil("the turn seen from its screen") {
            window.layoutIfNeeded()
            return console.agents.first?.agent.status == .idle
        }

        screen.generation += 1
        try await frames()
        screen.isShown = false
        try await frames()
        await report("working", at: 2)
        try await waitUntil("the next turn") { console.agents.first?.agent.status == .working }
        await report("done", at: 3)
        try await waitUntil("the next turn Done, with no screen on it") {
            console.agents.first?.agent.status == .done
        }

        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
    }

    /// A report from a program that has since left reads Unknown, and so does
    /// an Agent with no report: the status counts only while its owner is the
    /// foreground. A pinned Agent's Pin goes once the server stops listing it.
    @Test func aStaleReportReadsUnknownAndAPinGoesWithItsTerminal() async throws {
        var studio = studioRunningCodex(reporting: nil)
        var stale = studio.windows[0].layers[0].blocks[2]
        stale.status = stale.record("done", app: "codex", owner: (4100, "codex"))
        studio.windows[0].layers[0].blocks[2] = stale
        var claude = FakeRexWorld.Block.running("block:solo", program: "2.1.316", argv0: "claude")
        claude.title = "✳ Review the diff"
        studio.windows[1].layers[0].blocks[0] = claude
        let world = FakeRexWorld(sessions: [studio])
        let servers = await served(world)
        let store = store(servers: servers)
        defer { store.setHosts([]) }
        let rex = rex

        store.setHosts([rex])
        await store.resume()
        try await waitUntil("both Agents with their details") {
            store.agents.count == 2 && store.agents.contains { $0.agent.terminalTitleStripped == "Review the diff" }
        }
        #expect(store.agents.allSatisfy { $0.agent.status == .unknown })
        #expect(Set(store.agents.map(\.agent.kind)) == ["codex", "claude"])

        let solo = RexPaneAddress(sessionID: "session:studio", blockID: "block:solo").paneID
        store.togglePin(hostID: rex.id, paneID: solo)
        #expect(store.pins.isPinned(hostID: rex.id, paneID: solo))
        world.update { sessions in
            sessions[0].windows[1].layers[0].blocks.removeAll()
            sessions[0].windows[1].layers[0].layout = nil
            sessions[0].revision = 4
        }
        await servers[0].push("block_closed", ["block_id": "block:solo"], session: "session:studio")
        await servers[0].push("session_view_changed", ["revision": 4], session: "session:studio")
        try await waitUntil("the closed Agent gone") { store.agents.count == 1 }
        #expect(!store.pins.isPinned(hostID: rex.id, paneID: solo))
    }

    /// An open Rex Agent is its terminal's screen (ADR 0054), so its pooled
    /// connection stays through every inventory change, as a Terminal's does,
    /// while a closed terminal's goes.
    @Test func anOpenRexAgentsTerminalStaysPooled() async throws {
        let world = FakeRexWorld(sessions: [studioRunningCodex(reporting: "working")])
        let servers = await served(world)
        let console = store(servers: servers)
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the Agent with its status") { console.agents.first?.agent.status == .working }
        let agentRow = try #require(console.terminals.first { $0.isAgent })
        let soloPane = RexPaneAddress(sessionID: "session:studio", blockID: "block:solo").paneID
        let soloRow = try #require(console.terminals.first { $0.paneID == soloPane })
        // Selected as each detail selects its terminal; neither is sized, so
        // neither opens a data link.
        for row in [agentRow, soloRow] {
            let pin = console.corePin(on: rex.id)
            _ = try await console.terminalConnections.select(
                hostID: rex.id,
                identity: ShellTerminalIdentity(paneID: row.paneID, tabID: row.tabID, terminalID: row.terminalID),
                ownerID: UUID(), generation: console.hostConnectionGenerations[rex.id], corePin: pin,
                runTerminal: console.terminalRunner(for: rex.id, keepingTo: pin))
        }
        #expect(console.terminalConnections.entries.count == 2)

        await servers[0].push(
            "block_event",
            blockEvent(
                "program_status_changed",
                ["id": "", "record": world.sessions[0].windows[0].layers[0].blocks[2].record("blocked", app: "codex"),
                 "reason": "report"]),
            session: "session:studio")
        try await waitUntil("the new status") { console.agents.first?.agent.status == .blocked }
        world.update { sessions in
            sessions[0].windows[1].layers[0].blocks.removeAll()
            sessions[0].windows[1].layers[0].layout = nil
            sessions[0].revision = 4
        }
        await servers[0].push("block_closed", ["block_id": "block:solo"], session: "session:studio")
        await servers[0].push("session_view_changed", ["revision": 4], session: "session:studio")
        try await waitUntil("the closed terminal's connection gone") {
            !console.terminalConnections.entries.keys.contains { $0.identity.paneID == soloPane }
        }

        #expect(console.terminalConnections.entries.keys.map(\.identity.paneID) == [agentRow.paneID])
        #expect(console.agents.count == 1)
    }

    /// A Rex terminal opened from Terminals whose shell starts a known agent
    /// stays on its screen: that Agent opens as this same screen (ADR 0054),
    /// so leaving for it would only drop the connection and give back the
    /// size the screen took.
    @Test func aRexTerminalThatStartsAnAgentStaysOnItsScreen() async throws {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let servers = await served(world)
        let console = store(servers: servers)
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the terminals with their details") {
            console.terminals.count == 5 && console.terminals.first?.title == "make test"
        }
        let shell = try #require(console.terminals.first)
        #expect(!shell.isAgent)
        let defaults = try #require(UserDefaults(suiteName: "rex-shell-\(UUID().uuidString)"))
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults))
        let left = SelectedAgents()
        let controller = UIHostingController(
            rootView: RexLiveShell(
                console: console, terminal: shell, corePin: console.corePin(on: rex.id), settings: settings,
                activity: AppActivityCoordinator()
            ) { left.ids.append($0) }
            .defaultAppStorage(defaults))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        try await waitUntil("the screen's connection") {
            window.layoutIfNeeded()
            return console.terminalConnections.entries.count == 1
        }

        await servers[0].push(
            "block_event",
            blockEvent("process_changed", ["foreground": ["pid": 5150, "name": "codex", "argv0": "codex", "cwd": "/home/dev/app"]]),
            session: "session:studio")
        try await waitUntil("the shell listed as an Agent") {
            console.agents.count == 1 && console.terminals.first { $0.id == shell.id }?.isAgent == true
        }
        // The frames in which a screen leaves for an Agent its shell started.
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(left.ids.isEmpty)
        #expect(console.terminalConnections.entries.keys.map(\.identity.paneID) == [shell.paneID])
        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
    }

    /// A session whose terminals all run Agents has no card under Terminals:
    /// a Rex Host offers no New Terminal to fill it. When the only shell of
    /// one starts an agent, its card leaves the list while the open screen
    /// stays with its connection, and the card comes back when the agent
    /// exits to the shell.
    @Test func aRexSessionLeftWithOnlyAgentsLeavesTerminalsButNotItsOpenScreen() async throws {
        let alone = FakeRexWorld.Block("block:alone")
        let session = FakeRexWorld.Session(
            id: "session:agent", label: "agent",
            windows: [
                .init(
                    id: "window:0000-0000-0000-00000000c0c0", label: "main",
                    layers: [.init(layout: .block(alone.id), blocks: [alone])])
            ])
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio(), session])
        let servers = await served(world)
        let console = store(servers: servers)
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        let paneID = RexPaneAddress(sessionID: "session:agent", blockID: "block:alone").paneID
        try await waitUntil("both sessions' terminals with their details") {
            console.terminals.count == 6 && console.terminals.first?.title == "make test"
                && console.terminals.contains { $0.paneID == paneID && $0.cwd == "/home/dev" }
        }
        func cards() -> [String] {
            TerminalListProjection(hosts: [rex], console: console).workspaces().map(\.title)
        }
        #expect(cards() == ["studio", "agent"])
        let shell = try #require(console.terminals.first { $0.paneID == paneID })
        let defaults = try #require(UserDefaults(suiteName: "rex-alone-\(UUID().uuidString)"))
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults))
        let left = SelectedAgents()
        let controller = UIHostingController(
            rootView: RexLiveShell(
                console: console, terminal: shell, corePin: console.corePin(on: rex.id), settings: settings,
                activity: AppActivityCoordinator()
            ) { left.ids.append($0) }
            .defaultAppStorage(defaults))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        try await waitUntil("the screen's connection") {
            window.layoutIfNeeded()
            return console.terminalConnections.entries.count == 1
        }

        func foreground(_ name: String, pid: Int) async {
            let process: JSONValue = [
                "pid": .number(Double(pid)), "name": .string(name), "argv0": .string(name), "cwd": "/home/dev",
            ]
            await servers[0].push(
                "block_event", blockEvent("process_changed", ["foreground": process], block: "block:alone"),
                session: "session:agent")
        }
        await foreground("codex", pid: 5150)
        try await waitUntil("the shell listed as an Agent") { console.agents.count == 1 }
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(cards() == ["studio"])
        #expect(left.ids.isEmpty)
        #expect(console.terminalConnections.entries.keys.map(\.identity.paneID) == [paneID])

        await foreground("zsh", pid: 4242)
        try await waitUntil("the Agent back to a terminal") { console.agents.isEmpty }
        #expect(cards() == ["studio", "agent"])
        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
    }

    /// What an open Rex Agent's terminal keeps to is the server it opened on:
    /// another instance leaves it behind, and only a pick from the list opens
    /// the Agent anew there. While the Host recovers, its row stands in at the
    /// same address, so the pooled connection is found again.
    @Test func anOpenRexAgentKeepsToItsServerUntilPickedAnew() async throws {
        let world = FakeRexWorld(sessions: [studioRunningCodex(reporting: "working")])
        let servers = await served(world, count: 2)
        let host = ScriptedRexHost(control: servers.map { .server($0) })
        let console = store(rexConnect: { socket, previous in
            try await RexSSHTransport.connect(over: host, socket: socket, resuming: previous, options: .testing)
        })
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the Agent") { console.agents.first?.agent.status == .working }
        let agent = try #require(console.agents.first)
        let row = try #require(console.terminals.first { $0.isAgent })
        let standIn = ConsoleTerminal(standingInFor: agent)
        #expect(standIn.id == row.id)
        #expect(standIn.terminalID == row.terminalID)
        #expect(standIn.tabID == row.tabID)
        let cores = ConsoleDetailCores()
        let pin = cores.terminalPin(for: agent, console: console)
        #expect(cores.terminalPin(for: agent, console: console) === pin)
        #expect(!cores.openAnew(.agent(agent.id), console: console))

        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") { console.hasLeftCore(pin, on: rex.id) }

        #expect(cores.terminalPin(for: agent, console: console) === pin)
        #expect(cores.listSelection(for: .agent(agent.id), console: console) == .leftBehind(.agent(agent.id)))
        #expect(cores.openAnew(.agent(agent.id), console: console))
        let fresh = cores.terminalPin(for: agent, console: console)
        #expect(fresh !== pin)
        #expect(!console.hasLeftCore(fresh, on: rex.id))
    }

    /// Another server instance on the socket leaves every detail open on the
    /// last one's terminals, as another tmux server does.
    @Test func anotherServerLeavesOpenDetails() async throws {
        let world = FakeRexWorld(sessions: [FakeRexWorld.studio()])
        let servers = await served(world, count: 2)
        let host = ScriptedRexHost(control: servers.map { .server($0) })
        let console = store(rexConnect: { socket, previous in
            try await RexSSHTransport.connect(over: host, socket: socket, resuming: previous, options: .testing)
        })
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the first inventory") { console.terminals.count == 5 }
        let pin = console.corePin(on: rex.id)
        #expect(console.keepsDetailsToCores(on: rex.id))
        #expect(!console.hasLeftCore(pin, on: rex.id))

        world.restart(as: "instance-0002")
        await servers[0].close(.goingAway, reason: "shutting down")
        try await waitUntil("the new server") { console.hasLeftCore(pin, on: rex.id) }

        #expect(console.terminalEndedMessage(keepingTo: pin, on: rex.id) == TerminalStatusPresentation.rexServerGoneMessage)
        #expect(console.leftCoreError(on: rex.id) == .rexServerGone)
        try await waitUntil("the new server's terminals") { console.terminals.count == 5 }
    }

    /// A Rex terminal opens through the Console's runner: it paints and goes
    /// live, and takes input from that first paint (ADRs 0051 and 0052).
    @Test func aRexTerminalOpensAndTakesInput() async throws {
        let rig = RexTerminalAttachTests.Rig()
        let server = await rig.server()
        await server.answer(RexTerminalInputTests.write, with: .result(["bytes_written": 3]))
        let host = await rig.host([.server(server)])
        let console = store(rexConnect: { socket, previous in
            try await RexSSHTransport.connect(over: host, socket: socket, resuming: previous, options: .testing)
        })
        defer { console.setHosts([]) }
        let rex = rex
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the terminals") { console.terminals.count == 5 }
        let paneID = try #require(console.terminals.first?.paneID)
        let input = TerminalInputController()
        let terminal = AttachTerminalStore(
            target: .terminal(paneID), input: input,
            runTerminal: console.terminalRunner(for: rex.id, keepingTo: console.corePin(on: rex.id)))

        terminal.viewDidResize(cols: 80, rows: 24)
        #expect(!input.send(Data("early\r".utf8)))
        await rig.begin()
        try await waitUntil("the first paint") { terminal.status == .live }
        #expect(input.send(Data("ls\r".utf8)))
        try await waitUntil("the write") {
            await server.requests.contains { $0.payload?["args"]?["data"]?.stringValue == "ls\r" }
        }
        #expect(await !server.requests.contains { $0.payload?["args"]?["data"]?.stringValue == "early\r" })
        await terminal.stop()
        #expect(await rig.attachSlotsTaken == 0)
    }

    /// A Rex Server turned on while Rex was not running stores no socket, and
    /// its connections look one up. The socket its Server page's checks note
    /// later is the same Host: the connection and an open terminal stay, and
    /// nothing dials again. Another socket is another Host.
    @Test func aSocketNotedForTheFirstTimeKeepsTheConnection() async throws {
        let rex = rex
        let rig = RexTerminalAttachTests.Rig()
        let server = await rig.server()
        let socket = try #require(rex.rexSocket)
        let host = ScriptedRexHost(
            probe: ScriptedRexHost.probeFinding(socket.path), control: [.server(server)], admission: rig.admission)
        await host.serveData(from: rig.endpoint)
        let dials = Dials()
        let console = store(dials: dials, rexConnect: { stored, previous in
            dials.append("rex connect \(stored?.path ?? "looked up")")
            return try await RexSSHTransport.connect(
                over: host, socket: stored, resuming: previous, options: .testing)
        })
        defer { console.setHosts([]) }
        var bare = rex
        bare.rexSocket = nil
        console.setHosts([bare])
        await console.resume()
        try await waitUntil("the terminals") { console.terminals.count == 5 }
        let paneID = try #require(console.terminals.first?.paneID)
        let terminal = AttachTerminalStore(
            target: .terminal(paneID), input: TerminalInputController(),
            runTerminal: console.terminalRunner(for: bare.id, keepingTo: console.corePin(on: bare.id)))
        terminal.viewDidResize(cols: 80, rows: 24)
        await rig.begin()
        try await waitUntil("the first paint") { terminal.status == .live }

        console.setHosts([rex])
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(dials.all == ["rex session Rex", "rex connect looked up"])
        #expect(console.hostStatuses[rex.id] == .connected)
        #expect(console.terminals.count == 5)
        #expect(terminal.status == .live)
        #expect(await server.clientClose == nil)

        var moved = rex
        moved.rexSocket = RexSocket(path: "/run/user/1000/rex/other.sock")
        console.setHosts([moved])
        try await waitUntil("another Host's session") { dials.all.count >= 3 }
        #expect(dials.all.dropFirst(2).first == "rex session Rex")
        await terminal.stop()
    }

    /// A Rex Host lists Agents and Terminals (ADR 0054): both lists' Host
    /// filter offers it, and both show its problem unless filtered out.
    @Test func bothListsShowARexHost() async throws {
        let rex = rex
        let tmux = Host(
            name: "tmux", address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let catalog = HostStore(volatileHosts: [rex, tmux])
        let console = store(rexConnect: { _, _ in throw TransportError.rexForwardingRefused(socketPath: "/run/rex.sock") })
        defer { console.setHosts([]) }
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the failure") { console.hostStatuses[rex.id] == .failed(.rexForwardingRefused(socketPath: "/run/rex.sock")) }

        #expect(ConsoleView.hostFilterChoices(in: catalog).map(\.name) == ["Rex", "tmux"])
        func issueHostIDs(filter: Set<Host.ID> = []) -> [Host.ID] {
            ConsoleView.filteredHostIssues(hosts: catalog, console: console, hostFilter: filter).map(\.hostID)
        }
        #expect(issueHostIDs().contains(rex.id))
        #expect(issueHostIDs(filter: [rex.id]).contains(rex.id))
        #expect(!issueHostIDs(filter: [tmux.id]).contains(rex.id))
    }

    /// The lists name a Host alone (ADR 0047): a Host whose tmux and Rex
    /// Servers both have a problem lists each by the Host's name with its
    /// Server in the status, never as "Host · Server", and the summary of
    /// the two is the Host's.
    @Test func aHostsServersProblemsNameTheHostAlone() async throws {
        let rexServer = Host(
            name: "m3", address: "m3.example", username: "dev", serverKind: .rex,
            rexSocket: RexSocket(path: "/run/user/1000/rex/server.sock"))
        let tmux = Host(
            name: "m3", address: "m3.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let records = HostStore(volatileHosts: [tmux, rexServer]).consoleHosts
        #expect(records.map(\.displayName) == ["m3 · tmux", "m3 · Rex"])
        let console = store(rexConnect: { _, _ in throw TransportError.rexForwardingRefused(socketPath: "/run/rex.sock") })
        defer { console.setHosts([]) }
        console.setHosts(records)
        await console.resume()
        try await waitUntil("both Servers' problems") { console.hostIssues(for: records).count == 2 }

        let issues = console.hostIssues(for: records)
        #expect(issues.map(\.hostName) == ["m3", "m3"])
        #expect(issues[0].status.hasPrefix("tmux: "))
        #expect(issues[1].status.hasPrefix("Rex: "))
        #expect(!issues.contains { issue in
            [issue.message, issue.sectionMessage, issue.status, issue.spokenMessage].contains { $0.contains("m3 · ") }
        })
        #expect(ConsoleHostIssueSummary(issues: issues)?.title == "m3")
    }
}

/// The Agents a terminal's screen left for, in order.
@MainActor
private final class SelectedAgents {
    var ids: [ConsoleAgent.ID] = []
}

/// A Rex terminal's screen built as the Terminals list builds it, its row
/// read live from the store.
private struct RexLiveShell: View {
    let console: ConsoleStore
    let terminal: ConsoleTerminal
    let corePin: TerminalCorePin
    let settings: TerminalSettings
    let activity: AppActivityCoordinator
    let onSelectAgent: (ConsoleAgent.ID) -> Void

    var body: some View {
        NavigationStack {
            WorkspaceTerminalDetailView(
                terminal: console.terminals.first(where: { $0.id == terminal.id }) ?? terminal,
                console: console,
                corePin: corePin,
                settings: settings,
                activity: activity,
                onSelectAgent: onSelectAgent,
                onSelectTerminal: { _ in },
                onBack: {})
        }
        // A hosting controller has no SwiftUI scene to say so.
        .environment(\.scenePhase, .active)
    }
}

/// What a test does to a Rex Agent's screen: rebuild it, or leave it.
@MainActor
@Observable
private final class RexScreenDriver {
    var generation = 0
    var isShown = true
}

/// A Rex Agent's terminal screen, selected while it is shown, as a list
/// opens an Agent that opens on its terminal.
private struct RexAgentScreen: View {
    let console: ConsoleStore
    let terminal: ConsoleTerminal
    let corePin: TerminalCorePin
    let settings: TerminalSettings
    let activity: AppActivityCoordinator
    let driver: RexScreenDriver

    var body: some View {
        NavigationStack {
            if driver.isShown {
                WorkspaceTerminalDetailView(
                    terminal: terminal,
                    console: console,
                    corePin: corePin,
                    settings: settings,
                    activity: activity,
                    onSelectAgent: { _ in },
                    onSelectTerminal: { _ in },
                    isSelected: { driver.isShown },
                    onBack: {}
                )
                .id(driver.generation)
            }
        }
        .environment(\.scenePhase, .active)
    }
}
