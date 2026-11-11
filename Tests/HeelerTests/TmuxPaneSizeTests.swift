import Foundation
import Testing

@testable import Heeler

/// Sizing a tmux Pane's window on an Attach's control client (ADR 0043):
/// scaling `@<window>:<columns>x<rows>` from the Pane's share, correcting from
/// what tmux made of it so the Pane never exceeds the device's grid, stopping
/// at a smaller client's ceiling, and handing the window back with
/// `ignore-size`.
@Suite("tmux pane size")
struct TmuxPaneSizeTests {
    // MARK: Geometry & commands

    @Test func geometryReadsTheWindowAndPaneDimensions() throws {
        let geometry = try #require(TmuxPaneGeometry(Data("@2 120 40 59 24".utf8)))
        #expect(geometry == TmuxPaneGeometry(windowID: "@2", windowWidth: 120, windowHeight: 40, paneWidth: 59, paneHeight: 24))
        #expect(TmuxPaneGeometry(Data("@2 120 40 59".utf8)) == nil)
        #expect(TmuxPaneGeometry(Data("2 120 40 59 24".utf8)) == nil)
        #expect(TmuxPaneGeometry(Data("@2 0 40 59 24".utf8)) == nil)
        #expect(TmuxPaneGeometry(Data("@2 120 40 -1 24".utf8)) == nil)
    }

    @Test func commandsQuoteEveryWordForControlMode() {
        #expect(
            ScriptedTmuxHost.words(of: TmuxPaneSize.readCommand(pane: "%3").line)
                == ["display-message", "-p", "-t", "%3", TmuxPaneSize.geometryFormat])
        #expect(
            ScriptedTmuxHost.words(of: TmuxPaneSize.sizeCommand(window: "@2", columns: 80, rows: 24).line)
                == ["refresh-client", "-C", "@2:80x24"])
        #expect(
            ScriptedTmuxHost.words(
                of: TmuxPaneSize.sizeCommand(window: "@2", columns: 80, rows: 24, clearingIgnoreSize: true).line)
                == ["refresh-client", "-f", "!ignore-size", "-C", "@2:80x24"])
        #expect(
            ScriptedTmuxHost.words(of: TmuxPaneSize.sizeCommand(window: "@2", columns: 1, rows: 50_000).line)
                == ["refresh-client", "-C", "@2:2x10000"])
        #expect(
            ScriptedTmuxHost.words(of: TmuxPaneSize.ignoreSizeCommand().line)
                == ["refresh-client", "-f", "ignore-size"])
        #expect(
            ScriptedTmuxHost.words(
                of: TmuxPaneSize.ignoreSizeCommand(releasing: (window: "@2", width: 60, height: 20)).line)
                == ["refresh-client", "-f", "ignore-size", "-C", "@2:60x20"])
    }

    // MARK: Scaling & correction

    @Test func aSinglePaneWindowHitsTheTargetInOneRequest() {
        var sizer = TmuxPaneSizer(targetColumns: 60, targetRows: 20)
        let first = sizer.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 80, windowHeight: 24, paneWidth: 80, paneHeight: 24))
        #expect(first == .init(columns: 60, rows: 20))
        let next = sizer.nextRequest(
            after: TmuxPaneGeometry(windowID: "@0", windowWidth: 60, windowHeight: 20, paneWidth: 60, paneHeight: 20))
        #expect(next == nil)
    }

    @Test func aSplitPaneScalesFromItsShareAndStepsBackWhenRoundingOvershoots() {
        // Left pane in a 2-pane split where tmux gives the left pane (W / 2):
        // at W=80 it is 39 (border 1, right 40); scaling 60 * 80 / 39 asks for
        // 123, where left gets 61 (> 60), so the sizer steps down until left == 60.
        var sizer = TmuxPaneSizer(targetColumns: 60, targetRows: 20)
        var request: TmuxPaneSize.Request? = sizer.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 80, windowHeight: 24, paneWidth: 39, paneHeight: 11))
        #expect(request == .init(columns: 123, rows: 44))

        var rounds = 0
        var lastGeometry: TmuxPaneGeometry?
        while let current = request {
            rounds += 1
            #expect(rounds <= TmuxPaneSizer.maxRequests)
            let paneW = (current.columns - 1 + 1) / 2
            let paneH = (current.rows - 1) / 2
            let geometry = TmuxPaneGeometry(
                windowID: "@0", windowWidth: current.columns, windowHeight: current.rows,
                paneWidth: paneW, paneHeight: paneH)
            lastGeometry = geometry
            request = sizer.nextRequest(after: geometry)
        }
        #expect(lastGeometry?.paneWidth == 60)
        #expect(lastGeometry?.paneHeight == 20)
    }

    @Test func aSplitWhoseStepJumpsPastTheTargetSettlesNoLargerThanTheDevice() {
        // A 3-way split where W=179 gives paneWidth 59 and W=180 jumps to 61:
        // 60 is unreachable, so the sizer must return to 179 (59 <= 60), never 180 (61 > 60).
        var sizer = TmuxPaneSizer(targetColumns: 60, targetRows: 24)
        var request: TmuxPaneSize.Request? = sizer.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 120, windowHeight: 24, paneWidth: 39, paneHeight: 24))
        var history: [TmuxPaneSize.Request] = []
        var finalPaneWidth = 0
        while let current = request {
            history.append(current)
            #expect(history.count <= TmuxPaneSizer.maxRequests)
            let paneW = current.columns >= 180 ? 61 + (current.columns - 180) / 3 : (current.columns - 2) / 3
            finalPaneWidth = paneW
            request = sizer.nextRequest(
                after: TmuxPaneGeometry(
                    windowID: "@0", windowWidth: current.columns, windowHeight: current.rows,
                    paneWidth: paneW, paneHeight: 24))
        }
        #expect(finalPaneWidth == 59)
        #expect(history.last == .init(columns: 179, rows: 24))
    }

    @Test func aDesktopCeilingStopsGrowingThatAxisWhileStillCorrectingTheOther() {
        // Desktop holds @0 at 100x50. Width wants 80 in a 50/50 split (163 > 100,
        // capped at 100 -> paneWidth 49); height wants 20 in a 50/50 split (asks 44,
        // gets 21 > 20, corrects height while keeping width's 163 ceiling).
        var sizer = TmuxPaneSizer(targetColumns: 80, targetRows: 20)
        var request: TmuxPaneSize.Request? = sizer.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 100, windowHeight: 50, paneWidth: 49, paneHeight: 24))
        #expect(request == .init(columns: 163, rows: 42))

        var rounds = 0
        var lastGeometry: TmuxPaneGeometry?
        var lastRequest: TmuxPaneSize.Request?
        while let current = request {
            rounds += 1
            lastRequest = current
            let winW = min(100, current.columns)
            let winH = min(50, current.rows)
            let paneW = (winW - 1) / 2
            let paneH = winH / 2
            let geometry = TmuxPaneGeometry(
                windowID: "@0", windowWidth: winW, windowHeight: winH, paneWidth: paneW, paneHeight: paneH)
            lastGeometry = geometry
            request = sizer.nextRequest(after: geometry)
        }
        #expect(rounds == 2)
        #expect(lastRequest == .init(columns: 163, rows: 40))
        #expect(lastGeometry == TmuxPaneGeometry(windowID: "@0", windowWidth: 100, windowHeight: 40, paneWidth: 49, paneHeight: 20))
    }
}
