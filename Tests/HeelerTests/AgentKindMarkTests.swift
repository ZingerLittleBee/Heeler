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
        #expect(Set(unmarked) == [.droid, .maki, .muse])
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

    @MainActor
    @Test(arguments: SupportedAgentKind.allCases)
    func everyKindRendersANonEmptyMenuImage(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind)
        let expectedSize = AgentKindMark.menuImageSize
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = mark.menuImage(style: style)
            #expect(image.size == expectedSize)
            if mark.artwork?.art != nil || mark.artwork?.tint != nil {
                #expect(image.renderingMode == .alwaysOriginal)
            } else {
                #expect(image.renderingMode == .alwaysTemplate)
            }
            let cgImage = try #require(image.cgImage)
            #expect(Self.hasNonTransparentPixels(cgImage), "\(kind.rawValue) (\(style.rawValue))")
        }
    }

    @MainActor
    @Test(arguments: [SupportedAgentKind.kiro, .qwen, .qodercli])
    func appearanceSensitiveMenuImagesDifferBetweenLightAndDark(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind)
        let light = try #require(mark.menuImage(style: .light).pngData())
        let dark = try #require(mark.menuImage(style: .dark).pngData())
        #expect(light != dark)
    }

    @MainActor
    @Test func newAgentMenuItemsShowEachAgentKindsIcon() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [],
                workspaces: [.fixture(workspaceID: "w1", label: "proj")]))
        let kinds: [SupportedAgentKind] = [.pi, .claude, .codex, .cursor, .antigravity, .omp, .opencode]
        await transport.setAvailableAgentKinds(kinds)

        let presetDefaultsName = "start-agent-icon-test-\(UUID().uuidString)"
        let presetDefaults = try #require(UserDefaults(suiteName: presetDefaultsName))
        presetDefaults.removePersistentDomain(forName: presetDefaultsName)
        defer { presetDefaults.removePersistentDomain(forName: presetDefaultsName) }
        let presetStore = LaunchPresetStore(defaults: presetDefaults)
        _ = try presetStore.save(LaunchPreset(name: "Work", kind: .claude))

        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            launchPresets: presetStore,
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { transport },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(20)),
                    keepalive: nil)
            })
        console.setHosts([host])
        defer { console.setHosts([]) }

        let controller = UIHostingController(
            rootView: StartAgentView(hosts: [host], console: console, onStarted: { _ in }))
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 1000),
            rootViewController: controller
        ) { window in
            var budget = PollBudget(.seconds(5))
            while Self.formPicker(identifiedBy: "startAgent.agent", labeled: "Agent", in: window) == nil,
                budget.hasTimeLeft
            {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }

            let expectedSize = AgentKindMark.menuImageSize
            let agentActions = try await Self.openFormPickerActions(
                identifiedBy: "startAgent.agent", labeled: "Agent", in: window)
            #expect(agentActions.map(\.title) == kinds.map(\.displayName) + ["Work · Claude Code"])
            for action in agentActions {
                #expect(action.size == expectedSize, "\(action.title) missing menu icon")
            }

            try await Self.selectFormPickerAction(
                "Work · Claude Code", identifiedBy: "startAgent.agent", labeled: "Agent", in: window)
            budget = PollBudget(.seconds(5))
            while Self.formPicker(identifiedBy: "startAgent.preset", labeled: "Preset", in: window) == nil,
                budget.hasTimeLeft
            {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }

            let presetActions = try await Self.openFormPickerActions(
                identifiedBy: "startAgent.preset", labeled: "Preset", in: window)
            #expect(presetActions.map(\.title) == ["None", "Work"])
            #expect(presetActions.first { $0.title == "None" }?.size == nil)
            #expect(presetActions.first { $0.title == "Work" }?.size == expectedSize)
        }
    }

    @MainActor
    private static func formPicker(
        identifiedBy identifier: String, labeled label: String, in window: UIWindow
    ) -> NSObject? {
        accessibleElements(in: window).first { element in
            guard !element.accessibilityTraits.contains(.header), !element.accessibilityFrame.isEmpty else {
                return false
            }
            var current: UIView? =
                (element as? UIView)
                ?? ((element as? UIAccessibilityElement)?.accessibilityContainer as? UIView)
            while let view = current {
                if view.isHidden || view.alpha == 0 { return false }
                current = view.superview
            }
            if (element as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier {
                return true
            }
            guard let elementLabel = element.accessibilityLabel else { return false }
            return elementLabel == label || elementLabel.hasPrefix("\(label),")
        }
    }

    @MainActor
    private static func openFormPickerMenu(
        identifiedBy identifier: String, labeled label: String, in window: UIWindow
    ) async throws -> (controller: UIViewController, menu: UIMenu) {
        let row = try #require(formPicker(identifiedBy: identifier, labeled: label, in: window))
        let rowFrame = row.accessibilityFrame
        func buttons(in view: UIView) -> [UIButton] {
            var found: [UIButton] = []
            if let button = view as? UIButton, button.menu != nil { found.append(button) }
            for subview in view.subviews { found += buttons(in: subview) }
            return found
        }
        let button = try #require(
            buttons(in: window).first {
                UIAccessibility.convertToScreenCoordinates($0.bounds, in: $0).intersects(rowFrame)
            })
        _ = button.accessibilityActivate() || row.accessibilityActivate()
        var budget = PollBudget(.seconds(5))
        while budget.hasTimeLeft {
            if let presented = window.rootViewController?.presentedViewController,
                let menu = button.menu,
                !menu.children.isEmpty,
                !menu.children.contains(where: { $0 is UIDeferredMenuElement })
            {
                return (presented, menu)
            }
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        Issue.record("Timed out opening \(label) menu")
        throw CancellationError()
    }

    @MainActor
    private static func openFormPickerActions(
        identifiedBy identifier: String, labeled label: String, in window: UIWindow
    ) async throws -> [(title: String, size: CGSize?)] {
        let opened = try await openFormPickerMenu(identifiedBy: identifier, labeled: label, in: window)
        let actions = leafActions(of: opened.menu)
        opened.controller.dismiss(animated: false)
        var budget = PollBudget(.seconds(5))
        while window.rootViewController?.presentedViewController != nil, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        return actions
    }

    @MainActor
    private static func selectFormPickerAction(
        _ title: String, identifiedBy identifier: String, labeled label: String, in window: UIWindow
    ) async throws {
        let opened = try await openFormPickerMenu(identifiedBy: identifier, labeled: label, in: window)
        func leaf(in menu: UIMenu) -> (any UIMenuLeaf)? {
            for child in menu.children {
                if let section = child as? UIMenu, let found = leaf(in: section) { return found }
                if child.title == title, let item = child as? any UIMenuLeaf { return item }
            }
            return nil
        }
        let chosen = try #require(leaf(in: opened.menu))
        opened.controller.dismiss(animated: false)
        var budget = PollBudget(.seconds(5))
        while window.rootViewController?.presentedViewController != nil, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(20))
            budget.charge()
        }
        chosen.performWithSender(nil, target: nil)
    }

    private static func leafActions(of menu: UIMenu) -> [(title: String, size: CGSize?)] {
        menu.children.flatMap { child -> [(title: String, size: CGSize?)] in
            if let section = child as? UIMenu {
                return leafActions(of: section)
            }
            if let leaf = child as? any UIMenuLeaf {
                return [(title: leaf.title, size: leaf.image?.size)]
            }
            return [(title: child.title, size: nil)]
        }
    }

    private static func hasNonTransparentPixels(_ cgImage: CGImage) -> Bool {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
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
            [.working, .done, .blocked, .error, .idle, .unknown, AgentStatus(rawValue: "paused")].map {
                AgentStatusAvatar.ring(for: $0, differentiatingWithoutColor: differentiating)
            }
        }
        #expect(rings(false) == [.turning, .closed, .closed, .closed, .hairline, .hairline, .hairline])
        #expect(rings(true) == [.turning, .closed, .dashed, .dashed, .hairline, .hairline, .hairline])
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
