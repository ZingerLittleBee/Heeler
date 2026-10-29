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
        #expect(after.host(added.id)?.excludedReason == "Not read yet")
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
        }, defaults: defaults).run(hosts: [fresh, stale, unreachable], publisher: publisher)

        #expect(reads.withLock { $0 } == ["Stale true", "Overlay only false"])
        let snapshot = try #require(Self.snapshot(directory))
        #expect(snapshot.host(fresh.id)?.programs == UsageWidgetSnapshot.Host(
            id: fresh.id, name: "", report: kept, readAt: .now).programs)
        #expect(snapshot.host(stale.id)?.programs == UsageWidgetSnapshot.Host(
            id: stale.id, name: "", report: report, readAt: .now).programs)
        #expect(snapshot.host(unreachable.id)?.excludedReason == "Not connected")
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
        #expect(await transport.isClosed)
        #expect(connector.connects.withLock { $0 } == 1)

        // Overlay Network routes stay down in the background.
        var overlayOnly = host
        overlayOnly.routes = [HostRoute(address: "100.64.0.7", overlayNetworkID: UUID())]
        #expect(await refresh.read(overlayOnly, false) == nil)
        #expect(connector.connects.withLock { $0 } == 1)
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

    private static func console(
        publisher: AgentUsageWidgetPublisher
    ) async throws -> (ConsoleStore, ScriptedTransport, Host) {
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(try AgentUsageFixture.report(refreshing: false)))
        let console = ConsoleStore(snapshotRetryDelay: .milliseconds(10), usageWidgets: publisher) { _, subscriptions in
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

    private static func host(_ name: String) -> Host {
        Host(name: name, username: "dev", routes: [HostRoute(address: "studio.local")])
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
