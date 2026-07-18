import Foundation
import Observation

/// The Console's state store (#8): the flat, status-sorted Agent list across
/// all Hosts, snapshot-then-delta from day one (spec #20).
///
/// There is no replay-on-subscribe, so every `.connected` from a Host's
/// `EventsSession` triggers an explicit `session.snapshot` re-fetch; between
/// snapshots, `pane.agent_status_changed` deltas mutate rows in place.
/// Membership and context changes (agent detected, pane closed, workspace
/// renamed, ...) re-snapshot the Host instead of patching state
/// speculatively — one cheap RPC beats replicating herdr's tree logic.
///
/// Because `pane.agent_status_changed` subscribes per pane id, each snapshot
/// also pushes the current pane set into the session via
/// `updateSubscriptions`; a changed set costs one immediate re-subscribe and
/// converges on the follow-up snapshot.
@MainActor
@Observable
final class ConsoleStore {
    /// The Console list, sorted Blocked > Working > Idle/Done.
    private(set) var agents: [ConsoleAgent] = []
    /// Per-Host events-session status; the UI derives staleness from it.
    private(set) var hostStatuses: [Host.ID: EventsSessionStatus] = [:]

    @ObservationIgnored private var feeds: [Host.ID: HostFeed] = [:]
    @ObservationIgnored private let makeSession:
        @Sendable (Host, [EventSubscription]) -> EventsSession
    /// Whether the Console should hold live connections (foregrounded);
    /// feeds started while suspended stay down until `resume()`.
    @ObservationIgnored private var isActive = false

    init(
        makeSession: @escaping @Sendable (Host, [EventSubscription]) -> EventsSession =
            ConsoleStore.sshSessionFactory()
    ) {
        self.makeSession = makeSession
    }

    // MARK: Host reconciliation

    /// Aligns the feeds with the Host catalog: new Hosts get a session,
    /// removed Hosts lose theirs, edited Hosts get a fresh one (their
    /// connection coordinates may have changed).
    func setHosts(_ hosts: [Host]) {
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        for (id, feed) in feeds where incoming[id] != feed.host {
            endFeed(feed)
            feeds[id] = nil
            hostStatuses[id] = nil
        }
        for host in hosts where feeds[host.id] == nil {
            startFeed(for: host)
        }
        rebuild()
    }

    /// Brings every Host's events session up (launch, foregrounding).
    func resume() async {
        isActive = true
        for feed in feeds.values {
            await feed.session.resume()
        }
    }

    /// Tears every session down deliberately (backgrounding).
    func suspend() async {
        isActive = false
        for feed in feeds.values {
            await feed.session.suspend()
        }
    }

    private func startFeed(for host: Host) {
        let session = makeSession(host, Self.subscriptions(paneIDs: []))
        let feed = HostFeed(host: host, session: session)
        feeds[host.id] = feed
        feed.consumeTask = Task { [weak self] in
            for await update in session.updates {
                guard let self else { return }
                self.handle(update, feed: feed)
            }
        }
        if isActive {
            Task { await session.resume() }
        }
    }

    private func endFeed(_ feed: HostFeed) {
        feed.resyncPending = false
        Task { await feed.session.end() }
    }

    // MARK: Snapshot-then-delta

    private func handle(_ update: EventsSessionUpdate, feed: HostFeed) {
        // A removed Host's session still drains its final updates; they must
        // not resurrect its rows or status.
        guard feeds[feed.host.id] === feed else { return }
        switch update {
        case .status(let status):
            hostStatuses[feed.host.id] = status
            if status == .connected {
                scheduleResync(feed: feed)
            }
        case .event(let event):
            if event.kind == PaneEventKind.agentStatusChanged.kind {
                applyStatusChange(event.data, feed: feed)
            } else if Self.resyncEventKinds.contains(event.kind) {
                scheduleResync(feed: feed)
            }
        }
    }

    /// Runs one re-snapshot per Host at a time; signals arriving mid-run
    /// coalesce into a single follow-up run.
    private func scheduleResync(feed: HostFeed) {
        if feed.resyncTask != nil {
            feed.resyncPending = true
            return
        }
        feed.resyncTask = Task { [weak self] in
            await self?.runResync(feed: feed)
            guard let self else { return }
            feed.resyncTask = nil
            if feed.resyncPending {
                feed.resyncPending = false
                self.scheduleResync(feed: feed)
            }
        }
    }

    private func runResync(feed: HostFeed) async {
        guard let transport = await feed.session.currentTransport else { return }
        do {
            let snapshot = try await transport.sessionSnapshot()
            guard feeds[feed.host.id] === feed else { return }
            apply(snapshot, to: feed)
            await feed.session.updateSubscriptions(
                Self.subscriptions(paneIDs: feed.byPane.keys))
            refreshSnippets(feed: feed, transport: transport)
        } catch {
            // Keep the last known rows. If the connection is actually dead,
            // the session's own machinery notices and re-issues `.connected`
            // after reconnecting, which schedules the next attempt.
        }
    }

    private func apply(_ snapshot: SessionSnapshot, to feed: HostFeed) {
        let workspaces = Dictionary(
            snapshot.workspaces.map { ($0.workspaceID, $0) }) { first, _ in first }
        var byPane: [String: ConsoleAgent] = [:]
        for info in snapshot.agents {
            let agent = Agent(info)
            let workspace = workspaces[agent.workspaceID]
            byPane[agent.paneID] = ConsoleAgent(
                hostID: feed.host.id,
                hostName: feed.host.displayName,
                agent: agent,
                workspaceLabel: workspace?.label,
                repoName: workspace?.worktree?.repoName,
                lastOutputSnippet: feed.byPane[agent.paneID]?.lastOutputSnippet)
        }
        feed.byPane = byPane
        rebuild()
    }

    private func applyStatusChange(_ data: JSONValue, feed: HostFeed) {
        guard
            let paneID = data["pane_id"]?.stringValue,
            let rawStatus = data["agent_status"]?.stringValue,
            var row = feed.byPane[paneID]
        else { return }
        row.agent.status = AgentStatus(rawValue: rawStatus)
        feed.byPane[paneID] = row
        rebuild()
        // A status flip usually means fresh output worth showing — for
        // Blocked, it is the very question the user must answer.
        Task { [weak self] in
            guard let transport = await feed.session.currentTransport else { return }
            self?.refreshSnippet(feed: feed, paneID: paneID, transport: transport)
        }
    }

    private func rebuild() {
        agents = feeds.values.flatMap { $0.byPane.values }.consoleSorted()
    }

    // MARK: Last-output snippets

    /// `pane.read` line budget per snippet fetch; the card shows the
    /// trailing non-blank line of that window.
    private static let snippetReadLines = 6

    private func refreshSnippets(feed: HostFeed, transport: any Transport) {
        for paneID in feed.byPane.keys {
            refreshSnippet(feed: feed, paneID: paneID, transport: transport)
        }
    }

    private func refreshSnippet(feed: HostFeed, paneID: String, transport: any Transport) {
        // One in-flight read per pane; a burst of status flips must not pile
        // requests onto the slot queue.
        guard feed.snippetFetchesInFlight.insert(paneID).inserted else { return }
        Task { [weak self] in
            let read = try? await transport.readPane(
                PaneReadParams(
                    paneID: paneID, source: .recent, lines: Self.snippetReadLines,
                    stripANSI: true))
            guard let self else { return }
            feed.snippetFetchesInFlight.remove(paneID)
            guard
                let read, self.feeds[feed.host.id] === feed,
                var row = feed.byPane[paneID]
            else { return }
            row.lastOutputSnippet = Self.snippet(fromPaneText: read.text)
            feed.byPane[paneID] = row
            self.rebuild()
        }
    }

    /// The card snippet: the trailing non-blank line, whitespace-trimmed.
    static func snippet(fromPaneText text: String) -> String? {
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: Detail-screen transport access

    /// The Host's live transport for detail-screen RPCs (Observe backfill
    /// and live-follow, #9). A closure rather than a value: the events
    /// session may reconnect onto a fresh transport at any time, so it is
    /// re-queried per use; nil while the Host is disconnected or gone.
    func transportProvider(for hostID: Host.ID) -> @Sendable () async -> (any Transport)? {
        let session = feeds[hostID]?.session
        return { await session?.currentTransport }
    }

    // MARK: Subscriptions

    /// Global membership/context kinds; each triggers a Host re-snapshot.
    private static let membershipKinds: [GlobalEventKind] = [
        .paneAgentDetected, .paneClosed, .paneExited,
        .workspaceRenamed, .workspaceMetadataUpdated, .workspaceClosed,
    ]
    private static let resyncEventKinds = Set(membershipKinds.map(\.kind))

    /// One Host's Console subscription set: the global kinds plus a per-pane
    /// `pane.agent_status_changed` for every known Agent pane — the status
    /// kind is pane-scoped (verified against herdr 0.7.4: a bare
    /// subscription is rejected with `missing field pane_id`).
    static func subscriptions(paneIDs: some Sequence<String>) -> [EventSubscription] {
        membershipKinds.map(EventSubscription.global)
            + paneIDs.sorted().map { EventSubscription.pane(.agentStatusChanged, paneID: $0) }
    }
}

extension ConsoleStore {
    /// The production session factory: SSH transports built from the Host
    /// catalog's credentials. TOFU is restricted to already-trusted
    /// fingerprints — the Console never prompts; a Host that was never
    /// onboarded fails into `.reconnecting` with the host-key error until
    /// its onboarding checklist trusts it.
    static func sshSessionFactory(
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore(),
        credentials: HostCredentialsProvider = HostCredentialsProvider()
    ) -> @Sendable (Host, [EventSubscription]) -> EventsSession {
        { host, subscriptions in
            EventsSession(subscriptions: subscriptions) {
                let resolved = try credentials.credentials(for: host)
                let policy = HostKeyPolicy(knownHosts: knownHosts) { _ in false }
                return try await connector.connect(
                    settings: SSHTransportSettings(
                        host: host, credentials: resolved, hostKeyPolicy: policy))
            }
        }
    }
}

/// One Host's live feed: its events session plus the rows built from its
/// snapshots. A class so racing tasks can check identity (`===`) after the
/// Host was removed or replaced.
@MainActor
private final class HostFeed {
    let host: Host
    let session: EventsSession
    var consumeTask: Task<Void, Never>?
    var resyncTask: Task<Void, Never>?
    var resyncPending = false
    var byPane: [String: ConsoleAgent] = [:]
    var snippetFetchesInFlight: Set<String> = []

    init(host: Host, session: EventsSession) {
        self.host = host
        self.session = session
    }
}
