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

@MainActor
@Suite("Agent list row style settings")
struct AgentListRowStyleSettingsTests {
    private static let key = "console-list.row-style"

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-agent-row-style-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func defaultsToTiles() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        #expect(AgentListRowStyleSettings(defaults: defaults).style == .tile)
        #expect(EnvironmentValues().agentListRowStyle == .tile)
    }

    @Test func chosenStyleIsRememberedAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentListRowStyleSettings(defaults: defaults)

        settings.select(.statusRing)

        #expect(settings.style == .statusRing)
        #expect(AgentListRowStyleSettings(defaults: defaults).style == .statusRing)

        settings.select(.tile)

        #expect(AgentListRowStyleSettings(defaults: defaults).style == .tile)
    }

    @Test func unknownStoredStyleFallsBackToTiles() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set("compact", forKey: Self.key)

        #expect(AgentListRowStyleSettings(defaults: defaults).style == .tile)
    }

    @Test func reselectingTheCurrentStyleWritesNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        AgentListRowStyleSettings(defaults: defaults).select(.tile)

        #expect(defaults.object(forKey: Self.key) == nil)
    }
}

/// Where each row style puts an Agent card's mark, text, and status.
@MainActor
@Suite("Agent card row style", .timeLimit(.minutes(1)))
struct AgentCardRowStyleTests {
    private static let layout = AgentRowLayout(rows: [
        [.init(.terminalTitleStripped)], [.init(.workspace), .init(.agent)],
    ])

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

    private static func host(
        _ card: AgentCardView, style: AgentListRowStyle
    ) async throws -> (UIView, UIWindow) {
        let controller = UIHostingController(
            rootView: AnyView(
                card
                    .environment(\.agentListRowStyle, style)
                    .frame(width: 402)
                    .fixedSize(horizontal: false, vertical: true)))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 400), rootViewController: controller)
        controller.view.layoutIfNeeded()
        return (controller.view, window)
    }

    /// A list row leads with a 30-point tile, its text 12 points past it,
    /// and keeps the status capsule; the kind word the tile names is gone.
    @Test func aTileLeadsTheRowAndTheCapsuleStays() async throws {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(), layout: Self.layout), style: .tile)
        defer { window.isHidden = true }
        let tile = try #require(AccessibilityProbe.frame(labeled: "Claude", in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        #expect(abs(tile.minX) <= 0.5 && abs(tile.width - 30) <= 0.5, "\(tile)")
        #expect(abs(title.minX - 42) <= 0.5, "\(title)")
        #expect(abs(tile.midY - title.midY) <= 1, "\(tile) is not centered on \(title)")
        #expect(AccessibilityProbe.frame(labeled: "Working", in: root) != nil)
        let labels = AccessibilityProbe.labels(in: root)
        #expect(labels.contains("proj") && !labels.contains("proj · claude"), "\(labels)")
    }

    /// The ring takes the capsule's place, so VoiceOver hears the status
    /// with the program.
    @Test func aRingCarriesTheStatusInPlaceOfTheCapsule() async throws {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(), layout: Self.layout), style: .statusRing)
        defer { window.isHidden = true }
        let avatar = try #require(AccessibilityProbe.frame(labeled: "Claude, Working", in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        // The ring's open arc can draw inside the avatar's 34 points.
        #expect(avatar.minX >= -0.5 && avatar.maxX <= 34.5, "\(avatar)")
        #expect(abs(title.minX - 46) <= 0.5, "\(title)")
        #expect(AccessibilityProbe.frame(labeled: "Working", in: root) == nil)
    }

    /// A status the ring has no shape for still shows no text; VoiceOver
    /// reads it with the program.
    @Test func aStatusWithoutItsOwnRingStillShowsNoText() async throws {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(status: AgentStatus(rawValue: "paused")), layout: Self.layout),
            style: .statusRing)
        defer { window.isHidden = true }
        #expect(AccessibilityProbe.frame(labeled: "Claude, Paused", in: root) != nil)
        #expect(AccessibilityProbe.frame(labeled: "Paused", in: root) == nil)
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

    /// In a Workspace card the mark fills the card's icon column, which the
    /// Status Ring style widens to its avatar.
    @Test(arguments: [(AgentListRowStyle.tile, CGFloat(20), CGFloat(30)), (.statusRing, 28, 40)])
    func aCardRowsMarkFillsTheIconColumn(style: AgentListRowStyle, column: CGFloat, text: CGFloat)
        async throws
    {
        let (root, window) = try await Self.host(
            AgentCardView(agent: Self.agent(kind: "droid"), layout: Self.layout, lead: .card), style: style)
        defer { window.isHidden = true }
        let label = style == .tile ? "Droid" : "Droid, Working"
        let mark = try #require(AccessibilityProbe.frame(labeled: label, in: root))
        let title = try #require(AccessibilityProbe.frame(labeled: "Fix the flaky test", in: root))
        #expect(mark.minX >= -0.5 && mark.maxX <= column + 0.5, "\(mark)")
        #expect(abs(title.minX - text) <= 0.5, "\(title)")
        // Droid has no mark, so its row still names it.
        #expect(AccessibilityProbe.labels(in: root).contains("proj · droid"))
    }
}
