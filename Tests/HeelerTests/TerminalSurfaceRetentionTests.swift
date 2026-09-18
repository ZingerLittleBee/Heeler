import Foundation
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Retained terminal surfaces")
struct TerminalSurfaceRetentionTests {
    @Test func offscreenBytesReachTheSameEmulatorOnReturn() {
        let retention = TerminalSurfaceRetention()
        let feed = TerminalByteFeed()
        let surface = retention.surface(for: feed) {
            TerminalScreenView.makeConfiguredTerminal()
        }
        feed.attach(surface)
        retention.detachCallbacks()
        feed.write(Data("\u{1B}[?1049h\u{1B}[?1000h".utf8))

        let returned = retention.surface(for: feed) {
            TerminalScreenView.makeConfiguredTerminal()
        }
        #expect(returned === surface)
        #expect(returned.isAlternateScreen)
        #expect(returned.remoteTracksMouse)
        #expect(!returned.isLocalInputEnabled)
        retention.clear()
    }

    @Test func replacementFeedGetsAFreshSurfaceAndDisablesOldInput() {
        let retention = TerminalSurfaceRetention()
        let firstFeed = TerminalByteFeed()
        let first = retention.surface(for: firstFeed) {
            TerminalScreenView.makeConfiguredTerminal()
        }
        first.setLocalInputEnabled(true)
        firstFeed.attach(first)
        firstFeed.write(Data("\u{1B}[?1049h".utf8))
        let next = retention.surface(for: TerminalByteFeed()) {
            TerminalScreenView.makeConfiguredTerminal()
        }
        #expect(first !== next)
        #expect(!next.isAlternateScreen)
        #expect(!first.isLocalInputEnabled)
        retention.clear()
    }

    /// Replacement happens inside `makeUIView`, during SwiftUI's graph
    /// update. Resigning first responder there re-enters the graph and
    /// aborts, so the retired surface must keep the responder for the moment
    /// and give it up on the next run-loop turn.
    @Test func replacingAFirstResponderSurfaceResignsItOnTheNextTurn() async throws {
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }
        let retention = TerminalSurfaceRetention()
        let first = retention.surface(for: TerminalByteFeed()) {
            TerminalScreenView.makeConfiguredTerminal(notificationCenter: NotificationCenter())
        }
        first.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(first)
        first.requestKeyboard()
        try #require(first.isFirstResponder)

        let next = retention.surface(for: TerminalByteFeed()) {
            TerminalScreenView.makeConfiguredTerminal(notificationCenter: NotificationCenter())
        }
        #expect(first !== next)
        #expect(!first.isLocalInputEnabled)
        #expect(first.isFirstResponder, "the responder is released after the graph update, not inside it")

        for _ in 0..<40 where first.isFirstResponder {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!first.isFirstResponder)
        retention.clear()
    }

    /// A surface retired and re-enabled within the same turn (a return to
    /// the same feed) keeps its keyboard: the deferred release is skipped.
    @Test func reEnablingBeforeTheDeferredReleaseKeepsTheKeyboard() async throws {
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }
        let surface = TerminalScreenView.makeConfiguredTerminal(notificationCenter: NotificationCenter())
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(surface)
        surface.requestKeyboard()
        try #require(surface.isFirstResponder)

        surface.retireLocalInput()
        surface.setLocalInputEnabled(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.isFirstResponder)
        surface.dismissKeyboard()
    }

    /// A surface leaving for a screen that inherits its keyboard keeps first
    /// responder: resigning would start UIKit's hide before the destination
    /// exists, and its claim could then only bring the keyboard back up
    /// after it had dropped. Input still stops at once.
    @Test func retiringWhileKeepingTheKeyboardStopsInputWithoutResigning() async throws {
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }
        let retention = TerminalSurfaceRetention()
        let surface = retention.surface(for: TerminalByteFeed()) {
            TerminalScreenView.makeConfiguredTerminal(notificationCenter: NotificationCenter())
        }
        surface.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(surface)
        surface.requestKeyboard()
        try #require(surface.isFirstResponder)

        retention.detachCallbacks(keepingKeyboard: true)
        #expect(!surface.isLocalInputEnabled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(surface.isFirstResponder, "the destination's claim ends the responder, not this")

        // The next screen's claim takes it over without a dismissal.
        let next = TerminalScreenView.makeConfiguredTerminal(notificationCenter: NotificationCenter())
        next.frame = CGRect(x: 0, y: 400, width: 390, height: 300)
        host.view.addSubview(next)
        next.requestKeyboard()
        #expect(next.isFirstResponder)
        #expect(!surface.isFirstResponder)
        next.dismissKeyboard()
        retention.clear()
    }
}
