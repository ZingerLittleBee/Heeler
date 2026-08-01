import SwiftUI
import UIKit

/// The terminal's own keyboard avoidance.
///
/// SwiftUI's built-in avoidance retracts its inset in two stages: the software
/// keyboard's own height goes first, and the input accessory's follows about a
/// third of a second later, once UIKit has torn the accessory down. Ghostty
/// sizes its grid from the view's bounds, so each dismissal cost two grid
/// changes — two reflows, two PTY resizes, and a second full-screen TUI redraw
/// that landed well after the keyboard had already gone. Reading the
/// keyboard's frame directly settles the height in one step.
///
/// A dismissal is the case that has to be exact, and it is also the
/// unambiguous one: the keyboard is leaving, so the inset is zero, whatever
/// UIKit still has on screen. A presentation may well arrive in two
/// notifications (the accessory is measured after the keyboard itself), which
/// is why those coalesce — the terminal must not resize twice on the way up
/// either, and nobody can see the difference while the keyboard covers that
/// edge anyway.
@MainActor
@Observable
final class TerminalKeyboardInset {
    /// How much of the terminal's bottom edge the keyboard stack covers.
    private(set) var height: CGFloat = 0
    /// Long enough to fold a presentation's follow-up frame into the first,
    /// short enough to stay inside the keyboard's own animation.
    private static let coalesceDelay = Duration.milliseconds(60)
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private let measure: @MainActor (CGRect) -> CGFloat?

    init(
        notificationCenter: NotificationCenter = .default,
        measure: @escaping @MainActor (CGRect) -> CGFloat? = {
            TerminalKeyboardInset.coveredHeight(of: $0)
        }
    ) {
        self.measure = measure
        for name: Notification.Name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
        ] {
            notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                // Notification is not Sendable; the frame it carries is.
                let endFrame = notification.userInfo?[
                    UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                MainActor.assumeIsolated {
                    self?.keyboardWillPresent(endFrame: endFrame)
                }
            }
        }
        notificationCenter.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardWillDismiss()
            }
        }
    }

    private func keyboardWillPresent(endFrame: CGRect?) {
        guard let endFrame, let height = measure(endFrame), height > 0 else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
    }

    private func keyboardWillDismiss() {
        coalesceTask?.cancel()
        coalesceTask = nil
        apply(0)
    }

    private func apply(_ height: CGFloat) {
        coalesceTask = nil
        guard height != self.height else { return }
        self.height = height
    }

    /// How far the keyboard's end frame reaches above the terminal's own
    /// bottom edge. Keyboard frames are published in screen coordinates, which
    /// differ from the window's under split view and Stage Manager, and they
    /// are measured from the very bottom of the screen — while the terminal
    /// stops at the home indicator. Subtracting that safe area is what keeps
    /// the last row against the toolbar instead of a strip of background.
    static func coveredHeight(of endFrame: CGRect) -> CGFloat? {
        guard
            let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .keyWindow
        else { return nil }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return insetHeight(
            covered: window.bounds.intersection(frameInWindow).height,
            bottomSafeArea: window.safeAreaInsets.bottom)
    }

    nonisolated static func insetHeight(covered: CGFloat, bottomSafeArea: CGFloat) -> CGFloat {
        max(0, covered - bottomSafeArea)
    }
}

extension View {
    /// Sizes this view to the keyboard directly, instead of through SwiftUI's
    /// two-stage avoidance. See ``TerminalKeyboardInset``.
    func terminalKeyboardInset(_ inset: TerminalKeyboardInset) -> some View {
        padding(.bottom, inset.height)
            .ignoresSafeArea(.keyboard)
    }
}
