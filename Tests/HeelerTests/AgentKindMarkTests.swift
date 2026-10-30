import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Agent kind mark")
struct AgentKindMarkTests {
    /// Every kind Heeler starts has a decision, its assets resolve, and its
    /// name is the one notifications use.
    @Test(arguments: SupportedAgentKind.allCases)
    func everyKindHasAMarkOrAMonogram(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind.rawValue)
        #expect(mark.label == AgentNotificationIdentity.kindLabel(kind.rawValue))
        #expect(mark.monogram == String(mark.label.prefix(1)).uppercased())
        guard let artwork = mark.artwork else { return }
        let template = try #require(UIImage(named: artwork.template), "\(artwork.template)")
        #expect(template.renderingMode == .alwaysTemplate)
        if let art = artwork.art {
            let image = try #require(UIImage(named: art), "\(art)")
            #expect(image.renderingMode != .alwaysTemplate)
        }
    }

    @Test func onlyKindsWithoutAPublishedMarkFallBackToTheirInitial() {
        let unmarked = SupportedAgentKind.allCases.filter { AgentKindMark.artwork(for: $0) == nil }
        #expect(Set(unmarked) == [.droid, .pi, .omp, .maki, .muse])
    }

    /// herdr's kind is matched as `kindLabel` matches it; a kind this build
    /// does not know keeps its own word's initial.
    @Test func kindsMatchCaseInsensitivelyAndUnknownKindsTakeTheirInitial() {
        let claude = AgentKindMark(kind: "claude")
        #expect(AgentKindMark(kind: "Claude").artwork == claude.artwork)
        #expect(AgentKindMark(kind: " codex\n").artwork != nil)
        #expect(AgentKindMark(kind: "agy").label == "Antigravity")
        let future = AgentKindMark(kind: "future-cli")
        #expect(future.artwork == nil)
        #expect(future.monogram == "F")
        #expect(AgentKindMark(kind: "").label == "Unknown")
        #expect(AgentKindMark(kind: "").monogram == "U")
    }

    /// Art drawn for a light tile has its own dark-appearance variant.
    @Test(arguments: ["AgentArt/kiro", "AgentArt/qwen", "AgentArt/qodercli"])
    func darkArtDiffersFromLightArt(name: String) throws {
        func pixels(_ style: UIUserInterfaceStyle) throws -> Data {
            let image = try #require(
                UIImage(named: name, in: nil, compatibleWith: UITraitCollection(userInterfaceStyle: style)))
            let size = CGSize(width: 24, height: 24)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        #expect(try pixels(.dark) != pixels(.light))
    }
}

/// Where an Agent card puts its mark, text, and status.
@MainActor
@Suite("Agent card status ring", .timeLimit(.minutes(1)))
struct AgentCardStatusRingTests {
    private static let layout = AgentRowLayout(rows: [
        [.init(.terminalTitleStripped)], [.init(.workspace), .init(.agent)],
    ])
    /// `layout` with the status capsule ending Row 1.
    private static let badgedLayout = AgentRowLayout(rows: layout.rows, trailing: [[.init(.statusBadge)], [], []])

    private static func agent(kind: String = "claude", status: AgentStatus = .working) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(),
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_a", kind: kind, title: "Fix the flaky test",
                status: status, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/work/proj", revision: 3, terminalTitleStripped: "Fix the flaky test"),
            workspaceLabel: "proj",
            repositoryCheckout: nil)
    }

    private static func host(_ card: AgentCardView) async throws -> (UIView, UIWindow) {
        let controller = UIHostingController(
            rootView: card
                .frame(width: 402)
                .fixedSize(horizontal: false, vertical: true))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 400), rootViewController: controller)
        controller.view.layoutIfNeeded()
        return (controller.view, window)
    }

    /// A list row leads with a 34-point avatar whose ring alone shows the
    /// status, so VoiceOver hears it with the program; the kind word the
    /// mark names is gone.
    @Test func theRingCarriesTheStatusByDefault() async throws {
        let (root, window) = try await Self.host(AgentCardView(agent: Self.agent(), layout: Self.layout))
        defer { window.isHidden = true }
        let avatar = try #require(AccessibilityProbe.frame(labeled: "Claude, Working", in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        // The ring's open arc can draw inside the avatar's 34 points.
        #expect(avatar.minX >= -0.5 && avatar.maxX <= 34.5, "\(avatar)")
        #expect(abs(title.minX - 46) <= 0.5, "\(title)")
        #expect(AccessibilityProbe.frame(labeled: "Working", in: root) == nil)
        let labels = AccessibilityProbe.labels(in: root)
        #expect(labels.contains("proj") && !labels.contains("proj · claude"), "\(labels)")
    }

    /// A status the ring has no shape for still shows no text; VoiceOver
    /// reads it with the program.
    @Test func aStatusWithoutItsOwnRingStillShowsNoText() async throws {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(status: AgentStatus(rawValue: "paused")), layout: Self.layout))
        defer { window.isHidden = true }
        #expect(AccessibilityProbe.frame(labeled: "Claude, Paused", in: root) != nil)
        #expect(AccessibilityProbe.frame(labeled: "Paused", in: root) == nil)
    }

    /// The capsule is a field: a row shows it where the layout puts it, and
    /// the ring then leaves the status to it.
    @Test func theStatusBadgeFollowsTheFields() async throws {
        let (root, window) = try await Self.host(AgentCardView(agent: Self.agent(), layout: Self.badgedLayout))
        defer { window.isHidden = true }
        let badge = try #require(AccessibilityProbe.frame(labeled: "Working", in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        #expect(abs(badge.midY - title.midY) <= 1, "\(badge) does not end \(title)'s line")
        #expect(AccessibilityProbe.frame(labeled: "Claude", in: root) != nil)
    }

    /// A status field the Agent List Fields choose shows as text beside the
    /// ring; leaving it out is the way to hide it.
    @Test func aChosenStatusFieldShowsAsText() async throws {
        let layout = AgentRowLayout(rows: [[.init(.terminalTitleStripped)], [.init(.workspace), .init(.status)]])
        let (root, window) = try await Self.host(AgentCardView(agent: Self.agent(), layout: layout))
        defer { window.isHidden = true }
        let labels = AccessibilityProbe.labels(in: root)
        #expect(labels.contains("proj · Working"), "\(labels)")
    }

    /// Done and Blocked share a closed ring told apart by color, so Blocked
    /// breaks into dashes where color must not carry it alone.
    @Test func blockedDashesItsRingWhereColorCannotCarryIt() {
        func rings(_ differentiating: Bool) -> [AgentStatusAvatar.Ring] {
            [.working, .done, .blocked, .idle, .unknown, AgentStatus(rawValue: "paused")].map {
                AgentStatusAvatar.ring(for: $0, differentiatingWithoutColor: differentiating)
            }
        }
        #expect(rings(false) == [.turning, .closed, .closed, .hairline, .hairline, .hairline])
        #expect(rings(true) == [.turning, .closed, .dashed, .hairline, .hairline, .hairline])
    }

    /// In a Workspace card the avatar fills the card's icon column.
    @Test func aCardRowsMarkFillsTheIconColumn() async throws {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(kind: "droid"), layout: Self.layout, lead: .card))
        defer { window.isHidden = true }
        let mark = try #require(AccessibilityProbe.frame(labeled: "Droid, Working", in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        #expect(mark.minX >= -0.5 && mark.maxX <= 28.5, "\(mark)")
        #expect(abs(title.minX - 40) <= 0.5, "\(title)")
        // Droid has no mark, so its row still names it.
        #expect(AccessibilityProbe.labels(in: root).contains("proj · droid"))
    }
}
