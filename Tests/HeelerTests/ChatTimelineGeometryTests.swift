import CoreGraphics
import Testing

@testable import Heeler

@Suite("Chat timeline geometry")
struct ChatTimelineGeometryTests {
    @Test("Rows stack from prefix sums")
    func prefixSums() {
        let geometry = ChatTimelineGeometry(heights: [10, 20, 30])
        #expect(geometry.count == 3)
        #expect((0...3).map(geometry.minY(at:)) == [0, 10, 30, 60])
        #expect((0..<3).map(geometry.maxY(at:)) == [10, 30, 60])
        #expect(geometry.contentHeight == 60)
        #expect(geometry.topPadding == 0)
        #expect(geometry.totalHeight == 60)
    }

    @Test("Short content rests on the bottom of the visible area")
    func topPadding() {
        var geometry = ChatTimelineGeometry(heights: [10, 20, 30], visibleHeight: 100)
        #expect(geometry.topPadding == 40)
        #expect(geometry.totalHeight == 100)
        #expect(geometry.minY(at: 0) == 40)
        #expect(geometry.maxY(at: 2) == 100)

        geometry.visibleHeight = 50
        #expect(geometry.topPadding == 0)
        #expect(geometry.totalHeight == 60)
        #expect(geometry.minY(at: 0) == 0)
    }

    @Test("An empty timeline is all padding and has nothing to find")
    func empty() {
        let geometry = ChatTimelineGeometry(visibleHeight: 300)
        #expect(geometry.count == 0)
        #expect(geometry.contentHeight == 0)
        #expect(geometry.topPadding == 300)
        #expect(geometry.totalHeight == 300)
        #expect(geometry.index(at: 0) == nil)
        #expect(geometry.index(at: 300) == nil)
        #expect(geometry.anchor(visibleTop: 0) == nil)
        #expect(geometry.indices(from: 0, to: 300).isEmpty)
    }

    @Test("Positions outside the rows clamp instead of trapping")
    func clampedPositions() {
        let geometry = ChatTimelineGeometry(heights: [10, 20], visibleHeight: 100)
        #expect(geometry.minY(at: -1) == 70)
        #expect(geometry.minY(at: 2) == 100)
        #expect(geometry.minY(at: 9) == 100)
        #expect(geometry.maxY(at: 9) == 100)
        #expect(geometry.height(at: 2) == 0)
    }

    @Test("A y on a row boundary belongs to the row below it")
    func searchBoundaries() {
        let geometry = ChatTimelineGeometry(heights: [10, 20, 30])
        #expect(geometry.index(at: -0.5) == nil)
        #expect(geometry.index(at: 0) == 0)
        #expect(geometry.index(at: 9.75) == 0)
        #expect(geometry.index(at: 10) == 1)
        #expect(geometry.index(at: 29.75) == 1)
        #expect(geometry.index(at: 30) == 2)
        #expect(geometry.index(at: 59.75) == 2)
        #expect(geometry.index(at: 60) == nil)

        let padded = ChatTimelineGeometry(heights: [10, 20, 30], visibleHeight: 100)
        #expect(padded.index(at: 39.75) == nil)
        #expect(padded.index(at: 40) == 0)
        #expect(padded.index(at: 99.75) == 2)
        #expect(padded.index(at: 100) == nil)
    }

    @Test("Empty rows contain no y and never anchor")
    func emptyRows() {
        let geometry = ChatTimelineGeometry(heights: [10, 0, 0, 20])
        #expect(geometry.index(at: 10) == 3)
        #expect(geometry.anchor(visibleTop: 10)?.index == 3)
        #expect(geometry.anchor(visibleTop: 9.5)?.index == 0)
        #expect(geometry.indices(from: 0, to: 10) == 0..<1)
    }

    @Test("A band query returns the rows it overlaps, not the ones it touches")
    func bandQuery() {
        let geometry = ChatTimelineGeometry(heights: Array(repeating: 10, count: 10))
        #expect(geometry.indices(from: 15, to: 35) == 1..<4)
        #expect(geometry.indices(from: 10, to: 20) == 1..<2)
        #expect(geometry.indices(from: -100, to: 1_000) == 0..<10)
        #expect(geometry.indices(from: 200, to: 300).isEmpty)
        #expect(geometry.indices(from: 50, to: 20).isEmpty)
    }

    @Test("Searches agree with a linear scan, including fractional heights")
    func searchesMatchLinearScan() {
        var generator = SplitMix64(seed: 0x5EED)
        let choices: [CGFloat] = [0, 1.0 / 3, 36, 44, 52.5, 72, 120, 333 + 2.0 / 3, 1_000]
        let heights = (0..<1_000).map { _ in choices[Int(generator.next() % UInt64(choices.count))] }
        let geometry = ChatTimelineGeometry(heights: heights, visibleHeight: 800)

        var ys: [CGFloat] = [-50, 0, geometry.totalHeight, geometry.totalHeight + 50]
        for row in stride(from: 0, to: geometry.count, by: 7) {
            for edge in [geometry.minY(at: row), geometry.maxY(at: row)] {
                ys += [edge.nextDown, edge, edge.nextUp]
            }
        }
        for _ in 0..<300 {
            ys.append(CGFloat(generator.next() % 1_000_000) / 1_000_000 * geometry.totalHeight)
        }

        for y in ys {
            let containing = (0..<geometry.count).first {
                geometry.minY(at: $0) <= y && y < geometry.maxY(at: $0)
            }
            #expect(geometry.index(at: y) == containing, "index at \(y)")
            let anchor = (0..<geometry.count).first { geometry.maxY(at: $0) > y }
            #expect(geometry.anchor(visibleTop: y)?.index == anchor, "anchor at \(y)")
            let band = (0..<geometry.count).filter {
                geometry.maxY(at: $0) > y && geometry.minY(at: $0) < y + 400
            }
            #expect(Array(geometry.indices(from: y, to: y + 400)) == band, "band at \(y)")
        }
    }

    @Test("Incremental height changes leave the same sums as a fresh build")
    func incrementalEqualsFresh() {
        var generator = SplitMix64(seed: 42)
        var geometry = ChatTimelineGeometry(
            heights: Array(repeating: 120, count: 500), visibleHeight: 700)
        for _ in 0..<2_000 {
            let index = Int(generator.next() % 500)
            let height = CGFloat(generator.next() % 3_000) / 3
            geometry.setHeight(height, at: index)
        }
        #expect(geometry == ChatTimelineGeometry(heights: geometry.heights, visibleHeight: 700))
    }

    @Test("setHeight returns the change in total height")
    func setHeightDelta() {
        var geometry = ChatTimelineGeometry(heights: [10, 20, 30])
        #expect(geometry.setHeight(25, at: 1) == 5)
        #expect(geometry.heights == [10, 25, 30])
        #expect(geometry.minY(at: 2) == 35)
        #expect(geometry.totalHeight == 65)
        #expect(geometry.setHeight(25, at: 1) == 0)
        #expect(geometry.setHeight(5, at: 2) == -25)
        #expect(geometry.totalHeight == 40)
    }

    @Test("Top padding absorbs growth until the rows fill the visible area")
    func setHeightWithPadding() {
        var geometry = ChatTimelineGeometry(heights: [10, 20, 30], visibleHeight: 100)
        #expect(geometry.setHeight(40, at: 1) == 0)
        #expect(geometry.topPadding == 20)
        #expect(geometry.setHeight(70, at: 1) == 10)
        #expect(geometry.topPadding == 0)
        #expect(geometry.totalHeight == 110)
        #expect(geometry.setHeight(10, at: 1) == -10)
        #expect(geometry.topPadding == 50)
    }

    @Test("Negative, infinite and NaN heights count as empty rows; bad indices change nothing")
    func sanitizing() {
        var geometry = ChatTimelineGeometry(heights: [10, -5, .infinity, .nan])
        #expect(geometry.heights == [10, 0, 0, 0])
        #expect(geometry.totalHeight == 10)
        #expect(geometry.setHeight(-1, at: 0) == -10)
        #expect(geometry.setHeight(50, at: 4) == 0)
        #expect(geometry.setHeight(50, at: -1) == 0)
        #expect(geometry.heights == [0, 0, 0, 0])
        geometry.setHeights([1, .nan, 2])
        #expect(geometry.heights == [1, 0, 2])
        #expect(geometry.totalHeight == 3)
    }

    @Test("A change above the anchor moves the offset by the same amount")
    func changeAboveAnchor() {
        var geometry = ChatTimelineGeometry(heights: Array(repeating: 100, count: 20), visibleHeight: 600)
        let anchor = geometry.anchor(visibleTop: 1_050)
        #expect(anchor == ChatTimelineAnchor(index: 10, minY: 1_000))
        geometry.setHeight(150, at: 3)
        #expect(geometry.offsetAdjustment(restoring: anchor) == 50)
        geometry.setHeight(40, at: 9)
        #expect(geometry.offsetAdjustment(restoring: anchor) == -10)
    }

    @Test("A change to the anchor row or below it needs no adjustment")
    func changeAtOrBelowAnchor() {
        var geometry = ChatTimelineGeometry(heights: Array(repeating: 100, count: 20), visibleHeight: 600)
        let anchor = geometry.anchor(visibleTop: 1_050)
        geometry.setHeight(300, at: 10)
        #expect(geometry.offsetAdjustment(restoring: anchor) == 0)
        geometry.setHeight(10, at: 15)
        geometry.setHeight(400, at: 19)
        #expect(geometry.offsetAdjustment(restoring: anchor) == 0)
    }

    @Test("A visible top on a row boundary anchors the row below it")
    func anchorOnBoundary() {
        var geometry = ChatTimelineGeometry(heights: Array(repeating: 100, count: 20), visibleHeight: 600)
        let anchor = geometry.anchor(visibleTop: 1_000)
        #expect(anchor?.index == 10)
        geometry.setHeight(130, at: 9)
        #expect(geometry.offsetAdjustment(restoring: anchor) == 30)
    }

    @Test("Top padding changes count as changes above the anchor")
    func paddingIsAboveAnchor() {
        var geometry = ChatTimelineGeometry(heights: [100, 100], visibleHeight: 500)
        let anchor = geometry.anchor(visibleTop: 0)
        #expect(anchor == ChatTimelineAnchor(index: 0, minY: 300))

        geometry.setHeight(200, at: 1)
        #expect(geometry.offsetAdjustment(restoring: anchor) == -100)
        geometry.setHeight(600, at: 1)
        #expect(geometry.topPadding == 0)
        #expect(geometry.offsetAdjustment(restoring: anchor) == -300)
    }

    @Test("A smaller visible area lifts short content by the padding it loses")
    func visibleHeightChange() {
        var geometry = ChatTimelineGeometry(heights: [100, 100], visibleHeight: 500)
        let anchor = geometry.anchor(visibleTop: 0)
        geometry.visibleHeight = 400
        #expect(geometry.offsetAdjustment(restoring: anchor) == -100)

        var long = ChatTimelineGeometry(heights: Array(repeating: 100, count: 20), visibleHeight: 600)
        let longAnchor = long.anchor(visibleTop: 1_050)
        long.visibleHeight = 300
        #expect(long.offsetAdjustment(restoring: longAnchor) == 0)
    }

    @Test("No anchor, or one past the rows, needs no adjustment")
    func missingAnchor() {
        var geometry = ChatTimelineGeometry(heights: [100, 100])
        #expect(geometry.anchor(visibleTop: 200) == nil)
        #expect(geometry.offsetAdjustment(restoring: nil) == 0)
        let anchor = geometry.anchor(visibleTop: 150)
        geometry.setHeights([100])
        #expect(geometry.offsetAdjustment(restoring: anchor) == 0)
    }

    struct CacheCase: Sendable, CustomTestStringConvertible {
        let name: String
        let width: CGFloat
        let category: String
        let revision: Int
        let isExact: Bool
        var testDescription: String { name }
    }

    static let cached = ChatMeasuredHeight(
        height: 88, width: 390, contentSizeCategory: "UICTContentSizeCategoryL", revision: 3)

    static let cacheCases: [CacheCase] = [
        CacheCase(name: "all match", width: 390, category: "UICTContentSizeCategoryL", revision: 3, isExact: true),
        CacheCase(name: "another width", width: 834, category: "UICTContentSizeCategoryL", revision: 3, isExact: false),
        CacheCase(name: "another text size", width: 390, category: "UICTContentSizeCategoryXL", revision: 3, isExact: false),
        CacheCase(name: "another revision", width: 390, category: "UICTContentSizeCategoryL", revision: 4, isExact: false),
    ]

    @Test("A cached height is exact only when width, text size and revision all match", arguments: cacheCases)
    func cacheExactness(_ cacheCase: CacheCase) {
        #expect(
            Self.cached.isExact(
                width: cacheCase.width, contentSizeCategory: cacheCase.category,
                revision: cacheCase.revision) == cacheCase.isExact)
        let estimate = ChatHeightEstimate(
            cached: Self.cached, seed: .assistant, width: cacheCase.width,
            contentSizeCategory: cacheCase.category, revision: cacheCase.revision)
        #expect(estimate == (cacheCase.isExact ? .exact(88) : .stale(88)))
        #expect(estimate.height == 88)
        #expect(estimate.isExact == cacheCase.isExact)
    }

    @Test("An unmeasured row starts at its family's seed")
    func seedEstimate() {
        for seed in ChatRowSeed.allCases {
            let estimate = ChatHeightEstimate(
                cached: nil, seed: seed, width: 390,
                contentSizeCategory: "UICTContentSizeCategoryL", revision: 0)
            #expect(estimate == .seed(seed.height))
            #expect(!estimate.isExact)
            #expect(seed.height > 0)
        }
    }
}

/// A small deterministic generator, so a failing search case reproduces.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
