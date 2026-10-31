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

    private func started(_ terminals: [JSONValue]) async throws -> (ConsoleStore, ScriptedCoreTransport) {
        let transport = ScriptedCoreTransport(subscribeResults: [Self.subscribeResult(terminals)])
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

        // A change republishes every gate's input while the Host is connected.
        await transport.deliver(
            Self.statusEvent(sequence: 2, terminal: "t1", Self.report("idle", app: "claude-code")))
        try await waitUntil("the change") { agent(store, "t1")?.agent.status == .idle }
        await Task.yield()
        #expect(transport.hostServicesBorrows == 0)
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
