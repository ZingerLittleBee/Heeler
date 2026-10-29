import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage widgets")
struct AgentUsageWidgetTests {
    private static let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let studio = UUID()
    private let build = UUID()
    private let pi = UUID()

    @Test func aReportBecomesTheHostsFiguresAndUsageLimits() throws {
        let snapshot = UsageWidgetSnapshot(
            readings: [reading(studio, "Studio Mac", .available(try Self.report()), readAt: Self.now)],
            previous: nil, now: Self.now)

        let host = try #require(snapshot.hosts.first)
        #expect(host.reports && host.readAt == Self.now && host.timeZone == "Asia/Shanghai")
        // Only Token Usage that read ok is added up.
        #expect(host.programs.map(\.program) == ["claude"])
        #expect(host.programs.first?.today == .init(cost: 2, tokens: 200))
        #expect(host.programs.first?.days.map(\.date) == ["2026-10-25", "2026-10-26"])
        // Usage Limits keep every program, named for display.
        #expect(host.limits.map(\.name) == ["Claude Code", "Codex"])
        let claude = try #require(host.limits.first)
        #expect(claude.windows.map(\.name) == ["5-hour", "Weekly · Opus"])
        #expect(claude.source == .program && claude.message == nil && !claude.isLastReading)
        #expect(host.limits.last?.message == "Usage Limits are off.")
        #expect(host.limits.last?.windows.isEmpty == true)
    }

    @Test func aHostWithoutANewerReportKeepsItsLastOne() throws {
        let first = UsageWidgetSnapshot(
            readings: [reading(studio, "Studio Mac", .available(try Self.report()), readAt: Self.now)],
            previous: nil, now: Self.now)

        // A launch: stores idle and the Host not yet connected.
        let relaunched = UsageWidgetSnapshot(
            readings: [reading(studio, "Studio", .idle, isConnected: false)], previous: first,
            now: Self.now.addingTimeInterval(600))
        #expect(relaunched.hosts.first?.readAt == Self.now)
        #expect(relaunched.hosts.first?.programs == first.hosts.first?.programs)
        #expect(relaunched.hosts.first?.name == "Studio")

        // A Host that answered it cannot report drops its figures.
        let unsupported = UsageWidgetSnapshot(
            readings: [reading(studio, "Studio Mac", .unsupportedPlatform)], previous: first, now: Self.now)
        #expect(unsupported.hosts.first?.excludedReason == "Not supported on Windows")
        #expect(unsupported.hosts.first?.programs.isEmpty == true)
    }

    @Test func aHostNeverReadSaysWhy() {
        let snapshot = UsageWidgetSnapshot(
            readings: [
                reading(studio, "Studio Mac", .idle, isConnected: false),
                reading(build, "Build Box", .loading),
                reading(pi, "Pi Lab", .failed(AgentUsageStore.connectionFailureMessage)),
            ],
            previous: nil, now: Self.now)

        #expect(snapshot.hosts.map(\.excludedReason) == ["Not connected", "Not read yet", "Could not read Usage"])
        #expect(snapshot.hosts.allSatisfy { !$0.reports })
    }

    @Test func allHostsAddsUpTheHostsThatReportAndNamesTheRest() throws {
        let snapshot = UsageWidgetSnapshot(
            readings: [
                reading(studio, "Studio Mac", .available(try Self.report()), readAt: Self.now),
                reading(build, "Build Box", .available(try Self.report(timeZone: "UTC")),
                    readAt: Self.now.addingTimeInterval(-60)),
                reading(pi, "Pi Lab", .idle, isConnected: false),
            ],
            previous: nil, now: Self.now)

        let all = try #require(UsageWidgetScope(snapshot: snapshot, hostID: nil))
        #expect(all.title == "All Hosts")
        #expect(all.total(.today) == .init(cost: 4, tokens: 400))
        #expect(all.programs.first?.days["2026-10-25"] == .init(cost: 4, tokens: 400))
        #expect(all.updatedAt == Self.now.addingTimeInterval(-60))
        #expect(all.coverage == "2 of 3 Hosts")
        #expect(all.excludedNote == "Not included: Pi Lab")
        #expect(all.chartDates(.today) == ["2026-10-25", "2026-10-26"])

        let one = try #require(UsageWidgetScope(snapshot: snapshot, hostID: pi))
        #expect(one.isEmpty && one.coverage == nil && one.excludedNote == nil)
        #expect(UsageWidgetScope(snapshot: snapshot, hostID: UUID()) == nil)
        // Unpriced throughout stays unpriced rather than reading $0.
        #expect(UsageWidgetSnapshot.Summary.sum([.init(cost: nil, tokens: 5)]).cost == nil)
    }

    @Test func theSnapshotFileRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageWidgetSnapshotStore(containerURL: directory)
        #expect(store.read() == nil)

        let snapshot = UsageWidgetSnapshot(
            readings: [reading(studio, "Studio Mac", .available(try Self.report()), readAt: Self.now)],
            previous: nil, now: Self.now)
        store.write(snapshot)
        #expect(store.read() == snapshot)

        // A snapshot from another version reads as none.
        var future = snapshot
        future.version = UsageWidgetSnapshot.currentVersion + 1
        store.write(future)
        #expect(store.read() == nil)
    }

    @Test func thePublisherWritesAndReloadsOnlyOnChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads = 0
        let publisher = AgentUsageWidgetPublisher(
            store: UsageWidgetSnapshotStore(containerURL: directory), reloadTimelines: { reloads += 1 })
        let readings = [reading(studio, "Studio Mac", .available(try Self.report()), readAt: Self.now)]

        publisher.publish(readings, now: Self.now)
        publisher.publish(readings, now: Self.now)
        #expect(reloads == 1)
        #expect(UsageWidgetSnapshotStore(containerURL: directory).read()?.hosts.first?.readAt == Self.now)

        publisher.publish([reading(studio, "Studio", .loading)], now: Self.now)
        #expect(reloads == 2)
    }

    @Test func aReadRecordsItsTimeAndTellsTheWidgets() async throws {
        let report = try Self.report()
        let suite = "AgentUsageWidgetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentUsageStore(hostID: studio, defaults: defaults) { _, _ in .available(report) }
        var changes = 0
        store.didChange = { changes += 1 }

        #expect(store.readAt == nil)
        await store.refresh()
        #expect(store.readAt != nil)
        #expect(changes == 1)

        store.claudeLimitsEnabled = true
        #expect(changes == 2)
        store.invalidate()
        #expect(store.readAt == nil && changes == 3)
    }

    @Test func widgetLinksRoundTrip() throws {
        let usage = try #require(UsageWidgetLink.usageURL(hostID: studio))
        let limits = try #require(UsageWidgetLink.limitsURL(hostID: studio))
        let all = try #require(UsageWidgetLink.usageURL(hostID: nil))

        #expect(all.absoluteString == "heeler://usage")
        #expect(UsageWidgetLink.target(from: all) == .init(hostID: nil, showsLimits: false))
        #expect(UsageWidgetLink.target(from: usage) == .init(hostID: studio, showsLimits: false))
        #expect(UsageWidgetLink.target(from: limits) == .init(hostID: studio, showsLimits: true))
        #expect(UsageWidgetLink.target(from: try #require(URL(string: "heeler://usage/limits"))) == nil)
        #expect(UsageWidgetLink.target(from: try #require(URL(string: "heeler://usage/other"))) == nil)
        // The two link families never read each other's URLs.
        #expect(AgentActivityLink.target(from: usage) == nil)
        #expect(UsageWidgetLink.target(from: try #require(URL(string: "heeler://agent?host=mac"))) == nil)
    }

    @Test func smallSizesPickTheTightestOrSoonestRunningWindow() {
        func window(_ id: String, _ percent: Double, resetsIn hours: Double, expired: Bool = false) -> UsageWidgetSnapshot.Window {
            .init(id: id, name: id, usedPercent: percent,
                resetsAt: Self.now.addingTimeInterval(hours * 3_600), expired: expired)
        }
        let windows = [
            window("fiveHour", 62, resetsIn: 2), window("weekly", 38, resetsIn: 88),
            window("weeklyOpus", 71, resetsIn: 88), window("ended", 99, resetsIn: -1),
        ]

        #expect(UsageLimitsPick.tightest(windows, now: Self.now)?.id == "weeklyOpus")
        #expect(UsageLimitsPick.shortest(windows, now: Self.now)?.id == "fiveHour")
        #expect(UsageLimitsPick.lockScreen(windows, now: Self.now).map(\.id) == ["fiveHour", "weeklyOpus"])
        // A reset that passes after the reading ends the window.
        #expect(UsageLimitsPick.shortest(windows, now: Self.now.addingTimeInterval(3 * 3_600))?.id == "weekly")
    }

    @Test func automaticShowsTheProgramClosestToItsLimit() {
        func limits(_ program: String, _ percent: Double?) -> UsageWidgetSnapshot.Limits {
            .init(
                program: program, name: program, account: nil, message: percent == nil ? "Usage Limits are off." : nil,
                isLastReading: false, source: nil, observedAt: nil,
                windows: percent.map {
                    [.init(id: "weekly", name: "Weekly", usedPercent: $0,
                        resetsAt: Self.now.addingTimeInterval(3_600), expired: false)]
                } ?? [])
        }
        let off = [limits("claude", nil), limits("codex", 7)]
        let both = [limits("claude", 12), limits("codex", 40)]

        // Claude Code's limits are off by default; Automatic skips them.
        #expect(UsageLimitsPick.program(off, preferring: nil, now: Self.now)?.program == "codex")
        #expect(UsageLimitsPick.program(both, preferring: nil, now: Self.now)?.program == "codex")
        #expect(UsageLimitsPick.program(off, preferring: "claude", now: Self.now)?.program == "claude")
        #expect(UsageLimitsPick.program([limits("claude", nil)], preferring: nil, now: Self.now)?.program == "claude")
    }

    // MARK: Claude Code Accounts

    @Test func eachClaudeCodeAccountIsAnEntryInTheAppsOrder() throws {
        let report = try ClaudeAccountsUsageFixture.report()
        let host = UsageWidgetSnapshot.Host(id: studio, name: "Studio Mac", report: report, readAt: Self.now)

        // The Default Account, the Account file's order, then Codex, as Usage lists them.
        #expect(host.limits.map(\.account) == ["Default", "claude-2", "work", nil])
        #expect(host.limits.map(\.id) == ["claude.Default", "claude.claude-2", "claude.work", "codex"])
        #expect(host.limits.map(\.title) == [
            "Claude Code · Default", "Claude Code · claude-2", "Claude Code · work", "Codex",
        ])
        #expect(host.limits.map(\.program) == AgentUsageLimitsCard.readings(for: report).map(\.program))
        // Each Account carries its own windows; one that is not counted says why.
        #expect(host.limits[0].windows.map(\.usedPercent) == [34, 61])
        #expect(host.limits[1].windows.map(\.usedPercent) == [84, 52])
        #expect(host.limits[2].windows.isEmpty && host.limits[2].message == "Directory not found")
        // Token Usage stays per program, the Accounts already added up.
        #expect(host.programs.filter { $0.program == "claude" }.map(\.today.tokens) == [1_000])
    }

    @Test func aLoneAccountAnOldPluginOrLimitsOffKeepOneClaudeCodeEntry() throws {
        let reports = [
            try ClaudeAccountsUsageFixture.report(ClaudeAccountsUsageFixture.lone),
            try ClaudeAccountsUsageFixture.report(nil),
            try ClaudeAccountsUsageFixture.report(claudeLimits: false),
        ]
        let hosts = reports.map { UsageWidgetSnapshot.Host(id: studio, name: "Studio Mac", report: $0, readAt: Self.now) }

        for host in hosts {
            #expect(host.limits.map(\.id) == ["claude", "codex"])
            #expect(host.limits.allSatisfy { $0.account == nil })
            #expect(host.limits.first?.title == "Claude Code")
        }
        #expect(hosts[2].limits.first?.message == "Usage Limits are off.")
    }

    @Test func aSnapshotFromBeforeAccountsStillReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageWidgetSnapshotStore(containerURL: directory)
        let older = """
            {"version": 1, "hosts": [{"id": "\(studio.uuidString)", "name": "Studio Mac", "programs": [],
              "limits": [{"program": "claude", "name": "Claude Code", "isLastReading": false, "source": "program",
                "windows": [{"id": "fiveHour", "name": "5-hour", "usedPercent": 62, "expired": false}]}]}]}
            """
        try Data(older.utf8).write(to: directory.appendingPathComponent("usage-widgets.json"))

        let limits = try #require(store.read()?.host(studio)?.limits.first)
        #expect(limits.account == nil && limits.id == "claude" && limits.title == "Claude Code")
        #expect(limits.windows.map(\.usedPercent) == [62])

        // Accounts round-trip through the file.
        let snapshot = UsageWidgetSnapshot(hosts: [UsageWidgetSnapshot.Host(
            id: studio, name: "Studio Mac", report: try ClaudeAccountsUsageFixture.report(), readAt: Self.now)])
        store.write(snapshot)
        #expect(store.read() == snapshot)
        #expect(store.read()?.hosts.first?.limits.map(\.account) == ["Default", "claude-2", "work", nil])
    }

    @Test func circularAndInlineNameTheAccountClosestToALimit() {
        let accounts = [
            Self.limits("Default", [Self.window("fiveHour", 62, resetsIn: 2), Self.window("weeklyOpus", 71, resetsIn: 88)]),
            Self.limits("claude-2", [Self.window("fiveHour", 84, resetsIn: 0.5), Self.window("weekly", 57, resetsIn: 113)]),
            Self.limits("work", []),
        ]
        let codex = Self.limits(nil, program: "codex", [
            Self.window("primary", 24, resetsIn: 1), Self.window("secondary", 47, resetsIn: 70),
        ])

        let closest = UsageLimitsPick.reading(accounts, now: Self.now)
        #expect(closest?.limits.account == "claude-2" && closest?.window.id == "fiveHour")
        // Once claude-2's 5-hour window resets, Default's weekly Opus window is the closest.
        let later = UsageLimitsPick.reading(accounts, now: Self.now.addingTimeInterval(3_600))
        #expect(later?.limits.account == "Default" && later?.window.id == "weeklyOpus")
        // One program alone keeps the window that resets soonest.
        #expect(UsageLimitsPick.reading([codex], now: Self.now)?.window.id == "primary")
        #expect(UsageLimitsPick.reading([], now: Self.now) == nil)

        // The chosen program brings every Account; Automatic picks the
        // program of the entry closest to a limit.
        let all = accounts + [codex]
        #expect(UsageLimitsPick.entries(all, preferring: "claude", now: Self.now).map(\.account)
            == ["Default", "claude-2", "work"])
        #expect(UsageLimitsPick.entries(all, preferring: "codex", now: Self.now).map(\.id) == ["codex"])
        #expect(UsageLimitsPick.entries(all, preferring: nil, now: Self.now).map(\.program) == ["claude", "claude", "claude"])
        let tightCodex = Self.limits(nil, program: "codex", [Self.window("primary", 95, resetsIn: 1)])
        #expect(UsageLimitsPick.entries(accounts + [tightCodex], preferring: nil, now: Self.now).map(\.id) == ["codex"])
    }

    @Test func theLayoutFollowsHowManyEntriesAHostHas() {
        func entries(_ count: Int) -> [UsageWidgetSnapshot.Limits] {
            (0..<count).map { Self.limits("account-\($0)", []) }
        }

        // Small and rectangular: one program's figure, or a line per Account.
        #expect((0...4).map { UsageLimitsLayout.program(entries($0)) } == [.figure, .figure, .lines, .lines, .lines])
        // Medium: two columns for up to two entries, then a line each.
        #expect((0...5).map { UsageLimitsLayout.medium(entries($0)) }
            == [.columns, .columns, .columns, .lines, .lines, .lines])
        // Large: up to four windows each for up to three entries, then two each.
        #expect((0...5).map { UsageLimitsLayout.large(entries($0)) }
            == [.windows, .windows, .windows, .windows, .pairs, .pairs])
    }

    @Test func aPairNamesItsResetByTheTimeTodayAndByTheDayAfter() throws {
        let noon = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Self.now))
        let today = noon.addingTimeInterval(1_800)
        let later = noon.addingTimeInterval(72 * 3_600)
        func window(_ resetsAt: Date) -> UsageWidgetSnapshot.Window {
            .init(id: "w", name: "Weekly", usedPercent: 50, resetsAt: resetsAt, expired: false)
        }

        #expect(UsageWidgetText.resetDay(window(today), now: noon)
            == "resets \(today.formatted(date: .omitted, time: .shortened))")
        #expect(UsageWidgetText.resetDay(window(later), now: noon)
            == "resets \(later.formatted(.dateTime.month(.abbreviated).day()))")
        // An ended window has none: its row says so.
        #expect(UsageWidgetText.resetDay(window(today), now: noon.addingTimeInterval(3_600)) == nil)
    }

    private static func window(_ id: String, _ percent: Double, resetsIn hours: Double) -> UsageWidgetSnapshot.Window {
        .init(id: id, name: id, usedPercent: percent, resetsAt: now.addingTimeInterval(hours * 3_600), expired: false)
    }

    private static func limits(
        _ account: String?, program: String = "claude", _ windows: [UsageWidgetSnapshot.Window]
    ) -> UsageWidgetSnapshot.Limits {
        .init(
            program: program, name: AgentUsageReport.Program.displayName(for: program), account: account,
            message: windows.isEmpty ? "Directory not found" : nil, isLastReading: false,
            source: windows.isEmpty ? nil : .program, observedAt: now, windows: windows)
    }

    private func reading(
        _ id: UUID, _ name: String, _ state: AgentUsageStore.State, readAt: Date? = nil, isConnected: Bool = true
    ) -> AgentUsageWidgetReading {
        AgentUsageWidgetReading(id: id, name: name, state: state, readAt: readAt, isConnected: isConnected)
    }

    /// Claude Code with two days of Token Usage and two windows; Codex with
    /// Token Usage that failed and its Usage Limits off.
    private static func report(timeZone: String = "Asia/Shanghai") throws -> AgentUsageReport {
        func summary(_ total: Int64, _ cost: Double) -> [String: Any] {
            ["tokens": ["input": total, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0, "total": total],
             "estimatedCostUSD": cost, "unpricedTokens": 0]
        }
        var first = summary(200, 2)
        first["date"] = "2026-10-25"
        var second = summary(200, 2)
        second["date"] = "2026-10-26"
        let object: [String: Any] = [
            "version": 1, "runtime": "recorded", "generatedAt": "2026-10-26T09:00:00Z",
            "timeZone": timeZone, "refreshing": false, "pricingVersion": "2026-10-20",
            "scan": ["state": "complete", "coveredFrom": "2026-10-25", "skippedArchives": 0],
            "programs": [
                [
                    "program": "claude",
                    "usageLimits": [
                        "state": "ok", "source": "service", "observedAt": "2026-10-26T09:00:00Z",
                        "windows": [
                            ["id": "fiveHour", "durationMinutes": 300, "usedPercent": 62,
                             "resetsAt": "2026-10-26T12:00:00Z", "expired": false],
                            ["id": "sevenDayOpus", "durationMinutes": 10_080, "usedPercent": 71,
                             "resetsAt": "2026-10-30T02:00:00Z", "expired": false],
                        ],
                    ],
                    "tokenUsage": [
                        "state": "ok",
                        "totals": ["today": summary(200, 2), "last7Days": summary(400, 4), "last30Days": summary(400, 4)],
                        "daily": [first, second], "models": [], "directories": [],
                    ],
                ],
                [
                    "program": "codex",
                    "usageLimits": ["state": "disabled"],
                    "tokenUsage": ["state": "error", "reason": "scanFailed"],
                ],
            ],
        ]
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }
}
