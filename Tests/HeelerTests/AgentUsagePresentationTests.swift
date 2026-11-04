import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage presentation", .serialized)
struct AgentUsagePresentationTests {
    @Test func estimatedAPICostStatesRenderWithoutHidingUnpricedTokens() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("usage-cost-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scenarios: [(String, Double?, Int64, String)] = [
            ("priced", 1.92, 0, "Estimated API cost: $1.92"),
            ("unpriced", nil, 882_000, "Estimated API cost: Unpriced"),
            ("mixed", 1.92, 250, "Estimated API cost: $1.92"),
            ("small", 0.001, 0, "Estimated API cost: < $0.01"),
        ]
        for (name, cost, unpriced, expected) in scenarios {
            let report = try AgentUsageFixture.costReport(cost: cost, unpriced: unpriced)
            for accessible in [false, true] {
                let controller = UIHostingController(rootView:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Usage").font(.title2.bold())
                        AgentUsageContent(state: .available(report))
                    }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                controller.safeAreaRegions = []
                let size = controller.sizeThatFits(in: CGSize(width: 390, height: 5_000))
                let bounds = CGRect(origin: .zero, size: size)
                controller.view.frame = bounds
                let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                defer { window.isHidden = true }
                var labels = ""
                for _ in 0..<40 {
                    controller.view.layoutIfNeeded()
                    labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: ", ")
                    if labels.contains(expected) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(labels.contains(expected), "Actual labels: \(labels)")
                if unpriced > 0 {
                    #expect(labels.contains("\(unpriced.formatted()) tokens unpriced"))
                }
                if cost == nil { #expect(!labels.contains("$0.00")) }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
                }
                let filename = "cost-\(name)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
        }
    }

    @Test func tokenUsageAndRefreshStatesRenderAtStandardAndAccessibleSizes() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("usage-token-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for refreshing in [false, true] {
            let reports = [
                ("claude", try AgentUsageFixture.tokenReport(refreshing: refreshing)),
                ("both-programs", try AgentUsageFixture.report(refreshing: refreshing)),
            ]
            for (scenario, report) in reports {
                for accessible in [false, true] {
                    let controller = UIHostingController(rootView:
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Usage").font(.title2.bold())
                            AgentUsageContent(state: .available(report))
                        }
                        .padding(20)
                        .frame(width: 390, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(Color(uiColor: .systemBackground))
                        .environment(\.colorScheme, .light)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                    controller.safeAreaRegions = []
                    let size = controller.sizeThatFits(in: CGSize(width: 390, height: 5_000))
                    let bounds = CGRect(origin: .zero, size: size)
                    controller.view.frame = bounds
                    let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                    defer { window.isHidden = true }
                    controller.view.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 2
                    let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                        controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
                    }
                    #expect(image.size.width == 390)
                    let filename = "\(scenario)-refreshing-\(refreshing)-accessible-\(accessible).png"
                    Attachment.record(image, named: filename, as: .png)
                    try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
                }
            }
        }
    }

    @Test func eachHostStateShowsItsCopy() async throws {
        let available = try AgentUsageFixture.report(refreshing: true)
        let cases: [(AgentUsageContent, [String])] = [
            (.init(state: .loading), ["Loading Usage…"]),
            (.init(state: .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
             ["Usage needs plugin 0.7.0 or newer; this Host has 0.6.2."]),
            (.init(state: .unsupportedPlatform), ["Not supported on Windows"]),
            (.init(state: .runtimeMissing),
             ["Use any Agent on this computer once, or restart herdr, then refresh Usage."]),
            (.init(state: .updateRequired), ["Update Heeler to read this Host's Usage format."]),
            (.init(state: .failed(AgentUsageStore.connectionFailureMessage)),
             [AgentUsageStore.connectionFailureMessage]),
            (.init(state: .failed(AgentUsageStore.pluginFailureMessage)), [AgentUsageStore.pluginFailureMessage]),
            (.init(state: .available(try AgentUsageFixture.noDataReport())),
             ["Claude Code", "Codex", "No Token Usage recorded on this Host yet."]),
            (.init(state: .available(available)),
             ["Refreshing", "Today: 882,000 tokens"]),
            (.init(state: .available(available), refreshFailure: AgentUsageStore.connectionFailureMessage,
                isRetryingRefresh: true),
             ["Last refresh failed", AgentUsageStore.connectionFailureMessage,
              "Showing the last report while Heeler retries.", "Today: 882,000 tokens"]),
            (.init(state: .available(try AgentUsageFixture.report()),
                refreshFailure: AgentUsageStore.timeoutMessage),
             ["Last refresh failed", "Showing the last report. Pull to try again."]),
        ]
        for (content, expected) in cases {
            let controller = UIHostingController(rootView:
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .environment(\.locale, Locale(identifier: "en_US")))
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 1_600), rootViewController: controller)
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view)
                .joined(separator: "\n")
            for text in expected {
                #expect(labels.contains(text), "Missing \(text) for \(content.state): \(labels)")
            }
        }
    }

    @Test func hostStatesRenderAtStandardAndAccessibleSizes() throws {
        let states: [(String, AgentUsageStore.State)] = [
            ("old-plugin", .requirement("Usage needs plugin 0.7.0 or newer; this Host has 0.6.2.")),
            ("windows", .unsupportedPlatform),
            ("runtime-missing", .runtimeMissing),
            ("no-data", .available(try AgentUsageFixture.noDataReport())),
            ("update", .updateRequired),
        ]
        let directory = URL.documentsDirectory.appendingPathComponent("usage-495-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, state) in states {
            var heights: [CGFloat] = []
            for accessible in [false, true] {
                let renderer = ImageRenderer(content:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Usage").font(.title2.bold())
                        AgentUsageContent(state: state)
                    }
                    .padding(20)
                    .frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .light)
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                renderer.scale = 2
                let image = try #require(renderer.uiImage)
                #expect(image.size.width == 390)
                #expect(image.size.height > 60)
                heights.append(image.size.height)
                let filename = "\(name)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
            #expect(heights[1] > heights[0], "The full guidance must grow with Dynamic Type.")
        }
    }
}
