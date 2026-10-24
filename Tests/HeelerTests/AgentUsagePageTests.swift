import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage page", .serialized, .timeLimit(.minutes(1)))
struct AgentUsagePageTests {
    @Test func thePageShowsTheSevenDayTotalFromTheSharedVector() async throws {
        let report = try AgentUsageFixture.report()
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        let controller = UIHostingController(rootView:
            NavigationStack { AgentUsageView(store: store) }
                .environment(\.locale, Locale(identifier: "en_US")))
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
        defer { window.isHidden = true }
        var labels = ""
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: ", ")
            if labels.contains("Last 7 days") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(labels.contains("Last 7 days"), "Actual labels: \(labels)")
        #expect(labels.contains("882,000"), "Actual labels: \(labels)")
        #expect(labels.contains("Token Usage on this Host"), "Actual labels: \(labels)")
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

    @Test func detailsRenderFromTheSharedVectorAtBothContentSizes() async throws {
        let report = try AgentUsageFixture.report()
        let directory = URL.documentsDirectory.appendingPathComponent("usage-page-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for accessible in [false, true] {
            for program in report.programs ?? [] {
                let controller = UIHostingController(rootView:
                    VStack(alignment: .leading, spacing: 20) {
                        Text(program.program == "claude" ? "Claude Code" : "Codex").font(.title.bold())
                        AgentUsageProgramDetails(program: program, timeZone: report.timeZone)
                        AgentUsageCoverage(report: report)
                        CodexUsageLimitsNote()
                    }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                controller.safeAreaRegions = []
                let bounds = CGRect(origin: .zero,
                    size: controller.sizeThatFits(in: CGSize(width: 390, height: 10_000)))
                let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
                    .joined(separator: ", ")
                for expected in ["Last 7 days", "Daily tokens", "Models", "Top directories",
                                 "Price table: 2026-10-23", "Recorded on this Host since 2026-10-23",
                                 "Codex shows only its default limit group."] {
                    #expect(labels.contains(expected), "Missing \(expected): \(labels)")
                }
                #expect(labels.contains(program.program == "claude" ? "/work/project" : "/work/codex"))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    #expect(controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
                }
                let filename = "\(program.program)-accessible-\(accessible).png"
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
        await transport.setHeelerPlugin(.success(.init(version: "0.7.0")))
        await transport.setAgentUsage(.success(complete))
        let store = AgentUsageStore(hostID: hostID,
            transports: ScriptedTransportProvider(transports: [hostID: transport]))
        let controller = UIHostingController(rootView: AnyView(
            NavigationStack {
                List { AgentUsageSection(store: store) }.navigationTitle("Test Host")
            }.environment(\.locale, Locale(identifier: "en_US"))))
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
            try #require(await eventually { ChangesViewTests.activate("View Usage Details", in: controller.view) })
        }
        try #require(await eventually(seconds: interactive ? 120 : 5) {
            ChangesViewTests.navigationControllers(in: controller).contains { $0.viewControllers.count > 1 }
        })
        try #require(await eventually { await transport.agentUsageReads > initialReads && !store.isLoading })
        let beforeRefresh = await transport.agentUsageReads
        await transport.setAgentUsage(.success(partial))
        let started = ContinuousClock.now
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
        try #require(await eventually { store.state == .available(complete) && !store.isLoading })
        #expect(started.duration(to: .now) >= .seconds(3))
        #expect(await transport.agentUsageReads == beforeRefresh + 2)
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
        let store = AgentUsageStore(hostID: UUID()) { _, _ in reads += 1; return .available(partial) }
        let controller = UIHostingController(rootView: AnyView(NavigationStack { AgentUsageView(store: store) }))
        let window = try await makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await eventually { reads == 1 && store.isLoading })
        controller.rootView = AnyView(Text("Closed"))
        try #require(await eventually { !store.isLoading })
        try await Task.sleep(for: .milliseconds(3_100))
        #expect(reads == 1)
        #expect(store.state == .available(partial))
    }

    private func eventually(seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(seconds * 1_000)))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
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
        for expected in ["Models", "/work/project", "Codex", "Weekly", "Expired", "/work/codex", "Price table"] {
            #expect(allLabels.contains(expected), "Missing \(expected) across page viewports")
        }
    }
}
