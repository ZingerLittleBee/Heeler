import Testing

@testable import Heeler

/// The Agent detail state for a Host whose terminal channel is live in
/// another window.
@Suite("Live in another window presentation")
struct LiveInAnotherWindowPresentationTests {
    @Test func aHoldingWindowShowsNothingNew() {
        #expect(LiveInAnotherWindowPresentation(access: .holds) == nil)
    }

    @Test func anotherWindowsAttachOffersTakeOver() throws {
        let presentation = try #require(
            LiveInAnotherWindowPresentation(access: .liveInAnotherWindow))

        #expect(presentation.title == "Live in Another Window")
        #expect(presentation.message.contains("input continues there"))
        #expect(LiveInAnotherWindowPresentation.takeOverTitle == "Take Over Here")
    }

    /// Not a spinner: the window is not connecting, it is waiting on a
    /// deliberate handoff.
    @Test func itIsNotTheConnectingState() throws {
        let presentation = try #require(
            LiveInAnotherWindowPresentation(access: .liveInAnotherWindow))

        #expect(presentation.title != TerminalStatusPresentation.connecting.title)
    }
}
