import Foundation
import Testing
import UIKit

@testable import HerdrMobile

struct TerminalMouseReportingTests {
    @Test func sgrEncodingSeparatesPressFromRelease() {
        #expect(
            TerminalMouseEncoding.sgr.report(button: .left, column: 20, row: 10)
                == Data("\u{1B}[<0;20;10M".utf8))
        #expect(
            TerminalMouseEncoding.sgr.report(
                button: .left, column: 20, row: 10, isRelease: true)
                == Data("\u{1B}[<0;20;10m".utf8))
    }

    @Test func legacyEncodingBiasesEveryFieldByThirtyTwo() {
        #expect(
            TerminalMouseEncoding.legacy.report(button: .left, column: 1, row: 1)
                == Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
        // Release loses the button identity and reports 3 instead.
        #expect(
            TerminalMouseEncoding.legacy.report(
                button: .left, column: 1, row: 1, isRelease: true)
                == Data([0x1B, 0x5B, 0x4D, 35, 33, 33]))
        // Coordinates beyond the encodable range saturate rather than wrap.
        #expect(
            TerminalMouseEncoding.legacy.report(button: .left, column: 400, row: 400)
                == Data([0x1B, 0x5B, 0x4D, 32, 255, 255]))
    }

    @Test func clicksOnlyReportWhileTheApplicationTracksTheMouse() {
        var tracker = TerminalModeTracker()
        #expect(tracker.remoteClickSequence(column: 4, row: 2) == nil)

        tracker.receive(Data("\u{1B}[?1000h".utf8))
        #expect(
            tracker.remoteClickSequence(column: 4, row: 2)
                == Data([0x1B, 0x5B, 0x4D, 32, 36, 34, 0x1B, 0x5B, 0x4D, 35, 36, 34]))

        tracker.receive(Data("\u{1B}[?1006h".utf8))
        #expect(
            tracker.remoteClickSequence(column: 4, row: 2)
                == Data("\u{1B}[<0;4;2M\u{1B}[<0;4;2m".utf8))

        tracker.receive(Data("\u{1B}[?1000l".utf8))
        #expect(tracker.remoteClickSequence(column: 4, row: 2) == nil)
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

    @Test func gridMapperClampsTouchesToTheCentredGrid() {
        // 8×4 cells of 10×20 leaves 4 points across and 10 down: the grid
        // starts 2 points in from the left and 5 down from the top.
        let mapper = TerminalGridPointMapper(
            viewSize: CGSize(width: 84, height: 90),
            cellSize: CGSize(width: 10, height: 20),
            columns: 8,
            rows: 4)

        #expect(mapper.gridOrigin == CGPoint(x: 2, y: 5))
        #expect(mapper.cell(at: CGPoint(x: 2, y: 5)).map(Pair.init) == Pair(1, 1))
        #expect(mapper.cell(at: CGPoint(x: 11, y: 24)).map(Pair.init) == Pair(1, 1))
        #expect(mapper.cell(at: CGPoint(x: 12, y: 25)).map(Pair.init) == Pair(2, 2))
        // Touches in the inset and past the last cell fall on the edge.
        #expect(mapper.cell(at: CGPoint(x: 0, y: 0)).map(Pair.init) == Pair(1, 1))
        #expect(mapper.cell(at: CGPoint(x: 999, y: 999)).map(Pair.init) == Pair(8, 4))
    }

    @Test func gridMapperRejectsAnUnmeasuredGrid() {
        let mapper = TerminalGridPointMapper(
            viewSize: CGSize(width: 390, height: 720),
            cellSize: .zero,
            columns: 80,
            rows: 24)
        #expect(mapper.cell(at: CGPoint(x: 10, y: 10)) == nil)
    }

    /// The mapper's padding assumption is only as good as Ghostty's layout, so
    /// this drives the real surface: park the cursor on a known cell, tap where
    /// Ghostty draws it, and require the report to name that same cell.
    @MainActor
    @Test func tapsOnTheRenderedCursorReportItsOwnCell() async throws {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let controller = UIViewController()
        controller.view = terminal
        let windowScene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: windowScene)
        window.frame = terminal.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        terminal.receive(Data("\u{1B}[?1049h\u{1B}[?1000;1006h".utf8))
        terminal.layoutIfNeeded()
        try await settle()

        let row = 10
        let column = 20
        terminal.receive(Data("\u{1B}[\(row);\(column)H".utf8))
        try await settle()

        // Ghostty's IME rect is not the cursor cell: its x is the cell's left
        // edge but its y is the cell's vertical centre (the rect then extends
        // one cell down, where an IME candidate window would sit). minY is
        // therefore the one y inside the cursor's own row.
        let caret = terminal.caretRect(for: terminal.endOfDocument)
        #expect(!caret.isNull)
        let cursorPoint = CGPoint(x: caret.midX, y: caret.minY)
        let probe: Comment =
            "caret=\(caret) mapper=\(terminal.gridPointMapper) bounds=\(terminal.bounds)"
        #expect(terminal.clickTouch(at: cursorPoint))
        await Task.yield()

        #expect(
            sent == Data("\u{1B}[<0;\(column);\(row)M\u{1B}[<0;\(column);\(row)m".utf8),
            probe)
    }

    /// Without tracking a tap is only a keyboard affordance for the input row;
    /// with it, every cell is a target the TUI wants to hear about.
    @MainActor
    @Test func mouseTrackingOpensTheWholeSurfaceToTaps() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let tap = try #require(
            terminal.gestureRecognizers?
                .compactMap { $0 as? UITapGestureRecognizer }
                .first { $0.allowedTouchTypes.contains(directTouch) })

        // Off-window the caret has no rect, so there is no input row either.
        #expect(!terminal.gestureRecognizerShouldBegin(tap))

        terminal.receive(Data("\u{1B}[?1000h".utf8))
        #expect(terminal.gestureRecognizerShouldBegin(tap))
    }

    @MainActor
    @Test func tapsStaySilentWithoutMouseTracking() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })

        #expect(!terminal.clickTouch(at: CGPoint(x: 40, y: 40)))
        await Task.yield()
        #expect(sent.isEmpty)
    }

    @MainActor
    @Test func pausedInputSwallowsTheClick() async {
        var sent = Data()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSend: { sent.append($0) })
        terminal.receive(Data("\u{1B}[?1000;1006h".utf8))
        terminal.setLocalInputEnabled(false)

        #expect(!terminal.clickTouch(at: CGPoint(x: 40, y: 40)))
        await Task.yield()
        #expect(sent.isEmpty)
    }

    /// Ghostty needs a few render passes before its grid metrics settle.
    private func settle() async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(50))
            await Task.yield()
        }
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
