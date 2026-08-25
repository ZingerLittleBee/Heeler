import GhosttyTerminal
import Testing
import UIKit

@testable import Heeler

/// The ghostty surface parks an `IOSurfaceLayer` sublayer inside the terminal
/// view's layer. That layer is a CALayer subclass whose `display` override
/// calls back into the surface's renderer through a raw context pointer, and
/// nothing on ghostty's teardown path removes it from the tree — so a layer
/// that outlives its freed surface keeps a dangling pointer, and the next
/// Core Animation commit that touches it jumps into freed renderer memory.
/// On device this was the PAC trap in `object_getClass` under
/// `CA::Context::commit_transaction` (#242).
///
/// GhosttyTerminal 1.4.0 keeps the surface across temporary window detaches
/// (a SwiftUI presentation pulling the hierarchy out of the window no longer
/// frees it), so the orphan-producing path left is the in-place surface
/// rebuild — assigning a new controller or non-equivalent configuration —
/// which tears the old surface down while the view stays alive. Heeler
/// removes the orphans from `terminalDidDetachSurface()`.
@MainActor
struct TerminalSurfaceOrphanLayerTests {
    /// Upstream's fix for the empty-terminal-after-cover bug: a temporary
    /// window detach must keep the surface, so its content layer stays too.
    /// Guards against reintroducing cleanup in `didMoveToWindow(nil)`, which
    /// would blank a live terminal behind every presentation.
    @Test func aTemporaryWindowDetachKeepsTheLiveSurfaceLayer() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view.addSubview(terminal)
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        try await waitForGhosttyContentLayer(in: terminal)

        terminal.removeFromSuperview()
        await Task.yield()

        #expect(ghosttyContentLayers(of: terminal).count == 1)
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

        try await waitForGhosttyContentLayer(in: terminal)

        terminal.removeFromSuperview()
        await Task.yield()
        controller.view.addSubview(terminal)
        try await waitForGhosttyContentLayer(in: terminal)

        #expect(ghosttyContentLayers(of: terminal).count == 1)
    }

    /// The orphan-producing path on 1.4.0: an in-place rebuild frees the old
    /// surface while the view stays in the window. Without the
    /// `terminalDidDetachSurface()` cleanup the old content layer stacks
    /// under the new one, dangling renderer pointer and all.
    @Test func anInPlaceSurfaceRebuildLeavesNoOrphanContentLayer() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view.addSubview(terminal)
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }

        try await waitForGhosttyContentLayer(in: terminal)

        terminal.controller = TerminalController(theme: .default)
        try await waitForGhosttyContentLayer(in: terminal)

        #expect(ghosttyContentLayers(of: terminal).count == 1)
    }

    @Test func themePreviewRebuildAlsoLeavesNoOrphanContentLayer() async throws {
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

        try await waitForGhosttyContentLayer(in: preview)

        preview.controller = TerminalController(theme: .default)
        try await waitForGhosttyContentLayer(in: preview)

        #expect(ghosttyContentLayers(of: preview).count == 1)
    }
}
