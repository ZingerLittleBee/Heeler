import Testing
import UIKit

@MainActor
func makeTestWindow(
    frame: CGRect,
    rootViewController: UIViewController,
    timeout: Duration = .seconds(2)
) async throws -> UIWindow {
    let deadline = ContinuousClock.now + timeout
    var windowScene: UIWindowScene?
    while windowScene == nil, ContinuousClock.now < deadline {
        windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        if windowScene == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    let window = UIWindow(
        windowScene: try #require(
            windowScene,
            "the test host should connect a window scene"))
    window.frame = frame
    window.rootViewController = rootViewController
    window.makeKeyAndVisible()
    return window
}

@MainActor
func withTestWindow(
    frame: CGRect,
    rootViewController: UIViewController,
    body: @MainActor (UIWindow) async throws -> Void
) async throws {
    let window = try await makeTestWindow(frame: frame, rootViewController: rootViewController)
    do {
        try await body(window)
    } catch {
        await hideTestWindowWhenSettled(window)
        window.rootViewController = nil
        throw error
    }
    await hideTestWindowWhenSettled(window)
    window.rootViewController = nil
}

/// No push or pop is still animating under `root`.
@MainActor
func isNavigationSettled(_ root: UIViewController?) -> Bool {
    guard let root else { return true }
    if let stack = root as? UINavigationController, stack.transitionCoordinator != nil {
        return false
    }
    return root.children.allSatisfy { isNavigationSettled($0) }
}

/// Hides `window` once its pushes and pops have finished. A window hidden
/// mid-transition leaves the scene's keyboard layout guide offset by the
/// transition, which later keyboard tests then read.
@MainActor
func hideTestWindowWhenSettled(_ window: UIWindow, timeout: Duration = .seconds(2)) async {
    var budget = PollBudget(timeout)
    while !isNavigationSettled(window.rootViewController), budget.hasTimeLeft {
        try? await Task.sleep(for: .milliseconds(10))
        budget.charge()
    }
    window.isHidden = true
}

/// Everything under `root` that accessibility reaches, in the order it walks.
/// SwiftUI containers can expose an empty or incomplete array while their
/// indexed accessibility API owns the live controls.
@MainActor
func accessibleElements(in root: NSObject) -> [NSObject] {
    var visited = Set<ObjectIdentifier>()
    var found: [NSObject] = []
    func visit(_ node: NSObject) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        found.append(node)
        for element in node.accessibilityElements ?? [] {
            if let object = element as? NSObject { visit(object) }
        }
        let count = node.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            for index in 0..<count {
                if let object = node.accessibilityElement(at: index) as? NSObject {
                    visit(object)
                }
            }
        }
        if let view = node as? UIView {
            for subview in view.subviews { visit(subview) }
        }
    }
    visit(root)
    return found
}

@MainActor
func accessibleElement(labeled label: String, in root: NSObject) -> NSObject? {
    accessibleElements(in: root).first { $0.accessibilityLabel == label }
}

/// A SwiftUI `Menu` in a hosted window. Its items exist only once it opens, so
/// these open it as the user does and read what UIKit built.
@MainActor
enum HostedMenu {
    /// What each menu labeled `label` offers, one list per menu, in the order
    /// the window lists them. Each is closed again.
    static func items(labeled label: String, in window: UIWindow) async throws -> [[String]] {
        var menus: [[String]] = []
        for element in accessibleElements(in: window) where element.accessibilityLabel == label {
            let opened = try await open(element, in: window)
            menus.append(leafTitles(of: opened.menu))
            try await close(opened.controller, in: window)
        }
        return menus
    }

    /// Runs `item` from the first menu labeled `label` that offers it, as a tap
    /// on its row does: the menu closes and the item's action runs.
    static func select(_ item: String, labeled label: String, in window: UIWindow) async throws {
        for element in accessibleElements(in: window) where element.accessibilityLabel == label {
            let opened = try await open(element, in: window)
            let leaf = leaf(titled: item, in: opened.menu)
            try await close(opened.controller, in: window)
            if let leaf {
                leaf.performWithSender(nil, target: nil)
                return
            }
        }
        Issue.record("No menu labeled \(label) offers \(item)")
    }

    private static func open(
        _ element: NSObject, in window: UIWindow
    ) async throws -> (controller: UIViewController, menu: UIMenu) {
        let label = CGPoint(x: element.accessibilityFrame.midX, y: element.accessibilityFrame.midY)
        _ = element.accessibilityActivate()
        return try await poll("the menu to open") {
            guard let controller = window.rootViewController?.presentedViewController,
                let menu = menuButtons(in: window).first(where: {
                    UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0).contains(label)
                })?.menu, !menu.children.isEmpty
            else { return nil }
            return (controller, menu)
        }
    }

    private static func close(_ presented: UIViewController, in window: UIWindow) async throws {
        presented.dismiss(animated: false)
        _ = try await poll("the menu to close") {
            window.rootViewController?.presentedViewController == nil ? true : nil
        }
    }

    private static func menuButtons(in view: UIView) -> [UIButton] {
        var buttons: [UIButton] = []
        if let button = view as? UIButton, button.menu != nil { buttons.append(button) }
        for subview in view.subviews { buttons += menuButtons(in: subview) }
        return buttons
    }

    private static func leaf(titled title: String, in menu: UIMenu) -> (any UIMenuLeaf)? {
        for child in menu.children {
            if let section = child as? UIMenu, let found = leaf(titled: title, in: section) { return found }
            if child.title == title, let leaf = child as? any UIMenuLeaf { return leaf }
        }
        return nil
    }

    private static func leafTitles(of menu: UIMenu) -> [String] {
        menu.children.flatMap { child -> [String] in
            if let section = child as? UIMenu { leafTitles(of: section) } else { [child.title] }
        }
    }

    private static func poll<Value>(_ what: String, _ value: () -> Value?) async throws -> Value {
        var budget = PollBudget(.seconds(10))
        while budget.hasTimeLeft {
            if let value = value() { return value }
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        return try #require(value(), "Timed out waiting for \(what)")
    }
}
