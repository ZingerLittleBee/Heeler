import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent usage detail rendering", .serialized)
struct AgentUsageDetailTests {
    @Test func sharedVectorPreservesModelPricesDirectoryTotalsAndCalendarDays() throws {
        let report = try AgentUsageFixture.report()
        let claude = try #require(report.programs?.first?.tokenUsage)
        let codex = try #require(report.programs?.last?.tokenUsage)
        #expect(claude.models?.first?.model == "claude-opus-4-5")
        #expect(claude.models?.first?.priced == true)
        #expect(claude.models?.first?.tokens.total == 882_000)
        #expect(claude.models?.first?.unpricedTokens == 0)
        #expect(claude.directories?.first?.path == "/work/project")
        #expect(claude.directories?.first?.tokens.total == 882_000)
        #expect(claude.directories?.first?.estimatedCostUSD == 0.92225)
        #expect(codex.models?.first?.model == "gpt-5.3-codex")
        #expect(codex.models?.first?.priced == true)
        #expect(codex.directories?.first?.path == "/work/codex")
        #expect(codex.directories?.first?.tokens.total == 250)
        #expect(codex.directories?.first?.unpricedTokens == 0)
        #expect(claude.daily?.count == 30)
        #expect(claude.daily?.first?.date == "2026-09-24")
        #expect(claude.daily?.last?.date == "2026-10-23")
    }

    @Test func theCoverageNoteCountsSkippedAndUnreadableTranscripts() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var labelsByCount: [Int: String] = [:]
        var reportsByCount: [Int: AgentUsageReport] = [:]
        for count in [0, 3] {
            var scan = try #require(object["scan"] as? [String: Any])
            scan["skippedArchives"] = count
            scan["unreadableFiles"] = count
            object["scan"] = scan
            let report = try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
            #expect(report.scan?.unreadableFiles == count)
            reportsByCount[count] = report
            labelsByCount[count] = AgentUsageDashboard.coverage(
                hosts: [("Studio Mac", report)], locale: Locale(identifier: "en_US"),
                calendar: Calendar(identifier: .gregorian))
        }
        let clean = try #require(labelsByCount[0])
        let unreadable = try #require(labelsByCount[3])
        #expect(clean.contains("Recorded on this Host since"), "Actual labels: \(clean)")
        #expect(!clean.contains("could not be read"), "Actual labels: \(clean)")
        #expect(!clean.contains("archives skipped"), "Actual labels: \(clean)")
        #expect(unreadable.contains(
            "3 Transcripts or folders could not be read. They are retried on the next refresh."),
            "Actual labels: \(unreadable)")
        #expect(unreadable.contains("3 compressed archives skipped."), "Actual labels: \(unreadable)")

        let both = AgentUsageDashboard.coverage(
            hosts: [("Studio Mac", try #require(reportsByCount[0])), ("Build Box", try #require(reportsByCount[3]))],
            locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian))
        #expect(both.hasPrefix("Recorded on these 2 Hosts since"), "Actual: \(both)")
        #expect(both.contains("Build Box: 3 compressed archives skipped."), "Actual: \(both)")
        #expect(!both.contains("Studio Mac:"), "Actual: \(both)")
        #expect(both.hasSuffix("Price table: 2026-11-21."), "Actual: \(both)")
    }

    @Test func calendarDaysAreLocalizedWithoutShiftingTheirDay() {
        var farEast = Calendar(identifier: .gregorian)
        farEast.timeZone = TimeZone(identifier: "Pacific/Kiritimati") ?? .gmt
        var farWest = Calendar(identifier: .gregorian)
        farWest.timeZone = TimeZone(identifier: "Pacific/Pago_Pago") ?? .gmt
        let english = Locale(identifier: "en_US")
        for calendar in [farEast, farWest] {
            #expect(AgentUsageCalendarDay.text("2026-10-23", locale: english, calendar: calendar,
                includesYear: true) == "Oct 23, 2026")
            #expect(AgentUsageCalendarDay.text("2026-10-01", locale: english, calendar: calendar,
                includesYear: false) == "Oct 1")
        }
        #expect(AgentUsageCalendarDay.text("2026-10-23", locale: Locale(identifier: "de_DE"),
            calendar: farEast, includesYear: false) == "23. Okt.")
        for invalid in ["2026-13-40", "yesterday", "2026-10"] {
            #expect(AgentUsageCalendarDay.text(invalid, locale: english, calendar: farEast,
                includesYear: true) == invalid)
        }
    }
}
