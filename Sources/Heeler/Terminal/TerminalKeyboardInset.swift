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
    private enum KeyboardTypeSwitchTarget {
        case system
        case tools
    }

    private struct KeyboardTypeSwitch {
        let target: KeyboardTypeSwitchTarget
        let frozenHeight: CGFloat
        let onSettled: @MainActor () -> Void
    }

    /// How much of the terminal's bottom edge the keyboard stack covers.
    private(set) var height: CGFloat = 0
    /// The last complete keyboard footprint. It survives dismissal so an
    /// in-app keyboard can replace UIKit's keyboard without changing layout.
    private(set) var lastPresentedHeight: CGFloat = 0
    /// Long enough to fold a presentation's follow-up frame into the first,
    /// short enough to stay inside the keyboard's own animation.
    private static let coalesceDelay = Duration.milliseconds(60)
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var keyboardTypeSwitch: KeyboardTypeSwitch?
    @ObservationIgnored private var keyboardTypeSwitchFallbackTask: Task<Void, Never>?
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
        notificationCenter.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let isLocal = (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey]
                as? NSNumber)?.boolValue ?? true
            MainActor.assumeIsolated {
                self?.keyboardDidSettle(isLocal: isLocal, target: .system)
            }
        }
        notificationCenter.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let isLocal = (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey]
                as? NSNumber)?.boolValue ?? true
            MainActor.assumeIsolated {
                self?.keyboardDidSettle(isLocal: isLocal, target: .tools)
            }
        }
    }

    private func keyboardWillPresent(endFrame: CGRect?) {
        guard let endFrame, let height = measure(endFrame), height > 0 else { return }
        guard keyboardTypeSwitch == nil else { return }
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
        guard keyboardTypeSwitch == nil else { return }
        apply(0)
    }

    /// Pins the complete keyboard footprint while UIKit replaces the system
    /// keyboard with the app tools keyboard, or vice versa. Keyboard frame
    /// notifications can temporarily add or remove candidate and paste rows;
    /// those measurements must not resize the terminal during a type switch.
    /// The corresponding did-show or did-hide notification settles the swap;
    /// the timeout is only a fallback for interrupted keyboard transactions.
    func beginKeyboardTypeSwitch(
        expectsSystemKeyboard: Bool,
        onSettled: @escaping @MainActor () -> Void
    ) {
        coalesceTask?.cancel()
        coalesceTask = nil
        keyboardTypeSwitchFallbackTask?.cancel()
        keyboardTypeSwitch = KeyboardTypeSwitch(
            target: expectsSystemKeyboard ? .system : .tools,
            frozenHeight: lastPresentedHeight,
            onSettled: onSettled)
        keyboardTypeSwitchFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.finishKeyboardTypeSwitch()
        }
    }

    private func keyboardDidSettle(
        isLocal: Bool,
        target: KeyboardTypeSwitchTarget
    ) {
        guard isLocal else { return }
        guard keyboardTypeSwitch?.target == target else { return }
        finishKeyboardTypeSwitch()
    }

    private func finishKeyboardTypeSwitch() {
        guard let keyboardTypeSwitch else { return }
        self.keyboardTypeSwitch = nil
        keyboardTypeSwitchFallbackTask?.cancel()
        keyboardTypeSwitchFallbackTask = nil
        switch keyboardTypeSwitch.target {
        case .system:
            apply(keyboardTypeSwitch.frozenHeight)
        case .tools:
            apply(0)
        }
        keyboardTypeSwitch.onSettled()
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
}

extension View {
    /// Sizes this view to the keyboard directly, instead of through SwiftUI's
    /// two-stage avoidance. See ``TerminalKeyboardInset``.
    func terminalKeyboardInset(_ inset: TerminalKeyboardInset) -> some View {
        padding(.bottom, inset.height)
            .ignoresSafeArea(.keyboard)
    }
}
