import GhosttyTerminal
import Testing
import UIKit

@testable import Heeler

/// The ghostty surface parks an `IOSurfaceLayer` sublayer inside the terminal
/// view's layer. That layer is a CALayer subclass whose `display` override
/// calls back into the surface's renderer through a raw context pointer, so a
/// layer that outlives its surface keeps a dangling pointer: the next Core
/// Animation commit that touches it (any bounds change schedules display) calls
/// straight into freed renderer memory. On device this is the PAC trap in
/// `object_getClass` under `CA::Context::commit_transaction`.
///
/// The package frees the surface in `didMoveToWindow(nil)` — every SwiftUI
/// presentation or navigation that pulls the hierarchy out of the window hits
/// this path — so no content layer may survive a detach, and a detach/reattach
/// cycle must not accumulate layers.
@MainActor
struct TerminalSurfaceOrphanLayerTests {
    private static let ghosttyContentLayerClass = "IOSurfaceLayer"

    private func ghosttyContentLayers(of view: UIView) -> [CALayer] {
        (view.layer.sublayers ?? []).filter {
            NSStringFromClass(type(of: $0)) == Self.ghosttyContentLayerClass
        }
    }

    private func waitForContentLayer(
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

    @Test func freeingTheSurfaceOnWindowDetachLeavesNoOrphanContentLayer() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view.addSubview(terminal)
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        try await waitForContentLayer(in: terminal)

        terminal.removeFromSuperview()
        await Task.yield()

        #expect(
            ghosttyContentLayers(of: terminal).isEmpty,
            "a content layer that outlives its freed surface keeps a dangling renderer pointer")
    }

    @Test func detachReattachCycleDoesNotAccumulateContentLayers() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view.addSubview(terminal)
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        try await waitForContentLayer(in: terminal)

        terminal.removeFromSuperview()
        await Task.yield()
        controller.view.addSubview(terminal)
        try await waitForContentLayer(in: terminal)

        #expect(
            ghosttyContentLayers(of: terminal).count == 1,
            "each detach/reattach must replace the content layer, not stack orphans")
    }

    @Test func themePreviewAlsoDropsItsContentLayerOnWindowDetach() async throws {
        let palette = TerminalThemeOption.followSystem.configuration(isDark: false)
        let preview = TerminalThemePreviewView(
            theme: TerminalTheme(light: palette, dark: palette), fontSize: 13)
        preview.frame = CGRect(x: 0, y: 0, width: 390, height: 240)
        let controller = UIViewController()
        controller.view.addSubview(preview)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 720),
            rootViewController: controller)
        defer { window.isHidden = true }

        try await waitForContentLayer(in: preview)

        preview.removeFromSuperview()
        await Task.yield()

        #expect(ghosttyContentLayers(of: preview).isEmpty)
    }
}
