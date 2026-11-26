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

    struct Artwork: Hashable, Sendable {
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
    struct Tint: Hashable, Sendable {
        let light: UInt32
        let dark: UInt32

        init(_ light: UInt32, dark: UInt32? = nil) {
            self.light = light
            self.dark = dark ?? light
        }
    }

    init(kind: SupportedAgentKind) {
        label = AgentNotificationIdentity.kindLabel(kind.rawValue)
        artwork = Self.artwork(for: kind)
    }

    init(kind: String) {
        label = AgentNotificationIdentity.kindLabel(kind)
        artwork = SupportedAgentKind(
            rawValue: kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ).flatMap(Self.artwork(for:))
    }

    /// Centered 18x18 glyph with symmetric 5pt horizontal sidebearings so a
    /// closed `Form` `Picker` value has a space's width before the title while
    /// `UIMenu`'s trailing icon column stays centered.
    static let menuImageSize = CGSize(width: 28, height: 20)

    /// Flattened at menu glyph size for `UIMenu` and `Picker` rows, which take
    /// a single `UIImage`: the program's art or brand tint where available,
    /// its template mark in the label color, or its initial in a circle.
    @MainActor
    func menuImage(style: UIUserInterfaceStyle) -> UIImage {
        let resolved: UIUserInterfaceStyle = style == .dark ? .dark : .light
        let key = AgentKindMenuGlyphCache.Key(label: label, artwork: artwork, style: resolved)
        if let cached = AgentKindMenuGlyphCache.images[key] { return cached }
        let image = renderMenuImage(style: resolved)
        AgentKindMenuGlyphCache.images[key] = image
        return image
    }

    private func renderMenuImage(style: UIUserInterfaceStyle) -> UIImage {
        let canvas = Self.menuImageSize
        let bounds = CGRect(x: 5, y: 1, width: 18, height: 18)
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(displayScale: 3),
            UITraitCollection(userInterfaceStyle: style),
        ])
        let format = UIGraphicsImageRendererFormat(for: traits)
        format.scale = 3
        format.opaque = false

        if let artwork {
            if let art = artwork.art,
                let source = UIImage(named: art, in: nil, compatibleWith: traits)
            {
                let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                    source.draw(in: Self.fittedRect(for: source.size, in: bounds))
                }
                return drawn.withRenderingMode(.alwaysOriginal)
            }
            if let tint = artwork.tint,
                let source = UIImage(named: artwork.template, in: nil, compatibleWith: traits)?
                    .withTintColor(
                        UIColor(rgb: style == .dark ? tint.dark : tint.light),
                        renderingMode: .alwaysOriginal)
            {
                let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                    source.draw(in: Self.fittedRect(for: source.size, in: bounds))
                }
                return drawn.withRenderingMode(.alwaysOriginal)
            }
            if let source = UIImage(named: artwork.template, in: nil, compatibleWith: traits)?
                .withTintColor(.black, renderingMode: .alwaysOriginal)
            {
                let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                    source.draw(in: Self.fittedRect(for: source.size, in: bounds))
                }
                return drawn.withRenderingMode(.alwaysTemplate)
            }
        }

        let drawn = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            UIColor.black.setStroke()
            let border = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.7, dy: 0.7))
            border.lineWidth = 1.4
            border.stroke()

            let baseFont = UIFont.systemFont(ofSize: 10.5, weight: .bold)
            let font = baseFont.fontDescriptor.withDesign(.rounded)
                .map { UIFont(descriptor: $0, size: 10.5) } ?? baseFont
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black,
            ]
            let textSize = (monogram as NSString).size(withAttributes: attributes)
            let origin = CGPoint(
                x: bounds.midX - textSize.width / 2,
                y: bounds.midY - textSize.height / 2)
            (monogram as NSString).draw(at: origin, withAttributes: attributes)
        }
        return drawn.withRenderingMode(.alwaysTemplate)
    }

    private static func fittedRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height)
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
        case .pi: Artwork(kind, art: true, tint: Tint(0x4D9ABF, dark: 0x5EB0D8))
        case .omp: Artwork(kind, art: true, tint: Tint(0x9B4DFF, dark: 0xAD6BFF))
        case .opencode, .cursor, .copilot, .cline, .grok, .kilo, .mastracode, .hermes:
            Artwork(kind)
        case .droid, .maki, .muse: nil
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
    /// Applies the program's brand tint to a template-only mark (such as Kimi)
    /// when `isTinted` is false and no multi-color art exists.
    var usesBrandTintFallback = false

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
                    .foregroundStyle(
                        (isTinted || usesBrandTintFallback)
                            ? artwork.tint.map(Self.color) ?? .primary : .primary)
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

/// A harness's mark on a neutral rounded tile, without a status ring — for
/// lists such as Launch Presets where there is no live Agent status.
struct AgentKindBadge: View {
    let mark: AgentKindMark
    var size: CGFloat = 32

    init(kind: SupportedAgentKind, size: CGFloat = 32) {
        self.mark = AgentKindMark(kind: kind)
        self.size = size
    }

    init(mark: AgentKindMark, size: CGFloat = 32) {
        self.mark = mark
        self.size = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (size * 0.25).rounded(), style: .continuous)
        ZStack {
            shape
                .fill(Color(uiColor: .tertiarySystemFill))
            AgentKindMarkImage(
                mark: mark,
                size: (size * 0.62).rounded(),
                monogramSize: (size * 0.45).rounded(),
                usesBrandTintFallback: true)
        }
        .frame(width: size, height: size)
    }
}

/// An Agents list row's lead: the mark on a disc, inside a ring that is the
/// Agent's status. Working's ring is an open arc that turns; Done, Blocked and
/// Error close it in their colors, and Blocked's and Error's break into dashes
/// where color must not carry them alone; Idle and any other status keep a
/// hairline.
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
        case .blocked, .error: differentiatingWithoutColor ? .dashed : .closed
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

extension EnvironmentValues {
    /// False inside an iPad sidebar list hidden behind the active list tab.
    @Entry var isSidebarListShown = true
}

/// Working's ring: three quarters of a circle turning once every 1.2
/// seconds. Every arc phase-locks to `CACurrentMediaTime()` on the Core
/// Animation render server, so they turn in step with zero main-thread frame
/// ticks; reduced motion holds it still, still open where Done and Blocked
/// are closed.
private struct AgentWorkingArc: View {
    let lineWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSidebarListShown) private var isSidebarListShown

    var body: some View {
        AgentWorkingArcLayerView(
            lineWidth: lineWidth,
            isSpinning: !reduceMotion && scenePhase == .active && isSidebarListShown)
    }
}

private struct AgentWorkingArcLayerView: UIViewRepresentable {
    let lineWidth: CGFloat
    let isSpinning: Bool

    func makeUIView(context: Context) -> ArcView {
        ArcView(lineWidth: lineWidth, isSpinning: isSpinning)
    }

    func updateUIView(_ view: ArcView, context: Context) {
        view.configure(lineWidth: lineWidth, isSpinning: isSpinning)
    }

    final class ArcView: UIView {
        private static let period: CFTimeInterval = 1.2
        private static let animationKey = "heeler.workingArc.spin"
        private static let startAngle = CGFloat(-50.0 * .pi / 180.0)
        private static let endAngle = CGFloat((-50.0 + 0.72 * 360.0) * .pi / 180.0)

        private let shapeLayer = CAShapeLayer()
        private var lineWidth: CGFloat
        private var isSpinning: Bool
        private var lastBoundsSize: CGSize = .zero

        init(lineWidth: CGFloat, isSpinning: Bool) {
            self.lineWidth = lineWidth
            self.isSpinning = isSpinning
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            shapeLayer.fillColor = nil
            shapeLayer.lineCap = .round
            shapeLayer.lineWidth = lineWidth
            layer.addSublayer(shapeLayer)
            updateStrokeColor()
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self,
                UITraitAccessibilityContrast.self,
            ]) { (self: Self, _) in
                self.updateStrokeColor()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func configure(lineWidth: CGFloat, isSpinning: Bool) {
            if self.lineWidth != lineWidth {
                self.lineWidth = lineWidth
                shapeLayer.lineWidth = lineWidth
                lastBoundsSize = .zero
                setNeedsLayout()
            }
            if self.isSpinning != isSpinning {
                self.isSpinning = isSpinning
                syncAnimation()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            syncAnimation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != lastBoundsSize else { return }
            lastBoundsSize = bounds.size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeLayer.frame = bounds
            let radius = max(0, min(bounds.width, bounds.height) / 2 - lineWidth / 2)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            shapeLayer.path = UIBezierPath(
                arcCenter: center,
                radius: radius,
                startAngle: Self.startAngle,
                endAngle: Self.endAngle,
                clockwise: true
            ).cgPath
            CATransaction.commit()
            syncAnimation()
        }

        private func updateStrokeColor() {
            shapeLayer.strokeColor = AgentStatus.working.inkUIColor
                .resolvedColor(with: traitCollection).cgColor
        }

        private func syncAnimation() {
            let shouldAnimate = isSpinning && window != nil && bounds.width > 0 && bounds.height > 0
            if shouldAnimate {
                guard shapeLayer.animation(forKey: Self.animationKey) == nil else { return }
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0.0
                spin.toValue = Double.pi * 2
                spin.duration = Self.period
                spin.repeatCount = .infinity
                spin.isRemovedOnCompletion = false
                let mediaNow = CACurrentMediaTime()
                let layerNow = shapeLayer.convertTime(mediaNow, from: nil)
                let phase = mediaNow.truncatingRemainder(dividingBy: Self.period)
                spin.beginTime = layerNow - phase
                shapeLayer.add(spin, forKey: Self.animationKey)
            } else if shapeLayer.animation(forKey: Self.animationKey) != nil {
                shapeLayer.removeAnimation(forKey: Self.animationKey)
            }
        }
    }
}

/// A `Picker` or `Menu` item's label leading (or trailing in `UIMenu`) with
/// the harness's mark.
struct AgentKindMenuLabel: View {
    private let title: String
    private let mark: AgentKindMark
    @Environment(\.colorScheme) private var colorScheme

    nonisolated init(_ title: String, kind: SupportedAgentKind) {
        self.title = title
        self.mark = AgentKindMark(kind: kind)
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: mark.menuImage(style: colorScheme == .dark ? .dark : .light))
        }
    }
}

@MainActor
private enum AgentKindMenuGlyphCache {
    struct Key: Hashable {
        let label: String
        let artwork: AgentKindMark.Artwork?
        let style: UIUserInterfaceStyle
    }

    static var images: [Key: UIImage] = [:]
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
