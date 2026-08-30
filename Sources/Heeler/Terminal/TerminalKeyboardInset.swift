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
    /// The last complete keyboard footprint. It survives dismissal so an
    /// in-app keyboard can replace UIKit's keyboard without changing layout.
    private(set) var lastPresentedHeight: CGFloat = 0
    /// Long enough to fold a presentation's follow-up frame into the first,
    /// short enough to stay inside the keyboard's own animation.
    private static let coalesceDelay = Duration.milliseconds(60)
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private let measure: @MainActor (CGRect) -> CGFloat?
    @ObservationIgnored private var capturesPresentedHeight = true
    /// Composer-to-terminal responder handoff can publish transient show,
    /// change-frame, and even hide notifications while the software keyboard
    /// never visibly leaves. Keep the last settled footprint until the new
    /// terminal confirms that its own keyboard frame settled.
    private(set) var activeResponderHandoffID: UUID?
    @ObservationIgnored private var responderHandoffFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var sawDismissDuringResponderHandoff = false
    @ObservationIgnored var responderHandoffFallbackDelay = Duration.milliseconds(500)
    /// The destination terminal owns the primary 500ms timeout. This later
    /// owner-side watchdog exists only for a destination that is deallocated
    /// before its weakly captured timeout can report an outcome.
    @ObservationIgnored var destinationResponderHandoffFallbackDelay = Duration.seconds(1)

    var isHoldingHandoffHeight: Bool { activeResponderHandoffID != nil }

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
        guard !isHoldingHandoffHeight else { return }
        guard capturesPresentedHeight else { return }
        guard let endFrame, let height = measure(endFrame), height > 0 else { return }
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
    }

    private func keyboardWillDismiss() {
        guard !isHoldingHandoffHeight else {
            sawDismissDuringResponderHandoff = true
            return
        }
        coalesceTask?.cancel()
        coalesceTask = nil
        apply(0)
    }

    /// Candidate bars publish smaller positive frames while UIKit removes the
    /// system keyboard. Tools mode keeps the last complete measurement and
    /// ignores those transition-only frames; an actual hide still clears the
    /// current overlap through `keyboardWillDismiss()`.
    func pauseHeightCapture() {
        capturesPresentedHeight = false
        coalesceTask?.cancel()
        coalesceTask = nil
    }

    func resumeHeightCapture() {
        capturesPresentedHeight = true
    }

    /// Freezes the app-owned keyboard inset while UIKit transfers responder
    /// ownership. All frames inside the handoff are transient by definition:
    /// both endpoints use the same system keyboard, so retaining one would let
    /// a candidate-row or another window's frame replace the settled height.
    func beginResponderHandoff(
        currentHeight: @escaping @MainActor () -> CGFloat? = { nil },
        onFallback: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> UUID {
        let id = prepareResponderHandoff()
        let fallbackDelay = responderHandoffFallbackDelay
        responderHandoffFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: fallbackDelay)
            guard !Task.isCancelled else { return }
            guard let self, self.activeResponderHandoffID == id else { return }
            self.responderHandoffFallbackTask = nil
            self.activeResponderHandoffID = nil
            let shouldApplyDismissal = self.sawDismissDuringResponderHandoff
            self.sawDismissDuringResponderHandoff = false
            if shouldApplyDismissal {
                self.apply(max(0, currentHeight() ?? 0))
            }
            onFallback(id)
        }
        return id
    }

    /// Starts a freeze whose destination owns the primary fallback. A later
    /// owner-side watchdog prevents a deallocated destination from leaving
    /// the shared inset and handoff token active forever.
    func beginDestinationOwnedResponderHandoff(
        currentHeight: @escaping @MainActor () -> CGFloat? = { nil },
        onFallback: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> UUID {
        let id = prepareResponderHandoff()
        let fallbackDelay = destinationResponderHandoffFallbackDelay
        responderHandoffFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: fallbackDelay)
            guard !Task.isCancelled else { return }
            guard let self, self.activeResponderHandoffID == id else { return }
            self.responderHandoffFallbackTask = nil
            self.activeResponderHandoffID = nil
            let shouldApplyDismissal = self.sawDismissDuringResponderHandoff
            self.sawDismissDuringResponderHandoff = false
            if shouldApplyDismissal, let height = currentHeight() {
                self.apply(max(0, height))
            }
            onFallback(id)
        }
        return id
    }

    private func prepareResponderHandoff() -> UUID {
        let id = UUID()
        coalesceTask?.cancel()
        coalesceTask = nil
        responderHandoffFallbackTask?.cancel()
        activeResponderHandoffID = id
        sawDismissDuringResponderHandoff = false
        return id
    }

    /// Releases a responder-handoff freeze after the destination terminal's
    /// own keyboard frame settles. The pre-handoff settled height stays
    /// authoritative; a later ordinary keyboard event can replace it.
    func endResponderHandoff(_ id: UUID) {
        guard activeResponderHandoffID == id else { return }
        responderHandoffFallbackTask?.cancel()
        responderHandoffFallbackTask = nil
        activeResponderHandoffID = nil
        sawDismissDuringResponderHandoff = false
    }

    /// Cancels a transfer without committing any frame emitted while neither
    /// responder had stable ownership.
    func cancelResponderHandoff(
        _ id: UUID,
        currentHeight: @escaping @MainActor () -> CGFloat? = { nil }
    ) {
        guard activeResponderHandoffID == id else { return }
        let shouldApplyDismissal = sawDismissDuringResponderHandoff
        endResponderHandoff(id)
        if shouldApplyDismissal, let height = currentHeight() {
            apply(max(0, height))
        }
    }

    private func apply(_ height: CGFloat) {
        coalesceTask = nil
        if height > 0 {
            lastPresentedHeight = height
        }
        guard height != self.height else { return }
        self.height = height
    }

    /// How far the keyboard's end frame reaches above the terminal's own
    /// bottom edge. Keyboard frames are published in screen coordinates, which
    /// differ from the window's under split view and Stage Manager, and they
    /// are measured from the very bottom of the screen — while the terminal
    /// stops at the home indicator. Subtracting that safe area is what keeps
    /// the last row against the toolbar instead of a strip of background.
    ///
    /// Foreground-inactive scenes count too: UIKit restores the keyboard
    /// during foregrounding, before the scene reaches `.foregroundActive`.
    /// Requiring an active scene dropped exactly that measure, and the inset
    /// stayed at zero under a visible keyboard — with the Agent strip buried
    /// behind it.
    static func coveredHeight(of endFrame: CGRect) -> CGFloat? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard
            let window = scenes
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow
                ?? scenes
                .first(where: { $0.activationState == .foregroundInactive })?.keyWindow
        else { return nil }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return insetHeight(
            covered: window.bounds.intersection(frameInWindow).height,
            bottomSafeArea: window.safeAreaInsets.bottom)
    }

    nonisolated static func insetHeight(covered: CGFloat, bottomSafeArea: CGFloat) -> CGFloat {
        max(0, covered - bottomSafeArea)
    }

    /// Normalizes docked keyboard frames to the content edge above the home
    /// indicator while leaving floating keyboard geometry unchanged.
    static func normalizedKeyboardFrame(_ frame: CGRect, in window: UIWindow) -> CGRect {
        var visible = window.bounds.intersection(frame)
        if abs(visible.maxY - window.bounds.maxY) <= 1 {
            visible.size.height = max(
                0, window.safeAreaLayoutGuide.layoutFrame.maxY - visible.minY)
        }
        return visible
    }

    static func keyboardFrame(
        _ frame: CGRect, matches otherFrame: CGRect, in window: UIWindow
    ) -> Bool {
        let lhs = normalizedKeyboardFrame(frame, in: window)
        let rhs = normalizedKeyboardFrame(otherFrame, in: window)
        return lhs.height > 0
            && rhs.height > 0
            && abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.maxX - rhs.maxX) <= 1
            && abs(lhs.maxY - rhs.maxY) <= 1
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
