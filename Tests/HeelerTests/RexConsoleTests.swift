import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What a Rex Host offers and how the Console shows it (ADRs 0047 to 0050):
/// nothing to start, close or rename, no integrations, its terminals listed
/// from the server, and opened to view and type into.
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
        }
        #expect(rex.capabilities == HostCapabilities(serverKind: .rex))
    }

    /// The Notifications, Live Activities and Usage surfaces each pick their
    /// Hosts by kind, and none of them picks a Rex Host.
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
        offersRexHosts: Bool = true, servers: [FakeRexServer] = [], dials: Dials = Dials(),
        rexConnect: (@Sendable (RexSocket?, RexControlLink?) async throws -> any RexTransport)? = nil
    ) -> ConsoleStore {
        let hosts = Mutex(servers.map { ScriptedRexHost(control: [.server($0)]) })
        return ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
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
            offersRexHosts: offersRexHosts)
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

    /// With the switch off a Rex Host is not the Console's: nothing dials it,
    /// however the Console is woken.
    @Test func withTheSwitchOffNothingDialsARexHost() async {
        let dials = Dials()
        let store = store(offersRexHosts: false, dials: dials)
        defer { store.setHosts([]) }
        let rex = rex

        store.setHosts([rex])
        await store.resume()
        await store.retryHost(rex.id)
        await store.retryFailedHosts()
        await store.reactivate()

        #expect(dials.all == [])
        #expect(store.hostStatuses[rex.id] == nil)
        #expect(store.terminals.isEmpty)
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
    /// after its windows, and no Agents.
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
    /// live, and takes input from that first paint (ADRs 0049 and 0050).
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

    /// A Rex Host lists Terminals only: the Agents list, its Host filter and
    /// its issues leave it out, and the Terminals list keeps its problem.
    @Test func onlyTheTerminalsListShowsARexHost() async throws {
        let rex = rex
        let tmux = Host(
            name: "tmux", address: "tmux.example", username: "dev", serverKind: .tmux, sessionName: "default")
        let catalog = HostStore(volatileHosts: [rex, tmux])
        let console = store(rexConnect: { _, _ in throw TransportError.rexForwardingRefused(socketPath: "/run/rex.sock") })
        defer { console.setHosts([]) }
        console.setHosts([rex])
        await console.resume()
        try await waitUntil("the failure") { console.hostStatuses[rex.id] == .failed(.rexForwardingRefused(socketPath: "/run/rex.sock")) }

        #expect(ConsoleView.listedHosts(on: .agents, in: catalog) == [tmux])
        #expect(ConsoleView.listedHosts(on: .terminals, in: catalog) == [rex, tmux])
        func issueHostIDs(on tab: ConsoleTab, filter: Set<Host.ID> = []) -> [Host.ID] {
            ConsoleView.filteredHostIssues(on: tab, hosts: catalog, console: console, hostFilter: filter)
                .map(\.hostID)
        }
        #expect(!issueHostIDs(on: .agents).contains(rex.id))
        #expect(!issueHostIDs(on: .agents, filter: [rex.id]).contains(rex.id))
        #expect(issueHostIDs(on: .terminals).contains(rex.id))
        #expect(!issueHostIDs(on: .terminals, filter: [tmux.id]).contains(rex.id))
    }
}
