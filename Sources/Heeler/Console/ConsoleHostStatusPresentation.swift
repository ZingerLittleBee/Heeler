import Foundation

/// One Console list row for a Host's connection or snapshot condition.
///
/// Quiet rows (Paused, Connecting, Loading Agents) are informational and
/// do not navigate to Host settings. Failed and reconnecting rows still do.
/// `inventoryNoun` names what the loading row waits for on its list: the
/// token "Agents" or "Terminals", never shown as it is.
struct ConsoleHostStatusPresentation: Equatable, Identifiable {
    enum Severity: Equatable {
        case informational
        case warning
        case critical
    }

    /// The condition `status` words, kept apart from its copy so a summary
    /// counts Hosts per condition in whole localized phrases.
    enum Condition: Equatable {
        case paused
        case connecting
        case reconnecting
        case cannotConnect
        case syncIssue
        case loadingAgents
        case loadingTerminals

        /// A few words for a compact row.
        var title: String {
            switch self {
            case .paused: String(localized: "Paused")
            case .connecting: String(localized: "Connecting…")
            case .reconnecting: String(localized: "Reconnecting…")
            case .cannotConnect: String(localized: "Can't connect")
            case .syncIssue: String(localized: "Sync issue")
            case .loadingAgents: String(localized: "Loading Agents…")
            case .loadingTerminals: String(localized: "Loading Terminals…")
            }
        }

        /// "3 reconnecting": how many Hosts share the condition.
        func countText(_ count: Int) -> String {
            switch self {
            case .paused: String(localized: "\(count) paused")
            case .connecting: String(localized: "\(count) connecting")
            case .reconnecting: String(localized: "\(count) reconnecting")
            case .cannotConnect: String(localized: "\(count) can't connect")
            case .syncIssue: String(localized: "\(count) sync issue")
            case .loadingAgents: String(localized: "\(count) loading agents")
            case .loadingTerminals: String(localized: "\(count) loading terminals")
            }
        }
    }

    /// The catalog record the condition is keyed by: the Server's own, or
    /// its Host's first where it speaks for the Host (`perHost`), so the
    /// Host keeps one identity whichever Server leads.
    let hostID: Host.ID
    /// The Server whose condition this is, by its catalog record.
    let serverID: Host.ID
    let hostName: String
    let message: String
    /// `message` for a row under the Host's own section header, which
    /// already names it: a failure without the "studio: " before it.
    let sectionMessage: String
    let systemImage: String
    let severity: Severity
    let navigates: Bool
    /// The badge on the Host's server glyph, as on its section header.
    let tone: HostConnectionTone
    let condition: Condition
    /// Connected but loading or out of sync, rather than without a
    /// connection at all.
    let isConnected: Bool

    var id: Host.ID { hostID }
    var isCritical: Bool { severity == .critical }
    /// A few words for a compact row: "Reconnecting…", "Can't connect".
    var status: String { condition.title }

    /// `group` is the Host the condition speaks for, when it does
    /// (`perHost`): it then names the Host alone, not this Server of it.
    init?(
        host: Host,
        speakingFor group: ConsoleHostSectionGroup? = nil,
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        isAwaitingSnapshot: Bool = false,
        syncError: String?,
        inventoryNoun: String = "Agents"
    ) {
        hostID = group?.servers.first?.id ?? host.id
        serverID = host.id
        let name = group?.name ?? host.displayName
        hostName = name
        isConnected = if case .connected = status { true } else { false }
        let usesHerdrEndpoint = host.herdrEndpoint != nil
        // What follows a "studio: " prefix, where the message has one.
        var unprefixed: String?
        switch status {
        case .suspended:
            message = String(localized: "Connection to \(name) is paused.")
            systemImage = "pause.circle"
            severity = .informational
            navigates = false
            (tone, condition) = (.paused, .paused)
        case .connecting:
            if let standingFailure {
                (message, systemImage, severity, navigates) = Self.failed(
                    standingFailure, hostName: name,
                    usesHerdrEndpoint: usesHerdrEndpoint)
                unprefixed = standingFailure.presentation(
                    usesHerdrEndpoint: usesHerdrEndpoint).message
                (tone, condition) = Self.cannotConnect
            } else {
                message = String(localized: "Connecting to \(name)…")
                systemImage = "dot.radiowaves.left.and.right"
                severity = .informational
                navigates = false
                (tone, condition) = (.pending, .connecting)
            }
        case .reconnecting(_, _, let failure):
            let summary = failure.presentation.summary
            message = String(localized: "Reconnecting to \(name): \(summary)")
            systemImage = "wifi.exclamationmark"
            severity = .warning
            navigates = true
            (tone, condition) = (.reconnecting, .reconnecting)
        case .failed(let failure):
            (message, systemImage, severity, navigates) = Self.failed(
                failure, hostName: name, usesHerdrEndpoint: usesHerdrEndpoint)
            unprefixed = failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).message
            (tone, condition) = Self.cannotConnect
        case .connected:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: name)
                unprefixed = syncError
                (tone, condition) = Self.syncIssue
            } else if isAwaitingSnapshot {
                let loadsTerminals = inventoryNoun == "Terminals"
                message = loadsTerminals
                    ? String(localized: "Loading Terminals from \(name)…")
                    : String(localized: "Loading Agents from \(name)…")
                systemImage = "hourglass"
                severity = .informational
                navigates = false
                (tone, condition) = (.pending, loadsTerminals ? .loadingTerminals : .loadingAgents)
            } else {
                return nil
            }
        case .ended, nil:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: name)
                unprefixed = syncError
                (tone, condition) = Self.syncIssue
            } else {
                return nil
            }
        }
        sectionMessage = unprefixed ?? message
    }

    private static let cannotConnect: (HostConnectionTone, Condition) = (.unavailable, .cannotConnect)
    private static let syncIssue: (HostConnectionTone, Condition) = (.warning, .syncIssue)

    private static func failed(
        _ failure: TransportError, hostName: String, usesHerdrEndpoint: Bool
    ) -> (String, String, Severity, Bool) {
        (
            String(localized: "\(hostName): \(failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).message)"),
            failure.isHostKeySecurityFailure
                ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
            failure.isHostKeySecurityFailure ? .critical : .warning,
            true
        )
    }

    private static func syncError(
        _ syncError: String, hostName: String
    ) -> (String, String, Severity, Bool) {
        (
            String(localized: "\(hostName): \(syncError)"),
            "arrow.trianglehead.2.clockwise",
            .warning,
            true
        )
    }
}

extension ConsoleHostStatusPresentation {
    /// One condition for each Host among `hosts`, the records of the Servers
    /// that are on, in the Hosts tab's order: the connection is the Host's
    /// (ADR 0058), so the Servers of one Host never each take a row. A Host
    /// with nothing to say has none.
    static func perHost(
        _ hosts: [Host],
        statuses: [Host.ID: EventsSessionStatus],
        standingFailures: [Host.ID: TransportError],
        awaitingSnapshot: Set<Host.ID>,
        syncErrors: [Host.ID: String],
        inventoryNoun: String = "Agents"
    ) -> [ConsoleHostStatusPresentation] {
        ConsoleHostSectionGroup.grouping(hosts).compactMap {
            ranked(
                $0, statuses: statuses, standingFailures: standingFailures,
                awaitingSnapshot: awaitingSnapshot, syncErrors: syncErrors,
                inventoryNoun: inventoryNoun
            ).first
        }
    }

    /// The conditions that speak for one Host, the one it reads as first, as
    /// the Hosts tab reads a Host (`HostMachineRowPresentation`). While a
    /// Server is connected the Host is, so only a connected Server still
    /// loading or out of sync is a condition. With none connected, the
    /// Server that most needs the user leads, a failure of the connection
    /// ahead of one Server's own, the first among equals.
    static func ranked(
        _ group: ConsoleHostSectionGroup,
        statuses: [Host.ID: EventsSessionStatus],
        standingFailures: [Host.ID: TransportError],
        awaitingSnapshot: Set<Host.ID> = [],
        syncErrors: [Host.ID: String] = [:],
        inventoryNoun: String = "Agents"
    ) -> [ConsoleHostStatusPresentation] {
        let connected = group.servers.filter { statuses[$0.id] == .connected }
        let relevant = connected.isEmpty ? group.servers : connected
        let conditions = relevant.enumerated().compactMap { offset, server -> RankedCondition? in
            let status = statuses[server.id]
            let standingFailure = standingFailures[server.id]
            guard
                let condition = ConsoleHostStatusPresentation(
                    host: server, speakingFor: group, status: status,
                    standingFailure: standingFailure,
                    isAwaitingSnapshot: awaitingSnapshot.contains(server.id),
                    syncError: syncErrors[server.id], inventoryNoun: inventoryNoun)
            else { return nil }
            let isServerFailure = (status?.failure ?? standingFailure)?.isServerFailure == true
            return RankedCondition(
                condition: condition,
                rank: (-condition.tone.seriousness, isServerFailure ? 1 : 0, offset))
        }
        return conditions.sorted { $0.rank < $1.rank }.map(\.condition)
    }

    /// A Server's condition and where it stands among its Host's: the most
    /// serious first, the connection's ahead of the Server's own, then
    /// catalog order.
    private struct RankedCondition {
        let condition: ConsoleHostStatusPresentation
        let rank: (Int, Int, Int)
    }
}

extension HostConnectionTone {
    /// How much a condition of this tone needs the user.
    fileprivate var seriousness: Int {
        switch self {
        case .unavailable: 5
        case .warning: 4
        case .reconnecting: 3
        case .pending: 2
        case .paused: 1
        case .connected: 0
        }
    }
}

/// Several Host conditions folded into one row for the flat lists, so a
/// handful of unreachable Hosts cannot push the inventory off screen.
/// Absent for fewer than two: one condition shows as its own row.
struct ConsoleHostIssueSummary: Equatable {
    /// Hosts sharing one status, shown as a chip with its tone's dot.
    struct Count: Equatable {
        let tone: HostConnectionTone
        /// "3 reconnecting"
        let text: String
    }

    let title: String
    let counts: [Count]
    /// The most serious badge among the Hosts.
    let tone: HostConnectionTone

    /// The counts in a sentence, for VoiceOver.
    var detail: String { counts.map(\.text).joined(separator: ", ") }

    init?(issues: [ConsoleHostStatusPresentation]) {
        guard issues.count > 1 else { return nil }
        // Loading or out of sync is not "not connected"; say less then.
        title =
            issues.contains(where: \.isConnected)
            ? String(localized: "\(issues.count) Hosts not ready") : String(localized: "\(issues.count) Hosts not connected")
        // One count per condition, in the order the worst first appears.
        let ranked = issues.sorted { $0.tone.seriousness > $1.tone.seriousness }
        var grouped: [(tone: HostConnectionTone, condition: ConsoleHostStatusPresentation.Condition, count: Int)] = []
        for issue in ranked {
            if let index = grouped.firstIndex(where: { $0.condition == issue.condition }) {
                grouped[index].count += 1
            } else {
                grouped.append((issue.tone, issue.condition, 1))
            }
        }
        // "Reconnecting…" counts as "3 reconnecting".
        counts = grouped.map { Count(tone: $0.tone, text: $0.condition.countText($0.count)) }
        tone = ranked.first?.tone ?? .pending
    }
}

/// Which Console agents surface to show for a catalog and inventory.
///
/// "No Agents" is a known-empty snapshot, not an unknown inventory. Connecting,
/// reconnecting, paused, failed, and Connected-awaiting-snapshot all produce
/// condition rows, so those states take `.rows` rather than the empty claim.
///
/// Grouped presentation always takes `.rows` when any Host section is
/// projected: empty and disconnected Hosts remain visible as sections rather
/// than collapsing into the flat-list empty claim. With none projected, as
/// when every Host is connected and lists nothing it could start more of,
/// it takes the flat list's empty claims.
enum ConsoleAgentsSurface: Equatable {
    case noHosts
    case noAgents
    case noAgentsOnHost(String)
    case noSearchResults
    case rows

    init(
        hostCount: Int,
        filteredHostName: String?,
        filteredAgentCount: Int,
        visibleIssueCount: Int,
        presentationMode: ConsoleListPresentationMode = .flat,
        projectedSectionCount: Int = 0,
        searchQuery: String = "",
        isStatusFiltered: Bool = false
    ) {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isStatusFiltered
        let isEmpty =
            presentationMode == .grouped
            ? projectedSectionCount == 0 : filteredAgentCount == 0 && visibleIssueCount == 0
        if hostCount == 0 {
            self = .noHosts
        } else if isEmpty {
            if isSearching {
                self = .noSearchResults
            } else if let filteredHostName {
                self = .noAgentsOnHost(filteredHostName)
            } else {
                self = .noAgents
            }
        } else {
            self = .rows
        }
    }
}

/// Where Host connection/readiness issues appear for Console list presentation
/// modes: every Agents and Terminals presentation floats the compact corner
/// status tile so Host recovery never pushes inventory rows down.
enum ConsoleHostIssuePlacement: Equatable {
    /// Floating bottom-trailing tile over the list.
    case floatingCorner
    /// Inline rows under each Host's section header (unused once all modes float).
    case sectionHeaders

    init(mode: ConsoleListPresentationMode) {
        self = .floatingCorner
    }

    init(mode: TerminalListPresentationMode) {
        self = .floatingCorner
    }
}

/// What the Agents list's bottom-trailing floating Host status tile shows in
/// `.flat` and `.byWorkspace` presentations: expands briefly to name the Host
/// or summary, then settles into a compact squircle tile with a bottom bar.
struct ConsoleHostIssueCornerPresentation: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Several Hosts have conditions; opens `ConsoleHostIssuesSheet`.
        case showAll
        /// One Host has a navigable condition; opens the Host's connection
        /// sheet, or the page of the Server whose condition it is.
        case openHost(Host.ID)
        /// One Host has a quiet informational condition; toggles the expanded label.
        case toggleExpanded
    }

    struct AttentionKey: Hashable, Sendable {
        let hostID: Host.ID
        let isStationaryProblem: Bool
    }

    let issueCount: Int
    let expandedTitle: String
    let expandedStatus: String?
    let tone: HostConnectionTone
    /// True while at least one Host is actively connecting, reconnecting, or
    /// loading inventory and none has stopped on a failure or sync warning.
    let animatesBar: Bool
    private let hasStationaryProblem: Bool
    let action: Action
    let accessibilityLabel: String
    let accessibilityHint: String?
    /// Keys whose additions trigger the brief auto-expansion: a Host newly
    /// entering an issue state, or escalating to a failure or sync warning.
    let attentionKeys: Set<AttentionKey>

    init?(issues: [ConsoleHostStatusPresentation]) {
        guard let first = issues.first else { return nil }
        issueCount = issues.count
        let stationary = issues.contains {
            $0.condition == .cannotConnect || $0.condition == .syncIssue
        }
        hasStationaryProblem = stationary
        let activeProgress = issues.contains {
            switch $0.condition {
            case .reconnecting, .connecting, .loadingAgents, .loadingTerminals: true
            case .paused, .cannotConnect, .syncIssue: false
            }
        }
        animatesBar = !stationary && activeProgress
        attentionKeys = Set(
            issues.map { issue in
                AttentionKey(
                    hostID: issue.hostID,
                    isStationaryProblem: issue.condition == .cannotConnect
                        || issue.condition == .syncIssue)
            })

        if let summary = ConsoleHostIssueSummary(issues: issues) {
            expandedTitle = summary.title
            expandedStatus = nil
            tone = summary.tone
            action = .showAll
            accessibilityLabel = "\(summary.title), \(summary.detail)"
            accessibilityHint = String(localized: "Lists these Hosts.")
        } else {
            expandedTitle = first.hostName
            expandedStatus = first.status
            tone = first.tone
            accessibilityLabel = first.message
            if first.navigates {
                action = .openHost(first.serverID)
                accessibilityHint =
                    first.condition == .syncIssue
                    ? String(localized: "Opens this Host's settings.")
                    : String(localized: "Shows this Host's connection details.")
            } else {
                action = .toggleExpanded
                accessibilityHint = nil
            }
        }
    }

    /// Corner pill text: the Host count when more than one Host has an issue,
    /// or `"!"` when one Host is stopped on a failure or sync issue and the
    /// tile is collapsed.
    func badgeText(isExpanded: Bool) -> String? {
        if issueCount > 1 {
            return "\(issueCount)"
        }
        if hasStationaryProblem && !isExpanded {
            return "!"
        }
        return nil
    }
}
