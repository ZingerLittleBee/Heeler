import Foundation
import Synchronization

/// A viewer's first paint (`viewers.rs` `first_paint`): the core's own repaint of
/// the screen, with its modes, cursor and styles, then whether the program wants
/// win32 key events, then its status reports. That win32 mode always goes out, so
/// its sequence says the screen is all here. Rows arrive as `agent.read`'s do,
/// CRLF apart with SGR styling, so this is the one styled read a core offers:
/// `terminal.read` has text only (ADR 0035).
///
/// After the last row the paint moves the cursor to where the program left it. A
/// cursor waiting to wrap at the end of a row is restored by printing that row's
/// last character again, which is not more of the screen, so the rows end there.
///
/// The core queues the paint whole, ahead of any live byte, but its writer can cut
/// it into frames anywhere.
struct HerdrCoreFirstPaint {
    /// The win32 mode that closes every paint.
    static let endOfScreen = [Data("\u{1B}[?9001h".utf8), Data("\u{1B}[?9001l".utf8)]
    private static let controlSequence = Data("\u{1B}[".utf8)

    private var received = Data()

    /// Takes the next output, and returns the screen once the paint holds it all.
    mutating func receive(_ output: Data) -> ANSIScreen? {
        received.append(output)
        let ends = Self.endOfScreen.compactMap { received.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return nil }
        let rows = Self.rows(in: received[received.startIndex..<end])
        return ANSIScreenDecoder.decode(String(decoding: rows, as: UTF8.self))
    }

    /// Up to the last `CSI row ; column H`. A cell holds no escape, and the only
    /// other cursor moves come before the rows, with one parameter or none.
    private static func rows(in painted: Data) -> Data {
        var searched = painted
        while let sequence = searched.range(of: controlSequence, options: .backwards) {
            let parameters = painted[sequence.upperBound...].prefix { isDigit($0) || $0 == UInt8(ascii: ";") }
            if parameters.contains(UInt8(ascii: ";")), parameters.endIndex < painted.endIndex,
                painted[parameters.endIndex] == UInt8(ascii: "H")
            {
                return painted[painted.startIndex..<sequence.lowerBound]
            }
            searched = searched[searched.startIndex..<sequence.lowerBound]
        }
        return painted
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

/// Holds an attach's first paint until it is all here, so a surface takes it in
/// one write. The core queues the paint whole, ahead of any live byte, but its
/// writer cuts it into 16 KiB frames and credit lets 256 KiB through at a time.
/// Handed over frame by frame, a long main-screen session's history scrolls past
/// on screen for as long as the link takes to carry it; Ghostty parses one write
/// under its terminal lock, so the surface draws the latest screen once.
///
/// Held bytes return their credit as they arrive, or the core would stop at the
/// end of the first window and the paint would never close; the consumer's later
/// report of the same bytes is not credited again. Output that does not open as
/// a paint, and a paint that outgrows `limit` before its close, pass as they come.
final class HerdrCoreFirstPaintHold: Sendable {
    /// Where a paint starts (`ghostty-vt` `paint`): bare, as 0.1.13 sends it, or
    /// after the CAN that later cores put ahead of it.
    fileprivate static let openings = [Data("\u{1B}[!p".utf8), Data([0x18]) + Data("\u{1B}[!p".utf8)]
    fileprivate static let longestClose = HerdrCoreFirstPaint.endOfScreen.map(\.count).max() ?? 0

    private struct State {
        /// The paint so far; nil once output passes as it comes.
        var held: Data? = Data()
        /// What followed the close in the read that brought it.
        var afterPaint: Data?
        /// Held bytes already credited that the consumer has not reported.
        var prepaid = 0

        /// Adds `chunk` to the paint, and returns what goes out now: nil while
        /// the paint may still be unfinished.
        mutating func receive(_ chunk: Data, limit: Int) -> Data? {
            guard var paint = held else { return chunk }
            held = nil
            let searchFrom = max(0, paint.count - HerdrCoreFirstPaintHold.longestClose + 1)
            paint.append(chunk)
            let openings = HerdrCoreFirstPaintHold.openings
            guard openings.contains(where: { paint.starts(with: $0) }) else {
                guard openings.contains(where: { $0.starts(with: paint) }) else { return paint }
                held = paint
                return nil
            }
            let region = paint.index(paint.startIndex, offsetBy: searchFrom)..<paint.endIndex
            let closes = HerdrCoreFirstPaint.endOfScreen.compactMap { paint.range(of: $0, in: region)?.upperBound }
            if let close = closes.min() {
                if close < paint.endIndex {
                    afterPaint = Data(paint[close...])
                    paint.removeSubrange(close...)
                }
                return paint
            }
            guard paint.count <= limit else { return paint }
            held = paint
            return nil
        }
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int = HerdrCoreFrame.maximumPayload) {
        self.limit = limit
    }

    /// The next output: the whole paint first, then each read as it comes.
    /// `credit` returns a held read's credit on arrival.
    func next(
        read: () async throws -> Data?, credit: (Int) async -> Void
    ) async throws -> Data? {
        let afterPaint = state.withLock { state in
            defer { state.afterPaint = nil }
            return state.afterPaint
        }
        if let afterPaint { return afterPaint }
        while state.withLock({ $0.held != nil }) {
            guard let chunk = try await read() else {
                return state.withLock { state in
                    defer { state.held = nil }
                    return state.held?.isEmpty == false ? state.held : nil
                }
            }
            let output = state.withLock { state in
                let output = state.receive(chunk, limit: limit)
                if output == nil { state.prepaid += chunk.count }
                return output
            }
            if let output { return output }
            await credit(chunk.count)
        }
        return try await read()
    }

    /// The consumer took `count` bytes; returns the credit still owed for them.
    func consumed(_ count: Int) -> Int {
        state.withLock { state in
            let covered = min(count, state.prepaid)
            state.prepaid -= covered
            return count - covered
        }
    }
}
