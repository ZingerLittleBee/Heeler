import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Claude Code Accounts on the Usage surfaces: the Programs card's Account
/// rows, the Usage Limits chips and iPad strip, All Hosts and Host detail.
/// With only the Default Account, or a plugin before Accounts, every surface
/// reads as before.
@MainActor
@Suite("Claude Code Accounts in Usage", .serialized, .timeLimit(.minutes(1)))
struct ClaudeAccountsUsageTests {
    private typealias Fixture = ClaudeAccountsUsageFixture

    private func scope(_ reports: (name: String, report: AgentUsageReport)...) -> AgentUsageScope {
        AgentUsageScope(readings: reports.map { .init(id: Fixture.hostID($0.name), name: $0.name, state: .available($0.report)) })
    }

    // MARK: Programs card

    @Test(arguments: AgentUsageRange.allCases)
    func readableAccountsAddUpToClaudeCode(range: AgentUsageRange) throws {
        let scope = scope(("studio", try Fixture.report()))
        let accounts = scope.accounts(of: "claude", range: range)
        // The missing Account has no figures to show.
        #expect(accounts.map(\.name) == ["Default", "claude-2"])
        let claude = try #require(scope.programs.first { $0.program == "claude" })
        let program = range.summary(in: claude.totals)
        #expect(accounts.compactMap(\.summary?.tokens.total).reduce(0, +) == program.tokens.total)
        for metric in AgentUsageMetric.allCases {
            let shares = accounts.compactMap(\.summary).map {
                AgentUsageAccountRow.share($0, of: program, metric: metric)
            }
            #expect(abs(shares.reduce(0, +) - 1) < 0.000_1)
        }
        #expect(scope.accounts(of: "codex", range: range).isEmpty)
    }

    @Test func accountRowsReadTheirShareAndTheOtherMetric() throws {
        let scope = scope(("studio", try Fixture.report()))
        let english = Locale(identifier: "en_US")
        let program = try #require(scope.programs.first).totals.last7Days
        let accounts = scope.accounts(of: "claude", range: .last7Days)
        let cost = accounts.map {
            AgentUsageAccountRow.detail($0, programName: "Claude Code", programSummary: program, metric: .cost, locale: english)
        }
        #expect(cost == ["60% of Claude Code · 4.2K tokens", "40% of Claude Code · 2.8K tokens"])
        let tokens = accounts.map {
            AgentUsageAccountRow.detail($0, programName: "Claude Code", programSummary: program, metric: .tokens, locale: english)
        }
        #expect(tokens == ["60% of Claude Code · $4.20", "40% of Claude Code · $2.80"])
    }

    @Test func anAccountWithoutTranscriptsReadsZeroAndAFailedOneSaysSo() throws {
        var accounts = Fixture.studio
        accounts[1].tokenUsage = "noData"
        accounts.append(.init(id: "5e8a10d2", name: "claude-team", tokenUsage: "error"))
        let scope = scope(("studio", try Fixture.report(accounts)))
        let rows = scope.accounts(of: "claude", range: .last30Days)
        #expect(rows.map(\.name) == ["Default", "claude-2", "claude-team"])
        #expect(rows[1].summary?.tokens.total == 0)
        #expect(rows[2].summary == nil)
        let program = try #require(scope.programs.first).totals.last30Days
        #expect(AgentUsageAccountRow.detail(rows[2], programName: "Claude Code", programSummary: program,
            metric: .cost, locale: Locale(identifier: "en_US")) == "Token Usage could not be read.")
        #expect(AgentUsageAccountRow.share(try #require(rows[0].summary), of: program, metric: .tokens) == 1)
    }

    @Test func oneReadableAccountOrAnOlderPluginHasNoAccountRows() throws {
        var oneReadable = Fixture.studio
        oneReadable[1].state = "duplicate"
        for report in [try Fixture.report(Fixture.lone), try Fixture.report(nil), try Fixture.report(oneReadable)] {
            #expect(scope(("studio", report)).accounts(of: "claude", range: .last30Days).isEmpty)
        }
    }

    // MARK: All Hosts

    @Test func allHostsCountEachAccountOnceAndListNoAccountRows() throws {
        let studio = try Fixture.report()
        let build = try Fixture.report(Fixture.lone)
        let scope = scope(("studio", studio), ("build", build))
        let claude = try #require(scope.programs.first { $0.program == "claude" })
        // studio's Default (600) and claude-2 (400) a day, build's Default (300).
        #expect(claude.totals.last30Days.tokens.total == (600 + 400 + 300) * 30)
        let accountTotals = [studio, build].flatMap { $0.claudeProgram?.accounts ?? [] }
            .compactMap { $0.tokenUsage?.totals?.last30Days.tokens.total }
        #expect(claude.totals.last30Days.tokens.total == accountTotals.reduce(0, +))
        // Accounts belong to their Host; the Programs card keeps program totals.
        #expect(scope.accounts(of: "claude", range: .last30Days).isEmpty)
    }

    @Test func allHostsListUsageLimitsPerHostAndAccount() throws {
        let scope = scope(
            ("studio", try Fixture.report()),
            ("build", try Fixture.report([.init(id: "default", daily: 300, fiveHour: 95, weekly: 30)], codexPercent: 20)))
        let chips = AgentUsageLimitChip.chips(in: scope)
        // studio's chips stay together, placed by claude-2's 84%.
        #expect(chips.map { $0.lines(showsHost: true).top } == ["build", "studio", "studio", "studio", "studio", "build"])
        #expect(chips.map { $0.lines(showsHost: true).bottom } == [
            "Claude Code · 5-hour", "Default · Weekly", "claude-2 · 5-hour", "work · Directory not found",
            "Codex · 5-hour", "Codex · 5-hour",
        ])
        #expect(Set(chips.map(\.id)).count == chips.count)
    }

    // MARK: Usage Limits chips

    @Test func eachAccountGetsAChipInAccountOrderThenCodex() throws {
        let chips = AgentUsageLimitChip.chips(in: scope(("studio", try Fixture.report())))
        #expect(chips.map(\.programTitle)
            == ["Claude Code · Default", "Claude Code · claude-2", "Claude Code · work", "Codex"])
        #expect(chips.map(\.title) == ["Weekly", "5-hour", "Directory not found", "5-hour"])
        #expect(chips.map(\.percent) == [61, 84, nil, 47])
        #expect(chips.map { $0.lines(showsHost: false).top } == chips.map(\.programTitle))
        #expect(chips.map { $0.lines(showsHost: false).bottom } == chips.map(\.title))
    }

    @Test func limitsOffKeepOneClaudeCodeChip() throws {
        let chips = AgentUsageLimitChip.chips(in: scope(("studio", try Fixture.report(claudeLimits: false))))
        #expect(chips.map(\.programTitle) == ["Codex", "Claude Code"])
        #expect(chips.map(\.title) == ["5-hour", "Limits off"])
        #expect(chips.allSatisfy { $0.account == nil })
    }

    /// One Account reads as the program did before Accounts: the same ids,
    /// titles and fullest-first order.
    @Test func aLoneDefaultAccountOrAnOlderPluginKeepsTheProgramChips() throws {
        let hostID = Fixture.hostID("studio")
        for accounts in [Fixture.lone, nil] {
            let report = try Fixture.report(accounts, codexPercent: 70)
            let chips = AgentUsageLimitChip.chips(in: scope(("studio", report)))
            #expect(chips.map(\.id) == ["\(hostID)codex", "\(hostID)claude"])
            #expect(chips.map { $0.lines(showsHost: false).top } == ["Codex", "Claude Code"])
            #expect(chips.map { $0.lines(showsHost: true).bottom } == ["Codex · 5-hour", "Claude Code · Weekly"])
            #expect(chips.map(\.percent) == [70, accounts == nil ? 61 : 30])
            #expect(AgentUsageLimitChip.closest(in: scope(("studio", report))) == chips.first)
        }
    }

    // MARK: Host detail

    @Test func hostDetailNamesTheAccountClosestToALimit() throws {
        let closest = try #require(AgentUsageLimitChip.closest(in: scope(("studio", try Fixture.report()))))
        #expect(closest.programTitle == "Claude Code · claude-2")
        #expect(closest.title == "5-hour")
        #expect(closest.percent == 84)
        // With limits off, Codex is the only reading.
        let off = try #require(AgentUsageLimitChip.closest(in: scope(("studio", try Fixture.report(claudeLimits: false)))))
        #expect(off.programTitle == "Codex")
    }

    // MARK: iPad strip

    @Test func theStripGivesOneHostWithAccountsACardPerAccount() async throws {
        let studio = try await Fixture.entry("studio", try Fixture.report())
        let cards = try #require(AgentUsageLimitsStrip.accountCards([studio]))
        #expect(cards.map(\.id) == ["claude.default", "claude.c2d7a1f0", "claude.9be41c07", "codex"])
        #expect(cards.map(\.account) == ["Default", "claude-2", "work", nil])
        // All Hosts keeps a card per Host; one Account keeps the Host card.
        let build = try await Fixture.entry("build", try Fixture.report(Fixture.lone))
        #expect(AgentUsageLimitsStrip.accountCards([studio, build]) == nil)
        #expect(AgentUsageLimitsStrip.accountCards([build]) == nil)
        #expect(AgentUsageLimitsCard.readings(for: try Fixture.report(Fixture.lone)).map(\.id) == ["claude", "codex"])
        #expect(AgentUsageLimitsCard.readings(for: try Fixture.report(nil)).map(\.id) == ["claude", "codex"])
        let off = try await Fixture.entry("studio", try Fixture.report(claudeLimits: false), claudeLimits: false)
        #expect(AgentUsageLimitsStrip.accountCards([off]) == nil)
    }

    // MARK: Rendering

    @Test func theProgramsCardListsEachReadableAccountUnderClaudeCode() async throws {
        let studio = try await Fixture.entry("studio", try Fixture.report())
        let labels = try await renderedLabels(dashboard(studio), until: { $0.contains { $0.contains("of Claude Code") } })
        for expected in [
            "Default, $18.00, 60% of Claude Code · 18K tokens", "claude-2, $12.00, 40% of Claude Code · 12K tokens",
            "Claude Code · claude-2, 5-hour", "Claude Code · work, Directory not found",
        ] {
            #expect(labels.contains { $0.contains(expected) }, "Missing \(expected) in \(labels.sorted())")
        }
    }

    @Test func aLoneDefaultAccountRendersThePageAsBefore() async throws {
        for accounts in [Fixture.lone, nil] {
            let entry = try await Fixture.entry("studio", try Fixture.report(accounts))
            let labels = try await renderedLabels(dashboard(entry), until: { $0.contains { $0.hasPrefix("Breakdown") } })
            #expect(!labels.contains { $0.contains("of Claude Code") }, "\(labels.sorted())")
            #expect(!labels.contains { $0.contains("Default") }, "\(labels.sorted())")
            #expect(labels.contains { $0.contains("Claude Code, Weekly") }, "\(labels.sorted())")
        }
    }

    @Test func hostDetailShowsTheClosestAccountByName() async throws {
        let studio = try await Fixture.entry("studio", try Fixture.report())
        let section = List {
            AgentUsageSection(hostID: studio.id, hostName: studio.name, store: studio.store)
        }
        let labels = try await renderedLabels(section, until: { $0.contains { $0.contains("resets in") } })
        #expect(labels.contains { $0.hasPrefix("claude-2 · 5-hour, Claude Code · resets in") && $0.hasSuffix("84%") },
            "\(labels.sorted())")
    }

    /// An iPad's wide layout, at a landscape iPad Pro 11-inch's width: Account
    /// rows under Claude Code and a strip card per Account for one Host; a
    /// card per Host with a row per Account for All Hosts.
    @Test(arguments: [false, true])
    func theWideLayoutListsAccountsInItsRowsAndStrip(allHosts: Bool) async throws {
        let studio = try await Fixture.entry("studio", try Fixture.report())
        let build = try await Fixture.entry("build", try Fixture.report(Fixture.lone, codexPercent: 20))
        for dark in [false, true] {
            let page = NavigationStack {
                AgentUsageDashboard(
                    entries: [studio, build], scopeHostID: .constant(allHosts ? nil : studio.id),
                    metric: .constant(.cost), allowsColumns: true)
            }
            let name = "wide-\(allHosts ? "all-hosts" : "studio")-\(dark ? "dark" : "light")"
            let labels = try await renderedLabels(
                page, size: CGSize(width: 1_210, height: 1_500), dark: dark, image: name,
                until: { $0.contains { $0.contains("Claude Code · claude-2") } })
            #expect(labels.contains { $0.contains("Claude Code · claude-2") }, "\(labels.sorted())")
            if allHosts {
                #expect(!labels.contains { $0.contains("of Claude Code") }, "\(labels.sorted())")
            } else {
                for expected in [
                    "Default, $18.00, 60% of Claude Code · 18K tokens", "Claude Code · work, Directory not found",
                ] {
                    #expect(labels.contains { $0.contains(expected) }, "Missing \(expected) in \(labels.sorted())")
                }
            }
        }
    }

    private func dashboard(_ entry: AgentUsageHostEntry) -> some View {
        NavigationStack {
            AgentUsageDashboard(entries: [entry], scopeHostID: .constant(entry.id), metric: .constant(.cost))
        }
    }

    /// The accessibility labels `view` shows on a window of `size` once
    /// `ready` holds, or when the wait runs out; `image` also records what
    /// it drew under that name.
    private func renderedLabels(
        _ view: some View, size: CGSize = CGSize(width: 390, height: 2_700), dark: Bool = false,
        image: String? = nil, until ready: (Set<String>) -> Bool
    ) async throws -> Set<String> {
        let controller = UIHostingController(rootView: view
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, dark ? .dark : .light))
        controller.overrideUserInterfaceStyle = dark ? .dark : .light
        controller.safeAreaRegions = []
        let bounds = CGRect(origin: .zero, size: size)
        let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
        defer { window.isHidden = true }
        var labels: Set<String> = []
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            controller.view.layoutIfNeeded()
            labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
            if ready(labels) { break }
            try await Task.sleep(for: .milliseconds(50))
            budget.charge()
        }
        if let image {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            Attachment.record(rendered, named: "\(image).png", as: .png)
            let directory = URL.documentsDirectory.appendingPathComponent("usage-accounts-renders")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(rendered.pngData()).write(to: directory.appendingPathComponent("\(image).png"))
        }
        return labels
    }
}

/// A Host's report with Claude Code Accounts built on the shared vector:
/// each readable Account with its own Token Usage and a 5-hour and weekly
/// window, the program adding their Token Usage up and carrying the Default
/// Account's limits.
@MainActor
enum ClaudeAccountsUsageFixture {
    struct Account {
        let id: String
        var name: String? = nil
        var state = "ok"
        /// Tokens a day: today counts one day, 7 days seven, 30 days thirty.
        var daily: Int64 = 0
        var fiveHour: Double = 10
        var weekly: Double = 5
        var tokenUsage = "ok"
    }

    /// The Default Account, claude-2 closer to its limits, and a missing
    /// `work`.
    static let studio: [Account] = [
        Account(id: "default", daily: 600, fiveHour: 34, weekly: 61),
        Account(id: "c2d7a1f0", name: "claude-2", daily: 400, fiveHour: 84, weekly: 52),
        Account(id: "9be41c07", name: "work", state: "missing"),
    ]

    static let lone: [Account] = [Account(id: "default", daily: 300, fiveHour: 20, weekly: 30)]

    private static var hostIDs: [String: Host.ID] = [:]

    /// One id per Host name, so chips and cards can be compared.
    static func hostID(_ name: String) -> Host.ID {
        if let id = hostIDs[name] { return id }
        let id = UUID()
        hostIDs[name] = id
        return id
    }

    /// A Host whose store has read `report`, with Claude Code limits on.
    static func entry(
        _ name: String, _ report: AgentUsageReport, claudeLimits: Bool = true
    ) async throws -> AgentUsageHostEntry {
        // The store reads its consent once; the suite need not outlive it.
        let suite = "claude-accounts-usage-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentUsageStore(hostID: hostID(name), defaults: defaults) { _, _ in .available(report) }
        store.claudeLimitsEnabled = claudeLimits
        await store.refresh()
        return AgentUsageHostEntry(id: hostID(name), name: name, store: store, isConnected: true)
    }

    /// `accounts` nil answers as a plugin before Accounts, with the Default
    /// Account's figures as the program's.
    static func report(
        _ accounts: [Account]? = studio, claudeLimits: Bool = true, codexPercent: Double = 47
    ) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        let timestamp = ISO8601DateFormatter()
        func window(_ id: String, _ minutes: Int, _ percent: Double, in seconds: TimeInterval) -> [String: Any] {
            [
                "id": id, "durationMinutes": minutes, "usedPercent": percent,
                "resetsAt": timestamp.string(from: Date().addingTimeInterval(seconds)), "expired": false,
            ]
        }
        func limits(_ windows: [[String: Any]]) -> [String: Any] {
            [
                "state": "ok", "source": "service", "plan": "max",
                "observedAt": timestamp.string(from: Date().addingTimeInterval(-60)), "windows": windows,
            ]
        }
        func claudeLimitsOf(_ account: Account) -> [String: Any] {
            claudeLimits
                ? limits([
                    window("fiveHour", 300, account.fiveHour, in: 2 * 3_600),
                    window("sevenDay", 10_080, account.weekly, in: 3 * 86_400),
                ])
                : ["state": "disabled"]
        }
        func summary(_ total: Int64) -> [String: Any] {
            [
                "tokens": ["input": total, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0, "total": total],
                "estimatedCostUSD": Double(total) / 1_000, "unpricedTokens": 0,
            ]
        }
        func totals(_ daily: Int64) -> [String: Any] {
            ["today": summary(daily), "last7Days": summary(daily * 7), "last30Days": summary(daily * 30)]
        }
        let all = accounts ?? [Account(id: "default", daily: 600, fiveHour: 34, weekly: 61)]
        let counted = all.filter { $0.state == "ok" && $0.tokenUsage == "ok" }
        var claude = programs[0]
        var usage = try #require(claude["tokenUsage"] as? [String: Any])
        usage["totals"] = totals(counted.reduce(0) { $0 + $1.daily })
        claude["tokenUsage"] = usage
        claude["usageLimits"] = claudeLimitsOf(all[0])
        if let accounts {
            claude["accounts"] = accounts.map { account -> [String: Any] in
                var entry: [String: Any] = [
                    "id": account.id, "isDefault": account.id == "default",
                    "name": account.name.map { $0 as Any } ?? NSNull(),
                    "directory": "/Users/u/.\(account.name ?? "claude")", "state": account.state,
                ]
                if account.state == "ok" {
                    entry["tokenUsage"] = account.tokenUsage == "ok"
                        ? ["state": "ok", "totals": totals(account.daily)] : ["state": account.tokenUsage]
                    entry["usageLimits"] = claudeLimitsOf(account)
                }
                return entry
            }
            claude["accountSuggestions"] = [Any]()
        } else {
            claude.removeValue(forKey: "accounts")
            claude.removeValue(forKey: "accountSuggestions")
        }
        programs[0] = claude
        programs[1]["usageLimits"] = limits([window("primary", 300, codexPercent, in: 3 * 3_600)])
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }
}
