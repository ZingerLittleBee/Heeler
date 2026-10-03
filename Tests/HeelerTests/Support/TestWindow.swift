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
    let deadline = ContinuousClock.now + timeout
    while !isNavigationSettled(window.rootViewController), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    window.isHidden = true
}
