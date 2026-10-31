import Foundation
import Testing

@testable import Heeler

/// Close on a core Host, through `ConsoleStore` and a scripted core: each
/// affected Terminal gets one `terminal.kill`, sent as a mutation and never again
/// (ADR 0032). The records and events follow what herdr-core 0.1.13 sends.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreCloseTests {
    private let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)

    private static func shell(_ address: String, labels: [String: String] = [:]) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "labels": .object(labels.mapValues(JSONValue.string)),
        ])
    }

    private static func agent(_ address: String, labels: [String: String] = [:]) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
                "cwd": .string("/work/app"),
            ]),
            "status": .object(["state": .string("working"), "app": .string("claude-code")]),
        ])
    }

    private static func tab(_ tab: String) -> [String: String] {
        ["herdr.space": "s1", "herdr.tab": tab]
    }

    private static func event(sequence: Int, type: String, terminal: String, data: JSONValue) -> Data {
        (try? JSONEncoder().encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "method": .string("event"),
            "params": .object([
                "seq": .number(Double(sequence)), "type": .string(type),
                "terminal": .string(terminal), "data": data,
            ]),
        ]))) ?? Data()
    }

    private static func killed(sequence: Int, terminal: String) -> Data {
        event(
            sequence: sequence, type: "finished", terminal: terminal,
            data: .object([
                "reason": .string("killed"), "exit_code": .null, "signal": .number(1),
                "finished_ms": .number(5),
            ]))
    }

    private func started(_ terminals: [JSONValue]) async throws -> (ConsoleStore, ScriptedCoreTransport) {
        let (store, transport) = makeStore(terminals)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return (store, transport)
    }

    private func makeStore(_ terminals: [JSONValue]) -> (ConsoleStore, ScriptedCoreTransport) {
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
            ])
        let defaults = UserDefaults(suiteName: "core-close-\(UUID().uuidString)") ?? .standard
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
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

    private func panes(_ store: ConsoleStore) -> Set<String> {
        Set(store.terminals.map(\.paneID) + store.agents.map(\.agent.paneID))
    }

    // MARK: One Pane

    /// A kill is final even on a kept Terminal, so no keep is cleared first.
    @Test func closingAPaneSendsOneKillAndNoOtherMutation() async throws {
        let (store, transport) = try await started([Self.shell("t1"), Self.shell("t2")])
        defer { store.setHosts([]) }

        try await store.closePane("t1", on: host.id)

        #expect(await transport.kills == ["t1"])
        #expect(await transport.mutations == ["terminal.kill"])
    }

    @Test func aKilledTerminalLeavesTheConsoleWhenItReportsFinished() async throws {
        let (store, transport) = try await started([Self.shell("t1"), Self.agent("t2")])
        defer { store.setHosts([]) }
        #expect(panes(store) == ["t1", "t2"])

        try await store.closePane("t2", on: host.id)
        try await store.closePane("t1", on: host.id)
        await transport.deliver(Self.killed(sequence: 2, terminal: "t2"))
        await transport.deliver(Self.killed(sequence: 3, terminal: "t1"))

        try await waitUntil("both to leave") { panes(store).isEmpty }
        #expect(await transport.subscribeCount == 1)
    }

    // MARK: A whole Tab

    /// A row whose confirmation outlived its Tab's last-Pane count still takes
    /// everything in the Tab by then, and nothing outside it.
    @Test func closingATabSendsOneKillForEachTerminalInIt() async throws {
        let (store, transport) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.shell("t9", labels: Self.tab("tb2")),
        ])
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first { $0.agent.paneID == "t1" })
        #expect(store.closesTab(of: row))

        await transport.deliver(
            Self.event(
                sequence: 2, type: "created", terminal: "t2", data: Self.shell("t2", labels: Self.tab("tb1"))))
        try await waitUntil("the new Pane") { panes(store).contains("t2") }

        try await store.closeAgent(row)

        #expect(await transport.kills.sorted() == ["t1", "t2"])
        #expect(await transport.mutations == ["terminal.kill", "terminal.kill"])
    }

    @Test func aTerminalRowAloneInItsTabKillsOnlyItself() async throws {
        let (store, transport) = try await started([
            Self.shell("t1", labels: Self.tab("tb1")), Self.shell("t2", labels: Self.tab("tb2")),
        ])
        defer { store.setHosts([]) }
        let row = try #require(store.terminals.first { $0.paneID == "t1" })
        #expect(store.closesTab(of: row))

        try await store.closeTerminal(row)

        #expect(await transport.kills == ["t1"])
    }

    @Test func aRowBesideOtherPanesKillsOnlyItsOwnTerminal() async throws {
        let (store, transport) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.shell("t2", labels: Self.tab("tb1")),
            Self.agent("t3", labels: Self.tab("tb1")),
        ])
        defer { store.setHosts([]) }
        let terminal = try #require(store.terminals.first { $0.paneID == "t2" })
        let agent = try #require(store.agents.first { $0.agent.paneID == "t3" })
        #expect(!store.closesTab(of: terminal))
        #expect(!store.closesTab(of: agent))

        try await store.closeTerminal(terminal)
        try await store.closeAgent(agent)

        #expect(await transport.kills == ["t2", "t3"])
    }

    // MARK: Refused or no answer

    @Test func aKillWithNoAnswerReadsAsOutcomeUnknownAndIsNeverSentAgain() async throws {
        let (store, transport) = try await started([Self.shell("t1"), Self.shell("t2")])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t1")

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closePane("t1", on: self.host.id)
        }

        // A new link is where a replay would go.
        await transport.endLink()
        await transport.waitForSubscribe(count: 2)
        try await waitUntil("the next snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        #expect(await transport.kills == ["t1"])
    }

    @Test func aTabsOtherTerminalsStillGetTheirOneKillAfterOneHasNoAnswer() async throws {
        let (store, transport) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.agent("t2", labels: Self.tab("tb1")),
            Self.shell("t3", labels: Self.tab("tb1")),
        ])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t1")
        await transport.setKillAnswer(
            .failure(HerdrAPIError(code: "invalid_params", message: "no")), for: "t2")
        let row = try #require(store.agents.first { $0.agent.paneID == "t1" })
        // As this row read before the others joined its Tab.
        let stale = ConsoleAgent(
            hostID: row.hostID, hostName: row.hostName, agent: row.agent, workspaceLabel: nil,
            repositoryCheckout: nil)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closeAgent(stale)
        }

        #expect(await transport.kills == ["t1", "t2", "t3"])
    }

    @Test func aKillAnsweredWithARunningTerminalIsOutcomeUnknown() async throws {
        let (store, transport) = try await started([Self.shell("t1")])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(.success(Self.shell("t1")), for: "t1")

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closePane("t1", on: self.host.id)
        }
    }

    @Test func aKillAnsweredWithNothingReadableIsOutcomeUnknown() async throws {
        let (store, transport) = try await started([Self.shell("t1")])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(.success(.object(["state": .number(1)])), for: "t1")

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closePane("t1", on: self.host.id)
        }
    }

    /// `--rm` Terminals are gone before the core reads the record back.
    @Test func aTerminalTheCoreNoLongerKnowsCountsAsEnded() async throws {
        let (store, transport) = try await started([Self.shell("t1")])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(
            .failure(HerdrAPIError(code: "not_found", message: "no terminal")), for: "t1")

        try await store.closePane("t1", on: host.id)

        #expect(await transport.kills == ["t1"])
    }

    /// The core is what refused, wherever Close was asked from.
    @Test func aRefusedKillSaysWhatTheCoreSaid() async throws {
        let (store, transport) = try await started([Self.shell("t1")])
        defer { store.setHosts([]) }
        await transport.setKillAnswer(
            .failure(HerdrAPIError(code: "invalid_params", message: "no")), for: "t1")

        let refusal = await #expect(throws: (any Error).self) {
            try await store.closePane("t1", on: self.host.id)
        }
        let row = try #require(refusal)
        #expect(ConsoleStore.tabCloseFailureMessage(for: row) == "herdr-core rejected the close: no")

        let hostID = host.id
        let detail = ClosePaneStore(paneTitle: "Claude") {
            try await store.closePane("t1", on: hostID)
        }
        await detail.confirmClose()
        #expect(detail.state == .failed("herdr-core rejected the close: no"))
    }

    /// A core that stopped with SSH still up is said in words.
    @Test(arguments: [true, false])
    func aCloseWithNoCoreRunningSaysSo(socketFilePresent: Bool) async {
        let error = TransportError.herdrCoreNotRunning(
            socketPath: "/run/core.sock", socketFilePresent: socketFilePresent)
        let store = ClosePaneStore(paneTitle: "Claude") { throw error }

        await store.confirmClose()

        guard case .failed(let detail) = store.state else {
            Issue.record("The close ended as \(store.state)")
            return
        }
        let row = ConsoleStore.tabCloseFailureMessage(for: error)
        for message in [detail, row] {
            #expect(message.hasPrefix("herdr-core is not running: "), "\(message)")
            #expect(message.contains("/run/core.sock"))
            #expect(!message.contains("herdrCoreNotRunning"))
        }
    }

    /// A row kept from an earlier connection, with no inventory yet on this one.
    @Test func aTabCannotBeClosedWithNoInventoryToSayWhatItHolds() async throws {
        let (store, transport) = makeStore([Self.agent("t1", labels: Self.tab("tb1"))])
        defer { store.setHosts([]) }
        await transport.holdSubscribes()
        store.setHosts([host])
        await store.resume()
        await transport.waitForSubscribe(count: 1)
        let row = ConsoleAgent(
            hostID: host.id, hostName: host.name,
            agent: Agent(
                terminalID: "t1", kind: "claude", title: "", status: .unknown, workspaceID: "w1",
                tabID: "tab-t1", paneID: "t1", cwd: "/work/app", revision: 0, name: nil),
            workspaceLabel: nil, repositoryCheckout: nil)

        await #expect(throws: TransportError.self) { try await store.closeAgent(row) }
        await transport.releaseSubscribes()

        #expect(await transport.kills.isEmpty)
    }

    // MARK: Pins

    private func pin(_ addresses: String..., in store: ConsoleStore) {
        for address in addresses { store.togglePin(hostID: host.id, paneID: address) }
    }

    private func isPinned(_ address: String, in store: ConsoleStore) -> Bool {
        store.pins.isPinned(hostID: host.id, paneID: address)
    }

    @Test func anAgentClosedFromItsRowLosesItsPinAndOthersKeepTheirs() async throws {
        let (store, _) = try await started([Self.agent("t1"), Self.agent("t2")])
        defer { store.setHosts([]) }
        pin("t1", "t2", in: store)

        try await store.closeAgent(try #require(store.agents.first { $0.agent.paneID == "t1" }))

        #expect(!isPinned("t1", in: store))
        #expect(isPinned("t2", in: store))
    }

    @Test func everyAgentThatClosesWithItsTabLosesItsPin() async throws {
        let (store, transport) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.agent("t9", labels: Self.tab("tb2")),
        ])
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first { $0.agent.paneID == "t1" })
        await transport.deliver(
            Self.event(
                sequence: 2, type: "created", terminal: "t2", data: Self.agent("t2", labels: Self.tab("tb1"))))
        try await waitUntil("the other Agent") { store.agents.contains { $0.agent.paneID == "t2" } }
        pin("t1", "t2", "t9", in: store)

        try await store.closeAgent(row)

        #expect(!isPinned("t1", in: store))
        #expect(!isPinned("t2", in: store))
        #expect(isPinned("t9", in: store))
    }

    @Test func anAgentBesideOtherPanesLosesOnlyItsOwnPin() async throws {
        let (store, _) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.agent("t2", labels: Self.tab("tb1")),
        ])
        defer { store.setHosts([]) }
        pin("t1", "t2", in: store)

        try await store.closeAgent(try #require(store.agents.first { $0.agent.paneID == "t1" }))

        #expect(!isPinned("t1", in: store))
        #expect(isPinned("t2", in: store))
    }

    @Test func aKillWithNoAnswerKeepsThePin() async throws {
        let (store, transport) = try await started([Self.agent("t1")])
        defer { store.setHosts([]) }
        pin("t1", in: store)
        await transport.setKillAnswer(.failure(TransportError.coreMutationOutcomeUnknown), for: "t1")
        let row = try #require(store.agents.first)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closeAgent(row)
        }

        #expect(isPinned("t1", in: store))
    }

    /// The row read as alone in its Tab, so both go by `closeTab`. The Terminal
    /// that ended has no reason to keep a Pin because another did not answer.
    @Test func aTabWithOneKillUnconfirmedKeepsOnlyThatTerminalsPin() async throws {
        let (store, transport) = try await started([
            Self.agent("t1", labels: Self.tab("tb1")), Self.agent("t2", labels: Self.tab("tb1")),
        ])
        defer { store.setHosts([]) }
        pin("t1", "t2", in: store)
        await transport.setKillAnswer(.success(Self.agent("t2", labels: Self.tab("tb1"))), for: "t2")
        let row = try #require(store.agents.first { $0.agent.paneID == "t1" })
        let stale = ConsoleAgent(
            hostID: row.hostID, hostName: row.hostName, agent: row.agent, workspaceLabel: nil,
            repositoryCheckout: nil)

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) {
            try await store.closeAgent(stale)
        }

        #expect(await transport.kills == ["t1", "t2"])
        #expect(!isPinned("t1", in: store))
        #expect(isPinned("t2", in: store))
    }

    // MARK: Saying so

    private static let unconfirmed =
        "The Host did not confirm the close. The Terminal may already have ended, "
        + "so check it before trying again."

    @Test func aRowsCloseSaysSoWhenTheHostDidNotConfirm() {
        #expect(
            ConsoleStore.tabCloseFailureMessage(for: TransportError.coreMutationOutcomeUnknown)
                == Self.unconfirmed)
    }

    /// The detail's Close asks once for each confirmation.
    @Test func aDetailsCloseSaysSoAndDoesNotAskAgain() async {
        var closes = 0
        let store = ClosePaneStore(paneTitle: "Claude") {
            closes += 1
            throw TransportError.coreMutationOutcomeUnknown
        }

        await store.confirmClose()

        #expect(store.state == .failed(Self.unconfirmed))
        #expect(closes == 1)
    }

    // MARK: With the screen gone

    private final class Reports {
        var messages: [String] = []
    }

    /// Agent detail went with the link while the kill was on its way.
    @Test func aCloseThatFailsAfterItsScreenLeftIsHandedOver() async {
        let reports = Reports()
        let store = ClosePaneStore(paneTitle: "Claude") {
            throw TransportError.coreMutationOutcomeUnknown
        }
        store.didLeaveScreen(reportingTo: { reports.messages.append($0) })

        await store.confirmClose()

        #expect(reports.messages == [Self.unconfirmed])
        #expect(store.state == .idle)
    }

    @Test func aFailureStillOnScreenWhenItLeavesIsHandedOverOnce() async {
        let reports = Reports()
        let store = ClosePaneStore(paneTitle: "Claude") {
            throw TransportError.coreMutationOutcomeUnknown
        }
        await store.confirmClose()
        #expect(store.state == .failed(Self.unconfirmed))

        store.didLeaveScreen(reportingTo: { reports.messages.append($0) })
        store.didLeaveScreen(reportingTo: { reports.messages.append($0) })

        #expect(reports.messages == [Self.unconfirmed])
    }

    @Test func aFailureAlreadyDismissedIsNotHandedOver() async {
        let reports = Reports()
        let store = ClosePaneStore(paneTitle: "Claude") {
            throw TransportError.coreMutationOutcomeUnknown
        }
        await store.confirmClose()
        store.dismissFailure()

        store.didLeaveScreen(reportingTo: { reports.messages.append($0) })

        #expect(reports.messages.isEmpty)
    }

    @Test func aScreenThatCameBackKeepsItsFailureAndNoReportersMeansItStays() async {
        let reports = Reports()
        let store = ClosePaneStore(paneTitle: "Claude") {
            throw TransportError.coreMutationOutcomeUnknown
        }
        store.didLeaveScreen(reportingTo: { reports.messages.append($0) })
        store.didReturnToScreen()

        await store.confirmClose()

        #expect(reports.messages.isEmpty)
        #expect(store.state == .failed(Self.unconfirmed))

        store.didLeaveScreen(reportingTo: nil)
        #expect(store.state == .failed(Self.unconfirmed))
    }

    // MARK: What a core Host offers

    @Test func aCoreHostOffersCloseOnItsRowsAndDetails() {
        #expect(HostCapabilities(serverKind: .herdrCore).closeTab)
    }
}

/// A kill on the real link and transport, over a scripted Host.
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreKillTransportTests {
    private static let coreChannel = ScriptedCoreHost.Channel.core(ScriptedCoreHost.Core())

    @Test func aKillGoesOutOnceAsAMutationAndNoAnswerIsOutcomeUnknown() async throws {
        let host = ScriptedCoreHost(channel: Self.coreChannel)
        let transport = host.transport()

        let kill = Task { try await transport.killTerminal("t1") }
        await host.waitForMethod("terminal.kill")
        let socket = try #require(await host.socket)
        await socket.deliverEndOfFile()

        await #expect(throws: TransportError.coreMutationOutcomeUnknown) { try await kill.value }
        #expect(await host.methods.filter { $0 == "terminal.kill" }.count == 1)
        try await transport.close()
    }
}
