import Foundation
import Testing
import UIKit

@testable import Heeler

/// Explicit opt-in live UI acceptance for Antigravity CLI model and effort
/// switching in Chat's header (`HEELER_AGY_MODEL_LIVE_CONFIG`), run through the
/// `HeelerLiveTests` scheme against an isolated disposable backend.
@MainActor
@Suite("Antigravity CLI header model switching live UI", .serialized)
struct AgyModelSwitchLiveTests {
    struct Configuration: Decodable {
        var hostID: UUID
        var paneID: String
        var screenshotDir: String?
    }

    @Test func switchesModelAndEffortFromChatHeader() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["HEELER_AGY_MODEL_LIVE_CONFIG"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(raw.utf8))

        UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
        UserDefaults.standard.set(true, forKey: "agent.back-header-expanded")

        let window = try await poll("active foreground UIWindow", timeout: .seconds(10)) { () -> UIWindow? in
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
        }

        // Wait until the Console renders the connected agy Agent row and POSIX platform check settles, then open Chat detail.
        if findTitlePill(in: window) == nil {
            let row = try await poll("disposable agy Agent row to appear in Console", timeout: .seconds(15)) { () -> NSObject? in
                accessibleElements(in: window).first {
                    ($0.accessibilityLabel ?? "").contains("demo-agy")
                }
            }
            try await Task.sleep(for: .seconds(2))
            UserDefaults.standard.set("chat", forKey: "agent.detail-surface")
            UserDefaults.standard.set(true, forKey: "agent.back-header-expanded")
            _ = row.accessibilityActivate()
        }

        let initialValue: String
        do {
            initialValue = try await poll("header pill to show initial agy model and effort", timeout: .seconds(20)) { () -> String? in
                guard let pill = findTitlePill(in: window),
                    let value = pill.accessibilityValue,
                    value.contains("Gemini 4 Carbon"),
                    value.lowercased().contains("high"),
                    findMenuButton(for: pill, in: window)?.menu != nil
                else { return nil }
                return value
            }
        } catch {
            saveWindowSnapshot(window, dir: config.screenshotDir, name: "00-debug-timeout.png")
            let summary = accessibleElements(in: window).compactMap { el -> String? in
                let id = (el as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? ""
                let label = el.accessibilityLabel ?? ""
                let val = el.accessibilityValue ?? ""
                guard !id.isEmpty || !label.isEmpty || !val.isEmpty else { return nil }
                return "[\(id)] label=\(label) value=\(val)"
            }.joined(separator: " | ")
            Issue.record("Visible elements on timeout: \(summary)")
            throw error
        }
        #expect(initialValue.contains("Gemini 4 Carbon"))
        try await Task.sleep(for: .milliseconds(350))
        saveWindowSnapshot(window, dir: config.screenshotDir, name: "01-initial-header.png")

        // Open the native SwiftUI menu on the header pill, inspect its sections, and select Claude Sonnet 5.5.
        try await selectFromHeaderMenu(
            item: "Claude Sonnet 5.5",
            in: window,
            screenshotDir: config.screenshotDir,
            openMenuScreenshot: "02-header-menu-open.png",
            expectEffortSection: true)

        _ = try await poll("header pill to confirm Claude Sonnet 5.5 (high)", timeout: .seconds(20)) { () -> String? in
            guard let value = findTitlePill(in: window)?.accessibilityValue,
                value.contains("Claude Sonnet 5.5"),
                value.lowercased().contains("high")
            else { return nil }
            return value
        }
        saveWindowSnapshot(window, dir: config.screenshotDir, name: "03-switched-sonnet-high.png")

        // Switch effort to medium from the Effort section.
        try await selectFromHeaderMenu(
            item: "medium",
            in: window,
            screenshotDir: nil,
            openMenuScreenshot: nil,
            expectEffortSection: true)

        _ = try await poll("header pill to confirm Claude Sonnet 5.5 (medium)", timeout: .seconds(20)) { () -> String? in
            guard let value = findTitlePill(in: window)?.accessibilityValue,
                value.contains("Claude Sonnet 5.5"),
                value.lowercased().contains("medium")
            else { return nil }
            return value
        }
        saveWindowSnapshot(window, dir: config.screenshotDir, name: "04-switched-sonnet-medium.png")

        // Switch to single-variant Orchestrator (Carbon), which carries no effort suffix or Effort submenu.
        try await selectFromHeaderMenu(
            item: "Orchestrator (Carbon)",
            in: window,
            screenshotDir: nil,
            openMenuScreenshot: nil,
            expectEffortSection: true)

        _ = try await poll("header pill to confirm Orchestrator (Carbon) without effort", timeout: .seconds(20)) { () -> String? in
            guard let pill = findTitlePill(in: window),
                let value = pill.accessibilityValue,
                value.contains("Orchestrator (Carbon)"),
                !value.lowercased().contains("medium")
            else { return nil }
            return value
        }
        try await verifyEffortSubmenuAbsent(in: window)
        saveWindowSnapshot(window, dir: config.screenshotDir, name: "05-single-variant-orchestrator.png")

        // Restore Gemini 4 Carbon (High) so the disposable session stays ready on its starting model.
        try await selectFromHeaderMenu(
            item: "Gemini 4 Carbon",
            in: window,
            screenshotDir: nil,
            openMenuScreenshot: nil,
            expectEffortSection: false)

        _ = try await poll("header pill to confirm Gemini 4 Carbon", timeout: .seconds(20)) { () -> String? in
            guard let value = findTitlePill(in: window)?.accessibilityValue,
                value.contains("Gemini 4 Carbon")
            else { return nil }
            return value
        }

        if let current = findTitlePill(in: window)?.accessibilityValue, !current.lowercased().contains("high") {
            try await selectFromHeaderMenu(
                item: "high",
                in: window,
                screenshotDir: nil,
                openMenuScreenshot: nil,
                expectEffortSection: true)
            _ = try await poll("header pill to restore Gemini 4 Carbon (high)", timeout: .seconds(20)) { () -> String? in
                guard let value = findTitlePill(in: window)?.accessibilityValue,
                    value.contains("Gemini 4 Carbon"),
                    value.lowercased().contains("high")
                else { return nil }
                return value
            }
        }
        try await Task.sleep(for: .seconds(1))
    }

    private func selectFromHeaderMenu(
        item: String,
        in window: UIWindow,
        screenshotDir: String?,
        openMenuScreenshot: String?,
        expectEffortSection: Bool
    ) async throws {
        let pill = try #require(findTitlePill(in: window))
        let center = CGPoint(x: pill.accessibilityFrame.midX, y: pill.accessibilityFrame.midY)
        _ = pill.accessibilityActivate()
        let opened = try await poll("the header model menu to open", timeout: .seconds(10)) { () -> (controller: UIViewController, menu: UIMenu)? in
            guard let controller = window.rootViewController?.presentedViewController,
                let button = menuButtons(in: window).first(where: {
                    UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0).contains(center)
                }),
                let menu = button.menu, !menu.children.isEmpty
            else { return nil }
            return (controller: controller, menu: menu)
        }
        if let openMenuScreenshot {
            try await Task.sleep(for: .milliseconds(350))
            saveWindowSnapshot(window, dir: screenshotDir, name: openMenuScreenshot)
        }
        if expectEffortSection {
            #expect(containsSubmenu(titled: "Effort", in: opened.menu))
        }
        let action = try #require(leaf(titled: item, in: opened.menu), "Menu did not offer \(item)")
        opened.controller.dismiss(animated: false)
        _ = try await poll("the header model menu to close", timeout: .seconds(10)) { () -> Bool? in
            window.rootViewController?.presentedViewController == nil ? true : nil
        }
        action.performWithSender(nil, target: nil)
    }

    private func verifyEffortSubmenuAbsent(in window: UIWindow) async throws {
        let pill = try #require(findTitlePill(in: window))
        let center = CGPoint(x: pill.accessibilityFrame.midX, y: pill.accessibilityFrame.midY)
        _ = pill.accessibilityActivate()
        let opened = try await poll("the header menu to open for Orchestrator", timeout: .seconds(10)) { () -> (controller: UIViewController, menu: UIMenu)? in
            guard let controller = window.rootViewController?.presentedViewController,
                let button = menuButtons(in: window).first(where: {
                    UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0).contains(center)
                }),
                let menu = button.menu, !menu.children.isEmpty
            else { return nil }
            return (controller: controller, menu: menu)
        }
        #expect(!containsSubmenu(titled: "Effort", in: opened.menu))
        opened.controller.dismiss(animated: false)
        _ = try await poll("the header menu to close", timeout: .seconds(10)) { () -> Bool? in
            window.rootViewController?.presentedViewController == nil ? true : nil
        }
    }

    private func containsSubmenu(titled title: String, in menu: UIMenu) -> Bool {
        for child in menu.children {
            guard let submenu = child as? UIMenu else { continue }
            if submenu.title == title || containsSubmenu(titled: title, in: submenu) {
                return true
            }
        }
        return false
    }

    private func findTitlePill(in root: NSObject) -> NSObject? {
        for element in accessibleElements(in: root) {
            if element.accessibilityLabel == "Agent settings" {
                return element
            }
        }
        return nil
    }

    private func findMenuButton(for element: NSObject, in window: UIWindow) -> UIButton? {
        let center = CGPoint(x: element.accessibilityFrame.midX, y: element.accessibilityFrame.midY)
        return menuButtons(in: window).first {
            UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0).contains(center)
        }
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

    private func menuButtons(in view: UIView) -> [UIButton] {
        var buttons: [UIButton] = []
        if let button = view as? UIButton, button.menu != nil { buttons.append(button) }
        for subview in view.subviews { buttons += menuButtons(in: subview) }
        return buttons
    }

    private func leaf(titled title: String, in menu: UIMenu) -> (any UIMenuLeaf)? {
        for child in menu.children {
            if let section = child as? UIMenu, let found = leaf(titled: title, in: section) { return found }
            if child.title == title, let leaf = child as? any UIMenuLeaf { return leaf }
        }
        return nil
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

    private func poll<Value>(_ what: String, timeout: Duration, _ check: () -> Value?) async throws -> Value {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let value = check() { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try #require(check(), "Timed out waiting for \(what)")
    }
}
