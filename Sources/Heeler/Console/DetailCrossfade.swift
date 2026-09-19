import SwiftUI
import UIKit

/// A dissolve over the Console detail column's content swap.
///
/// Replacing the column's screen (an Agent for a terminal, or back) rebuilds
/// a view tree around a terminal surface and moves the keyboard between
/// responders, which keeps the main thread busy for several frames. A
/// SwiftUI transition on the swap is driven from that same thread, so it
/// has no frames to draw and the switch reads as a cut. This keeps a
/// snapshot of the leaving screen over the window while the arriving one
/// is built, then fades it out with a Core Animation animation the render
/// server runs whether or not the main thread is free.
///
/// The whole window is covered, not just the column: the sidebar next to
/// it on iPad changes only its selection mark, which dissolves with the
/// rest, and covering it needs no view in the column to measure — an extra
/// layer around the detail content changed the order the leaving and
/// arriving surfaces move through the window in, and cost the keyboard
/// handoff. The keyboard itself lives in its own window above this one and
/// is untouched.
///
/// `beginSwap(in:)` goes with the selection change; the arriving screen
/// calls `contentDidAppear()` once its surface is in the window, and a
/// fallback reveals the window anyway when nothing reports in (a failure
/// or a missing-Agent placeholder).
@MainActor
final class DetailCrossfade {
    static let duration: TimeInterval = 0.22
    static let revealFallback: Duration = .milliseconds(700)

    private(set) var cover: UIView?
    private var fallback: Task<Void, Never>?

    func beginSwap(in window: UIWindow) {
        discardCover()
        // The last presented frame: the state change this accompanies has
        // not been committed yet, so this is the leaving screen.
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return }
        let cover = UIView(frame: window.bounds)
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        snapshot.frame = cover.bounds
        cover.addSubview(snapshot)
        window.addSubview(cover)
        self.cover = cover
        fallback = Task { [weak self] in
            try? await Task.sleep(for: Self.revealFallback)
            guard !Task.isCancelled else { return }
            self?.reveal()
        }
    }

    func contentDidAppear() {
        reveal()
    }

    private func reveal() {
        fallback?.cancel()
        fallback = nil
        guard let cover else { return }
        self.cover = nil
        UIView.animate(
            withDuration: Self.duration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    private func discardCover() {
        fallback?.cancel()
        fallback = nil
        cover?.removeFromSuperview()
        cover = nil
    }
}

extension EnvironmentValues {
    /// The dissolve over the Console detail column, for the screens shown
    /// there to report when their content is up. Nil elsewhere.
    @Entry var detailCrossfade: DetailCrossfade? = nil
}
