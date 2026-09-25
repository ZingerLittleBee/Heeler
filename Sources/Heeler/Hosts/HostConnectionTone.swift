import SwiftUI

/// How a Host's connection reads at a glance, shared by the Hosts list and
/// the Console's Host headers so one state never wears two looks. Wherever
/// color alone would tell two tones apart, text says the state too: the
/// Hosts rows' groups and details, and the headers' VoiceOver readiness.
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

/// The server glyph leading a Host's row or header. A badge on its corner
/// carries the connection state, cut out of the glyph so it reads on any
/// background: a green dot once connected, a spinning arc while
/// reconnecting.
struct HostStatusGlyph: View {
    let tone: HostConnectionTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let badgeSize: CGFloat = 8
    /// Clear ring between badge and glyph.
    private static let cutoutRing: CGFloat = 2
    /// How far the badge hangs past the glyph's bottom-trailing corner.
    private static let overhang: CGFloat = 3

    var body: some View {
        Image(systemName: "server.rack")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tone == .unavailable ? .tertiary : .secondary)
            .frame(width: 20, height: 18)
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        let cutout = Self.badgeSize + Self.cutoutRing * 2
                        Circle()
                            .frame(width: cutout, height: cutout)
                            .offset(
                                x: Self.overhang + Self.cutoutRing,
                                y: Self.overhang + Self.cutoutRing)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                badge
                    .frame(width: Self.badgeSize, height: Self.badgeSize)
                    .offset(x: Self.overhang, y: Self.overhang)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        switch tone {
        case .reconnecting:
            // Driven by the clock rather than a repeating animation, which
            // leaks into a List's row insertions and removals.
            TimelineView(.animation(paused: reduceMotion)) { context in
                // Inset by half the line so the arc stays inside the badge.
                Circle()
                    .inset(by: 0.75)
                    .trim(from: 0, to: 0.7)
                    .stroke(tone.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(
                        .degrees(
                            reduceMotion
                                ? 0
                                : context.date.timeIntervalSinceReferenceDate
                                    .truncatingRemainder(dividingBy: 1) * 360))
            }
        case .pending:
            // Still dialing: an open ring, not yet a state.
            Circle().strokeBorder(tone.tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 1.6]))
        case .connected, .paused, .warning, .unavailable:
            Circle().fill(tone.tint)
        }
    }
}

extension HostNameEmphasis {
    /// Absolute colors, not hierarchical styles: a section header resolves
    /// `.primary` against its own gray, which left a connected Host's name
    /// as gray as a reconnecting one's.
    var color: Color {
        switch self {
        case .full: Color.primary
        case .receded: Color.secondary
        case .dimmed: Color(uiColor: .tertiaryLabel)
        }
    }
}
