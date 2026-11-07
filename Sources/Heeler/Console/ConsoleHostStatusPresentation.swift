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

    let hostID: Host.ID
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

    init?(
        host: Host,
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        isAwaitingSnapshot: Bool = false,
        syncError: String?,
        inventoryNoun: String = "Agents"
    ) {
        hostID = host.id
        hostName = host.displayName
        isConnected = if case .connected = status { true } else { false }
        let usesHerdrEndpoint = host.herdrEndpoint != nil
        // What follows a "studio: " prefix, where the message has one.
        var unprefixed: String?
        let name = host.displayName
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
        let ranked = issues.sorted { Self.rank($0.tone) > Self.rank($1.tone) }
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

    private static func rank(_ tone: HostConnectionTone) -> Int {
        switch tone {
        case .unavailable: 5
        case .warning: 4
        case .reconnecting: 3
        case .pending: 2
        case .paused: 1
        case .connected: 0
        }
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
/// than collapsing into the flat-list empty claim.
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
        if hostCount == 0 {
            self = .noHosts
        } else if presentationMode == .grouped {
            if projectedSectionCount > 0 {
                self = .rows
            } else if isSearching {
                self = .noSearchResults
            } else {
                self = .noHosts
            }
        } else if filteredAgentCount == 0 && visibleIssueCount == 0 {
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

/// Where Host connection/readiness issues appear for a presentation mode.
///
/// Grouped mode moves those conditions into their Host's section, as the
/// header's badge and, while expanded, a row, rather than listing them again
/// at the top.
enum ConsoleHostIssuePlacement: Equatable {
    /// Flat list: global Host-issue rows above the Agent cards.
    case flatIssueRows
    /// Grouped list: Host readiness lives in each Host's own section.
    case sectionHeaders

    init(mode: ConsoleListPresentationMode) {
        switch mode {
        case .flat, .byWorkspace: self = .flatIssueRows
        case .grouped: self = .sectionHeaders
        }
    }
}
