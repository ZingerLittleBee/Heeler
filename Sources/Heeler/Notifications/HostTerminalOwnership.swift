import Foundation

/// What one window's Agent detail may do with its Host's terminal channel.
enum HostTerminalAccess: Equatable, Sendable {
    /// This window holds the channel, nothing else wants it, or this window
    /// does not claim that Host and so has nothing to hand over.
    case holds
    /// Another window of the app holds it. `canTakeOver` is false while that
    /// window shows a Shell Terminal, which has no rejoin path to hand over.
    case liveInAnotherWindow(canTakeOver: Bool)
}

/// One window's claim on a Host's terminal channel: the Agent detail it has
/// on screen, on that Agent's Host.
struct HostTerminalClaim: Equatable, Sendable {
    let sceneID: UUID
    let hostID: Host.ID
    /// The window shows a Shell Terminal (or is opening one) for its Agent
    /// rather than the Agent's Attach.
    let isShellTerminal: Bool
}

/// Which window owns each Host's interactive Agent presentation, as a pure
/// decision over window claims. ADR 0017 allows retained idle terminals and
/// separate shell viewers alongside it; those use the shared retention budget.
///
/// Only one window actively presents an Agent on a given Host. Other loaded
/// Agents may retain their idle PTYs until expiry or eviction. "Key window" here
/// is the window the user is working in (see `AgentSceneState`), not UIKit's
/// per-scene key window. The rule:
///
/// - The user moving into a window, or the window they work in turning to a
///   Host, takes that Host's channel: the window being worked in is live.
/// - Otherwise the holder keeps it, so a background window navigating never
///   pulls the channel out from under the window being worked in.
/// - An explicit takeover moves it at once and holds until the user next
///   moves into another window.
/// - A Host whose holder stops claiming it passes to the key window if that
///   window claims it, else to the first-connected window that does.
/// - A holder showing a Shell Terminal is never handed away.
///
/// Hosts claimed by one window only are unaffected: that window holds. A
/// window that does not claim a Host (not on one of its Agents, or not yet
/// reconciled onto one) reads `.holds` for it: Live in Another Window is
/// only for a window that wants the channel.
struct HostTerminalOwnership: Equatable, Sendable {
    private(set) var holders: [Host.ID: UUID] = [:]
    /// The key window and the Host it claimed at the previous reconcile; a
    /// change to either is the key edge that hands a channel over.
    private var lastKeySceneID: UUID?
    private var lastKeyHostID: Host.ID?

    init() {}

    /// Re-derives every Host's holder. `claims` is in window connection
    /// order, at most one per window; `keySceneID` is the window most
    /// recently worked in, claiming or not.
    mutating func reconcile(claims: [HostTerminalClaim], keySceneID: UUID?) {
        let keyClaim = claims.first { $0.sceneID == keySceneID }
        let isKeyEdge =
            keyClaim != nil
            && (keySceneID != lastKeySceneID || keyClaim?.hostID != lastKeyHostID)
        lastKeySceneID = keySceneID
        lastKeyHostID = keyClaim?.hostID

        var next: [Host.ID: UUID] = [:]
        for claim in claims where next[claim.hostID] == nil {
            let hostID = claim.hostID
            let current = holders[hostID].flatMap { holder in
                claims.first { $0.sceneID == holder && $0.hostID == hostID }
            }
            if let keyClaim, keyClaim.hostID == hostID, isKeyEdge,
                current?.isShellTerminal != true
            {
                next[hostID] = keyClaim.sceneID
            } else if let current {
                next[hostID] = current.sceneID
            } else if let keyClaim, keyClaim.hostID == hostID {
                next[hostID] = keyClaim.sceneID
            } else {
                next[hostID] = claim.sceneID
            }
        }
        holders = next
    }

    /// Moves `hostID`'s channel to `sceneID` on the user's explicit request.
    /// False when that window does not claim the Host or the holder shows a
    /// Shell Terminal.
    @discardableResult
    mutating func takeOver(
        hostID: Host.ID, sceneID: UUID, claims: [HostTerminalClaim]
    ) -> Bool {
        guard claims.contains(where: { $0.sceneID == sceneID && $0.hostID == hostID })
        else { return false }
        if let holder = holders[hostID], holder != sceneID,
            claims.contains(where: {
                $0.sceneID == holder && $0.hostID == hostID && $0.isShellTerminal
            })
        {
            return false
        }
        holders[hostID] = sceneID
        return true
    }

    func access(
        sceneID: UUID, hostID: Host.ID, claims: [HostTerminalClaim]
    ) -> HostTerminalAccess {
        guard claims.contains(where: { $0.sceneID == sceneID && $0.hostID == hostID }),
            let holder = holders[hostID], holder != sceneID,
            let holderClaim = claims.first(where: {
                $0.sceneID == holder && $0.hostID == hostID
            })
        else { return .holds }
        return .liveInAnotherWindow(canTakeOver: !holderClaim.isShellTerminal)
    }
}
