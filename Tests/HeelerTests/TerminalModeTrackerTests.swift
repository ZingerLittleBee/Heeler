import Foundation
import Testing

@testable import Heeler

@Suite("Terminal mode tracker")
struct TerminalModeTrackerTests {
    private static let trackedModes = "2004;1;1000;1049"

    private static func modes(of tracker: TerminalModeTracker) -> [String: Bool] {
        [
            "bracketedPaste": tracker.usesBracketedPaste,
            "cursorKeys": tracker.usesApplicationCursorKeys,
            "mouseTracking": tracker.tracksMouse,
            "alternateScreen": tracker.isAlternateScreen,
        ]
    }

    @Test func queryingSavingAndRestoringAModeLeavesItOn() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?\(Self.trackedModes)h".utf8))
        let allOn = [
            "bracketedPaste": true, "cursorKeys": true,
            "mouseTracking": true, "alternateScreen": true,
        ]
        #expect(Self.modes(of: tracker) == allOn)

        for mode in ["2004", "1", "1000", "1049", Self.trackedModes] {
            for sequence in ["\u{1B}[?\(mode)$p", "\u{1B}[?\(mode)s", "\u{1B}[?\(mode)r"] {
                tracker.receive(Data(sequence.utf8))
                #expect(Self.modes(of: tracker) == allOn, "\(sequence.dropFirst())")
            }
        }
    }

    @Test func queryingSavingAndRestoringAModeLeavesItOff() {
        var tracker = TerminalModeTracker()
        let allOff = [
            "bracketedPaste": false, "cursorKeys": false,
            "mouseTracking": false, "alternateScreen": false,
        ]

        for mode in ["2004", "1", "1000", "1049", Self.trackedModes] {
            for sequence in ["\u{1B}[?\(mode)$p", "\u{1B}[?\(mode)s", "\u{1B}[?\(mode)r"] {
                tracker.receive(Data(sequence.utf8))
                #expect(Self.modes(of: tracker) == allOff, "\(sequence.dropFirst())")
            }
        }
    }
}
