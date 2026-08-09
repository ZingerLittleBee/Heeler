import Foundation

/// Monitor's local scrollback cache: captured line runs and explicit gap
/// markers, ordered oldest first. The final line run is always exactly the
/// live screen, kept separate from backfilled, proven-stitched, or sealed
/// history. In-memory only.
///
/// herdr exposes no history cursor (`agent.read` takes a source and a line
/// count, capped at 1000 lines), so every reconciliation is an
/// overlap-stitch against what the cache already holds. Backfill uses
/// `recent_unwrapped`, while the live screen remains a terminal grid; the
/// stitcher therefore permits one logical backfill line to match multiple
/// trailing grid rows after trimming terminal padding. It never rewrites the
/// captured bytes, and it still records a gap unless a whole boundary or at
/// least `minimumOverlap` logical lines prove continuity. This type is the
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

    /// Truly distinct live screens remain useful context, but they cannot
    /// grow without bound during a long-running alternate-screen session.
    /// Backfilled and overlap-proven history does not count against this cap.
    static let maximumSealedLiveGenerations = 8

    private static let minimumNearDuplicateLineCount = 5
    private static let maximumNearDuplicateLineDifferences = 2

    /// The final `.lines` segment is always the live screen. Backfilled and
    /// sealed live runs remain separate from it, including when they are
    /// known to be contiguous; only a `.gap` claims unknown continuity.
    private(set) var segments: [Segment] = []

    /// Indices of live screens retained only because a later non-overlapping
    /// read replaced them. Their adjacent generation gaps are tracked by
    /// position. Other line segments are proven history and never capped.
    private var sealedLiveGenerationIndices: [Int] = []

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
        /// The read's top overlapped the live screen's bottom; rows proven to
        /// have scrolled off were preserved above the new exact live screen.
        case extended
        /// The live screen changed without a scroll overlap. Near-duplicate
        /// repaints replace it in place; distinct screens start a generation.
        case replaced
    }

    /// Reconciles one `visible` read with the live tail. The visible screen
    /// is a sliding window: when its top lines match the live run's bottom,
    /// scrolled-off rows become proven history. Otherwise a near-duplicate
    /// repaint replaces the live run in place, while a distinct screen seals
    /// the old live run and starts a new generation below a gap.
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
        guard !Self.areByteIdentical(read, newest) else { return .unchanged }
        // A read fully contained at the tail (a shorter version of the same
        // screen) changes nothing.
        // The empty read is excluded: a cleared screen is a replacement.
        if !read.isEmpty,
            read.count <= newest.count,
            Self.areByteIdentical(newest.suffix(read.count), read)
        {
            return .unchanged
        }
        // Alternate-screen repaint ticks usually preserve the screen shape
        // and change only a spinner, timer, or status row. They are the same
        // live generation, so replace it in place rather than retaining a
        // near-identical sealed screen on every poll.
        if Self.isNearDuplicate(newest, read) {
            segments[segments.count - 1] = .lines(read)
            backfillRange = contiguousTailRange
            return .replaced
        }

        let floor = min(Self.minimumOverlap, read.count, newest.count)
        if floor >= 1,
            let overlap = Self.largestOverlap(suffixOf: newest, prefixOf: read, floor: floor)
        {
            guard overlap < read.count else { return .unchanged }
            let scrolledOff = Array(newest.prefix(newest.count - overlap))
            installExtendedLiveScreen(read, preserving: scrolledOff)
            return .extended
        }

        // Replacing only the live segment preserves every backfilled and
        // previously sealed run. There is no content to seal when the old
        // live screen was empty, so reuse that final slot in that case.
        if newest.isEmpty {
            segments[segments.count - 1] = .lines(read)
        } else {
            sealedLiveGenerationIndices.append(segments.count - 1)
            segments.append(.gap)
            segments.append(.lines(read))
        }
        backfillRange = (segments.count - 1)..<segments.count
        trimSealedLiveGenerations()
        return .replaced
    }

    struct BackfillOutcome: Equatable, Sendable {
        /// Logical lines the read added that the cache did not already hold.
        /// Zero means the read was fully captured: the capture limit is
        /// reached.
        var newLines: Int
        /// Whether an explicit gap marker was inserted because the read
        /// could not be overlap-stitched onto the cache.
        var insertedGap: Bool
    }

    /// Reconciles one `recent_unwrapped` read (the server's newest logical
    /// lines, up to its cap) with the range covered by the preceding backfill.
    /// Its largest logical suffix is matched against the cached physical-line
    /// suffix, allowing several wrapped grid rows to equal one logical line.
    /// The read's remaining prefix is older content and stays byte-exact in a
    /// segment above the live screen. With no proven boundary, the read is
    /// likewise placed above the live run with explicit gaps rather than
    /// displacing the live screen or pretending continuity.
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
        if let overlap = Self.largestReflowedOverlap(
            unwrappedSuffixOf: read, cachedSuffixOf: anchor)
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

    /// A conservative repaint heuristic. Both screens must have the same
    /// shape and at least five lines, and at least 80% of corresponding lines
    /// must be byte-identical. Even on large screens, no more than two lines
    /// may differ. This catches spinner/status repaint ticks without folding
    /// genuinely distinct screens into one generation.
    static func isNearDuplicate(_ first: [String], _ second: [String]) -> Bool {
        guard
            first.count == second.count,
            first.count >= minimumNearDuplicateLineCount
        else { return false }

        let allowedDifferences = min(
            maximumNearDuplicateLineDifferences,
            first.count / minimumNearDuplicateLineCount)
        var differences = 0
        for (firstLine, secondLine) in zip(first, second)
        where !firstLine.utf8.elementsEqual(secondLine.utf8) {
            differences += 1
            if differences > allowedDifferences {
                return false
            }
        }
        return true
    }

    private static func areByteIdentical<First: Collection, Second: Collection>(
        _ first: First,
        _ second: Second
    ) -> Bool where First.Element == String, Second.Element == String {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy { firstLine, secondLine in
            firstLine.utf8.elementsEqual(secondLine.utf8)
        }
    }

    /// `nil` only when the cache is empty; the invariant keeps a trailing
    /// `.lines` run otherwise, even if it holds zero lines.
    private var newestLinesIfPresent: [String]? {
        guard case .lines(let lines) = segments.last else { return nil }
        return lines
    }

    private var contiguousTailRange: Range<Int> {
        var lowerBound = segments.count - 1
        while lowerBound > segments.startIndex {
            guard case .lines = segments[lowerBound - 1] else { break }
            lowerBound -= 1
        }
        return lowerBound..<segments.endIndex
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
        var result: [String] = []
        for index in range {
            guard case .lines(let lines) = segments[index] else { continue }
            result.append(contentsOf: lines)
        }
        return result
    }

    /// Keeps overlap-proven output outside the replace-generation cap. The
    /// live segment stays an exact screen, while rows that demonstrably
    /// scrolled off are folded into the contiguous protected history above.
    private mutating func installExtendedLiveScreen(
        _ read: [String],
        preserving scrolledOff: [String]
    ) {
        let liveIndex = segments.count - 1
        segments[liveIndex] = .lines(read)
        if !scrolledOff.isEmpty {
            if liveIndex > segments.startIndex,
                case .lines(let provenHistory) = segments[liveIndex - 1]
            {
                segments[liveIndex - 1] = .lines(provenHistory + scrolledOff)
            } else {
                segments.insert(.lines(scrolledOff), at: liveIndex)
            }
        }
        backfillRange = contiguousTailRange
    }

    private mutating func trimSealedLiveGenerations() {
        while sealedLiveGenerationIndices.count > Self.maximumSealedLiveGenerations {
            let sealedIndex = sealedLiveGenerationIndices.removeFirst()
            guard
                sealedIndex >= segments.startIndex,
                sealedIndex < segments.endIndex,
                case .lines = segments[sealedIndex]
            else { continue }

            // Later generations were introduced by a gap immediately above
            // them, so discard that gap with the sealed screen. The original
            // live screen has no preceding gap; removing it leaves its
            // following gap as the honest boundary between protected history
            // and the oldest retained generation.
            let removalLowerBound =
                sealedIndex > segments.startIndex && segments[sealedIndex - 1] == .gap
                ? sealedIndex - 1 : sealedIndex
            let removedRange = removalLowerBound..<(sealedIndex + 1)
            segments.removeSubrange(removedRange)
            sealedLiveGenerationIndices = sealedLiveGenerationIndices.map { index in
                index >= removedRange.upperBound ? index - removedRange.count : index
            }
            if let range = backfillRange {
                if range.lowerBound >= removedRange.upperBound {
                    let offset = removedRange.count
                    backfillRange = (range.lowerBound - offset)..<(range.upperBound - offset)
                } else if range.overlaps(removedRange) {
                    backfillRange = nil
                }
            }
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
            if Self.areByteIdentical(first.suffix(candidate), second.prefix(candidate)) {
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
            if Self.areByteIdentical(first.suffix(candidate), second.suffix(candidate)) {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }

    /// Returns the number of logical `recent_unwrapped` lines proven to be
    /// the same boundary as a suffix of the cached grid. Each logical line
    /// consumes one or more cached rows, so differing terminal widths do not
    /// manufacture gaps. Trailing spaces and tabs are ignored only for this
    /// comparison because a visible grid may pad its final row; stored and
    /// rendered strings remain byte-exact.
    ///
    /// A match is accepted when it covers either whole boundary, or when at
    /// least `minimumOverlap` logical lines agree. This preserves the former
    /// small-screen behavior without letting one coincidental prompt line
    /// stitch two otherwise unrelated captures.
    private static func largestReflowedOverlap(
        unwrappedSuffixOf read: [String],
        cachedSuffixOf cached: [String]
    ) -> Int? {
        guard !read.isEmpty, !cached.isEmpty else { return nil }

        let logicalLines = read.map(ReconciliationLine.init)
        let cachedRows = cached.map(ReconciliationLine.init)
        var cachedEnd = cachedRows.endIndex
        var overlap = 0

        for logicalLine in logicalLines.reversed() {
            guard
                let start = matchingStart(
                    of: logicalLine,
                    in: cachedRows,
                    endingAt: cachedEnd)
            else { break }
            overlap += 1
            cachedEnd = start
        }

        guard overlap > 0 else { return nil }
        let coversWholeRead = overlap == read.count
        let coversWholeCache = cachedEnd == cachedRows.startIndex
        guard overlap >= minimumOverlap || coversWholeRead || coversWholeCache else {
            return nil
        }
        return overlap
    }

    private struct ReconciliationLine {
        let raw: [UInt8]
        let trimmed: [UInt8]

        init(_ line: String) {
            raw = Array(line.utf8)
            var trimmed = raw
            while let last = trimmed.last, last == 0x20 || last == 0x09 {
                trimmed.removeLast()
            }
            self.trimmed = trimmed
        }
    }

    /// Finds the nearest cached row boundary whose concatenated bytes equal one
    /// unwrapped logical line. Searching backward makes the required suffix
    /// boundary explicit and keeps older unrelated rows out of the proof.
    private static func matchingStart(
        of logicalLine: ReconciliationLine,
        in cachedRows: [ReconciliationLine],
        endingAt cachedEnd: Int
    ) -> Int? {
        guard cachedEnd > cachedRows.startIndex else { return nil }
        var combinedRaw: [UInt8] = []
        var combinedTrimmed: [UInt8] = []
        var start = cachedEnd

        while start > cachedRows.startIndex {
            start -= 1
            combinedRaw.insert(contentsOf: cachedRows[start].raw, at: combinedRaw.startIndex)
            combinedTrimmed.insert(
                contentsOf: cachedRows[start].trimmed,
                at: combinedTrimmed.startIndex)
            let rawCanMatch = combinedRaw.count <= logicalLine.raw.count
            let trimmedCanMatch = combinedTrimmed.count <= logicalLine.trimmed.count
            guard rawCanMatch || trimmedCanMatch else { break }
            if (rawCanMatch && combinedRaw.elementsEqual(logicalLine.raw))
                || (trimmedCanMatch
                    && combinedTrimmed.elementsEqual(logicalLine.trimmed))
            {
                // Empty padded rows can yield many equivalent partitions;
                // the nearest boundary preserves the most evidence for the
                // preceding logical line and is the conservative choice.
                return start
            }
        }
        return nil
    }

    /// The rightmost position at which `needle` appears in `haystack` as a
    /// contiguous run, if any. Rightmost because the newest run sits at the
    /// end of a `recent_unwrapped` read when content is stable; an earlier
    /// duplicate of the same lines is history, not the tail.
    private static func containment(of needle: [String], in haystack: [String]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var start = haystack.count - needle.count
        while start >= 0 {
            if Self.areByteIdentical(haystack[start..<(start + needle.count)], needle) {
                return start
            }
            start -= 1
        }
        return nil
    }
}
