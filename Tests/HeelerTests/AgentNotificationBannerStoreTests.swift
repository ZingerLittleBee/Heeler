import Foundation
import Testing

@testable import Heeler

/// The in-app foreground banner (#77): Blocked/Done transitions observed on
/// the Console's live Agent list must hold before announcing (anti-flap),
/// never repeat for an unchanged status (dedupe), stay silent for the
/// presented Agent and for Hosts whose notification preferences are unknown
/// or off (fail closed), and auto-dismiss after a few seconds.
///
/// Pane ids here stand in for live herdr addresses, so they use the observed
/// alphanumeric `w…:p…` family (uppercase included). The store only compares
/// them as opaque strings.
@MainActor
@Suite("Agent notification banner store")
struct AgentNotificationBannerStoreTests {
    private let hostID = UUID()

    /// Mutable fixtures the store's injected closures read at fire time.
    @MainActor
    private final class World {
        var presentedAgent: ConsoleAgent.ID?
        var triggers: [UUID: NotificationTriggerPreferences] = [:]
        var soundCount = 0
    }

    private let world = World()

    private func makeStore(
        holdDuration: Duration = .milliseconds(20),
        dismissDelay: Duration = .seconds(5)
    ) -> AgentNotificationBannerStore {
        let world = world
        return AgentNotificationBannerStore(
            holdDuration: holdDuration,
            dismissDelay: dismissDelay,
            presentedAgent: { world.presentedAgent },
            triggers: { world.triggers[$0] },
            playSound: { world.soundCount += 1 })
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        hostID: UUID? = nil, kind: String = "claude", workspaceLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID ?? self.hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID, status: status, kind: kind)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            lastOutputSnippet: nil)
    }

    /// Polls until `condition` holds, yielding so the store's tasks progress.
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

    /// Lets any (wrongly) scheduled hold elapse so silence is meaningful.
    private func waitPastHold() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: Transition detection and copy

    @Test func blockedTransitionBannersAfterTheHoldWithThePushCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        #expect(store.banner == nil, "the transition must hold before announcing")

        try await waitUntil("the banner should show once the hold elapses") {
            store.banner != nil
        }
        #expect(
            store.banner
                == AgentNotificationBanner(
                    target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
                    alert: AgentNotificationAlert(
                        title: "Claude", body: "Blocked — waiting for input")))
        #expect(world.soundCount == 1)
    }

    /// The banner shares the push renderer, so a known workspace leads the
    /// same way it does on a push.
    @Test func aKnownWorkspaceLeadsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, workspaceLabel: "Caterm")])

        store.agentsDidChange([agent("wV:p1", .blocked, workspaceLabel: "Caterm")])

        try await waitUntil("the banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(
                    title: "Caterm · Claude", body: "Blocked — waiting for input"))
    }

    @Test func doneTransitionBannersWithTheDoneCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, kind: "codex")])

        store.agentsDidChange([agent("wV:p1", .done, kind: "codex")])

        try await waitUntil("the Done banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(title: "Codex", body: "Done"))
    }

    /// The first sight of a pane is baseline, not a transition: a killed-state
    /// launch must not banner every already-Blocked Agent it syncs.
    @Test func firstSightOfABlockedAgentIsBaselineNotATransition() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func workingAndIdleTransitionsNeverBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .idle)])

        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .idle)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Anti-flap

    @Test func aTransitionThatDoesNotHoldNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    /// A flap that settles back into Blocked banners exactly once, from the
    /// re-entry that finally held.
    @Test func aFlapThatSettlesBannersOnce() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the settled transition should banner") { store.banner != nil }
        #expect(world.soundCount == 1)
    }

    @Test func aVanishedPaneCancelsItsPendingBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        // Reappearing is a fresh baseline, not a transition.
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Same-status dedupe

    @Test func anUnchangedStatusNeverRepeatsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the first banner should show") { store.banner != nil }

        store.dismiss()
        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 1)
    }

    // MARK: Suppression and preferences

    /// Suppression is decided at fire time: navigating into the Agent while
    /// its transition is still holding silences the banner.
    @Test func thePresentedAgentsOwnTransitionNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func anotherAgentsTransitionBannersWhileOneIsPresented() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])

        try await waitUntil("the other pane's banner should show") { store.banner != nil }
        #expect(store.banner?.target == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
    }

    /// Unknown preferences (Host unreachable, never registered, still loading)
    /// fail closed, matching the plugin's missing-flag semantics.
    @Test func unknownPreferencesFailClosed() async throws {
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    @Test func aDisabledDoneFlagSkipsDoneButKeepsBlocked() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences(blocked: true, done: false)
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitPastHold()
        #expect(store.banner == nil)

        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the Blocked banner should still show") { store.banner != nil }
    }

    // MARK: Presentation lifecycle

    @Test func theBannerAutoDismissesAfterItsDelay() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore(dismissDelay: .milliseconds(40))
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the banner should show") { store.banner != nil }
        try await waitUntil("the banner should auto-dismiss") { store.banner == nil }
    }

    @Test func aNewerBannerReplacesTheCurrentOne() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wR:pC", .working)])

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .working)])
        try await waitUntil("the first banner should show") {
            store.banner?.target.paneID == "w1:pT"
        }

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .done)])
        try await waitUntil("the newer banner should replace it") {
            store.banner?.target.paneID == "wR:pC"
        }
    }

    @Test func dismissClearsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the banner should show") { store.banner != nil }

        store.dismiss()

        #expect(store.banner == nil)
    }
}
