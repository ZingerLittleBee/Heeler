import UIKit

extension UIColor {
    /// This colour with `share` of `other` mixed in, both resolved for
    /// `style`. The result is opaque and no longer adapts.
    func mixed(with other: UIColor, by share: CGFloat, style: UIUserInterfaceStyle) -> UIColor {
        let (red, green, blue, _) = components(for: style)
        let (otherRed, otherGreen, otherBlue, _) = other.components(for: style)
        return UIColor(
            red: red + (otherRed - red) * share,
            green: green + (otherGreen - green) * share,
            blue: blue + (otherBlue - blue) * share,
            alpha: 1)
    }

    /// This colour as it shows over `background`: opaque, for `style`.
    func flattened(over background: UIColor, style: UIUserInterfaceStyle) -> UIColor {
        background.mixed(with: self, by: components(for: style).alpha, style: style)
    }

    /// The grey as light as this colour (equal relative luminance), for
    /// `style`.
    func neutral(style: UIUserInterfaceStyle) -> UIColor {
        let luminance = luminance(for: style)
        let value = luminance <= 0.0031308 ? 12.92 * luminance : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return UIColor(white: value, alpha: 1)
    }

    /// The WCAG contrast ratio between this opaque colour and `other`.
    func contrast(with other: UIColor, style: UIUserInterfaceStyle) -> CGFloat {
        let lighter = max(luminance(for: style), other.luminance(for: style))
        let darker = min(luminance(for: style), other.luminance(for: style))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Black or white, whichever reads better on every one of `backgrounds`.
    static func readablePole(on backgrounds: [UIColor], style: UIUserInterfaceStyle) -> UIColor {
        func worst(_ pole: UIColor) -> CGFloat {
            backgrounds.map { pole.contrast(with: $0, style: style) }.min() ?? 0
        }
        return worst(.white) >= worst(.black) ? .white : .black
    }

    /// This opaque colour moved toward black or white, only as far as it
    /// takes to reach `minimum` contrast on each of `backgrounds`.
    func readable(
        on backgrounds: [UIColor], style: UIUserInterfaceStyle, minimum: CGFloat = 4.5
    ) -> UIColor {
        let pole = Self.readablePole(on: backgrounds, style: style)
        var share: CGFloat = 0
        var color = mixed(with: pole, by: share, style: style)
        while share < 1, backgrounds.contains(where: { color.contrast(with: $0, style: style) < minimum }) {
            share = min(share + 0.01, 1)
            color = mixed(with: pole, by: share, style: style)
        }
        return color
    }

    private func components(for style: UIUserInterfaceStyle) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    private func luminance(for style: UIUserInterfaceStyle) -> CGFloat {
        let (red, green, blue, _) = components(for: style)
        let linear = [red, green, blue].map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }
}
