import Foundation
import Testing

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
}
