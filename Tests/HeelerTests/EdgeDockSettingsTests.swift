import Foundation
import Testing

@testable import Heeler

@MainActor
struct EdgeDockSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "EdgeDockSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsAtEachControlsDefaultUntilMoved() throws {
        let settings = EdgeDockSettings(defaults: try makeDefaults())
        #expect(settings.fraction(for: .workspaceDrawer) == 0.5)
        #expect(settings.fraction(for: .messageJump) == 1)
    }

    @Test func remembersWhereEachControlWasDockedAcrossLaunches() throws {
        let defaults = try makeDefaults()
        let settings = EdgeDockSettings(defaults: defaults)
        settings.setFraction(0.2, for: .workspaceDrawer)
        settings.setFraction(0.75, for: .messageJump)
        #expect(settings.fraction(for: .workspaceDrawer) == 0.2)

        let relaunched = EdgeDockSettings(defaults: defaults)
        #expect(relaunched.fraction(for: .workspaceDrawer) == 0.2)
        #expect(relaunched.fraction(for: .messageJump) == 0.75)
    }

    @Test func clampsToTheEdgeAndRejectsUnreadableValues() throws {
        let settings = EdgeDockSettings(defaults: try makeDefaults())
        settings.setFraction(1.4, for: .workspaceDrawer)
        #expect(settings.fraction(for: .workspaceDrawer) == 1)
        settings.setFraction(-3, for: .workspaceDrawer)
        #expect(settings.fraction(for: .workspaceDrawer) == 0)
        settings.setFraction(.nan, for: .messageJump)
        #expect(settings.fraction(for: .messageJump) == 0)
        #expect(EdgeDockSettings.clamped(.infinity) == 0)
    }

    @Test func liftTurnsPointsOfTravelIntoAFractionOfTheEdge() {
        typealias Coordinator = MessageJumpChromeOverlay.Coordinator
        #expect(Coordinator.fraction(base: 1, travel: -100, edgeTravel: 400) == 0.75)
        #expect(Coordinator.fraction(base: 0.5, travel: 400, edgeTravel: 400) == 1,
                "Dragging past the band docks at the lowest position")
        #expect(Coordinator.fraction(base: 0.5, travel: 50, edgeTravel: 0) == 0.5,
                "No room to slide: the chrome stays put")
    }

    @Test func drawerHandleFollowsTheFractionAndStaysOnTheEdge() {
        let height: CGFloat = 668
        let travel = height - WorkspaceTerminalDrawer.handleSize.height
        #expect(WorkspaceTerminalDrawer.handleTop(fraction: 0, liftTravel: 0, height: height) == 0)
        #expect(WorkspaceTerminalDrawer.handleTop(fraction: 1, liftTravel: 0, height: height) == travel)
        #expect(WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 30, height: height)
                == travel / 2 + 30)
        #expect(WorkspaceTerminalDrawer.handleTop(fraction: 1, liftTravel: 500, height: height) == travel,
                "A lift cannot leave the terminal")
        #expect(WorkspaceTerminalDrawer.fraction(handleTop: travel / 4, height: height) == 0.25)
        #expect(WorkspaceTerminalDrawer.fraction(handleTop: 10, height: 20) == 0,
                "A terminal shorter than the handle has no travel")
    }

    /// The terminal and jump buttons as measured on an iPhone with the
    /// keyboard open: the handle at its default rested 18 points into them.
    @Test func drawerHandleStepsAboveTheJumpButtonsItWouldOverlap() {
        let handle = WorkspaceTerminalDrawer.handleSize.height
        let gap = WorkspaceTerminalDrawer.edgeGap
        let height: CGFloat = 240
        let jump: ClosedRange<CGFloat> = 136...180
        let unclear = WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height)
        #expect(unclear + handle > jump.lowerBound, "the measured overlap")

        let top = WorkspaceTerminalDrawer.handleTop(
            fraction: 0.5, liftTravel: 0, height: height, clearing: [jump])
        #expect(top == jump.lowerBound - gap - handle)
    }

    @Test func drawerHandleKeepsItsPlaceWhenNothingIsInTheWay() {
        let height: CGFloat = 600
        let rested = WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height)
        #expect(WorkspaceTerminalDrawer.handleTop(
            fraction: 0.5, liftTravel: 0, height: height, clearing: [400...444]) == rested)
        #expect(WorkspaceTerminalDrawer.handleTop(
            fraction: 0.5, liftTravel: 0, height: height, clearing: []) == rested)
    }

    @Test func drawerHandleStepsBelowWhenTheJumpButtonsSitAtTheTop() {
        let gap = WorkspaceTerminalDrawer.edgeGap
        let jump: ClosedRange<CGFloat> = 0...44
        let top = WorkspaceTerminalDrawer.handleTop(
            fraction: 0, liftTravel: 0, height: 400, clearing: [jump])
        #expect(top == jump.upperBound + gap)
    }

    @Test func drawerHandleStaysPutWithNoRoomOnEitherSide() {
        let handle = WorkspaceTerminalDrawer.handleSize.height
        let height = handle + 40
        let top = WorkspaceTerminalDrawer.handleTop(
            fraction: 0.5, liftTravel: 0, height: height, clearing: [10...50])
        #expect(top == WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height))
    }

    @Test func liftingAHandleThatSteppedAsideStartsWhereItSits() {
        let jump: ClosedRange<CGFloat> = 136...180
        func top(lift: CGFloat) -> CGFloat {
            WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: lift, height: 240, clearing: [jump])
        }
        let rested = top(lift: 0)
        #expect(rested == 64)
        #expect(top(lift: 10) == rested + 10, "the lifted handle follows the finger into the buttons' span")
        #expect(top(lift: -30) == rested - 30)
    }

    @Test func accessibilityNudgesPassTheJumpButtons() {
        let handle = WorkspaceTerminalDrawer.handleSize.height
        let gap = WorkspaceTerminalDrawer.edgeGap
        let jump: ClosedRange<CGFloat> = 256...300
        let above = jump.lowerBound - gap - handle
        let below = jump.upperBound + gap
        func nudge(_ top: CGFloat, _ step: CGFloat) -> CGFloat {
            WorkspaceTerminalDrawer.nudged(from: top, by: step, height: 400, clearing: [jump])
        }
        #expect(nudge(above, handle) == below)
        #expect(nudge(below, -handle) == above)
        #expect(nudge(0, handle) == handle, "a nudge clear of the buttons moves by the handle's height")
        #expect(WorkspaceTerminalDrawer.nudged(from: 300, by: handle, height: 400, clearing: []) == 400 - handle,
                "a nudge stays on the edge")
    }

    /// A nudge past the buttons is saved as a fraction, which reads back a
    /// hair short of where it was saved.
    @Test func aHandleNudgedPastTheJumpButtonsStaysThereOnceSaved() {
        let height: CGFloat = 632
        let jump: ClosedRange<CGFloat> = 430...474
        let start = jump.lowerBound - WorkspaceTerminalDrawer.edgeGap - WorkspaceTerminalDrawer.handleSize.height
        let nudged = WorkspaceTerminalDrawer.nudged(
            from: start, by: WorkspaceTerminalDrawer.handleSize.height, height: height, clearing: [jump])
        #expect(nudged == jump.upperBound + WorkspaceTerminalDrawer.edgeGap)
        let saved = WorkspaceTerminalDrawer.fraction(handleTop: nudged, height: height)
        let rested = WorkspaceTerminalDrawer.handleTop(fraction: saved, liftTravel: 0, height: height, clearing: [jump])
        #expect(abs(rested - nudged) < 0.01)
    }

    /// Direct Input with Attach Links, both jump buttons docked halfway down
    /// a 240-point terminal: below the buttons is the Attach Links button.
    @Test func drawerHandleDoesNotStepOntoAnotherControl() {
        let height: CGFloat = 240
        let jump: ClosedRange<CGFloat> = 45.5...134.5
        let links: ClosedRange<CGFloat> = 188...232
        let pastJump = WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height, clearing: [jump])
        #expect(pastJump == jump.upperBound + WorkspaceTerminalDrawer.edgeGap, "with the jump buttons alone it steps below them")
        let top = WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height, clearing: [jump, links])
        #expect(top == WorkspaceTerminalDrawer.handleTop(fraction: 0.5, liftTravel: 0, height: height),
                "with no clear place it stays where it rests")
    }

    @Test func drawerPanelCentresOnTheHandleWithoutLeavingTheTerminal() {
        let panel = WorkspaceTerminalDrawer.panelHeight(count: 3)
        let expected: CGFloat = 178  // header 36, three 44 rows, two 2 gaps, inset 6
        #expect(panel == expected)
        #expect(WorkspaceTerminalDrawer.panelHeight(count: 12)
                == WorkspaceTerminalDrawer.panelHeight(count: 6), "Six rows show; the rest scroll")
        #expect(WorkspaceTerminalDrawer.panelHeight(count: 3, hasFooter: true)
                == panel + WorkspaceTerminalDrawer.footerHeight, "New Terminal adds one footer row")
        let height: CGFloat = 600
        let handleTop: CGFloat = 300
        let centred = WorkspaceTerminalDrawer.panelTop(
            handleTop: handleTop, panelHeight: panel, height: height)
        #expect(centred == handleTop + WorkspaceTerminalDrawer.handleSize.height / 2 - panel / 2)
        #expect(WorkspaceTerminalDrawer.panelTop(handleTop: 0, panelHeight: panel, height: height) == 0)
        #expect(WorkspaceTerminalDrawer.panelTop(handleTop: 560, panelHeight: panel, height: height)
                == height - panel)
    }
}
