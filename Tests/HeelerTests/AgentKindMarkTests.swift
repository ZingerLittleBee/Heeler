import Foundation
import Testing
import UIKit

@testable import Heeler

@Suite("Agent kind mark")
struct AgentKindMarkTests {
    /// Every kind Heeler starts has a decision, its assets resolve, and its
    /// name is the one notifications use.
    @Test(arguments: SupportedAgentKind.allCases)
    func everyKindHasAMarkOrAMonogram(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind.rawValue)
        #expect(mark.label == AgentNotificationIdentity.kindLabel(kind.rawValue))
        #expect(mark.monogram == String(mark.label.prefix(1)).uppercased())
        guard let artwork = mark.artwork else { return }
        let template = try #require(UIImage(named: artwork.template), "\(artwork.template)")
        #expect(template.renderingMode == .alwaysTemplate)
        if let art = artwork.art {
            let image = try #require(UIImage(named: art), "\(art)")
            #expect(image.renderingMode != .alwaysTemplate)
        }
    }

    @Test func onlyKindsWithoutAPublishedMarkFallBackToTheirInitial() {
        let unmarked = SupportedAgentKind.allCases.filter { AgentKindMark.artwork(for: $0) == nil }
        #expect(Set(unmarked) == [.droid, .maki, .muse])
    }

    /// herdr's kind is matched as `kindLabel` matches it; a kind this build
    /// does not know keeps its own word's initial.
    @Test func kindsMatchCaseInsensitivelyAndUnknownKindsTakeTheirInitial() {
        let claude = AgentKindMark(kind: "claude")
        #expect(AgentKindMark(kind: "Claude").artwork == claude.artwork)
        #expect(AgentKindMark(kind: " codex\n").artwork != nil)
        #expect(AgentKindMark(kind: "agy").label == "Antigravity")
        let future = AgentKindMark(kind: "future-cli")
        #expect(future.artwork == nil)
        #expect(future.monogram == "F")
        #expect(AgentKindMark(kind: "").label == "Unknown")
        #expect(AgentKindMark(kind: "").monogram == "U")
    }

    /// Art drawn for a light tile has its own dark-appearance variant.
    @Test(arguments: ["AgentArt/kiro", "AgentArt/qwen", "AgentArt/qodercli"])
    func darkArtDiffersFromLightArt(name: String) throws {
        func pixels(_ style: UIUserInterfaceStyle) throws -> Data {
            let image = try #require(
                UIImage(named: name, in: nil, compatibleWith: UITraitCollection(userInterfaceStyle: style)))
            let size = CGSize(width: 24, height: 24)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        #expect(try pixels(.dark) != pixels(.light))
    }

    @MainActor
    @Test(arguments: SupportedAgentKind.allCases)
    func everyKindRendersANonEmptyMenuImage(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind)
        let expectedSize = AgentKindMark.menuImageSize
        for style in [UIUserInterfaceStyle.light, .dark] {
            let image = mark.menuImage(style: style)
            #expect(image.size == expectedSize)
            if mark.artwork?.art != nil || mark.artwork?.tint != nil {
                #expect(image.renderingMode == .alwaysOriginal)
            } else {
                #expect(image.renderingMode == .alwaysTemplate)
            }
            let cgImage = try #require(image.cgImage)
            #expect(Self.hasNonTransparentPixels(cgImage), "\(kind.rawValue) (\(style.rawValue))")
        }
    }

    @MainActor
    @Test(arguments: [SupportedAgentKind.kiro, .qwen, .qodercli])
    func appearanceSensitiveMenuImagesDifferBetweenLightAndDark(kind: SupportedAgentKind) throws {
        let mark = AgentKindMark(kind: kind)
        let light = try #require(mark.menuImage(style: .light).pngData())
        let dark = try #require(mark.menuImage(style: .dark).pngData())
        #expect(light != dark)
    }

    private static func hasNonTransparentPixels(_ cgImage: CGImage) -> Bool {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
    }
}

/// Where an Agent card puts its mark, text, and status.
@MainActor
@Suite("Agent card status ring", .timeLimit(.minutes(1)))
struct AgentCardStatusRingTests {
    /// Done and Blocked share a closed ring told apart by color, so Blocked
    /// breaks into dashes where color must not carry it alone.
    @Test func blockedDashesItsRingWhereColorCannotCarryIt() {
        func rings(_ differentiating: Bool) -> [AgentStatusAvatar.Ring] {
            [.working, .done, .blocked, .error, .idle, .unknown, AgentStatus(rawValue: "paused")].map {
                AgentStatusAvatar.ring(for: $0, differentiatingWithoutColor: differentiating)
            }
        }
        #expect(rings(false) == [.turning, .closed, .closed, .closed, .hairline, .hairline, .hairline])
        #expect(rings(true) == [.turning, .closed, .dashed, .dashed, .hairline, .hairline, .hairline])
    }

    @Test func badgeSizedSolvingOrbUsesLighterLatticeAtSmallClockSpeed() {
        let badge = SolvingOrbRenderer(size: 12)
        let large = SolvingOrbRenderer(size: 64)
        #expect(badge.preset.speed == SolvingOrbRenderer.small.speed)
        #expect(badge.dots(at: 0.6).count < large.dots(at: 0.6).count)
    }
}
