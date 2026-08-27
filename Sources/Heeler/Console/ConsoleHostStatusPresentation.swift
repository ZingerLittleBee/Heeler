/// One Console list row for a Host's connection or snapshot condition.
///
/// Quiet rows (Paused, Connecting, Loading Agents) are informational and
/// do not navigate to Host settings. Failed and reconnecting rows still do.
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

    var id: Host.ID { hostID }
    var isCritical: Bool { severity == .critical }

    init?(
        host: Host,
        status: EventsSessionStatus?,
        standingFailure: TransportError? = nil,
        isAwaitingSnapshot: Bool = false,
        syncError: String?
    ) {
        hostID = host.id
        hostName = host.displayName
        switch status {
        case .suspended:
            message = "Connection to \(host.displayName) is paused."
            systemImage = "pause.circle"
            severity = .informational
            navigates = false
        case .connecting:
            if let standingFailure {
                (message, systemImage, severity, navigates) = Self.failed(
                    standingFailure, hostName: host.displayName)
            } else {
                message = "Connecting to \(host.displayName)…"
                systemImage = "dot.radiowaves.left.and.right"
                severity = .informational
                navigates = false
            }
        case .reconnecting(_, _, let failure):
            message = "Reconnecting to \(host.displayName): \(failure.presentation.summary)"
            systemImage = "wifi.exclamationmark"
            severity = .warning
            navigates = true
        case .failed(let failure):
            (message, systemImage, severity, navigates) = Self.failed(
                failure, hostName: host.displayName)
        case .connected:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
            } else if isAwaitingSnapshot {
                message = "Loading Agents from \(host.displayName)…"
                systemImage = "hourglass"
                severity = .informational
                navigates = false
            } else {
                return nil
            }
        case .ended, nil:
            if let syncError {
                (message, systemImage, severity, navigates) = Self.syncError(
                    syncError, hostName: host.displayName)
            } else {
                return nil
            }
        }
    }

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
    case rows

    init(
        hostCount: Int,
        filteredHostName: String?,
        filteredAgentCount: Int,
        visibleIssueCount: Int,
        presentationMode: ConsoleListPresentationMode = .flat,
        projectedSectionCount: Int = 0
    ) {
        if hostCount == 0 {
            self = .noHosts
        } else if presentationMode == .grouped {
            self = projectedSectionCount > 0 ? .rows : .noHosts
        } else if filteredAgentCount == 0 && visibleIssueCount == 0 {
            if let filteredHostName {
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
/// Grouped mode folds those conditions into section headers so the same
/// failure or loading message is not also listed as a top-of-list row.
enum ConsoleHostIssuePlacement: Equatable {
    /// Flat list: global Host-issue rows above the Agent cards.
    case flatIssueRows
    /// Grouped list: Host readiness lives on each section header only.
    case sectionHeaders

    init(mode: ConsoleListPresentationMode) {
        switch mode {
        case .flat: self = .flatIssueRows
        case .grouped: self = .sectionHeaders
        }
    }
}
