import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Agent usage limits", .serialized, .timeLimit(.minutes(1)))
struct AgentUsageLimitsTests {
    @Test func claudeToggleAndLimitStatesRenderAtStandardAndAccessibleSizes() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("usage-claude-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for state in ["disabled", "ok", "throttled", "unavailable"] {
            for accessible in [false, true] {
                let name = "claude-render-\(UUID())"
                let defaults = try #require(UserDefaults(suiteName: name))
                defer { defaults.removePersistentDomain(forName: name) }
                let report = try ClaudeUsageFixture.report(state: state)
                let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, _ in .available(report) }
                store.claudeLimitsEnabled = state != "disabled"
                await store.refresh()
                guard case .available(let visible) = store.state else { Issue.record("Missing report"); return }
                let limits = try #require(visible.programs?.first?.usageLimits)
                let controller = UIHostingController(rootView:
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Usage").font(.title2.bold())
                        ClaudeUsageLimitsToggle(store: store)
                        ClaudeUsageLimitsNote()
                        AgentUsageLimitsView(program: "claude", limits: limits)
                    }
                    .padding(20).frame(width: 390, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, accessible ? .dark : .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                controller.safeAreaRegions = []
                let size = controller.sizeThatFits(in: CGSize(width: 390, height: 5_000))
                let bounds = CGRect(origin: .zero, size: size)
                controller.view.frame = bounds
                let window = try await makeTestWindow(frame: bounds, rootViewController: controller)
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
                #expect(labels.contains("Claude Code limits"))
                if state == "disabled" { #expect(labels.contains("Usage Limits are off.")) }
                if state == "ok" || state == "throttled" {
                    #expect(labels.contains("Weekly · Opus"))
                    #expect(labels.contains("Weekly · Sonnet"))
                    #expect(labels.contains("Custom model"))
                    #expect(labels.contains("Expired · current usage unknown"))
                }
                if state == "throttled" { #expect(labels.contains("Retry after")) }
                if state == "unavailable" { #expect(labels.contains("Update Claude Code")) }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    #expect(controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
                }
                let filename = "claude-\(state)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
        }
    }

    @Test func claudeDisclosureAppearsBesideEachHostsLimits() async throws {
        do {
            let name = "claude-disclosure-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let report = try ClaudeUsageFixture.report()
            let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, _ in .available(report) }
            await store.refresh()
            let content = AnyView(AgentUsageLimitsSheet(entries: [
                AgentUsageHostEntry(id: UUID(), name: "Studio Mac", store: store, isConnected: true),
            ]))
            let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: "en_US")))
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller)
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(150))
            controller.view.layoutIfNeeded()
            let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
            #expect(labels.contains("Claude Code limits"))
            #expect(labels.contains("The plugin asks Claude Code on this computer for your plan limits."))
            #expect(labels.contains("Neither the plugin nor Heeler handles your sign-in."))
            #expect(labels.contains("This automated use is not officially supported."))
            let directory = URL.documentsDirectory.appendingPathComponent("usage-claude-surfaces")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
                #expect(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
            }
            let filename = "limits-sheet.png"
            Attachment.record(image, named: filename, as: .png)
            try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
        }
    }

    @Test func turningClaudeLimitsOnReadsThemInsteadOfSayingTheyAreOff() async throws {
        let name = "claude-reading-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let withoutLimits = try AgentUsageFixture.report()
        let withLimits = try ClaudeUsageFixture.report()
        var requested: [Bool] = []
        let store = AgentUsageStore(hostID: UUID(), defaults: defaults) { _, claudeLimits in
            requested.append(claudeLimits)
            return .available(claudeLimits ? withLimits : withoutLimits)
        }
        await store.refresh()
        store.claudeLimitsEnabled = true
        guard case .available(let pending) = store.state else { Issue.record("Missing report"); return }
        let reading = try #require(pending.programs?.first?.usageLimits)
        #expect(reading.state == "unavailable")
        #expect(reading.reason == "notReadYet")
        #expect(pending.programs?.last == withoutLimits.programs?.last)
        let controller = UIHostingController(rootView: AgentUsageLimitsView(program: "claude", limits: reading)
            .padding(20).frame(width: 390).environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 400), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
        #expect(labels.contains("Reading Usage Limits…"))
        #expect(!labels.contains("Usage Limits are off."))
        await store.refresh()
        #expect(requested == [false, true])
        #expect(store.state == .available(withLimits))
    }

    @Test func aResetThatPassesWhileThePageIsOpenExpiresTheReading() async throws {
        let passed = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let report = try AgentUsageLimitFixture.report(windows: [
            ["id": "primary", "durationMinutes": 300, "usedPercent": 64, "resetsAt": passed, "expired": false],
        ])
        let limits = try #require(report.programs?.last?.usageLimits)
        let controller = UIHostingController(rootView: AgentUsageLimitsView(program: "codex", limits: limits)
            .padding(20).frame(width: 390).environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
        #expect(labels.contains("Expired · current usage unknown"))
        #expect(labels.contains("Reset "))
        #expect(!labels.contains("Resets "))
        #expect(!labels.contains("64%"))
    }

    @Test func aProgramThisBuildDoesNotKnowKeepsItsOwnName() async throws {
        var object = try #require(JSONSerialization.jsonObject(with: AgentUsageFixture.data()) as? [String: Any])
        var programs = try #require(object["programs"] as? [[String: Any]])
        programs[1]["program"] = "gemini"
        programs[1]["usageLimits"] = ["state": "unavailable", "reason": "programMissing"]
        object["programs"] = programs
        let report = try AgentUsageReport.decode(JSONSerialization.data(withJSONObject: object))
        let store = AgentUsageStore(hostID: UUID()) { _, _ in .available(report) }
        await store.refresh()
        for surface in [
            AnyView(VStack { AgentUsageContent(state: store.state) }),
            AnyView(AgentUsageLimitsSheet(entries: [
                AgentUsageHostEntry(id: UUID(), name: "Studio Mac", store: store, isConnected: true),
            ])),
        ] {
            let controller = UIHostingController(rootView: surface.environment(\.locale, Locale(identifier: "en_US")))
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 2_400), rootViewController: controller)
            defer { window.isHidden = true }
            var labels = ""
            var budget = PollBudget(.seconds(5))
            while budget.hasTimeLeft {
                controller.view.layoutIfNeeded()
                labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
                if labels.contains("gemini is not installed") { break }
                try await Task.sleep(for: .milliseconds(50))
                budget.charge()
            }
            #expect(labels.contains("gemini is not installed or cannot run on this Host."), "\(labels)")
            #expect(!labels.contains("Codex is not installed"))
            #expect(labels.split(separator: "\n").contains { $0 == "Codex" || $0.hasPrefix("Codex,") } == false,
                "\(labels)")
        }
    }

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

    @Test func claudeBackoffKeepsItsLastReadingAndNamesModelWindows() async throws {
        let limits = try #require(ClaudeUsageFixture.report(state: "throttled").programs?.first?.usageLimits)
        let controller = UIHostingController(rootView: AgentUsageLimitsView(program: "claude", limits: limits)
            .padding(20).frame(width: 390).environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 1_200), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
        #expect(labels.contains("Weekly · Opus"))
        #expect(labels.contains("Weekly · Sonnet"))
        #expect(labels.contains("12%"))
        #expect(labels.contains("Last reading"))
        #expect(labels.contains("Retry after"))
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

    @Test func theHostNamesWindowsByLengthAndExplainsExpiredSessionReadings() async throws {
        let report = try AgentUsageLimitFixture.report(source: "lastSession")
        let controller = UIHostingController(rootView: AgentUsageContent(state: .available(report))
            .padding(20).frame(width: 390).environment(\.locale, Locale(identifier: "en_US")))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 1_200), rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
        #expect(labels.contains("Weekly"))
        #expect(labels.contains("5-hour"))
        #expect(labels.contains("18%"))
        #expect(labels.contains("Expired · current usage unknown"))
        #expect(labels.contains("as of"))
        #expect(!labels.contains("primary"))
        #expect(!labels.contains("secondary"))
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

    @Test func windowLabelsAndUnavailableReasonsRenderWithoutExposingProtocolIds() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("usage-limits-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cases: [(String, AgentUsageReport, [String])] = [
            ("service", try AgentUsageLimitFixture.report(), ["From Codex", "Weekly", "18%"]),
            ("last-session", try AgentUsageLimitFixture.report(source: "lastSession"), ["as of", "Expired · current usage unknown"]),
            ("future-windows", try AgentUsageLimitFixture.report(windows: [
                ["id": "new-window-id", "durationMinutes": 90, "usedPercent": 32.5, "resetsAt": NSNull(), "expired": false],
                ["id": "label-id", "label": "Model window", "durationMinutes": NSNull(), "usedPercent": 5, "resetsAt": NSNull(), "expired": false],
            ]), ["90-minute", "32.5%", "Model window"]),
            ("missing", try AgentUsageLimitFixture.report(state: "unavailable", reason: "programMissing"), ["Codex is not installed or cannot run on this Host."]),
            ("too-old", try AgentUsageLimitFixture.report(state: "unavailable", reason: "programTooOld"), ["Update Codex on this Host"]),
            ("signed-out", try AgentUsageLimitFixture.report(state: "unavailable", reason: "notSignedIn"), ["Sign in to Codex on this Host"]),
            ("no-plan", try AgentUsageLimitFixture.report(state: "unavailable", reason: "noPlanLimits"), ["This sign-in has no plan Usage Limits."]),
            ("keychain", try AgentUsageLimitFixture.report(state: "unavailable", reason: "keychainUnavailable"),
             ["Codex could not use this Mac’s keychain. Start herdr from a terminal on the Mac, then refresh."]),
            ("error", try AgentUsageLimitFixture.report(state: "error", reason: "timeout"), ["Usage Limits could not be read. Try refreshing."]),
            ("disabled", try AgentUsageLimitFixture.report(state: "disabled"), ["Usage Limits are off."]),
            ("not-read-yet", try AgentUsageLimitFixture.report(state: "unavailable", reason: "notReadYet"),
             ["Reading Usage Limits…"]),
        ]
        for (name, report, expected) in cases {
            let limits = try #require(report.programs?.last?.usageLimits)
            for accessible in [false, true] {
                let controller = UIHostingController(rootView:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Codex").font(.title2.bold())
                        AgentUsageLimitsView(program: "codex", limits: limits)
                        CodexUsageLimitsNote()
                    }
                    .padding(20).frame(width: 390, alignment: .leading)
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
                let labels = AgentSurfaceReplacementTests.accessibilityLabels(in: controller.view).joined(separator: "\n")
                for text in expected { #expect(labels.contains(text), "\(name): \(text)") }
                if name == "not-read-yet" { #expect(!labels.contains("not installed")) }
                #expect(labels.contains("Codex shows only its default limit group."))
                #expect(!labels.contains("new-window-id"))
                #expect(!labels.contains("label-id"))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                    controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
                }
                #expect(image.size.width == 390)
                let filename = "\(name)-accessible-\(accessible).png"
                Attachment.record(image, named: filename, as: .png)
                try #require(image.pngData()).write(to: directory.appendingPathComponent(filename))
            }
        }
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
