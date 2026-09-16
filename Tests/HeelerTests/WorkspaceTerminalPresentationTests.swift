import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("Workspace terminal presentation", .serialized, .timeLimit(.minutes(1)))
struct WorkspaceTerminalPresentationTests {
    @Test func drawerListsTerminalsInTabOrder() {
        #expect(WorkspaceTerminalDrawer.ordered(Self.terminals()).map(\.paneID) == ["agent", "server", "tests"],
                "Tab order, then Pane order, whatever the snapshot order")
    }

    @Test(arguments: [0.0, 1.0])
    func drawerHandleRestsWhereItWasLastDocked(fraction: Double) async throws {
        guard #available(iOS 27, *) else { return }
        let suite = "WorkspaceTerminalPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let edgeDock = EdgeDockSettings(defaults: defaults)
        edgeDock.setFraction(fraction, for: .workspaceDrawer)
        let height: CGFloat = 640
        let controller = UIHostingController(rootView:
            WorkspaceTerminalDrawer(
                terminals: Self.terminals(), selectedPaneID: "agent",
                edgeDock: edgeDock, onSelect: { _ in }))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: height), rootViewController: controller)
        defer { window.isHidden = true }
        let handle = try await accessible("Workspace terminals", in: controller.view)
        let frame = Self.frame(of: handle, in: controller.view)
        if fraction == 0 {
            #expect(frame.minY == 0, "Docked at the top: \(frame)")
        } else {
            #expect(frame.maxY == height, "Docked at the bottom: \(frame)")
        }
    }

    @Test func drawerRestsAsOneEdgeHandleAndExpandsToRouteTerminals() async throws {
        // Existing hosting tests use this boundary: older runtimes do not
        // materialize SwiftUI AX elements without an assistive client.
        guard #available(iOS 27, *) else { return }
        var selected: [ConsoleTerminal.ID] = []
        let terminals = Self.terminals()
        let controller = UIHostingController(rootView:
            WorkspaceTerminalDrawer(
                terminals: terminals, selectedPaneID: "agent",
                edgeDock: EdgeDockSettings(defaults: try #require(UserDefaults(suiteName: "WorkspaceTerminalPresentationTests.routing"))),
                onSelect: { selected.append($0.id) }))
        controller.safeAreaRegions = []
        let width: CGFloat = 320
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 640), rootViewController: controller)
        defer { window.isHidden = true }

        // Collapsed: only the handle, docked to the trailing edge.
        let handle = try await accessible("Workspace terminals", in: controller.view)
        #expect(handle.accessibilityValue == "3 terminals")
        let handleFrame = Self.frame(of: handle, in: controller.view)
        #expect(handleFrame.maxX == width, "Docked to the trailing edge: \(handleFrame)")
        #expect(handleFrame.width >= 44)
        #expect(handleFrame.height >= 44)
        #expect(handleFrame.width <= WorkspaceTerminalDrawer.handleHitWidth)
        #expect(Self.elements(in: controller.view)
            .contains { $0.accessibilityLabel == "Terminal, Dev server" } == false,
            "Rows stay hidden until the handle is tapped")

        // Expanded: every Workspace terminal, in Tab order, current one marked.
        #expect(handle.accessibilityActivate())
        let agent = try await accessible("Agent, Code review", in: controller.view)
        let sameTab = try await accessible("Terminal, Dev server", in: controller.view)
        let otherTab = try await accessible("Terminal, Tests", in: controller.view)
        #expect(agent.accessibilityTraits.contains(.selected))
        #expect(!sameTab.accessibilityTraits.contains(.selected))
        #expect(!otherTab.accessibilityTraits.contains(.selected))
        #expect(agent.accessibilityValue == "Development")
        #expect(otherTab.accessibilityValue == "Checks")
        // The panel slides in; read the rows once it has settled on screen.
        var frames: [CGRect] = []
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            frames = [agent, sameTab, otherTab].map { Self.frame(of: $0, in: controller.view) }
            if frames.allSatisfy({ $0.maxX <= width }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        for frame in frames {
            #expect(frame.height >= WorkspaceTerminalDrawer.rowHeight)
            #expect(frame.maxX <= width, "Panel settled inside the window: \(frame)")
            #expect(frame.minX >= width - WorkspaceTerminalDrawer.panelWidth)
        }
        #expect(frames[0].minY < frames[1].minY)
        #expect(frames[1].minY < frames[2].minY, "Rows run top to bottom in Tab order")

        #expect(otherTab.accessibilityActivate())
        #expect(selected == [terminals[0].id])
    }

    @Test(arguments: [320.0, 402.0])
    func consoleTitleOffersBothModesAtCompactWidths(width: Double) async throws {
        let composition = DemoScreenshotComposition.make()
        // Leave Console suspended. Merely displaying navigation must not
        // connect a Host or create an attach channel.
        let controller = UIHostingController(rootView: ConsoleView(
            hosts: composition.hosts, console: composition.console,
            terminal: TerminalSettings(
                themes: composition.terminalThemes, zoom: composition.terminalZoom,
                fonts: composition.terminalFonts, snippets: composition.snippets),
            inputMode: composition.inputMode, appearance: composition.appearance,
            pushRegistration: composition.pushRegistration,
            notificationPreferences: composition.notificationPreferences,
            relaySettings: composition.relaySettings,
            notificationRouter: composition.notificationRouter,
            bannerStore: composition.bannerStore, liveActivities: composition.liveActivities,
            activity: composition.activity))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 874), rootViewController: controller)
        defer { window.isHidden = true }
        var picker: UISegmentedControl?
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            picker = Self.segmentedControl(in: controller.view)
            if picker != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let control = try #require(picker)
        #expect(control.numberOfSegments == 2)
        #expect(control.titleForSegment(at: 0) == "Agents")
        #expect(control.titleForSegment(at: 1) == "Terminals")
        let frame = control.convert(control.bounds, to: controller.view)
        #expect(frame.width >= 150, "Both mode names need room: \(frame)")
        #expect(controller.view.bounds.contains(frame), "Mode picker must remain visible: \(frame)")
        if #available(iOS 27, *) {
            for label in ["Console options", "New Agent"] {
                if let action = Self.elements(in: controller.view).first(where: {
                    $0.accessibilityLabel == label && !$0.accessibilityElementsHidden
                }) {
                    let actionFrame = Self.frame(of: action, in: controller.view)
                    if actionFrame.width > 0, actionFrame.height > 0 {
                        #expect(!frame.intersects(actionFrame),
                                "Mode picker overlaps \(label): \(frame), \(actionFrame)")
                    }
                }
            }
        }
        control.selectedSegmentIndex = 1
        control.sendActions(for: .valueChanged)
        controller.view.layoutIfNeeded()
        #expect(composition.notificationRouter.path.isEmpty)
        #expect(composition.console.terminalConnections.entries.isEmpty)
    }

    private func accessible(_ label: String, in root: UIView) async throws -> NSObject {
        for _ in 0..<40 {
            root.layoutIfNeeded()
            if let element = Self.elements(in: root).first(where: { $0.accessibilityLabel == label }) {
                return element
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(nil as NSObject?, "Missing accessibility element: \(label)")
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                  !node.accessibilityElementsHidden else { return }
            result.append(node)
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }

    private static func frame(of element: NSObject, in root: UIView) -> CGRect {
        if let view = element as? UIView { return view.convert(view.bounds, to: root) }
        return root.convert(element.accessibilityFrame, from: nil)
    }

    private static func segmentedControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl,
           control.titleForSegment(at: 0) == "Agents" { return control }
        return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
    }

    private static func terminals() -> [ConsoleTerminal] {
        let host = Host.fixture()
        func terminal(
            _ id: String, tab: String, label: String, order: Int, agent: String? = nil
        ) -> ConsoleTerminal {
            ConsoleTerminal(
                hostID: host.id, hostName: host.displayName, hostUsername: host.username,
                pane: PaneInfo(
                    agentStatus: .idle, focused: false, paneID: id, revision: 1,
                    tabID: tab, terminalID: "term-\(id)", workspaceID: "workspace",
                    agent: agent, cwd: "/project", label: label),
                workspaceLabel: "Project", tabLabel: tab == "tab-one" ? "Development" : "Checks",
                workspaceOrder: 0, tabPosition: tab == "tab-one" ? 1 : 2,
                snapshotOrder: order, snapshotAgentKind: agent)
        }
        // Snapshot order deliberately disagrees with Tab order.
        return [
            terminal("tests", tab: "tab-two", label: "Tests", order: 0),
            terminal("agent", tab: "tab-one", label: "Code review", order: 1, agent: "claude"),
            terminal("server", tab: "tab-one", label: "Dev server", order: 2),
        ]
    }
}
