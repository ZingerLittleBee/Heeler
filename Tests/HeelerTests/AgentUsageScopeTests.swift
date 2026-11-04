import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage scope")
struct AgentUsageScopeTests {
    @Test func tokenUsageAddsUpAcrossHostsByTheDayEachHostReported() throws {
        let studio = try Self.report(timeZone: "Asia/Shanghai", days: [
            ("2026-10-25", 100, 1.0), ("2026-10-26", 200, 2.0),
        ], model: "claude-opus-5-5", directory: "/src/app")
        let build = try Self.report(timeZone: "UTC", days: [
            ("2026-10-24", 10, 0.1), ("2026-10-25", 20, 0.2),
        ], model: "claude-opus-5-5", directory: "/src/app")
        let scope = AgentUsageScope(readings: [
            .init(id: UUID(), name: "Studio Mac", state: .available(studio)),
            .init(id: UUID(), name: "Build Box", state: .available(build)),
        ])

        let claude = try #require(scope.programs.first)
        #expect(scope.programs.map(\.program) == ["claude"])
        #expect(claude.daily.map(\.date) == ["2026-10-24", "2026-10-25", "2026-10-26"])
        #expect(claude.daily.map(\.tokens.total) == [10, 120, 200])
        #expect(claude.totals.last30Days.tokens.total == 330)
        #expect(claude.totals.last30Days.estimatedCostUSD.map { ($0 * 100).rounded() } == 330)
        #expect(scope.total(.last30Days).tokens.total == 330)
        #expect(scope.day("2026-10-25").tokens.total == 120)
        // One model name is one model; one path on two Hosts is two directories.
        #expect(claude.models.map(\.model) == ["claude-opus-5-5"])
        #expect(claude.models.first?.tokens.total == 330)
        #expect(claude.directories.map(\.hostName) == ["Studio Mac", "Build Box"])
        #expect(scope.dayNote == "Days follow each Host’s time zone (Asia/Shanghai, UTC).")
    }

    @Test func usageLimitsStayWithTheirHost() throws {
        let first = try Self.report(timeZone: "UTC", days: [("2026-10-26", 1, 0.01)], limitsPercent: 62)
        let second = try Self.report(timeZone: "UTC", days: [("2026-10-26", 1, 0.01)], limitsPercent: 24)
        let scope = AgentUsageScope(readings: [
            .init(id: UUID(), name: "Studio Mac", state: .available(first)),
            .init(id: UUID(), name: "Build Box", state: .available(second)),
        ])

        #expect(scope.included.map { $0.programs.first?.usageLimits.windows?.first?.usedPercent }
            == [62, 24])
        #expect(scope.dayNote == "Days shown in UTC.")
    }

    @Test func hostsThatCannotReportAreLeftOutWithTheirReason() throws {
        let report = try Self.report(timeZone: "UTC", days: [("2026-10-26", 5, nil)])
        let scope = AgentUsageScope(readings: [
            .init(id: UUID(), name: "Studio Mac", state: .available(report)),
            .init(id: UUID(), name: "Office PC", state: .unsupportedPlatform),
            .init(id: UUID(), name: "Pi Lab", state: .failed(AgentUsageStore.connectionFailureMessage)),
            .init(id: UUID(), name: "Mini", state: .loading),
            .init(id: UUID(), name: "Lab", state: .loading, isConnected: false),
        ])

        #expect(scope.excluded.map(\.name) == ["Office PC", "Pi Lab", "Lab"])
        #expect(scope.excluded.map(\.reason)
            == ["Not supported on Windows", "Could not read Usage", "Not connected"])
        #expect(scope.loading.map(\.name) == ["Mini"])
        // Unpriced throughout stays unpriced instead of reading $0.00.
        #expect(scope.total(.last30Days).estimatedCostUSD == nil)
        #expect(scope.total(.last30Days).unpricedTokens == 5)
    }

    private static func report(
        timeZone: String, days: [(String, Int64, Double?)], model: String = "m",
        directory: String = "/d", limitsPercent: Double = 10
    ) throws -> AgentUsageReport {
        func tokens(_ total: Int64) -> [String: Any] {
            ["input": total, "cacheRead": 0, "cacheWrite": 0, "output": 0, "reasoning": 0, "total": total]
        }
        func summary(_ total: Int64, _ cost: Double?) -> [String: Any] {
            ["tokens": tokens(total), "estimatedCostUSD": cost.map { $0 as Any } ?? NSNull(),
             "unpricedTokens": cost == nil ? total : 0]
        }
        let total = days.reduce(Int64(0)) { $0 + $1.1 }
        let costs = days.compactMap(\.2)
        let cost: Double? = costs.isEmpty ? nil : costs.reduce(0, +)
        let object: [String: Any] = [
            "version": 1, "runtime": "recorded", "generatedAt": "2026-10-26T09:00:00Z",
            "timeZone": timeZone, "refreshing": false, "pricingVersion": "2026-10-20",
            "scan": ["state": "complete", "coveredFrom": days.first?.0 ?? "", "skippedArchives": 0],
            "programs": [[
                "program": "claude",
                "usageLimits": [
                    "state": "ok", "source": "service", "observedAt": "2026-10-26T09:00:00Z",
                    "windows": [[
                        "id": "fiveHour", "durationMinutes": 300, "usedPercent": limitsPercent,
                        "resetsAt": "2026-10-26T12:00:00Z", "expired": false,
                    ]],
                ],
                "tokenUsage": [
                    "state": "ok",
                    "totals": [
                        "today": summary(days.last?.1 ?? 0, days.last?.2),
                        "last7Days": summary(total, cost), "last30Days": summary(total, cost),
                    ],
                    "daily": days.map { day in
                        var entry = summary(day.1, day.2)
                        entry["date"] = day.0
                        return entry
                    },
                    "models": [{ () -> [String: Any] in
                        var entry = summary(total, cost)
                        entry["model"] = model
                        entry["priced"] = cost != nil
                        entry["unpricedTokens"] = cost == nil ? total : 0
                        return entry
                    }()],
                    "directories": [{ () -> [String: Any] in
                        var entry = summary(total, cost)
                        entry["path"] = directory
                        entry["unpricedTokens"] = cost == nil ? total : 0
                        return entry
                    }()],
                ],
            ]],
        ]
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }
}
