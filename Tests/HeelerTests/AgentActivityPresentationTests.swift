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

    @Test func lockScreenTilesTakeBlockedThenDoneThenWorkingAndKeepSenderOrderWithinStatus() {
        let cases = [
            (["working", "done", "blocked"], ["w1:p2", "w1:p1"]),
            (["working", "blocked", "done", "blocked", "blocked"], ["w1:p1", "w1:p3"]),
            (["working", "done", "done"], ["w1:p1", "w1:p2"]),
            (["unknown", "working", "working"], ["w1:p1", "w1:p2"]),
            (["unknown", "idle"], ["w1:p0", "w1:p1"]),
            (["working"], ["w1:p0"]),
        ]
        for (statuses, expected) in cases {
            let agents = statuses.enumerated().map {
                agentDetail(paneID: "w1:p\($0.offset)", status: $0.element)
            }
            let presentation = AgentActivityPresentation.detailed(
                details: .init(hostName: "Laptop", agents: agents),
                counts: .init(
                    working: statuses.filter { $0 == "working" }.count,
                    blocked: statuses.filter { $0 == "blocked" }.count,
                    done: statuses.filter { $0 == "done" }.count))
            let screen = AgentActivityLockScreenPresentation(presentation: presentation, isStale: false)
            #expect(screen.tiles.map(\.paneID) == expected)
            #expect(screen.countColumns.isEmpty)
        }
    }

    @Test func lockScreenFooterUsesPlaintextCountsMinusTilesInAttentionOrder() {
        let presentation = AgentActivityPresentation.detailed(
            details: .init(hostName: "Laptop", agents: [
                agentDetail(paneID: "w1:p1", status: "working"),
                agentDetail(paneID: "w1:p2", status: "blocked"),
                agentDetail(paneID: "w1:p3", status: "done"),
                agentDetail(paneID: "w1:p4", status: "done"),
                agentDetail(paneID: "w1:p5", status: "blocked"),
            ]),
            counts: .init(working: 2, blocked: 3, done: 2))

        let fresh = AgentActivityLockScreenPresentation(presentation: presentation, isStale: false)
        let stale = AgentActivityLockScreenPresentation(presentation: presentation, isStale: true)
        #expect(fresh.footer == .phrases(["+1 needs you", "+2 done", "+2 working"]))
        #expect(stale.footer == .phrases(["+1 needs you", "+2 done", "+2 working", "May be out of date"]))
        #expect(stale.tiles == fresh.tiles)
    }

    @Test func lockScreenFooterShowsTotalOrStaleNoteWhenAllAgentsHaveTiles() {
        let presentation = detailedPresentation(
            agentCount: 1, total: .init(working: 1, blocked: 0, done: 0))
        #expect(AgentActivityLockScreenPresentation(presentation: presentation, isStale: false)
            .footer == .total("1 agent"))
        #expect(AgentActivityLockScreenPresentation(presentation: presentation, isStale: true)
            .footer == .phrases(["May be out of date"]))
    }

    @Test func lockScreenCountsOnlyShowsOneColumnPerNonzeroStatusAndNoOverflow() {
        typealias CountColumn = AgentActivityLockScreenPresentation.CountColumn
        let counts = AgentActivityAttributes.ContentState.Counts(working: 12, blocked: 1, done: 4)
        let cases: [(AgentActivityPresentation, [CountColumn], String)] = [
            (.countsOnly(counts: counts), [
                CountColumn(status: "blocked", count: 1),
                CountColumn(status: "done", count: 4),
                CountColumn(status: "working", count: 12),
            ], "17 agents"),
            (.detailed(details: .init(hostName: "Mac mini", agents: []),
                counts: .init(working: 2, blocked: 1, done: 0)), [
                CountColumn(status: "blocked", count: 1),
                CountColumn(status: "working", count: 2),
            ], "3 agents"),
            (.countsOnly(counts: .init(working: 3, blocked: 0, done: 0)), [
                CountColumn(status: "working", count: 3),
            ], "3 agents"),
            (.countsOnly(counts: .init(working: 0, blocked: 0, done: 0)), [], "0 agents"),
        ]
        for (presentation, columns, total) in cases {
            let fresh = AgentActivityLockScreenPresentation(presentation: presentation, isStale: false)
            let stale = AgentActivityLockScreenPresentation(presentation: presentation, isStale: true)
            #expect(fresh.tiles.isEmpty)
            #expect(stale.tiles.isEmpty)
            #expect(fresh.countColumns == columns)
            #expect(stale.countColumns == columns)
            #expect(fresh.footer == .total(total))
            #expect(stale.footer == .phrases(["May be out of date"]))
        }
    }

    @Test func lockScreenTileUsesSecondFieldRowForTaskAndAppendsKindToFirstRow() {
        var agent = agentDetail(paneID: "w1:p1", status: "blocked")
        agent.rows = [
            [.init(text: "herdr", bold: true)],
            [.init(text: "Redesign"), .init(text: " live activity")],
            [.init(text: "Third row")],
        ]
        let text = AgentActivityLockScreenPresentation.TileText(agent: agent)
        #expect(text.task == "Redesign live activity")
        #expect(text.byline == "herdr · Claude")

        agent.rows = [
            [.init(text: "herdr"), .init(text: " · "), .init(text: "Claude")],
            [.init(text: "Redesign live activity")],
        ]
        #expect(AgentActivityLockScreenPresentation.TileText(agent: agent).byline == "herdr · Claude")
    }

    @Test func lockScreenTileUsesOnlyFieldRowForTaskAndOmitsDuplicateKind() {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = [[.init(text: "Redesign live activity")]]
        let text = AgentActivityLockScreenPresentation.TileText(agent: agent)
        #expect(text.task == "Redesign live activity")
        #expect(text.byline == "Claude")

        agent.rows = [[.init(text: "Claude")]]
        let kindOnly = AgentActivityLockScreenPresentation.TileText(agent: agent)
        #expect(kindOnly.task == "Claude")
        #expect(kindOnly.byline == nil)

        agent.rows = []
        let empty = AgentActivityLockScreenPresentation.TileText(agent: agent)
        #expect(empty.task == nil)
        #expect(empty.byline == nil)

        agent.rows = nil
        let legacy = AgentActivityLockScreenPresentation.TileText(agent: agent)
        #expect(legacy.task == "Claude")
        #expect(legacy.byline == "Heeler · Claude")
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
        let digit = level.unit * 0.6
        let pair = level.symbol + level.symbolGap + digit
        let trailing = pair + level.itemSpacing + digit
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

    @Test func expandedKeepsAPinnedAgentFirstOnlyWithinItsStatus() {
        // The Host sends pinned Agents first: here a pinned Working Agent.
        let agents = [("w1:p9", "working"), ("w1:p1", "done"), ("w1:p2", "blocked"), ("w1:p3", "working")]
            .map { agentDetail(paneID: $0.0, status: $0.1) }
        let expanded = AgentActivityIslandExpanded(presentation: .detailed(
            details: .init(hostName: "Laptop", agents: agents),
            counts: .init(working: 2, blocked: 1, done: 1)))
        #expect(expanded.cards.map(\.paneID) == ["w1:p2", "w1:p1", "w1:p9"])
        #expect(expanded.summary == [.init(status: "working", count: 1)])
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
        let tile = UIColor(AgentActivityLockScreenChrome.hostTile)
        #expect(rgba(tile, .light) == [225, 223, 224])
        #expect(rgba(tile, .dark) == [65, 65, 70])
        let cut = UIColor(AgentActivityLockScreenChrome.glyphCut)
        #expect(rgba(cut, .light) == [255, 255, 255])
        #expect(rgba(cut, .dark) == [30, 30, 34])
    }

    @Test func lockScreenHostNamePrefersTheCatalogAndFallsBackToTheEnvelope() {
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
