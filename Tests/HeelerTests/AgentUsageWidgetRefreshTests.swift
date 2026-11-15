import Foundation
import Synchronization
import Testing

@testable import Heeler

/// What keeps the Usage widgets current without anyone opening Usage: the
/// foreground re-read of stale Hosts and the background app refresh.
@MainActor
@Suite("Usage widget refresh", .timeLimit(.minutes(1)))
struct AgentUsageWidgetRefreshTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    @Test func aReadingMadeWhileTheAppWasAwayOutranksTheOneItStillHolds() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        let newer = try AgentUsageFixture.report(refreshing: false)
        let older = try AgentUsageFixture.tokenReport(refreshing: false)

        publisher.publish([Self.reading(host, .available(newer), readAt: Self.now)], now: Self.now)
        publisher.publish(
            [Self.reading(host, .available(older), readAt: Self.now.addingTimeInterval(-3600))], now: Self.now)
        #expect(Self.snapshot(directory)?.host(host.id) == UsageWidgetSnapshot.Host(
            id: host.id, name: host.displayName, report: newer, readAt: Self.now))

        let later = Self.now.addingTimeInterval(60)
        publisher.publish([Self.reading(host, .available(older), readAt: later)], now: later)
        #expect(Self.snapshot(directory)?.host(host.id)?.readAt == later)
    }

    @Test func readingSomeHostsKeepsWhatTheSnapshotHoldsForTheRest() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let studio = Self.host("Studio Mac")
        let build = Self.host("Build Box")
        let added = Self.host("New Host")
        publisher.publish([
            Self.reading(studio, .available(try AgentUsageFixture.tokenReport(refreshing: false)), readAt: Self.now),
            Self.reading(build, .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.")),
        ], now: Self.now)
        let before = try #require(Self.snapshot(directory))

        let later = Self.now.addingTimeInterval(1800)
        let report = try AgentUsageFixture.report(refreshing: false)
        publisher.publish(
            [Self.reading(studio, .available(report), readAt: later)], updating: [studio, build, added], now: later)

        let after = try #require(Self.snapshot(directory))
        #expect(after.hosts.map(\.id) == [studio.id, build.id, added.id])
        #expect(after.host(studio.id) == UsageWidgetSnapshot.Host(
            id: studio.id, name: studio.displayName, report: report, readAt: later))
        #expect(after.host(build.id) == before.host(build.id))
        #expect(after.host(added.id)?.excludedReason == .notReadYet)
    }

    @Test func claudeCodeAccountsReachTheWidgetsAsEntriesOfTheirOwn() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")

        publisher.publish(
            [Self.reading(host, .available(try ClaudeAccountsUsageFixture.report()), readAt: Self.now)], now: Self.now)
        #expect(Self.snapshot(directory)?.host(host.id)?.limits.map(\.title) == [
            "Claude Code · Default", "Claude Code · claude-2", "Claude Code · work", "Codex",
        ])

        // Down to the Default Account, Claude Code is one entry again.
        let later = Self.now.addingTimeInterval(60)
        let lone = try ClaudeAccountsUsageFixture.report(ClaudeAccountsUsageFixture.lone)
        publisher.publish([Self.reading(host, .available(lone), readAt: later)], now: later)
        #expect(Self.snapshot(directory)?.host(host.id)?.limits.map(\.id) == ["claude", "codex"])
    }

    @Test func aHostIsStaleOnceBothTheAppAndTheSnapshotReadingsAgePastTheInterval() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        #expect(publisher.isStale(host.id, readAt: nil, now: Self.now))

        publisher.publish(
            [Self.reading(host, .available(try AgentUsageFixture.report(refreshing: false)), readAt: Self.now)],
            now: Self.now)
        let interval = AgentUsageWidgetPublisher.staleInterval
        #expect(!publisher.isStale(host.id, readAt: nil, now: Self.now.addingTimeInterval(interval - 1)))
        #expect(publisher.isStale(host.id, readAt: nil, now: Self.now.addingTimeInterval(interval)))
        #expect(!publisher.isStale(
            host.id, readAt: Self.now.addingTimeInterval(60), now: Self.now.addingTimeInterval(interval)))
    }

    @Test func aRefreshingReadingIsAsOldAsTheScanItServes() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        let cached = try AgentUsageFixture.tokenReport(refreshing: true)
        let scannedAt = try #require(AgentUsageLimitsView.date(cached.scan?.coveredThrough))

        publisher.publish([Self.reading(host, .available(cached), readAt: Self.now)], now: Self.now)
        #expect(Self.snapshot(directory)?.host(host.id)?.readAt == scannedAt)
        #expect(publisher.isStale(host.id, readAt: nil, now: Self.now))
    }

    @Test func aRefreshingReadingIsAsOldAsTheLimitsItStillServes() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        // The worker commits its scan before it reads the limits, so a report
        // read then pairs seconds-old tokens with the last run's limits.
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        object["refreshing"] = true
        var scan = try #require(object["scan"] as? [String: Any])
        scan["coveredThrough"] = Self.now.addingTimeInterval(-3).ISO8601Format()
        object["scan"] = scan
        let report = try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        let limitsReadAt = try #require(AgentUsageLimitsView.date(report.claudeProgram?.usageLimits.observedAt))

        publisher.publish([Self.reading(host, .available(report), readAt: Self.now)], now: Self.now)
        #expect(Self.snapshot(directory)?.host(host.id)?.readAt == limitsReadAt)
        #expect(publisher.isStale(host.id, readAt: nil, now: Self.now))
    }

    @Test func turningClaudeCodeLimitsOffHidesThemWhileTheHostRefreshes() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        let complete = try AgentUsageReport.decode(AgentUsageFixture.data())
        // What the store hands on once the toggle is off: limits hidden.
        let optedOut = try AgentUsageFixture.report(refreshing: true)
        let shown = UsageWidgetSnapshot.Host(id: host.id, name: host.displayName, report: complete, readAt: Self.now)
        let hidden = UsageWidgetSnapshot.Host(id: host.id, name: host.displayName, report: optedOut, readAt: Self.now)
        #expect(shown.limits.contains { $0.program == "claude" && !$0.windows.isEmpty })

        publisher.publish([Self.reading(host, .available(complete), readAt: Self.now)], now: Self.now)
        let later = Self.now.addingTimeInterval(60)
        publisher.publish([Self.reading(host, .available(optedOut), readAt: later)], now: later)

        let published = try #require(Self.snapshot(directory)?.host(host.id))
        #expect(published.programs == shown.programs)
        #expect(published.limits.filter { $0.program == "claude" } == hidden.limits.filter { $0.program == "claude" })
        #expect(published.limits.filter { $0.program != "claude" } == shown.limits.filter { $0.program != "claude" })
        #expect(published.limits.map(\.program).first == "claude", "Claude Code keeps its place")
    }

    @Test func removingAnAccountDropsItsFiguresWhileTheHostRefreshes() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        let removedID = "7f3c9a2e"
        let complete = try AgentUsageReport.decode(AgentUsageFixture.data())
        // The next refreshing report serves the last run's figures without the Account.
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        object["refreshing"] = true
        var programs = try #require(object["programs"] as? [[String: Any]])
        var accounts = try #require(programs[0]["accounts"] as? [[String: Any]])
        accounts.removeAll { $0["id"] as? String == removedID }
        programs[0]["accounts"] = accounts
        object["programs"] = programs
        let removed = try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        let later = Self.now.addingTimeInterval(60)
        let fresh = UsageWidgetSnapshot.Host(
            id: host.id, name: host.displayName, report: removed, readAt: removed.figuresDate(readAt: later))
        let shown = UsageWidgetSnapshot.Host(id: host.id, name: host.displayName, report: complete, readAt: Self.now)
        #expect(shown.limits.contains { $0.accountID == removedID })
        #expect(try #require(fresh.readAt) < Self.now, "the report's figures are older than the widget's")

        publisher.publish([Self.reading(host, .available(complete), readAt: Self.now)], now: Self.now)
        publisher.publish([Self.reading(host, .available(removed), readAt: later)], now: later)

        let published = try #require(Self.snapshot(directory)?.host(host.id))
        #expect(!published.limits.contains { $0.accountID == removedID })
        #expect(published == fresh)
    }

    @Test func removingAnAccountDropsItsTokensWhileClaudeCodeLimitsAreOff() throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        let complete = try AgentUsageFixture.report(refreshing: false)
        // The next refreshing report no longer counts the removed Account,
        // which held every Claude Code token.
        var object = try #require(
            JSONSerialization.jsonObject(with: AgentUsageFixture.reportData(refreshing: true)) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        var accounts = try #require(programs[0]["accounts"] as? [[String: Any]])
        accounts.removeAll { $0["id"] as? String == "7f3c9a2e" }
        programs[0]["accounts"] = accounts
        programs[0]["tokenUsage"] = ["state": "noData"]
        object["programs"] = programs
        let removed = try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        let countsClaudeCode = { Self.snapshot(directory)?.host(host.id)?.programs.contains { $0.program == "claude" } }

        publisher.publish([Self.reading(host, .available(complete), readAt: Self.now)], now: Self.now)
        #expect(countsClaudeCode() == true)
        let later = Self.now.addingTimeInterval(60)
        publisher.publish([Self.reading(host, .available(removed), readAt: later)], now: later)
        #expect(countsClaudeCode() == false)
    }

    @Test func aStoreShowingARefreshingReportDatesItsFiguresByTheScan() async throws {
        let cached = try AgentUsageFixture.tokenReport(refreshing: true)
        let scannedAt = try #require(AgentUsageLimitsView.date(cached.scan?.coveredThrough))
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(cached) }

        await store.pullToRefresh()
        #expect(store.figuresReadAt == scannedAt)
    }

    @Test func onlyAUsageOrUsageLimitsWidgetCounts() async throws {
        for (kinds, installed) in [
            ([], false), (["dev.bybee.heeler.other"], false),
            ([UsageWidgetSnapshotStore.usageKind], true), ([UsageWidgetSnapshotStore.limitsKind], true),
        ] as [(Set<String>, Bool)] {
            let (publisher, directory) = try Self.publisher(installed: kinds)
            defer { try? FileManager.default.removeItem(at: directory) }
            #expect(await publisher.widgetsInstalled() == installed)
        }
    }

    @Test func theBackgroundRunReadsOnlyStaleHostsAndKeepsTheOthers() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fresh = Self.host("Fresh")
        let stale = Self.host("Stale")
        let unreachable = Self.host("Overlay only")
        let kept = try AgentUsageFixture.tokenReport(refreshing: false)
        publisher.publish([
            Self.reading(fresh, .available(kept), readAt: .now),
            Self.reading(stale, .available(kept), readAt: .now.addingTimeInterval(-3600)),
            Self.reading(unreachable, .idle, isConnected: false),
        ])
        let report = try AgentUsageFixture.report(refreshing: false)
        let reads = Mutex<Set<String>>([])

        let suite = "AgentUsageWidgetRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AgentUsageStore.claudeLimitsPreferenceKey(for: stale.id))
        await AgentUsageBackgroundRefresh(read: { host, claudeLimits in
            reads.withLock { _ = $0.insert("\(host.name) \(claudeLimits)") }
            return host.id == stale.id ? .available(report) : nil
        }, defaults: defaults).run(
            hosts: [fresh, stale, unreachable], publisher: publisher, isUsageEnabled: { true })

        #expect(reads.withLock { $0 } == ["Stale true", "Overlay only false"])
        let snapshot = try #require(Self.snapshot(directory))
        #expect(snapshot.host(fresh.id)?.programs == UsageWidgetSnapshot.Host(
            id: fresh.id, name: "", report: kept, readAt: .now).programs)
        #expect(snapshot.host(stale.id)?.programs == UsageWidgetSnapshot.Host(
            id: stale.id, name: "", report: report, readAt: .now).programs)
        #expect(snapshot.host(unreachable.id)?.excludedReason == .notConnected)
    }

    /// A Host's Servers read the same Transcripts, so the run asks each of
    /// them and the widgets count the Host once, under its first record.
    @Test func theBackgroundRunCountsAHostWithTwoServersOnce() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let herdr = Self.host("Studio Mac")
        var tmux = Self.host("Studio Mac")
        tmux.serverKind = .tmux
        let report = try AgentUsageFixture.report(refreshing: false)

        await AgentUsageBackgroundRefresh(read: { record, _ in
            record.id == herdr.id
                ? .requirement("Usage needs the Heeler plugin 0.7.0 or newer on this Host.") : .available(report)
        }).run(hosts: [herdr, tmux], publisher: publisher, isUsageEnabled: { true })

        let snapshot = try #require(Self.snapshot(directory))
        #expect(snapshot.hosts.map(\.id) == [herdr.id])
        #expect(snapshot.hosts.first?.name == "Studio Mac")
        #expect(snapshot.hosts.first?.programs == UsageWidgetSnapshot.Host(
            id: herdr.id, name: "", report: report, readAt: .now).programs)
    }

    @Test func theLiveReaderUsesItsOwnConnectionAndClosesIt() async throws {
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try AgentUsageFixture.report(refreshing: true)))
        let complete = try AgentUsageFixture.report(refreshing: false)
        let connector = RecordingConnector(transport: transport)
        let host = Self.host("Studio Mac")
        let refresh = AgentUsageBackgroundRefresh.live(
            connector: connector, knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            sleep: { _ in await transport.setAgentUsage(.success(complete)) })

        // The worker's refresh finishes within the task's re-reads.
        #expect(await refresh.read(host, true) == .available(complete))
        #expect(await transport.agentUsageClaudeLimits == [true, true])
        #expect(await transport.agentUsageCodexLimits == [true, true])
        #expect(await transport.isClosed)
        #expect(connector.connects.withLock { $0 } == 1)

        // A Host whose Codex limits are turned off forwards codexLimits = false
        // and hides any cached Codex reading in the widget snapshot.
        let suite = "codex-widget-refresh-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AgentUsageStore.codexLimitsPreferenceKey(for: host.id))
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let optedOutTransport = ScriptedTransport()
        await optedOutTransport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.10.0")))
        await optedOutTransport.setAgentUsage(.success(complete))
        let optedOutRefresh = AgentUsageBackgroundRefresh.live(
            connector: RecordingConnector(transport: optedOutTransport),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            defaults: defaults)
        await optedOutRefresh.run(hosts: [host], publisher: publisher, isUsageEnabled: { true })
        #expect(await optedOutTransport.agentUsageCodexLimits == [false])
        #expect(Self.snapshot(directory)?.host(host.id)?.limits.first { $0.program == "codex" }?.windows == [])

        // Overlay Network routes stay down in the background.
        var overlayOnly = host
        overlayOnly.routes = [HostRoute(address: "100.64.0.7", overlayNetworkID: UUID())]
        #expect(await refresh.read(overlayOnly, false) == nil)
        #expect(connector.connects.withLock { $0 } == 1)
    }

    @Test func theBackgroundReadWaitsOutAColdRefresh() async throws {
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try AgentUsageFixture.report(refreshing: true)))
        let complete = try AgentUsageFixture.report(refreshing: false)
        let pauses = PauseCount()
        // A Helper left quiet for half an hour took 13 seconds to refresh,
        // so the run finishes only after the fifth 3-second pause.
        let refresh = Self.backgroundRead(RecordingConnector(transport: transport)) { _ in
            if await pauses.next() == 5 { await transport.setAgentUsage(.success(complete)) }
        }

        #expect(await refresh.read(Self.host("Studio Mac"), true) == .available(complete))
    }

    private static func backgroundRead(
        _ connector: any TransportConnector, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> AgentUsageBackgroundRefresh {
        AgentUsageBackgroundRefresh.live(
            connector: connector, knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            sleep: sleep)
    }

    private static func coreConnector(_ core: ScriptedCoreHost) -> FakeTransportConnector {
        FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0.1.13", protocolVersion: 1))), core: core)
    }

    /// The background read follows the Server Kind: a core Host's Usage is its
    /// Helper's, over the connection it dials for the read.
    @Test func aCoreHostsBackgroundReadAsksItsHelper() async throws {
        let helper = ScriptedHelperHost()
        await helper.installApp()
        await helper.seedUsage(try AgentUsageFixture.reportData(refreshing: false), session: "default")
        let scripted = ScriptedCoreHost(helper: helper, channel: .refused)
        let connector = Self.coreConnector(scripted)
        var core = Self.host("Core Mac")
        core.serverKind = .herdrCore

        let state = await Self.backgroundRead(connector).read(core, true)

        #expect(state == .available(try AgentUsageFixture.report()))
        let limits = await helper.steps.compactMap { step -> Bool? in
            guard case .usageQuery(_, let limits, _, _, _) = step else { return nil }
            return limits
        }
        #expect(limits == [true])
        #expect(await scripted.log == ["close"])
    }

    @Test func aCoreHostWithoutTheHelperSaysSoInTheBackgroundToo() async {
        let connector = Self.coreConnector(ScriptedCoreHost(channel: .refused))
        var core = Self.host("Core Mac")
        core.serverKind = .herdrCore

        #expect(await Self.backgroundRead(connector).read(core, false) == .hostHelper(.notInstalled))
    }

    @Test func aCoreHostTheBackgroundReadCannotReachSaysNotConnected() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        var core = Self.host("Core Mac")
        core.serverKind = .herdrCore
        let connector = FakeTransportConnector(outcome: .connectFails(.sshUnreachable(detail: "no route")))

        await Self.backgroundRead(connector).run(hosts: [core], publisher: publisher, isUsageEnabled: { true })

        #expect(Self.snapshot(directory)?.host(core.id)?.excludedReason == .notConnected)
    }

    @Test func connectingReadsAStaleHostForTheWidgetsOnce() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (console, transport, host) = try await Self.console(publisher: publisher)
        defer { console.setHosts([]) }

        await console.resume()
        try await Self.waitUntil("the stale Host is read") { await transport.agentUsageReads == 1 }
        try await Self.waitUntil("the widgets get the reading") {
            Self.snapshot(directory)?.host(host.id)?.reports == true
        }

        // A return within the interval finds the reading fresh.
        await console.reactivate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.agentUsageReads == 1)
    }

    /// Two Servers of one Host both report its Usage. Usage and the widgets
    /// list the Host once, so All Hosts does not add its figures up twice.
    @Test func aHostWithTwoServersIsCountedOnce() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Self.host("Studio Mac")
        var work = Self.host("Studio Mac")
        work.sessionName = "work"
        let workID = work.id
        let report = try AgentUsageFixture.report(refreshing: false)
        let (first, second) = (
            ScriptedTransport(snapshot: .fixture(agents: [])), ScriptedTransport(snapshot: .fixture(agents: [])))
        for transport in [first, second] {
            await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
            await transport.setAgentUsage(.success(report))
        }
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), usageWidgets: publisher, usageSettings: AgentUsageSettings()
        ) { record, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { record.id == workID ? second : first },
                reconnectPolicy: Self.fastPolicy, keepalive: nil)
        }
        defer { console.setHosts([]) }
        console.setHosts([host, work])

        await console.resume()
        try await Self.waitUntil("both Servers connect") {
            console.hostStatuses[host.id] == .connected && console.hostStatuses[workID] == .connected
        }
        await console.agentUsageStore(for: host.id).refresh()
        await console.agentUsageStore(for: workID).refresh()
        try await Self.waitUntil("both Servers report") {
            [host.id, workID].allSatisfy { console.agentUsageStore(for: $0).state == .available(report) }
        }

        let entries = console.agentUsageEntries(for: [host, work])
        #expect(entries.map(\.id) == [host.id])
        #expect(entries.first?.servers.map(\.id) == [host.id, work.id])
        try await Self.waitUntil("the widgets get the Host once") {
            Self.snapshot(directory)?.hosts.map(\.id) == [host.id]
                && Self.snapshot(directory)?.host(host.id)?.reports == true
        }
    }

    @Test func withoutAUsageWidgetConnectingReadsNothing() async throws {
        let (publisher, directory) = try Self.publisher(installed: [])
        defer { try? FileManager.default.removeItem(at: directory) }
        let (console, transport, host) = try await Self.console(publisher: publisher)
        defer { console.setHosts([]) }

        await console.resume()
        try await Self.waitUntil("the Host connects") { console.hostStatuses[host.id] == .connected }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.agentUsageReads == 0)
    }

    @Test func anUnconfirmedHostNeverReachesTheWidgets() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (console, _, host) = try await Self.console(publisher: publisher)
        defer { console.setHosts([]) }

        console.setHosts([
            host, Host(address: "new.example", username: "dev", serverKind: .unconfirmed),
        ])

        #expect(Self.snapshot(directory)?.hosts.map(\.id) == [host.id])
    }

    @Test func turningUsageOffClearsTheWidgetsAndStopsReadsUntilItsBackOn() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (settings, cleanup) = try Self.usageSettings()
        defer { cleanup() }
        let (console, transport, host) = try await Self.console(publisher: publisher, usageSettings: settings)
        defer { console.setHosts([]) }
        await console.resume()
        try await Self.waitUntil("the widgets get the reading") {
            Self.snapshot(directory)?.host(host.id)?.reports == true
        }
        let store = console.agentUsageStore(for: host.id)

        console.setUsageEnabled(false)

        #expect(!settings.isEnabled)
        let off = try #require(Self.snapshot(directory)?.host(host.id))
        #expect(!off.reports && off.programs.isEmpty && off.limits.isEmpty)
        #expect(off.excludedReason == .usageOff)
        #expect(store.state == .idle)
        #expect(console.agentUsageStore(for: host.id) !== store)
        await console.reactivate()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.agentUsageReads == 1)

        console.setUsageEnabled(true)

        try await Self.waitUntil("the widgets read again") {
            Self.snapshot(directory)?.host(host.id)?.reports == true
        }
        #expect(await transport.agentUsageReads == 2)
    }

    @Test func launchingWithUsageOffReadsNothingAndTellsTheWidgets() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (settings, cleanup) = try Self.usageSettings()
        defer { cleanup() }
        settings.setEnabled(false)
        let (console, transport, host) = try await Self.console(publisher: publisher, usageSettings: settings)
        defer { console.setHosts([]) }

        await console.resume()
        try await Self.waitUntil("the Host connects") { console.hostStatuses[host.id] == .connected }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await transport.agentUsageReads == 0)
        #expect(Self.snapshot(directory)?.host(host.id)?.excludedReason == .usageOff)
    }

    @Test func turningUsageOffDuringABackgroundRunKeepsItsReadingsFromTheWidgets() async throws {
        let (publisher, directory) = try Self.publisher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (settings, cleanup) = try Self.usageSettings()
        defer { cleanup() }
        let (console, _, landing) = try await Self.console(publisher: publisher, usageSettings: settings)
        defer { console.setHosts([]) }
        let waiting = Self.host("Build Box")
        let report = try AgentUsageFixture.report(refreshing: false)
        let (started, reportStarted) = AsyncStream<Void>.makeStream()
        let (release, releaseLanding) = AsyncStream<Void>.makeStream()
        let waitingReadCancelled = Mutex(false)

        let run = Task {
            await AgentUsageBackgroundRefresh(read: { host, _ in
                reportStarted.yield()
                if host.id == landing.id {
                    for await _ in release { break }
                } else {
                    try? await Task.sleep(for: .seconds(30))
                    waitingReadCancelled.withLock { $0 = Task.isCancelled }
                }
                return .available(report)
            }).run(hosts: [landing, waiting], publisher: publisher, isUsageEnabled: { console.isUsageEnabled })
        }
        for await _ in started.prefix(2) {}

        console.setUsageEnabled(false)
        releaseLanding.yield()
        await run.value

        #expect(Self.snapshot(directory)?.host(landing.id)?.excludedReason == .usageOff)
        #expect(Self.snapshot(directory)?.host(landing.id)?.reports == false)
        #expect(waitingReadCancelled.withLock { $0 })
    }

    @Test func usageIsOnUntilTurnedOffAndTheChoiceIsRemembered() throws {
        let suite = "hm-usage-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AgentUsageSettings(defaults: defaults)
        #expect(settings.isEnabled)

        settings.setEnabled(false)
        #expect(!AgentUsageSettings(defaults: defaults).isEnabled)

        settings.setEnabled(true)
        #expect(AgentUsageSettings(defaults: defaults).isEnabled)
    }

    private static func usageSettings() throws -> (AgentUsageSettings, cleanup: () -> Void) {
        let suite = "hm-usage-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AgentUsageSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private static func console(
        publisher: AgentUsageWidgetPublisher, usageSettings: AgentUsageSettings? = nil
    ) async throws -> (ConsoleStore, ScriptedTransport, Host) {
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try AgentUsageFixture.report(refreshing: false)))
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), usageWidgets: publisher,
            usageSettings: usageSettings ?? AgentUsageSettings()
        ) { _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport },
                reconnectPolicy: fastPolicy, keepalive: nil)
        }
        let host = host("Studio Mac")
        console.setHosts([host])
        return (console, transport, host)
    }

    private static func publisher(
        installed: Set<String> = [UsageWidgetSnapshotStore.usageKind]
    ) throws -> (AgentUsageWidgetPublisher, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let publisher = AgentUsageWidgetPublisher(
            store: UsageWidgetSnapshotStore(containerURL: directory), reloadTimelines: {},
            installedKinds: { installed })
        return (publisher, directory)
    }

    private static func snapshot(_ directory: URL) -> UsageWidgetSnapshot? {
        UsageWidgetSnapshotStore(containerURL: directory).read()
    }

    /// A Host on an address of its own: records that share a connection are
    /// Servers of one Host, which Usage counts once.
    private static func host(_ name: String) -> Host {
        let address = name.lowercased().replacing(" ", with: "-") + ".local"
        return Host(name: name, username: "dev", routes: [HostRoute(address: address)])
    }

    private static func reading(
        _ host: Host, _ state: AgentUsageStore.State, readAt: Date? = nil, isConnected: Bool = true
    ) -> AgentUsageWidgetReading {
        AgentUsageWidgetReading(
            id: host.id, name: host.displayName, state: state, readAt: readAt, isConnected: isConnected)
    }

    private static func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5), condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

private actor PauseCount {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// Hands every connect the same scripted transport and counts them.
private final class RecordingConnector: TransportConnector {
    let transport: ScriptedTransport
    let connects = Mutex(0)

    init(transport: ScriptedTransport) {
        self.transport = transport
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        connects.withLock { $0 += 1 }
        return transport
    }
}
