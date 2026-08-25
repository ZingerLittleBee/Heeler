import Testing
import UIKit

/// ghostty parks its rendering content in an `IOSurfaceLayer` sublayer of the
/// terminal view; its presence is the observable sign that a live surface
/// exists (see `TerminalSurfaceOrphanLayerTests`).
@MainActor
func ghosttyContentLayers(of view: UIView) -> [CALayer] {
    (view.layer.sublayers ?? []).filter {
        NSStringFromClass(type(of: $0)) == "IOSurfaceLayer"
    }
}

@MainActor
func waitForGhosttyContentLayer(
    in view: UIView,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ghosttyContentLayers(of: view).isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
        !ghosttyContentLayers(of: view).isEmpty,
        "the surface should park its content layer after attaching to a window")
}
