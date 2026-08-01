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

    /// A claimed handoff hands the keyboard to the terminal that replaced the
    /// one the user was typing into — but only once Ghostty has measured a
    /// real grid. Raising it against the zero-cell first report leaves the
    /// surface drawing a band shorter than the view (#white-band).
    @MainActor
    @Test func aClaimedHandoffWaitsForTheMeasuredGridThenRaisesTheKeyboard() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.makeKeyAndVisible()

        let claimed = TerminalScreenView.makeConfiguredTerminal()
        claimed.raisesKeyboardWhenReady = true
        claimed.frame = window.bounds
        window.addSubview(claimed)
        #expect(!claimed.isFirstResponder)

        claimed.layoutIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while !claimed.isFirstResponder, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(claimed.isFirstResponder, "the measured grid should hand over the keyboard")

        // One shot: coming back on screen later starts with the keyboard down.
        claimed.dismissKeyboard()
        claimed.removeFromSuperview()
        window.addSubview(claimed)
        claimed.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!claimed.isFirstResponder)
    }

    /// A terminal nobody handed the keyboard to keeps it down, however many
    /// grids Ghostty measures.
    @MainActor
    @Test func anUnclaimedTerminalNeverRaisesTheKeyboardOnItsOwn() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.makeKeyAndVisible()

        let plain = TerminalScreenView.makeConfiguredTerminal()
        plain.frame = window.bounds
        window.addSubview(plain)
        plain.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!plain.isFirstResponder)
    }
}
