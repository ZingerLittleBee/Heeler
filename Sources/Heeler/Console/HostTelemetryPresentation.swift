import Foundation

/// Agent detail's Host telemetry label: the latest herdr `ping` round trip
/// measured over this Host's live SSH connection — SSH plus the forwarded
/// socket plus the herdr API. It is Host reachability, never the Agent's own
/// response time.
///
/// Only a connected Host with a measurement on its current connection renders
/// anything; every other combination fails initialization and the label simply
/// disappears. The Hosts sheet chip and the Host recovery surfaces already
/// narrate connection trouble, and a second, quieter voice repeating it here
/// would only compete with them. Nothing is preferable to a stale number, and
/// a placeholder zero would be a measurement the app never took.
struct HostTelemetryPresentation: Equatable {
    let title: String
    let accessibilityValue: String

    var accessibilityLabel: String { "Host API connection latency" }

    init?(status: EventsSessionStatus?, latency: Duration?) {
        guard status == .connected, let latency else { return nil }
        title = "Host · \(HostLatencyFormatting.formatted(latency))"
        accessibilityValue = "\(HostLatencyFormatting.spoken(latency)) over SSH"
    }
}
