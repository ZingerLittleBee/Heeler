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
