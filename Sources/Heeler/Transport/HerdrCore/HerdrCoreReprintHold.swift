import Foundation
import Synchronization

/// A program's reprint of its whole history, found in an attach's output.
///
/// A program that keeps its conversation on the main screen, such as
/// Antigravity CLI, answers every resize by erasing the scrollback (`CSI 3 J`)
/// and printing all of it again inside one synchronized block (`CSI ? 2026 h`
/// to `CSI ? 2026 l`). An attach resizes the terminal to the view, so the
/// reprint follows the first paint, and a keyboard that comes up brings another.
///
/// The block that opens right after the erase is held until it closes, so it
/// goes out as one piece. The erase itself, and everything else, passes as it
/// comes.
///
/// The reprint is not always the first block after the erase: on the resize
/// that follows an attach, Antigravity CLI at times repaints its status line
/// in a block of its own in between. So a block that opens right behind a
/// held one is held as well.
///
/// That leaves the screen to what the program does ahead of its reprint, and
/// Antigravity CLI erases it within moments of the resize. So once an attach
/// has shown one reprint, its program is taken to answer a resize with
/// another: everything that comes after a resize is held as well, and goes out
/// with the reprint, so the screen keeps what it showed until the reprint is
/// whole. Behind a resize, that status line is told from the reprint by having
/// no line of history in it, and what is held waits for the block behind it.
///
/// An attach that is told its program reprints (`TerminalReprint`) need not
/// see a reprint first. Its first read is the first paint, which passes as it
/// came, and where the attach itself is taken to resize the Terminal, what
/// follows the paint is held as after any other resize. Running out of time
/// there says the Terminal already had the size, not that its program has
/// stopped reprinting.
///
/// The link sets how long that takes, so each step has a wait of its own. What
/// a resize brings may take `quiet` to begin, and from then the erase that
/// begins a reprint has `resizeWait` to come: Antigravity CLI sends it about
/// 150 ms after its first answer. The block's first frame then has `quiet`
/// again, as each frame after it has. A resize whose output runs out of time
/// lets go of what it held, and the program is no longer taken to reprint
/// until it does again.
struct HerdrCoreReprint {
    typealias Instant = ContinuousClock.Instant

    /// What one read came to: the bytes that go out now, in order, and how
    /// many of the read's own bytes stay held.
    struct Step: Equatable {
        var passed: [Data] = []
        var held = 0
    }

    private enum Phase {
        case passing
        /// Everything since a resize, kept until `until` for a reprint to
        /// begin. A block that opens at `behind`, where one with no history in
        /// it closed, begins it as well.
        case resized(Data, until: Instant, behind: Int?)
        /// A block so far, its close looked for from `from`. Behind what a
        /// resize held ahead of it, its own bytes start at `body`.
        case block(Data, body: Int?, from: Int)
    }

    /// The first paint of an attach that was told its program reprints.
    private enum FirstPaint {
        case passed
        /// Still to come. `resizes` says the attach itself is taken to resize
        /// the Terminal, and `resized` that a resize has gone out meanwhile.
        case awaited(resizes: Bool, resized: Bool)
    }

    private static let blockOpen = Data("\u{1B}[?2026h".utf8)
    private static let blockClose = Data("\u{1B}[?2026l".utf8)
    private static let erase = Data("\u{1B}[3J".utf8)
    private static let lineFeed = UInt8(ascii: "\n")
    /// The erase, then at most a cursor move home, then the block's opening.
    private static let openings = [erase + blockOpen, erase + Data("\u{1B}[H".utf8) + blockOpen]
    /// An opening cut across reads starts within this much of a read's end.
    private static let overlap = (openings.map(\.count).max() ?? 1) - 1

    private var phase = Phase.passing
    private var firstPaint: FirstPaint
    /// The end of what last passed, where an opening cut across reads begins.
    private var passedEnd = Data()
    /// The program is known to reprint: this attach was told so or has shown a
    /// reprint, and no resize since has gone without one.
    private var reprints: Bool
    /// A resize went out while a reprint was held, so another reprint follows.
    private var resizedInBlock = false
    /// What is held follows a resize the attach is only taken to have made.
    private var presumesResize = false
    private let limit: Int
    private let quiet: Duration
    private let resizeWait: Duration

    init(limit: Int, quiet: Duration, resizeWait: Duration, expecting reprint: TerminalReprint = .unknown) {
        self.limit = limit
        self.quiet = quiet
        self.resizeWait = resizeWait
        reprints = reprint != .unknown
        firstPaint = reprint == .unknown ? .passed : .awaited(resizes: reprint == .afterAttach, resized: false)
    }

    var isHolding: Bool { heldCount > 0 }

    /// A resize is going out, ahead of anything it brings.
    mutating func resized(at now: Instant) {
        guard reprints else { return }
        if case .awaited(let resizes, _) = firstPaint {
            // Nothing is held ahead of the first paint.
            firstPaint = .awaited(resizes: resizes, resized: true)
            return
        }
        presumesResize = false
        switch phase {
        case .passing:
            phase = .resized(Data(), until: now + quiet, behind: nil)
        case .resized(let held, let until, let behind):
            // What is held already waits for an erase, and this resize may
            // bring one of its own.
            phase = .resized(
                held, until: held.isEmpty ? now + quiet : max(until, now + resizeWait), behind: behind)
        case .block:
            resizedInBlock = true
        }
    }

    /// Takes the next read. A block that closes in it goes out whole, with what
    /// a resize held ahead of it, and what follows the close is looked at like
    /// any other output. What outgrows `limit` goes out as it stands, and the
    /// rest of it passes.
    mutating func receive(_ read: Data, at now: Instant) -> Step {
        var step = Step()
        if case .awaited(let resizes, let resized) = firstPaint {
            // The first paint goes out as it came, and what a resize ahead of
            // it brings is held from here.
            firstPaint = .passed
            hand(read, to: &step)
            if resizes || resized {
                phase = .resized(Data(), until: now + quiet, behind: nil)
                presumesResize = !resized
            }
            return step
        }
        if case .resized(_, let until, _) = phase, now >= until { giveUp(into: &step) }
        var rest = read
        while !rest.isEmpty {
            switch phase {
            case .passing:
                rest = pass(rest, into: &step)
            case .resized(var held, var until, var behind):
                phase = .passing
                let scanFrom = max(0, held.count - Self.overlap)
                // The erase is waited for from the resize's first output on.
                if held.isEmpty { until = now + resizeWait }
                held.append(rest)
                rest = Data()
                var opening = Self.opening(in: held, from: scanFrom)
                if let start = behind {
                    let next = held[start...].prefix(Self.blockOpen.count)
                    if next == Self.blockOpen {
                        opening = start..<(start + next.count)
                    } else if !Self.blockOpen.starts(with: next) {
                        behind = nil
                    }
                }
                if let opening {
                    rest = Data(held[opening.upperBound...])
                    held.removeSubrange(opening.upperBound...)
                    phase = .block(held, body: held.count, from: held.count)
                } else if held.count <= limit {
                    // The erase comes in a frame of its own, ahead of the
                    // block, whose first frame is a whole frame away.
                    if Self.endsErased(held) { until = now + quiet }
                    phase = .resized(held, until: until, behind: behind)
                } else {
                    hand(held, to: &step)
                }
            case .block(var held, let body, let from):
                phase = .passing
                held.append(rest)
                rest = Data()
                if let close = held.range(of: Self.blockClose, in: from..<held.count) {
                    rest = Data(held[close.upperBound...])
                    held.removeSubrange(close.upperBound...)
                    if let body, !held[body..<close.lowerBound].contains(Self.lineFeed) {
                        // Not a history: the status line, which the reprint
                        // follows as a frame of its own.
                        phase = .resized(held, until: now + quiet, behind: held.count)
                        continue
                    }
                    hand(held, to: &step)
                    // The erase stands for a block that opens right behind this one.
                    passedEnd = Self.erase
                    if resizedInBlock {
                        resizedInBlock = false
                        phase = .resized(Data(), until: now + quiet, behind: nil)
                    }
                } else if held.count <= limit {
                    phase = .block(held, body: body, from: max(from, held.count - Self.blockClose.count + 1))
                } else {
                    resizedInBlock = false
                    hand(held, to: &step)
                }
            }
        }
        // What is held is the end of the output so far, and this read is the
        // last of it.
        step.held = min(read.count, heldCount)
        return step
    }

    /// How long the next read may take before what is held is let go; nil
    /// while nothing is held.
    func patience(at now: Instant) -> Duration? {
        switch phase {
        case .passing: nil
        case .resized(let held, let until, _): held.isEmpty ? nil : max(.zero, now.duration(to: until))
        case .block: quiet
        }
    }

    /// Hands over what is held and lets output pass again: the wait for the
    /// next read ran out, or the output `ended`. A resize that has been given
    /// more time since the wait began keeps what it holds.
    mutating func release(at now: Instant, ended: Bool = false) -> Data? {
        var step = Step()
        switch phase {
        case .passing:
            return nil
        case .resized(_, let until, _):
            guard ended || now >= until else { return nil }
            giveUp(into: &step)
        case .block(let held, _, _):
            phase = .passing
            resizedInBlock = false
            hand(held, to: &step)
        }
        return step.passed.first
    }

    private var heldCount: Int {
        switch phase {
        case .passing: 0
        case .resized(let held, _, _): held.count
        case .block(let held, _, _): held.count
        }
    }

    /// Looks at output that nothing holds, and returns what a block that opens
    /// in it takes: the bytes from the block's opening on. An opening that
    /// began in the last read is held from where this one starts: the surface
    /// already has the opening's first bytes and takes the rest with the block.
    private mutating func pass(_ output: Data, into step: inout Step) -> Data {
        let window = passedEnd + output
        guard let opening = Self.opening(in: window, from: 0) else {
            passedEnd = Data(window.suffix(Self.overlap))
            step.passed.append(output)
            return Data()
        }
        let cut = max(0, opening.upperBound - Self.blockOpen.count - passedEnd.count)
        if cut > 0 { step.passed.append(Data(output.prefix(cut))) }
        passedEnd = Data()
        reprints = true
        phase = .block(Data(), body: nil, from: 0)
        return Data(output.dropFirst(cut))
    }

    /// A resize's time ran out: what it held goes out, and the program that
    /// reprinted is taken to be gone. A resize that brought nothing says
    /// nothing about the program, and neither does one that was only presumed.
    private mutating func giveUp(into step: inout Step) {
        guard case .resized(let held, _, _) = phase else { return }
        phase = .passing
        guard !held.isEmpty else { return }
        if !presumesResize { reprints = false }
        hand(held, to: &step)
    }

    private mutating func hand(_ held: Data, to step: inout Step) {
        presumesResize = false
        guard !held.isEmpty else { return }
        passedEnd = Data(held.suffix(Self.overlap))
        step.passed.append(held)
    }

    /// The first opening in `data`, which starts at 0, from `from` on.
    private static func opening(in data: Data, from: Int) -> Range<Int>? {
        openings.compactMap { data.range(of: $0, in: from..<data.count) }.min { $0.lowerBound < $1.lowerBound }
    }

    /// Whether `data` ends with the erase and as much of an opening as came
    /// with it.
    private static func endsErased(_ data: Data) -> Bool {
        openings.contains { opening in
            (erase.count..<opening.count).contains { $0 <= data.count && data.suffix($0) == opening.prefix($0) }
        }
    }
}

/// Holds a reprint (`HerdrCoreReprint`) until it is all here, so a surface takes
/// it in one write. The core cuts the block into 16 KiB frames; handed over
/// frame by frame, Ghostty waits about a second for the block to close and then
/// draws whatever part has arrived, so the history jumps past on screen for as
/// long as the link takes to carry it. One write is parsed under the terminal
/// lock, and the surface draws the latest screen once.
///
/// Held bytes return their credit as they arrive, or the core would stop at the
/// end of its window and the block would never close; the consumer's later
/// report of the same bytes is not credited again.
///
/// A program that dies inside its block never closes it, and what its shell
/// prints next would be held too. So a block that brings nothing for `quiet`
/// is handed over as it stands, and output passes until the next reprint.
///
/// `resized()` says a resize is going out, which is when a program that
/// reprints erases its screen: what follows is held with the reprint, and let
/// go when none begins in time (`HerdrCoreReprint`).
final class HerdrCoreReprintHold: Sendable {
    typealias Read = @Sendable () async throws -> Data?
    typealias Credit = @Sendable (Int) async -> Void

    /// Two seconds: a 16 KiB frame still arrives within it at 8 KB/s, so a slow
    /// link alone does not end a hold. A resize gets as long to be answered.
    static let quiet: Duration = .seconds(2)
    /// One second, from a resize's first output to the erase: several times
    /// what Antigravity CLI takes, for a link that stalls in between.
    static let resizeWait: Duration = .seconds(1)

    private struct State {
        var reprint: HerdrCoreReprint
        /// Output already decided, oldest first.
        var ready: [Data] = []
        /// Held bytes already credited that the consumer has not reported.
        var prepaid = 0
        /// A read a wait gave up on, still in flight.
        var pending: PendingRead?
        var ended = false
    }

    private let state: Mutex<State>
    private let read: Read
    private let credit: Credit

    /// `read` gives the attach's output, its first paint whole and first, and
    /// `credit` returns a held read's credit on arrival. `reprint` is what is
    /// known of the program beforehand.
    init(
        expecting reprint: TerminalReprint = .unknown,
        limit: Int = HerdrCoreFrame.maximumPayload, quiet: Duration = HerdrCoreReprintHold.quiet,
        resizeWait: Duration = HerdrCoreReprintHold.resizeWait,
        read: @escaping Read, credit: @escaping Credit
    ) {
        state = Mutex(
            State(
                reprint: HerdrCoreReprint(limit: limit, quiet: quiet, resizeWait: resizeWait, expecting: reprint)))
        self.read = read
        self.credit = credit
    }

    /// A resize is about to be sent. Call it before the resize leaves, so
    /// nothing the resize brings can arrive first.
    func resized() {
        state.withLock { $0.reprint.resized(at: .now) }
    }

    /// The next output: each read as it comes, and a reprint whole.
    func next() async throws -> Data? {
        while true {
            let (output, ended, pending, patience) = state.withLock { state in
                (state.ready.isEmpty ? nil : state.ready.removeFirst(), state.ended, state.pending,
                    state.reprint.patience(at: .now))
            }
            if let output { return output }
            if ended { return nil }
            let chunk: Data?
            if pending == nil, patience == nil {
                chunk = try await read()
            } else {
                // Only what is held is waited on with a limit, and a wait that
                // gives up must leave its read in flight for the next one.
                let inFlight = pending ?? PendingRead(read)
                state.withLock { $0.pending = inFlight }
                guard let outcome = await inFlight.outcome(within: patience) else {
                    release()
                    continue
                }
                state.withLock { $0.pending = nil }
                chunk = try outcome.get()
            }
            guard let chunk else {
                state.withLock { $0.ended = true }
                release(ended: true)
                continue
            }
            let held = state.withLock { state in
                let step = state.reprint.receive(chunk, at: .now)
                state.ready.append(contentsOf: step.passed)
                state.prepaid += step.held
                return step.held
            }
            if held > 0 { await credit(held) }
        }
    }

    /// The consumer took `count` bytes; returns the credit still owed for them.
    func consumed(_ count: Int) -> Int {
        state.withLock { state in
            let covered = min(count, state.prepaid)
            state.prepaid -= covered
            return count - covered
        }
    }

    private func release(ended: Bool = false) {
        state.withLock { state in
            if let held = state.reprint.release(at: .now, ended: ended) { state.ready.append(held) }
        }
    }
}

/// A read whose wait can end before it does. A cancelled read closes its
/// channel (`HerdrCoreLinkStream`), so a wait with a limit cannot cancel the
/// read it gives up on: the read runs in a task of its own, and the next wait
/// takes it up again. Only a cancelled waiter cancels it.
private final class PendingRead: Sendable {
    typealias Outcome = Result<Data?, any Error>

    private let task: Task<Data?, any Error>

    init(_ read: @escaping HerdrCoreReprintHold.Read) {
        task = Task { try await read() }
    }

    /// How the read ended, or nil once `limit` passes first.
    func outcome(within limit: Duration?) async -> Outcome? {
        let task = task
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome?, Never>) in
                let waiter = Waiter(continuation)
                let timer = limit.map { limit in
                    Task {
                        guard (try? await Task.sleep(for: limit)) != nil else { return }
                        waiter.resume(nil)
                    }
                }
                Task {
                    let outcome = await task.result
                    timer?.cancel()
                    waiter.resume(outcome)
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Resumes its continuation for whichever comes first, once.
    private final class Waiter: Sendable {
        private let continuation: Mutex<CheckedContinuation<Outcome?, Never>?>

        init(_ continuation: CheckedContinuation<Outcome?, Never>) {
            self.continuation = Mutex(continuation)
        }

        func resume(_ outcome: Outcome?) {
            let waiting = continuation.withLock { continuation in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: outcome)
        }
    }
}
