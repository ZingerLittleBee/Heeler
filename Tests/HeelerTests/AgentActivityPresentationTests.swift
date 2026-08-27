import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Agent activity presentation")
struct AgentActivityPresentationTests {
    private static let statuses: [(wire: String, palette: AgentStatus)] = [
        ("blocked", .blocked),
        ("done", .done),
        ("working", .working),
        ("unknown", .unknown),
    ]

    private func agentDetail(
        paneID: String, status: String = "working"
    ) -> AgentActivityDetails.AgentDetail {
        AgentActivityDetails.AgentDetail(
            paneID: paneID, kind: "claude", name: nil, status: status,
            title: "Task \(paneID)")
    }

    private func detailedPresentation(
        agentCount: Int, total: AgentActivityAttributes.ContentState.Counts
    ) -> AgentActivityPresentation {
        let agents = (0..<agentCount).map { agentDetail(paneID: "w1:p\($0)") }
        return .detailed(
            details: AgentActivityDetails(hostName: "mbp", agents: agents),
            counts: total)
    }

    @Test func freshShowsFourRowsWhenTotalIsFour() {
        let presentation = detailedPresentation(
            agentCount: 4, total: .init(working: 4, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == nil)
    }

    @Test func freshShowsFourRowsAndOverflowWhenTotalIsFive() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 5, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 1)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == "+1 more")
    }

    @Test func freshShowsFourRowsAndOverflowWhenTotalExceedsEnvelopeLimit() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 6, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 2)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == "+2 more")
    }

    @Test func staleShowsFourRowsWhenTotalIsFour() {
        let presentation = detailedPresentation(
            agentCount: 4, total: .init(working: 4, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "May be out of date")
    }

    @Test func staleShowsFourRowsAndOverflowWhenTotalExceedsFour() {
        let presentation = detailedPresentation(
            agentCount: 5, total: .init(working: 5, blocked: 0, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).count == 4)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 1)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "+1 more · May be out of date")
    }

    @Test func staleShowsAllRowsWhenTotalIsThreeOrLess() {
        let presentation = detailedPresentation(
            agentCount: 3, total: .init(working: 1, blocked: 1, done: 1))
        #expect(presentation.lockScreenAgents(isStale: true).count == 3)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "May be out of date")
    }

    @Test func staleCountsOnlyHasNoRowsAndNoOverflow() {
        let presentation = AgentActivityPresentation.countsOnly(
            counts: .init(working: 2, blocked: 1, done: 0))
        #expect(presentation.lockScreenAgents(isStale: true).isEmpty)
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: true) == "May be out of date")
    }

    @Test func freshCountsOnlyHasNoRowsOrCaption() {
        let presentation = AgentActivityPresentation.countsOnly(
            counts: .init(working: 2, blocked: 1, done: 0))
        #expect(presentation.lockScreenAgents(isStale: false).isEmpty)
        #expect(presentation.lockScreenOverflowCount(isStale: false) == 0)
        #expect(presentation.lockScreenTrailingCaption(isStale: false) == nil)
    }

    @Test func attentionOrderPrefersBlockedThenDoneThenWorking() {
        let blockedFirst = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 1, done: 0)
        #expect(blockedFirst.attentionStatusItem?.status == "blocked")
        #expect(blockedFirst.attentionStatusItem?.count == 1)

        let doneBeforeWorking = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 0, done: 1)
        #expect(doneBeforeWorking.attentionStatusItem?.status == "done")
        #expect(doneBeforeWorking.attentionStatusItem?.count == 1)

        let workingOnly = AgentActivityAttributes.ContentState.Counts(
            working: 3, blocked: 0, done: 0)
        #expect(workingOnly.attentionStatusItem?.status == "working")
        #expect(workingOnly.attentionStatusItem?.count == 3)
    }

    @Test func narrationIncludesStatusForIslandAccessibility() {
        let agent = agentDetail(paneID: "w1:p1", status: "blocked")
        #expect(AgentActivityNarration.rowLabel(for: agent) == "claude, blocked, Task w1:p1")
    }

    @Test func lockScreenRowsUseComfortableAndDenseAppleTargetHeights() {
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 1) == 44)
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 3) == 44)
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 4) == 28)
    }

    @Test func deviceLightAppearanceOverridesIncorrectActivityKitDarkScheme() {
        let appearance = AgentActivityLockScreenAppearance.resolve(
            screenStyle: .light,
            fallback: .dark)

        #expect(appearance == .light)
        #expect(appearance.colorScheme == .light)
    }

    @Test func deviceDarkAppearanceOverridesIncorrectActivityKitLightScheme() {
        let appearance = AgentActivityLockScreenAppearance.resolve(
            screenStyle: .dark,
            fallback: .light)

        #expect(appearance == .dark)
        #expect(appearance.colorScheme == .dark)
    }

    @Test func unspecifiedDeviceAppearanceUsesActivityKitFallback() {
        #expect(
            AgentActivityLockScreenAppearance.resolve(
                screenStyle: .unspecified,
                fallback: .light
            ) == .light)
        #expect(
            AgentActivityLockScreenAppearance.resolve(
                screenStyle: .unspecified,
                fallback: .dark
            ) == .dark)
    }

    @Test func lockScreenChromeResolvesAgainstDeviceAppearance() {
        #expect(
            rgba(AgentActivityLockScreenAppearance.light.backgroundColor)
                == rgba(UIColor.systemBackground, .light))
        #expect(
            rgba(AgentActivityLockScreenAppearance.dark.backgroundColor)
                == rgba(UIColor.systemBackground, .dark))
        #expect(
            rgba(AgentActivityLockScreenAppearance.light.actionColor)
                == rgba(UIColor.label, .light))
        #expect(
            rgba(AgentActivityLockScreenAppearance.dark.actionColor)
                == rgba(UIColor.label, .dark))
    }

    @Test func lockScreenInkMatchesPaletteForEachAppearance() {
        for (wire, palette) in Self.statuses {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let resolved = rgba(
                    UIColor(AgentActivityStatusStyle.ink(for: wire, on: .lockScreen)),
                    style)
                #expect(resolved == rgba(palette.inkUIColor, style), "\(wire) ink \(style.rawValue)")
            }
        }
    }

    @Test func lockScreenWashMatchesPaletteForEachAppearance() {
        for (wire, palette) in Self.statuses {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let resolved = rgba(
                    UIColor(AgentActivityStatusStyle.wash(for: wire, on: .lockScreen)),
                    style)
                #expect(resolved == rgba(palette.tintUIColor, style), "\(wire) wash \(style.rawValue)")
            }
        }
    }

    @Test func islandInkStaysMochaUnderLightAppearance() {
        for (wire, palette) in Self.statuses {
            let resolved = rgba(
                UIColor(AgentActivityStatusStyle.ink(for: wire, on: .island)),
                .light)
            #expect(
                resolved == rgba(palette.inkUIColor, .dark),
                "\(wire) island ink must stay Mocha")
        }
    }

    @Test func islandWashStaysMochaUnderLightAppearance() {
        for (wire, palette) in Self.statuses {
            let resolved = rgba(
                UIColor(AgentActivityStatusStyle.wash(for: wire, on: .island)),
                .light)
            #expect(
                resolved == rgba(palette.tintUIColor, .dark),
                "\(wire) island wash must stay Mocha")
        }
    }

    @Test func unknownWireStatusMapsToMutedPaletteRole() {
        let bogus = "haunted"
        #expect(
            rgba(UIColor(AgentActivityStatusStyle.ink(for: bogus, on: .lockScreen)), .light)
                == rgba(AgentStatus.unknown.inkUIColor, .light))
        #expect(
            rgba(UIColor(AgentActivityStatusStyle.wash(for: bogus, on: .island)), .light)
                == rgba(AgentStatus.unknown.tintUIColor, .dark))
    }

    private func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> [Int] {
        rgba(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }

    private func rgba(_ color: UIColor) -> [Int] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()),
        ]
    }
}
