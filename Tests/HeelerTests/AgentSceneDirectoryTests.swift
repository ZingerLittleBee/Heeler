import Foundation
import Testing
import UIKit

@testable import Heeler

/// The single-window rule for deep links, as the pure policy: an Agent that
/// is already on screen is activated where it is, anything else lands in
/// the key window, and nothing ever asks for a new window.
@Suite("Agent deep-link policy")
struct AgentDeepLinkPolicyTests {
    private let hostID = UUID()
    private let first = UUID()
    private let second = UUID()

    private func agent(_ paneID: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: hostID, paneID: paneID)
    }

    @Test func noWindowYetHoldsTheLink() {
        #expect(
            AgentDeepLinkPolicy.decide(target: agent("w1:p1"), scenes: [], preferredSceneID: nil)
                == .awaitScene)
        #expect(
            AgentDeepLinkPolicy.decide(target: nil, scenes: [], preferredSceneID: nil)
                == .awaitScene)
    }

    @Test func anAgentOnScreenActivatesItsWindowEvenWhenAnotherIsKey() {
        let scenes = [
            AgentSceneState(id: first, presentedAgent: agent("w1:p1"), activationOrder: 1),
            AgentSceneState(id: second, presentedAgent: agent("w1:p2"), activationOrder: 2),
        ]

        #expect(
            AgentDeepLinkPolicy.decide(target: agent("w1:p1"), scenes: scenes, preferredSceneID: nil)
                == .activate(sceneID: first))
        // The window the link arrived through does not pull it away either.
        #expect(
            AgentDeepLinkPolicy.decide(
                target: agent("w1:p1"), scenes: scenes, preferredSceneID: second)
                == .activate(sceneID: first))
    }

    @Test func anAgentNotOnScreenRoutesIntoTheKeyWindow() {
        let scenes = [
            AgentSceneState(id: first, presentedAgent: agent("w1:p1"), activationOrder: 3),
            AgentSceneState(id: second, presentedAgent: nil, activationOrder: 2),
        ]

        #expect(
            AgentDeepLinkPolicy.decide(target: agent("w9:p9"), scenes: scenes, preferredSceneID: nil)
                == .route(sceneID: first))
    }

    @Test func theWindowALinkArrivedThroughIsPreferred() {
        let scenes = [
            AgentSceneState(id: first, presentedAgent: nil, activationOrder: 3),
            AgentSceneState(id: second, presentedAgent: nil, activationOrder: 2),
        ]

        #expect(
            AgentDeepLinkPolicy.decide(
                target: agent("w9:p9"), scenes: scenes, preferredSceneID: second)
                == .route(sceneID: second))
        #expect(
            AgentDeepLinkPolicy.decide(target: nil, scenes: scenes, preferredSceneID: second)
                == .route(sceneID: second))
    }

    /// Before any window has been active, the first one connected is key, so
    /// a killed-state launch still has a deterministic landing spot.
    @Test func theFirstConnectedWindowBreaksTies() {
        let scenes = [
            AgentSceneState(id: first, presentedAgent: nil, activationOrder: 0),
            AgentSceneState(id: second, presentedAgent: nil, activationOrder: 0),
        ]

        #expect(AgentDeepLinkPolicy.keyScene(in: scenes) == first)
        #expect(
            AgentDeepLinkPolicy.decide(target: nil, scenes: scenes, preferredSceneID: nil)
                == .route(sceneID: first))
    }
}

@MainActor
private final class FakeSceneWindow: AgentSceneWindow {
    var sceneWindowState = AgentSceneWindowState.connected
}

/// Which scene-phase activations count as the user moving into a window.
@Suite("Scene activation tracker")
struct SceneActivationTrackerTests {
    /// Open in New Window, a dragged row, a first launch: the user just asked
    /// for this window, so its first activation makes it the one worked in.
    @Test func aNewlyOpenedWindowCountsItsFirstActivation() {
        var tracker = SceneActivationTracker(isRestored: false)

        let first = tracker.sceneDidBecomeActive()

        #expect(first)
    }

    /// Every window turns active again on a foreground return, in no defined
    /// order; none of that is the user choosing a window.
    @Test func aForegroundReturnDoesNotCount() {
        var tracker = SceneActivationTracker(isRestored: false)
        _ = tracker.sceneDidBecomeActive()

        let returned = tracker.sceneDidBecomeActive()
        let returnedAgain = tracker.sceneDidBecomeActive()

        #expect(!returned)
        #expect(!returnedAgain)
    }

    @Test func aRestoredWindowWaitsForInteraction() {
        var tracker = SceneActivationTracker(isRestored: true)

        let first = tracker.sceneDidBecomeActive()

        #expect(!first)
    }
}

/// What a registered window's handle says about it.
@Suite("Agent scene window state")
struct AgentSceneWindowStateTests {
    @Test func aWindowThatNeverAttachedIsPending() {
        #expect(
            AgentSceneWindowState.resolve(hasAttached: false, activationState: nil) == .pending)
    }

    @Test func aWindowWhoseSceneIsGoneIsDisconnected() {
        #expect(
            AgentSceneWindowState.resolve(hasAttached: true, activationState: nil)
                == .disconnected)
        #expect(
            AgentSceneWindowState.resolve(hasAttached: true, activationState: .unattached)
                == .disconnected)
    }

    /// A backgrounded window is still a window: it restores, and links may
    /// bring it forward.
    @Test(arguments: [
        UIScene.ActivationState.foregroundActive, .foregroundInactive, .background,
    ])
    func anAttachedSceneIsConnected(state: UIScene.ActivationState) {
        #expect(
            AgentSceneWindowState.resolve(hasAttached: true, activationState: state)
                == .connected)
    }
}

/// The directory that owns the windows' routers: each window navigates on
/// its own, and a deep link drives exactly one of them.
@MainActor
@Suite("Agent scene directory")
struct AgentSceneDirectoryTests {
    private let hostID = UUID()

    private func consoleAgent(_ paneID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: nil, repositoryCheckout: nil, lastOutputSnippet: nil)
    }

    private func target(_ paneID: String) -> AgentNotificationTarget {
        AgentNotificationTarget(hostID: hostID, paneID: paneID)
    }

    private func makeRouter(knowing paneIDs: [String]) -> AgentNotificationRouter {
        let router = AgentNotificationRouter()
        router.agentsDidChange(paneIDs.map { consoleAgent($0) })
        return router
    }

    /// Two windows, two routers: navigating one leaves the other where it
    /// was, whether the user or a deep link moves it.
    @Test func windowRoutersAreIsolated() {
        let directory = AgentSceneDirectory()
        let firstRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let secondRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let first = UUID()
        let second = UUID()
        directory.register(sceneID: first, router: firstRouter, activate: {})
        directory.register(sceneID: second, router: secondRouter, activate: {})
        secondRouter.path = [target("w1:p2").agentID]

        firstRouter.path = [target("w1:p1").agentID]
        #expect(secondRouter.path == [target("w1:p2").agentID])

        directory.open(target("w1:p1"), preferredSceneID: first)
        #expect(firstRouter.path == [target("w1:p1").agentID])
        #expect(secondRouter.path == [target("w1:p2").agentID])
    }

    /// A tap for an Agent another window already shows brings that window
    /// forward and leaves the key window alone — never a second window on it.
    @Test func aDeepLinkToAnAgentOnScreenActivatesThatWindowOnly() {
        let directory = AgentSceneDirectory()
        let showingRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let keyRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let showing = UUID()
        let key = UUID()
        var activations: [UUID] = []
        directory.register(sceneID: showing, router: showingRouter) { activations.append(showing) }
        directory.register(sceneID: key, router: keyRouter) { activations.append(key) }
        showingRouter.path = [target("w1:p1").agentID]
        keyRouter.path = [target("w1:p2").agentID]
        directory.sceneDidBecomeActive(sceneID: showing)
        directory.sceneDidBecomeActive(sceneID: key)

        directory.open(target("w1:p1"))

        #expect(activations == [showing])
        #expect(showingRouter.path == [target("w1:p1").agentID])
        #expect(keyRouter.path == [target("w1:p2").agentID])
    }

    @Test func aDeepLinkToAnAgentOffScreenLandsInTheKeyWindow() {
        let directory = AgentSceneDirectory()
        let olderRouter = makeRouter(knowing: ["w1:p3"])
        let keyRouter = makeRouter(knowing: ["w1:p3"])
        let older = UUID()
        let key = UUID()
        var activations: [UUID] = []
        directory.register(sceneID: older, router: olderRouter) { activations.append(older) }
        directory.register(sceneID: key, router: keyRouter) { activations.append(key) }
        directory.sceneDidBecomeActive(sceneID: older)
        directory.sceneDidBecomeActive(sceneID: key)

        directory.open(target("w1:p3"))

        #expect(activations == [key])
        #expect(keyRouter.path == [target("w1:p3").agentID])
        #expect(olderRouter.path.isEmpty)
        #expect(directory.keyScenePresentedAgent == target("w1:p3").agentID)
    }

    /// A killed-state launch can deliver the tap before SwiftUI has built
    /// any window; the first window to connect receives it.
    @Test func aLinkBeforeAnyWindowWaitsForTheFirstOne() {
        let directory = AgentSceneDirectory()
        directory.open(target("w1:p1"))

        let router = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: UUID(), router: router, activate: {})

        #expect(router.path == [target("w1:p1").agentID])

        // Delivered once: a later window does not replay it.
        let laterRouter = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: UUID(), router: laterRouter, activate: {})
        #expect(laterRouter.path.isEmpty)
    }

    /// Open in New Window finds a window already on that Agent instead of
    /// opening a second one; it opens a window only when none shows it.
    @Test func activatingAPresentingWindowReportsWhetherOneExists() {
        let directory = AgentSceneDirectory()
        let router = makeRouter(knowing: ["w1:p1"])
        let scene = UUID()
        var activations = 0
        directory.register(sceneID: scene, router: router) { activations += 1 }
        router.path = [target("w1:p1").agentID]

        #expect(directory.activateScene(presenting: target("w1:p1").agentID))
        #expect(!directory.activateScene(presenting: target("w1:p9").agentID))
        #expect(activations == 1)
    }

    /// A closed window stops being a landing spot.
    @Test func anUnregisteredWindowReceivesNothing() {
        let directory = AgentSceneDirectory()
        let closedRouter = makeRouter(knowing: ["w1:p1"])
        let openRouter = makeRouter(knowing: ["w1:p1"])
        let closed = UUID()
        directory.register(sceneID: closed, router: closedRouter, activate: {})
        directory.register(sceneID: UUID(), router: openRouter, activate: {})
        directory.sceneDidBecomeActive(sceneID: closed)
        directory.unregister(sceneID: closed)

        directory.open(target("w1:p1"))

        #expect(closedRouter.path.isEmpty)
        #expect(openRouter.path == [target("w1:p1").agentID])
    }

    // MARK: Windows that closed without unregistering

    /// SwiftUI promises no `onDisappear` for a closed or system-disconnected
    /// scene, so a window can stay registered after it is gone.
    @Test func aClosedWindowThatNeverUnregisteredReceivesNothing() {
        let directory = AgentSceneDirectory()
        let closedWindow = FakeSceneWindow()
        let closedRouter = makeRouter(knowing: ["w1:p1"])
        let openRouter = makeRouter(knowing: ["w1:p1"])
        let closed = UUID()
        var activations: [UUID] = []
        directory.register(sceneID: closed, router: closedRouter, window: closedWindow) {
            activations.append(closed)
        }
        directory.register(sceneID: UUID(), router: openRouter, window: FakeSceneWindow()) {}
        closedRouter.path = [target("w1:p1").agentID]
        directory.sceneDidBecomeActive(sceneID: closed)

        closedWindow.sceneWindowState = .disconnected
        directory.open(target("w1:p1"))

        #expect(activations.isEmpty)
        #expect(openRouter.path == [target("w1:p1").agentID])
    }

    /// Open in New Window must open a window rather than "activate" one
    /// that is gone.
    @Test func openInNewWindowIgnoresAClosedWindowOnTheAgent() {
        let directory = AgentSceneDirectory()
        let closedWindow = FakeSceneWindow()
        let router = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: UUID(), router: router, window: closedWindow) {}
        router.path = [target("w1:p1").agentID]
        #expect(directory.activateScene(presenting: target("w1:p1").agentID))

        closedWindow.sceneWindowState = .disconnected

        #expect(!directory.activateScene(presenting: target("w1:p1").agentID))
        #expect(directory.keyScenePresentedAgent == nil)
    }

    /// A window registers before its `UIWindow` attaches; it is live then.
    @Test func aWindowNotYetAttachedStillReceivesLinks() {
        let directory = AgentSceneDirectory()
        let pendingWindow = FakeSceneWindow()
        pendingWindow.sceneWindowState = .pending
        let router = makeRouter(knowing: ["w1:p1"])
        directory.open(target("w1:p1"))

        directory.register(sceneID: UUID(), router: router, window: pendingWindow) {}

        #expect(router.path == [target("w1:p1").agentID])
    }

    @Test func aClosedWindowReleasesItsHostTerminal() {
        let directory = AgentSceneDirectory()
        let first = UUID()
        let second = UUID()
        let secondWindow = FakeSceneWindow()
        let firstRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let secondRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        directory.register(sceneID: first, router: firstRouter, window: FakeSceneWindow()) {}
        directory.register(sceneID: second, router: secondRouter, window: secondWindow) {}
        firstRouter.path = [target("w1:p1").agentID]
        directory.sceneRouteDidChange(sceneID: first)
        directory.sceneDidBecomeActive(sceneID: first)
        secondRouter.path = [target("w1:p2").agentID]
        directory.sceneRouteDidChange(sceneID: second)
        directory.sceneDidBecomeActive(sceneID: second)
        #expect(
            directory.terminalAccess(sceneID: first, hostID: hostID)
                == .liveInAnotherWindow)

        secondWindow.sceneWindowState = .disconnected
        directory.takeOverTerminal(sceneID: first, hostID: hostID)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
    }

    // MARK: Same-Host terminal handoff

    /// Two windows on two Agents of one Host, each registered and on its
    /// Agent, the second the one worked in.
    private func makeSharedHostWindows(
        _ directory: AgentSceneDirectory
    ) -> (first: UUID, second: UUID) {
        let first = UUID()
        let second = UUID()
        let firstRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let secondRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        directory.register(sceneID: first, router: firstRouter, activate: {})
        directory.register(sceneID: second, router: secondRouter, activate: {})
        firstRouter.path = [target("w1:p1").agentID]
        directory.sceneRouteDidChange(sceneID: first)
        directory.sceneDidBecomeActive(sceneID: first)
        secondRouter.path = [target("w1:p2").agentID]
        directory.sceneRouteDidChange(sceneID: second)
        directory.sceneDidBecomeActive(sceneID: second)
        return (first, second)
    }

    @Test func anInteractionInTheWaitingWindowHandsTheHostOver() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)

        directory.sceneDidReceiveInteraction(sceneID: first)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: second, hostID: hostID)
                == .liveInAnotherWindow)
    }

    /// Interaction in the window already worked in is not a move: it must
    /// not undo a takeover made from the other window.
    @Test func anInteractionInTheWindowAlreadyWorkedInChangesNothing() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)
        directory.takeOverTerminal(sceneID: first, hostID: hostID)

        directory.sceneDidReceiveInteraction(sceneID: second)
        directory.sceneDidReceiveInteraction(sceneID: second)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
    }

    /// The scene root's rule, applied to two restored windows coming back to
    /// the foreground in either order: the window the user was working in
    /// keeps its Host.
    @Test func aForegroundReturnDoesNotChangeTheHolder() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)
        var firstActivation = SceneActivationTracker(isRestored: true)
        var secondActivation = SceneActivationTracker(isRestored: true)
        #expect(directory.terminalAccess(sceneID: second, hostID: hostID) == .holds)

        for _ in 0..<2 {
            if secondActivation.sceneDidBecomeActive() {
                directory.sceneDidBecomeActive(sceneID: second)
            }
            if firstActivation.sceneDidBecomeActive() {
                directory.sceneDidBecomeActive(sceneID: first)
            }
        }

        #expect(directory.terminalAccess(sceneID: second, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: first, hostID: hostID)
                == .liveInAnotherWindow)
    }

    /// Open in New Window onto another Agent of the same Host lands the user
    /// on a live terminal, not on Live in Another Window.
    @Test func aNewlyOpenedWindowTakesTheHost() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)
        let opened = UUID()
        let openedRouter = makeRouter(knowing: ["w1:p1", "w1:p2", "w1:p3"])
        openedRouter.path = [target("w1:p3").agentID]
        directory.register(sceneID: opened, router: openedRouter, activate: {})
        var activation = SceneActivationTracker(isRestored: false)

        if activation.sceneDidBecomeActive() {
            directory.sceneDidBecomeActive(sceneID: opened)
        }

        #expect(directory.terminalAccess(sceneID: opened, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: first, hostID: hostID)
                == .liveInAnotherWindow)
        #expect(
            directory.terminalAccess(sceneID: second, hostID: hostID)
                == .liveInAnotherWindow)
    }

    @Test func aSharedHostIsLiveOnlyInTheKeyWindow() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)

        #expect(directory.terminalAccess(sceneID: second, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: first, hostID: hostID)
                == .liveInAnotherWindow)

        directory.sceneDidBecomeActive(sceneID: first)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: second, hostID: hostID)
                == .liveInAnotherWindow)
    }

    @Test func takeOverHandsTheChannelToTheTappedWindow() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)
        let routing = AgentSceneRouting(directory: directory, sceneID: first)

        routing.takeOverTerminal(for: hostID)

        #expect(routing.terminalAccess(for: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: second, hostID: hostID)
                == .liveInAnotherWindow)
    }

    @Test func closingTheHoldingWindowHandsItsHostOn() {
        let directory = AgentSceneDirectory()
        let (first, second) = makeSharedHostWindows(directory)

        directory.unregister(sceneID: second)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
    }

    /// A deep link that lands an Agent of the shared Host in the key window
    /// makes that window live, like navigating there by hand.
    @Test func aDeepLinkIntoTheKeyWindowTakesTheHost() {
        let directory = AgentSceneDirectory()
        let first = UUID()
        let second = UUID()
        let firstRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        let secondRouter = makeRouter(knowing: ["w1:p1", "w1:p2"])
        directory.register(sceneID: first, router: firstRouter, activate: {})
        directory.register(sceneID: second, router: secondRouter, activate: {})
        firstRouter.path = [target("w1:p1").agentID]
        directory.sceneRouteDidChange(sceneID: first)
        directory.sceneDidBecomeActive(sceneID: first)
        directory.sceneDidBecomeActive(sceneID: second)

        directory.open(target("w1:p2"))

        #expect(secondRouter.path == [target("w1:p2").agentID])
        #expect(directory.terminalAccess(sceneID: second, hostID: hostID) == .holds)
        #expect(
            directory.terminalAccess(sceneID: first, hostID: hostID)
                == .liveInAnotherWindow)
    }

    /// A window on an Agent the Console no longer lists has no terminal to
    /// run, so it takes nothing from the window that does.
    @Test func anUnlistedAgentClaimsNoChannel() {
        let directory = AgentSceneDirectory()
        let first = UUID()
        let second = UUID()
        let firstRouter = makeRouter(knowing: ["w1:p1"])
        let secondRouter = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: first, router: firstRouter, activate: {})
        directory.register(sceneID: second, router: secondRouter, activate: {})
        firstRouter.path = [target("w1:p1").agentID]
        directory.sceneRouteDidChange(sceneID: first)
        directory.sceneDidBecomeActive(sceneID: first)

        secondRouter.path = [target("w1:gone").agentID]
        directory.sceneRouteDidChange(sceneID: second)
        directory.sceneDidBecomeActive(sceneID: second)

        #expect(directory.terminalAccess(sceneID: first, hostID: hostID) == .holds)
    }
}
