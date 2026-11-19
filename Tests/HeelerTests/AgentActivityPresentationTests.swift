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
            paneID: paneID, kind: "claude", name: nil, workspace: "Heeler", status: status,
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
        let allThree = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 1, done: 3)
        #expect(allThree.attentionItems.map(\.status) == ["blocked", "done", "working"])
        #expect(allThree.attentionItems.map(\.count) == [1, 3, 2])

        let doneBeforeWorking = AgentActivityAttributes.ContentState.Counts(
            working: 2, blocked: 0, done: 1)
        #expect(doneBeforeWorking.attentionItems.map(\.status) == ["done", "working"])

        let workingOnly = AgentActivityAttributes.ContentState.Counts(
            working: 3, blocked: 0, done: 0)
        #expect(workingOnly.attentionItems.map(\.status) == ["working"])
        #expect(workingOnly.attentionItems.map(\.count) == [3])
    }

    private typealias Counts = AgentActivityAttributes.ContentState.Counts
    private typealias Compact = AgentActivityIslandCompact

    private func compact(_ counts: Counts, letter: String? = nil, width: CGFloat = 430) -> Compact {
        AgentActivityIslandCompact(
            tallies: counts.attentionItems.map { .init(status: $0.status, count: $0.count) },
            letter: letter, screenWidth: width)
    }

    @Test func compactShowsEveryStatusSplitAcrossTheCamera() {
        let working = compact(.init(working: 2, blocked: 0, done: 0))
        #expect(working.leading == [.symbol("working")])
        #expect(working.trailing == [.count("working", 2)])

        let two = compact(.init(working: 0, blocked: 1, done: 2))
        #expect(two.leading == [.pair("blocked", 1)])
        #expect(two.trailing == [.pair("done", 2)])

        let three = compact(.init(working: 1, blocked: 1, done: 1))
        #expect(three.leading == [.pair("blocked", 1), .pair("done", 1)])
        #expect(three.trailing == [.pair("working", 1)])
        #expect(three.letter == nil)
    }

    @Test func compactGathersStatusesLeftOfTheHostLetter() {
        let one = compact(.init(working: 0, blocked: 1, done: 0), letter: "L")
        #expect(one.leading == [.pair("blocked", 1)])
        #expect(one.trailing.isEmpty)
        #expect(one.letter == "L")

        let two = compact(.init(working: 3, blocked: 0, done: 2), letter: "L")
        #expect(two.leading == [.pair("done", 2), .pair("working", 3)])
        #expect(two.trailing.isEmpty)

        let three = compact(.init(working: 1, blocked: 1, done: 1), letter: "MB")
        #expect(three.leading == [.pair("blocked", 1), .pair("done", 1)])
        #expect(three.trailing == [.pair("working", 1)])
        #expect(three.letter == "MB")
    }

    @Test func compactStepsDownToSmallerSymbolsThenNumbersOnlyAndKeepsTheLetter() {
        let allThree = Counts(working: 1, blocked: 1, done: 1)
        #expect(compact(allThree, width: 430).level == .full)
        #expect(compact(allThree, width: 393).level == .small)

        let big = Counts(working: 15, blocked: 1, done: 12)
        #expect(compact(big, width: 430).level == .small)
        let narrow = compact(big, width: 393)
        #expect(narrow.level == .numbersOnly)
        #expect(narrow.leading == [.count("blocked", 1), .count("done", 12)])
        #expect(narrow.trailing == [.count("working", 15)])

        let lettered = compact(.init(working: 15, blocked: 10, done: 12), letter: "MB", width: 393)
        #expect(lettered.level == .numbersOnly)
        #expect(lettered.letter == "MB")
    }

    @Test func compactSidesShareTheWiderSidesWidth() {
        let level = Compact.Level.full
        let one = compact(.init(working: 2, blocked: 0, done: 0))
        #expect(one.sideWidth == level.symbol)

        let lettered = compact(.init(working: 1, blocked: 1, done: 1), letter: "L")
        let pair = level.symbol + level.symbolGap + level.digit
        let trailing = pair + level.itemSpacing + level.digit
        let leading = pair * 2 + level.itemSpacing
        #expect(abs(lettered.sideWidth - max(leading, trailing)) < 0.001)
    }

    @Test func expandedShowsThreeCardsThenTheAgentsLeftOutByStatus() {
        let agents = ["blocked", "done", "done", "done", "working"].enumerated().map {
            agentDetail(paneID: "w1:p\($0.offset)", status: $0.element)
        }
        let six = AgentActivityIslandExpanded(presentation: .detailed(
            details: .init(hostName: "Laptop", agents: agents),
            counts: .init(working: 2, blocked: 1, done: 3)))
        #expect(six.cards.map(\.paneID) == ["w1:p0", "w1:p1", "w1:p2"])
        #expect(six.summary == [.init(status: "done", count: 1), .init(status: "working", count: 2)])
        #expect(six.isOverflow)
        #expect(six.total == 6)

        let two = AgentActivityIslandExpanded(presentation: .detailed(
            details: .init(hostName: "Laptop", agents: Array(agents.prefix(2))),
            counts: .init(working: 0, blocked: 1, done: 1)))
        #expect(two.cards.count == 2)
        #expect(two.summary.isEmpty)

        let countsOnly = AgentActivityIslandExpanded(
            presentation: .countsOnly(counts: .init(working: 2, blocked: 1, done: 0)))
        #expect(countsOnly.cards.isEmpty)
        #expect(countsOnly.summary == [.init(status: "blocked", count: 1), .init(status: "working", count: 2)])
        #expect(countsOnly.isOverflow == false)
    }

    @Test func islandLetterRequiresTwoHostsAndAComputedLabel() {
        let oneHost = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: "host", name: "Laptop", label: "L"),
        ])
        let twoHosts = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: "host", name: "Laptop", label: "L"),
            .init(id: "other", name: "Oak4d", label: "O"),
        ])
        let one = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 0, done: 0)),
            hostID: "host", hostSnapshot: oneHost)
        #expect(one.hostLabel == nil)
        #expect(one.compact(screenWidth: 430).letter == nil)
        #expect(one.accessibilityLabel == "1 working")

        let two = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 1, done: 0)),
            hostID: "host", hostSnapshot: twoHosts)
        #expect(two.compact(screenWidth: 430).letter == "L")
        #expect(two.tallies == [.init(status: "blocked", count: 1), .init(status: "working", count: 1)])
        #expect(two.accessibilityLabel == "Laptop, 1 needs you, 1 working")

        for label in [nil, ""] as [String?] {
            let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
                .init(id: "host", name: "Laptop", label: label),
                .init(id: "other", name: "Oak4d", label: "O"),
            ])
            let unlabeled = AgentActivityIslandPresentation(
                presentation: .countsOnly(counts: .init(working: 1, blocked: 2, done: 1)),
                hostID: "host", hostSnapshot: snapshot)
            #expect(unlabeled.hostLabel == nil)
            #expect(unlabeled.accessibilityLabel == "Laptop, 2 need you, 1 working, 1 done")
        }
    }

    @Test func narrationIncludesStatusForIslandAccessibility() {
        let agent = agentDetail(paneID: "w1:p1", status: "blocked")
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Heeler, Claude, Needs you")
    }

    @Test func identityIgnoresCustomAgentNameAndTerminalTitle() {
        let agent = AgentActivityDetails.AgentDetail(
            paneID: "w1:p1", kind: "codex", name: "identityprobe", workspace: "Heeler",
            status: "working", title: "Developer · identityprobe")

        #expect(agent.displayIdentity == "Heeler · Codex")
        #expect(agent.displayWorkspace == "Heeler")
    }

    @Test func liveActivityRowsNarrateWorkspaceKindAndStatusWithoutTaskNoise() {
        let agent = AgentActivityDetails.AgentDetail(
            paneID: "w1:p1", kind: "claude", workspace: "Checkout",
            status: "blocked", title: nil)

        #expect(agent.displayWorkspace == "Checkout")
        #expect(AgentActivityNarration.rowLabel(for: agent)
            == "Checkout, Claude, Needs you")
    }

    @Test func lockScreenRowsUseComfortableAndDenseAppleTargetHeights() {
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 1) == 44)
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 2) == 44)
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 3) == 28)
        #expect(AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: 4) == 28)
    }

    @Test func lockScreenChromeRemainsDynamicAcrossSystemAppearances() {
        #expect(AgentActivityLockScreenChrome.backgroundTint == nil)
        #expect(
            rgba(AgentActivityLockScreenChrome.actionColor, .light)
                == rgba(UIColor.label, .light))
        #expect(
            rgba(AgentActivityLockScreenChrome.actionColor, .dark)
                == rgba(UIColor.label, .dark))
        #expect(
            rgba(AgentActivityLockScreenChrome.actionColor, .light)
                != rgba(AgentActivityLockScreenChrome.actionColor, .dark))
    }

    @Test func lockScreenHeaderPrefersTheCatalogAndFallsBackToTheEnvelope() {
        let presentation = detailedPresentation(
            agentCount: 1, total: .init(working: 1, blocked: 0, done: 0))
        let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: "host", name: "workstation-west-build-01"),
        ])
        #expect(presentation.lockScreenHostName(hostID: "host", snapshot: snapshot)
            == "workstation-west-build-01")
        #expect(presentation.lockScreenHostName(hostID: "other", snapshot: snapshot) == "mbp")
        #expect(presentation.lockScreenHostName(hostID: "host", snapshot: nil) == "mbp")
        let countsOnly = AgentActivityPresentation.countsOnly(counts: presentation.counts)
        #expect(countsOnly.lockScreenHostName(hostID: "host", snapshot: snapshot)
            == "workstation-west-build-01")
        #expect(countsOnly.lockScreenHostName(hostID: "host", snapshot: nil) == nil)
        let emptyName = AgentActivityPresentation.detailed(
            details: .init(hostName: "", agents: []), counts: presentation.counts)
        #expect(emptyName.lockScreenHostName(hostID: "host", snapshot: nil) == nil)
    }

    @Test func lockScreenNarrationIncludesTheDisplayedStatusWord() {
        for (wire, word) in [("blocked", "Needs you"), ("working", "Working"), ("done", "Done")] {
            let agent = agentDetail(paneID: "w1:p1", status: wire)
            #expect(AgentActivityNarration.rowLabel(for: agent, on: .lockScreen)
                == "Heeler, Claude, \(word)")
        }
    }

    @Test func countsOnlyUsesStatusPhrasesWithEnglishPlurals() {
        #expect(AgentActivityCopy.lockScreenCounts(.init(working: 2, blocked: 1, done: 0))
            == "1 needs you · 2 working")
        #expect(AgentActivityCopy.lockScreenCounts(.init(working: 0, blocked: 2, done: 1))
            == "2 need you · 1 done")
        #expect(AgentActivityCopy.lockScreenCounts(.init(working: 0, blocked: 0, done: 0)).isEmpty)
    }

    @Test func lockScreenSemanticTextRemainsDynamicAcrossSystemAppearances() {
        let primary = UIColor(AgentActivitySemanticStyle.primary(on: .lockScreen))
        let secondary = UIColor(AgentActivitySemanticStyle.secondary(on: .lockScreen))

        #expect(rgba(primary, .light) == rgba(UIColor.label, .light))
        #expect(rgba(primary, .dark) == rgba(UIColor.label, .dark))
        #expect(rgba(secondary, .light) == rgba(UIColor.secondaryLabel, .light))
        #expect(rgba(secondary, .dark) == rgba(UIColor.secondaryLabel, .dark))
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

    @Test func configuredRowsNarrateLiteralFieldsAndStatus() {
        var agent = agentDetail(paneID: "w1:p1", status: "blocked")
        agent.rows = [
            [.init(text: "**Task**"), .init(text: " · "), .init(text: "feature/one")],
            [.init(text: "/src/Heeler")],
        ]
        #expect(AgentActivityNarration.rowLabel(for: agent)
            == "**Task** · feature/one, /src/Heeler, Needs you")
        #expect(String(AgentActivityFields.attributedText(
            agent.rows?[0] ?? [], rowIndex: 0, surface: .lockScreen).characters)
            == "**Task** · feature/one")
    }

    @Test func intentionallyEmptyFieldsKeepOnlyTheStatus() {
        var agent = agentDetail(paneID: "w1:p1", status: "blocked")
        agent.rows = []
        #expect(AgentActivityFields.rows(for: agent).isEmpty)
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Needs you")
        #expect(AgentActivityNarration.rowLabel(for: agent, on: .lockScreen) == "Needs you")
    }

    @Test func configuredFieldsShowAtMostThreeRows() {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = (1...4).map { [.init(text: "Row \($0)")] }
        #expect(AgentActivityFields.rows(for: agent).count == 3)
        #expect(AgentActivityNarration.rowLabel(for: agent) == "Row 1, Row 2, Row 3, Working")
    }

    @Test func threeRowCardsReserveSpaceForTheHostHeaderOverflowAndStaleness() {
        let presentation = configuredPresentation(agentCount: 5)
        #expect(presentation.lockScreenAgents(isStale: false).map(\.paneID) == ["w1:p0", "w1:p1"])
        #expect(presentation.lockScreenAgents(isStale: true).count == 2)
        #expect(presentation.lockScreenTrailingCaption(isStale: true)
            == "+3 more · May be out of date")
        let three = configuredPresentation(agentCount: 3)
        #expect(three.lockScreenAgents(isStale: false).count == 2)
        #expect(three.lockScreenAgents(isStale: true).count == 2)
        #expect(three.lockScreenTrailingCaption(isStale: false) == "+1 more")
        #expect(three.lockScreenAgents(isStale: true, hasHeader: false).count == 3)
        #expect(three.lockScreenTrailingCaption(isStale: true, hasHeader: false)
            == "May be out of date")
    }

    @Test func lockScreenFittingKeepsTheEnvelopeOrderIncludingPinnedWorkingAgents() {
        let ordered = ["working", "blocked", "done", "working", "done"].enumerated().map {
            agentDetail(paneID: "w1:p\($0.offset)", status: $0.element)
        }
        let presentation = AgentActivityPresentation.detailed(
            details: .init(hostName: "mbp", agents: ordered),
            counts: .init(working: 3, blocked: 2, done: 2))
        #expect(presentation.lockScreenAgents(isStale: true).map(\.paneID)
            == ["w1:p0", "w1:p1", "w1:p2", "w1:p3"])
        #expect(presentation.lockScreenOverflowCount(isStale: true) == 3)
    }

    @Test func threeRowCardsUseTheComfortableTargetHeight() {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = [[.init(text: "1")], [.init(text: "2")], [.init(text: "3")]]
        #expect(AgentActivityRowMetrics.minimumHeight(for: agent) == 44)
        agent.rows = [[.init(text: "1")], [.init(text: "2")]]
        #expect(AgentActivityRowMetrics.minimumHeight(for: agent) == 31)
        agent.rows = [[.init(text: "1")]]
        #expect(AgentActivityRowMetrics.minimumHeight(for: agent) == 28)
        agent.rows = []
        #expect(AgentActivityRowMetrics.minimumHeight(for: agent) == 28)
        agent.rows = nil
        #expect(AgentActivityRowMetrics.minimumHeight(for: agent) == 28)
    }

    @Test func twoRowCardsReserveSpaceForTheHostHeaderOverflowAndStaleness() {
        let four = configuredPresentation(agentCount: 4, rowCount: 2)
        #expect(four.lockScreenAgents(isStale: false).count == 4)
        #expect(four.lockScreenTrailingCaption(isStale: false) == nil)
        #expect(four.lockScreenAgents(isStale: true).map(\.paneID) == ["w1:p0", "w1:p1", "w1:p2"])
        #expect(four.lockScreenTrailingCaption(isStale: true) == "+1 more · May be out of date")
        #expect(four.lockScreenAgents(isStale: true, hasHeader: false).count == 4)
        let five = configuredPresentation(agentCount: 5, rowCount: 2)
        #expect(five.lockScreenAgents(isStale: false).count == 3)
        #expect(five.lockScreenTrailingCaption(isStale: false) == "+2 more")
        #expect(five.lockScreenAgents(isStale: true).count == 3)
    }

    @Test func styledFieldsPreserveHexColorAndSecondarySemantics() {
        for hex in ["#abc", "#aabbcc"] {
            #expect(rgba(UIColor(AgentActivityFields.foreground(
                for: .init(text: "branch", fg: hex), rowIndex: 0, surface: .lockScreen)), .light)
                == [170, 187, 204])
        }
        for invalid in ["red", "#ggg", "#1234", "#12345678"] {
            #expect(rgba(UIColor(AgentActivityFields.foreground(
                for: .init(text: "branch", fg: invalid), rowIndex: 0, surface: .lockScreen)), .light)
                == rgba(.label, .light))
        }
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 0, surface: .lockScreen)), .light)
            == rgba(.secondaryLabel, .light))
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 2, surface: .lockScreen)), .light)
            == rgba(.tertiaryLabel, .light))
        #expect(rgba(UIColor(AgentActivityFields.foreground(
            for: .init(text: "directory", dim: true), rowIndex: 2, surface: .island)), .light)
            == rgba(.tertiaryLabel, .dark))
    }

    private func configuredPresentation(
        agentCount: Int, rowCount: Int = 3
    ) -> AgentActivityPresentation {
        let rows: [[AgentActivityDetails.Field]] = [
            [.init(text: "Heeler · Claude", bold: true)],
            [.init(text: "Fix the sidebar")],
            [.init(text: "/Users/developer/Heeler", dim: true)],
        ]
        let agents = (0..<agentCount).map { index in
            var agent = agentDetail(paneID: "w1:p\(index)")
            agent.rows = Array(rows.prefix(rowCount))
            return agent
        }
        return .detailed(details: .init(hostName: "mbp", agents: agents),
            counts: .init(working: agentCount, blocked: 0, done: 0))
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
