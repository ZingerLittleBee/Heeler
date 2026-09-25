import SwiftUI

/// How a Host's connection reads at a glance, shared by the Hosts list and
/// the Console's Host headers so one state never wears two colors.
enum HostConnectionTone: Equatable {
    case connected
    /// Connecting for the first time; no failure seen yet.
    case pending
    /// Deliberately torn down while the app is in the background.
    case paused
    /// Still working on it: reconnecting, or connected with a sync issue.
    case warning
    /// Stopped on a failure only the user can fix, until a retry.
    case unavailable

    var tint: Color {
        switch self {
        case .connected: .green
        case .pending, .paused: .secondary
        case .warning: .orange
        case .unavailable: .red
        }
    }

    /// Trouble colors its words too, so a failed Host is not just a
    /// different gray sentence among healthy ones.
    var textStyle: Color {
        switch self {
        case .connected, .pending, .paused: .secondary
        case .warning: .orange
        case .unavailable: .red
        }
    }

    /// States still in motion pulse; settled ones hold still.
    var isInProgress: Bool {
        switch self {
        case .pending, .warning: true
        case .connected, .paused, .unavailable: false
        }
    }
}

/// A status dot and its short text, as a Host row or header shows it.
struct HostConnectionStatusLabel: View {
    let text: String
    let tone: HostConnectionTone

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(tone.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: tone.isInProgress)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(tone.textStyle)
                .lineLimit(1)
        }
    }
}
