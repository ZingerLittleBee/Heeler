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
