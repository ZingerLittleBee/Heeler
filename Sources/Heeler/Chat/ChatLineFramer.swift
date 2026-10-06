import Foundation

/// One complete line of a JSON Lines transcript and where it sits in the
/// file. The newline is not included.
struct ChatLine: Equatable, Sendable {
    /// The offset of the line's first byte.
    let offset: UInt64
    /// The line's full length in bytes.
    let length: Int
    /// The line's bytes, or only their first `prefixCap` bytes when the line
    /// was longer than the framer keeps whole.
    let data: Data

    init(offset: UInt64, length: Int, data: Data) {
        self.offset = offset
        self.length = length
        self.data = data
    }

    init(offset: UInt64, data: Data) {
        self.init(offset: offset, length: data.count, data: data)
    }

    /// True when `data` holds only a prefix of the line.
    var isTruncated: Bool { data.count < length }

    /// The offset just past the line's newline.
    var end: UInt64 { offset + UInt64(length) + 1 }
}

/// Splits a transcript's bytes into complete lines.
///
/// Both programs write one JSON object per line and escape control
/// characters inside strings, so a raw 0x0A only ever ends a record, and a
/// read boundary can split UTF-8 but never a newline. Bytes after the last
/// newline wait for the next chunk: a line is handed on only once complete,
/// because the program may still be writing it.
///
/// A line longer than `lineCap` is not held whole. The framer keeps its first
/// `prefixCap` bytes and skips the rest up to the next newline, so a single
/// multi-megabyte tool output cannot hold the whole line in memory; callers
/// see the line's true length and a truncated `data`.
struct JSONLLineFramer: Sendable {
    /// Lines up to this many bytes are delivered whole.
    let lineCap: Int
    /// How much of a longer line is kept.
    let prefixCap: Int

    /// The offset just past the last complete line delivered, which is
    /// where the next unread line starts.
    private(set) var processedEnd: UInt64
    /// Where whole lines begin: the start offset, or the byte after the
    /// dropped leading fragment once its newline has arrived. Nil while the
    /// fragment is still being skipped.
    private(set) var deliveryStart: UInt64?
    /// Bytes of the line in progress, up to `lineCap` (or `prefixCap` once
    /// the line has outgrown `lineCap`).
    private var pending = Data()
    /// How many bytes of the line in progress have been seen, kept or not.
    private var pendingLength = 0
    private var isDiscardingFragment: Bool

    /// - Parameters:
    ///   - startOffset: the file offset of the first byte `append` receives.
    ///   - dropsLeadingFragment: true when `startOffset` may fall inside a
    ///     line, as at the start of a tail window: bytes up to the first
    ///     newline are skipped, since they cannot be parsed.
    init(
        startOffset: UInt64, dropsLeadingFragment: Bool = false,
        lineCap: Int = 8 * 1_024 * 1_024, prefixCap: Int = 16 * 1_024
    ) {
        self.lineCap = max(1, lineCap)
        self.prefixCap = max(0, min(prefixCap, lineCap))
        processedEnd = startOffset
        isDiscardingFragment = dropsLeadingFragment && startOffset > 0
        deliveryStart = isDiscardingFragment ? nil : startOffset
    }

    /// The bytes received after the last complete line.
    var pendingByteCount: Int { pendingLength }

    /// Feeds the next bytes of the file and returns the lines they complete,
    /// in order. Empty lines are skipped but still advance the offset.
    mutating func append(_ chunk: Data) -> [ChatLine] {
        var lines: [ChatLine] = []
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            guard let newline = chunk[cursor...].firstIndex(of: 0x0A) else {
                absorb(chunk[cursor...])
                break
            }
            absorb(chunk[cursor..<newline])
            if let line = finishLine() {
                lines.append(line)
            }
            cursor = chunk.index(after: newline)
        }
        return lines
    }

    private mutating func absorb(_ bytes: Data.SubSequence) {
        guard !bytes.isEmpty else { return }
        if isDiscardingFragment {
            processedEnd += UInt64(bytes.count)
            return
        }
        let kept = pendingLength < lineCap ? lineCap - pendingLength : 0
        pendingLength += bytes.count
        if kept > 0 {
            pending.append(contentsOf: bytes.prefix(kept))
        }
        if pendingLength > lineCap, pending.count > prefixCap {
            pending.removeSubrange(pending.index(pending.startIndex, offsetBy: prefixCap)...)
        }
    }

    /// Ends the line in progress at a newline.
    private mutating func finishLine() -> ChatLine? {
        let start = processedEnd
        if isDiscardingFragment {
            isDiscardingFragment = false
            processedEnd += 1
            deliveryStart = processedEnd
            return nil
        }
        let length = pendingLength
        let data = pending
        pending = Data()
        pendingLength = 0
        processedEnd = start + UInt64(length) + 1
        guard length > 0 else { return nil }
        return ChatLine(offset: start, length: length, data: data)
    }
}

extension JSONLLineFramer {
    /// Frames a whole file held in memory, for fixtures and small reads.
    static func lines(
        in data: Data, startOffset: UInt64 = 0, dropsLeadingFragment: Bool = false,
        lineCap: Int = 8 * 1_024 * 1_024, prefixCap: Int = 16 * 1_024
    ) -> [ChatLine] {
        var framer = JSONLLineFramer(
            startOffset: startOffset, dropsLeadingFragment: dropsLeadingFragment,
            lineCap: lineCap, prefixCap: prefixCap)
        return framer.append(data)
    }
}
