import Foundation

/// Monitor's local scrollback cache: an ordered list of contiguous line runs
/// separated by explicit gap markers, oldest first. In-memory only.
///
/// herdr exposes no history cursor (`agent.read` takes a source and a line
/// count, capped at 1000 lines), so every reconciliation is an
/// overlap-stitch against what the cache already holds. This type is the
/// pure line algebra behind that: it performs no I/O, keeps no presentation
/// state, and is deliberately separate from `AgentMonitorStore` so the
/// stitching rules are testable on their own.
struct AgentMonitorHistory: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        /// A contiguous run of captured lines. ANSI state flows within a run;
        /// runs never sit adjacent to another run (a stitch merges them).
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

    /// Invariant: `.lines` runs are never adjacent (a stitch merges them)
    /// and a `.gap` is never first or last, so the cache always ends with
    /// the live run.
    private(set) var segments: [Segment] = []

    var isEmpty: Bool {
        segments.isEmpty
    }

    /// The lines of the newest contiguous run. The live mirror of the
    /// Agent's screen always lives here; backfill stitches onto its front
    /// because a `recent` read ends at the same newest line.
    var newestLines: [String] {
        guard case .lines(let lines) = segments.last else { return [] }
        return lines
    }

    enum VisibleOutcome: Equatable, Sendable {
        /// The read carried no new content.
        case unchanged
        /// The read's top overlapped the cache's bottom; the newly scrolled
        /// lines were appended to the newest run.
        case extended
        /// No usable overlap (an alternate-screen repaint, or a reconnect
        /// that scrolled a full screen): the newest run was replaced.
        case replaced
    }

    /// Reconciles one `visible` read with the live tail. The visible screen
    /// is a sliding window: when its top lines match the cache's bottom
    /// lines the window scrolled and only the fresh lines are appended;
    /// otherwise the screen repainted and the tail is replaced outright.
    @discardableResult
    mutating func applyVisible(_ text: String) -> VisibleOutcome {
        let read = Self.splitLines(text)
        guard let newest = newestLinesIfPresent else {
            // The first install always reports a change: even an empty
            // screen must paint, or the store never renders and the view
            // loads forever.
            segments = [.lines(read)]
            return .replaced
        }
        guard read != newest else { return .unchanged }
        // A read fully contained at the tail (a shorter screen, or the same
        // screen while the cache runs deeper) changes nothing. The empty
        // read is excluded: a cleared screen is a replacement, not a no-op.
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
        segments[segments.count - 1] = .lines(read)
        return .replaced
    }

    struct BackfillOutcome: Equatable, Sendable {
        /// Lines the read added that the cache did not already hold. Zero
        /// means the read was fully captured — the capture limit is reached.
        var newLines: Int
        /// Whether an explicit gap marker was inserted because the read
        /// could not be overlap-stitched onto the cache.
        var insertedGap: Bool
    }

    /// Reconciles one `recent` read (the server's newest lines, up to its
    /// cap) with the cache. While the Agent is idle the read's last line is
    /// the cache's newest line, so the stitch is anchored at the end of the
    /// newest run: the largest shared suffix proves the read's remaining
    /// prefix is older content, which is prepended. Failing that, the read
    /// may still contain the whole newest run (output raced the read): the
    /// read then supersedes the tail outright. With no shared content at
    /// all, the read's relation to the cache is unknowable — the old tail
    /// is sealed, a gap marker records the missing region, and the read
    /// becomes the new tail.
    @discardableResult
    mutating func stitchBackfill(_ text: String) -> BackfillOutcome {
        let read = Self.splitLines(text)
        guard !read.isEmpty else {
            return BackfillOutcome(newLines: 0, insertedGap: false)
        }
        guard let newest = newestLinesIfPresent, !newest.isEmpty else {
            if segments.isEmpty {
                segments = [.lines(read)]
            } else {
                segments[segments.count - 1] = .lines(read)
            }
            return BackfillOutcome(newLines: read.count, insertedGap: false)
        }
        let floor = min(Self.minimumOverlap, read.count, newest.count)
        if floor >= 1,
            let overlap = Self.largestOverlap(suffixOf: read, suffixOf: newest, floor: floor)
        {
            let older = read.prefix(read.count - overlap)
            guard !older.isEmpty else {
                return BackfillOutcome(newLines: 0, insertedGap: false)
            }
            segments[segments.count - 1] = .lines(older + newest)
            return BackfillOutcome(newLines: older.count, insertedGap: false)
        }
        if newest.count >= Self.minimumOverlap,
            Self.containment(of: newest, in: read) != nil
        {
            segments[segments.count - 1] = .lines(read)
            return BackfillOutcome(
                newLines: read.count - newest.count, insertedGap: false)
        }
        segments.append(.gap)
        segments.append(.lines(read))
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
