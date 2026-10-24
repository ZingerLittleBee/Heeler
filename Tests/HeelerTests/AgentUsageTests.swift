import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage store", .timeLimit(.minutes(1)))
struct AgentUsageStoreTests {
    @Test func theSharedVectorCarriesVersionedEstimatedAPICost() throws {
        let object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        #expect(object["pricingVersion"] is String)
        let programs = try #require(object["programs"] as? [[String: Any]])
        for program in programs {
            let usage = try #require(program["tokenUsage"] as? [String: Any])
            let totals = try #require(usage["totals"] as? [String: Any])
            let today = try #require(totals["today"] as? [String: Any])
            #expect(today["estimatedCostUSD"] != nil)
            #expect(today["unpricedTokens"] is Int)
        }
        let report = try AgentUsageFixture.report()
        #expect(report.pricingVersion == "2026-10-23")
        for program in report.programs ?? [] {
            #expect(program.tokenUsage.totals?.today.estimatedCostUSD != nil)
            #expect(program.tokenUsage.totals?.today.unpricedTokens == 0)
            #expect(program.tokenUsage.daily?.last?.estimatedCostUSD != nil)
        }
        let claudeCost = try #require(report.programs?.first { $0.program == "claude" }?
            .tokenUsage.totals?.today.estimatedCostUSD)
        let codexCost = try #require(report.programs?.first { $0.program == "codex" }?
            .tokenUsage.totals?.today.estimatedCostUSD)
        #expect(abs(claudeCost - 0.92225) < 0.000000001)
        #expect(abs(codexCost - 0.000742) < 0.000000001)
    }

    @Test func nullEstimatedCostDoesNotBecomeZeroAndUnpricedTokensRemainVisible() throws {
        let report = try AgentUsageFixture.costReport(cost: nil, unpriced: 882_000)
        let today = try #require(report.programs?.first?.tokenUsage.totals?.today)
        #expect(today.estimatedCostUSD == nil)
        #expect(today.unpricedTokens == 882_000)
        let mixed = try AgentUsageFixture.costReport(cost: 1.92, unpriced: 250)
        #expect(mixed.programs?.first?.tokenUsage.totals?.last30Days.estimatedCostUSD == 1.92)
        #expect(mixed.programs?.first?.tokenUsage.totals?.last30Days.unpricedTokens == 250)
        #expect(mixed.programs?.first?.tokenUsage.daily?.last?.estimatedCostUSD == 1.92)
    }

    @Test func anOldPluginShowsItsRequirementWithoutAUsageRead() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(version: "0.6.2")))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .requirement(
            "Usage needs plugin 0.7.0 or newer; this Host has 0.6.2."))
        #expect(await transport.agentUsageReads == 0)
    }
    @Test func windowsIsExplainedWithoutStartingAQuery() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.failure(TransportError.hostFeatureUnavailable(feature: "Usage")))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .unsupportedPlatform)
        #expect(await transport.agentUsageReads == 0)
    }

    @Test func aMissingRuntimeAsksForAgentActivity() async throws {
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(try AgentUsageReport.decode(
            Data(#"{"version":1,"runtime":"missing"}"#.utf8))))
        await store.refresh()
        #expect(store.state == .runtimeMissing)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func theSharedNodeVectorIncludesBothProgramsTokenUsage() async throws {
        let report = try AgentUsageFixture.report()
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.success(report))
        await store.refresh(timeZone: "Asia/Shanghai")
        #expect(store.state == .available(report))
        #expect(report.programs?.map(\.program) == ["claude", "codex"])
        #expect(report.programs?.map { $0.tokenUsage.state } == ["ok", "ok"])
        #expect(report.programs?.first?.tokenUsage.totals?.today.tokens.total == 882_000)
        #expect(report.programs?.first?.tokenUsage.daily?.count == 30)
        let codex = try #require(report.programs?.first { $0.program == "codex" }?.tokenUsage)
        let today = try #require(codex.totals?.today.tokens)
        #expect(today.input == 120)
        #expect(today.cacheRead == 40)
        #expect(today.cacheWrite == 60)
        #expect(today.output == 30)
        #expect(today.reasoning == 10)
        #expect(today.total == 250)
        #expect(codex.totals?.last7Days.tokens.total == 250)
        #expect(codex.totals?.last30Days.tokens.total == 250)
        #expect(codex.daily?.count == 30)
        #expect(codex.daily?.last?.tokens.total == 250)
        #expect(report.scan?.skippedArchives == 0)
        #expect(report.scan?.state == "complete")
        #expect(report.refreshing == false)
    }

    @Test func unknownFieldsAreIgnoredButAnUnknownMajorRequiresAnUpdate() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        object["futureField"] = ["anything": true]
        #expect(try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
            == AgentUsageReport.decode(AgentUsageFixture.data()))
        object["version"] = 2
        object["programs"] = "a different future shape"
        #expect(throws: AgentUsageError.unsupportedVersion) {
            try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        }
        let (store, transport) = await readyStore()
        await transport.setAgentUsage(.failure(AgentUsageError.unsupportedVersion))
        await store.refresh()
        #expect(store.state == .updateRequired)
    }

    @Test func aDisabledPluginDoesNotRunUsage() async {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(version: "0.7.0", isEnabled: false)))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        #expect(store.state == .requirement("Enable the Heeler plugin on this Host to read Usage."))
        #expect(await transport.agentUsageReads == 0)
    }

    @Test func anInvalidatedPendingReadCannotRestoreOldHostData() async {
        let (store, transport) = await readyStore()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextHeelerPluginRead(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()
        store.invalidate()
        await gate.open()
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
    }

    @Test func tokenTotalsAndDailyBucketsDecodeWithoutCountingReasoningTwice() throws {
        let report = try AgentUsageFixture.tokenReport(refreshing: false)
        let usage = try #require(report.programs?.first?.tokenUsage)
        #expect(usage.totals?.today.tokens.input == 1_200)
        #expect(usage.totals?.today.tokens.cacheRead == 830_000)
        #expect(usage.totals?.today.tokens.cacheWrite == 41_000)
        #expect(usage.totals?.today.tokens.output == 9_800)
        #expect(usage.totals?.today.tokens.total == 882_000)
        #expect(usage.totals?.last30Days.tokens.total == 1_764_000)
        #expect(usage.daily?.first?.date == "2026-10-23")
        #expect(usage.daily?.first?.tokens.total == 882_000)
    }

    @Test func refreshingReportsAreQueriedAgainAfterThreeSecondsAndThenStop() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        await transport.setAgentUsage(.success(partial))
        let started = ContinuousClock.now
        let refresh = Task { await store.refresh(timeZone: "Asia/Kathmandu") }
        while await transport.agentUsageReads == 0 { await Task.yield() }
        await transport.setAgentUsage(.success(complete))
        await refresh.value
        #expect(started.duration(to: .now) >= .seconds(3))
        #expect(await transport.agentUsageReads == 2)
        #expect(store.state == .available(complete))
        #expect(!store.isLoading)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.agentUsageReads == 2)
    }

    @Test func cancellingAVisibleRefreshStopsPollingWithoutDiscardingItsLastSnapshot() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.tokenReport(refreshing: true)
        await transport.setAgentUsage(.success(partial))
        let refresh = Task { await store.refresh() }
        while store.state != .available(partial) { await Task.yield() }
        refresh.cancel()
        await refresh.value
        #expect(store.state == .available(partial))
        #expect(!store.isLoading)
        try await Task.sleep(for: .milliseconds(3_100))
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func invalidatingAHostDuringThePollingDelayPreventsAnotherRead() async throws {
        let (store, transport) = await readyStore()
        let partial = try AgentUsageFixture.tokenReport(refreshing: true)
        await transport.setAgentUsage(.success(partial))
        let refresh = Task { await store.refresh() }
        while store.state != .available(partial) { await Task.yield() }
        store.invalidate()
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
        #expect(await transport.agentUsageReads == 1)
    }

    @Test func anAlreadyCancelledRefreshDoesNotLeaveTheHostLoading() async {
        let (store, transport) = await readyStore()
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.refresh()
        }
        await refresh.value
        #expect(store.state == .idle)
        #expect(!store.isLoading)
        #expect(await transport.agentUsageReads == 0)
    }

    private func readyStore() async -> (AgentUsageStore, ScriptedTransport) {
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        return (AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport])), transport)
    }

}


enum AgentUsageFixture {
    private final class BundleLocator {}

    static func data() throws -> Data {
        let url = try #require(Bundle(for: BundleLocator.self)
            .url(forResource: "usage-v1", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func noDataReport() throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        for index in programs.indices { programs[index]["tokenUsage"] = ["state": "noData"] }
        object["programs"] = programs
        object["refreshing"] = false
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func costReport(cost: Double?, unpriced: Int64) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        var program = try #require((object["programs"] as? [[String: Any]])?.first)
        var usage = try #require(program["tokenUsage"] as? [String: Any])
        var totals = try #require(usage["totals"] as? [String: Any])
        for name in ["today", "last7Days", "last30Days"] {
            var summary = try #require(totals[name] as? [String: Any])
            summary["estimatedCostUSD"] = cost.map { $0 as Any } ?? NSNull()
            summary["unpricedTokens"] = unpriced
            totals[name] = summary
        }
        var daily = try #require(usage["daily"] as? [[String: Any]])
        for index in daily.indices {
            daily[index]["estimatedCostUSD"] = cost.map { $0 as Any } ?? NSNull()
            daily[index]["unpricedTokens"] = unpriced
        }
        usage["totals"] = totals
        usage["daily"] = daily
        program["tokenUsage"] = usage
        object["programs"] = [program]
        object["pricingVersion"] = "2026-10-24"
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func tokenReport(refreshing: Bool) throws -> AgentUsageReport {
        let json = """
        {"version":1,"runtime":"recorded","generatedAt":"2026-10-23T12:34:56Z",
         "timeZone":"Asia/Shanghai","refreshing":\(refreshing),
         "scan":{"state":"\(refreshing ? "partial" : "complete")","coveredFrom":"2026-10-23",
           "coveredThrough":"2026-10-23T12:34:00Z","skippedArchives":0},
         "programs":[{"program":"claude","usageLimits":{"state":"disabled"},
           "tokenUsage":{"state":"ok","totals":{
             "today":{"tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}},
             "last7Days":{"tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}},
             "last30Days":{"tokens":{"input":2400,"cacheRead":1660000,"cacheWrite":82000,"output":19600,"reasoning":0,"total":1764000}}},
             "daily":[{"date":"2026-10-23","tokens":{"input":1200,"cacheRead":830000,"cacheWrite":41000,"output":9800,"reasoning":0,"total":882000}}]}},
           {"program":"codex","tokenUsage":{"state":"noData"},"usageLimits":{"state":"unavailable","reason":"programMissing"}}]}
        """
        return try AgentUsageReport.decode(Data(json.utf8))
    }

    static func report(refreshing: Bool) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["refreshing"] = refreshing
        var programs = try #require(object["programs"] as? [[String: Any]])
        programs[0]["usageLimits"] = ["state": "disabled"]
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    static func report() throws -> AgentUsageReport {
        try report(refreshing: false)
    }
}


@MainActor
@Suite("Claude usage preference", .timeLimit(.minutes(1)))
struct ClaudeUsagePreferenceTests {
    @Test func disablingImmediatelyHidesCachedLimitsAndRejectsAnInFlightOptedInResponse() async throws {
        let name = "claude-cancel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let hostID = UUID()
        let transport = ScriptedTransport()
        let report = try ClaudeUsageFixture.report()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(report))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]), defaults: defaults)
        store.claudeLimitsEnabled = true
        await store.refresh()
        let gate = ScriptedTransportCallGate()
        await transport.setAgentUsage(.success(try AgentUsageFixture.costReport(cost: 9.99, unpriced: 0)))
        await transport.gateNextAgentUsageRead(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()
        store.claudeLimitsEnabled = false
        guard case .available(let hidden) = store.state else {
            await gate.open()
            await refresh.value
            Issue.record("Turning off Claude limits must retain Token Usage.")
            return
        }
        #expect(hidden.programs?.first?.usageLimits.state == "disabled")
        #expect(hidden.programs?.first?.tokenUsage == report.programs?.first?.tokenUsage)
        #expect(hidden.programs?.last == report.programs?.last)
        #expect(!store.isLoading)
        await gate.open()
        await refresh.value
        #expect(store.state == .available(hidden))
        #expect(await transport.agentUsageClaudeLimits == [true, true])
        await store.refresh()
        #expect(await transport.agentUsageClaudeLimits == [true, true, false])
        guard case .available(let afterRefresh) = store.state else { Issue.record("Missing snapshot"); return }
        #expect(afterRefresh.programs?.first?.usageLimits.state == "disabled")
    }

    @Test func thePerHostTogglePersistsOnThisDeviceAndReachesTransport() async throws {
        let name = "claude-usage-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let hostID = UUID()
        let otherID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try ClaudeUsageFixture.report()))
        let provider = ScriptedTransportProvider(transports: [hostID: transport, otherID: transport])
        let store = AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults)
        #expect(!store.claudeLimitsEnabled)
        await store.refresh()
        store.claudeLimitsEnabled = true
        await store.refresh()
        let reopened = AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults)
        #expect(reopened.claudeLimitsEnabled)
        await reopened.refresh()
        let other = AgentUsageStore(hostID: otherID, transports: provider, defaults: defaults)
        #expect(!other.claudeLimitsEnabled)
        await other.refresh()
        #expect(await transport.agentUsageClaudeLimits == [false, true, true, false])
        reopened.claudeLimitsEnabled = false
        #expect(!AgentUsageStore(hostID: hostID, transports: provider, defaults: defaults).claudeLimitsEnabled)
    }
}
