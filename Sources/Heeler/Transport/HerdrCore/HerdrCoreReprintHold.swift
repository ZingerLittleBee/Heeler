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
/// comes: what stays on screen while the block is on its way is whatever the
/// program left there.
///
/// The reprint is not always the first block after the erase: on the resize
/// that follows an attach, Antigravity CLI at times repaints its status line
/// in a block of its own in between. So a block that opens right behind a
/// held one is held as well.
struct HerdrCoreReprint {
    /// What one read came to: the bytes that go out now, in order, and how
    /// many of the read's own bytes stay held.
    struct Step: Equatable {
        var passed: [Data] = []
        var held = 0
    }

    private static let blockOpen = Data("\u{1B}[?2026h".utf8)
    private static let blockClose = Data("\u{1B}[?2026l".utf8)
    private static let erase = Data("\u{1B}[3J".utf8)
    /// The erase, then at most a cursor move home, then the block's opening.
    private static let openings = [erase + blockOpen, erase + Data("\u{1B}[H".utf8) + blockOpen]
    /// An opening cut across reads starts within this much of a read's end.
    private static let overlap = (openings.map(\.count).max() ?? 1) - 1

    /// The block so far; nil while output passes as it comes.
    private var block: Data?
    /// The end of what last passed, where an opening cut across reads begins.
    private var passedEnd = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var isHolding: Bool { block != nil }

    /// Takes the next read. A block that closes in it goes out whole, and what
    /// follows the close is looked at like any other output. A block that
    /// outgrows `limit` goes out as it stands, and the rest of it passes.
    mutating func receive(_ read: Data) -> Step {
        var step = Step()
        var rest = read
        while !rest.isEmpty {
            guard var held = block else {
                let window = passedEnd + rest
                let starts = Self.openings.compactMap { opening in
                    window.range(of: opening).map { $0.upperBound - Self.blockOpen.count }
                }
                guard let start = starts.min() else {
                    passedEnd = Data(window.suffix(Self.overlap))
                    step.passed.append(rest)
                    return step
                }
                // A block whose opening began in the last read is held from here:
                // the surface already has the opening's first bytes and takes the
                // rest with the block.
                let cut = max(0, start - passedEnd.count)
                if cut > 0 { step.passed.append(Data(rest.prefix(cut))) }
                rest = Data(rest.dropFirst(cut))
                passedEnd = Data()
                block = Data()
                continue
            }
            block = nil
            let searchFrom = max(0, held.count - Self.blockClose.count + 1)
            held.append(rest)
            guard let close = held.range(of: Self.blockClose, in: searchFrom..<held.count) else {
                guard held.count <= limit else {
                    passedEnd = Data(held.suffix(Self.overlap))
                    step.passed.append(held)
                    step.held = 0
                    return step
                }
                step.held += rest.count
                block = held
                return step
            }
            rest = Data(held[close.upperBound...])
            held.removeSubrange(close.upperBound...)
            // The erase stands for a block that opens right behind this one.
            passedEnd = Self.erase
            step.passed.append(held)
            step.held = 0
        }
        return step
    }

    /// Hands over what is held and lets output pass again: the block went
    /// quiet, or the output ended.
    mutating func release() -> Data? {
        guard let held = block else { return nil }
        block = nil
        passedEnd = Data(held.suffix(Self.overlap))
        return held
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
final class HerdrCoreReprintHold: Sendable {
    typealias Read = @Sendable () async throws -> Data?
    typealias Credit = @Sendable (Int) async -> Void

    /// Two seconds: a 16 KiB frame still arrives within it at 8 KB/s, so a slow
    /// link alone does not end a hold.
    static let quiet: Duration = .seconds(2)

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
    private let quiet: Duration

    /// `read` gives the attach's output after its first paint, and `credit`
    /// returns a held read's credit on arrival.
    init(
        limit: Int = HerdrCoreFrame.maximumPayload, quiet: Duration = HerdrCoreReprintHold.quiet,
        read: @escaping Read, credit: @escaping Credit
    ) {
        state = Mutex(State(reprint: HerdrCoreReprint(limit: limit)))
        self.read = read
        self.credit = credit
        self.quiet = quiet
    }

    /// The next output: each read as it comes, and a reprint whole.
    func next() async throws -> Data? {
        while true {
            let (output, ended, pending, holding) = state.withLock { state in
                (state.ready.isEmpty ? nil : state.ready.removeFirst(), state.ended, state.pending,
                    state.reprint.isHolding)
            }
            if let output { return output }
            if ended { return nil }
            let chunk: Data?
            if pending == nil, !holding {
                chunk = try await read()
            } else {
                // Only a held block is waited on with a limit, and a wait that
                // gives up must leave its read in flight for the next one.
                let inFlight = pending ?? PendingRead(read)
                state.withLock { $0.pending = inFlight }
                guard let outcome = await inFlight.outcome(within: holding ? quiet : nil) else {
                    release()
                    continue
                }
                state.withLock { $0.pending = nil }
                chunk = try outcome.get()
            }
            guard let chunk else {
                state.withLock { $0.ended = true }
                release()
                continue
            }
            let held = state.withLock { state in
                let step = state.reprint.receive(chunk)
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

    private func release() {
        state.withLock { state in
            if let block = state.reprint.release(), !block.isEmpty { state.ready.append(block) }
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
