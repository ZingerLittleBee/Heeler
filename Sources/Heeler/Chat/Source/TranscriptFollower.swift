import Foundation

/// Follows one transcript file on the Host: opens at its tail, reads what the
/// Agent appends, pages backwards on request, and notices when the file was
/// rewritten in place or replaced.
///
/// SFTP version 3 has no inode and whole-second modification times, so the
/// follower judges identity by content: the file's first bytes and the bytes
/// just before its read position. Offsets advance by the bytes
/// actually received, never by a reported length, and a line is handed on
/// only once its newline has arrived.
///
/// A value type: its owner runs one operation at a time and stores the
/// result, so at most one read per conversation is in flight.
struct TranscriptFollower: Sendable {
    struct Limits: Sendable, Equatable {
        /// How much of the file's end is read on open.
        var tailWindow = 1 << 20
        /// The largest single read; each runs under the transport deadline.
        var readChunk = 256 << 10
        /// The most one poll reads before handing lines on.
        var pollBudget = 2 << 20
        /// The first backward page; it doubles while a line does not fit.
        var olderPage = 512 << 10
        /// The largest backward page held in memory. Beyond it the start of a
        /// longer line is searched for without keeping its bytes.
        var maximumOlderPage = 8 << 20
        /// How far one request for older history reads back while its pages
        /// add nothing to show: long tool output and records off the
        /// conversation's branch can fill many pages.
        var olderSearch = 8 << 20
        /// How far that search goes before older history is reported
        /// unreadable.
        var lineStartSearch = 64 << 20
        var anchorLength = 64
        /// How much of the file's start identifies it.
        var headLength = 4 << 10
        var lineCap = 8 << 20
        var prefixCap = 16 << 10
    }

    enum Change: Equatable, Sendable {
        case unchanged
        case appended([ChatLine])
        /// The file was rewritten in place (`replaced == false`) or is a
        /// different file (`replaced == true`). Everything delivered before is
        /// stale; the lines are a fresh tail window.
        case reset([ChatLine], replaced: Bool)
        /// The file is gone. The follower keeps its state; the owner keeps
        /// what it showed and looks for the file again.
        case missing
    }

    enum OlderPage: Equatable, Sendable {
        case lines([ChatLine])
        case headReached
        /// The line before the window is longer than the search allows.
        case unreadable
        case missing
        /// The bytes before the window changed; poll to reload.
        case rewritten
    }

    let path: String
    let limits: Limits
    private(set) var framer: JSONLLineFramer
    /// The next byte to read.
    private(set) var readOffset: UInt64 = 0
    /// Where the earliest loaded line starts; 0 once the head is loaded, nil
    /// while a line longer than the tail window is still being skipped.
    private(set) var windowStart: UInt64?
    /// The size from the last look, used to tell whether more is waiting.
    private(set) var knownSize: UInt64?
    private(set) var modificationTime: UInt32?
    /// The file's first `headLength` bytes when it was opened.
    private(set) var head: Data?
    /// The bytes just before `readOffset`.
    private(set) var tailAnchor = Data()
    private(set) var isOpen = false

    init(path: String, limits: Limits = Limits()) {
        self.path = path
        self.limits = limits
        framer = JSONLLineFramer(startOffset: 0, lineCap: limits.lineCap, prefixCap: limits.prefixCap)
    }

    /// Whether lines older than the window remain on the Host.
    var hasOlder: Bool { (windowStart ?? 0) > 0 }

    /// Whether the last look saw bytes this follower has not read yet.
    var hasUnreadBytes: Bool { knownSize.map { $0 > readOffset } ?? false }

    /// Reads the file's last `tailWindow` bytes. Nil when the file is gone.
    mutating func open(_ files: ChatHostFiles) async throws -> [ChatLine]? {
        // Any failure below leaves the follower closed, so the next poll
        // reopens instead of continuing from a half-reset position.
        isOpen = false
        guard let status = try await files.status(path) else { return nil }
        let size = status.size ?? 0
        let start = size > UInt64(limits.tailWindow) ? size - UInt64(limits.tailWindow) : 0
        framer = JSONLLineFramer(
            startOffset: start, dropsLeadingFragment: start > 0,
            lineCap: limits.lineCap, prefixCap: limits.prefixCap)
        readOffset = start
        windowStart = framer.deliveryStart
        tailAnchor = Data()
        modificationTime = status.modificationTime
        knownSize = size
        guard let lines = try await readForward(files, until: size, budget: limits.tailWindow),
            let head = try await files.read(
                path: path, from: 0, to: UInt64(limits.headLength), chunk: limits.readChunk)
        else { return nil }
        self.head = head
        isOpen = true
        return lines
    }

    /// One look at the file: a stat, then a read only when it changed.
    mutating func poll(_ files: ChatHostFiles) async throws -> Change {
        guard isOpen else { return try await reload(files) }
        guard let status = try await files.status(path) else { return .missing }
        if let size = status.size {
            knownSize = size
            if size < readOffset { return try await reload(files) }
            if size == readOffset {
                if status.modificationTime == modificationTime { return .unchanged }
                guard try await anchorStillMatches(files) else { return try await reload(files) }
                modificationTime = status.modificationTime
                return .unchanged
            }
        }
        let anchorStart = readOffset - UInt64(tailAnchor.count)
        let end = status.size ?? (readOffset + UInt64(limits.pollBudget))
        guard
            let overlap = try await files.read(
                path: path, from: anchorStart, to: readOffset, chunk: limits.readChunk)
        else { return .missing }
        guard overlap == tailAnchor else { return try await reload(files) }
        guard let lines = try await readForward(files, until: end, budget: limits.pollBudget)
        else { return .missing }
        modificationTime = status.modificationTime
        return lines.isEmpty ? .unchanged : .appended(lines)
    }

    /// Reads the lines just before the window, oldest first.
    mutating func loadOlder(_ files: ChatHostFiles) async throws -> OlderPage {
        guard let end = windowStart, end > 0 else { return .headReached }
        var pageLength = UInt64(limits.olderPage)
        var page = Data()
        var start = end
        while true {
            // A grown page reads only the bytes it adds.
            let newStart = end > pageLength ? end - pageLength : 0
            guard
                let added = try await files.read(
                    path: path, from: newStart, to: start, chunk: limits.readChunk)
            else { return .missing }
            guard added.count == Int(start - newStart) else { return .rewritten }
            page = added + page
            start = newStart
            // `end` is a line start, so the byte before it ends a line.
            guard page.last == 0x0A else { return .rewritten }
            var pageFramer = JSONLLineFramer(
                startOffset: start, dropsLeadingFragment: start > 0,
                lineCap: limits.lineCap, prefixCap: limits.prefixCap)
            let lines = pageFramer.append(page)
            if start == 0 {
                windowStart = 0
                return .lines(lines)
            }
            if let first = pageFramer.deliveryStart, first < end {
                windowStart = first
                return .lines(lines)
            }
            if pageLength >= UInt64(limits.maximumOlderPage) {
                return try await loadLineLongerThanPage(files, before: end, searchedFrom: start)
            }
            pageLength = min(pageLength * 2, UInt64(limits.maximumOlderPage))
        }
    }

    // MARK: Reading

    /// Reads from `readOffset` toward `end`, at most `budget` bytes, feeding
    /// the framer. Nil when the file disappeared mid-read.
    private mutating func readForward(
        _ files: ChatHostFiles, until end: UInt64, budget: Int
    ) async throws -> [ChatLine]? {
        var lines: [ChatLine] = []
        var remaining = budget
        while readOffset < end, remaining > 0 {
            let length = Int(min(UInt64(min(limits.readChunk, remaining)), end - readOffset))
            let slice = try await files.read(
                RemoteFileRange(path: path, offset: readOffset, maxBytes: length))
            guard let reported = slice.length else { return nil }
            knownSize = reported
            guard !slice.data.isEmpty else { break }
            lines.append(contentsOf: framer.append(slice.data))
            readOffset += UInt64(slice.data.count)
            remaining -= slice.data.count
            remember(slice.data)
            if windowStart == nil { windowStart = framer.deliveryStart }
        }
        return lines
    }

    private mutating func remember(_ data: Data) {
        let length = limits.anchorLength
        if data.count >= length {
            tailAnchor = Data(data.suffix(length))
        } else {
            tailAnchor = Data((tailAnchor + data).suffix(length))
        }
    }

    private func anchorStillMatches(_ files: ChatHostFiles) async throws -> Bool {
        guard !tailAnchor.isEmpty else { return true }
        let start = readOffset - UInt64(tailAnchor.count)
        let bytes = try await files.read(path: path, from: start, to: readOffset, chunk: limits.readChunk)
        return bytes == tailAnchor
    }

    /// The file no longer continues what was read. If its start still
    /// matches, it was edited in place (Claude rewrites a transcript to drop
    /// records); otherwise it is a different file under the same name.
    private mutating func reload(_ files: ChatHostFiles) async throws -> Change {
        let previousHead = head
        guard let lines = try await open(files) else { return .missing }
        return .reset(lines, replaced: !Self.sameStart(previousHead, head))
    }

    /// Whether two heads agree over the bytes both have. A file read as
    /// empty either time identifies nothing.
    static func sameStart(_ a: Data?, _ b: Data?) -> Bool {
        guard let a, let b else { return false }
        let shared = min(a.count, b.count)
        return shared > 0 && a.prefix(shared) == b.prefix(shared)
    }

    /// The line ending at `end` began before the largest page. Searches
    /// backwards for its start without keeping its bytes, then hands it on
    /// truncated to its first `prefixCap` bytes, as the framer would.
    private mutating func loadLineLongerThanPage(
        _ files: ChatHostFiles, before end: UInt64, searchedFrom pageStart: UInt64
    ) async throws -> OlderPage {
        var searchEnd = pageStart
        var searched: UInt64 = 0
        var lineStart: UInt64?
        while lineStart == nil {
            if searchEnd == 0 {
                lineStart = 0
                break
            }
            guard searched < UInt64(limits.lineStartSearch) else { return .unreadable }
            let step = min(UInt64(limits.readChunk), searchEnd)
            let start = searchEnd - step
            guard
                let chunk = try await files.read(
                    path: path, from: start, to: searchEnd, chunk: limits.readChunk)
            else { return .missing }
            guard chunk.count == Int(step) else { return .rewritten }
            if let newline = chunk.lastIndex(of: 0x0A) {
                lineStart = start + UInt64(chunk.distance(from: chunk.startIndex, to: newline)) + 1
            }
            searchEnd = start
            searched += step
        }
        guard let lineStart else { return .unreadable }
        let length = Int(end - 1 - lineStart)
        guard
            let prefix = try await files.read(
                path: path, from: lineStart,
                to: lineStart + UInt64(min(limits.prefixCap, length)), chunk: limits.readChunk)
        else { return .missing }
        windowStart = lineStart
        return .lines([ChatLine(offset: lineStart, length: length, data: prefix)])
    }
}
