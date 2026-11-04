import Foundation
import Testing

@testable import Heeler

@Suite("Input shortcut strip presentation")
struct InputShortcutStripPresentationTests {
    @Test func theStripScrollsTheKeysAndPinsEnterAndMore() {
        let presentation = InputShortcutStripPresentation()
        #expect(presentation.items == InputShortcutStripPresentation.allItems)
        #expect(presentation.leadingItems == [
            .key(.escape), .key(.tab), .key(.shiftTab),
            .key(.up), .key(.down), .key(.left), .key(.right),
            .key(.backspace), .key(.shiftEnter), .paste,
        ])
        #expect(presentation.trailingItems == [.key(.enter), .more])
    }

    @Test func theShellTerminalStripDropsPasteAndMoreAndPinsEnter() {
        let presentation = InputShortcutStripPresentation(surface: .shellTerminal)
        #expect(presentation.leadingItems == [
            .key(.escape), .key(.tab), .key(.shiftTab),
            .key(.up), .key(.down), .key(.left), .key(.right),
            .key(.backspace), .key(.shiftEnter),
        ])
        #expect(presentation.trailingItems == [.key(.enter)])
        #expect(!presentation.items.contains(.paste))
        #expect(!presentation.items.contains(.more))
    }
}
