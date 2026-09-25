import Foundation

/// One Console list row for a Host's connection or snapshot condition.
///
/// Quiet rows (Paused, Connecting, Loading Agents) are informational and
/// do not navigate to Host settings. Failed and reconnecting rows still do.
/// `inventoryNoun` names what the loading row waits for on its list.
struct ConsoleHostStatusPresentation: Equatable, Identifiable {
    enum Severity: Equatable {
        case informational
        case warning
        case critical
    }

    let hostID: Host.ID
    let hostName: String
    let message: String
    let systemImage: String
    let severity: Severity
    let navigates: Bool
    /// The badge on the Host's server glyph, as on its section header.
    let tone: HostConnectionTone
    /// A few words for a compact row: "Reconnecting…", "Can't connect".
    let status: String

    var id: Host.ID { hostID }
    var isCritical: Bool { severity == .critical }

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
        switch status {
        case .suspended:
            message = "Connection to \(host.displayName) is paused."
            systemImage = "pause.circle"
            severity = .informational
            navigates = false
            (tone, self.status) = (.paused, "Paused")
        case .connecting:
            if let standingFailure {
                (message, systemImage, severity, navigates) = Self.failed(
                    standingFailure, hostName: host.displayName)
                (tone, self.status) = Self.cannotConnect
            } else {
                message = "Connecting to \(host.displayName)…"
                systemImage = "dot.radiowaves.left.and.right"
                severity = .informational
                navigates = false
                (tone, self.status) = (.pending, "Connecting…")
            }
        case .reconnecting(_, _, let failure):
            message = "Reconnecting to \(host.displayName): \(failure.presentation.summary)"
            systemImage = "wifi.exclamationmark"
            severity = .warning
            navigates = true
            (tone, self.status) = (.reconnecting, "Reconnecting…")
        case .failed(let failure):
            (message, systemImage, severity, navigates) = Self.failed(
                failure, hostName: host.displayName)
            (tone, self.status) = Self.cannotConnect
        case .connected:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
                (tone, self.status) = Self.syncIssue
            } else if isAwaitingSnapshot {
                message = "Loading \(inventoryNoun) from \(host.displayName)…"
                systemImage = "hourglass"
                severity = .informational
                navigates = false
                (tone, self.status) = (.pending, "Loading \(inventoryNoun)…")
            } else {
                return nil
            }
        case .ended, nil:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
                (tone, self.status) = Self.syncIssue
            } else {
                return nil
            }
        }
    }

    private static let cannotConnect: (HostConnectionTone, String) = (.unavailable, "Can't connect")
    private static let syncIssue: (HostConnectionTone, String) = (.warning, "Sync issue")

    private static func failed(
        _ failure: TransportError, hostName: String
    ) -> (String, String, Severity, Bool) {
        (
            "\(hostName): \(failure.presentation.message)",
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
            "\(hostName): \(syncError)",
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
    let title: String
    let detail: String
    /// The most serious badge among the Hosts.
    let tone: HostConnectionTone

    init?(issues: [ConsoleHostStatusPresentation]) {
        guard issues.count > 1 else { return nil }
        title = "\(issues.count) Hosts"
        // One count per status, in the order the worst first appears.
        let ranked = issues.sorted { Self.rank($0.tone) > Self.rank($1.tone) }
        var counts: [(status: String, count: Int)] = []
        for issue in ranked {
            // "Reconnecting…" counts as "3 reconnecting".
            let status = issue.status.lowercased().replacingOccurrences(of: "…", with: "")
            if let index = counts.firstIndex(where: { $0.status == status }) {
                counts[index].count += 1
            } else {
                counts.append((status, 1))
            }
        }
        detail = counts.map { "\($0.count) \($0.status)" }.joined(separator: " · ")
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
        searchQuery: String = ""
    ) {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        case .flat: self = .flatIssueRows
        case .grouped: self = .sectionHeaders
        }
    }
}
