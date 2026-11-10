import Foundation
import Testing

@testable import Heeler

/// A tmux Pane's first paint (ADR 0043): its modes and captured screens, as
/// bytes that put a terminal showing only that Pane where tmux has it.
@Suite("tmux pane paint")
struct TmuxPanePaintTests {
    private let escape = "\u{1B}"

    private func lines(_ text: String...) -> [Data] {
        text.map { Data($0.utf8) }
    }

    /// The modes line as tmux prints it for the format, field by field.
    private func modesLine(
        cursor: (Int, Int) = (3, 1), cursorFlag: Int = 1, alternate: Int = 0, saved: (Int, Int) = (0, 0),
        region: (Int, Int) = (0, 3), keypadCursor: Int = 0, keypad: Int = 0,
        mouse: [Int] = [0, 0, 0, 0, 0], insert: Int = 0, wrap: Int = 1, origin: Int = 0,
        history: Int = 0, size: (Int, Int) = (20, 4), bracketedPaste: String = ""
    ) -> Data {
        let fields: [String] = [
            "%3", "@2", "\(size.0)", "\(size.1)", "\(history)", "\(cursor.0)", "\(cursor.1)", "\(cursorFlag)",
            "\(alternate)", "\(saved.0)", "\(saved.1)", "\(region.0)", "\(region.1)", "\(keypadCursor)", "\(keypad)",
        ] + mouse.map(String.init) + ["\(insert)", "\(wrap)", "\(origin)", bracketedPaste]
        return Data(fields.joined(separator: " ").utf8)
    }

    private func modes(_ line: Data) throws -> TmuxPaneModes {
        try #require(TmuxPaneModes(line))
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: Commands

    @Test func aPaintAsksForTheModesThenTheHistoryThenBothScreens() {
        let commands = TmuxPanePaint.commands(pane: "%3", includingHistory: true).map(\.line)
        #expect(
            commands == [
                "display-message -p -t '%3' '\(TmuxPanePaint.modesFormat)'",
                "capture-pane -p -e -t '%3' -S -10000 -E -1",
                "capture-pane -p -e -t '%3'",
                "capture-pane -p -e -a -q -t '%3'",
            ])
        #expect(
            TmuxPanePaint.commands(pane: "%3", includingHistory: false).map(\.line)
                == [commands[0], commands[2], commands[3]])
    }

    @Test func theModesFormatNamesEveryFieldInOrder() {
        #expect(
            TmuxPanePaint.modesFormat
                == "#{pane_id} #{window_id} #{pane_width} #{pane_height} #{history_size} #{cursor_x} #{cursor_y} "
                + "#{cursor_flag} #{alternate_on} #{alternate_saved_x} #{alternate_saved_y} "
                + "#{scroll_region_upper} #{scroll_region_lower} #{keypad_cursor_flag} #{keypad_flag} "
                + "#{mouse_standard_flag} #{mouse_button_flag} #{mouse_all_flag} #{mouse_utf8_flag} "
                + "#{mouse_sgr_flag} #{insert_flag} #{wrap_flag} #{origin_flag} #{bracket_paste_flag}")
    }

    // MARK: Modes

    /// tmux 3.3a has no `bracket_paste_flag` and prints nothing for it.
    @Test func modesReadFromTmux33SayNothingOfBracketedPaste() throws {
        let read = try modes(modesLine(mouse: [1, 0, 0, 0, 1], history: 12))
        #expect(read.paneID == "%3")
        #expect(read.windowID == "@2")
        #expect(read.width == 20 && read.height == 4)
        #expect(read.historySize == 12)
        #expect(read.cursorX == 3 && read.cursorY == 1)
        #expect(read.cursorVisible)
        #expect(!read.alternateScreen)
        #expect(read.mouseStandard && read.mouseSGR && !read.mouseButton)
        #expect(read.bracketedPaste == nil)
    }

    @Test func modesReadFromTmux37SayWhetherBracketedPasteIsOn() throws {
        #expect(try modes(modesLine(bracketedPaste: "1")).bracketedPaste == true)
        #expect(try modes(modesLine(bracketedPaste: "0")).bracketedPaste == false)
    }

    @Test func aModesLineMissingFieldsIsNotRead() {
        #expect(TmuxPaneModes(Data("%3 @2 20 4".utf8)) == nil)
        #expect(TmuxPaneModes(Data("%3 @2 wide 4 0 0 0 1 0 0 0 0 3 0 0 0 0 0 0 0 0 1 0 ".utf8)) == nil)
    }

    // MARK: Bytes

    @Test func aPaneOnItsNormalScreenIsPaintedRowByRowWithItsCursor() throws {
        let paint = TmuxPanePaint.bytes(
            modes: try modes(modesLine(cursor: (3, 1))),
            history: nil,
            screen: lines("\(escape)[1mone", "two", "", ""),
            normalScreen: [],
            viewRows: 4)
        #expect(
            text(paint)
                == TmuxPanePaint.reset + "\(escape)[H\(escape)[2J"
                + "\(escape)[0m\(escape)[1;1H\(escape)[1mone\(escape)[2;1Htwo\(escape)[3;1H\(escape)[4;1H\(escape)[0m"
                + "\(escape)[2;4H")
    }

    @Test func historyGoesAboveTheScreenIntoTheTerminalsScrollback() throws {
        let paint = text(
            TmuxPanePaint.bytes(
                modes: try modes(modesLine(cursor: (0, 0), history: 2)),
                history: lines("old one", "old two"),
                screen: lines("now", "", "", ""),
                normalScreen: [],
                viewRows: 6))
        #expect(
            paint.hasPrefix(
                TmuxPanePaint.reset + "\(escape)[H\(escape)[2J\(escape)[3J"
                    + "\(escape)[0mold one\r\nold two\r\n\(escape)[0m\(escape)[6;1H\n\n"
                    + "\(escape)[0m\(escape)[1;1Hnow"))
    }

    /// With no history, tmux captures the screen's top row for the range.
    @Test func historyOfAPaneWithNoneIsIgnored() throws {
        let paint = text(
            TmuxPanePaint.bytes(
                modes: try modes(modesLine(history: 0)),
                history: lines("now"),
                screen: lines("now", "", "", ""),
                normalScreen: [],
                viewRows: 4))
        #expect(!paint.contains("now\r\n"))
        #expect(paint.contains("\(escape)[3J"))
    }

    @Test func aTallHistoryIsPushedUpByTheViewsRowsLessOne() throws {
        let history = (1...30).map { "line \($0)" }
        let paint = text(
            TmuxPanePaint.bytes(
                modes: try modes(modesLine(history: 30)),
                history: history.map { Data($0.utf8) },
                screen: lines("", "", "", ""),
                normalScreen: [],
                viewRows: 5))
        #expect(paint.contains("line 30\r\n\(escape)[0m\(escape)[5;1H\n\n\n\n\(escape)[0m"))
    }

    @Test func aPaneOnItsAlternateScreenPaintsTheNormalOneBeneathIt() throws {
        let paint = text(
            TmuxPanePaint.bytes(
                modes: try modes(modesLine(cursor: (5, 2), alternate: 1, saved: (7, 3))),
                history: nil,
                screen: lines("alt", "", "", ""),
                normalScreen: lines("$ vim", "", "", ""),
                viewRows: 4))
        #expect(
            paint
                == TmuxPanePaint.reset + "\(escape)[H\(escape)[2J"
                + "\(escape)[0m\(escape)[1;1H$ vim\(escape)[2;1H\(escape)[3;1H\(escape)[4;1H\(escape)[0m"
                + "\(escape)[4;8H\(escape)[?1049h"
                + "\(escape)[0m\(escape)[1;1Halt\(escape)[2;1H\(escape)[3;1H\(escape)[4;1H\(escape)[0m"
                + "\(escape)[3;6H")
    }

    @Test func thePanesModesAreSetAfterItsScreens() throws {
        let paint = text(
            TmuxPanePaint.bytes(
                modes: try modes(
                    modesLine(
                        cursor: (0, 2), cursorFlag: 0, region: (1, 2), keypadCursor: 1, keypad: 1,
                        mouse: [1, 1, 1, 1, 1], insert: 1, wrap: 0, origin: 1, bracketedPaste: "1")),
                history: nil,
                screen: lines("", "", "", ""),
                normalScreen: [],
                viewRows: 4))
        #expect(
            paint.hasSuffix(
                "\(escape)[2;3r\(escape)[?6h\(escape)[?1h\(escape)=\(escape)[?1000h\(escape)[?1002h\(escape)[?1003h"
                    + "\(escape)[?1005h\(escape)[?1006h\(escape)[?2004h\(escape)[4h\(escape)[?7l\(escape)[?25l"
                    + "\(escape)[2;1H"))
    }

    /// The terminal's own mode tracking reads the paint as the Pane's modes, and
    /// a second paint undoes what the first set.
    @Test func theTerminalsModeTrackingFollowsEachPaint() throws {
        var tracker = TerminalModeTracker()
        tracker.receive(
            TmuxPanePaint.bytes(
                modes: try modes(
                    modesLine(alternate: 1, keypadCursor: 1, mouse: [0, 1, 0, 0, 1], bracketedPaste: "1")),
                history: nil, screen: lines("", "", "", ""), normalScreen: lines("", "", "", ""), viewRows: 4))
        #expect(tracker.isAlternateScreen)
        #expect(tracker.usesApplicationCursorKeys)
        #expect(tracker.tracksMouse && tracker.usesSGRMouseEncoding)
        #expect(tracker.usesBracketedPaste)

        tracker.receive(
            TmuxPanePaint.bytes(
                modes: try modes(modesLine()), history: nil, screen: lines("", "", "", ""), normalScreen: [],
                viewRows: 4))
        #expect(!tracker.isAlternateScreen)
        #expect(!tracker.usesApplicationCursorKeys)
        #expect(!tracker.tracksMouse && !tracker.usesSGRMouseEncoding)
        #expect(!tracker.usesBracketedPaste)
    }
}
