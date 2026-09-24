import Foundation
import Observation
import SwiftUI
import UIKit

/// What the deep-link policy needs to know about one connected window.
///
/// "Key window" throughout this file and `HostTerminalOwnership` means the
/// window the user is working in: the one with the highest activation order,
/// which a touch, click, or key press in a window advances (see
/// `AgentSceneDirectory.sceneDidReceiveInteraction`). It is not UIKit's key
/// window, which since iOS 15 is per scene, so every on-screen Heeler window
/// is one.
struct AgentSceneState: Equatable, Sendable {
    let id: UUID
    /// The Agent the window shows, or is waiting to show once its pane syncs.
    let presentedAgent: ConsoleAgent.ID?
    /// Higher is more recently worked in; zero for a window that never was.
    let activationOrder: UInt64
}

/// Whether a window's scene turning active counts as the user moving to it.
///
/// Every Heeler window turns active together when the app returns to the
/// foreground, in no defined order, so a scene-phase edge says nothing about
/// which window the user is working in; letting it count would hand a
/// Host's terminal to whichever window happened to report last. Interaction
/// says that instead. The exception is a newly opened window — Open in New
/// Window, a dragged row, a first launch — which the user just asked for and
/// should land on live: its first activation counts, once. A window restored
/// from its scene storage waits for the user's first touch like any other.
struct SceneActivationTracker: Equatable, Sendable {
    private var countsNextActivation: Bool

    init(isRestored: Bool) {
        countsNextActivation = !isRestored
    }

    /// True for the first activation of a newly opened window only.
    mutating func sceneDidBecomeActive() -> Bool {
        defer { countsNextActivation = false }
        return countsNextActivation
    }
}

/// Where one deep link lands.
enum AgentDeepLinkDecision: Equatable, Sendable {
    /// A window already shows the target: bring that window forward.
    case activate(sceneID: UUID)
    /// No window shows it: navigate this one, the key window.
    case route(sceneID: UUID)
    /// No window is connected yet (a killed-state launch); hold the link
    /// until one is.
    case awaitScene
}

/// The single-window rule for Agent Notification taps, Live Activity links,
/// in-app banners, and dragged rows, as a pure decision. A deep link never
/// opens a second window: an Agent already on screen is activated where it
/// is, and anything else lands in the key window. A second window on the
/// same Agent would also contend for the Host's one terminal channel.
enum AgentDeepLinkPolicy {
    static func decide(
        target: ConsoleAgent.ID?,
        scenes: [AgentSceneState],
        preferredSceneID: UUID?
    ) -> AgentDeepLinkDecision {
        guard !scenes.isEmpty else { return .awaitScene }
        if let target,
            let presenting = presentingScene(
                for: target, in: scenes, preferredSceneID: preferredSceneID)
        {
            return .activate(sceneID: presenting)
        }
        if let preferredSceneID, scenes.contains(where: { $0.id == preferredSceneID }) {
            return .route(sceneID: preferredSceneID)
        }
        return keyScene(in: scenes).map { .route(sceneID: $0) } ?? .awaitScene
    }

    /// The window already showing `agent`, preferring `preferredSceneID`
    /// and then the most recently active one if, unexpectedly, several do.
    static func presentingScene(
        for agent: ConsoleAgent.ID,
        in scenes: [AgentSceneState],
        preferredSceneID: UUID?
    ) -> UUID? {
        let presenting = scenes.filter { $0.presentedAgent == agent }
        if let preferredSceneID, presenting.contains(where: { $0.id == preferredSceneID }) {
            return preferredSceneID
        }
        return keyScene(in: presenting)
    }

    /// The most recently activated window; the first connected one breaks
    /// ties, so the answer is stable before any window has been active.
    static func keyScene(in scenes: [AgentSceneState]) -> UUID? {
        var best: AgentSceneState?
        for scene in scenes {
            if let current = best, scene.activationOrder <= current.activationOrder { continue }
            best = scene
        }
        return best?.id
    }
}

/// Whether a registered window is still on screen. SwiftUI's `onDisappear`
/// makes no promise about closed or system-disconnected scenes, so the
/// directory asks the window itself rather than trusting `unregister` to
/// have run.
enum AgentSceneWindowState: Equatable, Sendable {
    /// Not attached to a `UIWindow` yet; a window that just registered counts
    /// as live.
    case pending
    case connected
    /// Its `UIWindow` is gone, or its scene is unattached.
    case disconnected

    /// `hasAttached` is whether a window was ever attached; `activationState`
    /// is that window's scene state, nil when the window or its scene is gone.
    static func resolve(
        hasAttached: Bool, activationState: UIScene.ActivationState?
    ) -> AgentSceneWindowState {
        guard hasAttached else { return .pending }
        guard let activationState, activationState != .unattached else {
            return .disconnected
        }
        return .connected
    }
}

/// The window handle a scene registers with, so the directory can skip a
/// window that closed without delivering `onDisappear`.
@MainActor
protocol AgentSceneWindow: AnyObject {
    var sceneWindowState: AgentSceneWindowState { get }
}

/// The app-wide registry of connected windows and the one place deep links
/// enter. Each window owns its own `AgentNotificationRouter`; this directory
/// decides which of those routers a link drives, through
/// `AgentDeepLinkPolicy`, and brings that window forward.
///
/// It also decides which window holds each Host's single terminal channel,
/// through `HostTerminalOwnership`. Windows read their access from here; the
/// one that loses the channel releases its Attach and the one that gains it
/// rejoins, both through the Attach store's existing leave and rejoin.
@MainActor
@Observable
final class AgentSceneDirectory {
    private struct Entry {
        let router: AgentNotificationRouter
        let window: (any AgentSceneWindow)?
        let activate: @MainActor () -> Void
        var activationOrder: UInt64 = 0
    }

    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    /// Connection order, so iteration and tie-breaks are deterministic.
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var activationClock: UInt64 = 0
    /// A link that arrived before any window connected. The inner optional
    /// is the link itself: nil means "the Console".
    @ObservationIgnored private var pendingOpen: AgentNotificationTarget??
    /// Observed: each window's Agent detail re-reads its access when either
    /// changes.
    private var terminalClaims: [HostTerminalClaim] = []
    private var terminalOwnership = HostTerminalOwnership()

    init() {}

    /// Connects a window. `activate` brings it forward when a link picks it;
    /// it must be a no-op for a window that is already frontmost. `window`
    /// reports whether the window is still on screen; nil counts as live.
    func register(
        sceneID: UUID,
        router: AgentNotificationRouter,
        window: (any AgentSceneWindow)? = nil,
        activate: @escaping @MainActor () -> Void
    ) {
        let activationOrder = entries[sceneID]?.activationOrder ?? 0
        entries[sceneID] = Entry(
            router: router, window: window, activate: activate,
            activationOrder: activationOrder)
        if !order.contains(sceneID) {
            order.append(sceneID)
        }
        if let pending = pendingOpen {
            pendingOpen = nil
            open(pending, preferredSceneID: sceneID)
        } else {
            reconcileTerminalOwnership()
        }
    }

    func unregister(sceneID: UUID) {
        entries[sceneID] = nil
        order.removeAll { $0 == sceneID }
        reconcileTerminalOwnership()
    }

    /// Records that the user is now working in this window: the landing spot
    /// for links no window is already showing, and the window that takes its
    /// Host's terminal channel. Fed by `sceneDidReceiveInteraction` and by a
    /// newly opened window's first activation (`SceneActivationTracker`).
    func sceneDidBecomeActive(sceneID: UUID) {
        guard entries[sceneID] != nil else { return }
        activationClock &+= 1
        entries[sceneID]?.activationOrder = activationClock
        reconcileTerminalOwnership()
    }

    /// A touch, click, or key press reached this window. Only a move from
    /// another window counts; interaction inside the window already worked in
    /// returns at once, so this is cheap on every event.
    func sceneDidReceiveInteraction(sceneID: UUID) {
        guard let entry = liveEntry(sceneID),
            activationClock == 0 || entry.activationOrder != activationClock
        else { return }
        sceneDidBecomeActive(sceneID: sceneID)
    }

    /// A window's navigation or its Agent list changed, so what it claims
    /// may have too.
    func sceneRouteDidChange(sceneID: UUID) {
        guard entries[sceneID] != nil else { return }
        reconcileTerminalOwnership()
    }

    func terminalAccess(sceneID: UUID, hostID: Host.ID) -> HostTerminalAccess {
        terminalOwnership.access(sceneID: sceneID, hostID: hostID, claims: terminalClaims)
    }

    /// Take Over Here: moves the Host's channel to this window now, instead
    /// of when the user next moves into it.
    func takeOverTerminal(sceneID: UUID, hostID: Host.ID) {
        reconcileTerminalOwnership()
        var ownership = terminalOwnership
        guard ownership.takeOver(hostID: hostID, sceneID: sceneID, claims: terminalClaims)
        else { return }
        if ownership != terminalOwnership {
            terminalOwnership = ownership
        }
    }

    private func reconcileTerminalOwnership() {
        let claims = order.compactMap { id -> HostTerminalClaim? in
            guard let entry = liveEntry(id), let agent = entry.router.path.last,
                entry.router.isKnownAgent(agent)
            else { return nil }
            return HostTerminalClaim(sceneID: id, hostID: agent.hostID)
        }
        var ownership = terminalOwnership
        ownership.reconcile(claims: claims, keySceneID: AgentDeepLinkPolicy.keyScene(in: scenes))
        // Assigned only on change, so an unrelated reconcile does not
        // invalidate every window's detail.
        if claims != terminalClaims {
            terminalClaims = claims
        }
        if ownership != terminalOwnership {
            terminalOwnership = ownership
        }
    }

    /// A registered window that is still on screen. A closed window that
    /// never delivered `onDisappear` must not swallow Open in New Window, a
    /// deep link, or its Host's terminal channel.
    private func liveEntry(_ sceneID: UUID) -> Entry? {
        guard let entry = entries[sceneID],
            entry.window?.sceneWindowState != .disconnected
        else { return nil }
        return entry
    }

    var scenes: [AgentSceneState] {
        order.compactMap { id in
            guard let entry = liveEntry(id) else { return nil }
            return AgentSceneState(
                id: id,
                presentedAgent: entry.router.path.last ?? entry.router.pendingTarget?.agentID,
                activationOrder: entry.activationOrder)
        }
    }

    /// What the key window shows; the in-app banner suppresses itself for it.
    var keyScenePresentedAgent: ConsoleAgent.ID? {
        let scenes = scenes
        guard let key = AgentDeepLinkPolicy.keyScene(in: scenes) else { return nil }
        return scenes.first(where: { $0.id == key })?.presentedAgent
    }

    /// Routes one deep link under the single-window rule. `preferredSceneID`
    /// is the window the link arrived through, when there is one — a banner
    /// tap, a URL opened into that window.
    func open(_ target: AgentNotificationTarget?, preferredSceneID: UUID? = nil) {
        let decision = AgentDeepLinkPolicy.decide(
            target: target?.agentID, scenes: scenes, preferredSceneID: preferredSceneID)
        switch decision {
        case .awaitScene:
            pendingOpen = .some(target)
        case .activate(let sceneID), .route(let sceneID):
            pendingOpen = nil
            guard let entry = entries[sceneID] else { return }
            entry.router.open(target)
            reconcileTerminalOwnership()
            entry.activate()
        }
    }

    /// Brings forward the window already showing `agent`. False when none
    /// does, so the caller can open a new window instead.
    func activateScene(presenting agent: ConsoleAgent.ID) -> Bool {
        guard
            let sceneID = AgentDeepLinkPolicy.presentingScene(
                for: agent, in: scenes, preferredSceneID: nil),
            let entry = entries[sceneID]
        else { return false }
        entry.activate()
        return true
    }
}

/// The window-aware way into a window's navigation, provided to its Console
/// by the scene root. Links raised inside a window — a banner tap, Open in
/// New Window — still obey the single-window rule, with that window as the
/// preferred landing spot.
struct AgentSceneRouting: Equatable {
    let directory: AgentSceneDirectory
    let sceneID: UUID

    static func == (lhs: AgentSceneRouting, rhs: AgentSceneRouting) -> Bool {
        lhs.directory === rhs.directory && lhs.sceneID == rhs.sceneID
    }

    @MainActor
    func open(_ target: AgentNotificationTarget?) {
        directory.open(target, preferredSceneID: sceneID)
    }

    @MainActor
    func terminalAccess(for hostID: Host.ID) -> HostTerminalAccess {
        directory.terminalAccess(sceneID: sceneID, hostID: hostID)
    }

    @MainActor
    func takeOverTerminal(for hostID: Host.ID) {
        directory.takeOverTerminal(sceneID: sceneID, hostID: hostID)
    }
}

extension EnvironmentValues {
    /// Nil outside a scene root (previews, hosted test views, the screenshot
    /// mode), where the Console drives its own router directly.
    @Entry var agentSceneRouting: AgentSceneRouting? = nil
}
