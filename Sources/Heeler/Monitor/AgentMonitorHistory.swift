import Foundation

/// Monitor's local scrollback cache: captured line runs and explicit gap
/// markers, ordered oldest first. The final line run is always the live
/// screen, kept separate from backfilled or sealed history. In-memory only.
///
/// herdr exposes no history cursor (`agent.read` takes a source and a line
/// count, capped at 1000 lines), so every reconciliation is an
/// overlap-stitch against what the cache already holds. This type is the
/// pure line algebra behind that: it performs no I/O, keeps no presentation
/// state, and is deliberately separate from `AgentMonitorStore` so the
/// stitching rules are testable on their own.
struct AgentMonitorHistory: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        /// One contiguous captured run. Adjacent line segments may exist to
        /// preserve the boundary between backfilled history and live output.
        case lines([String])
        /// An explicit marker that the content between the neighbouring runs
        /// could not be captured or reconciled. Never guessed around.
        case gap
    }

    /// The smallest suffix/prefix overlap accepted as proof that two reads
    /// cover the same content. Smaller coincidences (a shared blank line, a
    /// repeated prompt) are treated as no overlap, because a spurious gap is
    /// honest while a spurious stitch silently corrupts history. When one
    /// side is shorter than this, the overlap floor drops to that length: a
    /// whole-screen match is correct by construction there.
    static let minimumOverlap = 3

    /// The final `.lines` segment is always the live screen. Backfilled and
    /// sealed live runs remain separate from it, including when they are
    /// known to be contiguous; only a `.gap` claims unknown continuity.
    private(set) var segments: [Segment] = []

    /// The range reconciled by the most recent backfill. It normally spans
    /// the current history suffix and live run. After an unstitched read it
    /// instead points at that read above the gap, so a later, deeper read can
    /// extend it without moving captured history below the live screen.
    private var backfillRange: Range<Int>?

    var isEmpty: Bool {
        segments.isEmpty
    }

    /// The live mirror of the Agent's screen, always the final segment.
    var newestLines: [String] {
        guard case .lines(let lines) = segments.last else { return [] }
        return lines
    }

    enum VisibleOutcome: Equatable, Sendable {
        /// The read carried no new content.
        case unchanged
        /// The read's top overlapped the live screen's bottom; newly scrolled
        /// lines were appended to the live run.
        case extended
        /// No usable overlap (an alternate-screen repaint, or a reconnect
        /// that scrolled a full screen): a new live run was installed.
        case replaced
    }

    /// Reconciles one `visible` read with the live tail. The visible screen
    /// is a sliding window: when its top lines match the live run's bottom,
    /// only fresh lines are appended. Otherwise the old live run is sealed
    /// as history and the repaint becomes a new live run below a gap.
    @discardableResult
    mutating func applyVisible(_ text: String) -> VisibleOutcome {
        let read = Self.splitLines(text)
        guard let newest = newestLinesIfPresent else {
            // The first install always reports a change: even an empty
            // screen must paint, or the store never renders and the view
            // loads forever.
            segments = [.lines(read)]
            backfillRange = 0..<1
            return .replaced
        }
        guard read != newest else { return .unchanged }
        // A read fully contained at the tail (a shorter screen, or the same
        // screen while the live run accumulated scrolling) changes nothing.
        // The empty read is excluded: a cleared screen is a replacement.
        if !read.isEmpty, read.count <= newest.count, newest.suffix(read.count) == read {
            return .unchanged
        }
        let floor = min(Self.minimumOverlap, read.count, newest.count)
        if floor >= 1,
            let overlap = Self.largestOverlap(suffixOf: newest, prefixOf: read, floor: floor)
        {
            let fresh = read.suffix(read.count - overlap)
            guard !fresh.isEmpty else { return .unchanged }
            segments[segments.count - 1] = .lines(newest + fresh)
            return .extended
        }

        // Replacing only the live segment preserves every backfilled and
        // previously sealed run. There is no content to seal when the old
        // live screen was empty, so reuse that final slot in that case.
        if newest.isEmpty {
            segments[segments.count - 1] = .lines(read)
        } else {
            segments.append(.gap)
            segments.append(.lines(read))
        }
        backfillRange = (segments.count - 1)..<segments.count
        return .replaced
    }

    struct BackfillOutcome: Equatable, Sendable {
        /// Lines the read added that the cache did not already hold. Zero
        /// means the read was fully captured: the capture limit is reached.
        var newLines: Int
        /// Whether an explicit gap marker was inserted because the read
        /// could not be overlap-stitched onto the cache.
        var insertedGap: Bool
    }

    /// Reconciles one `recent` read (the server's newest lines, up to its
    /// cap) with the range covered by the preceding backfill. The largest
    /// shared suffix proves the read's remaining prefix is older content,
    /// which is kept in a segment above the live screen. With no shared
    /// content, the read is likewise placed above the live run with explicit
    /// gaps rather than displacing the live screen or pretending continuity.
    @discardableResult
    mutating func stitchBackfill(_ text: String) -> BackfillOutcome {
        let read = Self.splitLines(text)
        guard !read.isEmpty else {
            return BackfillOutcome(newLines: 0, insertedGap: false)
        }
        guard let newest = newestLinesIfPresent else {
            segments = [.lines(read)]
            backfillRange = 0..<1
            return BackfillOutcome(newLines: read.count, insertedGap: false)
        }
        if newest.isEmpty {
            let liveIndex = segments.count - 1
            segments.insert(.lines(read), at: liveIndex)
            backfillRange = liveIndex..<(liveIndex + 2)
            return BackfillOutcome(newLines: read.count, insertedGap: false)
        }

        let range = validBackfillRange ?? ((segments.count - 1)..<segments.count)
        let anchor = lines(in: range)
        let floor = min(Self.minimumOverlap, read.count, anchor.count)
        if floor >= 1,
            let overlap = Self.largestOverlap(suffixOf: read, suffixOf: anchor, floor: floor)
        {
            let older = Array(read.prefix(read.count - overlap))
            guard !older.isEmpty else {
                return BackfillOutcome(newLines: 0, insertedGap: false)
            }
            prepend(older, to: range)
            return BackfillOutcome(newLines: older.count, insertedGap: false)
        }
        if anchor.count >= Self.minimumOverlap,
            Self.containment(of: anchor, in: read) != nil
        {
            replaceBackfillRange(range, with: read)
            return BackfillOutcome(
                newLines: max(0, read.count - anchor.count), insertedGap: false)
        }
        insertUnstitchedBackfill(read)
        return BackfillOutcome(newLines: read.count, insertedGap: true)
    }

    /// Splits read text into lines, dropping the one empty fragment a
    /// trailing newline leaves behind. Interior empty lines are content;
    /// empty text is zero lines (Foundation's split would say one).
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    /// `nil` only when the cache is empty; the invariant keeps a trailing
    /// `.lines` run otherwise, even if it holds zero lines.
    private var newestLinesIfPresent: [String]? {
        guard case .lines(let lines) = segments.last else { return nil }
        return lines
    }

    private var validBackfillRange: Range<Int>? {
        guard
            let backfillRange,
            backfillRange.lowerBound >= segments.startIndex,
            backfillRange.upperBound <= segments.endIndex,
            !backfillRange.isEmpty,
            segments[backfillRange].allSatisfy({ segment in
                if case .lines = segment { return true }
                return false
            })
        else { return nil }
        return backfillRange
    }

    private func lines(in range: Range<Int>) -> [String] {
        range.flatMap { index in
            guard case .lines(let lines) = segments[index] else { return [] }
            return lines
        }
    }

    private mutating func prepend(_ older: [String], to range: Range<Int>) {
        guard case .lines(let first) = segments[range.lowerBound] else { return }
        if range.lowerBound == segments.count - 1 {
            segments.insert(.lines(older), at: range.lowerBound)
            backfillRange = range.lowerBound..<(range.upperBound + 1)
        } else {
            segments[range.lowerBound] = .lines(older + first)
            backfillRange = range
        }
    }

    private mutating func replaceBackfillRange(
        _ range: Range<Int>,
        with read: [String]
    ) {
        guard range.upperBound == segments.endIndex else {
            segments.replaceSubrange(range, with: [.lines(read)])
            backfillRange = range.lowerBound..<(range.lowerBound + 1)
            return
        }

        // A racing `recent` read can contain the previous screen before its
        // newest lines. Preserve the live/history boundary by treating a
        // screen-sized suffix as the new live run.
        let liveCount = min(newestLines.count, read.count)
        let history = Array(read.dropLast(liveCount))
        let live = Array(read.suffix(liveCount))
        let replacement: [Segment]
        if history.isEmpty {
            replacement = [.lines(live)]
        } else {
            replacement = [.lines(history), .lines(live)]
        }
        segments.replaceSubrange(range, with: replacement)
        backfillRange = range.lowerBound..<(range.lowerBound + replacement.count)
    }

    private mutating func insertUnstitchedBackfill(_ read: [String]) {
        let liveIndex = segments.count - 1
        var insertion: [Segment] = []
        if liveIndex > 0, segments[liveIndex - 1] != .gap {
            insertion.append(.gap)
        }
        let readOffset = insertion.count
        insertion.append(.lines(read))
        insertion.append(.gap)
        segments.insert(contentsOf: insertion, at: liveIndex)
        let readIndex = liveIndex + readOffset
        backfillRange = readIndex..<(readIndex + 1)
    }

    /// The largest `k >= floor` such that the two collections share a
    /// suffix/prefix (or suffix/suffix) of length `k`, searching longest
    /// first so a genuine deep overlap always wins over a coincidental
    /// short one.
    private static func largestOverlap(
        suffixOf first: [String],
        prefixOf second: [String],
        floor: Int
    ) -> Int? {
        var candidate = min(first.count, second.count)
        while candidate >= floor {
            if first.suffix(candidate) == second.prefix(candidate) {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }

    private static func largestOverlap(
        suffixOf first: [String],
        suffixOf second: [String],
        floor: Int
    ) -> Int? {
        var candidate = min(first.count, second.count)
        while candidate >= floor {
            if first.suffix(candidate) == second.suffix(candidate) {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }

    /// The rightmost position at which `needle` appears in `haystack` as a
    /// contiguous run, if any. Rightmost because the newest run sits at the
    /// end of a `recent` read when content is stable; an earlier duplicate
    /// of the same lines is history, not the tail.
    private static func containment(of needle: [String], in haystack: [String]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var start = haystack.count - needle.count
        while start >= 0 {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return start
            }
            start -= 1
        }
        return nil
    }
}
