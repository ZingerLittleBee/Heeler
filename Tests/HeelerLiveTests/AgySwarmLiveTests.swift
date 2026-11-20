import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Operator-authorized end-to-end verification against a disposable live
/// Antigravity CLI Swarm pane on the local Herdr TUI server. Skipped unless
/// `HEELER_SWARM_LIVE_PANE` is set in the Simulator's launchd environment.
@MainActor
@Suite("Antigravity CLI Swarm live verification", .serialized)
struct AgySwarmLiveTests {
    @Test func verifiesLiveSwarmChatUIAndCapturesScreens() async throws {
        guard let paneID = ProcessInfo.processInfo.environment["HEELER_SWARM_LIVE_PANE"],
            !paneID.isEmpty
        else { return }

        let rowQuery = ProcessInfo.processInfo.environment["HEELER_SWARM_LIVE_ROW"] ?? "agy-swarm-qa"
        let outputDir = ProcessInfo.processInfo.environment["HEELER_SWARM_CAPTURE_DIR"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
        UserDefaults.standard.set(true, forKey: "agent.back-header-expanded")

        let window = try await poll("active foreground UIWindow", timeout: .seconds(10)) { () -> UIWindow? in
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }

        // 1. Open the disposable Swarm Agent row in Console if not already inside its Chat surface.
        if findSwarmBar(in: window) == nil {
            let row = try await poll("disposable Swarm Agent row (\(rowQuery)) in Console", timeout: .seconds(20)) { () -> NSObject? in
                accessibleElements(in: window).first {
                    ($0.accessibilityLabel ?? "").contains(rowQuery)
                }
            }
            try await Task.sleep(for: .seconds(1.5))
            UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
            _ = row.accessibilityActivate()
        }

        // 2. Wait for the Swarm Live Bar (`Swarm: Heeler Swarm QA`) to resolve over live SSH/SFTP,
        // including walking from a worker/monitor `agent_session` back to the coordinator!
        let swarmBar: NSObject
        do {
            swarmBar = try await poll("ChatSwarmLiveBar above Composer", timeout: .seconds(25)) { () -> NSObject? in
                findSwarmBar(in: window)
            }
        } catch {
            saveWindowSnapshot(window, dir: outputDir, name: "live-00-debug-timeout.png")
            let summary = accessibleElements(in: window).compactMap { el -> String? in
                let label = el.accessibilityLabel ?? ""
                let val = el.accessibilityValue ?? ""
                guard !label.isEmpty || !val.isEmpty else { return nil }
                return "label=\(label) value=\(val)"
            }.joined(separator: " | ")
            Issue.record("Visible elements on timeout: \(summary)")
            throw error
        }

        #expect((swarmBar.accessibilityLabel ?? "").contains("Heeler Swarm QA"))
        #expect((swarmBar.accessibilityValue ?? "").contains("#"))
        try await Task.sleep(for: .milliseconds(600))
        saveWindowSnapshot(window, dir: outputDir, name: "live-01-chatui-swarm-bar.png")

        // 3. Tap the Swarm Live Bar to open the native 3-tab Swarm Sheet on Board!
        _ = swarmBar.accessibilityActivate()
        let presented = try await poll("ChatSwarmSheet presentation", timeout: .seconds(10)) { () -> UIViewController? in
            findPresentedViewController(from: window.rootViewController)
        }
        _ = try await poll("Board posts in ChatSwarmSheet", timeout: .seconds(10)) { () -> Bool? in
            let labels = accessibleElements(in: presented.view).compactMap(\.accessibilityLabel).joined(separator: " ")
            return labels.contains("parser-audit") ? true : nil
        }
        try await Task.sleep(for: .milliseconds(500))
        saveWindowSnapshot(window, dir: outputDir, name: "live-02-sheet-board.png")

        // 4. Switch segmented control to Overview (index 2) and capture!
        let segmented = try #require(findSegmentedControl(in: presented.view), "Missing segmented Picker in ChatSwarmSheet")
        segmented.selectedSegmentIndex = 2
        segmented.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(600))
        saveWindowSnapshot(window, dir: outputDir, name: "live-04-sheet-overview.png")

        // 5. Switch segmented control to Members (index 1), verify @parser-audit & @ui-audit, and capture!
        segmented.selectedSegmentIndex = 1
        segmented.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(500))
        let parserMember = try await poll("@parser-audit card in Members tab", timeout: .seconds(10)) { () -> NSObject? in
            accessibleElements(in: presented.view).first {
                let label = $0.accessibilityLabel ?? ""
                return label.contains("@parser-audit") && label.contains("steps")
            }
        }
        saveWindowSnapshot(window, dir: outputDir, name: "live-03-sheet-members.png")

        // 6. Tap @parser-audit to push read-only Worker sub-conversation detail view over live SFTP!
        _ = parserMember.accessibilityActivate()
        _ = try await poll("ChatSwarmWorkerDetailView transcript entries", timeout: .seconds(15)) { () -> Bool? in
            let labels = accessibleElements(in: presented.view).compactMap(\.accessibilityLabel).joined(separator: " ")
            return (labels.contains("Read-only view") && !labels.contains("Loading worker conversation")) ? true : nil
        }
        try await Task.sleep(for: .milliseconds(700))
        saveWindowSnapshot(window, dir: outputDir, name: "live-05-worker-detail.png")

        presented.dismiss(animated: false)
        _ = try await poll("ChatSwarmSheet dismissal", timeout: .seconds(10)) { () -> Bool? in
            findPresentedViewController(from: window.rootViewController) == nil ? true : nil
        }

        // 7. Verify live `w4X:p4` screen parsing + SFTP Swarm snapshot invariants directly via ConsoleStore!
        let hostStore = HostStore()
        let console = ConsoleStore(chatCache: VolatileChatTranscriptCache())
        console.setHosts(hostStore.hosts, hostsOutOfSight: hostStore.hostsOutOfSight)
        await console.resume()
        defer {
            Task { await console.suspend() }
        }

        let liveAgent = try await poll("ConsoleStore pane \(paneID)", timeout: .seconds(15)) { () -> ConsoleAgent? in
            console.agents.first(where: { $0.agent.paneID == paneID })
        }

        // Read the real live ANSI terminal screen of `w4X:p4` while `● Swarm(Heeler Swarm QA)` strip is visible!
        let ansiScreen = try await console.readAgentScreen(paneID, on: liveAgent.hostID)
        let screenState = InputBoxStateDetector.detect(ansiScreen, program: .agy)
        let isEmptyBox: Bool
        if case .empty = screenState { isEmptyBox = true } else { isEmptyBox = false }
        #expect(isEmptyBox, "Swarm strip below input box must not block ChatUI pre-send gate: got \(screenState)")
        #expect(!AgyScreen(ansiScreen).showsRunningTasks, "Swarm strip must not be miscounted as a /tasks background command")

        let chat = try #require(console.chatStore(for: liveAgent, program: .agy))
        chat.show()
        defer { chat.hide() }

        let swarm = try await poll("live AgySwarmSnapshot from SFTP", timeout: .seconds(15)) { () -> AgySwarmSnapshot? in
            guard let snap = chat.agySwarm, !snap.members.isEmpty, snap.postCount >= 4 else { return nil }
            return snap
        }
        #expect(swarm.displayTitle == "Heeler Swarm QA")
        #expect(swarm.taskWorkers.count == 2)
        #expect(!swarm.taskWorkers.contains(where: { $0.name == "monitor" || $0.name == "coordinator" }))

        // 8. Capture active-working + condensed ChatSwarmLiveBar variants from the live snapshot!
        var activeCopy = swarm
        if let idx = activeCopy.members.firstIndex(where: { $0.name == "parser-audit" }) {
            activeCopy.members[idx].status = .working
            activeCopy.members[idx].activity = "Read AgySwarm.swift"
        }
        try await captureHosted(
            VStack(spacing: 12) {
                ChatSwarmLiveBar(swarm: activeCopy, isCondensed: false, open: {})
                ChatSwarmLiveBar(swarm: activeCopy, isCondensed: true, open: {})
            }
            .padding(.vertical, 16)
            .background(Color(uiColor: .systemBackground)),
            in: window.windowScene,
            size: CGSize(width: 402, height: 180),
            to: "\(outputDir)/live-06-swarm-bars-active-and-condensed.png")
    }

    private func findSwarmBar(in root: NSObject) -> NSObject? {
        accessibleElements(in: root).first {
            ($0.accessibilityLabel ?? "").hasPrefix("Swarm: Heeler Swarm QA")
        }
    }

    private func findPresentedViewController(from root: UIViewController?) -> UIViewController? {
        guard let root else { return nil }
        if let presented = root.presentedViewController {
            return findPresentedViewController(from: presented) ?? presented
        }
        for child in root.children {
            if let found = findPresentedViewController(from: child) {
                return found
            }
        }
        return nil
    }

    private func findSegmentedControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl { return control }
        for subview in view.subviews {
            if let found = findSegmentedControl(in: subview) { return found }
        }
        return nil
    }

    private func accessibleElements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var stack: [NSObject] = [root]
        while let current = stack.popLast() {
            if current.isAccessibilityElement { result.append(current) }
            if let elements = current.accessibilityElements as? [NSObject] {
                stack.append(contentsOf: elements.reversed())
            }
            if let view = current as? UIView {
                stack.append(contentsOf: view.subviews.reversed())
            }
        }
        return result
    }

    private func saveWindowSnapshot(_ window: UIWindow, dir: String?, name: String) {
        guard let dir else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let windows = (window.windowScene?.windows ?? [window])
            .filter { !$0.isHidden && $0.alpha > 0 }
            .sorted { $0.windowLevel < $1.windowLevel }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            for candidate in windows {
                _ = candidate.drawHierarchy(in: candidate.bounds, afterScreenUpdates: true)
            }
        }
        if let png = image.pngData() {
            try? png.write(to: folder.appendingPathComponent(name))
        }
    }

    private func captureHosted<V: View>(
        _ rootView: V,
        in scene: UIWindowScene?,
        size: CGSize,
        to path: String
    ) async throws {
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        let controller = UIHostingController(rootView: rootView)
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size), format: format)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let png = try #require(image.pngData())
        try png.write(to: URL(fileURLWithPath: path))
    }

    private func poll<Value>(_ what: String, timeout: Duration, _ check: () -> Value?) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let value = check() { return value }
            try await Task.sleep(for: .milliseconds(150))
        }
        return try #require(check(), "Timed out waiting for \(what)")
    }
}
