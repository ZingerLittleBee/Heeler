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
            ScriptedTmuxHost.words(of: TmuxPaneSize.clientsCommand().line)
                == ["list-clients", "-F", TmuxPaneSize.clientsFormat])
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

    @Test func clientCeilingFindsSmallestQualifyingWindowAreaAndSubtractsStatusLines() {
        let lines = { (rows: [String]) in rows.map { Data($0.utf8) } }

        #expect(TmuxPaneSize.clientCeiling(from: [], forWindow: "@0") == nil)
        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines([
                    "1 @0 80  on attached,focused,control-mode",
                    "1 @0 30 10 on attached,focused,control-mode",
                    "0 @0 30 10 on attached,focused,ignore-size",
                    "0 @1 30 10 on attached,focused",
                ]),
                forWindow: "@0") == nil)

        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines(["0 @0 160 50 on attached,focused"]),
                forWindow: "@0") == .init(columns: 160, rows: 49))
        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines(["0 @0 160 50 off attached,focused"]),
                forWindow: "@0") == .init(columns: 160, rows: 50))
        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines(["0 @0 160 50 2 attached,focused"]),
                forWindow: "@0") == .init(columns: 160, rows: 48))
        // When client_height <= status lines, tmux sets CLIENT_STATUSOFF so all rows hold the window.
        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines(["0 @0 80 4 5 attached,focused"]),
                forWindow: "@0") == .init(columns: 80, rows: 4))

        // Multiple qualifying clients on @0 cap each axis to the smallest client showing @0.
        #expect(
            TmuxPaneSize.clientCeiling(
                from: lines([
                    "0 @0 120 50 on attached,focused",
                    "0 @0 140 32 2 attached",
                    "0 @2 20 8 on attached,focused",
                    "0 @0 25 9 on attached,ignore-size",
                ]),
                forWindow: "@0") == .init(columns: 120, rows: 30))
    }

    @Test func aDesktopCeilingCapsRequestsWhileStillCorrectingTheOtherAxis() {
        // Desktop holds @0 at 100x50. Width wants 80 in a 50/50 split (uncapped 163,
        // capped at 100 -> paneWidth 49); height wants 20 in a 50/50 split (asks 42,
        // gets 21 > 20, steps height down to 40 without ever asking width above 100).
        let ceiling = TmuxPaneSize.Request(columns: 100, rows: 50)
        var sizer = TmuxPaneSizer(targetColumns: 80, targetRows: 20, ceiling: ceiling)
        var request: TmuxPaneSize.Request? = sizer.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 100, windowHeight: 50, paneWidth: 49, paneHeight: 24))
        #expect(request == .init(columns: 100, rows: 42))

        var rounds = 0
        var lastGeometry: TmuxPaneGeometry?
        var lastRequest: TmuxPaneSize.Request?
        while let current = request {
            rounds += 1
            #expect(current.columns <= ceiling.columns)
            #expect(current.rows <= ceiling.rows)
            lastRequest = current
            let paneW = (current.columns - 1) / 2
            let paneH = current.rows / 2
            let geometry = TmuxPaneGeometry(
                windowID: "@0", windowWidth: current.columns, windowHeight: current.rows,
                paneWidth: paneW, paneHeight: paneH)
            lastGeometry = geometry
            request = sizer.nextRequest(after: geometry)
        }
        #expect(rounds == 2)
        #expect(lastRequest == .init(columns: 100, rows: 40))
        #expect(lastGeometry == TmuxPaneGeometry(windowID: "@0", windowWidth: 100, windowHeight: 40, paneWidth: 49, paneHeight: 20))

        // When a smaller desktop attaches after Heeler already sized @0 to 80x24,
        // the sizer shrinks @0 to the 36x6 ceiling in one request and stops.
        var shrinking = TmuxPaneSizer(
            targetColumns: 80, targetRows: 24, ceiling: .init(columns: 36, rows: 6))
        let shrinkFirst = shrinking.initialRequest(
            from: TmuxPaneGeometry(windowID: "@0", windowWidth: 80, windowHeight: 24, paneWidth: 80, paneHeight: 24))
        #expect(shrinkFirst == .init(columns: 36, rows: 6))
        #expect(
            shrinking.nextRequest(
                after: TmuxPaneGeometry(windowID: "@0", windowWidth: 36, windowHeight: 6, paneWidth: 36, paneHeight: 6))
                == nil)
    }
}
