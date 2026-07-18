import Foundation

/// One Observe live-follow request (#9): the `herdr terminal session
/// observe` target (a Pane address) plus the terminal geometry the server
/// should render frames for.
struct TerminalObserveRequest: Sendable, Equatable {
    let target: String
    let cols: Int
    let rows: Int

    init(target: String, cols: Int, rows: Int) {
        self.target = target
        self.cols = cols
        self.rows = rows
    }
}

/// One frame of the observe stream. The wire is NDJSON (verified against
/// herdr 0.7.4, issue #9): each line is
/// `{"type":"terminal.frame","seq":N,"full":bool,"width","height",
///   "encoding":"ansi","bytes":"<base64>"}`.
struct TerminalFrame: Sendable, Equatable {
    /// Monotonic frame counter; a gap means frames were dropped and the
    /// consumer should re-observe for a fresh full repaint.
    let seq: Int
    /// A full frame is a complete screen repaint (always the stream's first
    /// frame); non-full frames are incremental updates.
    let isFull: Bool
    let width: Int?
    let height: Int?
    /// Decoded ANSI bytes, ready to feed a terminal emulator. Never feed the
    /// wire line itself — the wire carries base64 inside JSON.
    let bytes: Data

    init(seq: Int, isFull: Bool, width: Int? = nil, height: Int? = nil, bytes: Data) {
        self.seq = seq
        self.isFull = isFull
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Decodes one observe-stream line. Returns nil for anything that is not
    /// a renderable terminal frame — lenient by design (herdr's API has no
    /// stability guarantee): unknown frame types, unknown encodings, and
    /// junk lines are dropped, never fatal.
    static func decode(fromLine data: Data) -> TerminalFrame? {
        guard let line = try? JSONDecoder().decode(FrameLine.self, from: data) else { return nil }
        guard line.type == "terminal.frame" else { return nil }
        // Only ANSI payloads are renderable; a frame in an encoding this
        // build does not know must not be fed to the terminal as ANSI.
        if let encoding = line.encoding, encoding != "ansi" { return nil }
        guard let bytes = Data(base64Encoded: line.bytes) else { return nil }
        return TerminalFrame(
            seq: line.seq, isFull: line.full ?? false,
            width: line.width, height: line.height, bytes: bytes)
    }

    private struct FrameLine: Decodable {
        let type: String
        let seq: Int
        let full: Bool?
        let width: Int?
        let height: Int?
        let encoding: String?
        let bytes: String
    }
}

/// A live observe stream over its Host's dedicated terminal exec channel.
///
/// Ending is explicit: call `end()`. A live exec channel does not respond to
/// Swift task cancellation (ADR 0002), so abandoning the stream without
/// `end()` leaks the channel until the SSH connection closes.
final class TerminalFrameStream: Sendable {
    /// Frames in arrival order. Finishes without error after `end()`,
    /// finishes throwing if the channel dies remotely.
    let frames: AsyncThrowingStream<TerminalFrame, any Error>
    private let ender: @Sendable () async -> Void

    init(
        frames: AsyncThrowingStream<TerminalFrame, any Error>,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.frames = frames
        self.ender = ender
    }

    /// Closes the terminal channel explicitly and waits for its teardown;
    /// the stream then finishes without error. Idempotent.
    func end() async {
        await ender()
    }
}
