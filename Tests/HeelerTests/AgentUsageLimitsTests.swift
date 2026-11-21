import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage limits", .serialized, .timeLimit(.minutes(1)))
struct AgentUsageLimitsTests {
    @Test func theSharedVectorCarriesClaudeServiceAndNullableModelWindows() throws {
        let report = try AgentUsageReport.decode(AgentUsageFixture.data())
        let limits = try #require(report.programs?.first?.usageLimits)
        #expect(limits.state == "ok")
        #expect(limits.source == "service")
        #expect(limits.plan == "max")
        #expect(limits.windows?.map(\.id) == ["fiveHour", "sevenDayOpus", "sevenDaySonnet", "claude:model:Custom model"])
        #expect(limits.windows?.first?.resetsAt == nil)
        #expect(limits.windows?.first?.usedPercent == 12)
        #expect(limits.windows?.last?.label == "Custom model")
        #expect(limits.windows?.last?.durationMinutes == nil)
        #expect(limits.windows?.last?.usedPercent == nil)
        #expect(limits.windows?.last?.expired == true)
    }

    @Test func theStoreKeepsLimitSourcesAndExpiredWindowsFromThePlugin() async throws {
        let report = try AgentUsageLimitFixture.report(source: "lastSession")
        let hostID = UUID()
        let transport = ScriptedTransport()
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(report))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        await store.refresh()
        guard case .available(let received) = store.state else {
            Issue.record("The Host must retain the reported Usage Limits.")
            return
        }
        let limits = try #require(received.programs?.last?.usageLimits)
        #expect(limits.source == "lastSession")
        #expect(limits.observedAt == "2026-10-23T12:34:50Z")
        #expect(limits.plan == "plus")
        #expect(limits.windows?.first?.durationMinutes == 10_080)
        #expect(limits.windows?.first?.usedPercent == 18)
        #expect(limits.windows?.last?.expired == true)
        #expect(limits.windows?.last?.usedPercent == nil)
    }

    @Test func theSharedNodeVectorCarriesDefaultGroupWindowsWithAnExpiredReading() throws {
        let limits = try #require(AgentUsageFixture.report().programs?.last?.usageLimits)
        #expect(limits.state == "ok")
        #expect(limits.source == "lastSession")
        #expect(limits.observedAt == "2026-10-23T12:34:50.000Z")
        #expect(limits.plan == "plus")
        #expect(limits.windows?.first?.id == "primary")
        #expect(limits.windows?.first?.durationMinutes == 10_080)
        #expect(limits.windows?.first?.usedPercent == 18)
        #expect(limits.windows?.last?.id == "secondary")
        #expect(limits.windows?.last?.expired == true)
        #expect(limits.windows?.last?.usedPercent == nil)
    }
}

enum AgentUsageLimitFixture {
    static func report(source: String = "service", state: String = "ok", reason: String? = nil,
        windows: [[String: Any]]? = nil) throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        var limits: [String: Any] = [
            "state": state, "source": source, "observedAt": "2026-10-23T12:34:50Z", "plan": "plus",
            "windows": [
                // Relative to now: a reset that has passed reads as expired.
                ["id": "primary", "durationMinutes": 10_080, "usedPercent": 18,
                 "resetsAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86_400)),
                 "expired": false],
                ["id": "secondary", "durationMinutes": 300, "usedPercent": NSNull(),
                 "resetsAt": "2026-10-23T12:00:00Z", "expired": true],
            ],
        ]
        if let windows { limits["windows"] = windows }
        if let reason { limits["reason"] = reason }
        if state != "ok" { limits.removeValue(forKey: "windows") }
        programs[programs.count - 1]["usageLimits"] = limits
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }
}

enum ClaudeUsageFixture {
    static func report(state: String = "ok") throws -> AgentUsageReport {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        let timestamp = ISO8601DateFormatter()
        let now = Date()
        programs[0]["usageLimits"] = [
            "state": state, "source": "service", "plan": "max", "reason": "programTooOld",
            "observedAt": timestamp.string(from: now.addingTimeInterval(-60)),
            "retryAt": timestamp.string(from: now.addingTimeInterval(300)),
            "windows": [
                ["id": "fiveHour", "durationMinutes": 300, "usedPercent": 12, "resetsAt": NSNull(), "expired": false],
                ["id": "sevenDayOpus", "durationMinutes": 10080, "usedPercent": 23, "resetsAt": NSNull(), "expired": false],
                ["id": "sevenDaySonnet", "durationMinutes": 10080, "usedPercent": 34, "resetsAt": NSNull(), "expired": false],
                ["id": "claude:model:Custom", "label": "Custom model", "durationMinutes": NSNull(),
                 "usedPercent": NSNull(), "resetsAt": timestamp.string(from: now.addingTimeInterval(-120)), "expired": true],
            ],
        ]
        object["programs"] = programs
        return try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
    }
}
