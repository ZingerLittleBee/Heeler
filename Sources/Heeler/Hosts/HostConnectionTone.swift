import SwiftUI

/// How a Host's connection reads at a glance, shared by the Hosts list and
/// the Console's Host headers so one state never wears two icons. Each tone
/// has its own shape as well as its own color, so it survives without color.
enum HostConnectionTone: Equatable, CaseIterable {
    case connected
    /// Connecting for the first time; no failure seen yet.
    case pending
    /// Deliberately torn down while the app is in the background.
    case paused
    /// Lost the connection and retrying on its own.
    case reconnecting
    /// Connected, but the inventory could not be synced.
    case warning
    /// Stopped on a failure only the user can fix, until a retry.
    case unavailable

    var systemImage: String {
        switch self {
        // Not a plain dot: Agent status already speaks in colored dots.
        case .connected: "checkmark.circle.fill"
        case .pending: "circle.dotted"
        case .paused: "pause.circle.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        case .unavailable: "exclamationmark.circle.fill"
        }
    }

    /// Muted system colors: a list of Hosts is mostly icons, and full
    /// strength glares on a dark background.
    var tint: Color {
        switch self {
        case .connected: .green.opacity(0.7)
        case .pending, .paused: .secondary
        case .reconnecting, .warning: .orange.opacity(0.7)
        case .unavailable: .red.opacity(0.7)
        }
    }
}

/// A Host's status icon alone, sized to sit beside a caption or a name.
struct HostConnectionStatusIcon: View {
    let tone: HostConnectionTone

    var body: some View {
        Image(systemName: tone.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tone.tint)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// A status icon and its short text, as a Host row shows it.
struct HostConnectionStatusLabel: View {
    let text: String
    let tone: HostConnectionTone

    var body: some View {
        HStack(spacing: 4) {
            HostConnectionStatusIcon(tone: tone)
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
