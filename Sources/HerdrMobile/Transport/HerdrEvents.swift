import Foundation

/// Canonical event kind: the dotted name (`pane.created`) as herdr's
/// subscription API spells it. Event lines arrive snake_case
/// (`pane_created`); `init(wireName:)` maps either spelling here, so
/// consumers only ever see one naming.
struct HerdrEventKind: Hashable, Sendable {
    let name: String

    init(name: String) {
        self.name = name
    }

    /// Maps a wire spelling (snake_case event line, or dotted) onto the
    /// canonical kind. Unknown names pass through untouched — herdr's API
    /// has no stability guarantee, and an unknown kind must not be
    /// guess-mangled or kill the stream.
    init(wireName: String) {
        self = Self.byWireName[wireName] ?? HerdrEventKind(name: wireName)
    }

    /// All kinds herdr 0.7.4's schema declares subscribable.
    static let known: [HerdrEventKind] =
        GlobalEventKind.allCases.map(\.kind)
        + PaneEventKind.allCases.map(\.kind)
        + [paneOutputMatched]

    /// `pane.output_matched` is subscribable only with a full output-match
    /// query (`source` + `match`; verified empirically: the server rejects a
    /// bare pane id). M0 does not subscribe to it, but its events still
    /// decode canonically.
    static let paneOutputMatched = HerdrEventKind(name: "pane.output_matched")

    private static let byWireName: [String: HerdrEventKind] = {
        var table: [String: HerdrEventKind] = [:]
        for kind in known {
            table[kind.name] = kind
            table[kind.name.replacingOccurrences(of: ".", with: "_")] = kind
        }
        return table
    }()
}

/// Host-wide subscription kinds: workspace/tab/pane/worktree lifecycle,
/// `pane.agent_detected`, and layout changes. Subscribed with no params.
enum GlobalEventKind: String, CaseIterable, Sendable {
    case workspaceCreated = "workspace.created"
    case workspaceUpdated = "workspace.updated"
    case workspaceMetadataUpdated = "workspace.metadata_updated"
    case workspaceRenamed = "workspace.renamed"
    case workspaceMoved = "workspace.moved"
    case workspaceClosed = "workspace.closed"
    case workspaceFocused = "workspace.focused"
    case worktreeCreated = "worktree.created"
    case worktreeOpened = "worktree.opened"
    case worktreeRemoved = "worktree.removed"
    case tabCreated = "tab.created"
    case tabClosed = "tab.closed"
    case tabFocused = "tab.focused"
    case tabRenamed = "tab.renamed"
    case tabMoved = "tab.moved"
    case paneCreated = "pane.created"
    case paneClosed = "pane.closed"
    case paneUpdated = "pane.updated"
    case paneFocused = "pane.focused"
    case paneMoved = "pane.moved"
    case paneExited = "pane.exited"
    case paneAgentDetected = "pane.agent_detected"
    case layoutUpdated = "layout.updated"

    /// The canonical kind, for matching against incoming events.
    var kind: HerdrEventKind { HerdrEventKind(name: rawValue) }
}

/// Pane-scoped subscription kinds: their subscriptions carry a `pane_id`.
/// Consumers key these off pane lifecycle events. (`pane.output_matched` is
/// also pane-scoped but requires a full output-match query — M1.)
enum PaneEventKind: String, CaseIterable, Sendable {
    case agentStatusChanged = "pane.agent_status_changed"
    case scrollChanged = "pane.scroll_changed"

    /// The canonical kind, for matching against incoming events.
    var kind: HerdrEventKind { HerdrEventKind(name: rawValue) }
}

/// One entry in an `events.subscribe` request.
enum EventSubscription: Sendable, Equatable {
    case global(GlobalEventKind)
    case pane(PaneEventKind, paneID: String)
}

/// One event from the Host's events channel, in canonical naming.
struct HerdrEvent: Sendable, Equatable {
    let kind: HerdrEventKind
    /// Raw payload: only 3 of 26 kinds are typed in herdr's schema, so the
    /// payload stays schema-free and consumers pick the fields they know.
    let data: JSONValue
}

/// A live `events.subscribe` stream over its Host's dedicated exec channel.
///
/// Ending is explicit: call `end()`. A live exec channel does not respond to
/// Swift task cancellation (ADR 0002), so abandoning the stream without
/// `end()` leaks the channel until the SSH connection closes.
final class HerdrEventStream: Sendable {
    /// Events in arrival order. Finishes without error after `end()`,
    /// finishes throwing if the channel dies remotely.
    let events: AsyncThrowingStream<HerdrEvent, any Error>
    private let ender: @Sendable () async -> Void

    init(
        events: AsyncThrowingStream<HerdrEvent, any Error>,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.ender = ender
    }

    /// Closes the events channel explicitly and waits for its teardown; the
    /// stream then finishes without error. Idempotent.
    func end() async {
        await ender()
    }
}
