import Foundation
import Testing
import SwiftUI
import UIKit

@testable import Heeler

/// The keyboard's Agent switcher: the strip of chips above the input row that
/// swaps the attached Agent without a trip back to the Console.
@Suite("Agent switcher")
struct TerminalAgentSwitcherTests {
    private static func makeAgent(
        pane: String,
        workspace: String? = nil,
        repo: String? = nil,
        name: String? = nil,
        status: AgentStatus = .idle,
        host: UUID = UUID()
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: "claude", title: "",
                status: status, workspaceID: "w", tabID: "w:t", paneID: pane,
                cwd: "/work", revision: 1, name: name),
            workspaceLabel: workspace,
            repoName: repo,
            lastOutputSnippet: nil)
    }

    private static func makeItem(
        _ agent: ConsoleAgent, status: AgentStatus? = nil, isPinned: Bool = false
    ) -> TerminalAgentSwitcherItem {
        TerminalAgentSwitcherItem(
            id: agent.id, title: agent.switcherLabel,
            status: status ?? agent.agent.status, isPinned: isPinned)
    }

    /// The project is what tells a console full of `claude` apart, so it
    /// leads; the agent's own name is the fallback when nothing named the
    /// workspace.
    @Test func chipLabelsPreferTheProject() {
        #expect(Self.makeAgent(pane: "p1", workspace: "proj", repo: "repo").switcherLabel == "proj")
        #expect(Self.makeAgent(pane: "p2", repo: "repo").switcherLabel == "repo")
        #expect(Self.makeAgent(pane: "p3", name: "reviewer").switcherLabel == "reviewer")
        #expect(Self.makeAgent(pane: "p4").switcherLabel == "claude")
    }

    /// The keyboard row carries typing controls only. The keyboard toggle
    /// moved to the Agent strip, which outlives the keyboard — a control that
    /// summons the keyboard back cannot live on the keyboard itself.
    @MainActor
    @Test func theKeyboardRowCarriesTypingControlsAlone() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)
        accessory.frame = CGRect(
            x: 0, y: 0, width: 402, height: TerminalKeyboardAccessory.preferredHeight)
        accessory.layoutIfNeeded()

        #expect(
            TerminalKeyboardAccessory.preferredHeight
                == TerminalKeyboardAccessory.inputRowHeight)
        for control in [accessory.pasteControl, accessory.newLineButton] as [UIView] {
            let frame = accessory.convert(control.bounds, from: control)
            #expect(frame.maxY <= TerminalKeyboardAccessory.preferredHeight)
        }
        // Paste anchors the leading edge, new line the trailing one, with the
        // mode control centred between them.
        #expect(accessory.pasteControl.frame.minX == 8)
        #expect(accessory.newLineButton.frame.maxX == accessory.bounds.width - 8)
        #expect(accessory.pasteControl.frame.maxX < accessory.newLineButton.frame.minX)
        #expect(Self.keyboardToggles(in: accessory).isEmpty)
    }

    private static func firstStrip(in view: UIView) -> TerminalAgentSwitcherBar? {
        if let strip = view as? TerminalAgentSwitcherBar { return strip }
        for subview in view.subviews {
            if let strip = firstStrip(in: subview) { return strip }
        }
        return nil
    }

    private static func keyboardToggles(in view: UIView) -> [UIView] {
        let labels: Set<String> = ["Dismiss keyboard", "Show keyboard"]
        let matches = view.subviews.flatMap { keyboardToggles(in: $0) }
        guard let label = view.accessibilityLabel, labels.contains(label) else {
            return matches
        }
        return matches + [view]
    }

    /// The strip is a scroll view whose content is as wide as its chips, so
    /// asked how big it wants to be it answers with the whole list. Mounted in
    /// SwiftUI without an answer of its own, that measurement is what SwiftUI
    /// lays out against — pushing the pinned toggle off the screen's edge.
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func theStripTakesTheWidthItIsGivenRatherThanItsChips() throws {
        let host = UUID()
        let agents = (0..<10).map {
            Self.makeAgent(
                pane: "p\($0)", workspace: "a-project-with-a-long-name-\($0)", host: host)
        }
        let row = TerminalAgentSwitcherRow(
            switcher: TerminalAgentSwitcher(
                items: agents.map { Self.makeItem($0) },
                // The Agent the user switched to is at the far end of the
                // strip, so opening it has to scroll — the case that hangs.
                selectedID: agents[9].id,
                onSelect: { _ in },
                onTogglePin: { _ in }),
            isKeyboardUp: true,
            toggleKeyboard: {},
            switchKeyboard: {})
        let controller = UIHostingController(rootView: row)
        let width: CGFloat = 402
        let window = try makeWindow(width: width, rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.frame = CGRect(
            x: 0, y: 0, width: width, height: TerminalAgentSwitcherBar.preferredHeight)
        controller.view.layoutIfNeeded()

        let measured = controller.sizeThatFits(in: CGSize(width: width, height: 40))
        #expect(measured.width <= width, "the strip demanded \(measured.width) of \(width)")

        // The strip has to stop short of the row's trailing edge, or the
        // toggle pinned beside it has nowhere left to sit.
        let strip = try #require(Self.firstStrip(in: controller.view))
        let stripFrame = strip.convert(strip.bounds, to: controller.view)
        #expect(stripFrame.width > 0)
        #expect(
            stripFrame.maxX <= width - 88,
            "the strip claimed \(stripFrame.maxX) of \(width), leaving no room for both toggles")
    }

    @MainActor
    private func makeWindow(
        width: CGFloat, rootViewController: UIViewController
    ) throws -> UIWindow {
        let window = UIWindow(
            frame: CGRect(x: 0, y: 0, width: width, height: 700))
        window.rootViewController = rootViewController
        window.isHidden = false
        return window
    }

    @MainActor
    @Test func chipsFollowTheAgentListAndMarkTheOpenOne() throws {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", status: .blocked, host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", status: .working, host: host),
        ]
        let bar = TerminalAgentSwitcherBar()

        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[1].id)

        #expect(bar.chips.map(\.id) == agents.map(\.id))
        #expect(bar.chips.map(\.title) == ["alpha", "beta"])
        #expect(bar.chips.map(\.isSelected) == [false, true])
        let blocked = try #require(bar.chips.first)
        #expect(blocked.accessibilityValue == "Blocked")
        #expect(blocked.accessibilityHint == "Switches to that Agent")
        #expect(bar.chips[1].accessibilityHint == nil)
    }

    @MainActor
    @Test func tappingAChipSwitchesAgentsAndTappingTheOpenOneDoesNot() {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", host: host),
        ]
        var opened: [ConsoleAgent.ID] = []
        let bar = TerminalAgentSwitcherBar()
        bar.onSelect = { opened.append($0) }
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[0].id)

        bar.chips[1].sendActions(for: .touchUpInside)
        #expect(opened == [agents[1].id])

        // The Agent already on screen is not a destination; re-attaching it
        // would tear down the terminal the user is typing into.
        bar.chips[0].sendActions(for: .touchUpInside)
        #expect(opened == [agents[1].id])
    }

    /// Switcher chips inherit pin state from the same store the Console list
    /// uses, so a pin made on one surface shows up on the other.
    @MainActor
    @Test func itemsReflectThePinStore() throws {
        let suiteName = "hm-switcher-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let agent = Self.makeAgent(pane: "p1", workspace: "alpha", status: .blocked)
        let pins = PinnedAgentsStore(defaults: defaults)

        let unpinned = TerminalAgentSwitcherItem(agent: agent, pins: pins)
        #expect(unpinned.id == agent.id)
        #expect(unpinned.title == "alpha")
        #expect(unpinned.status == .blocked)
        #expect(!unpinned.isPinned)

        pins.togglePin(hostID: agent.hostID, paneID: agent.agent.paneID)
        let pinned = TerminalAgentSwitcherItem(agent: agent, pins: pins)
        #expect(pinned.id == agent.id)
        #expect(pinned.isPinned)
    }

    /// Long-press is Pin / Unpin, matching the Console row, so the user can
    /// mark an Agent without leaving the terminal.
    @MainActor
    @Test func thePinMenuSaysPinWhenUnpinnedAndUnpinWhenPinned() throws {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", host: host),
        ]
        let items = [
            Self.makeItem(agents[0]),
            Self.makeItem(agents[1], isPinned: true),
        ]
        let bar = TerminalAgentSwitcherBar()
        bar.update(items: items, selectedID: agents[0].id)

        for chip in bar.chips {
            let interaction = try #require(
                chip.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
            #expect(interaction.delegate === bar)
            #expect(
                bar.contextMenuInteraction(interaction, configurationForMenuAtLocation: .zero)
                    != nil)
        }

        let pinMenu = bar.pinMenu(for: items[0])
        #expect(pinMenu.children.count == 1)
        let pin = try #require(pinMenu.children.first as? UIAction)
        #expect(pin.title == "Pin")
        #expect(pin.image == UIImage(systemName: "pin"))

        let unpinMenu = bar.pinMenu(for: items[1])
        #expect(unpinMenu.children.count == 1)
        let unpin = try #require(unpinMenu.children.first as? UIAction)
        #expect(unpin.title == "Unpin")
        #expect(unpin.image == UIImage(systemName: "pin.slash"))
    }

    /// The long-press must ask the chip under the finger, not the first
    /// Agent on the strip — otherwise every menu would show the first
    /// chip's Pin / Unpin state.
    @MainActor
    @Test func eachChipResolvesItsOwnPinItem() throws {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", host: host),
        ]
        let items = [
            Self.makeItem(agents[0]),
            Self.makeItem(agents[1], isPinned: true),
        ]
        let bar = TerminalAgentSwitcherBar()
        bar.update(items: items, selectedID: agents[0].id)

        let firstInteraction = try #require(
            bar.chips[0].interactions.compactMap { $0 as? UIContextMenuInteraction }.first)
        let secondInteraction = try #require(
            bar.chips[1].interactions.compactMap { $0 as? UIContextMenuInteraction }.first)

        let first = try #require(bar.pinItem(for: firstInteraction))
        let second = try #require(bar.pinItem(for: secondInteraction))
        #expect(first == items[0])
        #expect(second == items[1])
        #expect(!first.isPinned)
        #expect(second.isPinned)
    }

    @MainActor
    @Test func choosingThePinMenuTogglesThatAgent() throws {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", host: host),
        ]
        let items = [
            Self.makeItem(agents[0]),
            Self.makeItem(agents[1], isPinned: true),
        ]
        var toggled: [ConsoleAgent.ID] = []
        let bar = TerminalAgentSwitcherBar()
        bar.onTogglePin = { toggled.append($0) }
        bar.update(items: items, selectedID: agents[0].id)

        let pin = try #require(bar.pinMenu(for: items[0]).children.first as? UIAction)
        pin.perform(nil, with: nil)
        #expect(toggled == [agents[0].id])

        let unpin = try #require(bar.pinMenu(for: items[1]).children.first as? UIAction)
        unpin.perform(nil, with: nil)
        #expect(toggled == [agents[0].id, agents[1].id])
    }

    /// The pin glyph is how an already-pinned chip reads before a long-press;
    /// an unpinned chip stays a dot and a label.
    @MainActor
    @Test func pinnedChipsShowAPinIndicator() throws {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", status: .blocked, host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", status: .idle, host: host),
        ]
        let bar = TerminalAgentSwitcherBar()
        bar.update(
            items: [
                Self.makeItem(agents[0]),
                Self.makeItem(agents[1], isPinned: true),
            ],
            selectedID: agents[0].id)

        #expect(!bar.chips[0].showsPinIndicator)
        #expect(bar.chips[0].accessibilityValue == "Blocked")
        #expect(bar.chips[1].showsPinIndicator)
        #expect(bar.chips[1].accessibilityValue == "Pinned, Idle")

        bar.update(
            items: [
                Self.makeItem(agents[0], isPinned: true),
                Self.makeItem(agents[1]),
            ],
            selectedID: agents[0].id)
        #expect(bar.chips[0].showsPinIndicator)
        #expect(bar.chips[1].showsPinIndicator == false)
    }

    /// The context menu must not steal the tap that switches Agents.
    @MainActor
    @Test func tappingAChipStillSwitchesWhenTheChipHasAPinMenu() {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", host: host),
        ]
        var opened: [ConsoleAgent.ID] = []
        var toggled: [ConsoleAgent.ID] = []
        let bar = TerminalAgentSwitcherBar()
        bar.onSelect = { opened.append($0) }
        bar.onTogglePin = { toggled.append($0) }
        bar.update(
            items: [
                Self.makeItem(agents[0]),
                Self.makeItem(agents[1], isPinned: true),
            ],
            selectedID: agents[0].id)

        bar.chips[1].sendActions(for: .touchUpInside)
        #expect(opened == [agents[1].id])
        #expect(toggled.isEmpty)
    }

    /// Status deltas land constantly (`pane.agent_status_changed`). Rebuilding
    /// the strip on each one would restart the Working pulse and throw away
    /// the scroll offset, so chips are reused by Agent identity.
    @MainActor
    @Test func chipsSurviveStatusChangesAndLeaveWithTheirAgent() {
        let host = UUID()
        let agents = [
            Self.makeAgent(pane: "p1", workspace: "alpha", status: .working, host: host),
            Self.makeAgent(pane: "p2", workspace: "beta", status: .idle, host: host),
        ]
        let bar = TerminalAgentSwitcherBar()
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[0].id)
        let working = bar.chips[0]

        bar.update(
            items: [
                Self.makeItem(agents[0], status: .blocked),
                Self.makeItem(agents[1], status: .working),
            ],
            selectedID: agents[0].id)
        #expect(bar.chips[0] === working)

        bar.update(items: [Self.makeItem(agents[1])], selectedID: agents[1].id)
        #expect(bar.chips.map(\.id) == [agents[1].id])
        #expect(working.superview == nil)
    }

    /// A switch builds a new terminal, so the strip that comes back is a new
    /// bar sitting at offset zero — and the Agent the user just picked is off
    /// screen whenever the list outruns the row. The chip on screen must be
    /// the one the terminal is attached to, in a strip the user never scrolled.
    @MainActor
    @Test func theOpenAgentsChipIsScrolledIntoViewOnceThereIsRoomToMeasure() throws {
        let host = UUID()
        let agents = (0..<8).map {
            Self.makeAgent(pane: "p\($0)", workspace: "project-\($0)", host: host)
        }
        let bar = TerminalAgentSwitcherBar()

        // The accessory's first update lands before it has any width, so the
        // scroll has to survive until a layout that can measure.
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[7].id)
        bar.layoutIfNeeded()
        bar.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        bar.layoutIfNeeded()
        let opened = try #require(bar.chips.last)
        #expect(bar.bounds.contains(opened.convert(opened.bounds, to: bar)))

        // And it keeps following the selection once the row is on screen.
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[0].id)
        bar.layoutIfNeeded()
        let first = try #require(bar.chips.first)
        #expect(bar.bounds.contains(first.convert(first.bounds, to: bar)))
    }

    /// The path a switch actually takes: a fresh strip is handed its chips
    /// before it is measured, and lands on screen already scrolled to the
    /// Agent the user picked.
    @MainActor
    @Test func theStripOpensScrolledToTheAgentOnScreen() async throws {
        let controller = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 700),
            rootViewController: controller)
        defer { window.isHidden = true }

        let host = UUID()
        let agents = (0..<5).map {
            Self.makeAgent(pane: "p\($0)", workspace: "project-\($0)", host: host)
        }
        let strip = TerminalAgentSwitcherBar()
        strip.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[4].id)
        strip.frame = CGRect(
            x: 0, y: 0, width: 402, height: TerminalAgentSwitcherBar.preferredHeight)
        controller.view.addSubview(strip)
        strip.layoutIfNeeded()

        let opened = try #require(strip.chips.last)
        #expect(strip.bounds.contains(opened.convert(opened.bounds, to: strip)))
    }

    /// The pass that reads the strip is not the pass that sizes it: until the
    /// scroll view publishes a content width the row is still short of its
    /// chips, and the open Agent looks like it fits when it does not. Trusting
    /// that half-built measure is what left the strip pinned to the start.
    @MainActor
    @Test func aStripWithNoPublishedWidthIsNotJudgedYet() throws {
        let host = UUID()
        let agents = (0..<5).map {
            Self.makeAgent(pane: "p\($0)", workspace: "project-\($0)", host: host)
        }
        let bar = TerminalAgentSwitcherBar()
        bar.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[4].id)
        bar.layoutIfNeeded()
        let strip = try #require(bar.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(strip.contentOffset.x > 0)

        strip.contentSize = .zero
        strip.contentOffset.x = 0
        // However many passes it takes to measure, the answer is never "it
        // fits, leave the strip at the start".
        bar.layoutIfNeeded()
        bar.layoutIfNeeded()
        #expect(strip.contentOffset.x > 0)
    }

    /// The accessory is measured over several passes, so the strip holds the
    /// open Agent in view across all of them — until the user scrolls it
    /// themselves, which outranks the whole business.
    @MainActor
    @Test func aHandScrolledStripIsLeftAlone() throws {
        let host = UUID()
        let agents = (0..<8).map {
            Self.makeAgent(pane: "p\($0)", workspace: "project-\($0)", host: host)
        }
        let bar = TerminalAgentSwitcherBar()
        bar.frame = CGRect(x: 0, y: 0, width: 240, height: 40)
        bar.update(items: agents.map { Self.makeItem($0) }, selectedID: agents[7].id)
        bar.layoutIfNeeded()
        let strip = try #require(bar.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(strip.contentOffset.x > 0)

        // A reset the user did not ask for — UIKit reloading the accessory —
        // does not even change the bounds, so the strip has to notice it.
        strip.contentOffset.x = 0
        bar.layoutIfNeeded()
        #expect(strip.contentOffset.x > 0)

        bar.scrollViewWillBeginDragging(strip)
        strip.contentOffset.x = 0
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        #expect(strip.contentOffset.x == 0)
    }

    /// Motion is the Working signal here, exactly as the orb is on the card.
    @MainActor
    @Test func onlyWorkingChipsPulse() {
        let agent = Self.makeAgent(pane: "p1", workspace: "alpha", status: .working)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let bar = TerminalAgentSwitcherBar()
        window.addSubview(bar)
        window.makeKeyAndVisible()

        bar.update(items: [Self.makeItem(agent)], selectedID: agent.id)
        #expect(bar.chips[0].isPulsing != UIAccessibility.isReduceMotionEnabled)

        bar.update(items: [Self.makeItem(agent, status: .done)], selectedID: agent.id)
        #expect(!bar.chips[0].isPulsing)
    }

    /// The switcher only pays off if the keyboard survives the switch: it
    /// lives on the keyboard, so dropping it would take the switcher with it.
    @MainActor
    @Test func theKeyboardHandoffIsGoodForExactlyOneScreen() {
        let host = UUID()
        let first = Self.makeAgent(pane: "p1", host: host).id
        let second = Self.makeAgent(pane: "p2", host: host).id
        let handoff = TerminalKeyboardHandoff()

        #expect(!handoff.consume(second))

        handoff.arm(for: second)
        // Only the Agent that was switched to inherits the keyboard.
        #expect(!handoff.consume(first))
        #expect(handoff.consume(second))
        #expect(!handoff.consume(second))
    }

    /// The keyboard may not dip between the two terminals: it carries the
    /// switcher, so a dip flashes the row away mid-switch. The replacement
    /// takes first responder in the same pass it reaches the window.
    @MainActor
    @Test func aClaimedHandoffTakesTheKeyboardOverWithoutLettingItDrop() async throws {
        let center = NotificationCenter()
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }

        let plain = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        plain.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(plain)
        #expect(!plain.isFirstResponder)

        let claimed = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        claimed.raisesKeyboardWhenReady = true
        claimed.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(claimed)
        #expect(claimed.isFirstResponder)

        // One shot: coming back on screen later starts with the keyboard down.
        claimed.dismissKeyboard()
        claimed.removeFromSuperview()
        host.view.addSubview(claimed)
        #expect(!claimed.isFirstResponder)
    }

    /// A grid Ghostty measured a surface against, as the Host is told about it.
    private struct TerminalGrid: Hashable, CustomStringConvertible {
        let columns: Int
        let rows: Int

        var description: String { "\(columns)x\(rows)" }
    }

    /// Ghostty answers one layout with several viewport reports, arriving on
    /// the main actor a beat behind the layout that provoked them, so a grid
    /// only means anything once they have stopped coming.
    @MainActor
    private static func waitForGridReportsToStop(
        _ reportedGrids: () -> [TerminalGrid]
    ) async throws {
        var stablePolls = 0
        var previousCount = reportedGrids().count
        while stablePolls < 20 {
            try await Task.sleep(for: .milliseconds(10))
            if reportedGrids().count == previousCount {
                stablePolls += 1
            } else {
                previousCount = reportedGrids().count
                stablePolls = 0
            }
        }
    }

    /// Ghostty's first viewport report on a fresh surface carries a zero cell
    /// size. Measuring the surface against that half-built grid — which is
    /// what happens when the view shrinks for the keyboard right after the
    /// handoff — leaves it drawing a band shorter than the view, showing as an
    /// unpainted strip above the toolbar. So the grid stays frozen until the
    /// keyboard has settled, and the only grid that reaches the Host is the
    /// settled one.
    @MainActor
    @Test func aClaimedHandoffFreezesTheGridUntilTheKeyboardSettles() async throws {
        var reportedGrids: [TerminalGrid] = []
        // The terminal's own center, so a keyboard settling anywhere else in
        // the process — another test's terminal, say — cannot end this
        // handoff (#157).
        let center = NotificationCenter()
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGrid(columns: columns, rows: rows))
            },
            notificationCenter: center)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }

        terminal.raisesKeyboardWhenReady = true
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()

        // A foreign settle, posted to the process-wide center inside the
        // handoff window. Before the isolation above, exactly this thawed the
        // freeze early — that was #145's second failure — so the window below
        // doubles as the proof that it no longer can.
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)

        // The keyboard is arriving: every bounds UIKit animates through here
        // is a half-built grid Ghostty must not be measured against.
        for height: CGFloat in [520, 440, 360] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(reportedGrids.isEmpty)

        // The keyboard settled. A keyboard that never left reports no
        // did-show, so its end frame is what thaws the grid — delivered on
        // the terminal's own center, the only one it observes.
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 400, width: 390, height: 300)])
        try await Self.waitForGridReportsToStop { reportedGrids }
        let escaped = reportedGrids
        #expect(!escaped.isEmpty, "the settled grid never made it past the freeze")

        // Ghostty reports one settled layout more than once, and the thaw only
        // coalesces the reports that land inside its window, so how many escape
        // is a matter of how busy the machine is. What must hold whatever the
        // schedule is that every one of them carries the settled grid and none
        // of the taller or half-built ones the freeze held back. So measure the
        // settled bounds again here, through the ordinary unfrozen path, and
        // hold what escaped against it.
        reportedGrids = []
        for height: CGFloat in [600, 360] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Self.waitForGridReportsToStop { reportedGrids }
        let settled = try #require(
            reportedGrids.last, "the terminal never measured its settled bounds")

        #expect(
            Set(escaped) == [settled],
            "the freeze let a grid other than the settled \(settled) out: \(escaped)")
    }

    /// Both terminals' accessories ride the keyboard while it changes hands,
    /// and that is the frame the keyboard publishes: one accessory too tall.
    /// UIKit publishes no other when the outgoing one leaves, so the layout
    /// keeps reserving room for a toolbar that is gone — measured on device,
    /// the terminal came back 88pt short and the agent lost five rows. The
    /// rebuild at the end of the handoff is what republishes the settled
    /// frame; a dismissal has no stale accessory and must not pay for one.
    @MainActor
    @Test func aClaimedHandoffRebuildsInputViewsToRepublishTheKeyboardFrame() async throws {
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }

        // Both terminals observe the test's own center: with every terminal
        // in the process on the shared one, any keyboard settling anywhere
        // could end the handoff before the explicit call below (#157).
        let center = NotificationCenter()
        let inherited = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        inherited.raisesKeyboardWhenReady = true
        inherited.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(inherited)
        // A foreign settle inside the handoff window must leave the handoff
        // standing, so the call below is necessarily what ends it — and the
        // republish lands exactly there, not whenever a neighbour's keyboard
        // happened to settle.
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        let rebuildsBeforeHandoffEnds = inherited.inputViewRebuildCount
        inherited.finishKeyboardTransitionLayout()
        #expect(inherited.inputViewRebuildCount > rebuildsBeforeHandoffEnds)

        // A terminal that raised its own keyboard has no outgoing accessory to
        // account for, so the same call must leave its input views alone. That
        // makes it the yardstick as well: same surface, same window, same
        // keyboard, differing only in having no handoff to pay for.
        let dismissing = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: center)
        dismissing.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(dismissing)
        dismissing.requestKeyboard()
        let rebuildsBeforeDismissalEnds = dismissing.inputViewRebuildCount
        dismissing.finishKeyboardTransitionLayout()
        #expect(dismissing.inputViewRebuildCount == rebuildsBeforeDismissalEnds)

        #expect(
            inherited.inputViewRebuildCount > dismissing.inputViewRebuildCount,
            """
            the handoff rebuilt the input views \(inherited.inputViewRebuildCount) times, \
            the dismissal \(dismissing.inputViewRebuildCount)
            """)
    }

    /// Keyboard notifications are process-wide, and on iPad two of the app's
    /// windows can each hold a live terminal (#157). Both of these terminals
    /// share one center, the shape production gets from `.default`; a private
    /// one keeps the CI simulator's real software keyboard (raised by the
    /// first-responder claim below, with settle frames that cover this
    /// window) from thawing the handoff before the assertions sample it.
    /// Generic show/hide events, a frame without ownership evidence, and a
    /// frame leaving the other window must all leave this terminal's handoff
    /// alone. Only a frame that leaves the keyboard covering this terminal's
    /// own window may thaw it.
    @MainActor
    @Test func anotherWindowsKeyboardEventsDoNotEndTheHandoff() async throws {
        var reportedGrids: [TerminalGrid] = []
        let center = NotificationCenter()
        let foreign = TerminalScreenView.makeConfiguredTerminal(notificationCenter: center)
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGrid(columns: columns, rows: rows))
            },
            notificationCenter: center)
        let foreignHost = UIViewController()
        let foreignWindow = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: foreignHost)
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            foreign.removeFromSuperview()
            window.isHidden = true
            foreignWindow.isHidden = true
        }

        foreign.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        foreignHost.view.addSubview(foreign)

        // The handoff itself: the terminal claims the keyboard as it reaches
        // its window and freezes its grid until that keyboard settles.
        terminal.raisesKeyboardWhenReady = true
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()
        #expect(terminal.isFirstResponder)

        // The other window's keyboard notifications provide no usable scene
        // identity. Its end frame leaves nothing covering this terminal's
        // window. A thaw rebuilds the input views on the spot, so an unchanged
        // rebuild count proves the freeze survived synchronously.
        let rebuildsBeforeForeignEvent = terminal.inputViewRebuildCount
        center.post(
            name: UIResponder.keyboardDidShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 400, width: 390, height: 300)])
        center.post(
            name: UIResponder.keyboardDidHideNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 700, width: 390, height: 300)])
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 700, width: 390, height: 300)])
        #expect(terminal.inputViewRebuildCount == rebuildsBeforeForeignEvent)

        for height: CGFloat in [520, 440, 360] {
            terminal.frame.size.height = height
            terminal.setNeedsLayout()
            terminal.layoutIfNeeded()
        }
        #expect(terminal.inputViewRebuildCount == rebuildsBeforeForeignEvent)
        #expect(reportedGrids.isEmpty)

        // This terminal's own settle: the keyboard ends its move covering
        // the terminal's window, and the freeze thaws.
        center.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                x: 0, y: 400, width: 390, height: 300)])
        #expect(terminal.inputViewRebuildCount > rebuildsBeforeForeignEvent)
        try await Self.waitForGridReportsToStop { reportedGrids }
        #expect(
            !reportedGrids.isEmpty,
            "the terminal's own settle never made it past the freeze")
    }
}
