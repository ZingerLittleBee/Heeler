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

    private func rgba(
        _ status: AgentStatus, _ style: UIUserInterfaceStyle
    ) -> [CGFloat] {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        status.tintUIColor
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    @Test func everyActionableStatusGetsItsOwnHue() {
        for style in Self.styles {
            let tints = [AgentStatus.blocked, .done, .working, .idle].map {
                rgba($0, style)
            }
            for (index, tint) in tints.enumerated() {
                #expect(!tints.dropFirst(index + 1).contains(tint), "\(style)")
            }
        }
    }

    /// herdr's API has no stability guarantee: a status this build cannot
    /// read must look as inert as Idle, never as loud as Blocked or Done.
    @Test func unreadableStatusesShareTheMutedTint() {
        for style in Self.styles {
            let muted = rgba(.idle, style)
            #expect(rgba(.unknown, style) == muted, "\(style)")
            #expect(rgba(AgentStatus(rawValue: "haunted"), style) == muted, "\(style)")
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
            #expect(hex(rgba(status, .light)) == light, "\(status.rawValue) light")
            #expect(hex(rgba(status, .dark)) == dark, "\(status.rawValue) dark")
        }
    }

    private func hex(_ components: [CGFloat]) -> UInt32 {
        components.prefix(3).reduce(0) { packed, component in
            packed << 8 | UInt32((component * 255).rounded())
        }
    }
}
