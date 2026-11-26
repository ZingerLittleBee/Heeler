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

    @Test func verifiesWorkerScrollRoundTripAndBriefAssignment() async throws {
        guard let paneID = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_LIVE_PANE"],
            !paneID.isEmpty
        else { return }

        let rowQuery = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_LIVE_ROW"] ?? ""
        let workerName = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_LIVE_WORKER"] ?? "frontend-builder"
        let expectedBriefSeq = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_EXPECTED_BRIEF_SEQ"].flatMap(Int.init)
        let smoothDemo = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_SMOOTH_DEMO"] == "1"
        let outputDir = ProcessInfo.processInfo.environment["HEELER_SWARM_SCROLL_CAPTURE_DIR"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
        UserDefaults.standard.set(true, forKey: "agent.back-header-expanded")

        let window = try await poll("active foreground UIWindow", timeout: .seconds(10)) { () -> UIWindow? in
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }

        // 1. Open the target Swarm Agent row in Console if not already inside its Chat surface.
        if findAnySwarmBar(in: window) == nil {
            let row = try await poll("Swarm Agent row (\(rowQuery)) in Console", timeout: .seconds(25)) { () -> NSObject? in
                accessibleElements(in: window).first { el in
                    let label = el.accessibilityLabel ?? ""
                    guard !rowQuery.isEmpty else { return label.contains("Antigravity") }
                    return label.contains(rowQuery)
                }
            }
            try await Task.sleep(for: .milliseconds(800))
            UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
            _ = row.accessibilityActivate()
        }

        // 2. Wait for the Swarm Live Bar to resolve over live SSH/SFTP and open the Swarm Sheet.
        let swarmBar = try await poll("ChatSwarmLiveBar", timeout: .seconds(25)) { () -> NSObject? in
            findAnySwarmBar(in: window)
        }
        try await Task.sleep(for: .milliseconds(400))
        _ = swarmBar.accessibilityActivate()

        let presented = try await poll("ChatSwarmSheet presentation", timeout: .seconds(10)) { () -> UIViewController? in
            findPresentedViewController(from: window.rootViewController)
        }
        let boardCollection = try await poll("Swarm Board collection view", timeout: .seconds(10)) { () -> UICollectionView? in
            findCollectionView(in: presented.view, identifier: "chat.swarm.board.list")
        }
        _ = try await poll("Swarm Board rows populated", timeout: .seconds(10)) { () -> Bool? in
            boardCollection.numberOfSections > 0 && boardCollection.numberOfItems(inSection: 0) >= 2 ? true : nil
        }
        try await Task.sleep(for: .milliseconds(500))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-01-board-bottom.png")

        // Scroll Board to top to verify #1/#2 brief recipients and scroll round-trip cell configuration.
        await scrollCollection(boardCollection, toY: -boardCollection.adjustedContentInset.top, smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 1_200 : 450))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-01b-board-top.png")
        assertAllVisibleCellsConfigured(in: boardCollection, stage: "board top")

        if let expectedBriefSeq,
            let expectedPost = accessibleElements(in: boardCollection).first(where: {
                accessibilityID(of: $0) == "chat.swarm.post.\(expectedBriefSeq)"
            })
        {
            #expect((expectedPost.accessibilityLabel ?? "").contains("→ @\(workerName)"))
        }

        // 3. Switch to Members tab and open the target worker detail view.
        let segmented = try #require(findSegmentedControl(in: presented.view), "Missing segmented Picker in ChatSwarmSheet")
        segmented.selectedSegmentIndex = 1
        segmented.sendActions(for: .valueChanged)
        let memberRow = try await poll("@\(workerName) row in Members", timeout: .seconds(10)) { () -> NSObject? in
            accessibleElements(in: presented.view).first {
                let label = $0.accessibilityLabel ?? ""
                return label.contains("@\(workerName)") && label.contains("steps")
            }
        }
        try await Task.sleep(for: .milliseconds(smoothDemo ? 900 : 400))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-02-members.png")

        _ = memberRow.accessibilityActivate()
        let workerCollection = try await poll("Worker collection view", timeout: .seconds(15)) { () -> UICollectionView? in
            findCollectionView(in: window, identifier: "chat.swarm.worker.\(workerName)")
        }
        _ = try await poll("Worker transcript loaded", timeout: .seconds(15)) { () -> Bool? in
            guard workerCollection.numberOfSections > 0, workerCollection.numberOfItems(inSection: 0) >= 4 else {
                return nil
            }
            let labels = accessibleElements(in: workerCollection).compactMap(\.accessibilityLabel).joined(separator: " ")
            return !labels.contains("Loading worker conversation") ? true : nil
        }
        try await Task.sleep(for: .milliseconds(smoothDemo ? 900 : 600))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-03-worker-initial-bottom.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "initial bottom")

        // 4. Scroll all the way to the top: header + correct Assignment must both be visible and configured.
        await scrollCollection(workerCollection, toY: -workerCollection.adjustedContentInset.top, smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 1_100 : 400))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-04-worker-top.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "first scroll to top")

        let topLabels = accessibleElements(in: workerCollection).compactMap(\.accessibilityLabel).joined(separator: " | ")
        #expect(topLabels.contains("Read-only view"), "Worker header must remain rendered after scrolling up")
        if let expectedBriefSeq {
            #expect(
                topLabels.contains("Assignment (#\(expectedBriefSeq))"),
                "Expected Assignment (#\(expectedBriefSeq)) for @\(workerName), got: \(topLabels.prefix(300))")
        }

        // 5. Scroll down past header & assignment (triggering didEndDisplaying) and back to top.
        let maxY = max(
            -workerCollection.adjustedContentInset.top,
            workerCollection.contentSize.height + workerCollection.adjustedContentInset.bottom - workerCollection.bounds.height)
        await scrollCollection(
            workerCollection,
            toY: smoothDemo ? min(maxY, -workerCollection.adjustedContentInset.top + 950) : maxY,
            smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 600 : 350))
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "scrolled back to bottom")

        await scrollCollection(workerCollection, toY: -workerCollection.adjustedContentInset.top, smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 900 : 350))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-05-worker-top-after-roundtrip.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "top after offscreen round-trip")
        let roundTripTopLabels = accessibleElements(in: workerCollection).compactMap(\.accessibilityLabel).joined(separator: " | ")
        #expect(roundTripTopLabels.contains("Read-only view"), "Header vanished after offscreen round-trip")

        // 6. Expand the Assignment card, scroll all the way past it to bottom, then scroll back through it to top.
        let assignmentButton = try #require(
            accessibleElements(in: workerCollection).first {
                ($0.accessibilityLabel ?? "").contains("Assignment (#")
            },
            "Missing Assignment disclosure button at top of worker view")
        _ = assignmentButton.accessibilityActivate()
        try await Task.sleep(for: .milliseconds(smoothDemo ? 1_100 : 500))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-06-assignment-expanded.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "after expanding assignment")

        let expandedMaxY = max(
            -workerCollection.adjustedContentInset.top,
            workerCollection.contentSize.height + workerCollection.adjustedContentInset.bottom - workerCollection.bounds.height)
        await scrollCollection(
            workerCollection,
            toY: smoothDemo ? min(expandedMaxY, -workerCollection.adjustedContentInset.top + 2_200) : expandedMaxY,
            smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 700 : 400))
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "bottom past expanded assignment")

        let midAssignmentY = min(expandedMaxY, -workerCollection.adjustedContentInset.top + 420)
        await scrollCollection(workerCollection, toY: midAssignmentY, smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 1_000 : 400))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-07-expanded-mid-after-roundtrip.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "mid expanded assignment after round-trip")

        await scrollCollection(workerCollection, toY: -workerCollection.adjustedContentInset.top, smooth: smoothDemo)
        try await Task.sleep(for: .milliseconds(smoothDemo ? 1_200 : 400))
        saveWindowSnapshot(window, dir: outputDir, name: "verify-08-expanded-top-after-roundtrip.png")
        assertAllVisibleCellsConfigured(in: workerCollection, stage: "top expanded assignment after round-trip")

        presented.dismiss(animated: false)
        _ = try await poll("ChatSwarmSheet dismissal", timeout: .seconds(10)) { () -> Bool? in
            findPresentedViewController(from: window.rootViewController) == nil ? true : nil
        }

        // 7. Also assert live snapshot model directly via ConsoleStore for the target pane.
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
        let chat = try #require(console.chatStore(for: liveAgent, program: .agy))
        chat.show()
        defer { chat.hide() }
        let swarm = try await poll("live AgySwarmSnapshot", timeout: .seconds(15)) { () -> AgySwarmSnapshot? in
            guard let snap = chat.agySwarm, !snap.members.isEmpty, snap.postCount >= 2 else { return nil }
            return snap
        }
        if let expectedBriefSeq {
            let assignment = swarm.assignmentPost(for: workerName)
            #expect(assignment?.seq == expectedBriefSeq)
            #expect(assignment?.recipientSummary?.contains("@\(workerName)") == true)
        }
    }

    private func accessibilityID(of object: NSObject) -> String? {
        (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

    private func findAnySwarmBar(in root: NSObject) -> NSObject? {
        accessibleElements(in: root).first {
            let id = accessibilityID(of: $0)
            return id == "chat.swarm.bar"
                || id == "chat.swarm.summary"
                || ($0.accessibilityLabel ?? "").hasPrefix("Swarm:")
        }
    }

    private func findCollectionView(in view: UIView, identifier: String) -> UICollectionView? {
        if let cv = view as? UICollectionView, cv.accessibilityIdentifier == identifier {
            return cv
        }
        for subview in view.subviews {
            if let found = findCollectionView(in: subview, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private func scrollCollection(_ collectionView: UICollectionView, toY y: CGFloat, smooth: Bool = false) async {
        collectionView.delegate?.scrollViewWillBeginDragging?(collectionView)
        if smooth {
            let startY = collectionView.contentOffset.y
            let steps = 36
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let targetY = startY + (y - startY) * eased
                let minY = -collectionView.adjustedContentInset.top
                let maxY = max(
                    minY,
                    collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
                        - collectionView.bounds.height)
                collectionView.setContentOffset(CGPoint(x: 0, y: min(max(targetY, minY), maxY)), animated: false)
                collectionView.layoutIfNeeded()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        collectionView.layoutIfNeeded()
        // A second pass after newly realized cells self-size settles at the exact target offset.
        let clamped = min(
            max(y, -collectionView.adjustedContentInset.top),
            max(
                -collectionView.adjustedContentInset.top,
                collectionView.contentSize.height + collectionView.adjustedContentInset.bottom - collectionView.bounds.height))
        collectionView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
        collectionView.layoutIfNeeded()
        collectionView.delegate?.scrollViewDidEndDragging?(collectionView, willDecelerate: false)
    }

    private func assertAllVisibleCellsConfigured(in collectionView: UICollectionView, stage: String) {
        let visible = collectionView.visibleCells
        #expect(!visible.isEmpty, "Expected visible cells at stage '\(stage)'")
        for cell in visible {
            #expect(
                cell.contentConfiguration != nil,
                "Visible cell had nil contentConfiguration at stage '\(stage)'")
        }
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
