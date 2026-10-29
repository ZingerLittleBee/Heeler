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

    @Test func aHostWithoutRecordedTokenUsageReportsNoDataForEachProgram() async throws {
        let (store, transport) = await readyStore()
        let report = try AgentUsageFixture.noDataReport()
        await transport.setAgentUsage(.success(report))
        await store.refresh()
        #expect(store.state == .available(report.hidingClaudeLimits()))
        #expect(report.programs?.map(\.program) == ["claude", "codex"])
        #expect(report.programs?.allSatisfy { $0.tokenUsage.state == "noData" && $0.tokenUsage.totals == nil } == true)
        #expect(!store.isLoading)
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
        #expect(report.scan?.unreadableFiles == 0)
        #expect(report.scan?.state == "complete")
        #expect(report.refreshing == false)
        // A report without the unreadable count still decodes.
        #expect(try AgentUsageFixture.tokenReport(refreshing: false).scan?.unreadableFiles == nil)
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

    @Test(arguments: ["Asia/Kolkata", "US/Pacific"])
    func theDeviceTimeZoneReachesTheTransportUnchanged(timeZone: String) async throws {
        let (store, transport) = await readyStore()
        let report = try AgentUsageFixture.report()
        await transport.setAgentUsage(.success(report))
        await store.refresh(timeZone: timeZone)
        #expect(store.state == .available(report))
        #expect(await transport.agentUsageTimeZones == [timeZone])
    }

    @Test func oneReadListsPluginsOnceAndRunsTheInstallationItResolved() async throws {
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/opt/heeler plugin", version: "0.7.0")))
        let report = try AgentUsageFixture.report()
        await transport.setAgentUsage(.success(report))
        let state = try await AgentUsageStore.read(over: transport, timeZone: "US/Pacific", claudeLimits: true)
        #expect(state == .available(report))
        #expect(await transport.heelerPluginReads == 1)
        #expect(await transport.agentUsageReads == 1)
        #expect(await transport.agentUsageTimeZones == ["US/Pacific"])
        #expect(await transport.agentUsageClaudeLimits == [true])
        #expect(await transport.agentUsagePluginRoots == ["/opt/heeler plugin"])
    }

    @Test func theProductionReadGatesThePluginBeforeAnyQuery() async throws {
        let cases: [(HeelerPluginInstallation?, AgentUsageStore.State)] = [
            (nil, .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")),
            (.init(pluginRoot: "/plugins/heeler", version: "0.6.2"),
             .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
            (.init(pluginRoot: "/plugins/heeler", version: "seven"),
             .requirement("Could not verify the plugin version. Usage needs plugin 0.7.0 or newer.")),
            (.init(pluginRoot: "/plugins/heeler", version: "0.7.0", isEnabled: false),
             .requirement("Enable the Heeler plugin on this Host to read Usage.")),
            (.init(version: "0.7.0"),
             .requirement("herdr did not report where the Heeler plugin is installed. Update herdr on this Host to read Usage.")),
        ]
        for (plugin, expected) in cases {
            let transport = ScriptedTransport()
            await transport.setHeelerPlugin(.success(plugin))
            await transport.setAgentUsage(.success(try AgentUsageFixture.report()))
            let state = try await AgentUsageStore.read(over: transport, timeZone: "UTC", claudeLimits: false)
            #expect(state == expected)
            #expect(await transport.heelerPluginReads == 1)
            #expect(await transport.agentUsageReads == 0)
        }
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

    @Test func aFailedRefreshKeepsTheShownReportAndRetriesWithABoundedBackoff() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        let link = TransportError.sshUnreachable(detail: "The Host is not connected.")
        var results: [Result<AgentUsageStore.State, any Error>] =
            [.success(.available(partial))] + Array(repeating: .failure(link), count: 7)
            + [.success(.available(complete))]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        let refresh = Task { await store.refresh() }
        for pauses in 1...8 {
            while await sleeper.durations.count < pauses { await Task.yield() }
            #expect(store.state == .available(partial))
            #expect(store.isLoading)
            if pauses > 1 {
                #expect(store.refreshFailure == "Could not read Usage. Check the Host connection and try again.")
                #expect(store.isRetryingRefresh)
            }
            await sleeper.fireAll()
        }
        await refresh.value
        #expect(await sleeper.durations == [3, 3, 6, 12, 24, 30, 30, 30].map { Duration.seconds($0) })
        #expect(results.isEmpty)
        #expect(store.state == .available(complete))
        #expect(store.refreshFailure == nil)
        #expect(!store.isLoading)
    }

    @Test func failuresTheHostRepeatsDoNotBlameTheConnection() throws {
        let decoding = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentUsageReport.self, from: Data("{}".utf8))
        }
        let cases: [(any Error, AgentUsageStore.State)] = [
            (TransportError.sshUnreachable(detail: "gone"), .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.timedOut, .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.channelFailed(detail: "closed"), .failed(AgentUsageStore.connectionFailureMessage)),
            (TransportError.hostFileTimedOut, .failed(AgentUsageStore.timeoutMessage)),
            (TransportError.malformedResponse("The Host did not finish its Usage response."),
             .failed(AgentUsageStore.pluginFailureMessage)),
            (TransportError.apiRejected(code: "plugin_error", message: "boom"),
             .failed(AgentUsageStore.pluginFailureMessage)),
            (AgentUsageError.invalidReport, .failed(AgentUsageStore.pluginFailureMessage)),
            (decoding, .failed(AgentUsageStore.pluginFailureMessage)),
            (AgentUsageError.unsupportedVersion, .updateRequired),
            (TransportError.hostFeatureUnavailable(feature: "Usage"), .unsupportedPlatform),
        ]
        for (error, expected) in cases {
            #expect(AgentUsageStore.state(for: error) == expected, "\(error)")
        }
        for message in [AgentUsageStore.pluginFailureMessage, AgentUsageStore.timeoutMessage] {
            #expect(!message.contains("connection"))
        }
    }

    @Test func aFirstReadThatFailsStillShowsTheFailure() async {
        let store = AgentUsageStore(hostID: UUID()) { _, _ in
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        await store.refresh()
        #expect(store.state == .failed("Could not read Usage. Check the Host connection and try again."))
        #expect(store.refreshFailure == nil)
        #expect(!store.isLoading)
    }

    @Test func aFailedRefreshOfACompleteReportWaitsForThePull() async throws {
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [Result<AgentUsageStore.State, any Error>] = [
            .success(.available(complete)), .failure(TransportError.timedOut), .success(.available(complete)),
        ]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        await store.refresh()
        await store.pullToRefresh()
        #expect(store.state == .available(complete))
        #expect(store.refreshFailure != nil)
        #expect(!store.isRetryingRefresh)
        #expect(!store.isLoading)
        #expect(await sleeper.durations.isEmpty)
        await store.pullToRefresh()
        #expect(store.refreshFailure == nil)
        #expect(results.isEmpty)
    }

    @Test func aFailedOptInReadShowsClaudeLimitsAsFailedNotReading() async throws {
        let report = try AgentUsageFixture.report(refreshing: false)
        var results: [Result<AgentUsageStore.State, any Error>] = [
            .success(.available(report)), .failure(TransportError.timedOut),
        ]
        let name = "claude-opt-in-failure-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, _ in
            try results.removeFirst().get()
        }
        await store.refresh()
        store.claudeLimitsEnabled = true
        guard case .available(let reading) = store.state else { Issue.record("Missing snapshot"); return }
        #expect(reading.programs?.first { $0.program == "claude" }?.usageLimits.reason == "notReadYet")
        await store.pullToRefresh()
        #expect(store.refreshFailure != nil)
        guard case .available(let failed) = store.state else { Issue.record("Missing snapshot"); return }
        let limits = failed.programs?.first { $0.program == "claude" }?.usageLimits
        #expect(limits?.state == "error")
        #expect(limits?.reason == "requestFailed")
    }

    @Test func aUsableConnectionEndsTheRetryBackoffAtOnce() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [Result<AgentUsageStore.State, any Error>] = [
            .success(.available(partial)), .failure(TransportError.timedOut), .failure(TransportError.timedOut),
            .success(.available(complete)),
        ]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            try results.removeFirst().get()
        }
        let generation = store.refreshGeneration
        store.connectionBecameUsable()
        #expect(store.refreshGeneration == generation, "Nothing failed, so nothing resumes.")
        let refresh = Task { await store.refresh() }
        for pauses in 1...3 {
            while await sleeper.durations.count < pauses { await Task.yield() }
            if pauses < 3 { await sleeper.fireAll() }
        }
        #expect(store.refreshFailure != nil)
        store.connectionBecameUsable()
        await refresh.value
        #expect(store.state == .available(complete))
        #expect(await sleeper.durations.count == 3)
        #expect(results.isEmpty)
    }

    @Test func aUsableConnectionRestartsTheSurfacesAfterAFailedFirstRead() async {
        let store = AgentUsageStore(hostID: UUID()) { _, _ in throw TransportError.timedOut }
        await store.refresh()
        let key = store.refreshKey
        store.connectionBecameUsable()
        #expect(store.refreshKey != key)
    }

    @Test func pullToRefreshEndsAfterOneReadAndHandsPollingToTheSurfaces() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        var reads = 0
        let store = AgentUsageStore(hostID: UUID()) { _, _ in
            reads += 1
            return .available(partial)
        }
        let key = store.refreshKey
        await store.pullToRefresh()
        #expect(reads == 1)
        #expect(store.state == .available(partial))
        #expect(!store.isLoading)
        #expect(store.refreshKey != key, "A refreshing answer restarts the visible surfaces' polling.")
    }

    @Test func pullToRefreshDuringPollingReadsOnceAndLeavesPollingRunning() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        let complete = try AgentUsageFixture.report(refreshing: false)
        var results: [AgentUsageStore.State] = [.available(partial), .available(partial), .available(complete)]
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            results.removeFirst()
        }
        let refresh = Task { await store.refresh() }
        while await sleeper.durations.count < 1 { await Task.yield() }
        let key = store.refreshKey
        await store.pullToRefresh()
        #expect(results.count == 1)
        #expect(store.isLoading)
        #expect(store.refreshKey == key)
        while await sleeper.durations.count < 2 { await Task.yield() }
        await sleeper.fireAll()
        await refresh.value
        #expect(results.isEmpty)
        #expect(store.state == .available(complete))
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


@MainActor
@Suite("Claude Code Accounts report")
struct ClaudeAccountsReportTests {
    private func vector(_ change: (inout [String: Any]) throws -> Void) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        try change(&programs[0])
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }

    @Test func theSharedVectorCarriesEveryAccountInOrder() throws {
        let report = try AgentUsageReport.decode(AgentUsageFixture.data())
        let claude = try #require(report.claudeProgram)
        let accounts = try #require(claude.accounts)
        #expect(accounts.map(\.id) == ["default", "7f3c9a2e", "c41d07b9"])
        #expect(accounts.map(\.displayName) == ["Default", "claude-2", "work"])
        #expect(accounts.map(\.isDefault) == [true, false, false])
        #expect(accounts.map(\.state) == [.ok, .ok, .missing])
        #expect(accounts[0].name == nil)
        #expect(accounts[0].directory == "/Users/u/.claude")
        #expect(accounts[0].tokenUsage == claude.tokenUsage)
        #expect(accounts[0].usageLimits == claude.usageLimits)
        #expect(accounts[1].tokenUsage?.state == "noData")
        #expect(accounts[1].usageLimits?.windows?.first?.id == "fiveHour")
        #expect(!accounts[2].isReadable)
        #expect(accounts[2].tokenUsage == nil)
        #expect(accounts[2].usageLimits == nil)
        #expect(claude.accountSuggestions == [
            .init(directory: "/Users/u/.claude-work", name: "claude-work", source: .agent),
            .init(directory: "/Users/u/.claude-personal", name: "claude-personal", source: .home),
        ])
        let codex = try #require(report.programs?.last)
        #expect(codex.accounts == nil)
        #expect(codex.accountSuggestions == nil)
    }

    @Test func aReportFromAPluginBeforeAccountsStillDecodes() throws {
        let report = try AgentUsageFixture.tokenReport(refreshing: false)
        #expect(report.claudeProgram?.accounts == nil)
        #expect(report.claudeProgram?.accountSuggestions == nil)
        #expect(report.hidingClaudeLimits().claudeProgram?.accounts == nil)
    }

    /// A newer plugin's states, sources and fields must not cost the report.
    @Test func unknownStatesSourcesAndFieldsDecode() throws {
        let report = try vector { claude in
            var accounts = try #require(claude["accounts"] as? [[String: Any]])
            accounts[2]["state"] = "archived"
            accounts[2]["futureField"] = ["anything": true]
            claude["accounts"] = accounts
            var suggestions = try #require(claude["accountSuggestions"] as? [[String: Any]])
            suggestions[0]["source"] = "cloud"
            suggestions[1]["seenAt"] = "2026-10-29T00:00:00Z"
            claude["accountSuggestions"] = suggestions
        }
        let claude = try #require(report.claudeProgram)
        #expect(claude.accounts?[2].state == .other("archived"))
        #expect(claude.accounts?[2].isReadable == false)
        #expect(claude.accountSuggestions?.map(\.source) == [.other("cloud"), .home])
    }

    @Test func everyAccountsLimitsFollowTheToggle() throws {
        let report = try ClaudeUsageFixture.report()
        let cases: [(AgentUsageReport, String, String?)] = [
            (report.hidingClaudeLimits(), "disabled", nil),
            (report.readingClaudeLimits(), "unavailable", "notReadYet"),
            (report.failedClaudeLimits(), "error", "requestFailed"),
        ]
        for (replaced, state, reason) in cases {
            let accounts = try #require(replaced.claudeProgram?.accounts)
            for account in accounts.prefix(2) {
                #expect(account.usageLimits?.state == state)
                #expect(account.usageLimits?.reason == reason)
                #expect(account.usageLimits?.windows == nil)
                #expect(account.tokenUsage == report.claudeProgram?.accounts?.first { $0.id == account.id }?.tokenUsage)
            }
            // A missing Account has no limits to replace.
            #expect(accounts[2].usageLimits == nil)
        }
    }

    @Test func aDeviceThatOptedOutSeesNoAccountsLimits() async throws {
        let name = "claude-accounts-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let report = try ClaudeUsageFixture.report()
        let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, _ in .available(report) }
        await store.refresh()
        guard case .available(let shown) = store.state else { Issue.record("Missing report"); return }
        #expect(shown.claudeProgram?.accounts?.compactMap(\.usageLimits?.state) == ["disabled", "disabled"])
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

    /// As a query without `--claude-limits` answers: every Claude Code
    /// Account's limits are off too.
    static func report(refreshing: Bool) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["refreshing"] = refreshing
        var programs = try #require(object["programs"] as? [[String: Any]])
        programs[0]["usageLimits"] = ["state": "disabled"]
        if var accounts = programs[0]["accounts"] as? [[String: Any]] {
            for index in accounts.indices where accounts[index]["usageLimits"] != nil {
                accounts[index]["usageLimits"] = ["state": "disabled"]
            }
            programs[0]["accounts"] = accounts
        }
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

    @Test func removingAHostForgetsItsClaudeLimitsConsent() throws {
        let name = "claude-consent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let removed = Host(name: "Removed", address: "removed.invalid", username: "u")
        let kept = Host(name: "Kept", address: "kept.invalid", username: "u")
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        try catalog.add(removed)
        try catalog.add(kept)
        for host in [removed, kept] {
            AgentUsageStore(hostID: host.id, defaults: defaults) { _, _ in .idle }.claudeLimitsEnabled = true
        }
        try catalog.remove(removed.id)
        #expect(defaults.object(forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: removed.id)) == nil)
        #expect(defaults.bool(forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: kept.id)))
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

#if DEBUG && targetEnvironment(simulator)
    @MainActor
    @Suite("Demo Usage", .serialized)
    struct DemoUsageTests {
        @Test func demoHostsShowSampleUsageInsteadOfAPlatformNote() async throws {
            let host = try #require(DemoScreenshotFixture.hosts.first)
            let transport = try DemoScreenshotFixture.transport(for: host)
            for claudeLimits in [false, true] {
                let state = try await AgentUsageStore.read(
                    over: transport, timeZone: "Asia/Kolkata", claudeLimits: claudeLimits)
                guard case .available(let report) = state else {
                    Issue.record("Demo Usage must be sample data, not \(state)")
                    return
                }
                #expect(report.programs?.map(\.program) == ["claude", "codex"])
                #expect(report.timeZone == "Asia/Kolkata")
                #expect(report.programs?.first?.usageLimits.state == (claudeLimits ? "ok" : "disabled"))
                #expect(report.programs?.last?.usageLimits.windows?.allSatisfy { !$0.expired } == true)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
                let today = calendar.dateComponents([.year, .month, .day], from: Date())
                let todayText = String(
                    format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
                for program in report.programs ?? [] {
                    let usage = program.tokenUsage
                    let daily = try #require(usage.daily)
                    #expect(usage.state == "ok")
                    #expect(daily.count == 30)
                    #expect(daily.last?.date == todayText)
                    #expect(usage.totals?.today.tokens.total == daily.last?.tokens.total)
                    #expect(usage.totals?.last7Days.tokens.total
                        == daily.suffix(7).reduce(0) { $0 + $1.tokens.total })
                    #expect(usage.totals?.last30Days.tokens.total
                        == daily.reduce(0) { $0 + $1.tokens.total })
                }
            }
        }

        /// The studio Host shows several Accounts and suggestions; the build
        /// Host keeps one Account, as a Host that never added any.
        @Test func theStudioHostHasAccountsAndTheBuildHostOne() async throws {
            let studio = try #require(DemoScreenshotFixture.hosts.first { $0.id == DemoScreenshotFixture.studioHostID })
            let state = try await AgentUsageStore.read(
                over: try DemoScreenshotFixture.transport(for: studio), timeZone: "UTC", claudeLimits: true)
            guard case .available(let report) = state else { Issue.record("No studio report"); return }
            let claude = try #require(report.claudeProgram)
            let accounts = try #require(claude.accounts)
            #expect(accounts.map(\.displayName) == ["Default", "claude-2", "work"])
            #expect(accounts.map(\.state) == [.ok, .ok, .missing])
            #expect(accounts.map(\.directory) == ["/Users/developer/.claude", "/Users/developer/.claude-2", "/Volumes/T7/.claude"])
            #expect(accounts[1].usageLimits?.windows?.first { $0.id == "fiveHour" }?.usedPercent == 84)
            #expect(claude.accountSuggestions?.map(\.name) == ["claude-team", "claude-work"])
            #expect(claude.accountSuggestions?.map(\.source) == [.agent, .home])
            // The program's figures add up its readable Accounts.
            let readable = accounts.compactMap { $0.tokenUsage?.totals?.last30Days.tokens.total }
            #expect(claude.tokenUsage.totals?.last30Days.tokens.total == readable.reduce(0, +))

            let build = try #require(DemoScreenshotFixture.hosts.first { $0.id == DemoScreenshotFixture.buildHostID })
            let buildState = try await AgentUsageStore.read(
                over: try DemoScreenshotFixture.transport(for: build), timeZone: "UTC", claudeLimits: false)
            guard case .available(let buildReport) = buildState else { Issue.record("No build report"); return }
            #expect(buildReport.claudeProgram?.accounts?.map(\.displayName) == ["Default"])
            #expect(buildReport.claudeProgram?.accountSuggestions == [])
        }

        /// The demo keeps the studio Host's Account file in memory, so the
        /// Accounts sheet's changes show up in its next read.
        @Test func theStudioHostsAccountFileCanBeEdited() async throws {
            let studio = try #require(DemoScreenshotFixture.hosts.first { $0.id == DemoScreenshotFixture.studioHostID })
            let transport = try DemoScreenshotFixture.transport(for: studio)
            let store = AgentUsageStore(
                hostID: studio.id, transports: ScriptedTransportProvider(transports: [studio.id: transport]))
            await store.refresh()
            #expect(store.supportsClaudeAccounts)
            guard case .available(let report) = store.state,
                let team = report.claudeProgram?.accountSuggestions?.first(where: { $0.name == "claude-team" })
            else { Issue.record("No suggestion to add"); return }
            #expect(await store.addAccount(team))
            guard case .available(let added) = store.state else { Issue.record("No report"); return }
            #expect(added.claudeProgram?.accounts?.map(\.displayName) == ["Default", "claude-2", "work", "claude-team"])
            #expect(added.claudeProgram?.accounts?.last?.state == .ok)
            #expect(added.claudeProgram?.accountSuggestions?.map(\.name) == ["claude-work"])
            // A directory the demo Host does not hold is refused.
            #expect(await store.addAccount(directory: "/Users/developer/Downloads") == .refused(.notClaudeDirectory))
            let teamAccount = try #require(added.claudeProgram?.accounts?.last)
            #expect(await store.removeAccount(teamAccount))
            guard case .available(let restored) = store.state else { Issue.record("No report"); return }
            #expect(restored.claudeProgram?.accounts?.map(\.displayName) == ["Default", "claude-2", "work"])
            // Removed, it is not offered again at once.
            #expect(restored.claudeProgram?.accountSuggestions?.map(\.name) == ["claude-work"])
            #expect(store.accountChangeFailure == nil)
        }

        /// The demo's other Claude Code directories are the studio Host's:
        /// the build Host's browser neither lists nor accepts them, rather
        /// than add one it then reports as not found.
        @Test func onlyTheStudioHostHoldsTheDemoAccountDirectories() async throws {
            let build = try #require(DemoScreenshotFixture.hosts.first { $0.id == DemoScreenshotFixture.buildHostID })
            let transport = try DemoScreenshotFixture.transport(for: build)
            let store = AgentUsageStore(
                hostID: build.id, transports: ScriptedTransportProvider(transports: [build.id: transport]))
            await store.refresh()
            #expect(store.supportsClaudeAccounts)
            let directory = "\(DemoChatSample.home)/.claude-2"
            #expect(await store.addAccount(directory: directory) == .refused(.notClaudeDirectory))
            let home = try await transport.listFiles(RemoteFileListingRequest(directory: DemoChatSample.home))
            #expect(home?.entries.contains { $0.name == ".claude-2" } != true)

            let studio = try #require(DemoScreenshotFixture.hosts.first { $0.id == DemoScreenshotFixture.studioHostID })
            let studioTransport = try DemoScreenshotFixture.transport(for: studio)
            #expect(try await studioTransport.fileStatus(atPath: directory + "/.claude.json")?.kind == .regular)
            let studioHome = try await studioTransport.listFiles(RemoteFileListingRequest(directory: DemoChatSample.home))
            #expect(studioHome?.entries.contains { $0.name == ".claude-2" } == true)
        }
    }
#endif
