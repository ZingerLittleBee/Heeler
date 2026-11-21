import Foundation
import Testing

@testable import Heeler

@Suite("Diff word changes")
struct DiffWordChangesTests {
    @Test func tokensAreIdentifierRunsWhitespaceRunsAndSingleCharacters() {
        let tokens = DiffWordChanges.tokens("  func discard_Cart2() {")
        #expect(tokens.map(\.text) == ["  ", "func", " ", "discard_Cart2", "(", ")", " ", "{"])
        #expect(tokens[3].range == 7..<20)
        #expect(tokens.map(\.isWhitespace) == [true, false, true, false, false, false, true, false])
    }

    @Test func aRenamedCallHighlightsOnlyTheName() throws {
        let changes = try #require(
            DiffWordChanges.ranges(old: "    func discardCart() {", new: "    func keepCartForRetry() {"))
        #expect(changes.old == [9..<20])
        #expect(changes.new == [9..<25])
    }

    @Test func adjacentChangedTokensJoinIntoOneRange() throws {
        let changes = try #require(
            DiffWordChanges.ranges(old: "foo(bar, baz)", new: "foo(qux.quux, baz)"))
        #expect(changes.old == [4..<7])
        #expect(changes.new == [4..<12])
    }

    @Test func aMostlyRewrittenLineKeepsTheWashAlone() {
        #expect(DiffWordChanges.ranges(old: "let a = 1", new: "return cart.total > 80") == nil)
    }

    @Test func aWhitespaceChangeHighlightsNothing() throws {
        let changes = try #require(DiffWordChanges.ranges(old: "a  b", new: "a b"))
        #expect(changes.old.isEmpty)
        #expect(changes.new.isEmpty)
        let hunk = Self.hunk([(.removed, "a  b"), (.added, "a b")])
        #expect(DiffWordChanges.ranges(in: hunk).isEmpty)
    }

    @Test func linesPairInOrderWithinEachBlock() {
        let hunk = Self.hunk([
            (.removed, "x = 1"), (.removed, "y = 1"), (.added, "x = 2"), (.added, "y = 2"),
            (.context, "z"),
            (.removed, "w = 1"), (.added, "w = 3"),
        ])
        let ranges = DiffWordChanges.ranges(in: hunk)
        #expect(ranges == [0: [4..<5], 1: [4..<5], 2: [4..<5], 3: [4..<5], 5: [4..<5], 6: [4..<5]])
    }

    @Test func anAdditionBeforeARemovalStartsANewBlock() {
        let hunk = Self.hunk([(.added, "x = 2"), (.removed, "x = 1"), (.context, "z")])
        #expect(DiffWordChanges.ranges(in: hunk).isEmpty)
    }

    @Test func onlyTheFirstTwentyPairsOfABlockHighlight() {
        let removed = (0..<25).map { (DiffLine.Kind.removed, "value = \($0)") }
        let added = (0..<25).map { (DiffLine.Kind.added, "value = \($0 + 100)") }
        let ranges = DiffWordChanges.ranges(in: Self.hunk(removed + added))
        #expect(ranges.count == 40)
        #expect(ranges[19] != nil)
        #expect(ranges[20] == nil)
        #expect(ranges[25 + 19] != nil)
        #expect(ranges[25 + 20] == nil)
    }

    @Test func aVeryLongLineKeepsTheWashAlone() {
        let old = Array(repeating: "a", count: 300).joined(separator: " ")
        #expect(DiffWordChanges.ranges(old: old, new: old + " b") == nil)
    }

    private static func hunk(_ lines: [(DiffLine.Kind, String)]) -> DiffHunk {
        DiffHunk(
            id: 0, oldStart: 1, oldCount: lines.count, newStart: 1, newCount: lines.count,
            section: "",
            lines: lines.enumerated().map { index, line in
                DiffLine(
                    id: index, kind: line.0, oldNumber: index + 1, newNumber: index + 1,
                    text: line.1)
            })
    }
}

@MainActor
@Suite("Diff hunk and file headers")
struct DiffHeaderModelTests {
    @Test func unchangedLinesCountFromTheFileStartAndBetweenHunks() {
        let file = Self.file(hunks: [(5, 6), (35, 12), (59, 14)])
        #expect(file.unchangedLinesBefore(hunkAt: 0) == 4)
        #expect(file.unchangedLinesBefore(hunkAt: 1) == 24)
        #expect(file.unchangedLinesBefore(hunkAt: 2) == 12)
        #expect(file.unchangedLinesBefore(hunkAt: 3) == nil)
    }

    @Test func aZeroCountSideNamesTheLineBeforeItsChange() {
        // Lines 13–16 are the first hunk; lines 17–40 stay; the insertion
        // follows line 40.
        let insertion = Self.file(hunks: [(12, 5), (40, 0)])
        #expect(insertion.unchangedLinesBefore(hunkAt: 0) == 11)
        #expect(insertion.unchangedLinesBefore(hunkAt: 1) == 24)
        // A pure insertion after line 5, then a change at line 10.
        let afterInsertion = Self.file(hunks: [(5, 0), (10, 2)])
        #expect(afterInsertion.unchangedLinesBefore(hunkAt: 0) == 5)
        #expect(afterInsertion.unchangedLinesBefore(hunkAt: 1) == 4)
    }

    @Test func noCountShowsWhereNoLinesAreHidden() {
        #expect(Self.file(hunks: [(1, 3)]).unchangedLinesBefore(hunkAt: 0) == nil)
        #expect(Self.file(hunks: [(0, 0)]).unchangedLinesBefore(hunkAt: 0) == nil)
        #expect(Self.file(hunks: [(1, 3), (4, 2)]).unchangedLinesBefore(hunkAt: 1) == nil)
    }

    @Test func aFileCountsTheLinesItsReadHolds() {
        let file = DiffFile(
            id: 0, oldPath: "a", newPath: "a", summary: nil, isBinary: false,
            hunks: [
                DiffHunk(
                    id: 0, oldStart: 1, oldCount: 2, newStart: 1, newCount: 3, section: "",
                    lines: [
                        DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
                        DiffLine(id: 1, kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
                        DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 2, text: "c"),
                        DiffLine(id: 3, kind: .added, oldNumber: nil, newNumber: 3, text: "d"),
                    ])
            ])
        #expect(file.lineCounts == .lines(added: 2, removed: 1))
    }

    @Test func indentationHangsBesideTheWrappingCode() {
        #expect(DiffCodeText.split("    let x = 1") == ("    ", "let x = 1"))
        #expect(DiffCodeText.split("\t\tfoo()") == ("\t\t", "foo()"))
        #expect(DiffCodeText.split("plain") == ("", "plain"))
        // A blank line keeps its whitespace as its code.
        #expect(DiffCodeText.split("    ") == ("", "    "))
        #expect(DiffCodeText.split("") == ("", ""))
        let deep = String(repeating: " ", count: 40) + "x"
        let split = DiffCodeText.split(deep)
        #expect(split.indent.count == DiffCodeText.maximumHangingIndent)
        #expect(split.code == String(repeating: " ", count: 8) + "x")
    }

    private static func file(hunks: [(oldStart: Int, oldCount: Int)]) -> DiffFile {
        DiffFile(
            id: 0, oldPath: "a", newPath: "a", summary: nil, isBinary: false,
            hunks: hunks.enumerated().map { index, hunk in
                DiffHunk(
                    id: index, oldStart: hunk.oldStart, oldCount: hunk.oldCount,
                    newStart: hunk.oldStart, newCount: hunk.oldCount, section: "", lines: [])
            })
    }
}
