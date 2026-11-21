import Foundation
import GhosttyTerminal
import Observation
import Testing

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
        kind: String = "claude",
        status: AgentStatus = .idle,
        host: UUID = UUID()
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_\(pane)", kind: kind, title: "",
                status: status, workspaceID: "w", tabID: "w:t", paneID: pane,
                cwd: "/work", revision: 1, name: name),
            workspaceLabel: workspace,
            repositoryCheckout: repo.map {
                RepositoryCheckout(
                    repoKey: "/work/\($0)/.git",
                    repoName: $0,
                    repoRoot: "/work/\($0)",
                    checkoutPath: "/work/\($0)",
                    isLinkedWorktree: false)
            })
    }

    @Test func chipLabelsUseTheSharedFirstRowAndBoundLongText() {
        let project = Self.makeAgent(pane: "p1", workspace: "proj", repo: "repo")
        #expect(AgentCardPresentation(agent: project).switcherTitle == "proj")
        let fallback = Self.makeAgent(pane: "p2", repo: "repo", name: "reviewer")
        #expect(AgentCardPresentation(agent: fallback).switcherTitle == "reviewer")
        let long = Self.makeAgent(pane: "p3", workspace: String(repeating: "👨‍👩‍👧‍👦", count: 70))
        let title = AgentCardPresentation(agent: long).switcherTitle
        #expect(title.count == 48 && title.hasSuffix("…"))
        #expect(AgentCardPresentation(agent: project, layout: .init(rows: [])).switcherTitle == "claude")
    }

    /// A program name only helps when it differs, and a chip whose own title
    /// already names the Agent needs none.
    @MainActor
    @Test func chipsKeepTheirTitleWhenTheProgramCannotTellThemApart() throws {
        let suiteName = "hm-switcher-qualifiers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pins = PinnedAgentsStore(defaults: defaults)
        let host = UUID()
        let twins = [
            Self.makeAgent(pane: "p1", workspace: "proj", kind: "claude", host: host),
            Self.makeAgent(pane: "p2", workspace: "proj", kind: "claude", host: host),
        ]
        let sameProgram = TerminalAgentSwitcherItem.items(
            for: twins, pins: pins, layout: { _ in .heelerDefault })
        #expect(sameProgram.map(\.qualifier) == [nil, nil])

        let named = [
            Self.makeAgent(pane: "p1", workspace: "proj", name: "omp", kind: "omp", host: host),
            Self.makeAgent(pane: "p2", workspace: "proj", name: "omp", kind: "pi", host: host),
        ]
        let agentFirst = AgentRowLayout(rows: [[.init(.agent)], [.init(.workspace)]])
        let namedItems = TerminalAgentSwitcherItem.items(
            for: named, pins: pins, layout: { _ in agentFirst })
        #expect(namedItems.map(\.title) == ["omp", "omp"])
        #expect(namedItems.map(\.qualifier) == [nil, nil])
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
        let layout = AgentRowLayout(rows: [[.init(.agent)], [.init(.workspace)]])
        let custom = TerminalAgentSwitcherItem(agent: agent, pins: pins, layout: layout)
        #expect(custom.title == AgentCardPresentation(agent: agent, layout: layout).switcherTitle)
        #expect(custom.title == "claude" && custom.isPinned)
        #expect(custom.status == .blocked)
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

    @MainActor
    @Test func keyboardHandoffCancellationOnlyClearsTheMatchingAgent() {
        let handoff = TerminalKeyboardHandoff()
        let first = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let second = ConsoleAgent.ID(hostID: UUID(), paneID: "w2:p2")

        handoff.arm(for: first)
        handoff.cancel(for: second)
        #expect(handoff.consume(first))

        handoff.arm(for: second)
        handoff.cancel(for: second)
        #expect(!handoff.consume(second))
    }

    /// A Shell Terminal's identity is often unknown when the keyboard state
    /// is captured, so its handoff is unkeyed, one-shot, and cancellable.
    @MainActor
    @Test func theShellTerminalHandoffIsUnkeyedOneShotAndCancellable() {
        let handoff = TerminalKeyboardHandoff()
        #expect(!handoff.consumeShellTerminal())

        handoff.armShellTerminal()
        #expect(handoff.consumeShellTerminal())
        #expect(!handoff.consumeShellTerminal(), "spent on the first screen")

        handoff.armShellTerminal()
        handoff.cancelShellTerminal()
        #expect(!handoff.consumeShellTerminal(), "a failed creation must not raise a later open")

        // Independent of the Agent-keyed intent.
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:pA")
        handoff.arm(for: agent)
        #expect(!handoff.consumeShellTerminal())
        #expect(handoff.consume(agent))
    }

    /// The screen being left reads `isArmed` to keep first responder until
    /// the destination claims the keyboard; a stand-in for a Shell Terminal
    /// still being connected reads the Shell-specific intent.
    @MainActor
    @Test func anArmedHandoffIsVisibleUntilItIsConsumedOrCancelled() {
        let handoff = TerminalKeyboardHandoff()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:pA")
        #expect(!handoff.isArmed)
        #expect(!handoff.isShellTerminalArmed)

        handoff.arm(for: agent)
        #expect(handoff.isArmed)
        #expect(!handoff.isShellTerminalArmed)
        _ = handoff.consume(agent)
        #expect(!handoff.isArmed)

        handoff.arm(for: agent)
        handoff.cancel(for: agent)
        #expect(!handoff.isArmed)

        handoff.armShellTerminal()
        #expect(handoff.isArmed)
        #expect(handoff.isShellTerminalArmed)
        _ = handoff.consumeShellTerminal()
        #expect(!handoff.isArmed)
        #expect(!handoff.isShellTerminalArmed)

        handoff.armShellTerminal()
        handoff.cancelShellTerminal()
        #expect(!handoff.isArmed)
    }

}
