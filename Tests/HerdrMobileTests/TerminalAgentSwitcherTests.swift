import Foundation
import Testing
import UIKit

@testable import HerdrMobile

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
        _ agent: ConsoleAgent, status: AgentStatus? = nil
    ) -> TerminalAgentSwitcherItem {
        TerminalAgentSwitcherItem(
            id: agent.id, title: agent.switcherLabel, status: status ?? agent.agent.status)
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

    /// The switcher sits above the input row, and the dismiss button is
    /// pinned beside it — outside the scroll view, so the one control that
    /// takes the keyboard down can never scroll out of reach.
    @MainActor
    @Test func theSwitcherRowCarriesAPinnedDismissButton() throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let accessory = try #require(
            terminal.inputAccessoryView as? TerminalKeyboardAccessory)
        accessory.frame = CGRect(
            x: 0, y: 0, width: 402, height: TerminalKeyboardAccessory.preferredHeight)
        accessory.layoutIfNeeded()

        #expect(
            TerminalKeyboardAccessory.preferredHeight
                == TerminalKeyboardAccessory.switcherHeight
                    + TerminalKeyboardAccessory.inputRowHeight)
        #expect(accessory.dismissButton.accessibilityLabel == "Dismiss keyboard")
        #expect(accessory.dismissButton.frame.maxY <= TerminalKeyboardAccessory.switcherHeight)
        #expect(accessory.dismissButton.frame.maxX == accessory.bounds.width - 8)
        #expect(!accessory.dismissButton.isDescendant(of: accessory.agentSwitcher))
        #expect(accessory.agentSwitcher.frame.maxX <= accessory.dismissButton.frame.minX)
        // The input row keeps its own controls, now entirely below the strip.
        for control in [accessory.pasteControl, accessory.newLineButton] as [UIView] {
            let frame = accessory.convert(control.bounds, from: control)
            #expect(frame.minY >= TerminalKeyboardAccessory.switcherHeight)
        }
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
        #expect(blocked.accessibilityHint == "Switches this terminal to that Agent")
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

    /// The path a switch actually takes: a fresh accessory is handed the strip
    /// before it is measured, and lands on the keyboard already scrolled to
    /// the Agent the user picked.
    @MainActor
    @Test func theAccessoryOpensScrolledToTheAgentOnScreen() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal()
        let accessory = try #require(terminal.inputAccessoryView as? TerminalKeyboardAccessory)
        let controller = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 700),
            rootViewController: controller)
        defer { window.isHidden = true }

        let host = UUID()
        let agents = (0..<5).map {
            Self.makeAgent(pane: "p\($0)", workspace: "project-\($0)", host: host)
        }
        accessory.update(
            agentSwitcher: TerminalAgentSwitcher(
                items: agents.map { Self.makeItem($0) },
                selectedID: agents[4].id,
                onSelect: { _ in }))
        accessory.frame = CGRect(
            x: 0, y: 0, width: 402, height: TerminalKeyboardAccessory.preferredHeight)
        controller.view.addSubview(accessory)
        accessory.layoutIfNeeded()

        let strip = accessory.agentSwitcher
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
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer { window.isHidden = true }

        let plain = TerminalScreenView.makeConfiguredTerminal()
        plain.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(plain)
        #expect(!plain.isFirstResponder)

        let claimed = TerminalScreenView.makeConfiguredTerminal()
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

    /// Ghostty's first viewport report on a fresh surface carries a zero cell
    /// size. Measuring the surface against that half-built grid — which is
    /// what happens when the view shrinks for the keyboard right after the
    /// handoff — leaves it drawing a band shorter than the view, showing as an
    /// unpainted strip above the toolbar. So the grid stays frozen until the
    /// keyboard has settled, then fits once.
    @MainActor
    @Test func aClaimedHandoffFreezesTheGridUntilTheKeyboardSettles() async throws {
        var reportedGrids: [(columns: Int, rows: Int)] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append((columns, rows))
            })
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
        // did-show, so its end frame is what thaws the grid.
        NotificationCenter.default.post(
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        var stablePolls = 0
        var previousCount = reportedGrids.count
        while stablePolls < 20 {
            try await Task.sleep(for: .milliseconds(10))
            if reportedGrids.count == previousCount {
                stablePolls += 1
            } else {
                previousCount = reportedGrids.count
                stablePolls = 0
            }
        }

        #expect(reportedGrids.count == 1, "only the settled grid may escape")
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

        let inherited = TerminalScreenView.makeConfiguredTerminal()
        inherited.raisesKeyboardWhenReady = true
        inherited.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(inherited)
        let rebuildsBeforeHandoffEnds = inherited.inputViewRebuildCount
        inherited.finishKeyboardTransitionLayout()
        #expect(inherited.inputViewRebuildCount > rebuildsBeforeHandoffEnds)

        let dismissing = TerminalScreenView.makeConfiguredTerminal()
        dismissing.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(dismissing)
        dismissing.requestKeyboard()
        dismissing.beginKeyboardDismissalLayoutDeferral()
        let rebuildsBeforeDismissalEnds = dismissing.inputViewRebuildCount
        dismissing.finishKeyboardTransitionLayout()
        #expect(dismissing.inputViewRebuildCount == rebuildsBeforeDismissalEnds)
    }
}
