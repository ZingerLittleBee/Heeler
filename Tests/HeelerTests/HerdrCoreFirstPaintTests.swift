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

    // MARK: Holding the paint for one write

    /// Every output `hold` gives for `reads`, and the credit it returned on its own.
    private static func drain(
        _ hold: HerdrCoreFirstPaintHold, reads: [Data]
    ) async throws -> (outputs: [Data], credited: [Int]) {
        var pending = reads
        var outputs: [Data] = []
        var credited: [Int] = []
        while let output = try await hold.next(
            read: { pending.isEmpty ? nil : pending.removeFirst() }, credit: { credited.append($0) })
        {
            outputs.append(output)
        }
        return (outputs, credited)
    }

    @Test func aPaintCutInsideItsCloseComesOutWholeAndWhatSharedItsLastReadFollows() async throws {
        let paint = Data([0x18]) + Data("\u{1B}[!p\u{1B}[H\u{1B}[2Jrow one\r\nrow two\u{1B}[?9001l".utf8)
        let close = paint.count - 8
        let reads = [
            Data(paint[..<3]), Data(paint[3..<(close + 4)]),
            Data(paint[(close + 4)...]) + Data("live".utf8), Data("more".utf8),
        ]
        let hold = HerdrCoreFirstPaintHold()

        let (outputs, credited) = try await Self.drain(hold, reads: reads)

        #expect(outputs == [paint, Data("live".utf8), Data("more".utf8)])
        // Held reads return their credit on arrival, so the core keeps sending;
        // the consumer's report of them is not credited again.
        #expect(credited == [3, close + 1])
        #expect(hold.consumed(paint.count) == paint.count - (close + 4))
        #expect(hold.consumed(4) == 4)
    }

    @Test func outputThatDoesNotOpenAsAPaintPassesAsItComesAndCreditsAsConsumed() async throws {
        let hold = HerdrCoreFirstPaintHold()

        let (outputs, credited) = try await Self.drain(
            hold, reads: [Data("hello\r\n".utf8), Data("\u{1B}[!p".utf8)])

        #expect(outputs == [Data("hello\r\n".utf8), Data("\u{1B}[!p".utf8)])
        #expect(credited.isEmpty)
        #expect(hold.consumed(7) == 7)
    }

    @Test func aPaintThatOutgrowsTheLimitBeforeItsClosePassesAsItComes() async throws {
        let hold = HerdrCoreFirstPaintHold(limit: 8)

        let (outputs, credited) = try await Self.drain(
            hold, reads: [Data("\u{1B}[!p".utf8), Data("row\r\n".utf8), Data("more".utf8)])

        #expect(outputs == [Data("\u{1B}[!prow\r\n".utf8), Data("more".utf8)])
        #expect(credited == [4])
    }

    @Test func outputThatEndsBeforeThePaintClosesHandsOverWhatCame() async throws {
        let hold = HerdrCoreFirstPaintHold()

        let (outputs, _) = try await Self.drain(hold, reads: [Data("\u{1B}[!prow".utf8)])

        #expect(outputs == [Data("\u{1B}[!prow".utf8)])
    }
}
