import Foundation
import Testing

@testable import Heeler

/// Drives the paint engine by hand: it answers reads and passes waits as
/// each test says, and keeps what the engine emitted.
struct PaintHarness {
    var engine: RexTerminalPaint
    var emitted: [RexTerminalInstruction] = []
    var reads: [(read: RexTerminalRead, id: UInt64)] = []
    /// The latest wait asked for; the engine has one at a time.
    var wait: (duration: Duration, id: UInt64)?

    init(_ configure: (inout RexTerminalPaint.Parameters) -> Void = { _ in }) {
        var parameters = RexTerminalPaint.Parameters()
        configure(&parameters)
        engine = RexTerminalPaint(parameters: parameters)
    }

    static let grid = RexTerminalGrid(columns: 80, rows: 24, cellWidth: 9, cellHeight: 18, owner: "client:a")

    var pendingReads: [RexTerminalRead] { reads.map(\.read) }

    mutating func take(_ effects: [RexTerminalPaint.Effect]) {
        for effect in effects {
            switch effect {
            case .emit(let instruction): emitted.append(instruction)
            case .read(let read, let id): reads.append((read, id))
            case .wait(let duration, let id): wait = (duration, id)
            }
        }
    }

    /// What was emitted since the last call.
    mutating func drain() -> [RexTerminalInstruction] {
        defer { emitted = [] }
        return emitted
    }

    mutating func resize(_ grid: RexTerminalGrid = PaintHarness.grid) {
        take(engine.receive([.message(.resize(grid))]))
    }

    mutating func message(_ message: RexStreamMessage) {
        take(engine.receive([.message(message)]))
    }

    mutating func output(_ text: String) {
        take(engine.receive([.program(Data(text.utf8))]))
    }

    mutating func answer(where matches: (RexTerminalRead) -> Bool, with answer: RexTerminalAnswer) {
        guard let index = reads.firstIndex(where: { matches($0.read) }) else {
            Issue.record("No read pending for \(answer); pending: \(pendingReads)")
            return
        }
        let id = reads.remove(at: index).id
        take(engine.answered(answer, id: id))
    }

    mutating func answerModes(wraparound: Bool? = true) {
        answer(where: { $0 == .modes }, with: .modes(wraparound: wraparound))
    }

    mutating func answerRedraw(_ vt: String, next: Int? = nil) {
        answer(
            where: {
                if case .format = $0 { return true }
                if case .blobRead = $0 { return true }
                return false
            }, with: .page(Data(vt.utf8), next: next))
    }

    mutating func answerTitle(_ title: String = "shell") {
        answer(where: { $0 == .title }, with: .title(title))
    }

    /// Passes the pending wait, which must be `duration` long.
    mutating func pass(_ duration: Duration, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let wait else {
            Issue.record("No wait pending", sourceLocation: sourceLocation)
            return
        }
        #expect(wait.duration == duration, sourceLocation: sourceLocation)
        self.wait = nil
        take(engine.waited(id: wait.id))
    }

    /// One attempt read with nothing in the way: modes, the redraw, the
    /// title, and the settle.
    mutating func readQuietly(_ vt: String, title: String = "shell") {
        answerModes()
        answerRedraw(vt)
        answerTitle(title)
        pass(engine.parameters.settle)
    }

    /// One attempt that output disturbs: some before the redraw's answer,
    /// some after it, which is kept.
    mutating func readBusily(_ vt: String, before: String = "a", after: String = "b", title: String = "shell") {
        answerModes()
        output(before)
        answerRedraw(vt)
        output(after)
        answerTitle(title)
        pass(engine.parameters.settle)
    }

    static func painted(_ vt: String, exact: Bool) -> RexTerminalInstruction {
        .paint(RexTerminalPaint.reset + Data(vt.utf8), exact: exact)
    }

    static func feed(_ text: String) -> RexTerminalInstruction {
        .feed(Data(text.utf8))
    }
}

/// The first paint of a Rex terminal and its repaints, as the pure engine
/// decides them: what is read, when it is exact, what is fed after it, and
/// the instructions in order. Time is only the waits each test passes.
@Suite("Rex terminal paint")
struct RexTerminalPaintTests {
    typealias Harness = PaintHarness

    // MARK: The first paint

    @Test func anIdleTerminalPaintsOnceAndExactly() {
        var harness = Harness()
        harness.resize()
        #expect(harness.drain() == [.grid(Harness.grid)])
        #expect(harness.pendingReads == [.modes])

        harness.answerModes()
        #expect(harness.pendingReads == [.format(unwrap: true), .title])
        harness.answerRedraw("SCREEN")
        #expect(harness.wait == nil, "the settle waits for the title too")
        harness.answerTitle("vim")
        #expect(harness.wait?.duration == .milliseconds(60))
        #expect(harness.drain().isEmpty)

        harness.pass(.milliseconds(60))
        #expect(harness.drain() == [Harness.painted("SCREEN", exact: true), .title("vim")])
        #expect(harness.engine.isPainted)
        #expect(!harness.engine.isDirty)
        #expect(harness.engine.paintCount == 1)
        #expect(harness.engine.exactPaintCount == 1)
        #expect(harness.wait == nil)
        #expect(harness.reads.isEmpty)
        #expect(!harness.engine.isReading)

        harness.output("live")
        #expect(harness.drain() == [Harness.feed("live")])
        #expect(harness.reads.isEmpty)
    }

    /// Output before the redraw was asked for is in the redraw, so it is not
    /// shown on its own and does not spoil the paint.
    @Test func outputBeforeTheRequestIsInThePaint() {
        var harness = Harness()
        harness.resize()
        harness.output("early")
        harness.readQuietly("SCREEN")
        #expect(harness.drain() == [.grid(Harness.grid), Harness.painted("SCREEN", exact: true), .title("shell")])
    }

    @Test func outputDuringTheSettleSpoilsThePaint() {
        var harness = Harness()
        harness.resize()
        harness.answerModes()
        harness.answerRedraw("SCREEN")
        harness.answerTitle()
        harness.output("late")
        harness.pass(.milliseconds(60))
        #expect(!harness.engine.isPainted)
        #expect(harness.wait?.duration == .milliseconds(50), "a pause before the next attempt")
    }

    @Test func aGridChangeDuringTheReadSpoilsThePaint() {
        var harness = Harness()
        harness.resize()
        harness.answerModes()
        var wider = Harness.grid
        wider.columns = 100
        harness.resize(wider)
        harness.answerRedraw("SCREEN")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(!harness.engine.isPainted)
        #expect(harness.drain() == [.grid(Harness.grid), .grid(wider)])
    }

    /// A busy terminal is tried `attempts` times, each after the stream
    /// pauses or the wait runs out; the last attempt is painted best effort
    /// with what came after its redraw, and once the stream goes quiet one
    /// exact paint replaces it.
    @Test func aBusyTerminalRetriesThenPaintsBestEffortThenRepaintsWhenQuiet() {
        var harness = Harness()
        harness.resize()
        _ = harness.drain()

        harness.readBusily("ONE")
        harness.pass(.milliseconds(50))
        #expect(harness.pendingReads == [.modes], "a quiet pause starts the second attempt")

        harness.readBusily("TWO")
        // Output during the pause: the wait goes on, up to its limit.
        harness.output("c")
        harness.pass(.milliseconds(50))
        #expect(harness.reads.isEmpty)
        harness.output("d")
        harness.pass(.milliseconds(50))
        harness.output("e")
        harness.pass(.milliseconds(50))
        harness.output("f")
        harness.pass(.milliseconds(50))
        #expect(harness.pendingReads == [.modes], "the wait's limit starts the third attempt")

        harness.readBusily("THREE", before: "g", after: "h")
        #expect(
            harness.drain() == [Harness.painted("THREE", exact: false), .title("shell"), Harness.feed("h")])
        #expect(harness.engine.isPainted)
        #expect(harness.engine.isDirty)
        #expect(harness.engine.exactPaintCount == 0)

        // Live output is shown, and keeps the repaint waiting.
        harness.output("i")
        #expect(harness.drain() == [Harness.feed("i")])
        harness.pass(.milliseconds(250))
        #expect(harness.reads.isEmpty)
        #expect(harness.wait?.duration == .milliseconds(250))

        harness.pass(.milliseconds(250))
        #expect(harness.pendingReads == [.modes])
        harness.readQuietly("FOUR")
        #expect(harness.drain() == [Harness.painted("FOUR", exact: true), .title("shell")])
        #expect(!harness.engine.isDirty)
        #expect(harness.engine.paintCount == 2)
        #expect(harness.wait == nil)
    }

    /// A quiet repaint that output disturbs paints nothing and waits for a
    /// quiet spell twice as long.
    @Test func aDisturbedQuietRepaintWaitsAgain() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.readBusily("ONE")
        #expect(harness.engine.isDirty)
        _ = harness.drain()

        harness.pass(.milliseconds(250))
        harness.readBusily("TWO", before: "x", after: "y")
        #expect(harness.drain() == [Harness.feed("x"), Harness.feed("y")])
        #expect(harness.engine.paintCount == 1)
        #expect(harness.wait?.duration == .milliseconds(500))
    }

    /// Each quiet repaint reads the whole redraw, so one that output keeps
    /// disturbing backs off up to the limit; an exact paint starts it over.
    @Test func disturbedQuietRepaintsBackOffUntilOneIsExact() {
        var harness = Harness {
            $0.attempts = 1
            $0.quietRepaintLimit = .seconds(1)
        }
        harness.resize()
        harness.readBusily("ONE")
        for (window, next) in [(250, 500), (500, 1000), (1000, 1000)] {
            harness.pass(.milliseconds(window))
            harness.readBusily("AGAIN")
            #expect(harness.wait?.duration == .milliseconds(next))
        }
        harness.pass(.seconds(1))
        harness.readQuietly("QUIET")
        #expect(!harness.engine.isDirty)
        #expect(harness.wait == nil)

        harness.resize(RexTerminalGrid(columns: 100, rows: 30, cellWidth: 9, cellHeight: 18, owner: "client:a"))
        harness.readBusily("WIDER")
        #expect(harness.engine.isDirty)
        #expect(harness.wait?.duration == .milliseconds(250))
    }

    @Test func autowrapDecidesUnwrap() {
        for (wraparound, unwrap) in [(true, true), (false, false), (nil, true)] as [(Bool?, Bool)] {
            var harness = Harness()
            harness.resize()
            harness.answerModes(wraparound: wraparound)
            #expect(harness.pendingReads.first == .format(unwrap: unwrap))
        }
    }

    /// A long redraw is read in pages, each from the UTF-8 bytes read so far.
    @Test func aLongRedrawIsPaged() {
        var harness = Harness()
        harness.resize()
        harness.answerModes()
        let first = String(repeating: "é", count: 10)
        harness.answerRedraw(first, next: 7)
        #expect(harness.pendingReads == [.title, .blobRead(id: 7, offset: 20)])
        harness.answerTitle()
        harness.answerRedraw("漢字", next: 7)
        #expect(harness.pendingReads == [.blobRead(id: 7, offset: 26)])
        #expect(harness.wait == nil)
        harness.answerRedraw("end")
        harness.pass(.milliseconds(60))
        #expect(harness.drain().dropFirst().first == Harness.painted(first + "漢字end", exact: true))
    }

    /// A redraw up to `redrawByteLimit` paints; the page that takes it past
    /// ends the stream, and no further page is asked for.
    @Test func aRedrawPastItsLimitEndsTheStream() {
        var harness = Harness { $0.redrawByteLimit = 8 }
        harness.resize()
        harness.answerModes()
        harness.answerRedraw("1234", next: 7)
        harness.answerRedraw("5678", next: 7)
        #expect(harness.pendingReads == [.title, .blobRead(id: 7, offset: 8)])
        harness.answerRedraw("9")
        #expect(harness.drain().dropFirst() == [.ended(.redrawTooLarge)])
        #expect(harness.engine.hasEnded)
        #expect(harness.engine.paintCount == 0)
        harness.answerTitle()
        harness.output("ignored")
        #expect(harness.drain().isEmpty)
        #expect(harness.wait == nil)

        var fits = Harness { $0.redrawByteLimit = 8 }
        fits.resize()
        fits.answerModes()
        fits.answerRedraw("1234", next: 7)
        fits.answerRedraw("5678")
        fits.answerTitle()
        fits.pass(.milliseconds(60))
        #expect(fits.drain().dropFirst().first == Harness.painted("12345678", exact: true))
    }

    /// A repaint meets the same limit: the view stops there rather than read
    /// the whole history again at every quiet spell.
    @Test func aRepaintPastTheLimitEndsTheStream() {
        var harness = Harness { $0.redrawByteLimit = 8 }
        harness.resize()
        harness.readQuietly("SCREEN")
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        _ = harness.drain()
        harness.answerModes()
        harness.answerRedraw("TALLER", next: 3)
        harness.answerRedraw("ROWS")
        #expect(harness.drain() == [.ended(.redrawTooLarge)])
        #expect(harness.engine.paintCount == 1)
        #expect(harness.wait == nil)
    }

    /// Output after the redraw's first page is kept, so a paint whose state
    /// came before it is fed what followed.
    @Test func outputBetweenPagesIsKept() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.answerModes()
        harness.answerRedraw("A", next: 1)
        harness.output("x")
        harness.answerRedraw("B")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(harness.drain().dropFirst() == [Harness.painted("AB", exact: false), .title("shell"), Harness.feed("x")])
    }

    /// A theme before the first paint goes into it, right after the reset,
    /// and an exit waits for it.
    @Test func themeAndExitWaitForTheFirstPaint() {
        var harness = Harness()
        harness.resize()
        let theme = RexTerminalTheme(foreground: "#ffffff", background: nil, cursor: nil, palette: [], scheme: "dark")
        harness.message(.theme(theme))
        harness.message(.childExited(exitCode: 0))
        #expect(harness.drain() == [.grid(Harness.grid)])
        harness.readQuietly("SCREEN")
        #expect(
            harness.drain() == [
                .paint(RexTerminalPaint.reset + theme.sequences + Data("SCREEN".utf8), exact: true),
                .title("shell"), .exited(code: 0),
            ])
        harness.message(.childExited(exitCode: nil))
        #expect(harness.drain() == [.exited(code: nil)])
    }

    /// A theme after the first paint reaches the view at once, and every
    /// later paint applies it after its reset.
    @Test func aThemeAfterThePaintIsAppliedAndRepainted() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("SCREEN")
        #expect(harness.drain().dropFirst() == [Harness.painted("SCREEN", exact: true), .title("shell")])
        let theme = RexTerminalTheme(
            foreground: "#111111", background: "#fafafa", cursor: nil, palette: ["1=#ef5350"], scheme: nil)
        harness.message(.theme(theme))
        #expect(harness.drain() == [.theme(theme)])
        #expect(harness.pendingReads.isEmpty)
        harness.resize(RexTerminalGrid(columns: 100, rows: 30, cellWidth: 9, cellHeight: 18, owner: nil))
        harness.readQuietly("WIDER")
        #expect(
            harness.drain().dropFirst() == [
                .paint(RexTerminalPaint.reset + theme.sequences + Data("WIDER".utf8), exact: true), .title("shell"),
            ])
    }

    /// A palette entry the server stops listing has gone back to Rex's
    /// built-in color, which only a redraw carries.
    @Test func aPaletteEntryDroppedRepaints() {
        var harness = Harness()
        harness.resize()
        harness.message(
            .theme(RexTerminalTheme(foreground: nil, background: nil, cursor: nil, palette: ["1=ef5350"], scheme: nil)))
        harness.readQuietly("SCREEN")
        _ = harness.drain()
        harness.message(.theme(.builtIn))
        #expect(harness.drain() == [.theme(.builtIn)])
        #expect(harness.pendingReads == [.modes])
    }

    /// A new stream sends a theme only for colors that are not built in, so
    /// colors the last one gave are set back unless it gives them again.
    @Test func aNewStreamSetsTheLastStreamsColorsBack() {
        var harness = Harness()
        harness.resize()
        harness.message(
            .theme(RexTerminalTheme(foreground: "#111111", background: nil, cursor: nil, palette: [], scheme: nil)))
        harness.readQuietly("SCREEN")
        _ = harness.drain()
        harness.take(harness.engine.beginStream())
        harness.resize()
        harness.readQuietly("AGAIN")
        #expect(
            harness.drain().dropFirst() == [
                .paint(RexTerminalPaint.reset + RexTerminalTheme.builtIn.sequences + Data("AGAIN".utf8), exact: true),
                .title("shell"),
            ])
    }

    /// The sequences carry only colors read as six hex digits, so nothing
    /// else the server sent reaches the terminal.
    @Test func themeSequencesCarryOnlyColors() {
        let theme = RexTerminalTheme(
            foreground: "#D6DEEB", background: "011627", cursor: "red\u{1B}]52;c;x",
            palette: ["1=#ef5350", "300=#000000", "2=#12345", "x=#ffffff", "4=82aaff"], scheme: "dark")
        let text = String(decoding: theme.sequences, as: UTF8.self)
        #expect(
            text == "\u{1B}]10;rgb:d6/de/eb\u{1B}\\" + "\u{1B}]11;rgb:01/16/27\u{1B}\\" + "\u{1B}]112\u{1B}\\"
                + "\u{1B}]4;1;rgb:ef/53/50\u{1B}\\" + "\u{1B}]4;4;rgb:82/aa/ff\u{1B}\\")
        #expect(
            String(decoding: RexTerminalTheme.builtIn.sequences, as: UTF8.self)
                == "\u{1B}]110\u{1B}\\\u{1B}]111\u{1B}\\\u{1B}]112\u{1B}\\")
    }

    // MARK: Repaints

    /// The redraw carries no primary screen behind the alternate one, so a
    /// paint taken on it is redone once the program leaves it.
    @Test func leavingTheAlternateScreenRepaints() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("\u{1B}[?1049hFULLSCREEN")
        _ = harness.drain()
        harness.output("more")
        #expect(harness.reads.isEmpty)
        harness.output("\u{1B}[?1049l")
        #expect(harness.drain() == [Harness.feed("more"), Harness.feed("\u{1B}[?1049l")])
        #expect(harness.pendingReads == [.modes])
        harness.readQuietly("PRIMARY")
        #expect(harness.drain() == [Harness.painted("PRIMARY", exact: true), .title("shell")])
        harness.output("\u{1B}[?1049l")
        #expect(harness.reads.isEmpty, "a paint on the primary screen is not redone")
    }

    /// Output that stopped partway into a sequence leaves nothing behind once
    /// a repaint comes: the paint's reset starts the modes afresh.
    @Test func aRepaintAfterACutSequenceStartsClean() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("\u{1B}[?1049hFULLSCREEN")
        harness.output("\u{1B}[?104")
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        _ = harness.drain()
        harness.readQuietly("\u{1B}[?1049hTALLER")
        #expect(harness.drain() == [Harness.painted("\u{1B}[?1049hTALLER", exact: true), .title("shell")])
        // Had the cut sequence outlived the paint, this would end it as a
        // leave of the alternate screen.
        harness.output("9l")
        #expect(harness.reads.isEmpty)
        harness.output("\u{1B}[?1049l")
        #expect(harness.pendingReads == [.modes])
    }

    @Test func leavingTheAlternateScreenInTheKeptOutputRepaintsAtOnce() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.readBusily("\u{1B}[?1049hFULLSCREEN", before: "x", after: "\u{1B}[?1049l")
        #expect(harness.engine.paintCount == 1)
        #expect(harness.pendingReads == [.modes])
    }

    @Test func aGridChangeRepaints() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("SCREEN")
        _ = harness.drain()

        var owned = Harness.grid
        owned.owner = "client:b"
        harness.resize(owned)
        #expect(harness.drain() == [.grid(owned)])
        #expect(harness.reads.isEmpty, "the same size with another owner is no change")

        var taller = owned
        taller.rows = 40
        harness.resize(taller)
        #expect(harness.drain() == [.grid(taller)])
        #expect(harness.pendingReads == [.modes])
        harness.output("during")
        #expect(harness.drain() == [Harness.feed("during")], "output still reaches the view")
        harness.answerModes()
        harness.answerRedraw("TALLER")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(harness.drain() == [Harness.painted("TALLER", exact: true), .title("shell")])
    }

    /// A repaint keeps the output after its redraw, which the view already
    /// showed once, and feeds it again on top of the paint.
    @Test func aBestEffortRepaintFeedsWhatFollowedItsRedraw() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.readQuietly("SCREEN")
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        _ = harness.drain()
        harness.readBusily("TALLER", before: "x", after: "y")
        #expect(
            harness.drain() == [
                Harness.feed("x"), Harness.feed("y"), Harness.painted("TALLER", exact: false), .title("shell"),
                Harness.feed("y"),
            ])
        #expect(harness.engine.isDirty)
    }

    @Test func aGridChangeDuringAPaintRepaintsAfterIt() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.readQuietly("SCREEN")
        _ = harness.drain()
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        harness.answerModes()
        harness.resize(Harness.grid)
        #expect(harness.pendingReads == [.format(unwrap: true), .title])
        harness.answerRedraw("X")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(harness.pendingReads == [.modes], "the second change is read after the first paint")
    }

    // MARK: Bounds and failures

    /// Past `replayByteLimit`, what was kept is dropped and keeping starts
    /// over: a first paint shows the bytes after the gap, and stays dirty.
    @Test func keptOutputIsBounded() {
        var harness = Harness {
            $0.attempts = 1
            $0.replayByteLimit = 8
        }
        harness.resize()
        harness.answerModes()
        harness.answerRedraw("SCREEN")
        harness.output("12345")
        harness.output("6789A")
        harness.output("0123456789")
        harness.output("BC")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(harness.drain().dropFirst() == [Harness.painted("SCREEN", exact: false), .title("shell"), Harness.feed("BC")])
        #expect(harness.engine.droppedReplayBytes == 20)
        #expect(harness.engine.isDirty)
    }

    /// A repaint whose kept output overflowed would show a gap, so it paints
    /// nothing: the live output stays, and the next quiet spell repaints.
    @Test func anOverflowingRepaintKeepsTheLiveView() {
        var harness = Harness {
            $0.attempts = 1
            $0.replayByteLimit = 4
        }
        harness.resize()
        harness.readQuietly("SCREEN")
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        _ = harness.drain()
        harness.readBusily("TALLER", before: "x", after: "too long")
        #expect(harness.drain() == [Harness.feed("x"), Harness.feed("too long")])
        #expect(harness.engine.paintCount == 1)
        #expect(harness.engine.isDirty)
        #expect(harness.wait?.duration == .milliseconds(250))
    }

    @Test func aFirstPaintWhoseReadsKeepFailingEnds() {
        var harness = Harness { $0.failedReadLimit = 2 }
        harness.resize()
        harness.answer(where: { $0 == .modes }, with: .failed)
        #expect(harness.wait?.duration == .seconds(2))
        harness.pass(.seconds(2))
        harness.answerModes()
        harness.answer(where: { if case .format = $0 { true } else { false } }, with: .failed)
        #expect(harness.drain().last == .ended(.paintFailed))
        #expect(harness.engine.hasEnded)
        harness.output("ignored")
        harness.answerTitle()
        #expect(harness.drain().isEmpty)
    }

    @Test func aFailedTitleDoesNotSpoilThePaint() {
        var harness = Harness()
        harness.resize()
        harness.answerModes()
        harness.answerRedraw("SCREEN")
        harness.answer(where: { $0 == .title }, with: .failed)
        harness.pass(.milliseconds(60))
        #expect(harness.drain().dropFirst() == [Harness.painted("SCREEN", exact: true)])
    }

    @Test func aFailedRepaintLeavesTheViewDirty() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("SCREEN")
        var taller = Harness.grid
        taller.rows = 40
        harness.resize(taller)
        harness.answer(where: { $0 == .modes }, with: .failed)
        #expect(harness.engine.isDirty)
        #expect(!harness.engine.hasEnded)
        harness.pass(.seconds(2))
        harness.readQuietly("TALLER")
        #expect(!harness.engine.isDirty)
    }

    /// While the connection is being resumed, output may be on its way: no
    /// paint read meanwhile is exact, and the quiet repaint waits.
    @Test func aPausedStreamIsNeitherExactNorQuiet() {
        var harness = Harness { $0.attempts = 1 }
        harness.resize()
        harness.answerModes()
        harness.take(harness.engine.streamPaused())
        harness.answerRedraw("SCREEN")
        harness.answerTitle()
        harness.pass(.milliseconds(60))
        #expect(harness.engine.isDirty)
        harness.pass(.milliseconds(250))
        #expect(harness.reads.isEmpty)
        harness.take(harness.engine.streamResumed())
        harness.pass(.milliseconds(250))
        harness.pass(.milliseconds(250))
        #expect(harness.pendingReads == [.modes])
    }

    /// A new stream starts from nothing: its first message starts its first paint.
    @Test func aNewStreamPaintsAfresh() {
        var harness = Harness()
        harness.resize()
        harness.readQuietly("ONE")
        harness.take(harness.engine.beginStream())
        _ = harness.drain()
        harness.output("stale")
        harness.resize()
        #expect(harness.drain() == [.grid(Harness.grid)])
        harness.readQuietly("TWO")
        #expect(harness.drain() == [Harness.painted("TWO", exact: true), .title("shell")])
    }

    // MARK: Reads

    @Test func theRedrawAsksForEveryExtra() {
        let call = RexTerminalReads.call(.format(unwrap: false), session: "session:a", block: "block:b", pageBytes: 4096)
        #expect(call.method == "com.superlogical.terminal.format")
        #expect(call.payload["session_id"] == "session:a")
        #expect(call.payload["block_id"] == "block:b")
        let args = call.payload["args"]
        #expect(args?["format"] == "vt")
        #expect(args?["unwrap"] == false)
        #expect(args?["max_bytes"] == 4096)
        for extra in [
            "extra_charsets", "extra_cursor", "extra_hyperlink", "extra_keyboard", "extra_kitty_keyboard",
            "extra_modes", "extra_palette", "extra_protection", "extra_pwd", "extra_scrolling_region", "extra_style",
            "extra_tabstops",
        ] {
            #expect(args?[extra] == true, "\(extra)")
        }

        let page = RexTerminalReads.call(.blobRead(id: 3, offset: 900), session: "session:a", block: "block:b", pageBytes: 512)
        #expect(page.method == "com.superlogical.terminal.blob_read")
        #expect(page.payload["args"] == ["id": 3, "offset": 900, "max_bytes": 512])
        let modes = RexTerminalReads.call(.modes, session: "session:a", block: "block:b", pageBytes: 512)
        #expect(modes.method == "com.superlogical.terminal.modes")
        #expect(modes.payload == ["session_id": "session:a", "block_id": "block:b"])
    }

    /// A page stays under the control link's message limit.
    @Test func pagesFitTheMessageLimit() {
        #expect(RexTerminalPaint.pageBytes(asked: 983_040, messageLimit: 1_048_576) == 983_040)
        #expect(RexTerminalPaint.pageBytes(asked: 983_040, messageLimit: 65_536) == 61_440)
    }

    @Test func answersRead() {
        #expect(
            RexTerminalReads.answer(to: .format(unwrap: true), ["content": "abc", "total": 3, "eof": true])
                == .page(Data("abc".utf8), next: nil))
        #expect(
            RexTerminalReads.answer(to: .format(unwrap: true), ["content": "ab", "total": 9, "id": 4])
                == .page(Data("ab".utf8), next: 4))
        #expect(
            RexTerminalReads.answer(to: .blobRead(id: 4, offset: 2), ["id": 4, "data": "cd", "total": 9, "eof": false])
                == .page(Data("cd".utf8), next: 4))
        #expect(
            RexTerminalReads.answer(to: .blobRead(id: 4, offset: 4), ["id": 4, "data": "e", "total": 9, "eof": true])
                == .page(Data("e".utf8), next: nil))
        #expect(
            RexTerminalReads.answer(to: .blobRead(id: 4, offset: 4), ["id": 4, "data": "", "eof": false]) == .failed)
        #expect(RexTerminalReads.answer(to: .format(unwrap: true), ["total": 3]) == .failed)

        let modes: JSONValue = [
            "screen": "primary",
            "modes": [
                ["name": "insert", "number": 7, "ansi": true, "set": true],
                ["name": "wraparound", "number": 7, "ansi": false, "set": false],
            ],
        ]
        #expect(RexTerminalReads.answer(to: .modes, modes) == .modes(wraparound: false))
        #expect(RexTerminalReads.answer(to: .modes, ["modes": .null]) == .modes(wraparound: nil))
        #expect(RexTerminalReads.answer(to: .title, ["title": "a\u{1B}]b\u{07}c\nd"]) == .title("a]bcd"))
        #expect(RexTerminalReads.answer(to: .title, ["title": .null]) == .failed)
    }

    @Test func aLongTitleIsCut() {
        let title = RexTerminalReads.displayTitle(String(repeating: "é", count: 1000))
        #expect(title.count == RexTerminalReads.titleCharacterLimit)
    }
}
