import Foundation
import Synchronization
import Testing

@testable import Heeler

/// A program's reprint of its history in an attach's output, in the bytes
/// Antigravity CLI 1.5.13 sends through herdr-core 0.1.21
/// (`docs/agents/herdr-compatibility.md`).
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreReprintTests {
    private typealias Step = HerdrCoreReprint.Step

    private static let open = Data("\u{1B}[?2026h".utf8)
    private static let close = Data("\u{1B}[?2026l".utf8)
    /// What Antigravity CLI sends ahead of its reprint.
    private static let erase = Data("\u{1B}[2J\u{1B}[3J\u{1B}[H".utf8)
    /// Its first answer to a resize: a block that erases the screen down to its
    /// status line.
    private static let cleared = block("\r\u{1B}[20A\u{1B}[Jstatus")

    /// Its status line, which it at times repaints between the erase and the
    /// reprint: a block with no line feed in it.
    private static let statusLine = block("\u{1B}[J? for shortcuts\r")

    private static func bytes(_ text: String) -> Data { Data(text.utf8) }
    private static func block(_ body: String) -> Data { open + bytes(body) + close }
    /// A reprint: a block of lines.
    private static func history(_ name: String) -> Data { block("\(name)\r\n") }

    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start + .milliseconds(Int((seconds * 1000).rounded()))
    }

    private static func reprint(
        limit: Int = HerdrCoreFrame.maximumPayload, expecting reprint: TerminalReprint = .unknown
    ) -> HerdrCoreReprint {
        HerdrCoreReprint(limit: limit, quiet: .seconds(2), resizeWait: .seconds(1), expecting: reprint)
    }

    /// A machine whose attach has shown a reprint.
    private func reprinted() -> HerdrCoreReprint {
        var reprint = Self.reprint()
        _ = reprint.receive(Self.erase + Self.history("all"), at: at(0))
        return reprint
    }

    // MARK: A reprint, whole

    @Test(arguments: [1, 2, 3, 5, 7, 11, 13, 64, 1000, 4096])
    func aReprintGoesOutInOnePieceHoweverItsReadsAreCut(size: Int) {
        let history = Self.block(String(repeating: "line\r\n", count: 1500))
        // The erase with its cursor move, as Antigravity CLI sends it, then bare.
        let again = Self.block("again\r\n")
        let before = Self.bytes("before") + Self.erase
        let between = Self.bytes("after\u{1B}[3J")
        let stream = before + history + between + again + Self.bytes("end")
        var reprint = Self.reprint()
        var passed = Data()
        /// Where each output ends, to where it starts.
        var outputs: [Int: Int] = [:]

        for offset in stride(from: 0, to: stream.count, by: size) {
            let read = Data(stream[offset..<min(offset + size, stream.count)])
            let step = reprint.receive(read, at: at(0))
            for output in step.passed {
                outputs[passed.count + output.count] = passed.count
                passed.append(output)
            }
            // A read's held bytes are what the core is owed credit for now.
            #expect(step.held == min(read.count, offset + read.count - passed.count))
        }

        #expect(!reprint.isHolding)
        #expect(passed == stream)
        // An opening cut across reads has passed its first bytes by the time it
        // is known, so a block is held from somewhere inside its opening.
        for (opens, block) in [(before.count, history), (before.count + history.count + between.count, again)] {
            let from = outputs[opens + block.count] ?? -1
            #expect((opens..<(opens + Self.open.count)).contains(from))
        }
    }

    @Test func onlyABlockRightAfterAnEraseIsHeld() {
        var reprint = Self.reprint()
        let frame = Self.block("frame")

        #expect(reprint.receive(frame, at: at(0)) == Step(passed: [frame]))
        #expect(reprint.receive(Self.erase, at: at(0)) == Step(passed: [Self.erase]))
        #expect(
            reprint.receive(Self.bytes("$ ") + Self.open, at: at(0))
                == Step(passed: [Self.bytes("$ ") + Self.open]))
        #expect(!reprint.isHolding)
    }

    /// On the resize that follows an attach, Antigravity CLI at times repaints
    /// its status line in a block of its own between the erase and the reprint.
    @Test func aBlockRightBehindAHeldOneIsHeldAsWell() {
        let status = Self.statusLine
        let history = Self.block(String(repeating: "line\r\n", count: 1500))
        var reprint = Self.reprint()

        #expect(reprint.receive(Self.erase + status, at: at(0)) == Step(passed: [Self.erase, status]))
        #expect(reprint.receive(Data(history.prefix(5000)), at: at(0.1)) == Step(passed: [], held: 5000))
        #expect(reprint.receive(Data(history.dropFirst(5000)), at: at(1)) == Step(passed: [history]))
        // Anything in between ends that.
        let later = Self.bytes("$ ") + Self.open + Self.bytes("more")
        #expect(reprint.receive(later, at: at(2)) == Step(passed: [later]))
    }

    @Test func whatOutgrowsTheLimitGoesOutAsItStandsAndTheRestPasses() {
        let big = Data(repeating: 0x41, count: 5000)
        var reprint = Self.reprint(limit: 4096)

        #expect(reprint.receive(Self.erase + Self.open + big, at: at(0)) == Step(passed: [Self.erase, Self.open + big]))
        #expect(reprint.receive(big, at: at(0)) == Step(passed: [big]))
        _ = reprint.receive(Self.erase + Self.history("all"), at: at(1))
        reprint.resized(at: at(2))
        #expect(reprint.receive(big, at: at(2.1)) == Step(passed: [big]))
    }

    // MARK: Keeping the screen after a resize

    @Test func aResizeHoldsNothingBeforeTheAttachHasShownAReprint() {
        var reprint = Self.reprint()

        reprint.resized(at: at(1))

        #expect(reprint.receive(Self.cleared, at: at(1.01)) == Step(passed: [Self.cleared]))
    }

    @Test func afterAReprintAResizeHoldsAllItBringsUntilItsReprintCloses() {
        var reprint = reprinted()

        reprint.resized(at: at(10))

        #expect(reprint.receive(Self.cleared, at: at(10.02)) == Step(passed: [], held: Self.cleared.count))
        #expect(reprint.receive(Self.erase, at: at(10.2)) == Step(passed: [], held: Self.erase.count))
        #expect(reprint.receive(Self.open + Self.bytes("two"), at: at(10.3)) == Step(passed: [], held: 11))
        #expect(
            reprint.receive(Self.bytes("\r\n") + Self.close + Self.bytes("tail"), at: at(10.4))
                == Step(passed: [Self.cleared + Self.erase + Self.history("two"), Self.bytes("tail")]))
    }

    /// The link sets how long a reprint takes, so each step is waited for on
    /// its own: the first output, the erase, the block's first frame, each frame.
    @Test func eachStepOfAResizeHasAWaitOfItsOwn() {
        var reprint = reprinted()

        reprint.resized(at: at(10))
        #expect(reprint.patience(at: at(10)) == nil)
        _ = reprint.receive(Self.cleared, at: at(11.5))
        #expect(reprint.patience(at: at(11.5)) == .seconds(1))
        _ = reprint.receive(Self.erase, at: at(12.4))
        #expect(reprint.patience(at: at(12.4)) == .seconds(2))
        // The erase's wait running out lets nothing go.
        #expect(reprint.release(at: at(12.6)) == nil)
        _ = reprint.receive(Self.open + Self.bytes("two\r\n"), at: at(14))
        #expect(reprint.patience(at: at(14)) == .seconds(2))
        #expect(
            reprint.receive(Self.close, at: at(15.9))
                == Step(passed: [Self.cleared + Self.erase + Self.history("two")]))
    }

    @Test func anotherResizeGivesWhatIsHeldMoreTime() {
        var reprint = reprinted()
        reprint.resized(at: at(20))
        _ = reprint.receive(Self.cleared, at: at(20.1))

        reprint.resized(at: at(20.8))

        #expect(reprint.release(at: at(21.5)) == nil)
        let rest = Self.erase + Self.history("three")
        #expect(reprint.receive(rest, at: at(21.6)) == Step(passed: [Self.cleared + rest]))
    }

    @Test func aResizeSentWhileAReprintIsHeldHoldsFromThatReprintsClose() {
        var reprint = reprinted()
        reprint.resized(at: at(30))
        _ = reprint.receive(Self.cleared + Self.erase + Self.open + Self.bytes("four\r\n"), at: at(30.2))

        reprint.resized(at: at(31))

        #expect(
            reprint.receive(Self.close + Self.cleared, at: at(33))
                == Step(passed: [Self.cleared + Self.erase + Self.history("four")], held: Self.cleared.count))
        let rest = Self.erase + Self.history("five")
        #expect(reprint.receive(rest, at: at(33.3)) == Step(passed: [Self.cleared + rest]))
    }

    @Test func aResizeAnsweredWithNoReprintLetsGoAndTheNextOneHoldsNothing() {
        let prompt = Self.bytes("$ ")
        var reprint = reprinted()
        reprint.resized(at: at(40))
        #expect(reprint.receive(prompt, at: at(40.1)) == Step(passed: [], held: 2))

        // A second from its first output, not from the resize.
        #expect(reprint.release(at: at(41)) == nil)
        #expect(reprint.release(at: at(41.1)) == prompt)

        reprint.resized(at: at(42))
        #expect(reprint.receive(prompt, at: at(42.1)) == Step(passed: [prompt]))
    }

    /// A resize that brought nothing says nothing about the program.
    @Test func aResizeNothingAnswersLeavesTheNextOneHeld() {
        var reprint = reprinted()
        reprint.resized(at: at(60))
        let later = Self.bytes("much later")
        #expect(reprint.receive(later, at: at(63)) == Step(passed: [later]))

        reprint.resized(at: at(64))

        #expect(reprint.receive(Self.cleared, at: at(65.5)) == Step(passed: [], held: Self.cleared.count))
    }

    @Test func theEndOfOutputHandsOverWhatAResizeHolds() {
        var reprint = reprinted()
        reprint.resized(at: at(80))
        _ = reprint.receive(Self.cleared, at: at(80.1))

        #expect(reprint.release(at: at(80.2), ended: true) == Self.cleared)
        #expect(!reprint.isHolding)
    }

    /// Behind a resize the status line would otherwise end the hold with the
    /// screen erased and the reprint still to come.
    @Test func behindAResizeABlockWithNoLineInItWaitsForTheReprintRightBehindIt() {
        let history = Self.history("six")
        var reprint = reprinted()
        reprint.resized(at: at(10))
        _ = reprint.receive(Self.cleared, at: at(10.02))

        #expect(
            reprint.receive(Self.erase + Self.statusLine, at: at(10.2))
                == Step(passed: [], held: Self.erase.count + Self.statusLine.count))
        // The block's first frame has a frame's wait.
        #expect(reprint.patience(at: at(10.2)) == .seconds(2))
        #expect(reprint.receive(Data(history.prefix(3)), at: at(11.5)) == Step(passed: [], held: 3))
        #expect(
            reprint.receive(Data(history.dropFirst(3)), at: at(11.6))
                == Step(passed: [Self.cleared + Self.erase + Self.statusLine + history]))
    }

    @Test func aBlockWithNoLineInItThatNoBlockFollowsIsLetGoWithTheRest() {
        var reprint = reprinted()
        reprint.resized(at: at(10))
        _ = reprint.receive(Self.cleared + Self.erase + Self.statusLine, at: at(10.2))

        #expect(reprint.receive(Self.bytes("$ "), at: at(10.3)) == Step(passed: [], held: 2))
        #expect(
            reprint.release(at: at(12.2)) == Self.cleared + Self.erase + Self.statusLine + Self.bytes("$ "))
    }

    // MARK: A program known to reprint

    private static let paint = Data("\u{1B}[!p\u{1B}[H\u{1B}[2Jscreen\u{1B}[?9001l".utf8)
    /// The status report a core sends behind every first paint.
    private static let report = Data("\u{1B}]7501;state=idle:app=antigravity\u{1B}\\".utf8)

    /// The attach resizes the Terminal, so the program erases the screen the
    /// first paint drew before its reprint is here.
    @Test func anAttachThatResizesAReprintingProgramHoldsAllThatFollowsItsFirstPaint() {
        var reprint = Self.reprint(expecting: .afterAttach)

        #expect(reprint.receive(Self.paint, at: at(0)) == Step(passed: [Self.paint]))
        #expect(reprint.receive(Self.report, at: at(0)) == Step(passed: [], held: Self.report.count))
        #expect(reprint.receive(Self.cleared, at: at(0.02)) == Step(passed: [], held: Self.cleared.count))
        let rest = Self.erase + Self.history("all")
        #expect(reprint.receive(rest, at: at(0.2)) == Step(passed: [Self.report + Self.cleared + rest]))
    }

    @Test func anAttachAtTheTerminalsSizeHoldsNothingUntilAResize() {
        var reprint = Self.reprint(expecting: .afterResize)
        _ = reprint.receive(Self.paint, at: at(0))
        #expect(reprint.receive(Self.report, at: at(0)) == Step(passed: [Self.report]))

        reprint.resized(at: at(5))

        #expect(reprint.receive(Self.cleared, at: at(5.02)) == Step(passed: [], held: Self.cleared.count))
    }

    @Test func aResizeSentAheadOfTheFirstPaintLetsThePaintPassAndHoldsWhatFollows() {
        var reprint = Self.reprint(expecting: .afterResize)

        reprint.resized(at: at(0))

        #expect(reprint.receive(Self.paint, at: at(1)) == Step(passed: [Self.paint]))
        #expect(reprint.receive(Self.cleared, at: at(1.02)) == Step(passed: [], held: Self.cleared.count))
    }

    /// The Terminal already had the size, which says nothing about the
    /// program. A resize that goes out and brings no reprint does.
    @Test func anAttachThatResizedNothingLetsGoAndStillHoldsItsFirstResize() {
        var reprint = Self.reprint(expecting: .afterAttach)
        _ = reprint.receive(Self.paint, at: at(0))
        _ = reprint.receive(Self.report, at: at(0))

        #expect(reprint.release(at: at(1)) == Self.report)

        reprint.resized(at: at(5))
        #expect(reprint.receive(Self.cleared, at: at(5.02)) == Step(passed: [], held: Self.cleared.count))
        #expect(reprint.release(at: at(6.02)) == Self.cleared)
        reprint.resized(at: at(7))
        #expect(reprint.receive(Self.cleared, at: at(7.02)) == Step(passed: [Self.cleared]))
    }

    // MARK: The hold

    /// A channel's reads, answered when a test says. A channel has one reader.
    private final class Reads: Sendable {
        private typealias Answer = Result<Data?, any Error>

        private struct State {
            var answers: [Answer] = []
            var waiting: CheckedContinuation<Answer, Never>?
            var started = 0
            var cancelled = 0
        }

        private let state = Mutex(State())

        var started: Int { state.withLock { $0.started } }
        var cancelled: Int { state.withLock { $0.cancelled } }

        func answer(_ data: Data?) { answer(.success(data)) }
        func fail(_ error: any Error) { answer(.failure(error)) }

        private func answer(_ answer: Answer) {
            let waiting = state.withLock { state -> CheckedContinuation<Answer, Never>? in
                defer { state.waiting = nil }
                if state.waiting == nil { state.answers.append(answer) }
                return state.waiting
            }
            waiting?.resume(returning: answer)
        }

        func read() async throws -> Data? {
            let answer = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                    let ready = state.withLock { state -> Answer? in
                        state.started += 1
                        if state.cancelled > 0 { return .failure(CancellationError()) }
                        guard state.answers.isEmpty else { return state.answers.removeFirst() }
                        state.waiting = continuation
                        return nil
                    }
                    if let ready { continuation.resume(returning: ready) }
                }
            } onCancel: {
                let waiting = state.withLock { state -> CheckedContinuation<Answer, Never>? in
                    defer { state.waiting = nil }
                    state.cancelled += 1
                    return state.waiting
                }
                waiting?.resume(returning: .failure(CancellationError()))
            }
            return try answer.get()
        }
    }

    private final class Credits: Sendable {
        private let given = Mutex<[Int]>([])
        var all: [Int] { given.withLock { $0 } }
        func add(_ count: Int) { given.withLock { $0.append(count) } }
    }

    private struct Lost: Error {}

    private static func hold(
        reading reads: Reads, crediting credits: Credits = Credits(),
        quiet: Duration = HerdrCoreReprintHold.quiet, resizeWait: Duration = HerdrCoreReprintHold.resizeWait
    ) -> HerdrCoreReprintHold {
        HerdrCoreReprintHold(
            quiet: quiet, resizeWait: resizeWait, read: { try await reads.read() }, credit: { credits.add($0) })
    }

    @Test func whatAResizeBringsIsOneWriteWithItsReprintAndEveryByteIsCreditedOnce() async throws {
        let reads = Reads()
        let credits = Credits()
        let hold = Self.hold(reading: reads, crediting: credits)
        reads.answer(Self.erase + Self.history("all"))
        #expect(try await hold.next() == Self.erase)
        #expect(try await hold.next() == Self.history("all"))

        hold.resized()
        let frames = [Self.open + Self.bytes("a"), Self.bytes("b\r\n"), Self.bytes("c") + Self.close]
        for read in [Self.cleared, Self.erase] + frames {
            reads.answer(read)
        }
        reads.answer(nil)

        let whole = Self.cleared + Self.erase + Self.block("ab\r\nc")
        #expect(try await hold.next() == whole)
        #expect(try await hold.next() == nil)
        // Held reads return their credit on arrival, or the core would stop at
        // the end of its window; what the surface takes is not credited again.
        #expect(credits.all == [Self.cleared.count, Self.erase.count, Self.open.count + 1, 3])
        let consumed = Self.erase.count + Self.history("all").count + whole.count
        #expect(hold.consumed(consumed) + credits.all.reduce(0, +) == consumed)
    }

    /// A program that dies inside its block never closes it.
    @Test func aBlockThatGoesQuietIsHandedOverAndTheReadItWaitedOnIsTakenUpAgain() async throws {
        let reads = Reads()
        let hold = Self.hold(reading: reads, quiet: .milliseconds(50))
        reads.answer(Self.erase + Self.open + Self.bytes("half"))
        #expect(try await hold.next() == Self.erase)

        let asked = ContinuousClock.now
        let handed = try await hold.next()

        #expect(handed == Self.open + Self.bytes("half"))
        #expect(ContinuousClock.now - asked >= .milliseconds(45))
        reads.answer(Self.bytes("$ "))
        #expect(try await hold.next() == Self.bytes("$ "))
        // A cancelled read closes its channel, so the wait left its read out.
        #expect(reads.started == 2)
    }

    @Test func whatAResizeHoldsIsLetGoWhenNoReprintBeginsInTime() async throws {
        let reads = Reads()
        let hold = Self.hold(reading: reads, resizeWait: .milliseconds(50))
        reads.answer(Self.erase + Self.history("all"))
        #expect(try await hold.next() == Self.erase)
        #expect(try await hold.next() == Self.history("all"))

        hold.resized()
        reads.answer(Self.bytes("$ "))
        let asked = ContinuousClock.now
        let handed = try await hold.next()

        #expect(handed == Self.bytes("$ "))
        #expect(ContinuousClock.now - asked >= .milliseconds(45))
    }

    @Test func outputThatEndsInsideABlockHandsOverWhatCame() async throws {
        let reads = Reads()
        let hold = Self.hold(reading: reads)
        reads.answer(Self.erase + Self.open + Self.bytes("part"))
        reads.answer(nil)

        #expect(try await hold.next() == Self.erase)
        #expect(try await hold.next() == Self.open + Self.bytes("part"))
        #expect(try await hold.next() == nil)
    }

    @Test func aReadThatFailsInsideABlockThrowsItsError() async throws {
        let reads = Reads()
        let hold = Self.hold(reading: reads)
        reads.answer(Self.erase + Self.open + Self.bytes("part"))
        reads.fail(Lost())

        #expect(try await hold.next() == Self.erase)
        await #expect(throws: Lost.self) { try await hold.next() }
    }

    /// In a hold, and after a block that went quiet was handed over.
    @Test(arguments: [Duration.seconds(5), .milliseconds(20)])
    func aCancelledConsumerCancelsTheReadItWaitsOn(quiet: Duration) async throws {
        let reads = Reads()
        let hold = Self.hold(reading: reads, quiet: quiet)
        reads.answer(Self.erase + Self.open + Self.bytes("part"))
        let consumer = Task { () -> Bool in
            do {
                while try await hold.next() != nil {}
                return false
            } catch {
                return error is CancellationError
            }
        }
        var waits = 0
        while reads.started < 2, waits < 1000 {
            try await Task.sleep(for: .milliseconds(5))
            waits += 1
        }
        try await Task.sleep(for: .milliseconds(100))

        consumer.cancel()

        #expect(await consumer.value)
        #expect(reads.cancelled == 1)
    }
}
