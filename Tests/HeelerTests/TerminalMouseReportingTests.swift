import Foundation
import Testing

@testable import Heeler

struct TerminalMouseReportingTests {
    @Test func sgrEncodingSeparatesWheelDirections() {
        #expect(
            TerminalMouseEncoding.sgr.report(button: .wheelUp, column: 20, row: 10)
                == Data("\u{1B}[<64;20;10M".utf8))
        #expect(
            TerminalMouseEncoding.sgr.report(
                button: .wheelDown, column: 20, row: 10)
                == Data("\u{1B}[<65;20;10M".utf8))
    }

    @Test func legacyEncodingBiasesEveryFieldByThirtyTwo() {
        #expect(
            TerminalMouseEncoding.legacy.report(button: .wheelUp, column: 1, row: 1)
                == Data([0x1B, 0x5B, 0x4D, 96, 33, 33]))
        #expect(
            TerminalMouseEncoding.legacy.report(
                button: .wheelDown, column: 1, row: 1)
                == Data([0x1B, 0x5B, 0x4D, 97, 33, 33]))
        // Coordinates beyond the encodable range saturate rather than wrap.
        #expect(
            TerminalMouseEncoding.legacy.report(button: .wheelUp, column: 400, row: 400)
                == Data([0x1B, 0x5B, 0x4D, 96, 255, 255]))
    }

    @Test func bracketedPasteFollowsDECSET2004() {
        var tracker = TerminalModeTracker()
        #expect(!tracker.usesBracketedPaste)

        tracker.receive(Data("\u{1B}[?2004h".utf8))
        #expect(tracker.usesBracketedPaste)

        tracker.receive(Data("\u{1B}[?2004l".utf8))
        #expect(!tracker.usesBracketedPaste)
    }

    @Test func bracketedPasteIsPickedOutOfACombinedModeList() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?1049;1006;2004h".utf8))

        #expect(tracker.usesBracketedPaste)
        #expect(tracker.isAlternateScreen)
        #expect(tracker.usesSGRMouseEncoding)
    }

    @Test func gridMapperAnchorsTheGridAtGhosttysFixedPadding() {
        // Ghostty's default padding is floor(2pt · 96/72 · scale) pixels:
        // 5px = 2.5pt at 2x, 8px = 8/3pt at 3x. Leftover space past the last
        // whole cell stays on the right and bottom, so the origin is fixed.
        let at2x = TerminalGridPointMapper(
            viewSize: CGSize(width: 84, height: 90),
            cellSize: CGSize(width: 10, height: 20),
            columns: 8,
            rows: 4,
            scale: 2)

        #expect(at2x.gridOrigin == CGPoint(x: 2.5, y: 2.5))
        #expect(at2x.cell(at: CGPoint(x: 2.5, y: 2.5)).map(Pair.init) == Pair(1, 1))
        #expect(at2x.cell(at: CGPoint(x: 12.4, y: 22.4)).map(Pair.init) == Pair(1, 1))
        #expect(at2x.cell(at: CGPoint(x: 12.5, y: 22.5)).map(Pair.init) == Pair(2, 2))
        // Touches in the padding and past the last cell fall on the edge.
        #expect(at2x.cell(at: CGPoint(x: 0, y: 0)).map(Pair.init) == Pair(1, 1))
        #expect(at2x.cell(at: CGPoint(x: 999, y: 999)).map(Pair.init) == Pair(8, 4))

        let at3x = TerminalGridPointMapper(
            viewSize: CGSize(width: 84, height: 90),
            cellSize: CGSize(width: 10, height: 20),
            columns: 8,
            rows: 4,
            scale: 3)
        #expect(at3x.gridOrigin == CGPoint(x: 8.0 / 3, y: 8.0 / 3))
    }

    @Test func gridMapperRejectsAnUnmeasuredGrid() {
        let mapper = TerminalGridPointMapper(
            viewSize: CGSize(width: 390, height: 720),
            cellSize: .zero,
            columns: 80,
            rows: 24,
            scale: 3)
        #expect(mapper.cell(at: CGPoint(x: 10, y: 10)) == nil)
    }

    /// Tuple results are not `Equatable`; this keeps the expectations readable.
    private struct Pair: Equatable {
        let column: Int
        let row: Int

        init(_ cell: (column: Int, row: Int)) {
            column = cell.column
            row = cell.row
        }

        init(_ column: Int, _ row: Int) {
            self.column = column
            self.row = row
        }
    }
}
