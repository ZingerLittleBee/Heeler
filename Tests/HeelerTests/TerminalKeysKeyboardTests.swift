import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Keys keyboard", .serialized)
struct TerminalKeysKeyboardTests {
    @Test func composerSuppressesTheSystemKeyboardBehindTheToolsDock() throws {
        let textView = AgentComposerUITextView()

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        // UIKit owns its candidate and paste area. Adding an accessory here
        // changes the keyboard stack's frame during an in-place replacement.
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        let suppressedSystemKeyboard = try #require(
            textView.inputView as? TerminalSuppressedSoftKeyboardView)
        #expect(suppressedSystemKeyboard.intrinsicContentSize.height == 0)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .system)
        #expect(textView.inputView == nil)
        #expect(textView.inputAccessoryView == nil)

        textView.updateKeyboard(presentation: .tools)
        #expect(textView.inputView === suppressedSystemKeyboard)
    }

    /// The terminal makes the same move the Composer does: Keys mode only
    /// suppresses the software keyboard, and nothing rides the keyboard in
    /// either mode. A real input view here is the regression this replaces —
    /// swapping one tears down the IME's candidate row for good.
    @Test func keysModeSuppressesTheSystemKeyboardInPlace() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: NotificationCenter())
        #expect(terminal.keyboardMode == .text)
        #expect(terminal.inputView == nil)
        #expect(terminal.inputAccessoryView == nil)

        terminal.setKeyboardMode(.controls)
        let suppressed = try #require(
            terminal.inputView as? TerminalSuppressedSoftKeyboardView)
        #expect(suppressed.intrinsicContentSize.height == 0)
        #expect(terminal.inputAccessoryView == nil)
        #expect(terminal.keyboardMode == .controls)

        terminal.setKeyboardMode(.text)
        #expect(terminal.inputView == nil)
        #expect(terminal.keyboardMode == .text)
    }

    /// Skills sits right beside the control keys when the agent has a skills
    /// source; without one the tab does not exist at all.
    @Test func skillsTabAppearsOnlyWithASkillsContext() throws {
        let suiteName = "hm-keys-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults))

        let plain = TerminalKeysContext(settings: settings, manageSnippets: {})
        #expect(plain.tabs == [.controls, .snippets, .appearance])

        let withSkills = TerminalKeysContext(
            settings: settings,
            skills: TerminalSkillsContext(store: SkillsPaneStore { _ in [] }),
            manageSnippets: {})
        #expect(withSkills.tabs == [.controls, .skills, .snippets, .appearance])
    }

    /// The in-place swap back to Text passes through a transient will-hide
    /// that zeroes the measured inset while the terminal keeps first
    /// responder. Reading hidden off the height alone tore the input row down
    /// for a frame and let it ride back up with the keyboard.
    @Test func aTransientZeroInsetDoesNotHideTheInputRowMidSwap() {
        // The regression: height dipped to zero mid-swap, responder retained.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 0, keyboardIsUp: true) == .system)

        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 336, keyboardIsUp: true) == .system)
        // A real dismissal resigns first responder before its will-hide.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .text, insetHeight: 0, keyboardIsUp: false) == .hidden)
        // Keys mode is the tools presentation no matter what the inset says.
        #expect(
            ShellTerminalView.keyboardPresentation(
                mode: .controls, insetHeight: 0, keyboardIsUp: true) == .tools)
    }

    /// A hardware keyboard attaching hides the system keyboard while the
    /// shell terminal keeps first responder, so Text stays `.system`. Its
    /// inset must follow the confirmed dismissal to zero instead of keeping a
    /// keyboard-sized band.
    @Test func aConfirmedHardwareKeyboardDismissalReleasesTheShellTextPin() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        inset.dismissalConfirmationDelay = .milliseconds(30)
        let text = ShellTerminalView.keyboardPresentation(
            mode: .text, insetHeight: 0, keyboardIsUp: true)
        #expect(text == .system)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 500, width: 402, height: 370)])
        try #require(await Self.eventually { inset.height == 336 })
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: text).contentInset == 336)

        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: text).contentInset == 0)
    }

    /// Keys suppresses the system keyboard, so its will-hide is a real
    /// dismissal and gets confirmed while the dock is up. Switching back to
    /// Text must restore the pre-show pin before UIKit's frame arrives, or
    /// the terminal drops to the bottom and rides back up with the keyboard.
    @Test func keysToTextKeepsThePreShowPinAfterAConfirmedDismissal() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        inset.dismissalConfirmationDelay = .milliseconds(30)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 500, width: 402, height: 370)])
        try #require(await Self.eventually { inset.height == 336 })

        ShellTerminalView.prepareKeyboardMode(.controls, inset: inset)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try #require(await Self.eventually { inset.isSoftwareKeyboardDismissed })
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: .tools).contentInset == 336)

        ShellTerminalView.prepareKeyboardMode(.text, inset: inset)
        let text = ShellTerminalView.keyboardPresentation(
            mode: .text, insetHeight: inset.height, keyboardIsUp: true)
        #expect(text == .system)
        #expect(!inset.isSoftwareKeyboardDismissed)
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: text).contentInset == 336)

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 500, width: 402, height: 370)])
        #expect(!inset.isConfirmingDismissal)
        try #require(await Self.eventually { inset.height == 336 })
        #expect(ShellTerminalView.keyboardLayout(
            inset: inset, presentation: text).contentInset == 336)
    }

    @Test func everyTabHasItsOwnIconAndLabel() {
        let icons = Set(TerminalKeysTab.allCases.map(\.systemImageName))
        let labels = Set(TerminalKeysTab.allCases.map(\.accessibilityLabel))

        #expect(icons.count == TerminalKeysTab.allCases.count)
        #expect(labels.count == TerminalKeysTab.allCases.count)
        for icon in icons {
            #expect(UIImage(systemName: icon) != nil, "missing SF Symbol \(icon)")
        }
    }

    /// Polls instead of sleeping a fixed time, so a loaded runner cannot
    /// outlast a hard-coded margin.
    private static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
@Suite("Keyboard ride", .serialized)
struct KeyboardRideTests {
    private static func post(
        _ name: Notification.Name, on center: NotificationCenter, duration: TimeInterval = 0.25
    ) {
        center.post(
            name: name, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 500, width: 402, height: 336),
                UIResponder.keyboardAnimationDurationUserInfoKey: duration,
            ])
    }

    private static func offset(coverage: CGFloat, layoutInset: CGFloat) -> CGFloat {
        KeyboardRideEffect(keyboardCoverage: coverage, contentInset: 34, layoutInset: layoutInset)
            .effectValue(size: .zero).m32
    }

    @Test func theRowHoldsUntilTheKeyboardReachesItThenMovesWithIt() {
        // Laid out at the end of a rise, while the keyboard is still below the
        // content edge, and then one point of row per point of keyboard.
        #expect(Self.offset(coverage: 0, layoutInset: 336) == 336)
        #expect(Self.offset(coverage: 34, layoutInset: 336) == 336)
        #expect(Self.offset(coverage: 134, layoutInset: 336) == 236)
        #expect(Self.offset(coverage: 370, layoutInset: 336) == 0)
        // Laid out at the end of a fall, while the keyboard is still up.
        #expect(Self.offset(coverage: 134, layoutInset: 0) == -100)
    }

    @Test func theRideStartsWithThePresentationWhileTheLayoutCoalesces() {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center, measure: { _ in 336 })
        Self.post(UIResponder.keyboardWillShowNotification, on: center)
        #expect(inset.keyboardRideCoverage == 336)
        #expect(inset.height == 0, "the layout folds in the presentation's follow-up frame")
    }

    @Test func theRideFallsWithTheDismissal() {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center, measure: { _ in 336 })
        Self.post(UIResponder.keyboardWillShowNotification, on: center)
        Self.post(UIResponder.keyboardWillHideNotification, on: center)
        #expect(inset.keyboardRideCoverage == 0)
        #expect(inset.height == 0)
    }

    @Test func aHandoffFreezesTheRide() {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center, measure: { _ in 336 })
        let id = inset.beginResponderHandoff()
        Self.post(UIResponder.keyboardWillShowNotification, on: center)
        #expect(inset.keyboardRideCoverage == 0)
        inset.cancelResponderHandoff(id)
    }

    @Test func theMotionRunsOnTheNotificationsClock() throws {
        let motion = KeyboardMotion(start: 100)
        let expected = KeyboardMotion.spring.value(target: 335.0, initialVelocity: 0.0, time: 0.1)
        // However late SwiftUI's first frame, the position is the keyboard's.
        let position = try #require(motion.position(toward: 335.0, at: 100.1))
        #expect(abs(position - expected) < 0.01)
        #expect(motion.position(toward: 335.0, at: 100) == 0)
        #expect(motion.position(toward: 335.0, at: 100 + KeyboardMotion.spring.settlingDuration) == nil)
    }

    private final class Sampler: NSObject {
        var body: (CFTimeInterval) -> Void = { _ in }
        @objc func tick(_ link: CADisplayLink) { body(link.timestamp) }
    }

    /// The published curve is the keyboard's own: its layout guide follows this
    /// curve to within a tenth of a percent. The band allows for the unknown
    /// offset between the animation's start and the first sampled frame.
    @Test func theMotionMatchesUIKitsKeyboardCurve() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIViewController()
        window.isHidden = false
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        try #require(window.rootViewController?.view).addSubview(view)

        let spring = KeyboardMotion.spring
        var samples: [(time: TimeInterval, progress: Double)] = []
        let start = CACurrentMediaTime()
        UIView.animate(
            withDuration: 0.25, delay: 0,
            options: [
                .overrideInheritedCurve, .overrideInheritedDuration,
                UIView.AnimationOptions(rawValue: 7 << 16),
            ]
        ) { view.frame.origin.y = 100 }
        let sampler = Sampler()
        sampler.body = { now in
            let progress = (view.layer.presentation() ?? view.layer).frame.minY / 100
            samples.append((now - start, progress))
        }
        let link = CADisplayLink(target: sampler, selector: #selector(Sampler.tick(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        try await Task.sleep(for: .milliseconds(500))

        #expect(samples.count > 5)
        for sample in samples {
            let earlier = spring.value(target: 1.0, initialVelocity: 0.0, time: max(0, sample.time - 0.05))
            let later = spring.value(target: 1.0, initialVelocity: 0.0, time: sample.time + 0.05)
            #expect(
                (earlier - 0.01...later + 0.01).contains(sample.progress),
                "\(sample.progress) at \(sample.time)s left [\(earlier), \(later)]")
        }
    }
}
