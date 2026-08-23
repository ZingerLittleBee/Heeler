/// One Console list row for a Host's connection or snapshot trouble.
///
/// Extracted from the view so the row's severity, copy, and whether it
/// navigates can be asserted without hosting SwiftUI. Quiet conditions
/// (Paused, Connecting, Loading Agents) are added by #155; this type
/// currently carries the rows the Console already showed.
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
        syncError: String?
    ) {
        hostID = host.id
        hostName = host.displayName
        switch status {
        case .reconnecting(_, _, let failure):
            message = "Reconnecting to \(host.displayName): \(failure.presentation.summary)"
            systemImage = "wifi.exclamationmark"
            severity = .warning
            navigates = true
        case .failed(let failure):
            message = "\(host.displayName): \(failure.presentation.message)"
            systemImage = failure.isHostKeySecurityFailure
                ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill"
            severity = failure.isHostKeySecurityFailure ? .critical : .warning
            navigates = true
        case .connected, .suspended, .ended, nil:
            guard let syncError else { return nil }
            message = "\(host.displayName): \(syncError)"
            systemImage = "arrow.trianglehead.2.clockwise"
            severity = .warning
            navigates = true
        }
    }
}
