import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Monitor store")
struct AgentMonitorStoreTests {
    @Test func openingFetchesOneVisibleANSISnapshot() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("plain \u{1B}[31mred\u{1B}[0m", target: "w1:p1")
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AgentMonitorStore(target: "w1:p1", now: { capturedAt }) { params in
            try await transport.readAgent(params)
        }

        await store.open()
        await store.open()

        #expect(store.state == .loaded)
        #expect(store.capturedAt == capturedAt)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "plain red")
        #expect(
            await transport.agentReadParams == [
                AgentReadParams(
                    source: .visible,
                    target: "w1:p1",
                    format: .ansi,
                    stripANSI: false)
            ])
    }

    @Test func returningFromAttachRefreshesExactlyOnce() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("before", target: "w1:p1")
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }
        await store.open()

        await transport.setAgentText("after", target: "w1:p1")
        store.attachDidOpen()
        await store.refreshOnReturn()
        await store.refreshOnReturn()

        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func returningWhileOpenIsLoadingStillPerformsTheRefresh() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("opening", target: "w1:p1")
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAgentRead(using: gate)
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        let opening = Task { await store.open() }
        try await waitUntil("the opening read should be in flight") {
            await gate.entryCount == 1
        }
        await transport.setAgentText("after Attach", target: "w1:p1")
        store.attachDidOpen()
        let returning = Task { await store.refreshOnReturn() }

        await gate.open()
        await opening.value
        await returning.value

        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after Attach")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func failedOpenSurfacesTheServerErrorAndRetryRecovers() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentReadFailure(
            HerdrAPIError(code: "agent_not_idle", message: "agent is working"))
        let store = AgentMonitorStore(target: "w1:p1") { params in
            try await transport.readAgent(params)
        }

        await store.open()

        #expect(store.state == .failed("herdr rejected the snapshot: agent is working"))
        #expect(store.snapshot == nil)

        await transport.setAgentReadFailure(nil)
        await transport.setAgentText("recovered", target: "w1:p1")
        await store.retry()

        #expect(store.state == .loaded)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "recovered")
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func failedReturnKeepsTheLastSnapshotAndItsFreshness() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("known screen", target: "w1:p1")
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let store = AgentMonitorStore(target: "w1:p1", now: { capturedAt }) { params in
            try await transport.readAgent(params)
        }
        await store.open()

        await transport.setAgentReadFailure(TransportError.timedOut)
        store.attachDidOpen()
        await store.refreshOnReturn()

        #expect(store.state == .failed("The Host did not answer in time."))
        #expect(store.capturedAt == capturedAt)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "known screen")
    }

    @Test func sendDeliversControlKeysAndRefreshesTheSnapshot() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("before", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentText("after ctrl+c", target: "w1:p1")
        await store.send(.interrupt)

        #expect(store.sendError == nil)
        #expect(store.isSendingKey == false)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "after ctrl+c")
        #expect(
            await transport.agentSendKeysParams == [
                AgentSendKeysParams(keys: ["ctrl+c"], target: "w1:p1")
            ])
        #expect(await transport.agentReadParams.count == 2)
    }

    @Test func sendFailureSurfacesWithoutRefreshing() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("known screen", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentSendKeysFailure(
            HerdrAPIError(code: "invalid_key", message: "unsupported key foo"))
        await store.send(.enter)

        #expect(store.sendError == "herdr rejected the key: unsupported key foo")
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "known screen")
        #expect(await transport.agentSendKeysParams.isEmpty)
        #expect(await transport.agentReadParams.count == 1)
    }

    @Test func successfulSendClearsAPriorSendError() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentText("screen", target: "w1:p1")
        let store = makeStore(transport: transport)
        await store.open()

        await transport.setAgentSendKeysFailure(TransportError.timedOut)
        await store.send(.escape)
        #expect(store.sendError == "The Host did not answer in time.")

        await transport.setAgentSendKeysFailure(nil)
        await transport.setAgentText("dismissed", target: "w1:p1")
        await store.send(.escape)

        #expect(store.sendError == nil)
        let snapshot = try #require(store.snapshot)
        #expect(String(snapshot.characters) == "dismissed")
        #expect(
            await transport.agentSendKeysParams == [
                AgentSendKeysParams(keys: ["esc"], target: "w1:p1")
            ])
    }

    @Test func controlKeySpellingsMatchHerdrContract() {
        // Load-bearing spellings verified live on herdr 0.8.0 (CLAUDE.md):
        // enter/esc/ctrl+c accepted; ctrl-c rejected with invalid_key.
        #expect(MonitorControlKey.enter.keys == ["enter"])
        #expect(MonitorControlKey.escape.keys == ["esc"])
        #expect(MonitorControlKey.interrupt.keys == ["ctrl+c"])
        #expect(MonitorControlKey.interrupt.keys != ["ctrl-c"])
        #expect(MonitorControlKey.up.keys == ["up"])
        #expect(MonitorControlKey.down.keys == ["down"])
        #expect(MonitorControlKey.left.keys == ["left"])
        #expect(MonitorControlKey.right.keys == ["right"])

        for key in MonitorControlKey.allCases {
            #expect(!key.keys.isEmpty)
            #expect(key.keys.allSatisfy { !$0.isEmpty })
            #expect(key.label != nil || key.systemImage != nil)
            // Negative contract: herdr rejects hyphenated `ctrl-…` spellings
            // with `invalid_key` (verified live on 0.8.0); only `ctrl+c` /
            // `C-c` are accepted. Pin the whole prefix so a future key
            // (⌃D, ⌃Z, …) cannot regress into the trap.
            for spelling in key.keys {
                #expect(
                    !spelling.lowercased().hasPrefix("ctrl-"),
                    "\(key.rawValue) must not use hyphenated ctrl- form \(spelling)")
            }
        }
    }

    private func makeStore(
        transport: ScriptedTransport,
        target: String = "w1:p1",
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> AgentMonitorStore {
        AgentMonitorStore(
            target: target,
            now: now,
            read: { params in try await transport.readAgent(params) },
            sendKeys: { params in try await transport.sendAgentKeys(params) })
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}
