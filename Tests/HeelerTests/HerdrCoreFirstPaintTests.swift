import Foundation
import Testing

@testable import Heeler

/// Reading a screen from the paint a real core sends: captures of `.ansi` screen
/// fixtures replayed in a fixture core's Terminal (`ChatFixtures/README.md`).
@Suite struct HerdrCoreFirstPaintTests {
    private static func paint(_ stem: String) throws -> Data {
        Data(try ChatFixture.text("screens/core-paint/\(stem).paint").utf8)
    }

    private static func screen(of data: Data) -> ANSIScreen? {
        var paint = HerdrCoreFirstPaint()
        return paint.receive(data)
    }

    @Test(arguments: [
        "claude-01-ready", "claude-02-c1-bash-blocked", "claude-14-c4-review", "codex-00-ready", "grok-03-working",
        "grok-12-permission-command", "opencode-09-armed-180", "opencode-10-permission-180",
    ])
    func aPaintReadsAsTheScreenItCameFrom(stem: String) throws {
        let screen = try #require(Self.screen(of: try Self.paint(stem)))
        let original = ANSIScreenDecoder.decode(try ScreenFixture.text(stem))
        let program = ScreenFixture.program(stem)

        #expect(screen.rows.map(\.trimmedText) == original.rows.map(\.trimmedText))
        #expect(
            InputBoxStateDetector.detect(screen, program: program)
                == InputBoxStateDetector.detect(original, program: program))
        #expect(
            BlockedDialogParser.parse(screen, program: program).fingerprint
                == BlockedDialogParser.parse(original, program: program).fingerprint)
    }

    @Test func aPaintCutAnywhereWaitsForTheWholeScreen() throws {
        let whole = try Self.paint("claude-02-c1-bash-blocked")
        // Inside a three-byte box character, then inside the closing mode itself.
        let box = try #require(whole.range(of: Data("▐".utf8)))
        let end = try #require(whole.range(of: Data("\u{1B}[?9001".utf8)))
        var paint = HerdrCoreFirstPaint()

        #expect(paint.receive(whole[..<(box.lowerBound + 1)]) == nil)
        #expect(paint.receive(whole[(box.lowerBound + 1)..<(end.lowerBound + 3)]) == nil)
        let last = paint.receive(whole[(end.lowerBound + 3)...])
        let screen = try #require(last)

        #expect(screen.rows[1].text.contains("▐"))
        #expect(screen.rows.count == 38)
    }

    @Test func outputAfterThePaintIsNotPartOfTheScreen() throws {
        let live = Data("live output\r\n".utf8)

        let screen = try #require(Self.screen(of: try Self.paint("modes-main-plain") + live))

        #expect(screen.rows.map(\.text) == ["plain main screen"])
    }

    /// A cursor waiting to wrap is restored by printing the row's last character.
    @Test func aRowFilledToItsEndIsNotReadWithItsCursorsLastCharacterAgain() throws {
        let paint = Data("\u{1B}[H\u{1B}[0mfull row\u{1B}[1;8Hw\u{1B}[0m\u{1B}[?9001l".utf8)

        let screen = try #require(Self.screen(of: paint))

        #expect(screen.rows.map(\.text) == ["full row"])
    }

    @Test func stylesSurviveAndTheAlternateScreenReadsLikeAnyOther() throws {
        let screen = try #require(Self.screen(of: try Self.paint("modes-alt-paste-kitty")))

        let hello = try #require(screen.rows.first?.runs.first)
        #expect(hello.text == "hello")
        #expect(hello.style == ScreenStyle(foreground: .indexed(1), isBold: true))
        #expect(screen.rows.first?.run(at: 6)?.style == ScreenStyle(isDim: true))
    }

    @Test func aPaintSetsTheModesTheProgramAsked() throws {
        var modes = TerminalModeTracker()

        modes.receive(try Self.paint("modes-alt-paste-kitty"))

        #expect(modes.isAlternateScreen)
        #expect(modes.usesBracketedPaste)
        #expect(modes.kittyKeyboardFlags == 9)
        #expect(modes.usesApplicationCursorKeys)
    }

    @Test func aPaintOfAPlainProgramTurnsEveryModeOff() throws {
        var modes = TerminalModeTracker()
        modes.receive(Data("\u{1B}[?2004h\u{1B}[>9u".utf8))

        modes.receive(try Self.paint("modes-main-plain"))

        #expect(!modes.usesBracketedPaste)
        #expect(modes.kittyKeyboardFlags == 0)
    }
}
