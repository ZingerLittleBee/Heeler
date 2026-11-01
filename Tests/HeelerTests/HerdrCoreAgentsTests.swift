import Foundation
import Testing

@testable import Heeler

/// A core Host's Agents in the Console, through `ConsoleStore`: the Agents list,
/// its Host filter and sections, and what stays closed to them for now.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreAgentsTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func foreground(_ argv: [String], name: String? = nil, pid: Int = 40) -> JSONValue {
        .object([
            "pid": .number(Double(pid)),
            "name": .string(name ?? argv.first.map { ($0 as NSString).lastPathComponent } ?? ""),
            "argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/app/src"),
        ])
    }

    private static func report(_ state: String, app: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["state": .string(state)]
        if let app { fields["app"] = .string(app) }
        return .object(fields)
    }

    private static func record(
        _ address: String, cwd: String = "/work/app", argv: [String] = ["/bin/zsh"], name: String? = nil,
        foreground: JSONValue = .null, status: JSONValue = .null, pid: Int? = 7, reason: String? = nil,
        keep: Bool = false, title: String = "", labels: [String: String] = [:]
    ) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string(cwd), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "keep": .bool(keep), "title": .string(title),
            "cols": .number(80), "rows": .number(24), "foreground": foreground, "status": status,
            "name": name.map(JSONValue.string) ?? .null,
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "reason": reason.map(JSONValue.string) ?? .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func claude(
        _ address: String, cwd: String = "/work/app", state: String = "working", title: String = "",
        keep: Bool = false, name: String? = nil, labels: [String: String] = [:]
    ) -> JSONValue {
        record(
            address, cwd: cwd, name: name, foreground: foreground(["claude"]),
            status: report(state, app: "claude-code"), keep: keep, title: title, labels: labels)
    }

    private static func subscribeResult(_ terminals: [JSONValue]) -> JSONValue {
        .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
    }

    private static func event(
        sequence: Int, type: String, terminal: String, data: JSONValue
    ) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private static func statusEvent(
        sequence: Int, terminal: String, _ status: JSONValue
    ) -> Data {
        event(
            sequence: sequence, type: "status", terminal: terminal,
            data: .object(["status": status, "records": .object([:]), "reported": .bool(status != .null)]))
    }

    private func started(
        _ terminals: [JSONValue], document: JSONValue? = nil
    ) async throws -> (ConsoleStore, ScriptedCoreTransport) {
        let transport = ScriptedCoreTransport(subscribeResults: [Self.subscribeResult(terminals)])
        if let document { await transport.setDocument(document, version: 3) }
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "core-agents-\(UUID().uuidString)") ?? .standard))
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return (store, transport)
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func agent(_ store: ConsoleStore, _ address: String) -> ConsoleAgent? {
        store.agents.first { $0.agent.paneID == address }
    }

    private func shells(_ store: ConsoleStore) -> [String] {
        TerminalListPresentationStore(defaults: UserDefaults(suiteName: "core-\(UUID())") ?? .standard)
            .projection(hosts: [host], console: store).workspaces()
            .flatMap { $0.terminals.map(\.paneID) }
    }

    private func list() -> ConsoleListPresentationStore {
        ConsoleListPresentationStore(
            defaults: UserDefaults(suiteName: "core-list-\(UUID().uuidString)") ?? .standard)
    }

    // MARK: Where an Agent shows

    @Test func aTerminalHoldingAnAgentListsAsAnAgentAndNotAsATerminal() async throws {
        let (store, _) = try await started([
            Self.claude("t1", title: "fix the flaky test", name: "review"),
            Self.record("t2", foreground: Self.foreground(["/bin/zsh"])),
        ])
        defer { store.setHosts([]) }

        #expect(store.agents.map(\.agent.paneID) == ["t1"])
        let row = try #require(agent(store, "t1"))
        #expect(row.agent.kind == "claude")
        #expect(row.agent.status == .working)
        #expect(row.agent.name == "review")
        #expect(row.agent.cwd == "/work/app")
        #expect(row.directory == "/work/app/src")
        #expect(row.agent.terminalTitleStripped == "fix the flaky test")
        #expect(row.hostName == host.displayName)
        #expect(row.workspaceLabel == "app")
        #expect(shells(store) == ["t2"])
        #expect(store.terminals.first { $0.paneID == "t1" }?.isAgent == true)
        #expect(store.terminals.first { $0.paneID == "t2" }?.isAgent == false)
    }

    @Test func agentsShowByHostByWorkspaceAndUnderTheHostFilter() async throws {
        let tui = Host.fixture()
        let core = ScriptedCoreTransport(subscribeResults: [
            Self.subscribeResult([
                Self.claude("t1", cwd: "/work/app"),
                Self.claude("t2", cwd: "/work/docs", state: "idle"),
                Self.record("t3", cwd: "/work/docs"),
            ])
        ])
        let herdr = ScriptedTransport(
            snapshot: SessionSnapshot(
                agents: [.fixture(paneID: "w1:p1")], layouts: [],
                panes: [], protocolVersion: 17, tabs: [], version: "0.7.5-fake",
                workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { herdr }, keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { core }, keepalive: nil) },
            coreHostMemory: HerdrCoreHostMemory(
                defaults: UserDefaults(suiteName: "core-agents-\(UUID().uuidString)") ?? .standard))
        defer { store.setHosts([]) }
        store.setHosts([host, tui])
        await store.resume()
        try await waitUntil("both Hosts listed") { store.agents.count == 3 }

        let presentation = list()
        let byHost = presentation.sections(hosts: [host, tui], console: store)
        #expect(byHost.map(\.hostID) == [host.id, tui.id])
        #expect(Set(byHost[0].agents.map(\.agent.paneID)) == ["t1", "t2"])
        #expect(byHost[1].agents.map(\.agent.paneID) == ["w1:p1"])

        let filtered = presentation.sections(hosts: [host, tui], console: store, filteredHostID: host.id)
        #expect(filtered.map(\.hostID) == [host.id])
        #expect(Set(filtered[0].agents.map(\.agent.paneID)) == ["t1", "t2"])

        let byWorkspace = presentation.workspaceSections(
            hosts: [host, tui], console: store, filteredHostID: host.id)
        #expect(Set(byWorkspace.map(\.title)) == ["app", "docs"])
        #expect(byWorkspace.first { $0.title == "app" }?.agents.map(\.agent.paneID) == ["t1"])
        #expect(byWorkspace.first { $0.title == "docs" }?.agents.map(\.agent.paneID) == ["t2"])
    }

    /// Zeta before Alpha, and Zeta's Tab holding z2 before z1.
    private static let zetaThenAlpha = CoreDesktopJSON.document([
        CoreDesktopJSON.space(
            "s2", name: "Zeta", tabs: [CoreDesktopJSON.tab("tb2", name: "logs", terminals: ["z2", "z1"])]),
        CoreDesktopJSON.space("s1", name: "Alpha", tabs: [CoreDesktopJSON.tab("tb1", name: "main")]),
    ])

    private static func inSpace(_ space: String, _ tab: String) -> [String: String] {
        ["herdr.space": space, "herdr.tab": tab]
    }

    @Test func agentsFollowTheDesktopAppsOrderWithinEachStatus() async throws {
        let (store, transport) = try await started(
            [
                Self.claude("a1", state: "idle", labels: Self.inSpace("s1", "tb1")),
                Self.claude("z1", state: "idle", labels: Self.inSpace("s2", "tb2")),
                Self.claude("z2", state: "idle", labels: Self.inSpace("s2", "tb2")),
            ], document: Self.zetaThenAlpha)
        defer { store.setHosts([]) }

        #expect(store.agents.map(\.agent.paneID) == ["z2", "z1", "a1"])
        #expect(list().workspaceSections(hosts: [host], console: store).map(\.title) == ["Zeta", "Alpha"])

        await transport.deliver(
            Self.statusEvent(sequence: 2, terminal: "a1", Self.report("blocked", app: "claude-code")))
        try await waitUntil("the Blocked Agent") { agent(store, "a1")?.agent.status == .blocked }

        // Who needs you still comes first, and their Workspace with them.
        #expect(store.agents.map(\.agent.paneID) == ["a1", "z2", "z1"])
        #expect(list().workspaceSections(hosts: [host], console: store).map(\.title) == ["Alpha", "Zeta"])
    }

    // MARK: Deltas

    @Test func anAgentComesAndGoesWithTheForeground() async throws {
        let (store, transport) = try await started([
            Self.record("t1", foreground: Self.foreground(["/bin/zsh"]))
        ])
        defer { store.setHosts([]) }
        #expect(store.agents.isEmpty)

        await transport.deliver(
            Self.event(sequence: 2, type: "foreground", terminal: "t1", data: Self.foreground(["codex"])))
        try await waitUntil("codex") { agent(store, "t1")?.agent.kind == "codex" }
        #expect(shells(store).isEmpty)
        #expect(agent(store, "t1")?.agent.status == .unknown)

        await transport.deliver(
            Self.statusEvent(sequence: 3, terminal: "t1", Self.report("working", app: "codex")))
        try await waitUntil("its report") { agent(store, "t1")?.agent.status == .working }

        await transport.deliver(
            Self.event(sequence: 4, type: "foreground", terminal: "t1", data: Self.foreground(["/bin/zsh"])))
        try await waitUntil("the shell ends it") { store.agents.isEmpty }
        #expect(shells(store) == ["t1"])
    }

    @Test func underTheDesktopFishWrapperNewArgumentsOnTheSamePidEndTheAgent() async throws {
        let wrapper = [
            "/usr/bin/fish", "-ic", "command $argv[2..]; exec $argv[1] -i", "/usr/bin/fish", "claude",
        ]
        let (store, transport) = try await started([
            Self.record(
                "t1", argv: wrapper, foreground: Self.foreground(wrapper, name: "fish", pid: 77),
                status: Self.report("working", app: "claude-code"))
        ])
        defer { store.setHosts([]) }
        #expect(agent(store, "t1")?.agent.kind == "claude")

        await transport.deliver(
            Self.event(
                sequence: 2, type: "foreground", terminal: "t1",
                data: Self.foreground(["/usr/bin/fish", "-i"], name: "fish", pid: 77)))
        try await waitUntil("the Agent ended") { store.agents.isEmpty }
        #expect(shells(store) == ["t1"])
    }

    /// Delivers a cleared foreground, then a title to know it has been folded.
    private func clearForeground(
        of address: String, sequence: Int, store: ConsoleStore, transport: ScriptedCoreTransport
    ) async throws {
        await transport.deliver(
            Self.event(sequence: sequence, type: "foreground", terminal: address, data: .null))
        let title = "after the clear \(sequence)"
        await transport.deliver(
            Self.event(
                sequence: sequence + 1, type: "title", terminal: address,
                data: .object(["title": .string(title)])))
        try await waitUntil("the clear folded") {
            store.terminals.first { $0.paneID == address }?.pane.terminalTitle == title
        }
    }

    @Test func aClearedForegroundBringsNoExitedAgentBackFromTheLaunchCommand() async throws {
        let wrapper = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "claude"]
        let (store, transport) = try await started([
            Self.record(
                "t1", argv: wrapper, foreground: Self.foreground(["/bin/zsh", "-i"]),
                status: Self.report("working", app: "claude-code"))
        ])
        defer { store.setHosts([]) }
        #expect(store.agents.isEmpty)

        // `printf x | less` in the shell the Agent left: the group's leader is gone.
        try await clearForeground(of: "t1", sequence: 2, store: store, transport: transport)
        #expect(store.agents.isEmpty)
        #expect(shells(store) == ["t1"])
    }

    @Test func aClearedForegroundKeepsTheAgentItWasSampledHolding() async throws {
        let (store, transport) = try await started([
            Self.record(
                "t1", foreground: Self.foreground(["claude"]),
                status: Self.report("working", app: "claude-code"))
        ])
        defer { store.setHosts([]) }
        #expect(agent(store, "t1")?.agent.kind == "claude")

        try await clearForeground(of: "t1", sequence: 2, store: store, transport: transport)
        #expect(agent(store, "t1")?.agent.kind == "claude")
        #expect(agent(store, "t1")?.agent.status == .working)
        #expect(agent(store, "t1")?.directory == "/work/app/src")
        #expect(shells(store).isEmpty)

        await transport.deliver(
            Self.event(
                sequence: 4, type: "foreground", terminal: "t1", data: Self.foreground(["/bin/zsh", "-i"])))
        try await waitUntil("the next sample decides") { store.agents.isEmpty }
        #expect(shells(store) == ["t1"])
    }

    /// A record omits a cleared foreground, so a reconnect's snapshot cannot say
    /// the shell the wrapper continued as has one. The first sample speaks for it.
    @Test func aDesktopWrapperLaunchWaitsForItsFirstSample() async throws {
        let wrapper = ["/bin/zsh", "-ic", "\"$@\"; exec \"$0\" -i", "/bin/zsh", "claude"]
        let (store, transport) = try await started([
            Self.record("t1", argv: wrapper, status: Self.report("idle", app: "claude-code"))
        ])
        defer { store.setHosts([]) }
        #expect(store.agents.isEmpty)
        #expect(shells(store) == ["t1"])

        await transport.deliver(
            Self.event(
                sequence: 2, type: "foreground", terminal: "t1",
                data: Self.foreground(wrapper, name: "zsh", pid: 77)))
        try await waitUntil("the sample names it") { agent(store, "t1")?.agent.kind == "claude" }
        #expect(agent(store, "t1")?.agent.status == .idle)
    }

    @Test func aReportFromAProgramThatLeftEndsNothingButNamesNothing() async throws {
        let (store, transport) = try await started([Self.claude("t1", state: "idle")])
        defer { store.setHosts([]) }

        await transport.deliver(
            Self.event(sequence: 2, type: "foreground", terminal: "t1", data: Self.foreground(["vim"])))
        try await waitUntil("a known app that does not name the foreground") { store.agents.isEmpty }
        #expect(shells(store) == ["t1"])
    }

    @Test func aTerminalBetweenLostAndRestartedHostsNoAgent() async throws {
        let (store, transport) = try await started([Self.claude("t1", keep: true)])
        defer { store.setHosts([]) }
        #expect(agent(store, "t1") != nil)

        await transport.deliver(
            Self.event(
                sequence: 2, type: "lost", terminal: "t1",
                data: .object(["reason": .string("signaled"), "signal": .number(9)])))
        try await waitUntil("no Agent") { store.agents.isEmpty }
        #expect(store.terminals.first { $0.paneID == "t1" }?.isRestarting == true)
        #expect(store.terminals.first { $0.paneID == "t1" }?.isAgent == false)

        // Its foreground lingers on the wire, and reports keep coming: neither brings it back.
        await transport.deliver(
            Self.statusEvent(sequence: 3, terminal: "t1", Self.report("working", app: "claude-code")))
        await transport.deliver(
            Self.event(sequence: 4, type: "title", terminal: "t1", data: .object(["title": .string("late")])))
        try await waitUntil("the late title") {
            store.terminals.first { $0.paneID == "t1" }?.pane.terminalTitle == "late"
        }
        #expect(store.agents.isEmpty)

        // It comes back as the core's shell, having reported nothing.
        await transport.deliver(
            Self.event(
                sequence: 5, type: "restarted", terminal: "t1",
                data: Self.record("t1", argv: ["/bin/bash"], pid: 99, keep: true)))
        try await waitUntil("restarted") {
            store.terminals.first { $0.paneID == "t1" }?.isRestarting == false
        }
        #expect(store.agents.isEmpty)

        await transport.deliver(
            Self.event(sequence: 6, type: "foreground", terminal: "t1", data: Self.foreground(["claude"])))
        try await waitUntil("a new Agent") { agent(store, "t1") != nil }
        #expect(agent(store, "t1")?.agent.status == .unknown)
    }

    @Test func aSuspendedHostHoldsNoAgents() async throws {
        let (store, _) = try await started([Self.claude("t1")])
        defer { store.setHosts([]) }
        #expect(!store.agents.isEmpty)

        await store.suspend()
        try await waitUntil("the inventory dropped") { store.agents.isEmpty }
    }

    // MARK: Agent Status

    @Test(arguments: [
        ("idle", AgentStatus.idle), ("working", .working), ("blocked", .blocked), ("error", .error),
        ("done", .idle),
    ])
    func agentStatusFollowsProgramStatus(state: String, expected: AgentStatus) async throws {
        let (store, transport) = try await started([
            Self.record("t1", foreground: Self.foreground(["claude"]))
        ])
        defer { store.setHosts([]) }
        #expect(agent(store, "t1")?.agent.status == .unknown)

        await transport.deliver(
            Self.statusEvent(sequence: 2, terminal: "t1", Self.report(state, app: "claude-code")))
        try await waitUntil("the report") { agent(store, "t1")?.agent.status != .unknown }
        #expect(agent(store, "t1")?.agent.status == expected)
    }

    @Test func aClearedStatusReadsUnknownAgain() async throws {
        let (store, transport) = try await started([Self.claude("t1")])
        defer { store.setHosts([]) }
        #expect(agent(store, "t1")?.agent.status == .working)

        await transport.deliver(Self.statusEvent(sequence: 2, terminal: "t1", .null))
        try await waitUntil("cleared") { agent(store, "t1")?.agent.status == .unknown }
    }

    @Test func errorShowsAsItselfAndSortsWithBlocked() async throws {
        let (store, _) = try await started([
            Self.claude("t1", state: "idle"), Self.claude("t2", state: "working"),
            Self.claude("t3", state: "error"), Self.claude("t4", state: "blocked"),
        ])
        defer { store.setHosts([]) }

        let order = store.agents.map(\.agent.paneID)
        #expect(Set(order.prefix(2)) == ["t3", "t4"])
        #expect(Array(order.suffix(2)) == ["t2", "t1"])
        #expect(agent(store, "t3")?.agent.status.displayTitle == "Error")
        let counts = ConsoleHostAgentStatusCounts(agents: store.agents)
        #expect(counts.error == 1)
        #expect(counts.blocked == 1)
    }

    // MARK: A program Heeler does not know

    @Test func aProgramHeelerDoesNotKnowIsAnAgentWithNoChat() async throws {
        let (store, transport) = try await started([
            Self.record(
                "t1", foreground: Self.foreground(["mytool"]),
                status: Self.report("working", app: "Claude")),
            Self.record("t2", foreground: Self.foreground(["vim"])),
        ])
        defer { store.setHosts([]) }

        let row = try #require(agent(store, "t1"))
        #expect(row.agent.kind == "other-claude")
        #expect(row.agent.status == .working)
        #expect(!AgentChatAvailability.mayOfferChat(for: row.agent, hasAdapter: { _ in true }))
        #expect(store.chatProgram(for: row) == nil)
        #expect(agent(store, "t2") == nil)
        #expect(shells(store) == ["t2"])

        // A shell ends it, whatever it reported last.
        await transport.deliver(
            Self.event(sequence: 2, type: "foreground", terminal: "t1", data: Self.foreground(["bash"])))
        try await waitUntil("ended") { store.agents.isEmpty }
    }

    // MARK: Chat stays closed

    /// A core Host offers no Chat yet: even with a Claude Code Agent, nothing
    /// resolves a Chat, and no Chat read reaches the transport.
    @Test func aCoreAgentGetsNoChatAndNoChatReadReachesTheTransport() async throws {
        let (store, transport) = try await started([Self.claude("t1")])
        defer { store.setHosts([]) }
        let row = try #require(agent(store, "t1"))

        #expect(store.chatProgram(for: row) == nil)
        #expect(store.chatStore(for: row, program: .claude) == nil)
        #expect(store.chatDisplayAgents.map(\.id) == [row.id])
        #expect(store.savedChatEntries.isEmpty)

        // The Workspace asks which checkout it is once; nothing else borrows them.
        try await waitUntil("the Workspace's checkout") { transport.hostServicesBorrows == 1 }

        // A change republishes every gate's input while the Host is connected.
        await transport.deliver(
            Self.statusEvent(sequence: 2, terminal: "t1", Self.report("idle", app: "claude-code")))
        try await waitUntil("the change") { agent(store, "t1")?.agent.status == .idle }
        await Task.yield()
        #expect(transport.hostServicesBorrows == 1)
    }

    // MARK: Agent detail

    /// Agent detail opens on its live terminal, and its row reads Changes
    /// through the kind-neutral Host services.
    @Test func aCoreAgentOpensItsDetailAndItsRowReadsChangesThroughHostServices() async throws {
        let (store, transport) = try await started([Self.claude("t1")])
        defer { store.setHosts([]) }
        let row = try #require(agent(store, "t1"))

        let offers = ConsoleAgentRowOffers(
            capabilities: store.capabilities(for: host.id), supportsMultipleWindows: true)
        #expect(offers == ConsoleAgentRowOffers(opensInNewWindow: true, closes: true))

        try await waitUntil("the Workspace's checkout") { transport.hostServicesBorrows == 1 }
        store.rowChanges.rowAppeared(row)
        #expect(store.rowChanges.store(for: row) != nil)
        try await waitUntil("a Changes read") { transport.hostServicesBorrows > 1 }
    }

    @Test func aCoreHostHoldsItsTerminalsInEveryWindowAndNeverOffersTakeOver() {
        let core = HostCapabilities(serverKind: .herdrCore)
        #expect(!core.takeOver)
        let away = HostTerminalAccess.liveInAnotherWindow(canTakeOver: true)
        #expect(core.terminalAccess(away) == .holds)
        #expect(LiveInAnotherWindowPresentation(access: core.terminalAccess(away)) == nil)

        let tui = HostCapabilities(serverKind: .herdrTUI)
        #expect(tui.takeOver)
        #expect(tui.terminalAccess(away) == away)
        #expect(tui.terminalAccess(nil) == .holds)
    }

    @Test(arguments: [ServerKind.herdrCore, .herdrTUI])
    func newTerminalIsOfferedBesideATerminalInAUsableDirectory(kind: ServerKind) {
        let capabilities = HostCapabilities(serverKind: kind)
        #expect(
            capabilities.newTerminalRequest(workspaceID: "w1", cwd: "/srv/app")
                == ShellTerminalCreationRequest(workspaceID: "w1", cwd: "/srv/app"))
        #expect(capabilities.newTerminalRequest(workspaceID: "w1", cwd: "") == nil)
    }

    @Test func aHerdrTUIAgentsRowOffersWhatItAlwaysDid() {
        let capabilities = HostCapabilities(serverKind: .herdrTUI)
        #expect(
            ConsoleAgentRowOffers(capabilities: capabilities, supportsMultipleWindows: true)
                == ConsoleAgentRowOffers(opensInNewWindow: true, closes: true))
        #expect(
            ConsoleAgentRowOffers(capabilities: capabilities, supportsMultipleWindows: false)
                == ConsoleAgentRowOffers(opensInNewWindow: false, closes: true))
    }

    // MARK: Agent Row Layout

    private static let titleThenDirectory: [AgentRow] = [
        [.init(.terminalTitleStripped)], [.init(.directory)],
    ]

    @Test func aCoreHostsRowsStartFromTheTitleThenTheDirectory() async throws {
        let (store, _) = try await started([Self.claude("t1", title: "fix the sync")])
        defer { store.setHosts([]) }
        let layout = store.rowLayout(for: host.id)
        #expect(layout.rows == Self.titleThenDirectory)
        let row = try #require(agent(store, "t1"))
        #expect(
            AgentRowRenderer.render(layout: layout, agent: row).map { $0.map(\.text) }
                == [["fix the sync"], ["/work/app"]])
    }

    @Test func aPluginSnapshotNeverSetsACoreHostsRowsButItsSavedLayoutDoes() {
        let plugin = AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.workspace)]]))
        #expect(
            AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin, followsPlugin: false).rows
                == Self.titleThenDirectory)
        let saved = AgentRowLayout(rows: [[.init(.host)]])
        #expect(
            AgentRowLayoutResolver.resolve(hostLayout: saved, pluginSnapshot: plugin, followsPlugin: false)
                == saved)
        // Herdr TUI still follows its plugin.
        #expect(
            AgentRowLayoutResolver.resolve(hostLayout: nil, pluginSnapshot: plugin, followsPlugin: true)
                == plugin.layout.withHeelerRow())
    }

    @Test func theEditorStartsACoreHostFromHeelersRowsAndNeverAsksForPluginFields() async throws {
        let suite = "core-agent-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var fetches = 0
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: HerdrSidebarSnapshotStore(),
            fetch: { _ in
                fetches += 1
                return .loaded(AgentRowLayoutSnapshot(layout: AgentRowLayout(rows: [[.init(.workspace)]])))
            },
            followsPlugin: { _ in false })
        let id = host.id

        #expect(editor.layout(for: id).rows == Self.titleThenDirectory)
        #expect(AgentListFieldsSourceCaption.text(editor.underlyingSource(for: id)) == "Heeler's fields")

        await editor.replaceWithPluginFields(id)
        #expect(fetches == 0)
        #expect(layouts.hostLayouts[id] == nil)
        #expect(editor.syncStates[id] == nil)

        let label = try #require(AgentRowToken.terminalLabel("team.owner"))
        #expect(AgentLayoutTokensEditing.add(label, editor: editor, hostID: id, rowIndex: 1))
        #expect(
            AgentRowLayoutStore(defaults: defaults).hostLayouts[id]?.rows
                == [[.init(.terminalTitleStripped)], [.init(.directory), .init(label)]])
        #expect(AgentListFieldsSourceCaption.text(editor.underlyingSource(for: id)) == "Your fields")
    }

    /// Core accepts any non-empty label key without `=` (terminals.rs
    /// `check_label_key`, v0.1.13), so a label is not a `$` plugin name.
    @Test func aTerminalLabelIsARowFieldReadFromItsTerminal() async throws {
        let (store, _) = try await started([
            Self.claude("t1", labels: ["team.owner": "ana"]),
            Self.record("t2", labels: ["project": "heeler", "team.owner": "bo"]),
        ])
        defer { store.setHosts([]) }
        #expect(store.terminalLabelKeys(on: host.id) == ["project", "team.owner"])

        let owner = try #require(AgentRowToken.terminalLabel("team.owner"))
        #expect(owner.rawValue == "label:team.owner")
        #expect(AgentRowToken(rawValue: "label:team.owner") == owner)
        let project = try #require(AgentRowToken.terminalLabel("project"))
        let row = try #require(agent(store, "t1"))
        // A label the Terminal does not carry leaves no empty field behind.
        let layout = AgentRowLayout(rows: [[.init(owner), .init(project)]])
        #expect(AgentRowRenderer.render(layout: layout, agent: row).map { $0.map(\.text) } == [["ana"]])
    }

    @Test(arguments: ["", "   ", "a=b", "tab\tkey", String(repeating: "k", count: 65)])
    func aKeyCoreWouldRefuseOrThatCannotBeShownIsNoField(key: String) {
        #expect(AgentRowToken.terminalLabel(key) == nil)
        #expect(AgentRowToken(rawValue: "label:\(key)") == nil)
    }

    @Test func aSavedLabelFieldSurvivesTheCatalogThatDropsUnknownNames() throws {
        let data = Data(#"{"rows":[[{"token":"label:team.owner"},{"token":"mystery"}]]}"#.utf8)
        let layout = try JSONDecoder().decode(AgentRowLayout.Lenient.self, from: data).layout
        #expect(layout.rows == [[.init(try #require(AgentRowToken.terminalLabel("team.owner")))]])
    }

    @Test func aCoreHostOffersItsTerminalsLabelsAndNoPluginOnlyFields() throws {
        let project = try #require(AgentRowToken.terminalLabel("project"))
        let team = try #require(AgentRowToken.terminalLabel("team"))
        let offer = AgentLayoutFieldOffer(
            row: [.init(.directory), .init(project)], followsPlugin: false, labelKeys: ["project", "team"])
        #expect(offer.labelFields == [team])
        #expect(offer.acceptsPluginFields == false)
        #expect(offer.herdrFields.isEmpty)
        #expect(offer.heelerFields.isEmpty)
        #expect(offer.hostFields.contains(.terminalTitleStripped))
        #expect(!offer.hostFields.contains(.directory))
        #expect(!offer.hostFields.contains(.stateText))
        #expect(!offer.hostFields.contains(.stateIcon))
    }

    /// A core row's right side offers what only that side holds, and neither
    /// side offers what the slot already shows on the other.
    @Test func aCoreHostsRightSideOffersTheBadgeAndTheTotals() throws {
        let team = try #require(AgentRowToken.terminalLabel("team"))
        let right = AgentLayoutFieldOffer(
            row: [.init(.directory), .init(team)], side: .trailing, followsPlugin: false, labelKeys: ["team"])
        #expect(right.hostFields.contains(.statusBadge))
        #expect(right.hostFields.contains(.changes))
        #expect(!right.hostFields.contains(.directory))
        #expect(right.labelFields.isEmpty)
        let left = AgentLayoutFieldOffer(row: [], followsPlugin: false, labelKeys: [])
        #expect(!left.hostFields.contains(.statusBadge))
        #expect(!left.hostFields.contains(.changes))
    }

    /// Apply to All Hosts can copy a label field onto a Herdr TUI Host. Plugin
    /// 0.8.0 reads a field it does not know as a malformed layout and drops all
    /// of that Host's Live Activity rows, and that Host has no label to show.
    @Test func aLabelFieldAppliedToAHerdrTUIHostStaysOutOfItsLiveActivityFields() throws {
        let suite = "core-agents-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layouts = AgentRowLayoutStore(defaults: defaults)
        let tui = Host(address: "tui.example", username: "dev", serverKind: .herdrTUI)
        let store = ConsoleStore(
            rowLayouts: layouts,
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "never dialed") },
                    keepalive: nil)
            })
        store.setHosts([host, tui])
        defer { store.setHosts([]) }
        let editor = AgentListFieldsEditor(
            layouts: layouts, snapshots: HerdrSidebarSnapshotStore(), fetch: { _ in nil },
            followsPlugin: { store.capabilities(for: $0).syncLayoutFromPlugin })

        let project = AgentRowStyledToken(try #require(AgentRowToken.terminalLabel("project")))
        let owner = AgentRowStyledToken(try #require(AgentRowToken.terminalLabel("team.owner")))
        let fields: [AgentRow] = [[project], [.init(.directory), owner]]
        #expect(editor.commit(host.id) { $0.rows = fields })
        #expect(editor.applyToOtherHosts(from: host.id, among: [host.id, tui.id]) == 1)

        #expect(store.liveActivityRowLayout(for: host.id).rows == fields)
        #expect(store.liveActivityRowLayout(for: tui.id).rows == [[], [.init(.directory)]])
        // Its row editor still shows the copy, so the field can be removed there.
        #expect(store.rowLayout(for: tui.id).rows == fields)
    }

    @Test func aHerdrTUIHostsRightSideOffersTheBadgeAndTheTotalsAmongHeelersFields() {
        let offer = AgentLayoutFieldOffer(row: [], side: .trailing, followsPlugin: true, labelKeys: [])
        #expect(offer.heelerFields == AgentRowToken.heelerBuiltins + AgentRowToken.trailingOnlyBuiltins)
        #expect(offer.hostFields.isEmpty)
    }

    @Test func aHerdrTUIHostsOfferStaysAsItWas() {
        let offer = AgentLayoutFieldOffer(row: [.init(.tab)], followsPlugin: true, labelKeys: ["project"])
        #expect(offer.herdrFields == AgentRowToken.herdrBuiltins.filter { $0 != .tab })
        #expect(offer.heelerFields == AgentRowToken.heelerBuiltins)
        #expect(offer.hostFields.isEmpty)
        #expect(offer.labelFields.isEmpty)
        #expect(offer.acceptsPluginFields)
    }

    @Test func aCoreHostsLayoutCopyMentionsNoSyncNoPluginAndNoHerdrRow() {
        let copy =
            [AgentListFieldsCopy.rowSlots(followsPlugin: false)]
            + (0..<3).map {
                AgentLayoutTokensEditing.navigationSubtitle(
                    hostName: "Studio Mac", rowIndex: $0, followsPlugin: false)
            }
            + (0..<3).map { AgentListFieldsRowLabel.accessibilityLabel(index: $0, row: [], followsPlugin: false) }
        for text in copy {
            #expect(!text.localizedCaseInsensitiveContains("sync"))
            #expect(!text.localizedCaseInsensitiveContains("plugin"))
            #expect(!text.localizedCaseInsensitiveContains("herdr"))
        }
        #expect(AgentListFieldsCopy.rowSlots(followsPlugin: false).contains("Row 1 starts from the terminal's title"))
        #expect(AgentListFieldsCopy.rowSlots(followsPlugin: true) == AgentListFieldsCopy.rowSlots)
    }

    /// The right side is a fact of every Host, and says nothing of herdr.
    @Test func aCoreHostsRightSideSubtitleNamesTheSide() {
        #expect(
            AgentLayoutTokensEditing.navigationSubtitle(
                hostName: "Studio Mac", rowIndex: 0, side: .trailing, followsPlugin: false)
                == "Studio Mac · right side")
    }

    @Test func thePreviewFillsALabelFieldSoItReadsInTheCard() throws {
        let owner = try #require(AgentRowToken.terminalLabel("team.owner"))
        let layout = AgentRowLayout(rows: [[.init(owner)]])
        let sample = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac", layout: layout)
        #expect(AgentRowRenderer.render(layout: layout, agent: sample).map { $0.map(\.text) } == [["team.owner"]])
    }

    @Test func thePreviewFillsALabelFieldOnTheRightSide() throws {
        let owner = try #require(AgentRowToken.terminalLabel("team.owner"))
        let layout = AgentRowLayout(rows: [[.init(.directory)]], trailing: [[.init(owner)], [], []])
        let sample = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac", layout: layout)
        #expect(sample.agent.tokens["team.owner"] == "team.owner")
    }

    /// No sample on its page talks about Sync.
    @Test func aCoreHostsPreviewHasNoSyncSample() {
        let sample = AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac", followsPlugin: false)
        #expect(sample.agent.terminalTitleStripped == "fix login redirect")
        #expect(
            AgentListFieldsPreview.sampleAgent(hostName: "Studio Mac").agent.terminalTitleStripped
                == "fix sidebar sync")
    }

    // MARK: Row fields

    @Test func anAgentCarriesItsTerminalsLabelsAndTitle() async throws {
        let (store, transport) = try await started([
            Self.claude("t1", title: "⠋ fix it", labels: ["herdr.space": "s1", "team": "docs"])
        ])
        defer { store.setHosts([]) }
        let row = try #require(agent(store, "t1"))
        #expect(row.agent.tokens == ["herdr.space": "s1", "team": "docs"])
        #expect(row.agent.terminalTitle == "⠋ fix it")
        #expect(row.agent.terminalTitleStripped == "fix it")

        await transport.deliver(
            Self.event(
                sequence: 2, type: "labels", terminal: "t1",
                data: .object(["labels": .object(["team": .string("web")])])))
        try await waitUntil("the new labels") { agent(store, "t1")?.agent.tokens == ["team": "web"] }
    }

    @Test func anAgentWithNoTitleYetIsNamedForItsProgram() async throws {
        let (store, _) = try await started([Self.claude("t1", title: "")])
        defer { store.setHosts([]) }
        let row = try #require(agent(store, "t1"))
        #expect(row.agent.terminalTitle == nil)
        #expect(row.agent.terminalTitleStripped == "Claude")
    }
}
