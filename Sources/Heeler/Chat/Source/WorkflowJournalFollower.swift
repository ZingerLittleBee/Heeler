import Foundation

/// Follows a Workflow's journal on the Host from its first byte, so every
/// agent the run started is read, however long ago it started.
///
/// Like `TranscriptFollower`, it judges the file by content, since SFTP has
/// no inode: the bytes just before the read position must still be there
/// for what follows to continue them. Unlike it, the file is small and read
/// whole, so a shrink or a changed anchor starts over at byte 0 rather than
/// opening a tail window, and one read covers the anchor and the new bytes.
///
/// A value type: its owner runs one poll at a time and keeps the result only
/// when the poll succeeds, so a failed read leaves the last good position.
struct WorkflowJournalFollower: Sendable {
    struct Limits: Sendable, Equatable {
        /// The largest single read; each runs under the transport deadline.
        var readChunk = 64 << 10
        var anchorLength = 64
        /// Start lines are short. A result line can run to many kilobytes,
        /// and only its start, which names the agent, is kept.
        var lineCap = 4 << 10
        var prefixCap = 1 << 10
        /// A journal larger than this is not read from its start. One
        /// already followed past it still reads what it appends.
        var maximumBytes = 8 << 20
    }

    enum Change: Equatable, Sendable {
        case unchanged
        case appended([ChatLine])
        /// The file no longer continues what was read. Everything delivered
        /// before is stale; the lines start again at byte 0.
        case restarted([ChatLine])
        case missing
        case tooLarge
    }

    let path: String
    let limits: Limits
    /// The next byte to read.
    private(set) var readOffset: UInt64 = 0
    /// The size from the last look.
    private(set) var knownSize: UInt64?
    /// The Host's modification time from the last look, in whole seconds.
    private(set) var modificationTime: UInt32?
    private var framer: JSONLLineFramer
    /// The bytes just before `readOffset`.
    private var tailAnchor = Data()

    init(path: String, limits: Limits = Limits()) {
        self.path = path
        self.limits = limits
        framer = JSONLLineFramer(startOffset: 0, lineCap: limits.lineCap, prefixCap: limits.prefixCap)
    }

    /// Whether everything the last look saw has been read.
    var isCaughtUp: Bool { knownSize.map { readOffset >= $0 } ?? false }

    /// One look: a stat, then reads of at most `budget` new bytes. An
    /// unchanged file costs the stat alone.
    mutating func poll(_ files: ChatHostFiles, budget: Int) async throws -> Change {
        guard let status = try await files.status(path) else { return .missing }
        var restarted = false
        if let size = status.size {
            if size < readOffset {
                restart()
                restarted = true
            } else if size == readOffset {
                knownSize = size
                if status.modificationTime == modificationTime { return .unchanged }
                // Written again at the same length: only the anchor tells.
                guard
                    let anchor = try await files.read(
                        path: path, from: readOffset - UInt64(tailAnchor.count), to: readOffset,
                        chunk: limits.readChunk)
                else { return .missing }
                guard anchor != tailAnchor else {
                    modificationTime = status.modificationTime
                    return .unchanged
                }
                restart()
                restarted = true
            }
            guard readOffset > 0 || size <= UInt64(limits.maximumBytes) else { return .tooLarge }
        }
        let end = status.size ?? readOffset + UInt64(budget)
        var lines: [ChatLine] = []
        var remaining = budget
        while readOffset < end, remaining > 0 {
            let anchor = tailAnchor
            let length = Int(min(UInt64(min(limits.readChunk, remaining)), end - readOffset))
            let slice = try await files.read(
                RemoteFileRange(
                    path: path, offset: readOffset - UInt64(anchor.count), maxBytes: anchor.count + length))
            guard let reported = slice.length else { return .missing }
            guard readOffset > 0 || reported <= UInt64(limits.maximumBytes) else { return .tooLarge }
            knownSize = reported
            guard slice.data.prefix(anchor.count) == anchor else {
                // Rewritten since the last look: read it again from the
                // start, within what is left of the budget.
                restart()
                restarted = true
                lines = []
                continue
            }
            let added = Data(slice.data.dropFirst(anchor.count))
            guard !added.isEmpty else { break }
            lines.append(contentsOf: framer.append(added))
            readOffset += UInt64(added.count)
            remaining -= added.count
            remember(added)
        }
        modificationTime = status.modificationTime
        if restarted { return .restarted(lines) }
        return lines.isEmpty ? .unchanged : .appended(lines)
    }

    private mutating func restart() {
        framer = JSONLLineFramer(startOffset: 0, lineCap: limits.lineCap, prefixCap: limits.prefixCap)
        readOffset = 0
        tailAnchor = Data()
    }

    private mutating func remember(_ data: Data) {
        let length = limits.anchorLength
        tailAnchor = data.count >= length ? Data(data.suffix(length)) : Data((tailAnchor + data).suffix(length))
    }
}
