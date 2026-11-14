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

    @Test func islandMarksUseAttentionOrderAndReplaceTheLastSlotOnOverflow() {
        let mixed = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 1, done: 1)),
            hostID: "host", hostSnapshot: nil)
        #expect(mixed.marks.map(\.status) == ["blocked", "done", "working"])
        #expect(mixed.marks.allSatisfy { !$0.isOverflow })

        let seven = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 7, blocked: 0, done: 0)),
            hostID: "host", hostSnapshot: nil)
        #expect(seven.marks.count == 4)
        #expect(seven.marks.dropLast().map(\.status) == ["working", "working", "working"])
        #expect(seven.marks.last?.isOverflow == true)

        let four = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 2, done: 1)),
            hostID: "host", hostSnapshot: nil)
        #expect(four.marks.map(\.status) == ["blocked", "blocked", "done", "working"])
        #expect(four.marks.allSatisfy { !$0.isOverflow })

        let empty = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 0, blocked: 0, done: 0)),
            hostID: "host", hostSnapshot: nil)
        #expect(empty.marks.isEmpty)
    }

    @Test func islandTileRequiresTwoHostsAndAComputedLabel() {
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
        #expect(one.hasMultipleHosts == false)
        #expect(one.hostLabel == nil)
        #expect(one.minimalTileStatus == nil)
        #expect(one.accessibilityLabel == "1 working")

        let two = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 1, done: 0)),
            hostID: "host", hostSnapshot: twoHosts)
        #expect(two.hostLabel == "L")
        #expect(two.minimalTileStatus == "blocked")
        #expect(two.accessibilityLabel == "Laptop, 1 needs you, 1 working")

        let missing = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 0, done: 1)),
            hostID: "missing", hostSnapshot: twoHosts)
        #expect(missing.hasMultipleHosts)
        #expect(missing.hostLabel == nil)
        #expect(missing.minimalTileStatus == nil)
    }

    @Test func islandMinimalTileUsesTheMostUrgentCount() {
        let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: "host", name: "Laptop", label: "L"),
            .init(id: "other", name: "Oak4d", label: "O"),
        ])
        let cases: [(AgentActivityAttributes.ContentState.Counts, String)] = [
            (.init(working: 5, blocked: 1, done: 1), "blocked"),
            (.init(working: 5, blocked: 0, done: 1), "done"),
            (.init(working: 5, blocked: 0, done: 0), "working"),
        ]
        for (counts, status) in cases {
            let island = AgentActivityIslandPresentation(
                presentation: .countsOnly(counts: counts), hostID: "host", hostSnapshot: snapshot)
            #expect(island.minimalTileStatus == status)
        }
    }

    @Test func islandMissingLabelsOmitTilesButKeepTheFullAccessibilitySummary() {
        for label in [nil, ""] as [String?] {
            let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
                .init(id: "host", name: "Laptop", label: label),
                .init(id: "other", name: "Oak4d", label: "O"),
            ])
            let island = AgentActivityIslandPresentation(
                presentation: .countsOnly(counts: .init(working: 1, blocked: 2, done: 1)),
                hostID: "host", hostSnapshot: snapshot)
            #expect(island.hostLabel == nil)
            #expect(island.minimalTileStatus == nil)
            #expect(island.accessibilityLabel == "Laptop, 2 need you, 1 working, 1 done")
        }
        let noSnapshot = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: .init(working: 1, blocked: 1, done: 1)),
            hostID: "host", hostSnapshot: nil)
        #expect(noSnapshot.hostLabel == nil)
        #expect(noSnapshot.accessibilityLabel == "1 needs you, 1 working, 1 done")
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
        #expect(presentation.expandedAgents.count == 2)
        #expect(presentation.overflowCount == 3)
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

    /// The island clips its expanded content short of the 160 pt limit, which
    /// used to cut the overflow caption in half under two three-row Agents.
    @MainActor
    @Test func expandedIslandRowsStayInsideTheHeightTheIslandLeavesThem() throws {
        for count in [1, 2, 3, 5] {
            let presentation = configuredPresentation(agentCount: count)
            let rows = AgentActivityIslandRows(presentation: presentation, hostID: "host")
                .frame(width: 335)
            #expect(
                try renderedSize(rows).height <= AgentActivityIslandMetrics.rowsHeightBudget + 0.5,
                "\(count) agents")
        }
        let three = configuredPresentation(agentCount: 3)
        #expect(three.expandedAgents.count == 2)
        #expect(three.overflowCount == 1)
    }

    /// Larger text sizes grew the rows while the island stayed 160 pt tall.
    @MainActor
    @Test func expandedIslandRowsIgnoreLargerDynamicTypeSizes() throws {
        let rows = AgentActivityIslandRows(
            presentation: configuredPresentation(agentCount: 3), hostID: "host"
        )
        .frame(width: 335)
        let standard = try renderedSize(rows.environment(\.dynamicTypeSize, .large))
        let enlarged = try renderedSize(rows.environment(\.dynamicTypeSize, .accessibility3))
        #expect(enlarged.height == standard.height)
    }

    @MainActor
    @Test func compactAndMinimalIslandEvidenceFitsAtBothTypeSizes() throws {
        let oneHost = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: "host", name: "Laptop", label: "L"),
        ])
        let twoHosts = LiveActivityHostSnapshot(v: 1, hosts: oneHost.hosts + [
            .init(id: "oak", name: "Oak4d", label: "O"),
        ])
        let compactCases: [(String, AgentActivityAttributes.ContentState.Counts, LiveActivityHostSnapshot)] = [
            ("working", .init(working: 1, blocked: 0, done: 0), oneHost),
            ("mixed", .init(working: 1, blocked: 1, done: 1), oneHost),
            ("blocked", .init(working: 0, blocked: 1, done: 0), oneHost),
            ("overflow", .init(working: 7, blocked: 0, done: 0), oneHost),
            ("two-host-l", .init(working: 1, blocked: 1, done: 1), twoHosts),
            ("two-host-wide-overflow", .init(working: 5, blocked: 1, done: 1),
                LiveActivityHostSnapshot(v: 1, hosts: [
                    .init(id: "host", name: "10.0.180.255", label: "180.255"),
                    .init(id: "other", name: "10.0.181.255", label: "181.255"),
                ])),
        ]
        for size in [DynamicTypeSize.large, .accessibility3] {
            for (name, counts, snapshot) in compactCases {
                let island = AgentActivityIslandPresentation(
                    presentation: .countsOnly(counts: counts), hostID: "host", hostSnapshot: snapshot)
                let bitmap = try RenderedBitmap(
                    HStack(spacing: 0) {
                        AgentActivityCompactLeading(presentation: island)
                        Color.clear.frame(width: 126)
                        AgentActivityCompactTrailing(presentation: island)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 37)
                    .background(Color.black)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.colorScheme, .light),
                    proposedSize: .unspecified, scale: 2)
                #expect(bitmap.size.width <= 240, "\(name), \(size)")
                #expect(bitmap.size.height == 37)
                Attachment.record(try bitmap.image(),
                    named: "island-b2-compact-\(name)-\(size)", as: .png)
            }
            for (name, counts) in [
                ("single", AgentActivityAttributes.ContentState.Counts(working: 1, blocked: 0, done: 0)),
                ("mixed", .init(working: 1, blocked: 1, done: 1)),
                ("overflow", .init(working: 7, blocked: 0, done: 0)),
                ("done", .init(working: 0, blocked: 0, done: 1)),
            ] {
                for (hostCount, snapshot) in [(1, oneHost), (2, twoHosts)] {
                    let island = AgentActivityIslandPresentation(
                        presentation: .countsOnly(counts: counts), hostID: "host", hostSnapshot: snapshot)
                    let content = AgentActivityMinimal(presentation: island)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.colorScheme, .light)
                    let naturalSize = try renderedSize(content)
                    #expect(naturalSize.width <= 37)
                    #expect(naturalSize.height <= 37)
                    let bitmap = try RenderedBitmap(
                        content.frame(width: 37, height: 37).background(Color.black),
                        proposedSize: .unspecified, scale: 2)
                    Attachment.record(try bitmap.image(),
                        named: "island-b2-minimal-\(hostCount)-host-\(name)-\(size)", as: .png)
                }
            }
        }
    }

    @MainActor
    @Test func expandedIslandEvidenceIncludesHostHeadingsAndCompleteRows() throws {
        let hostCases = [
            ("laptop", "Laptop", "L"),
            ("long-name", "workstation-west-build-01", "W"),
            ("ip-name", "192.0.2.15", "15"),
        ]
        let statuses = ["blocked", "done", "working"]
        let agents = statuses.enumerated().map { index, status in
            var agent = agentDetail(paneID: "w1:p\(index)", status: status)
            agent.rows = [
                [.init(text: ["herdr", "arch", "docs"][index], bold: true)],
                [.init(text: ["Redesign live activity", "Fix sshd forwarding", "Update changelog"][index])],
            ]
            return agent
        }
        for (name, hostName, label) in hostCases {
            let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
                .init(id: "host", name: hostName, label: label),
                .init(id: "other", name: "Oak4d", label: "O"),
            ])
            let presentation = AgentActivityPresentation.detailed(
                details: .init(hostName: "envelope-fallback", agents: agents),
                counts: .init(working: 1, blocked: 1, done: 1))
            let island = AgentActivityIslandPresentation(
                presentation: presentation, hostID: "host", hostSnapshot: snapshot)
            #expect(island.hostName == hostName)
            #expect(island.hostLabel == label)
            #expect(presentation.expandedAgents.count == 3)
            var standardHeight: CGFloat?
            for size in [DynamicTypeSize.large, .accessibility3] {
                let rows = AgentActivityIslandRows(presentation: presentation, hostID: "host")
                    .frame(width: 321)
                    .environment(\.dynamicTypeSize, size)
                #expect(try renderedSize(rows).height <= 100)
                let bitmap = try RenderedBitmap(
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            AgentActivityIslandHeadline(presentation: island)
                            AgentActivityIslandHeaderTrailing(presentation: island)
                        }
                        rows
                    }
                    .padding(.horizontal, AgentActivityIslandMetrics.expandedSideMargin)
                    .padding(.top, 13)
                    .padding(.bottom, 13)
                    .frame(width: 371)
                    .background(Color.black)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\.colorScheme, .light),
                    proposedSize: .unspecified, scale: 2)
                #expect(bitmap.size.height <= 160)
                if let standardHeight {
                    #expect(bitmap.size.height == standardHeight)
                } else {
                    standardHeight = bitmap.size.height
                }
                Attachment.record(try bitmap.image(),
                    named: "island-b2-expanded-\(name)-\(size)", as: .png)
            }
        }
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

    @MainActor
    @Test func styledFieldsChangeRenderedPixelsOnBothSurfaces() throws {
        let plain = AgentActivityDetails.Field(text: "Feature branch")
        for surface in [AgentActivitySurface.lockScreen, .island] {
            let baseline = try rowPixels(field: plain, surface: surface)
            for styled in [
                AgentActivityDetails.Field(text: plain.text, fg: "#f00"),
                .init(text: plain.text, bold: true),
                .init(text: plain.text, dim: true),
            ] {
                #expect(try rowPixels(field: styled, surface: surface) != baseline)
            }
        }
    }

    @MainActor
    @Test func threeRowBannersFitTheLockScreenHeightBudget() throws {
        for count in [3, 4, 5] {
            for stale in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let banner = try lockScreenBitmap(
                        configuredPresentation(agentCount: count), scheme: scheme, stale: stale,
                        hostName: "workstation-west-build-01")
                    #expect(banner.size.height <= 160)
                    #expect(banner.size.height > 120)
                    Attachment.record(try banner.image(),
                        named: "lock-a2-three-fields-\(count)-agents-\(scheme)-stale-\(stale)", as: .png)
                }
            }
        }
    }

    @MainActor
    @Test func twoRowBannersFitTheLockScreenHeightBudget() throws {
        for count in [4, 5] {
            for stale in [false, true] {
                for scheme in [ColorScheme.light, .dark] {
                    let banner = try lockScreenBitmap(
                        configuredPresentation(agentCount: count, rowCount: 2), scheme: scheme,
                        stale: stale, hostName: "workstation-west-build-01")
                    #expect(banner.size.height <= 160)
                    #expect(banner.size.height > 120)
                    Attachment.record(try banner.image(),
                        named: "lock-a2-two-fields-\(count)-agents-\(scheme)-stale-\(stale)", as: .png)
                }
            }
        }
    }

    @MainActor
    @Test func lockScreenEvidenceCoversAppearancesHostNamesCountsAndStaleness() throws {
        for scheme in [ColorScheme.light, .dark] {
            for hostName in ["workstation-west-build-01", "192.0.2.15"] {
                for count in [1, 2, 3, 5] {
                    let agents = (0..<count).map { index in
                        agentDetail(paneID: "w1:p\(index)", status: ["working", "blocked", "done"][index % 3])
                    }
                    let presentation = AgentActivityPresentation.detailed(
                        details: .init(hostName: "envelope-fallback", agents: agents),
                        counts: .init(
                            working: agents.filter { $0.status == "working" }.count,
                            blocked: agents.filter { $0.status == "blocked" }.count,
                            done: agents.filter { $0.status == "done" }.count))
                    for stale in (count == 5 ? [false, true] : [false]) {
                        let banner = try lockScreenBitmap(
                            presentation, scheme: scheme, stale: stale, hostName: hostName)
                        #expect(banner.size.height <= 160)
                        #expect(banner.size.height >= 76)
                        Attachment.record(try banner.image(),
                            named: "lock-a2-\(scheme)-\(count)-agents-host-\(hostName)-stale-\(stale)", as: .png)
                    }
                }
                for stale in [false, true] {
                    let banner = try lockScreenBitmap(
                        .countsOnly(counts: .init(working: 2, blocked: 1, done: 0)),
                        scheme: scheme, stale: stale, hostName: hostName)
                    #expect(banner.size.height <= 160)
                    #expect(banner.size.height > 40)
                    Attachment.record(try banner.image(),
                        named: "lock-a2-\(scheme)-counts-only-host-\(hostName)-stale-\(stale)", as: .png)
                }
            }
            let unnamed = try lockScreenBitmap(
                .countsOnly(counts: .init(working: 0, blocked: 2, done: 1)),
                scheme: scheme, stale: false, hostName: nil)
            #expect(unnamed.size.height <= 160)
            Attachment.record(try unnamed.image(), named: "lock-a2-\(scheme)-counts-only-no-host", as: .png)
        }
    }

    @MainActor
    @Test func lockScreenContentLeavesTheBackgroundToActivityKit() throws {
        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try RenderedBitmap(
                AgentActivityLockScreenView(
                    presentation: detailedPresentation(
                        agentCount: 1, total: .init(working: 1, blocked: 0, done: 0)),
                    hostID: "host", isStale: false, hostSnapshot: nil)
                    .frame(width: 360)
                    .environment(\.colorScheme, scheme),
                proposedSize: .unspecified)
            #expect(bitmap.pixel(x: 0, y: 0).alpha == 0)
            #expect(bitmap.pixel(x: bitmap.width - 1, y: bitmap.height - 1).alpha == 0)
        }
    }

    @MainActor
    @Test func lockScreenBannerHonorsLargerDynamicTypeSizes() throws {
        let view = AgentActivityLockScreenView(
            presentation: configuredPresentation(agentCount: 1), hostID: "host", isStale: false,
            hostSnapshot: nil)
            .frame(width: 360)
        let standard = try RenderedBitmap(view.environment(\.dynamicTypeSize, .large), proposedSize: .unspecified)
        let enlarged = try RenderedBitmap(view.environment(\.dynamicTypeSize, .accessibility3), proposedSize: .unspecified)
        #expect(enlarged.size.height > standard.size.height)
    }

    @MainActor
    private func lockScreenBitmap(
        _ presentation: AgentActivityPresentation, scheme: ColorScheme, stale: Bool, hostName: String?
    ) throws -> RenderedBitmap {
        let snapshot = hostName.map { LiveActivityHostSnapshot(v: 1, hosts: [.init(id: "host", name: $0)]) }
        return try RenderedBitmap(
            AgentActivityLockScreenView(
                presentation: presentation, hostID: "host", isStale: stale, hostSnapshot: snapshot)
                .frame(width: 360)
                .background(scheme == .light ? Color.white : Color.black)
                .environment(\.colorScheme, scheme),
            proposedSize: .unspecified, scale: 2)
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

    @MainActor
    private func rowPixels(
        field: AgentActivityDetails.Field, surface: AgentActivitySurface
    ) throws -> RenderedBitmap {
        var agent = agentDetail(paneID: "w1:p1")
        agent.rows = [[field]]
        return try RenderedBitmap(
            AgentActivityRowView(agent: agent, surface: surface)
                .frame(width: 300, height: 50)
                .background(surface == .lockScreen ? Color.white : Color.black)
                .environment(\.colorScheme, surface == .lockScreen ? .light : .dark),
            proposedSize: .init(width: 300, height: 50))
    }

    @MainActor
    private func renderedSize(_ view: some View) throws -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        return try #require(renderer.uiImage).size
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
