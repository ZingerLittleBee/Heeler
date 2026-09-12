import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Backspace hold timing", .serialized)
struct TerminalBackspaceButtonTests {
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
        button.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(80))
        #expect(count == 0)
        button.sendActions(for: .touchUpInside)
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

    @Test func onlyAnExistingHoldToleratesSmallMovementPastTheEdge() async throws {
        let (button, window) = try await host {}
        defer { window.isHidden = true }
        let nearEdges = [
            CGPoint(x: -4, y: 22), CGPoint(x: 104, y: 22),
            CGPoint(x: 50, y: -4), CGPoint(x: 50, y: 48),
        ]
        for point in nearEdges { #expect(!button.point(inside: point, with: nil)) }
        button.sendActions(for: .touchDown)
        button.isHighlighted = true
        for point in nearEdges { #expect(button.point(inside: point, with: nil)) }
        #expect(!button.point(inside: CGPoint(x: 116, y: 22), with: nil))
        button.sendActions(for: .touchCancel)
        for point in nearEdges { #expect(!button.point(inside: point, with: nil)) }
    }

    @Test func holdStartsBeforeHalfASecondAndStopsWithoutAnExtraRelease() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        let start = ContinuousClock.now
        button.sendActions(for: .touchDown)
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == 0)
        while count == 0 && start.duration(to: .now) < .milliseconds(450) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count > 0)
        #expect(start.duration(to: .now) < .milliseconds(500))
        try await Task.sleep(for: .milliseconds(170))
        #expect(count >= 3)
        let beforeRelease = count
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(200))
        #expect(count == beforeRelease)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchUpInside)
        #expect(count == beforeRelease + 1)
    }

    @Test func swipingOffBeforeTheDelayDoesNotDeleteOnReentry() async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragExit)
        try await Task.sleep(for: .milliseconds(350))
        button.sendActions(for: .touchDragEnter)
        button.sendActions(for: .touchUpInside)
        #expect(count == 0)
        #expect(button.accessibilityActivate())
        #expect(count == 1)
    }

    enum Cancellation: CaseIterable {
        case dragExit, touchCancel, disabled, detached, inactive
    }

    @Test(arguments: Cancellation.allCases)
    func interruptedHoldStopsDeleting(cancellation: Cancellation) async throws {
        var count = 0
        let (button, window) = try await host { count += 1 }
        defer { window.isHidden = true }
        button.sendActions(for: .touchDown)
        let start = ContinuousClock.now
        while count == 0 && start.duration(to: .now) < .seconds(1) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(count > 0)
        switch cancellation {
        case .dragExit: button.sendActions(for: .touchDragExit)
        case .touchCancel: button.sendActions(for: .touchCancel)
        case .disabled: button.isEnabled = false
        case .detached: button.removeFromSuperview()
        case .inactive:
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        }
        let stoppedCount = count
        button.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(200))
        #expect(count == stoppedCount)
    }
}
