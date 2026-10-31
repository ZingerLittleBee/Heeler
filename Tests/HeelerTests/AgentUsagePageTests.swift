import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage page", .serialized, .timeLimit(.minutes(1)))
struct AgentUsagePageTests {
    @Test func thePageShowsTheThirtyDayTotalFromTheSharedVector() async throws {
        let report = try AgentUsageFixture.report()
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let english = Locale(identifier: "en_US")
        let total = AgentUsageScope.sum((report.programs ?? []).compactMap(\.okTotals?.last30Days))
        let controller = UIHostingController(rootView:
            NavigationStack {
                AgentUsageDashboard(entries: [Self.entry(store)], scopeHostID: .constant(nil), metric: .constant(.cost))
            }
                .environment(\.locale, english))
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
        defer { window.isHidden = true }
        var labels = ""
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: ", ")
            if labels.contains("Last 30 days") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(labels.contains("Estimated API cost · Last 30 days"), "Actual labels: \(labels)")
        #expect(labels.contains(AgentUsageStyle.cost(total.estimatedCostUSD, locale: english)),
            "Actual labels: \(labels)")
        #expect(labels.contains("tokens on this Host"), "Actual labels: \(labels)")
    }

    @Test func aWideIPadPageReadsAsATableAndCanShowUsageLimitsInstead() async throws {
        let report = try AgentUsageFixture.report()
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let entries = [Self.entry(store), Self.entry(store, name: "Build Box")]
        for showsLimits in [false, true] {
            let controller = UIHostingController(rootView:
                NavigationStack {
                    AgentUsageDashboard(
                        entries: entries, scopeHostID: .constant(nil), metric: .constant(.cost),
                        showsLimits: .constant(showsLimits), allowsColumns: true)
                }
                .environment(\.locale, Locale(identifier: "en_US")))
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 1_100, height: 1_600), rootViewController: controller)
            defer { window.isHidden = true }
            let expected = showsLimits
                ? ["Account windows as each service reports them", "Shown per Host", "Usage Limits"]
                : ["Daily estimated API cost", "Estimated API cost on these 2 Hosts · Last 30 days",
                   "claude-opus-4-5", "Usage Limits are shown per Host", "Breakdown",
                   "Recorded on these 2 Hosts since"]
            var labels = ""
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                controller.view.layoutIfNeeded()
                labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
                    .joined(separator: ", ")
                if expected.allSatisfy(labels.contains) { break }
                try await Task.sleep(for: .milliseconds(50))
                budget.charge()
            }
            for text in expected {
                #expect(labels.contains(text), "Missing \(text): \(labels)")
            }
            // The wide page has no Day sheet or Hosts card; the sidebar lists Hosts.
            #expect(!labels.contains("Hold to read a day"), "\(labels)")
        }
    }

    static func entry(_ store: AgentUsageStore, name: String = "Studio Mac") -> AgentUsageHostEntry {
        AgentUsageHostEntry(id: UUID(), name: name, store: store, isConnected: true)
    }
}

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
        #expect(both.hasSuffix("Price table: 2026-10-30."), "Actual: \(both)")
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

    @Test func detailsRenderFromTheSharedVectorAtBothContentSizes() async throws {
        let report = try AgentUsageFixture.report()
        let directory = URL.documentsDirectory.appendingPathComponent("usage-page-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let entry = AgentUsagePageTests.entry(store)
        let scope = AgentUsageScope(readings: [entry.reading])
        for accessible in [false, true] {
            for kind in [AgentUsageBreakdown.Kind.models, .directories] {
                // drawHierarchy fails past the 8,192-pixel texture limit.
                let size = CGSize(width: 390, height: kind == .models ? 2_700 : 600)
                let content: AnyView = kind == .models
                    ? AnyView(AgentUsageDashboard(
                        entries: [entry], scopeHostID: .constant(nil), metric: .constant(.cost)))
                    : AnyView(List { AgentUsageBreakdown(scope: scope, kind: kind, metric: .cost) })
                let controller = UIHostingController(rootView: content
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                controller.safeAreaRegions = []
                let bounds = CGRect(origin: .zero, size: size)
                let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                defer { window.isHidden = true }
                let expected = kind == .models
                    ? ["Last 30 days", "Programs", "Breakdown", "claude-opus-4-5", "Price table: 2026-10-30.",
                       "Recorded on this Host since Oct 23, 2026.",
                       "Estimated API cost is based on recorded Token Usage"]
                    : ["/work/project", "/work/codex"]
                var labels = ""
                var budget = PollBudget(.seconds(5))
                while budget.hasTimeLeft {
                    controller.view.layoutIfNeeded()
                    labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
                        .joined(separator: ", ")
                    if expected.allSatisfy(labels.contains) { break }
                    try await Task.sleep(for: .milliseconds(50))
                    budget.charge()
                }
                for text in expected {
                    #expect(labels.contains(text), "Missing \(text): \(labels)")
                }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    #expect(controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
                }
                let filename = "\(kind.rawValue)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
        }
    }
}

@MainActor
@Suite("Agent usage page interaction", .serialized, .timeLimit(.minutes(5)))
struct AgentUsagePageInteractionTests {
    @Test func navigationAndPullRefreshFollowTheRefreshingLoop() async throws {
        let hostID = UUID()
        let transport = ScriptedTransport()
        let complete = try AgentUsageFixture.report()
        let partial = try AgentUsageFixture.report(refreshing: true)
        await transport.setHeelerPlugin(.success(.init(pluginRoot: "/plugins/heeler", version: "0.7.0")))
        await transport.setAgentUsage(.success(complete))
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]),
            sleep: { try await sleeper.sleep($0) })
        let controller = UIHostingController(rootView: AnyView(
            UsageHarness(hostID: hostID, store: store).environment(\.locale, Locale(identifier: "en_US"))))
        let window = try await makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await eventually { store.state == .available(complete) && !store.isLoading })
        let initialReads = await transport.agentUsageReads
        let manual = URL.documentsDirectory.appendingPathComponent("usage-interactive-review")
        let interactive = FileManager.default.fileExists(atPath: manual.path)
        if interactive {
            try "host-ready".write(to: URL.documentsDirectory.appendingPathComponent("usage-interactive-stage"),
                atomically: true, encoding: .utf8)
        } else {
            try #require(await eventually { ChangesViewTests.activate("Open in Usage", in: controller.view) })
        }
        try #require(await eventually(seconds: interactive ? 120 : 5) {
            ChangesViewTests.navigationControllers(in: controller).contains { $0.viewControllers.count > 1 }
        })
        try #require(await eventually { await transport.agentUsageReads > initialReads && !store.isLoading })
        let beforeRefresh = await transport.agentUsageReads
        await transport.setAgentUsage(.success(partial))
        if interactive {
            try "page-ready".write(to: URL.documentsDirectory.appendingPathComponent("usage-interactive-stage"),
                atomically: true, encoding: .utf8)
        } else {
            let refresh = try #require(Self.refreshControls(in: controller.view).first)
            refresh.sendActions(for: .valueChanged)
        }
        try #require(await eventually(seconds: interactive ? 120 : 5) {
            await transport.agentUsageReads > beforeRefresh && store.state == .available(partial)
        })
        await transport.setAgentUsage(.success(complete))
        // The pull ends after its read; the surfaces keep the 3-second cadence.
        // The Host section under the page and the dashboard both restart
        // polling, and the later one supersedes the earlier.
        try #require(await eventually { await sleeper.durations.count >= 2 })
        for duration in await sleeper.durations {
            #expect(duration > .zero && duration <= AgentUsageStore.pollInterval)
        }
        #expect(await transport.agentUsageReads == beforeRefresh + 1)
        // Let the cadence elapse for every loop, including one whose sleep
        // registers after an earlier firing: firing once can leave the
        // current loop asleep, which no real sleep would do.
        try #require(await eventually(seconds: 30) {
            await sleeper.fireAll()
            return store.state == .available(complete) && !store.isLoading
        })
        let reads = await transport.agentUsageReads
        #expect(reads == beforeRefresh + 2)
        try #require(await eventually { isNavigationSettled(controller) })
        try await Self.captureViewports(in: controller)
        if interactive {
            try "refresh-complete".write(to: URL.documentsDirectory.appendingPathComponent("usage-interactive-stage"),
                atomically: true, encoding: .utf8)
            try #require(await eventually(seconds: 120) {
                !FileManager.default.fileExists(atPath: manual.path)
            })
        }
        controller.rootView = AnyView(Text("Closed"))
    }

    @Test func leavingThePageCancelsItsPollingTask() async throws {
        let partial = try AgentUsageFixture.report(refreshing: true)
        var reads = 0
        let sleeper = ChangesManualSleeper()
        let store = AgentUsageStore(hostID: UUID(), sleep: { try await sleeper.sleep($0) }) { _, _ in
            reads += 1
            return .available(partial)
        }
        let controller = UIHostingController(rootView: AnyView(NavigationStack {
            AgentUsageDashboard(
                entries: [AgentUsagePageTests.entry(store)], scopeHostID: .constant(nil), metric: .constant(.cost))
        }))
        let window = try await makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await eventually { await !sleeper.durations.isEmpty && reads == 1 && store.isLoading })
        controller.rootView = AnyView(Text("Closed"))
        try #require(await eventually { !store.isLoading })
        await sleeper.fireAll()
        for _ in 0..<20 { await Task.yield() }
        #expect(reads == 1)
        #expect(store.state == .available(partial))
    }

    /// The Host detail's section above the dashboard it opens, as the
    /// Usage tab shows it.
    private struct UsageHarness: View {
        let hostID: Host.ID
        let store: AgentUsageStore
        @State private var showsUsage = false

        var body: some View {
            NavigationStack {
                List {
                    AgentUsageSection(hostID: hostID, hostName: "Test Host", store: store,
                        openUsage: { showsUsage = true })
                }
                .navigationTitle("Test Host")
                .navigationDestination(isPresented: $showsUsage) {
                    AgentUsageDashboard(
                        entries: [AgentUsageHostEntry(id: hostID, name: "Test Host", store: store, isConnected: true)],
                        scopeHostID: .constant(hostID), metric: .constant(.cost))
                }
            }
        }
    }

    private func eventually(seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        var budget = PollBudget(.milliseconds(Int64(seconds * 1_000)))
        while budget.hasTimeLeft {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
            budget.charge()
        }
        return await condition()
    }

    private static func refreshControls(in view: UIView) -> [UIRefreshControl] {
        (view as? UIRefreshControl).map { [$0] } ?? []
            + view.subviews.flatMap { refreshControls(in: $0) }
    }

    /// Programmatic viewport renders complement real Simulator gestures; they
    /// establish layout below the fold, not successful touch injection.
    private static func captureViewports(in controller: UIViewController) async throws {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(controller.view).last { $0.contentSize.height > $0.bounds.height })
        let directory = URL.documentsDirectory.appendingPathComponent("usage-page-viewports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var allLabels = ""
        var offset = -scroll.adjustedContentInset.top
        for index in 0..<12 {
            scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            allLabels += AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: ", ")
            let bounds = controller.view.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                #expect(controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
            }
            let filename = "viewport-\(index).png"
            Attachment.record(image, named: filename, as: .png)
            try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            // List refines its estimated content height as rows come on screen.
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = min(scroll.contentOffset.y + 500, bottom)
            if next <= scroll.contentOffset.y + 1 { break }
            offset = next
        }
        for expected in ["Programs", "Codex", "claude-opus-4-5", "Price table"] {
            #expect(allLabels.contains(expected), "Missing \(expected) across page viewports")
        }
    }
}
