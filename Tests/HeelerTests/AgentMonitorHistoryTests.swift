import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent Monitor history")
struct AgentMonitorHistoryTests {
    @Test func splitLinesDropsOnlyTheTrailingNewlineFragment() {
        #expect(AgentMonitorHistory.splitLines("") == [])
        #expect(AgentMonitorHistory.splitLines("a") == ["a"])
        #expect(AgentMonitorHistory.splitLines("a\n") == ["a"])
        #expect(AgentMonitorHistory.splitLines("a\n\nb") == ["a", "", "b"])
        #expect(AgentMonitorHistory.splitLines("\n") == [""])
    }

    @Test func visibleReadsExtendReplaceAndSettle() {
        var history = AgentMonitorHistory()
        #expect(history.applyVisible("l1\nl2\nl3\nl4\nl5") == .replaced)
        #expect(history.applyVisible("l1\nl2\nl3\nl4\nl5") == .unchanged)

        // Scrolled by one: the four-line overlap extends the tail.
        #expect(history.applyVisible("l2\nl3\nl4\nl5\nl6") == .extended)
        #expect(history.newestLines == ["l1", "l2", "l3", "l4", "l5", "l6"])

        // Repaint: no overlap, the tail is replaced.
        #expect(history.applyVisible("n1\nn2\nn3\nn4\nn5") == .replaced)
        #expect(history.newestLines == ["n1", "n2", "n3", "n4", "n5"])

        // A cleared screen replaces; re-reading it changes nothing.
        #expect(history.applyVisible("") == .replaced)
        #expect(history.newestLines == [])
        #expect(history.applyVisible("") == .unchanged)
    }

    @Test func backfillStitchesBySharedSuffix() {
        var history = AgentMonitorHistory()
        history.applyVisible("s1\ns2\ns3\ns4")

        let first = history.stitchBackfill("o1\no2\ns1\ns2\ns3\ns4")
        #expect(first == .init(newLines: 2, insertedGap: false))
        #expect(history.newestLines == ["o1", "o2", "s1", "s2", "s3", "s4"])

        // The same window again: fully captured, nothing new.
        let repeatRead = history.stitchBackfill("o1\no2\ns1\ns2\ns3\ns4")
        #expect(repeatRead == .init(newLines: 0, insertedGap: false))

        // A window contained inside a deeper cache adds nothing either.
        let contained = history.stitchBackfill("s1\ns2\ns3\ns4")
        #expect(contained == .init(newLines: 0, insertedGap: false))
        #expect(history.newestLines == ["o1", "o2", "s1", "s2", "s3", "s4"])
    }

    @Test func backfillSupersedesTheTailWhenTheWindowContainsIt() {
        var history = AgentMonitorHistory()
        history.applyVisible("s1\ns2\ns3\ns4")

        // Output raced the read: the tail sits mid-window, not at its end.
        // The read is the better truth for the whole region.
        let outcome = history.stitchBackfill("o1\ns1\ns2\ns3\ns4\nn1\nn2")
        #expect(outcome == .init(newLines: 3, insertedGap: false))
        #expect(history.newestLines == ["o1", "s1", "s2", "s3", "s4", "n1", "n2"])
    }

    @Test func backfillWithoutSharedContentRecordsAGap() {
        var history = AgentMonitorHistory()
        history.applyVisible("stale a\nstale b\nstale c")

        let outcome = history.stitchBackfill("fresh 1\nfresh 2\nfresh 3")
        #expect(outcome == .init(newLines: 3, insertedGap: true))
        #expect(
            history.segments == [
                .lines(["stale a", "stale b", "stale c"]),
                .gap,
                .lines(["fresh 1", "fresh 2", "fresh 3"]),
            ])

        // The next read stitches onto the new tail, below the gap.
        let second = history.stitchBackfill("older\nfresh 1\nfresh 2\nfresh 3")
        #expect(second == .init(newLines: 1, insertedGap: false))
        #expect(
            history.segments == [
                .lines(["stale a", "stale b", "stale c"]),
                .gap,
                .lines(["older", "fresh 1", "fresh 2", "fresh 3"]),
            ])
    }

    @Test func tinyScreensMatchOnTheirWholeLength() {
        var history = AgentMonitorHistory()
        history.applyVisible("only line")

        // Below the minimum overlap the floor drops to the screen's length:
        // a whole-screen match is correct by construction.
        let outcome = history.stitchBackfill("older 1\nolder 2\nonly line")
        #expect(outcome == .init(newLines: 2, insertedGap: false))
        #expect(history.newestLines == ["older 1", "older 2", "only line"])
    }

    @Test func emptyFirstReadStillInstalls() {
        var history = AgentMonitorHistory()
        // The first install must report a change even for empty content, or
        // the store never renders and the view loads forever.
        #expect(history.applyVisible("") == .replaced)
        #expect(history.newestLines == [])
        #expect(history.applyVisible("") == .unchanged)
    }

    @Test func coincidentalShortOverlapsDoNotStitch() {
        var history = AgentMonitorHistory()
        history.applyVisible("a\nb\nc\nd")

        // Two shared lines at the end are below the minimum overlap: the
        // read is treated as unrelated content, never stitched history.
        let short = history.stitchBackfill("x\ny\nc\nd")
        #expect(short.insertedGap)
        #expect(
            history.segments == [
                .lines(["a", "b", "c", "d"]),
                .gap,
                .lines(["x", "y", "c", "d"]),
            ])

        // The live tail holds the same line: a two-line overlap is a
        // repaint, not an extension.
        var visible = AgentMonitorHistory()
        visible.applyVisible("a\nb\nc\nd")
        #expect(visible.applyVisible("c\nd\ne") == .replaced)
        #expect(visible.newestLines == ["c", "d", "e"])
    }

    @Test func emptyBackfillAddsNothing() {
        var history = AgentMonitorHistory()
        history.applyVisible("s1\ns2\ns3")

        #expect(history.stitchBackfill("") == .init(newLines: 0, insertedGap: false))
        #expect(history.newestLines == ["s1", "s2", "s3"])
    }
}
