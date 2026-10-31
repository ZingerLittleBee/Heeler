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
    /// How much of the window the keyboard covers right now, frame by frame,
    /// where ``height`` jumps to the end of the motion so the terminal resizes
    /// once. Measured from the window's edge, where the keyboard's own travel
    /// starts; see `View.ridesKeyboard`.
    private(set) var keyboardRideCoverage: CGFloat = 0
    /// Where ``keyboardRideCoverage`` is heading.
    private(set) var keyboardRideTarget: CGFloat = 0
    /// How far above the window's edge the row rests with no keyboard.
    private(set) var keyboardRideContentInset: CGFloat = 0
    /// How far the keyboard has raised a row resting on the content edge: the
    /// row holds still until the keyboard reaches it.
    var keyboardRideRaise: CGFloat {
        Self.insetHeight(covered: keyboardRideCoverage, bottomSafeArea: keyboardRideContentInset)
    }
    @ObservationIgnored private var rideMotion: KeyboardRideMotion?
    @ObservationIgnored private var rideLink: CADisplayLink?
    /// Leaving the tools dock, whose footprint the input row already rests on,
    /// moves the keyboard but not the row. A time rather than one motion,
    /// since that swap publishes a hide and then a show.
    private(set) var isSkippingKeyboardRide = false
    @ObservationIgnored private var keyboardRideSkipTask: Task<Void, Never>?
    private static let toolsDockExitDuration = Duration.milliseconds(800)
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
    /// A view inside the terminal's screen, when the terminal can rest above
    /// a bar rather than on the home indicator; see
    /// ``contentBottomInset(of:in:)``.
    @ObservationIgnored private weak var contentAnchor: UIView?
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
                // Notification is not Sendable; the values it carries are.
                let endFrame = notification.userInfo?[
                    UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let animates = Self.keyboardAnimates(notification.userInfo)
                MainActor.assumeIsolated {
                    self?.keyboardWillPresent(endFrame: endFrame, animates: animates)
                }
            }
        }
        notificationCenter.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let animates = Self.keyboardAnimates(notification.userInfo)
            MainActor.assumeIsolated {
                self?.keyboardWillDismiss(animates: animates)
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
    /// keeps the last window it was given, and the last `contentAnchor`.
    func attach(to window: UIWindow, contentAnchor: UIView? = nil) {
        if let contentAnchor { self.contentAnchor = contentAnchor }
        guard self.window !== window else { return }
        self.window = window
    }

    /// Leaving the tools dock: the keyboard's motions right after move nothing
    /// that rides them, since the row already rests at the dock's height.
    func skipKeyboardRideLeavingToolsDock() {
        isSkippingKeyboardRide = true
        keyboardRideSkipTask?.cancel()
        keyboardRideSkipTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toolsDockExitDuration)
            guard !Task.isCancelled else { return }
            self?.isSkippingKeyboardRide = false
        }
    }

    private func measure(_ endFrame: CGRect) -> CGFloat? {
        if let measureOverride {
            return measureOverride(endFrame)
        }
        guard let window else { return nil }
        return Self.coveredHeight(
            of: endFrame, in: window,
            contentBottomInset: Self.contentBottomInset(of: contentAnchor, in: window))
    }

    private func measureWindowKeyboard() -> CGFloat? {
        if let measureWindowKeyboardOverride {
            return measureWindowKeyboardOverride()
        }
        guard let window else { return nil }
        return keyboardHeight(in: window)
    }

    /// The keyboard's reach above the terminal's bottom edge in `window`, as
    /// the layout guide tracks it, measured the way this inset measures:
    /// against ``contentBottomInset(of:in:)`` for its content anchor.
    func keyboardHeight(in window: UIWindow) -> CGFloat? {
        Self.layoutGuideHeight(
            in: window,
            contentBottomInset: Self.contentBottomInset(of: contentAnchor, in: window))
    }

    private nonisolated static func keyboardAnimates(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) != 0
    }

    private func keyboardWillPresent(endFrame: CGRect?, animates: Bool) {
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
        rideKeyboard(height: height, animates: animates)
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled else { return }
            self?.apply(height)
        }
    }

    private func keyboardWillDismiss(animates: Bool) {
        missedPresentationFrame = false
        guard !isHoldingHandoffHeight else {
            owesDismissalAfterResponderHandoff = true
            return
        }
        coalesceTask?.cancel()
        coalesceTask = nil
        rideKeyboard(height: 0, animates: animates)
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

    /// Adopts a keyboard that is already on screen when this inset's screen
    /// comes up: a Shell Terminal inheriting the keyboard from the Agent it
    /// was opened from. A fresh inset starts at zero, so its input row would
    /// be laid out at the bottom of the screen and ride up to the keyboard
    /// once UIKit's next frame notification arrived — the same motion as a
    /// keyboard being presented, under a keyboard that never left. The
    /// window's keyboard layout guide already knows the footprint, so the
    /// first layout can use it. Measures nothing while the window does not
    /// own the keyboard, and leaves a keyboard-free window alone.
    func inheritPresentedKeyboard(in window: UIWindow) {
        attach(to: window)
        guard let measured = measureWindowKeyboard(), measured > 0 else { return }
        dismissalConfirmationTask?.cancel()
        dismissalConfirmationTask = nil
        isSoftwareKeyboardDismissed = false
        missedPresentationFrame = false
        coalesceTask?.cancel()
        apply(measured)
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
    /// retaining one would let a candidate-row or another window's frame
    /// replace the settled height. The destination's settle measures the
    /// keyboard it actually kept; see ``endResponderHandoff(_:currentHeight:)``.
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
    /// own keyboard frame settles (or its own timeout gives up). While the
    /// keyboard is still measured up, the inset eases to that measurement:
    /// the two endpoints can carry different correction traits (Composer
    /// autocorrect shows a candidate bar Direct Input never does), and UIKit
    /// published the resized frame inside the freeze, where it was dropped.
    /// Matching endpoints measure the frozen height and nothing moves. An
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
    /// keeps a positive inset while the keyboard still measures up (the
    /// destination's settle contract), easing it to that measurement. With
    /// nothing owed, a frozen zero inset still adopts a keyboard measured up
    /// at exit: its presentation was discarded inside the freeze (a hardware
    /// keyboard detached during the transfer), and no later frame would
    /// restore it.
    private func reconcileResponderHandoffExit(
        owesDismissal: Bool,
        measuredHeight: CGFloat?,
        keepsVisibleHeight: Bool = false
    ) {
        if keepsVisibleHeight, let measuredHeight, measuredHeight > 0, height > 0 {
            adoptSettledKeyboardHeight(measuredHeight)
            return
        }
        if owesDismissal {
            settleDismissal(measuredHeight: measuredHeight)
        } else if height == 0, let measuredHeight, measuredHeight > 0 {
            settleDismissal(measuredHeight: measuredHeight)
        }
    }

    /// Moves a visible inset to the keyboard the destination settled on.
    /// The keyboard itself already changed height; easing the inset closes
    /// (or opens) the difference instead of snapping the input chrome.
    private func adoptSettledKeyboardHeight(_ measuredHeight: CGFloat) {
        guard abs(measuredHeight - height) > 1 else { return }
        withAnimation(Self.settledHeightAnimation) {
            apply(measuredHeight)
        }
    }

    private static let settledHeightAnimation = Animation.easeOut(duration: 0.25)

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
        // A keyboard that arrived without a presentation to ride, such as an
        // inherited one, is already where it is going.
        rideKeyboard(height: height)
        guard height != self.height else { return }
        self.height = height
    }

    /// `animates` starts the keyboard's motion from where the ride is. Without
    /// it the ride only follows a height the keyboard is already headed to, so
    /// a motion on its way there is left to finish.
    private func rideKeyboard(height: CGFloat, animates: Bool = false) {
        let contentInset =
            window.map {
                Self.contentBottomInset(of: contentAnchor, in: $0) ?? $0.safeAreaInsets.bottom
            } ?? 0
        let target = height > 0 ? height + contentInset : 0
        if contentInset != keyboardRideContentInset { keyboardRideContentInset = contentInset }
        guard target != keyboardRideTarget else { return }
        keyboardRideTarget = target
        guard animates else {
            stopRideMotion()
            keyboardRideCoverage = target
            return
        }
        let now = CACurrentMediaTime()
        rideMotion = KeyboardRideMotion(
            from: keyboardRideCoverage,
            target: target,
            start: now,
            initialVelocity: rideMotion?.velocity(at: now) ?? 0)
        guard rideLink == nil else { return }
        let link = CADisplayLink(target: KeyboardRideTicker(self), selector: #selector(KeyboardRideTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        rideLink = link
    }

    /// The position for the frame this tick will reach the screen in, which
    /// is what the keyboard's own animation shows then.
    fileprivate func advanceRideMotion(toward time: CFTimeInterval) {
        guard let rideMotion else { return stopRideMotion() }
        if rideMotion.isSettled(at: time) {
            keyboardRideCoverage = rideMotion.target
            stopRideMotion()
        } else {
            keyboardRideCoverage = rideMotion.coverage(at: time)
        }
    }

    private func stopRideMotion() {
        rideMotion = nil
        rideLink?.invalidate()
        rideLink = nil
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
    ///
    /// `contentBottomInset` is how far above the window's bottom edge the
    /// terminal stops; nil means the home indicator's safe area.
    static func coveredHeight(
        of endFrame: CGRect, in window: UIWindow, contentBottomInset: CGFloat? = nil
    ) -> CGFloat? {
        guard let scene = window.windowScene,
            windowOwnsKeyboard(
                isKeyWindow: window.isKeyWindow,
                isSceneKeyWindow: scene.keyWindow === window,
                activationState: scene.activationState)
        else { return nil }
        let frameInWindow = window.convert(endFrame, from: window.screen.coordinateSpace)
        return insetHeight(
            covered: window.bounds.intersection(frameInWindow).height,
            bottomSafeArea: contentBottomInset ?? window.safeAreaInsets.bottom)
    }

    /// How far the keyboard reaches above the terminal's bottom edge as the
    /// keyboard layout guide tracks it, under the same ownership rule as
    /// `coveredHeight(of:in:contentBottomInset:)`. The guide rests on the
    /// bottom safe area while no keyboard is docked, which measures zero.
    static func layoutGuideHeight(
        in window: UIWindow, contentBottomInset: CGFloat? = nil
    ) -> CGFloat? {
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
            bottomSafeArea: includesBottomSafeArea
                ? contentBottomInset ?? window.safeAreaInsets.bottom : 0)
    }

    /// How far above `window`'s bottom edge a terminal containing `anchor`
    /// stops: the bottom safe area of the view controller hosting it. That is
    /// the home indicator's, unless a bar stays below the terminal, as the
    /// Console's tab bar does beside a selection in a regular-width iPhone
    /// window (an unfolded iPhone). Measured from the window's edge, the
    /// keyboard then left a bar's height of gap above it. UIKit's safe area
    /// never includes the keyboard, so this holds while it moves. Nil without
    /// an anchor in `window`, which measures the window's own safe area.
    static func contentBottomInset(of anchor: UIView?, in window: UIWindow) -> CGFloat? {
        guard let anchor, anchor.window === window else { return nil }
        var responder: UIResponder? = anchor
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let host = (responder as? UIViewController)?.view else { return nil }
        let safeFrame = host.convert(host.safeAreaLayoutGuide.layoutFrame, to: window)
        return max(0, window.bounds.maxY - safeFrame.maxY)
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

    /// Keeps an input row on the keyboard while it moves. `layoutInset` is how
    /// far above the content edge the row is laid out.
    func ridesKeyboard(
        _ inset: TerminalKeyboardInset, layoutInset: CGFloat, isEnabled: Bool
    ) -> some View {
        modifier(KeyboardRide(inset: inset, layoutInset: layoutInset, isEnabled: isEnabled))
    }

    /// Lays this view out on the keyboard while it moves, for a surface with
    /// no terminal to resize once. `restingInset` is the inset without a
    /// keyboard to follow, such as the tools dock's.
    func keyboardRidePadding(
        _ inset: TerminalKeyboardInset, restingInset: CGFloat, isEnabled: Bool
    ) -> some View {
        modifier(KeyboardRidePadding(inset: inset, restingInset: restingInset, isEnabled: isEnabled))
    }
}

/// The keyboard's own motion, up or down, on the clock of its notification.
///
/// Keyboard notifications publish `UIView.AnimationCurve` 7, a
/// `CASpringAnimation` of mass 3, stiffness 1000 and damping 500 that ignores
/// the published duration. SwiftUI's `Spring` solves those three numbers
/// differently, up to 10% of the travel behind, so ``spring`` is fitted to the
/// curve, within 3pt of the keyboard's 335; `KeyboardRideTests` watches the
/// numbers it was fitted to.
///
/// It is not a SwiftUI animation: those start at their first rendered frame,
/// about 70ms after the keyboard, and leave a hole of about 50ms after it.
struct KeyboardRideMotion {
    static let spring = Spring(response: 0.266, dampingRatio: 1)

    let from: CGFloat
    let target: CGFloat
    let start: CFTimeInterval
    let initialVelocity: CGFloat

    func coverage(at time: CFTimeInterval) -> CGFloat {
        from + Self.spring.value(
            target: target - from, initialVelocity: initialVelocity, time: max(0, time - start))
    }

    func velocity(at time: CFTimeInterval) -> CGFloat {
        Self.spring.velocity(
            target: target - from, initialVelocity: initialVelocity, time: max(0, time - start))
    }

    func isSettled(at time: CFTimeInterval) -> Bool {
        time - start >= Self.spring.settlingDuration
    }
}

/// Keeps a display link from retaining the inset it advances.
@MainActor
private final class KeyboardRideTicker: NSObject {
    private weak var inset: TerminalKeyboardInset?

    init(_ inset: TerminalKeyboardInset) {
        self.inset = inset
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let inset else { return link.invalidate() }
        inset.advanceRideMotion(toward: link.targetTimestamp)
    }
}

/// On its own so the surface does not re-evaluate each frame of the ride.
private struct KeyboardRide: ViewModifier {
    let inset: TerminalKeyboardInset
    let layoutInset: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        let rides = isEnabled && !inset.isHoldingHandoffHeight && !inset.isSkippingKeyboardRide
        content.offset(y: rides ? layoutInset - inset.keyboardRideRaise : 0)
    }
}

/// On its own for the same reason as ``KeyboardRide``.
private struct KeyboardRidePadding: ViewModifier {
    let inset: TerminalKeyboardInset
    let restingInset: CGFloat
    let isEnabled: Bool

    func body(content: Content) -> some View {
        let rides = isEnabled && !inset.isHoldingHandoffHeight && !inset.isSkippingKeyboardRide
        content.padding(.bottom, rides ? inset.keyboardRideRaise : restingInset)
    }
}
