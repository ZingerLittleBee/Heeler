import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Terminal full keyboard layout", .serialized)
struct TerminalFullKeyboardLayoutTests {
    @Test(arguments: [320, 390, 600, 834, 1024, 1366])
    func rowsFillTheAvailableWidthWithoutChangingHeight(width: Int) {
        for height in [220, 320, 420] {
            let layout = TerminalFullKeyboardLayout(size: CGSize(width: width, height: height))
            let gap = layout.keySpacing
            let character = layout.characterWidth
            let fullRow = 10 * character + 9 * gap
            let homeRow = 9 * character + 8 * gap + 2 * layout.homeRowInset
            let bottomRow = 9 * layout.bottomKeyWidth + layout.spaceWidth + 9 * gap
            for occupiedWidth in [fullRow, homeRow, bottomRow] {
                #expect(abs(occupiedWidth - layout.contentWidth) < 0.001)
            }
            for count in [6, 7] {
                let lowerRow = CGFloat(count) * character + CGFloat(count + 1) * gap
                    + 2 * layout.sideKeyWidth(characterCount: count)
                #expect(abs(lowerRow - layout.contentWidth) < 0.001)
                #expect(layout.sideKeyWidth(characterCount: count) > character)
            }
            #expect(layout.spaceWidth > 2 * character)
            #expect(abs(6 * layout.rowHeight + 5 * TerminalFullKeyboardLayout.rowSpacing
                + 12 - CGFloat(height)) < 0.001)
            #expect(layout.rowHeight == TerminalFullKeyboardLayout(
                size: CGSize(width: 390, height: height)).rowHeight)
        }
    }
}
