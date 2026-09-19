import Foundation
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Detail crossfade")
struct DetailCrossfadeTests {
    /// A window with a presented frame: the cover is a snapshot of the last
    /// one, and a window that has never rendered has none to give.
    private func makeWindow() async throws -> UIWindow {
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            rootViewController: UIViewController())
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return window
    }

    /// The cover fills the window, sits over it, and leaves once the
    /// arriving screen reports its content is up.
    @Test func aSwapCoversTheWindowUntilTheContentAppears() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let crossfade = DetailCrossfade()
        crossfade.beginSwap(in: window)
        let cover = try #require(crossfade.cover)
        #expect(cover.superview === window)
        #expect(cover.frame == window.bounds)
        #expect(!cover.isUserInteractionEnabled)
        #expect(cover.alpha == 1)

        crossfade.contentDidAppear()
        #expect(crossfade.cover == nil, "a second report must not touch the fade")
        try await Task.sleep(for: .milliseconds(400))
        #expect(cover.superview == nil)
    }

    /// A screen that never reports (a failure, a placeholder) still gets
    /// revealed: the cover is not allowed to stick.
    @Test func aSwapNobodyReportsOnRevealsByItself() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let crossfade = DetailCrossfade()
        crossfade.beginSwap(in: window)
        let cover = try #require(crossfade.cover)
        try await Task.sleep(for: DetailCrossfade.revealFallback + .milliseconds(400))
        #expect(cover.superview == nil)
        #expect(crossfade.cover == nil)
    }

    /// A swap arriving during another replaces the cover outright rather
    /// than stacking a second one.
    @Test func aSwapDuringASwapReplacesTheCover() async throws {
        let window = try await makeWindow()
        defer { window.isHidden = true }
        let crossfade = DetailCrossfade()
        crossfade.beginSwap(in: window)
        let first = try #require(crossfade.cover)
        crossfade.beginSwap(in: window)
        let second = try #require(crossfade.cover)
        #expect(first !== second)
        #expect(first.superview == nil)
        #expect(second.superview === window)
        crossfade.contentDidAppear()
    }

    /// A report with nothing pending is a no-op.
    @Test func aReportWithoutASwapDoesNothing() {
        let crossfade = DetailCrossfade()
        crossfade.contentDidAppear()
        #expect(crossfade.cover == nil)
    }
}
