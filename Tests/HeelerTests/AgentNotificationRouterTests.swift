import Foundation
import Testing

@testable import Heeler

/// The navigation half of #74: taps land on the right Agent Monitor through
/// the Console's navigation path, a killed-state tap waits for the pane to
/// arrive with the Host's first sync, and stale or unresolvable pushes fall
/// back to the Console with no alarming copy.
@MainActor
@Suite("Agent notification router")
struct AgentNotificationRouterTests {
    private func consoleAgent(hostID: UUID, paneID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: nil, repoName: nil, lastOutputSnippet: nil)
    }

    /// Polls until `condition` holds, yielding so the router's tasks progress.
    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), comment)
    }

    @Test func tapOnAKnownAgentOpensItsMonitor() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "%5")])

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%5"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%5")])
        #expect(router.pendingTarget == nil)
    }

    @Test func tapReplacesTheCurrentlyPresentedAgent() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "%5"),
            consoleAgent(hostID: hostID, paneID: "%6"),
        ])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%6")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%5"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%5")])
    }

    /// The killed-state launch path: the tap arrives before any Host has
    /// synced, so the router waits on the Console and routes the moment the
    /// pane appears.
    @Test func tapBeforeTheConsoleSyncsWaitsForThePaneThenOpens() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%5"))
        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == AgentNotificationTarget(hostID: hostID, paneID: "%5"))

        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "%5")])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%5")])
        #expect(router.pendingTarget == nil)
    }

    /// A stale pane — closed since the push was sent — never shows up, so
    /// the tap quietly stays on the Console once the grace window elapses.
    @Test func stalePaneFallsBackToTheConsoleQuietly() async throws {
        let router = AgentNotificationRouter(pendingGrace: .milliseconds(25))
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "%1")])
        // Viewing some other Agent when the tap lands: fall back means
        // popping to the Console, not staying wherever the user was.
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%1")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%gone"))
        #expect(router.path.isEmpty)

        try await waitUntil("the pending target should expire") {
            router.pendingTarget == nil
        }
        #expect(router.path.isEmpty)
    }

    /// Unknown key id or an undecryptable envelope resolves to no target;
    /// the tap still brings the user to the Console.
    @Test func unresolvableTapFallsBackToTheConsole() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "%5")])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%5")]

        router.open(nil)

        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == nil)
    }

    /// If the user starts navigating while a tap is still waiting for its
    /// pane, the deep link must not yank them away later.
    @Test func manualNavigationDropsAPendingDeepLink() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%5"))
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%other")]

        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "%5"),
            consoleAgent(hostID: hostID, paneID: "%other"),
        ])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%other")])
        #expect(router.pendingTarget == nil)
    }
}
