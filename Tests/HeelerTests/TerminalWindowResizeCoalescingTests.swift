import Foundation
import GhosttyTerminal
import Testing

@testable import Heeler

/// Stage Manager live resize changes a window's size on consecutive frames.
/// Every grid the Host hears is a full TUI redraw, so a burst must reach the
/// Host as one PTY resize carrying the grid the window settled on.
@Suite("Terminal window resize coalescing")
struct TerminalWindowResizeCoalescingTests {
    @Test func theFirstLayoutOnlyEstablishesTheBaseline() {
        var tracker = TerminalWindowResizeTracker()

        let first = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))
        let repeated = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))
        #expect(!first)
        #expect(!repeated)
    }

    @Test func onlyAChangedWindowSizeCounts() {
        var tracker = TerminalWindowResizeTracker()
        _ = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))

        let narrower = tracker.windowDidLayout(size: CGSize(width: 900, height: 768))
        let smaller = tracker.windowDidLayout(size: CGSize(width: 880, height: 760))
        // A layout pass for any other reason — the keyboard, a split-view
        // column — leaves the window's size alone.
        let unchanged = tracker.windowDidLayout(size: CGSize(width: 880, height: 760))
        #expect(narrower)
        #expect(smaller)
        #expect(!unchanged)
    }

    /// The first software-keyboard raise on a 13-inch iPad shrinks the terminal
    /// from 1630 to 1100 points while its surface is still 3260 pixels tall:
    /// Ghostty derives a 3x layer scale and an idle terminal never renders
    /// the frame that corrects it. Every size change, the first raise
    /// included, must schedule the follow-up passes, and those passes (which
    /// keep the size) must not schedule more.
    @Test func everyTerminalSizeChangeSchedulesOneScaleSettle() {
        var settle = TerminalSurfaceScaleSettle()
        let keyboardDown = CGSize(width: 1032, height: 1630)
        let keyboardUp = CGSize(width: 1032, height: 1100)

        // `boundsDidLayout` is mutating, so each pass runs outside `#expect`.
        let unsized = settle.boundsDidLayout(size: .zero)
        let firstLayout = settle.boundsDidLayout(size: keyboardDown)
        let repeatedLayout = settle.boundsDidLayout(size: keyboardDown)
        let firstRaise = settle.boundsDidLayout(size: keyboardUp)
        var followUps: [Bool] = []
        for _ in TerminalSurfaceScaleSettle.followUpDelays {
            followUps.append(settle.boundsDidLayout(size: keyboardUp))
        }
        let dismissal = settle.boundsDidLayout(size: keyboardDown)
        let secondRaise = settle.boundsDidLayout(size: keyboardUp)

        #expect(!unsized)
        #expect(firstLayout)
        #expect(!repeatedLayout)
        #expect(firstRaise)
        #expect(followUps == Array(repeating: false, count: followUps.count))
        #expect(dismissal)
        #expect(secondRaise)
    }

    @Test func scaleSettleFollowUpsRunInOrderAfterTheChange() {
        let delays = TerminalSurfaceScaleSettle.followUpDelays
        #expect(!delays.isEmpty)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(delays == delays.sorted())
        #expect(Set(delays).count == delays.count)
    }

    /// The choke point itself: N grid reports inside one freeze leave as one
    /// resize, the last one.
    @MainActor
    @Test func aBurstOfGridReportsForwardsOnlyTheFinalGrid() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        for step in 0..<12 {
            bridge.resize(
                InMemoryTerminalViewport(columns: UInt16(120 - step), rows: UInt16(40 - step)))
        }
        bridge.finishSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 109, rows: 29))
        #expect(reportedGrids == [TerminalGridSize(columns: 109, rows: 29)])
    }

    /// A cancelled freeze throws away the grid it held. The Host has to hear
    /// that grid anyway, and exactly once.
    @MainActor
    @Test func aSettledSizeReportsOnceAndConsumesTheEngineDuplicate() async {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)

        bridge.reportSettledSize(columns: 90, rows: 30)
        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])

        // Ghostty's own callback for the same grid, still in its pipeline.
        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(InMemoryTerminalViewport(columns: 90, rows: 30))
        }
        bridge.onViewport = nil

        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])
    }

    @MainActor
    @Test func aSettledSizeDuringAFreezeWaitsForTheThaw() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        bridge.reportSettledSize(columns: 90, rows: 30)
        #expect(reportedGrids.isEmpty)
        bridge.finishSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 90, rows: 30))
        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])
    }

    /// Keyboard notifications are process-wide. Only the window that owns
    /// the keyboard measures it; another window of the app leaves its
    /// terminal's inset alone (#157).
    @Test func onlyTheKeyWindowOwnsTheKeyboard() {
        #expect(
            TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: true, isSceneKeyWindow: true, activationState: .foregroundActive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: true, activationState: .foregroundActive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: false, activationState: .foregroundActive))
    }

    /// UIKit restores the keyboard while a scene is still foregrounding, and
    /// no window is key yet; the scene's own key window stands in there.
    @Test func aForegroundingSceneMeasuresThroughItsOwnKeyWindow() {
        #expect(
            TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: true, activationState: .foregroundInactive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: false, activationState: .foregroundInactive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: true, isSceneKeyWindow: true, activationState: .background))
    }
}
