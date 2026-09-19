import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Backspace hold timing", .serialized)
struct TerminalBackspaceButtonTests {
    private final class Finger: UITouch {
        var point = CGPoint(x: 50, y: 22)
        override func location(in view: UIView?) -> CGPoint { point }
    }

    @MainActor
    private struct Press {
        let button: TerminalRepeatingBackspaceButton
        let finger = Finger()
        let event = UIEvent()

        init(_ button: TerminalRepeatingBackspaceButton) {
            self.button = button
            finger.point = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        }

        func begin() {
            for recognizer in button.gestureRecognizers ?? [] {
                recognizer.touchesBegan([finger], with: event)
            }
        }

        func move(to point: CGPoint) {
            finger.point = point
            for recognizer in button.gestureRecognizers ?? [] {
                recognizer.touchesMoved([finger], with: event)
            }
        }

        func end() {
            for recognizer in button.gestureRecognizers ?? [] {
                recognizer.touchesEnded([finger], with: event)
            }
        }

        func cancel() {
            for recognizer in button.gestureRecognizers ?? [] {
                recognizer.touchesCancelled([finger], with: event)
            }
        }
    }

    @Test func heldTouchRepeatsBeforeUIKitDeliversDelayedControlActions() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let finger = Finger()
        let event = UIEvent()
        // An ancestor recognizer can delay UIButton's touchDown until release.
        // Recognizers still receive the original touch before the control does.
        for recognizer in button.gestureRecognizers ?? [] {
            recognizer.touchesBegan([finger], with: event)
        }
        let repeats = await repeatsReaching(3) { count }
        #expect(button.isHighlighted)
        #expect(repeats >= 3, "Holding must repeat before delayed touchDown/touchUpInside arrive")
        for recognizer in button.gestureRecognizers ?? [] {
            recognizer.touchesEnded([finger], with: event)
        }
        let beforeRelease = count
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == beforeRelease, "Delayed control actions must not duplicate the release")
        #expect(!button.isHighlighted)
    }

    @MainActor @Observable
    final class KeyboardProbe {
        var count = 0
        let control = TerminalKeyboardControl()
    }

    private struct KeyboardProbeView: View {
        let probe: KeyboardProbe

        var body: some View {
            VStack {
                Text("Deleted: \(probe.count)")
                TerminalFullKeyboard(isEnabled: true, keyboardControl: probe.control) { key in
                    if key == .backspace { probe.count += 1 }
                    probe.control.setModifierArmed([.control, .option, .shift], armed: false)
                }
                .frame(height: 320)
            }
        }
    }

    @Test func fullKeyboardKeepsRepeatingAcrossViewUpdates() async throws {
        let probe = KeyboardProbe()
        let controller = UIHostingController(rootView: KeyboardProbeView(probe: probe))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
        defer { window.isHidden = true }
        func findButton(in view: UIView) -> TerminalRepeatingBackspaceButton? {
            if let button = view as? TerminalRepeatingBackspaceButton { return button }
            return view.subviews.lazy.compactMap { findButton(in: $0) }.first
        }
        controller.view.layoutIfNeeded()
        let button = try #require(findButton(in: controller.view))
        let press = Press(button)
        #expect(button.isEnabled)
        press.begin()
        #expect(
            await repeatsReaching(3) { probe.count } >= 3,
            "A held full-keyboard Backspace must delete repeatedly")
        press.end()
        let count = probe.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(probe.count == count)
    }

    /// Waits for a held key to reach `target` repeats, and answers how many it
    /// reached.
    ///
    /// Each repeat arms the next on a main run loop timer, so a machine that
    /// stalls the main thread delays the whole chain without changing the
    /// behaviour under test. Sampling the count at a fixed instant measures
    /// that stall as well as the repeat, and the margin was under two repeats:
    /// a 650ms hold lands 5 or 6 deletes with the timers on schedule, and the
    /// app lane twice reported 1 — the same assertion, the same count, on
    /// 2026-09-16 and again on 2026-09-19, on unrelated branches. That lane's
    /// wall clock for one run of these suites has ranged from 59s to 135s, so
    /// no fixed window in this suite was safe.
    ///
    /// Waiting keeps the assertion on the behaviour rather than on the clock.
    /// A hold that never repeats still fails; it just takes the timeout to
    /// say so.
    private func repeatsReaching(
        _ target: Int, within timeout: Duration = .seconds(5), count: () -> Int
    ) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while count() < target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return count()
    }

    private func host(action: @escaping () -> Void) async throws -> (TerminalRepeatingBackspaceButton, UIWindow) {
        let button = TerminalRepeatingBackspaceButton(action: action)
        button.frame = CGRect(x: 0, y: 0, width: 100, height: 44)
        let controller = UIViewController()
        controller.view.addSubview(button)
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 200, height: 100), rootViewController: controller)
        return (button, window)
    }

    @Test func shortTapAndAccessibilityActivationEachDeleteOnce() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let press = Press(button)
        press.begin()
        try await Task.sleep(for: .milliseconds(80))
        #expect(count == 0)
        press.end()
        #expect(count == 1)
        try await Task.sleep(for: .milliseconds(350))
        #expect(count == 1)
        #expect(button.accessibilityActivate())
        #expect(count == 2)
    }

    @Test func pressFeedbackKeepsAllFourEdgesHittable() async throws {
        let (button, window) = try await host {}
        defer { window.isHidden = true }
        let parent = try #require(button.superview)
        let restingFrame = button.frame
        let edgePoints = [
            CGPoint(x: restingFrame.minX + 0.1, y: restingFrame.midY),
            CGPoint(x: restingFrame.maxX - 0.1, y: restingFrame.midY),
            CGPoint(x: restingFrame.midX, y: restingFrame.minY + 0.1),
            CGPoint(x: restingFrame.midX, y: restingFrame.maxY - 0.1),
        ]
        func hitsButton(_ point: CGPoint) -> Bool {
            guard let hit = parent.hitTest(point, with: nil) else { return false }
            return hit === button || hit.isDescendant(of: button)
        }
        for point in edgePoints { #expect(hitsButton(point)) }
        button.isHighlighted = true
        #expect(button.frame == restingFrame)
        for point in edgePoints { #expect(hitsButton(point), "Press feedback lost the edge at \(point)") }
        button.isHighlighted = false
        for point in edgePoints { #expect(hitsButton(point)) }
    }

    @Test(arguments: 0..<4)
    func edgeHoldKeepsRepeatingAfterSmallFingerDrift(edge: Int) async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let points = [
            (CGPoint(x: 0.1, y: 22), CGPoint(x: -4, y: 22)),
            (CGPoint(x: 99.9, y: 22), CGPoint(x: 104, y: 22)),
            (CGPoint(x: 50, y: 0.1), CGPoint(x: 50, y: -4)),
            (CGPoint(x: 50, y: 43.9), CGPoint(x: 50, y: 48)),
        ]
        let press = Press(button)
        press.finger.point = points[edge].0
        press.begin()
        press.move(to: points[edge].1)
        #expect(await repeatsReaching(3) { count } >= 3)
        let beforeRelease = count
        press.end()
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == beforeRelease)
    }

    @Test func onlyAnExistingHoldToleratesSmallMovementPastTheEdge() async throws {
        let (button, window) = try await host {}
        defer { window.isHidden = true }
        let press = Press(button)
        let nearEdges = [
            CGPoint(x: -4, y: 22), CGPoint(x: 104, y: 22),
            CGPoint(x: 50, y: -4), CGPoint(x: 50, y: 48),
        ]
        for point in nearEdges { #expect(!button.point(inside: point, with: nil)) }
        press.begin()
        button.isHighlighted = true
        for point in nearEdges { #expect(button.point(inside: point, with: nil)) }
        #expect(!button.point(inside: CGPoint(x: 116, y: 22), with: nil))
        press.cancel()
        for point in nearEdges { #expect(!button.point(inside: point, with: nil)) }
    }

    @Test func holdStartsBeforeHalfASecondAndStopsWithoutAnExtraRelease() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let press = Press(button)
        let start = ContinuousClock.now
        press.begin()
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == 0)
        while count == 0 && start.duration(to: .now) < .milliseconds(450) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count > 0)
        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(await repeatsReaching(3) { count } >= 3)
        let beforeRelease = count
        press.end()
        try await Task.sleep(for: .milliseconds(200))
        #expect(count == beforeRelease)
        press.begin()
        press.end()
        #expect(count == beforeRelease + 1)
    }

    @Test func swipingOffBeforeTheDelayDoesNotDeleteOnReentry() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let press = Press(button)
        press.begin()
        press.move(to: CGPoint(x: -20, y: 22))
        try await Task.sleep(for: .milliseconds(350))
        press.move(to: CGPoint(x: 50, y: 22))
        press.end()
        #expect(count == 0)
        #expect(button.accessibilityActivate())
        #expect(count == 1)
    }

    enum Cancellation: CaseIterable {
        case dragExit, swipeWithinKey, touchCancel, recognizerReset, disabled, detached, inactive
    }

    @Test(arguments: Cancellation.allCases)
    func interruptedHoldStopsDeleting(cancellation: Cancellation) async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let press = Press(button)
        press.begin()
        let start = ContinuousClock.now
        while count == 0 && start.duration(to: .now) < .seconds(1) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count > 0)
        switch cancellation {
        case .dragExit: press.move(to: CGPoint(x: -20, y: 22))
        case .swipeWithinKey: press.move(to: CGPoint(x: 70, y: 22))
        case .touchCancel: press.cancel()
        case .recognizerReset:
            for recognizer in button.gestureRecognizers ?? [] { recognizer.reset() }
        case .disabled: button.isEnabled = false
        case .detached: button.removeFromSuperview()
        case .inactive:
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        }
        let stoppedCount = count
        press.end()
        try await Task.sleep(for: .milliseconds(200))
        #expect(count == stoppedCount)
    }
}
