import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Lazy terminal connection pool")
struct TerminalConnectionPoolTests {
    @Test func selectionIsLazyAndRetappingReusesTheSameLivePipeline() async throws {
        let probe = PoolSessionProbe()
        let pool = TerminalConnectionPool()
        let host = UUID()
        let owner = UUID()
        let shell = identity("one")
        let first = try await pool.select(
            hostID: host, identity: shell, ownerID: owner,
            generation: 1, runTerminal: runner(probe))
        #expect(await probe.requests.isEmpty)
        first.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 1 })
        pool.release(hostID: host, identity: shell, ownerID: owner)
        #expect(await probe.ended.isEmpty)
        let reused = try await pool.select(
            hostID: host, identity: shell, ownerID: owner,
            generation: 1, runTerminal: runner(probe))
        #expect(first === reused)
        #expect(first.store.terminalID == reused.store.terminalID)
        #expect(await probe.requests.count == 1)
        #expect(await probe.requests.first?.takeover == false)
        await pool.suspend()
        #expect(await probe.ended == ["one"])
    }

    @Test func duplicateConcurrentSelectionsShareOneEntryAndOtherWindowsCannotClaimIt() async throws {
        let pool = TerminalConnectionPool()
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let shell = identity("one")
        let first = Task {
            try await pool.select(hostID: host, identity: shell, ownerID: owner,
                                  generation: 1, runTerminal: runner(probe))
        }
        let second = Task {
            try await pool.select(hostID: host, identity: shell, ownerID: owner,
                                  generation: 1, runTerminal: runner(probe))
        }
        #expect(try await first.value === second.value)
        await #expect(throws: TerminalConnectionPool.Failure.self) {
            try await pool.select(hostID: host, identity: shell, ownerID: UUID(),
                                  generation: 1, runTerminal: runner(probe))
        }
        #expect(pool.entries.count == 1)
        await pool.suspend()
    }

    @Test func idleExpiryDoesNotCloseTheVisibleTerminal() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let pool = TerminalConnectionPool(maximumShellsPerHost: 2, now: { date })
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let one = try await pool.select(hostID: host, identity: identity("one"), ownerID: owner,
                                        generation: 1, runTerminal: runner(probe))
        one.store.viewDidResize(cols: 80, rows: 24)
        pool.release(hostID: host, identity: identity("one"), ownerID: owner)
        let two = try await pool.select(hostID: host, identity: identity("two"), ownerID: owner,
                                        generation: 1, runTerminal: runner(probe))
        two.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 2 })
        date = date.addingTimeInterval(299)
        await pool.expireIdle()
        #expect(pool.entries.count == 2)
        date = date.addingTimeInterval(1)
        await pool.expireIdle()
        #expect(pool.entries.count == 1)
        #expect(await probe.ended == ["one"])
        #expect(two.store.terminalStatus != .stopped)
        await pool.suspend()
    }

    @Test func lruEvictionAwaitsChannelTeardownBeforeAdmittingTheNextTerminal() async throws {
        var date = Date(timeIntervalSince1970: 1_000)
        let pool = TerminalConnectionPool(maximumShellsPerHost: 2, now: { date })
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let gate = ScriptedTransportCallGate()
        await probe.setEndGate(gate, for: "one")
        let first = try await pool.select(hostID: host, identity: identity("one"), ownerID: owner,
                                          generation: 1, runTerminal: runner(probe))
        first.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 1 })
        pool.release(hostID: host, identity: identity("one"), ownerID: owner)
        date = date.addingTimeInterval(1)
        let second = try await pool.select(hostID: host, identity: identity("two"), ownerID: owner,
                                           generation: 1, runTerminal: runner(probe))
        second.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 2 })
        pool.release(hostID: host, identity: identity("two"), ownerID: owner)
        let third = Task {
            try await pool.select(hostID: host, identity: identity("three"), ownerID: owner,
                                  generation: 1, runTerminal: runner(probe))
        }
        await gate.waitForEntry()
        #expect(pool.entries.count == 1)
        #expect(await probe.requests.count == 2)
        await gate.open()
        let next = try await third.value
        next.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 3 })
        #expect(await probe.ended == ["one"])
        #expect(pool.entries[.init(hostID: host, identity: identity("two"))] === second)
        await pool.suspend()
    }

    @Test func cancellingSelectionDuringEvictionDoesNotCreateAReplacement() async throws {
        let pool = TerminalConnectionPool(maximumShellsPerHost: 1)
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let gate = ScriptedTransportCallGate()
        await probe.setEndGate(gate, for: "one")
        let first = try await pool.select(hostID: host, identity: identity("one"), ownerID: owner,
                                          generation: 1, runTerminal: runner(probe))
        first.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 1 })
        pool.release(hostID: host, identity: identity("one"), ownerID: owner)
        let next = Task {
            try await pool.select(hostID: host, identity: identity("two"), ownerID: owner,
                                  generation: 1, runTerminal: runner(probe))
        }
        await gate.waitForEntry()
        next.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await next.value }
        #expect(pool.entries.isEmpty)
        #expect(await probe.ended == ["one"])
    }

    @Test func removingAHostOnlyEndsItsConnectionsAndGenerationDropsIdleEntries() async throws {
        let pool = TerminalConnectionPool()
        let probe = PoolSessionProbe()
        let host = UUID()
        let other = UUID()
        let owner = UUID()
        for hostID in [host, other] {
            _ = try await pool.select(hostID: hostID, identity: identity("one"), ownerID: owner,
                                      generation: 1, runTerminal: runner(probe))
        }
        await pool.removeHost(host)
        #expect(pool.entries.count == 1)
        pool.release(hostID: other, identity: identity("one"), ownerID: owner)
        await pool.transportGenerationDidChange(2, for: other)
        #expect(pool.entries.isEmpty)
    }

    @Test func staleSnapshotCannotEvictEntriesAfterWaitingForPriorTeardown() async throws {
        let pool = TerminalConnectionPool(maximumShellsPerHost: 1)
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let gate = ScriptedTransportCallGate()
        await probe.setEndGate(gate, for: "one")
        let first = try await pool.select(hostID: host, identity: identity("one"), ownerID: owner,
                                          generation: 1, runTerminal: runner(probe))
        first.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 1 })
        pool.release(hostID: host, identity: identity("one"), ownerID: owner)
        let second = Task {
            try await pool.select(hostID: host, identity: identity("two"), ownerID: owner,
                                  generation: 1, runTerminal: runner(probe))
        }
        await gate.waitForEntry()
        var snapshotCurrent = true
        let reconciliation = Task {
            await pool.reconcile(hostID: host, identities: [], isCurrent: { snapshotCurrent })
        }
        await Task.yield()
        snapshotCurrent = false
        await gate.open()
        let replacement = try await second.value
        await reconciliation.value
        #expect(pool.entries[.init(hostID: host, identity: identity("two"))] === replacement)
        await pool.suspend()
    }

    @Test func agentAdmissionSharesShellBudgetAndAwaitsShellEviction() async throws {
        let budget = TerminalRetentionBudget(maximumPerHost: 3)
        let pool = TerminalConnectionPool(maximumShellsPerHost: 3, budget: budget)
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let gate = ScriptedTransportCallGate()
        await probe.setEndGate(gate, for: "one")
        for id in ["one", "two", "three"] {
            let entry = try await pool.select(hostID: host, identity: identity(id), ownerID: owner,
                                              generation: 1, runTerminal: runner(probe))
            entry.store.viewDidResize(cols: 80, rows: 24)
            try #require(await eventually { await probe.requests.contains(where: { $0.target == .terminal(id) }) })
            pool.release(hostID: host, identity: identity(id), ownerID: owner)
        }
        #expect(pool.entries.count == 3)
        var agentAdmitted = false
        let agent = Task {
            try await budget.admit(key: .init(hostID: host, terminalID: "agent"), ownerID: UUID(),
                                   isVisible: { true }, onEvict: {})
            agentAdmitted = true
        }
        await gate.waitForEntry()
        #expect(!agentAdmitted)
        #expect(pool.entries.count == 2)
        await gate.open()
        try await agent.value
        #expect(await probe.ended == ["one"])
        #expect(pool.entries.count == 2)
        await pool.suspend()
    }

    @Test(arguments: [false, true])
    func changedRouteCanBeEvictedBeforeTheOldViewDisappears(withAgentSlot: Bool) async throws {
        let budget = TerminalRetentionBudget(maximumPerHost: 3)
        let pool = TerminalConnectionPool(maximumShellsPerHost: 3, budget: budget)
        let probe = PoolSessionProbe()
        let host = UUID()
        let owner = UUID()
        let presentation = PoolPresentationProbe()
        if withAgentSlot {
            try await budget.admit(key: .init(hostID: host, terminalID: "agent"), ownerID: UUID(),
                                   isVisible: { true }, onEvict: {})
        }
        let first = try await pool.select(
            hostID: host, identity: identity("one"), ownerID: owner, generation: 1,
            isPresented: { presentation.isPresented }, runTerminal: runner(probe))
        first.store.viewDidResize(cols: 80, rows: 24)
        try #require(await eventually { await probe.requests.count == 1 })
        for id in withAgentSlot ? ["two"] : ["two", "three"] {
            _ = try await pool.select(hostID: host, identity: identity(id), ownerID: owner,
                                      generation: 1, runTerminal: runner(probe))
        }
        // SwiftUI has selected the next destination, but has not delivered
        // the previous view's onDisappear/release callback yet.
        presentation.isPresented = false
        let next = try await pool.select(hostID: host, identity: identity("next"), ownerID: owner,
                                         generation: 1, runTerminal: runner(probe))
        #expect(pool.entries[.init(hostID: host, identity: identity("one"))] == nil)
        #expect(pool.entries[.init(hostID: host, identity: identity("next"))] === next)
        #expect(await probe.ended == ["one"])
        await pool.suspend()
    }

    private func identity(_ terminalID: String) -> ShellTerminalIdentity {
        ShellTerminalIdentity(paneID: "pane-\(terminalID)", tabID: "tab", terminalID: terminalID)
    }

    private func runner(_ probe: PoolSessionProbe) -> TerminalSessionRunner {
        { request, handler in
            let session = await probe.open(request)
            try await handler.runEndingSession(session)
        }
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private actor PoolSessionProbe {
    private(set) var requests: [TerminalAttachRequest] = []
    private(set) var ended: [String] = []
    private var endGates: [String: ScriptedTransportCallGate] = [:]

    func setEndGate(_ gate: ScriptedTransportCallGate, for terminalID: String) {
        endGates[terminalID] = gate
    }

    func open(_ request: TerminalAttachRequest) -> TerminalAttachSession {
        requests.append(request)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let gate = endGates[request.target.identifier]
        return TerminalAttachSession(output: { stream }, input: input) {
            await gate?.waitUntilOpen()
            input.finish()
            continuation.finish()
            await self.recordEnd(request.target.identifier)
        }
    }

    private func recordEnd(_ terminalID: String) {
        guard !ended.contains(terminalID) else { return }
        ended.append(terminalID)
    }
}

@MainActor
private final class PoolPresentationProbe {
    var isPresented = true
}
