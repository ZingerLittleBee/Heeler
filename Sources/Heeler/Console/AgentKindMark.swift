import SwiftUI
import UIKit

/// The program an Agent runs, as its row leads with it: the program's own
/// mark (lobe-icons, see Acknowledgements) where Heeler ships one, else the
/// first letter of the name notifications use. VoiceOver hears that name.
struct AgentKindMark: Equatable, Sendable {
    /// The name notifications use (`AgentNotificationIdentity.kindLabel`).
    let label: String
    /// Nil for a kind without a mark, which shows `monogram` instead.
    let artwork: Artwork?

    struct Artwork: Equatable, Sendable {
        /// The one-color mark, a template image.
        let template: String
        /// The program's own colors, where they read on a tile; elsewhere
        /// the tile shows `template` in the label color.
        let art: String?
        /// The color the status ring style tints `template` with, or nil
        /// for the label color.
        let tint: Tint?

        fileprivate init(_ kind: SupportedAgentKind, art: Bool = false, tint: Tint? = nil) {
            template = "AgentMark/\(kind.rawValue)"
            self.art = art ? "AgentArt/\(kind.rawValue)" : nil
            self.tint = tint
        }
    }

    /// A brand color per appearance, lifted or darkened where the brand's
    /// own sits too close to the avatar's disc.
    struct Tint: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32

        init(_ light: UInt32, dark: UInt32? = nil) {
            self.light = light
            self.dark = dark ?? light
        }
    }

    init(kind: String) {
        label = AgentNotificationIdentity.kindLabel(kind)
        artwork = SupportedAgentKind(
            rawValue: kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ).flatMap(Self.artwork(for:))
    }

    /// The first letter of the name, for a kind without a mark.
    var monogram: String { label.first.map { String($0).uppercased() } ?? "?" }

    /// Whether the mark names the program itself, so a row need not spell
    /// the kind out.
    static func names(kind: String) -> Bool { AgentKindMark(kind: kind).artwork != nil }

    /// Exhaustive, so a kind added to `SupportedAgentKind` decides on a mark.
    static func artwork(for kind: SupportedAgentKind) -> Artwork? {
        switch kind {
        case .claude: Artwork(kind, art: true, tint: Tint(0xD97757))
        case .codex: Artwork(kind, art: true, tint: Tint(0x5B6CFF))
        case .gemini: Artwork(kind, art: true, tint: Tint(0x207CFE))
        case .amp: Artwork(kind, art: true, tint: Tint(0xF34E3F))
        case .antigravity: Artwork(kind, art: true, tint: Tint(0x3186FF))
        case .devin: Artwork(kind, art: true, tint: Tint(0x0294DE))
        // Kimi's color art is drawn for a dark ground; on a light tile only
        // its dot shows, so the tile keeps the one-color mark.
        case .kimi: Artwork(kind, tint: Tint(0x1783FF))
        case .kiro: Artwork(kind, art: true, tint: Tint(0x9046FF, dark: 0x9955FF))
        case .qwen: Artwork(kind, art: true, tint: Tint(0x6336E7, dark: 0x8866ED))
        case .qodercli: Artwork(kind, art: true, tint: Tint(0x20A646, dark: 0x2ADB5C))
        case .opencode, .cursor, .copilot, .cline, .grok, .kilo, .mastracode, .hermes:
            Artwork(kind)
        case .droid, .pi, .omp, .maki, .muse: nil
        }
    }
}

/// The mark at `size` points: the program's colors on a tile, its one-color
/// mark in the ring style's tint, or the monogram.
private struct AgentKindMarkImage: View {
    let mark: AgentKindMark
    let size: CGFloat
    let monogramSize: CGFloat
    /// The status ring style's brand tint in place of the program's art.
    var isTinted = false

    var body: some View {
        if let artwork = mark.artwork {
            if !isTinted, let art = artwork.art {
                Image(art)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(artwork.template)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(isTinted ? artwork.tint.map(Self.color) ?? .primary : .primary)
            }
        } else {
            Text(verbatim: mark.monogram)
                .font(.system(size: monogramSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private static func color(_ tint: AgentKindMark.Tint) -> Color {
        Color(light: UIColor(rgb: tint.light), dark: UIColor(rgb: tint.dark))
    }
}

/// An Agents list row's lead: the mark on a disc, inside a ring that is the
/// Agent's status. Working's ring is an open arc that turns; Done and
/// Blocked close it in their colors, and Blocked's breaks into dashes where
/// color must not carry it alone; Idle and any other status keep a hairline.
struct AgentStatusAvatar: View {
    let mark: AgentKindMark
    let status: AgentStatus
    /// 34 points in a list row, the icon column's width in a card.
    let diameter: CGFloat

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiatesWithoutColor

    enum Ring: Equatable {
        case turning, closed, dashed, hairline
    }

    static func ring(for status: AgentStatus, differentiatingWithoutColor: Bool) -> Ring {
        switch status {
        case .working: .turning
        case .done: .closed
        case .blocked: differentiatingWithoutColor ? .dashed : .closed
        default: .hairline
        }
    }

    private static let ringWidth: CGFloat = 2

    var body: some View {
        // A list row's 34-point avatar has a 2-point gap; a card's 28, 1.5.
        let gap = diameter >= 34 ? 2 : diameter * 1.5 / 28
        let disc = diameter - 2 * (Self.ringWidth + gap)
        ZStack {
            Circle()
                .fill(Color(uiColor: .tertiarySystemFill))
                .frame(width: disc, height: disc)
            AgentKindMarkImage(
                mark: mark, size: (disc * 0.68).rounded(), monogramSize: disc / 2, isTinted: true)
            ring
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder
    private var ring: some View {
        switch Self.ring(for: status, differentiatingWithoutColor: differentiatesWithoutColor) {
        case .turning:
            AgentWorkingArc(lineWidth: Self.ringWidth)
        case .closed:
            Circle().strokeBorder(Color(uiColor: status.inkUIColor), lineWidth: Self.ringWidth)
        case .dashed:
            // Whole dashes around the ring, so none meets the start cut short.
            let circumference = .pi * (diameter - Self.ringWidth)
            let period = circumference / (circumference / 6).rounded()
            Circle().strokeBorder(
                Color(uiColor: status.inkUIColor),
                style: StrokeStyle(
                    lineWidth: Self.ringWidth, lineCap: .round, dash: [period * 0.4, period * 0.6]))
        case .hairline:
            Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 1)
        }
    }
}

/// Working's ring: three quarters of a circle turning once every 1.2
/// seconds. Every arc reads the wall clock, so they turn in step; reduced
/// motion holds it still, still open where Done and Blocked are closed.
private struct AgentWorkingArc: View {
    let lineWidth: CGFloat

    private static let period: TimeInterval = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    var body: some View {
        Group {
            if reduceMotion {
                arc(turn: 0)
            } else {
                // Holds its last frame while off screen or not in the
                // foreground, as the solving orb does.
                TimelineView(.animation(
                    minimumInterval: 1.0 / 60, paused: !isOnScreen || scenePhase != .active
                )) { timeline in
                    arc(turn: timeline.date.timeIntervalSinceReferenceDate / Self.period)
                }
            }
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

    private func arc(turn: Double) -> some View {
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: 0.72)
            .stroke(
                Color(uiColor: AgentStatus.working.inkUIColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees((turn - turn.rounded(.down)) * 360 - 50))
    }
}

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}
