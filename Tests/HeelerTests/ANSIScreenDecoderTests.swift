import Foundation
import Testing

@testable import Heeler

@Suite("ANSI screen decoder")
struct ANSIScreenDecoderTests {
    private static let esc = "\u{1B}"

    @Test("Basic attributes switch on and off")
    func attributes() {
        let screen = ANSIScreenDecoder.decode(
            "a\(Self.esc)[1mb\(Self.esc)[2mc\(Self.esc)[22md\(Self.esc)[3;7me\(Self.esc)[23;27mf")
        let runs = screen.rows[0].runs
        #expect(runs.map(\.text) == ["a", "b", "c", "d", "e", "f"])
        #expect(runs[0].style == .plain)
        #expect(runs[1].style == ScreenStyle(isBold: true))
        #expect(runs[2].style == ScreenStyle(isBold: true, isDim: true))
        #expect(runs[3].style == .plain)
        #expect(runs[4].style == ScreenStyle(isItalic: true, isReverse: true))
        #expect(runs[5].style == .plain)
    }

    @Test("Colors in every spelling the Agents use")
    func colors() {
        let screen = ANSIScreenDecoder.decode(
            [
                "\(Self.esc)[38;2;177;185;249ma\(Self.esc)[48;2;55;55;55mb\(Self.esc)[39;49mc",
                "\(Self.esc)[38;5;208md\(Self.esc)[48;5;17me\(Self.esc)[0mf",
                "\(Self.esc)[31mg\(Self.esc)[92mh\(Self.esc)[44mi\(Self.esc)[103mj\(Self.esc)[mk",
                "\(Self.esc)[38:2::1:2:3ml\(Self.esc)[38:2:4:5:6mm\(Self.esc)[48:5:9mn",
            ].joined(separator: "\r\n"))
        let styles = screen.rows.flatMap(\.runs).map(\.style)
        #expect(styles[0].foreground == .rgb(177, 185, 249))
        #expect(styles[1] == ScreenStyle(foreground: .rgb(177, 185, 249), background: .rgb(55, 55, 55)))
        #expect(styles[2] == .plain)
        #expect(styles[3].foreground == .indexed(208))
        #expect(styles[4] == ScreenStyle(foreground: .indexed(208), background: .indexed(17)))
        #expect(styles[5] == .plain)
        #expect(styles[6].foreground == .indexed(1))
        #expect(styles[7].foreground == .indexed(10))
        #expect(styles[8].background == .indexed(4))
        #expect(styles[9].background == .indexed(11))
        #expect(styles[10] == .plain)
        #expect(styles[11].foreground == .rgb(1, 2, 3))
        #expect(styles[12].foreground == .rgb(4, 5, 6))
        #expect(styles[13].background == .indexed(9))
    }

    @Test("Unknown SGR codes and other escape sequences change nothing")
    func ignoredSequences() {
        let screen = ANSIScreenDecoder.decode(
            "\(Self.esc)[1ma\(Self.esc)[4;53;58;5;3mb\(Self.esc)[2J\(Self.esc)[10;4Hc"
                + "\(Self.esc)]0;title\u{07}d\(Self.esc)]8;;https://x\(Self.esc)\\e\(Self.esc)(Bf")
        #expect(screen.rows.count == 1)
        #expect(screen.rows[0].text == "abcdef")
        #expect(screen.rows[0].runs.count == 1)
        #expect(screen.rows[0].runs[0].style == ScreenStyle(isBold: true))
    }

    @Test("Style carries from one row to the next")
    func styleCarriesAcrossRows() {
        let screen = ANSIScreenDecoder.decode("\(Self.esc)[2ma\r\nb\(Self.esc)[0m\r\nc")
        #expect(screen.rows.map(\.text) == ["a", "b", "c"])
        #expect(screen.rows[1].runs[0].style == ScreenStyle(isDim: true))
        #expect(screen.rows[2].runs[0].style == .plain)
    }

    @Test("CRLF and LF both end rows; a final line break adds no row")
    func rowSeparators() {
        #expect(ANSIScreenDecoder.decode("a\r\n\r\nb\r\n").rows.map(\.text) == ["a", "", "b"])
        #expect(ANSIScreenDecoder.decode("a\nb").rows.map(\.text) == ["a", "b"])
        #expect(ANSIScreenDecoder.decode("a\r\n  ").rows.map(\.text) == ["a", "  "])
        #expect(ANSIScreenDecoder.decode("").rows.count == 1)
    }

    @Test("Wide characters take two cells and shift later runs")
    func cellWidths() {
        let screen = ANSIScreenDecoder.decode("下执行\(Self.esc)[1m，ok\(Self.esc)[0m❯ é🙂x")
        let runs = screen.rows[0].runs
        #expect(runs.map(\.column) == [0, 6, 10])
        #expect(runs.map(\.width) == [6, 4, 6])
        #expect(screen.columns == 16)
        #expect(TerminalCellWidth.width(of: "e\u{301}") == 1)
        #expect(TerminalCellWidth.width(of: "⚠️") == 2)
        #expect(TerminalCellWidth.width(of: "⚠") == 1)
        #expect(TerminalCellWidth.width(of: "─╌▔⏺⎿☐✔") == 7)
    }

    @Test("A tab advances to the next multiple of eight")
    func tabs() {
        let screen = ANSIScreenDecoder.decode("ab\tc")
        #expect(screen.rows[0].text == "ab      c")
    }

    @Test("Columns come from the widest row, trailing spaces included")
    func columnInference() throws {
        #expect(try ScreenFixture.screen("claude-27-n1-narrow-bash").columns == 40)
        #expect(try ScreenFixture.screen("codex-12-x5-narrow-exec").columns == 40)
        // Claude draws one cell short of a 120-column pane.
        #expect(try ScreenFixture.screen("claude-02-c1-bash-blocked").columns == 119)
        #expect(try ScreenFixture.screen("codex-01-x1-exec").columns == 120)
    }

    @Test("The residue row keeps each color as its own run")
    func residueRuns() throws {
        let row = try ScreenFixture.screen("claude-27-n1-narrow-bash").rows[27]
        #expect(row.text == "   4. Nor you")
        let inactive = ScreenStyle(foreground: .rgb(153, 153, 153))
        #expect(row.runs.map(\.text) == ["   ", "4. ", "No", "r you"])
        #expect(row.runs.map(\.style) == [.plain, inactive, .plain, inactive])
        #expect(row.runs.map(\.column) == [0, 3, 6, 8])
    }

    @Test("A row of CJK text fills the 40-column pane")
    func cjkRow() throws {
        let row = try ScreenFixture.screen("claude-27-n1-narrow-bash").rows[0]
        #expect(row.width == 40)
        #expect(row.contentWidth == 40)
    }

    @Test("Claude's prompt keeps its no-break space")
    func noBreakSpace() throws {
        let row = try ScreenFixture.screen("claude-01-ready").rows[35]
        #expect(row.text == "❯\u{00A0} ")
        #expect(row.runs.last?.style == ScreenStyle(isReverse: true))
        #expect(row.trimmedText == "❯")
        #expect(row.indent == 0)
    }

    @Test("Every capture decodes into contiguous runs within its columns", arguments: ScreenFixture.all)
    func everyCapture(stem: String) throws {
        let text = try ScreenFixture.text(stem)
        let screen = ANSIScreenDecoder.decode(text)
        #expect(screen.rows.count == text.components(separatedBy: "\r\n").count)
        #expect(screen.columns >= 40)
        for row in screen.rows {
            #expect(!row.text.contains("\u{1B}"))
            #expect(row.width <= screen.columns)
            var column = 0
            for run in row.runs {
                #expect(run.column == column)
                #expect(!run.text.isEmpty)
                column = run.endColumn
            }
        }
    }
}
