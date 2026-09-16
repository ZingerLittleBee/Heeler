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
    /// Whether the software keyboard really left since it was last presented
    /// or expected. A hardware keyboard attaching hides the software keyboard
    /// without moving first responder, so a presentation that pins its inset
    /// to ``lastPresentedHeight`` would otherwise keep a keyboard-sized gap
    /// forever. Set only once a will-hide stays unanswered for
    /// ``dismissalConfirmationDelay``: swapping input views publishes a
    /// transient will-hide right before the next will-show, and that must
    /// not drop the pin for a frame.
    private(set) var isSoftwareKeyboardDismissed = false
    @ObservationIgnored var dismissalConfirmationDelay = Duration.milliseconds(350)
    @ObservationIgnored private var dismissalConfirmationTask: Task<Void, Never>?
    /// Whether a will-hide is still waiting on ``dismissalConfirmationDelay``.
    var isConfirmingDismissal: Bool { dismissalConfirmationTask != nil }
    /// Long enough to fold a presentation's follow-up frame into the first,
    /// short enough to stay inside the keyboard's own animation.
    private static let coalesceDelay = Duration.milliseconds(60)
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    /// Nil in production, where the keyboard is measured against `window`.
    @ObservationIgnored private let measureOverride: (@MainActor (CGRect) -> CGFloat?)?
    /// Nil in production, where `window`'s keyboard layout guide is read.
    @ObservationIgnored private let measureWindowKeyboardOverride: (@MainActor () -> CGFloat?)?
    /// A presentation published a keyboard-sized end frame that covered none
    /// of the window, so it was dropped; see `keyboardDidShow()`.
    @ObservationIgnored private var missedPresentationFrame = false
    /// The window this inset's terminal lives in. Keyboard notifications are
    /// process-wide; with two windows on iPad only the terminal's own window
    /// can say how much of it the keyboard covers.
    @ObservationIgnored private weak var window: UIWindow?
    @ObservationIgnored private var capturesPresentedHeight = true
    /// Composer-to-terminal responder handoff can publish transient show,
    /// change-frame, and even hide notifications while the software keyboard
    /// never visibly leaves. Keep the last settled footprint until the new
    /// terminal confirms that its own keyboard frame settled.
    private(set) var activeResponderHandoffID: UUID?
    @ObservationIgnored private var responderHandoffFallbackTask: Task<Void, Never>?
    /// A dismissal the handoff has to settle on exit: a hide inside the
    /// freeze, or one still unconfirmed when the freeze began or expiring
    /// during it. Every exit reconciles it against the owning window, so a
    /// hardware keyboard attached just before a mode switch cannot leave the
    /// inset pinned with nothing left to confirm it.
    @ObservationIgnored private var owesDismissalAfterResponderHandoff = false
    @ObservationIgnored var responderHandoffFallbackDelay = Duration.milliseconds(500)
    /// The destination terminal owns the primary 500ms timeout. This later
    /// owner-side watchdog exists only for a destination that is deallocated
    /// before its weakly captured timeout can report an outcome.
    @ObservationIgnored var destinationResponderHandoffFallbackDelay = Duration.seconds(1)

    var isHoldingHandoffHeight: Bool { activeResponderHandoffID != nil }

    /// `measure` and `measureWindowKeyboard` replace the window measurements
    /// in tests; production leaves them nil and attaches the terminal's
    /// window instead.
    init(
        notificationCenter: NotificationCenter = .default,
        measure: (@MainActor (CGRect) -> CGFloat?)? = nil,
        measureWindowKeyboard: (@MainActor () -> CGFloat?)? = nil
    ) {
        measureOverride = measure
        measureWindowKeyboardOverride = measureWindowKeyboard
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
        notificationCenter.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardDidShow()
            }
        }
    }

    /// Measures against the window the terminal is mounted in, which its view
    /// reports from a `WindowReader` in its background. Idempotent; the inset
    /// keeps the last window it was given.
    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        self.window = window
    }

    private func measure(_ endFrame: CGRect) -> CGFloat? {
        if let measureOverride {
            return measureOverride(endFrame)
        }
        guard let window else { return nil }
        return Self.coveredHeight(of: endFrame, in: window)
    }

    private func measureWindowKeyboard() -> CGFloat? {
        if let measureWindowKeyboardOverride {
            return measureWindowKeyboardOverride()
        }
        guard let window else { return nil }
        return Self.layoutGuideHeight(in: window)
    }

    private func keyboardWillPresent(endFrame: CGRect?) {
        guard !isHoldingHandoffHeight else { return }
        guard capturesPresentedHeight else { return }
        guard let endFrame, let height = measure(endFrame) else { return }
        guard height > 0 else {
            missedPresentationFrame = endFrame.height > 0
            return
        }
        missedPresentationFrame = false
        dismissalConfirmationTask?.cancel()
        dismissalConfirmationTask = nil
        isSoftwareKeyboardDismissed = false
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
    }

    private func keyboardWillDismiss() {
        missedPresentationFrame = false
        guard !isHoldingHandoffHeight else {
            owesDismissalAfterResponderHandoff = true
            return
        }
        coalesceTask?.cancel()
        coalesceTask = nil
        apply(0)
        confirmDismissalIfUnanswered()
    }

    /// UIKit can publish a presentation whose end frame has the keyboard's
    /// size but lies wholly below the screen. Observed on the iPad simulator
    /// after windowed multitasking: detaching the hardware keyboard posted
    /// `willShow` with `(0, 1376, 1032, 403)` while the keyboard sat at
    /// `y = 973`, and no corrected frame followed. That frame covers none of
    /// the window and is dropped above, which left the inset at zero, with a
    /// confirmed dismissal, under a visible keyboard. The window's keyboard
    /// layout guide still tracks the real keyboard, so the did-show settles
    /// against it. Only a dropped presentation is reconciled: any measured
    /// frame stays authoritative.
    private func keyboardDidShow() {
        guard missedPresentationFrame, !isHoldingHandoffHeight, capturesPresentedHeight
        else { return }
        missedPresentationFrame = false
        guard let measuredHeight = measureWindowKeyboard(), measuredHeight > 0 else { return }
        coalesceTask?.cancel()
        settleDismissal(measuredHeight: measuredHeight)
    }

    /// The app is about to ask UIKit for the software keyboard (Tools→iOS,
    /// or the Composer taking focus), so the pin to ``lastPresentedHeight``
    /// applies again until the keyboard's own frame arrives. If nothing
    /// presents (a hardware keyboard is attached), the dismissal is
    /// confirmed after the same delay as an unanswered will-hide.
    func expectSoftwareKeyboard() {
        isSoftwareKeyboardDismissed = false
        confirmDismissalIfUnanswered()
    }

    private func confirmDismissalIfUnanswered() {
        dismissalConfirmationTask?.cancel()
        let delay = dismissalConfirmationDelay
        dismissalConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.dismissalConfirmationTask = nil
            guard self.height == 0 else { return }
            // A handoff freezes the inset; its exit settles the dismissal.
            guard !self.isHoldingHandoffHeight else {
                self.owesDismissalAfterResponderHandoff = true
                return
            }
            self.isSoftwareKeyboardDismissed = true
        }
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
            let owesDismissal = self.owesDismissalAfterResponderHandoff
            self.owesDismissalAfterResponderHandoff = false
            let measuredHeight = currentHeight()
            self.reconcileResponderHandoffExit(
                owesDismissal: owesDismissal,
                measuredHeight: owesDismissal ? measuredHeight ?? 0 : measuredHeight)
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
            let owesDismissal = self.owesDismissalAfterResponderHandoff
            self.owesDismissalAfterResponderHandoff = false
            self.reconcileResponderHandoffExit(
                owesDismissal: owesDismissal, measuredHeight: currentHeight())
            onFallback(id)
        }
        return id
    }

    private func prepareResponderHandoff() -> UUID {
        let id = UUID()
        coalesceTask?.cancel()
        coalesceTask = nil
        responderHandoffFallbackTask?.cancel()
        // An unconfirmed hide from before the freeze, or one a replaced
        // freeze still owed, is carried into it rather than dropped.
        owesDismissalAfterResponderHandoff =
            (isHoldingHandoffHeight && owesDismissalAfterResponderHandoff)
            || isConfirmingDismissal
        activeResponderHandoffID = id
        dismissalConfirmationTask?.cancel()
        dismissalConfirmationTask = nil
        return id
    }

    /// Releases a responder-handoff freeze after the destination terminal's
    /// own keyboard frame settles (or its own timeout gives up). The
    /// pre-handoff settled height stays authoritative while the keyboard is
    /// still measured up; a later ordinary keyboard event can replace it. An
    /// owed dismissal is settled against `currentHeight` otherwise.
    func endResponderHandoff(
        _ id: UUID,
        currentHeight: @escaping @MainActor () -> CGFloat? = { nil }
    ) {
        guard activeResponderHandoffID == id else { return }
        reconcileResponderHandoffExit(
            owesDismissal: releaseResponderHandoff(),
            measuredHeight: currentHeight(),
            keepsVisibleHeight: true)
    }

    private func releaseResponderHandoff() -> Bool {
        responderHandoffFallbackTask?.cancel()
        responderHandoffFallbackTask = nil
        activeResponderHandoffID = nil
        let owesDismissal = owesDismissalAfterResponderHandoff
        owesDismissalAfterResponderHandoff = false
        return owesDismissal
    }

    /// Cancels a transfer without committing any frame emitted while neither
    /// responder had stable ownership.
    func cancelResponderHandoff(
        _ id: UUID,
        currentHeight: @escaping @MainActor () -> CGFloat? = { nil }
    ) {
        guard activeResponderHandoffID == id else { return }
        reconcileResponderHandoffExit(
            owesDismissal: releaseResponderHandoff(),
            measuredHeight: currentHeight())
    }

    /// Every handoff exit reconciles against the owning window. An owed
    /// dismissal is settled against the measurement; `keepsVisibleHeight`
    /// keeps a positive frozen height while the keyboard still measures up
    /// (the destination's settle contract). With nothing owed, a frozen zero
    /// inset still adopts a keyboard measured up at exit: its presentation
    /// was discarded inside the freeze (a hardware keyboard detached during
    /// the transfer), and no later frame would restore it.
    private func reconcileResponderHandoffExit(
        owesDismissal: Bool,
        measuredHeight: CGFloat?,
        keepsVisibleHeight: Bool = false
    ) {
        if owesDismissal {
            if keepsVisibleHeight, let measuredHeight, measuredHeight > 0, height > 0 {
                return
            }
            settleDismissal(measuredHeight: measuredHeight)
        } else if height == 0, let measuredHeight, measuredHeight > 0 {
            settleDismissal(measuredHeight: measuredHeight)
        }
    }

    /// Commits an owed dismissal. A measurement is authoritative; without
    /// one (no owning window) the frozen height stands, and a zero height
    /// still gets its confirmation.
    private func settleDismissal(measuredHeight: CGFloat?) {
        if let measuredHeight {
            apply(max(0, measuredHeight))
        }
        if height > 0 {
            dismissalConfirmationTask?.cancel()
            dismissalConfirmationTask = nil
            isSoftwareKeyboardDismissed = false
        } else {
            confirmDismissalIfUnanswered()
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
    /// The frame is measured against the terminal's own window, and only
    /// while that window owns the keyboard (see `windowOwnsKeyboard`): the
    /// notification is process-wide, and on iPad another window of the app
    /// can be the one typing (#157).
    static func coveredHeight(of endFrame: CGRect, in window: UIWindow) -> CGFloat? {
        guard let scene = window.windowScene,
            windowOwnsKeyboard(
                isKeyWindow: window.isKeyWindow,
                isSceneKeyWindow: scene.keyWindow === window,
                activationState: scene.activationState)
        else { return nil }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return insetHeight(
            covered: window.bounds.intersection(frameInWindow).height,
            bottomSafeArea: window.safeAreaInsets.bottom)
    }

    /// How far the keyboard reaches above the terminal's bottom edge as the
    /// keyboard layout guide tracks it, under the same ownership rule as
    /// `coveredHeight(of:in:)`. The guide rests on the bottom safe area while
    /// no keyboard is docked, which measures zero.
    static func layoutGuideHeight(in window: UIWindow) -> CGFloat? {
        guard let scene = window.windowScene,
            windowOwnsKeyboard(
                isKeyWindow: window.isKeyWindow,
                isSceneKeyWindow: scene.keyWindow === window,
                activationState: scene.activationState),
            let guideFrame = keyboardLayoutGuideFrame(in: window)
        else { return nil }
        let frame = window.bounds.intersection(guideFrame)
        let includesBottomSafeArea = abs(frame.maxY - window.bounds.maxY) <= 1
        return insetHeight(
            covered: frame.height,
            bottomSafeArea: includesBottomSafeArea ? window.safeAreaInsets.bottom : 0)
    }

    /// The keyboard layout guide's frame in `window`'s coordinates, or nil
    /// while the window has no root view. Every reader of the guide goes
    /// through here.
    ///
    /// The guide is read from the window's root view: a `UIWindow`'s own
    /// `keyboardLayoutGuide` is never laid out, and its `layoutFrame` stayed
    /// `.zero` on the iPad under a visible keyboard while the root hosting
    /// view's guide reported `(0, 973, 1032, 403)`.
    static func keyboardLayoutGuideFrame(in window: UIWindow) -> CGRect? {
        guard let rootView = window.rootViewController?.view else { return nil }
        return rootView.convert(rootView.keyboardLayoutGuide.layoutFrame, to: window)
    }

    /// Whether a keyboard notification can belong to this window. The key
    /// window is the one receiving keyboard input, which is how the terminal
    /// itself decides a frame is its own (#157).
    ///
    /// Foreground-inactive scenes count too: UIKit restores the keyboard
    /// during foregrounding, before the scene reaches `.foregroundActive` and
    /// before any window is key again, so there the scene's own key window
    /// stands in. Requiring an active scene dropped exactly that measure, and
    /// the inset stayed at zero under a visible keyboard — with the Agent
    /// strip buried behind it.
    nonisolated static func windowOwnsKeyboard(
        isKeyWindow: Bool,
        isSceneKeyWindow: Bool,
        activationState: UIScene.ActivationState
    ) -> Bool {
        switch activationState {
        case .foregroundActive:
            isKeyWindow
        case .foregroundInactive:
            isKeyWindow || isSceneKeyWindow
        case .background, .unattached:
            false
        @unknown default:
            false
        }
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
