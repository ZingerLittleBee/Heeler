import Foundation

extension TransportError {
    /// Whether this is a failure of one Server on a Host that was reached
    /// and signed in to: the Server is missing, stopped, too old, or refused
    /// what was asked of it. Everything else is the connection's, which the
    /// Host's Servers share (ADR 0058).
    var isServerFailure: Bool {
        switch self {
        case .socketNotFound, .herdrBinaryNotFound, .herdrLauncherNotFound, .streamLocalOpenFailed,
            .protocolVersionMismatch, .homeDirectoryUnresolvable, .herdrCoreNotInstalled,
            .herdrCoreNotRunning, .herdrCoreForwardingRefused, .herdrCoreUpdateRequired,
            .herdrCoreSocketPathTooLong, .herdrCoreSessionNameRefused, .herdrCoreInventoryStale,
            .herdrCoreTerminalGone, .tmuxNotInstalled, .tmuxUpdateRequired, .tmuxServerNotRunning,
            .tmuxStartOnMac, .tmuxPaneGone, .tmuxServerGone, .rexTerminalOutputUnavailable,
            .rexTerminalHistoryTooLong, .rexServerGone, .rexNotInstalled, .rexLookupFailed,
            .rexServerNotRunning, .rexForwardingRefused, .rexSocketUnreachable, .rexAccountRefused,
            .rexUnsupportedRevision, .rexRejected, .rexAnswerUnreadable, .rexScreenUnreadable,
            .malformedResponse, .apiRejected,
            .hostFeatureUnavailable, .eventsChannelAlreadyOpen, .terminalChannelAlreadyOpen,
            .invalidDirectoryPath, .gitTimedOut, .coreMutationOutcomeUnknown, .hostFileTimedOut,
            .hostFileUnreadable, .hostStoreUnreadable, .attachExited:
            true
        case .sshUnreachable, .jumpHostFailed, .overlayFailed, .noRouteReached,
            .tcpForwardingUnavailable, .authenticationFailed, .deviceKeyCorrupt, .rsaKeyCorrupt,
            .rsaSignatureUnsupported, .hostKeyRejected, .hostKeyMismatch, .timedOut, .cancelled,
            .channelFailed:
            false
        }
    }
}

extension EventsSessionStatus {
    /// The Console is dialing, or between automatic retries.
    var isDialing: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .connected, .failed, .suspended, .ended: false
        }
    }

    /// The failure a dial stopped on or is retrying past.
    var failure: TransportError? {
        switch self {
        case .reconnecting(_, _, let failure), .failed(let failure): failure
        case .connecting, .connected, .suspended, .ended: nil
        }
    }
}

/// What Host detail's look at the Host owes the Host's connection (ADR 0058).
/// The Console never asks about a key and waits out its backoff. A look asks,
/// and one that reaches the Host shows there is nothing left to wait for.
struct HostLookFollowUp: Equatable {
    /// A dial stopped at a key nobody has confirmed, so a look is due: only
    /// a look may ask about it.
    let asksForKey: Bool
    /// The Servers a look that reached the Host dials again at once: on, and
    /// stopped on or backing off from a failure of the connection. One the
    /// user stopped, and one whose own Server is missing, stay as they are.
    let redials: [Host.ID]

    init(servers: [(id: Host.ID, status: EventsSessionStatus?)]) {
        let waiting = servers.compactMap { server -> (Host.ID, TransportError)? in
            guard let failure = server.status?.failure, !failure.isServerFailure else { return nil }
            return (server.id, failure)
        }
        asksForKey = waiting.contains { $0.1.isDeclinedHostKey }
        redials = waiting.map(\.0)
    }
}

/// Host detail's Routes section (ADR 0058): the one route the Host's
/// connections hold, or each route's own failure when a dial reached none,
/// and what the section's one action does.
struct HostRoutesPresentation: Equatable {
    /// One Server that is on: its record's routes, which carry ids of their
    /// own, and what the Console says of its connection.
    struct Server: Equatable {
        let routes: [HostRoute]
        let status: EventsSessionStatus?
        let routeID: HostRoute.ID?

        fileprivate func index(of id: HostRoute.ID?) -> Int? {
            guard let id else { return nil }
            return routes.firstIndex { $0.id == id }
        }
    }

    enum Footer: Equatable {
        case none
        case note(String)
        /// Why no route carries the Host, in red.
        case problem(String)
    }

    /// The route in use, as an index into the Host's routes.
    let inUse: Int?
    /// Each failed route's own reason, by index.
    let failures: [Int: String]
    /// A Server is dialing, so the action is Stop.
    let isDialing: Bool
    /// A Server is on, so there is something to reconnect.
    let offersReconnect: Bool
    let footer: Footer

    init(
        hostName: String, routeCount: Int, servers: [Server],
        isManualReconnectInFlight: Bool = false
    ) {
        let note =
            routeCount > 1
            ? String(
                localized:
                    "Every server on \(hostName) uses the first route that reaches it. Heeler moves to a direct route when one comes into reach.")
            : nil
        offersReconnect = !servers.isEmpty
        // A Reconnect press reads as dialing at once, and drops the outcome
        // it replaces.
        if isManualReconnectInFlight {
            inUse = nil
            failures = [:]
            isDialing = true
            footer = note.map(Footer.note) ?? .none
            return
        }
        isDialing = servers.contains { $0.status?.isDialing == true }
        if let connected = servers.first(where: { $0.status == .connected }) {
            inUse = connected.index(of: connected.routeID)
            failures = [:]
            footer = note.map(Footer.note) ?? .none
            return
        }
        inUse = nil
        let stopped = servers.lazy.compactMap { server -> (Server, TransportError)? in
            guard let failure = server.status?.failure, !failure.isServerFailure else { return nil }
            return (server, failure)
        }.first
        guard let (server, failure) = stopped else {
            failures = [:]
            // Nothing is dialing and nothing failed: the Servers were stopped.
            let isIdle = !servers.isEmpty && !isDialing && servers.allSatisfy { $0.status?.failure == nil }
            if isIdle {
                let notConnected = String(localized: "Not connected.")
                footer = .note(note.map { "\(notConnected) \($0)" } ?? notConnected)
            } else {
                footer = note.map(Footer.note) ?? .none
            }
            return
        }
        var routeFailures: [Int: String] = [:]
        if case .noRouteReached(let reached) = failure {
            for routeFailure in reached {
                guard let index = server.index(of: routeFailure.routeID) else { continue }
                routeFailures[index] = routeFailure.error.presentation.summary
            }
        } else if routeCount == 1 {
            routeFailures[0] = failure.presentation.summary
        }
        failures = routeFailures
        // While it retries, the tags say what the last dial met.
        guard !isDialing else {
            footer = note.map(Footer.note) ?? .none
            return
        }
        footer = .problem(Self.problem(failure, hostName: hostName, routeCount: routeCount))
    }

    private static func problem(_ failure: TransportError, hostName: String, routeCount: Int) -> String {
        guard case .noRouteReached(let reached) = failure else { return failure.presentation.message }
        // A changed key leads its own presentation: it is not an outage.
        if reached.contains(where: \.isHostKeySecurityFailure) { return failure.presentation.message }
        if reached.count == routeCount, routeCount > 1 {
            return String(
                localized:
                    "Heeler tried all \(routeCount) routes and none reached \(hostName). Check that it is awake and on a network this device can reach.")
        }
        // The tags name each route's failure; the footer adds what to do.
        return failure.presentation.recoverySuggestion ?? failure.presentation.summary.asSentence
    }
}

/// What a Server's row on Host detail says under its name: the Server's own
/// state, never the connection's, which is the Host's (ADR 0058).
struct HostServerStateLine: Equatable {
    let text: String?
    /// The Server stopped Heeler: red.
    let isProblem: Bool

    /// `found` is what the last look at the Host saw of this Server.
    init(
        found: FoundServer?, status: EventsSessionStatus?, standingFailure: TransportError? = nil,
        syncIssue: String? = nil, usesHerdrEndpoint: Bool = false
    ) {
        let seen = found?.stateLine
        switch status {
        case .connected:
            if syncIssue != nil {
                text = String(localized: "Sync issue")
            } else {
                text = seen ?? String(localized: "Running")
            }
            isProblem = false
        case .failed(let failure) where failure.isServerFailure:
            text = failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).summary
            isProblem = true
        case .reconnecting(_, _, let failure) where failure.isServerFailure:
            text = failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).summary
            isProblem = false
        case .connecting:
            // The Standing Failure is the last answer until this dial has one.
            if let standingFailure, standingFailure.isServerFailure {
                text = standingFailure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).summary
            } else {
                text = seen
            }
            isProblem = false
        case .failed, .reconnecting, .suspended, .ended, nil:
            text = seen
            isProblem = false
        }
    }
}
