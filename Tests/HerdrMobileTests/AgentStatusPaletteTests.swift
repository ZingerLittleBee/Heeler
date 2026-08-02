import Testing
import UIKit

@testable import HerdrMobile

/// The status palette is the Console's only colour vocabulary: the card
/// badge and the keyboard switcher's dot both read from it, so a status must
/// never borrow another's hue — and an unreadable status must never borrow an
/// actionable one's.
@Suite("Agent status palette")
struct AgentStatusPaletteTests {
    private static let styles: [UIUserInterfaceStyle] = [.light, .dark]
    /// Both palette roles, so every invariant holds for wash and ink alike.
    private static let roles: [(String, @Sendable (AgentStatus) -> UIColor)] = [
        ("tint", { $0.tintUIColor }),
        ("ink", { $0.inkUIColor }),
    ]

    private func rgba(
        _ color: UIColor, _ style: UIUserInterfaceStyle
    ) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    @Test func everyActionableStatusGetsItsOwnHue() {
        for style in Self.styles {
            for (role, color) in Self.roles {
                let tints = [AgentStatus.blocked, .done, .working, .idle].map {
                    rgba(color($0), style)
                }
                for (index, tint) in tints.enumerated() {
                    #expect(
                        !tints.dropFirst(index + 1).contains(tint),
                        "\(role) \(style)")
                }
            }
        }
    }

    /// herdr's API has no stability guarantee: a status this build cannot
    /// read must look as inert as Idle, never as loud as Blocked or Done.
    @Test func unreadableStatusesShareTheMutedTint() {
        for style in Self.styles {
            for (role, color) in Self.roles {
                let muted = rgba(color(.idle), style)
                #expect(rgba(color(.unknown), style) == muted, "\(role) \(style)")
                #expect(
                    rgba(color(AgentStatus(rawValue: "haunted")), style) == muted,
                    "\(role) \(style)")
            }
        }
    }

    /// The colours are herdr's, not UIKit's — the phone and the TUI have to
    /// agree on what green means.
    @Test func huesMatchHerdrsCatppuccinFlavours() {
        let expected: [(AgentStatus, light: UInt32, dark: UInt32)] = [
            (.blocked, light: 0xD20F39, dark: 0xF38BA8),
            (.done, light: 0x40A02B, dark: 0xA6E3A1),
            (.working, light: 0xDF8E1D, dark: 0xF9E2AF),
        ]
        for (status, light, dark) in expected {
            #expect(hex(rgba(status.tintUIColor, .light)) == light, "\(status.rawValue) light")
            #expect(hex(rgba(status.tintUIColor, .dark)) == dark, "\(status.rawValue) dark")
        }
    }

    /// The regression that prompted the ink role: Latte yellow measured
    /// 2.3:1 as badge text on its own capsule. Every ink must clear WCAG
    /// 4.5:1 for the badge's caption text over its wash, and 3:1 as the
    /// switcher's bare dot on the card background.
    @Test func inksStayLegibleOnTheirWashes() {
        let statuses = [AgentStatus.blocked, .done, .working, .idle]
        for style in Self.styles {
            // secondarySystemGroupedBackground: the Console card and the
            // terminal chrome the switcher chips sit over.
            let card: [CGFloat] =
                style == .dark
                ? [44 / 255, 44 / 255, 46 / 255, 1] : [1, 1, 1, 1]
            for status in statuses {
                let ink = rgba(status.inkUIColor, style)
                let wash = blend(
                    rgba(status.tintUIColor, style), alpha: 0.15, over: card)
                #expect(
                    contrastRatio(ink, wash) >= 4.5,
                    "\(status.rawValue) \(style) on capsule")
                #expect(
                    contrastRatio(ink, card) >= 3,
                    "\(status.rawValue) \(style) as dot")
            }
        }
    }

    private func hex(_ components: [CGFloat]) -> UInt32 {
        components.prefix(3).reduce(0) { packed, component in
            packed << 8 | UInt32((component * 255).rounded())
        }
    }

    private func blend(
        _ top: [CGFloat], alpha: CGFloat, over bottom: [CGFloat]
    ) -> [CGFloat] {
        zip(top, bottom).map { $0 * alpha + $1 * (1 - alpha) }
    }

    /// WCAG 2 contrast ratio from sRGB components.
    private func contrastRatio(_ a: [CGFloat], _ b: [CGFloat]) -> CGFloat {
        let (lighter, darker) = luminance(a) > luminance(b)
            ? (luminance(a), luminance(b)) : (luminance(b), luminance(a))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ components: [CGFloat]) -> CGFloat {
        let linear = components.prefix(3).map { channel in
            channel <= 0.04045
                ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
