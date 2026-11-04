import CoreGraphics

/// The Chat timeline's vertical layout as plain numbers: one height per row,
/// in display order.
///
/// The collection view layout keeps one of these and asks it everything that
/// depends on row heights, so the arithmetic is testable without UIKit. Rows
/// stack with no gaps between them; spacing belongs to the rows. When the
/// rows are shorter than the visible area, `topPadding` pushes them down so a
/// short conversation rests on the composer instead of hanging under the
/// navigation bar.
///
/// Positions are content coordinates and include `topPadding`. Prefix sums
/// answer every position in constant time and every search in logarithmic
/// time; a new height rebuilds only the sums below its row.
struct ChatTimelineGeometry: Sendable, Equatable {
    /// Row heights in display order. Never negative.
    private(set) var heights: [CGFloat]
    /// `offsets[i]` is the combined height of the rows above row `i`. It has
    /// one more entry than `heights`, so its last entry is the rows' total.
    private var offsets: [CGFloat]
    /// The height rows can show in: the viewport less its top and bottom
    /// insets. It decides `topPadding` and nothing else.
    var visibleHeight: CGFloat
    /// A reader-opened row can retain the blank space above a short
    /// conversation, so expanding it adds content below instead of lifting it.
    var minimumTopPadding: CGFloat = 0

    init(heights: [CGFloat] = [], visibleHeight: CGFloat = 0) {
        self.heights = heights.map(Self.sanitized)
        offsets = []
        self.visibleHeight = visibleHeight
        rebuildOffsets(from: 0)
    }

    var count: Int { heights.count }

    /// The rows' combined height, without `topPadding`.
    var contentHeight: CGFloat { offsets.last ?? 0 }

    /// Space above the first row that rests short content at the bottom of
    /// the visible area. Zero once the rows fill it.
    var topPadding: CGFloat { max(minimumTopPadding, visibleHeight - contentHeight, 0) }

    /// The layout's content height: the rows plus `topPadding`, so never
    /// shorter than the visible area.
    var totalHeight: CGFloat { topPadding + contentHeight }

    /// Row `index`'s height, or zero outside the rows.
    func height(at index: Int) -> CGFloat {
        heights.indices.contains(index) ? heights[index] : 0
    }

    /// The top edge of row `index`. `count` is valid and gives the bottom of
    /// the last row, where an appended row would start; indices outside
    /// `0...count` are clamped to it.
    func minY(at index: Int) -> CGFloat {
        topPadding + offsets[min(max(index, 0), count)]
    }

    /// The bottom edge of row `index`, clamped like `minY(at:)`. It reads the
    /// same sums the searches compare, so a row found below a y always has a
    /// `maxY` past it, even for heights like 1/3 pt that do not add exactly.
    func maxY(at index: Int) -> CGFloat {
        guard heights.indices.contains(index) else { return minY(at: index) }
        return topPadding + offsets[index + 1]
    }

    /// The row whose span `minY ..< maxY` contains `y`, or nil when `y` lies
    /// in the top padding, past the last row, or on an empty row's edge.
    func index(at y: CGFloat) -> Int? {
        let index = firstRow(endingBelow: y)
        guard index < count, minY(at: index) <= y else { return nil }
        return index
    }

    /// The rows that overlap the band from `minY` to `maxY`, for the layout's
    /// rect queries. A row that only touches the band's edge is not in it.
    func indices(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        let lower = firstRow(endingBelow: minY)
        let upper = firstRow(startingAtOrBelow: maxY)
        return lower..<max(lower, upper)
    }

    /// What the reader is looking at when the visible area starts at
    /// `visibleTop`: the first row whose bottom edge lies below it, so a row
    /// the viewport has scrolled fully past never anchors. Nil when no row
    /// reaches that far down.
    func anchor(visibleTop: CGFloat) -> ChatTimelineAnchor? {
        let index = firstRow(endingBelow: visibleTop)
        guard index < count else { return nil }
        return ChatTimelineAnchor(index: index, minY: minY(at: index))
    }

    /// How far the content offset must move for `anchor` to stay where it
    /// was on screen, after any height or `visibleHeight` changes made since
    /// it was captured.
    ///
    /// Changes above the anchor row, and changes to `topPadding`, move the
    /// row and are matched exactly; changes to the anchor row itself or below
    /// it leave its top edge in place and need nothing. A following timeline
    /// does not use this: it pins to the end instead.
    func offsetAdjustment(restoring anchor: ChatTimelineAnchor?) -> CGFloat {
        guard let anchor, anchor.index < count else { return 0 }
        return minY(at: anchor.index) - anchor.minY
    }

    /// Replaces every row height, as when the rows themselves change.
    mutating func setHeights(_ heights: [CGFloat]) {
        self.heights = heights.map(Self.sanitized)
        rebuildOffsets(from: 0)
    }

    /// Records row `index`'s new height and returns how much `totalHeight`
    /// changed, which is the layout's content size adjustment. While
    /// `topPadding` absorbs the change, that is less than the row's own
    /// change, or nothing. An index outside the rows changes nothing.
    @discardableResult
    mutating func setHeight(_ height: CGFloat, at index: Int) -> CGFloat {
        guard heights.indices.contains(index) else { return 0 }
        let height = Self.sanitized(height)
        guard height != heights[index] else { return 0 }
        let previousTotal = totalHeight
        heights[index] = height
        rebuildOffsets(from: index)
        return totalHeight - previousTotal
    }

    /// Rebuilds the sums below row `index` from the heights rather than
    /// shifting them by the difference, so repeated changes never accumulate
    /// rounding error.
    private mutating func rebuildOffsets(from index: Int) {
        var start = index
        if offsets.count != heights.count + 1 {
            offsets = Array(repeating: 0, count: heights.count + 1)
            start = 0
        }
        var running = offsets[start]
        for row in start..<heights.count {
            running += heights[row]
            offsets[row + 1] = running
        }
    }

    /// The first row whose bottom edge lies below `y`, or `count`.
    private func firstRow(endingBelow y: CGFloat) -> Int {
        let padding = topPadding
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if padding + offsets[middle + 1] > y {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// The first row whose top edge lies at or below `y`, or `count`.
    private func firstRow(startingAtOrBelow y: CGFloat) -> Int {
        let padding = topPadding
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if padding + offsets[middle] >= y {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// Heights come from Auto Layout; anything negative or not finite would
    /// corrupt every position below it, so it counts as an empty row.
    private static func sanitized(_ height: CGFloat) -> CGFloat {
        height.isFinite ? max(0, height) : 0
    }
}

/// The row a reader is looking at and where its top edge was, captured
/// before a change so `ChatTimelineGeometry.offsetAdjustment(restoring:)`
/// can hold it still.
struct ChatTimelineAnchor: Sendable, Equatable {
    let index: Int
    let minY: CGFloat
}

/// One entry of the timeline's height cache: a row's height as measured at
/// one width, text size and content revision.
struct ChatMeasuredHeight: Sendable, Equatable {
    var height: CGFloat
    var width: CGFloat
    /// `UIContentSizeCategory.rawValue` at measurement time.
    var contentSizeCategory: String
    var revision: Int

    init(height: CGFloat, width: CGFloat, contentSizeCategory: String, revision: Int) {
        self.height = height
        self.width = width
        self.contentSizeCategory = contentSizeCategory
        self.revision = revision
    }

    /// Whether the measurement still describes the row: the same width, text
    /// size and content. Anything else can wrap differently.
    func isExact(width: CGFloat, contentSizeCategory: String, revision: Int) -> Bool {
        self.width == width && self.contentSizeCategory == contentSizeCategory
            && self.revision == revision
    }
}

/// The height the layout gives a row until its cell measures it.
enum ChatHeightEstimate: Sendable, Equatable {
    /// Measured under the current conditions: this is the row's height.
    case exact(CGFloat)
    /// Measured at another width, text size or revision. Most rows change
    /// little between those, so a stale height still lands far closer than
    /// a seed and keeps scroll positions steadier until the cell re-measures.
    case stale(CGFloat)
    /// Never measured: the row family's first guess.
    case seed(CGFloat)

    init(
        cached: ChatMeasuredHeight?, seed: ChatRowSeed,
        width: CGFloat, contentSizeCategory: String, revision: Int
    ) {
        guard let cached else {
            self = .seed(seed.height)
            return
        }
        self = cached.isExact(width: width, contentSizeCategory: contentSizeCategory, revision: revision)
            ? .exact(cached.height) : .stale(cached.height)
    }

    var height: CGFloat {
        switch self {
        case .exact(let height), .stale(let height), .seed(let height): height
        }
    }

    var isExact: Bool {
        if case .exact = self { return true }
        return false
    }
}

/// Row families with their own first guess at a height. A seed only places
/// a row until it is measured once; afterwards even a stale measurement
/// wins. The values are rough guesses at the default text size: a better
/// guess only means a smaller correction when the row first measures.
enum ChatRowSeed: Sendable, CaseIterable {
    case user
    case assistant
    case tool
    case reasoning
    case system
    case pending
    case olderStatus

    var height: CGFloat {
        switch self {
        case .user: 72
        case .assistant: 120
        case .tool: 52
        case .reasoning: 44
        case .system: 36
        case .pending: 72
        case .olderStatus: 44
        }
    }
}
