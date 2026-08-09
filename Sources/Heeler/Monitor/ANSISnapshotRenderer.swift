import Foundation
import SwiftUI
import UIKit

/// Renders the ANSI-formatted text returned by herdr reads for Monitor.
///
/// The renderer preserves printable text and line structure, applies the SGR
/// subset Monitor understands, and removes every other terminal control
/// sequence. It has no I/O or terminal state beyond the supplied snapshot.
///
/// Monitor shows snapshots on the grouped list surface in both light and dark
/// appearance, so emitted colors adapt. Every foreground reaches WCAG 4.5:1
/// against its effective background — the run's own background when one is
/// set, else the snapshot surface — and every background reaches 4.5:1
/// against the appearance's label color, so ambient text on colored
/// backgrounds (diff hunks, selection bars) stays legible.
enum ANSISnapshotRenderer {
    /// Converts one complete terminal snapshot into display-ready attributed text.
    static func render(_ snapshot: String) -> AttributedString {
        var parser = Parser(snapshot)
        return cleanTerminalChrome(from: parser.render())
    }

    private static func cleanTerminalChrome(from rendered: AttributedString) -> AttributedString {
        var cleaned = rendered
        let whitespaceBackgroundRanges = cleaned.runs.flatMap { run in
            backgroundPaddingRanges(in: run.range, characters: cleaned.characters)
        }
        for range in whitespaceBackgroundRanges {
            cleaned[range].backgroundColor = nil
        }
        return removingTrailingChromeBlock(from: cleaned)
    }

    private static func backgroundPaddingRanges(
        in range: Range<AttributedString.Index>,
        characters: AttributedString.CharacterView
    ) -> [Range<AttributedString.Index>] {
        var start = range.lowerBound
        while start < range.upperBound, characters[start].isWhitespace {
            start = characters.index(after: start)
        }

        guard start < range.upperBound else { return [range] }

        var end = range.upperBound
        while end > start {
            let previous = characters.index(before: end)
            guard characters[previous].isWhitespace else { break }
            end = previous
        }

        var ranges: [Range<AttributedString.Index>] = []
        if range.lowerBound < start {
            ranges.append(range.lowerBound..<start)
        }
        if end < range.upperBound {
            ranges.append(end..<range.upperBound)
        }
        return ranges
    }

    /// Removes only the trailing chrome block of the snapshot: the agent
    /// TUI's own input-box frame (a wide box-drawing frame at the very end
    /// whose interior is empty or a bare prompt) plus one immediately
    /// following status/hint line. Monitor renders its own Composer directly
    /// below the snapshot, so a dead input box on top of it is the single
    /// worst "fake terminal" artifact. Interior box-drawing content — tables,
    /// framed boxes mid-snapshot — is always kept: losing chrome is cosmetic,
    /// losing content is a correctness bug, so whenever detection is unsure
    /// this returns the snapshot untouched.
    private static func removingTrailingChromeBlock(
        from source: AttributedString
    ) -> AttributedString {
        var lines: [AttributedString] = []
        var lineStart = source.startIndex
        var cursor = lineStart

        while cursor < source.endIndex {
            if source.characters[cursor] == "\n" {
                lines.append(AttributedString(source[lineStart..<cursor]))
                cursor = source.characters.index(after: cursor)
                lineStart = cursor
            } else {
                cursor = source.characters.index(after: cursor)
            }
        }
        lines.append(AttributedString(source[lineStart..<source.endIndex]))

        guard let chromeStart = trailingChromeStartIndex(in: lines) else { return source }

        var result = AttributedString()
        for (index, line) in lines[..<chromeStart].enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            result.append(line)
        }
        return result
    }

    /// The smallest box width considered chrome. Agent input boxes span the
    /// pane; narrower decorations are treated as content.
    private static let minimumFrameWidth = 20

    private static let topBorderCorners: Set<Character> = ["╭", "┌", "┏"]
    private static let bottomBorderCorners: Set<Character> = ["╰", "└", "┗"]
    private static let barePrompts: Set<String> = [">", "❯"]

    private static func trailingChromeStartIndex(in lines: [AttributedString]) -> Int? {
        var end = lines.count
        while end > 0, isBlank(lines[end - 1]) {
            end -= 1
        }
        guard end >= 3 else { return nil }

        // The TUI draws at most one status/hint line below the input box.
        var bottom = end - 1
        if !isBorderLine(lines[bottom], openedBy: bottomBorderCorners) {
            guard isHintLine(lines[bottom]),
                isBorderLine(lines[bottom - 1], openedBy: bottomBorderCorners)
            else { return nil }
            bottom -= 1
        }

        var interiorStart = bottom - 1
        while interiorStart >= 0, isFrameInteriorLine(lines[interiorStart]) {
            // A frame holding real content is content, not chrome.
            guard frameInteriorIsBarePrompt(lines[interiorStart]) else { return nil }
            interiorStart -= 1
        }
        // Require at least one interior line and a matching top border.
        guard interiorStart < bottom - 1,
            interiorStart >= 0,
            isBorderLine(lines[interiorStart], openedBy: topBorderCorners)
        else { return nil }
        return interiorStart
    }

    private static func isBorderLine(
        _ line: AttributedString,
        openedBy corners: Set<Character>
    ) -> Bool {
        let trimmed = String(line.characters).trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minimumFrameWidth,
            let first = trimmed.first,
            corners.contains(first)
        else { return false }
        return trimmed.allSatisfy(isBoxDrawing)
    }

    private static func isFrameInteriorLine(_ line: AttributedString) -> Bool {
        let trimmed = String(line.characters).trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first,
            let last = trimmed.last,
            isVerticalBorder(first),
            isVerticalBorder(last)
        else { return false }
        return true
    }

    private static func frameInteriorIsBarePrompt(_ line: AttributedString) -> Bool {
        var content = String(line.characters).trimmingCharacters(in: .whitespaces)
        // The vertical borders were verified by `isFrameInteriorLine`.
        guard content.count >= 2 else { return false }
        content.removeFirst()
        content.removeLast()
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || barePrompts.contains(trimmed)
    }

    /// The status/hint line a TUI draws under its input box: indented, never
    /// starting at column 0 like real content.
    private static func isHintLine(_ line: AttributedString) -> Bool {
        let text = String(line.characters)
        guard let first = text.first, first.isWhitespace else { return false }
        return text.contains { !$0.isWhitespace }
    }

    private static func isBlank(_ line: AttributedString) -> Bool {
        line.characters.allSatisfy { $0.isWhitespace }
    }

    private static func isVerticalBorder(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else { return false }
        return [0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B].contains(scalar.value)
    }

    private static func isBoxDrawing(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x2500...0x257F).contains(scalar.value)
        }
    }
}

extension ANSISnapshotRenderer {
    /// The appearance a snapshot is rendered for. Adaptive colors carry one
    /// value per appearance.
    enum Appearance {
        case light
        case dark
    }

    /// An 8-bit sRGB color. This is the currency of the contrast machinery;
    /// dynamic resolution happens only at the `Color`/`UIColor` boundary.
    struct RGB: Sendable, Equatable {
        let red: Int
        let green: Int
        let blue: Int

        init(red: Int, green: Int, blue: Int) {
            self.red = min(0xFF, max(0, red))
            self.green = min(0xFF, max(0, green))
            self.blue = min(0xFF, max(0, blue))
        }

        /// Fails when the color cannot be converted to sRGB; callers must
        /// substitute a documented fallback rather than render silent black.
        init?(_ uiColor: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            else { return nil }
            self.init(
                red: Int((red * 255).rounded()),
                green: Int((green * 255).rounded()),
                blue: Int((blue * 255).rounded()))
        }

        var uiColor: UIColor {
            UIColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1)
        }
    }

    /// WCAG contrast math and the legibility clamp, expressed as pure
    /// functions so tests can assert the contrast contract directly.
    enum Contrast {
        /// The WCAG AA ratio every emitted color pair must reach.
        static let minimumForegroundRatio = 4.5

        /// The ratio the clamp searches for. The small margin absorbs 8-bit
        /// quantization so the rounded result still clears the minimum.
        private static let clampTargetRatio = minimumForegroundRatio + 0.1

        /// WCAG relative luminance of an opaque sRGB color.
        static func relativeLuminance(of color: RGB) -> Double {
            func linear(_ channel: Int) -> Double {
                let value = Double(channel) / 255
                return value <= 0.03928
                    ? value / 12.92
                    : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red)
                + 0.7152 * linear(color.green)
                + 0.0722 * linear(color.blue)
        }

        /// WCAG contrast ratio between two colors, in 1...21.
        static func ratio(of first: RGB, to second: RGB) -> Double {
            let firstLuminance = relativeLuminance(of: first)
            let secondLuminance = relativeLuminance(of: second)
            let lighter = max(firstLuminance, secondLuminance)
            let darker = min(firstLuminance, secondLuminance)
            return (lighter + 0.05) / (darker + 0.05)
        }

        /// Returns `color` unchanged when it already contrasts with
        /// `reference`; otherwise adjusts its lightness — hue and saturation
        /// preserved — until it does, moving away from the reference's
        /// lightness to stay as close to the source as possible.
        ///
        /// The guarantee rests on one fact: against any reference, at least
        /// one lightness extreme (0.0 or 1.0) reaches 4.5:1 — the worst case
        /// is a mid-luminance reference, where black or white still passes.
        /// The references used here (label colors, the snapshot surface, and
        /// already-clamped backgrounds) all satisfy it. If the direction away
        /// from the reference cannot reach the minimum — possible with a
        /// mid-luminance reference — the other direction is used.
        static func legible(_ color: RGB, on reference: RGB) -> RGB {
            guard ratio(of: color, to: reference) < minimumForegroundRatio else { return color }

            let hsl = HSL(color)
            let darken = relativeLuminance(of: color) < relativeLuminance(of: reference)
            let primary = clamped(hsl, on: reference, darken: darken)
            guard ratio(of: primary, to: reference) < minimumForegroundRatio else {
                return primary
            }
            return clamped(hsl, on: reference, darken: !darken)
        }

        /// Binary-searches the lightness value closest to the original that
        /// reaches `clampTargetRatio` against `reference`. Contrast against a
        /// fixed reference is monotonic in lightness, so the search
        /// converges; if even the endpoint misses the target it is returned
        /// as the best effort.
        private static func clamped(_ hsl: HSL, on reference: RGB, darken: Bool) -> RGB {
            var passing = darken ? 0.0 : 1.0
            var failing = hsl.lightness
            for _ in 0..<32 {
                let middle = (passing + failing) / 2
                if ratio(of: hsl.withLightness(middle).rgb, to: reference) >= clampTargetRatio {
                    passing = middle
                } else {
                    failing = middle
                }
            }
            return hsl.withLightness(passing).rgb
        }

        private struct HSL {
            var hue: Double
            var saturation: Double
            var lightness: Double

            init(hue: Double, saturation: Double, lightness: Double) {
                self.hue = hue
                self.saturation = saturation
                self.lightness = lightness
            }

            init(_ rgb: RGB) {
                let red = Double(rgb.red) / 255
                let green = Double(rgb.green) / 255
                let blue = Double(rgb.blue) / 255
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let delta = maximum - minimum

                let lightness = (maximum + minimum) / 2
                guard delta > 0 else {
                    self.init(hue: 0, saturation: 0, lightness: lightness)
                    return
                }

                let saturation = delta / (1 - abs(2 * lightness - 1))
                let hue: Double
                switch maximum {
                case red:
                    hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
                case green:
                    hue = 60 * ((blue - red) / delta + 2)
                default:
                    hue = 60 * ((red - green) / delta + 4)
                }
                self.init(
                    hue: hue < 0 ? hue + 360 : hue,
                    saturation: saturation,
                    lightness: lightness)
            }

            func withLightness(_ lightness: Double) -> HSL {
                HSL(hue: hue, saturation: saturation, lightness: lightness)
            }

            var rgb: RGB {
                let chroma = (1 - abs(2 * lightness - 1)) * saturation
                let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
                let offset = lightness - chroma / 2
                let red: Double
                let green: Double
                let blue: Double
                switch hue {
                case 0..<60: (red, green, blue) = (chroma, x, 0)
                case 60..<120: (red, green, blue) = (x, chroma, 0)
                case 120..<180: (red, green, blue) = (0, chroma, x)
                case 180..<240: (red, green, blue) = (0, x, chroma)
                case 240..<300: (red, green, blue) = (x, 0, chroma)
                default: (red, green, blue) = (chroma, 0, x)
                }
                return RGB(
                    red: Int(((red + offset) * 255).rounded()),
                    green: Int(((green + offset) * 255).rounded()),
                    blue: Int(((blue + offset) * 255).rounded()))
            }
        }
    }

    /// The surface Monitor renders snapshots on, resolved once per
    /// appearance. It is the reference for foregrounds with no explicit
    /// background.
    static func surfaceColor(for appearance: Appearance) -> RGB {
        resolvedSurface.resolve(appearance)
    }

    /// The appearance's default text color, resolved once per appearance.
    /// Backgrounds are clamped against it so ambient label-colored text on
    /// colored backgrounds (diff hunks, selection bars) stays legible.
    static func labelColor(for appearance: Appearance) -> RGB {
        resolvedLabel.resolve(appearance)
    }

    private static let resolvedSurface = DynamicColor(
        light: resolveSystemColor(
            UIColor.secondarySystemGroupedBackground, for: .light,
            fallback: RGB(red: 0xFF, green: 0xFF, blue: 0xFF)),
        dark: resolveSystemColor(
            UIColor.secondarySystemGroupedBackground, for: .dark,
            fallback: RGB(red: 0x1C, green: 0x1C, blue: 0x1E)))
    private static let resolvedLabel = DynamicColor(
        light: resolveSystemColor(
            UIColor.label, for: .light,
            fallback: RGB(red: 0x00, green: 0x00, blue: 0x00)),
        dark: resolveSystemColor(
            UIColor.label, for: .dark,
            fallback: RGB(red: 0xFF, green: 0xFF, blue: 0xFF)))

    /// Resolves a system color in one appearance. The fallback is the value
    /// iOS documents for that color in that appearance, used only when the
    /// color cannot be converted to sRGB.
    private static func resolveSystemColor(
        _ uiColor: UIColor,
        for appearance: Appearance,
        fallback: RGB
    ) -> RGB {
        let style: UIUserInterfaceStyle = appearance == .dark ? .dark : .light
        let resolved = uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        return RGB(resolved) ?? fallback
    }

    /// A pair of per-appearance sRGB values with a dynamic `Color` bridge.
    private struct DynamicColor {
        let light: RGB
        let dark: RGB

        func resolve(_ appearance: Appearance) -> RGB {
            appearance == .dark ? dark : light
        }

        var color: Color {
            Color(uiColor: UIColor { traits in
                resolve(traits.userInterfaceStyle == .dark ? .dark : .light).uiColor
            })
        }
    }

    /// A terminal-requested color: per-appearance source values plus the two
    /// precomputed clamp results for the two roles it can play.
    private struct ANSIColor {
        /// The requested color, per appearance.
        let source: DynamicColor
        /// Foreground role with no explicit background: clamped against the
        /// snapshot surface.
        let onSurface: DynamicColor
        /// Background role: clamped so the appearance's label text stays
        /// legible on it.
        let asBackground: DynamicColor

        init(source: DynamicColor) {
            self.source = source
            onSurface = DynamicColor(
                light: Contrast.legible(
                    source.light, on: ANSISnapshotRenderer.resolvedSurface.light),
                dark: Contrast.legible(
                    source.dark, on: ANSISnapshotRenderer.resolvedSurface.dark))
            asBackground = DynamicColor(
                light: Contrast.legible(
                    source.light, on: ANSISnapshotRenderer.resolvedLabel.light),
                dark: Contrast.legible(
                    source.dark, on: ANSISnapshotRenderer.resolvedLabel.dark))
        }
    }

    private struct Parser {
        private let scalars: String.UnicodeScalarView
        private var index: String.UnicodeScalarView.Index
        private var style = SGRState()
        private var output = AttributedString()

        init(_ snapshot: String) {
            scalars = snapshot.unicodeScalars
            index = scalars.startIndex
        }

        mutating func render() -> AttributedString {
            var textStart = index

            while index < scalars.endIndex {
                let scalar = scalars[index]
                switch scalar.value {
                case 0x1B:
                    appendText(from: textStart, to: index)
                    consumeEscape()
                    textStart = index
                case 0x9B:
                    appendText(from: textStart, to: index)
                    consumeCSI(after: scalars.index(after: index))
                    textStart = index
                case 0x9D:
                    appendText(from: textStart, to: index)
                    consumeControlString(after: scalars.index(after: index), bellTerminates: true)
                    textStart = index
                case 0x90, 0x98, 0x9E, 0x9F:
                    appendText(from: textStart, to: index)
                    consumeControlString(after: scalars.index(after: index), bellTerminates: false)
                    textStart = index
                case 0x00...0x08, 0x0B...0x1F, 0x7F...0x9F:
                    appendText(from: textStart, to: index)
                    index = scalars.index(after: index)
                    textStart = index
                default:
                    index = scalars.index(after: index)
                }
            }

            appendText(from: textStart, to: index)
            return output
        }

        private mutating func appendText(
            from start: String.UnicodeScalarView.Index,
            to end: String.UnicodeScalarView.Index
        ) {
            guard start < end else { return }
            var run = AttributedString(String(scalars[start..<end]))

            // Reverse video swaps the effective colors first; the usual
            // foreground/background rules then apply to the swapped pair.
            // Unset sides fall back to the default label-on-surface pair, so
            // a bare SGR 7 still reads as a visible highlight.
            let foregroundSource = style.reversed ? style.background : style.foreground
            let backgroundSource = style.reversed ? style.foreground : style.background

            // A background is clamped so the appearance's label text stays
            // legible on it; the system fallback (label fill for reverse
            // video) needs no clamp.
            let background: DynamicColor? = backgroundSource?.asBackground
                ?? (style.reversed ? ANSISnapshotRenderer.resolvedLabel : nil)

            let foreground: DynamicColor?
            if let foregroundSource {
                if let background, backgroundSource != nil {
                    // Explicit foreground on an explicit background: clamped
                    // against it here, once per appearance, so the dynamic
                    // provider stays trivial. Every other pairing uses a
                    // precomputed variant.
                    foreground = DynamicColor(
                        light: Contrast.legible(
                            foregroundSource.source.light, on: background.light),
                        dark: Contrast.legible(
                            foregroundSource.source.dark, on: background.dark))
                } else if background != nil {
                    // Reversed with no explicit background: the fill is the
                    // label color, which this variant is clamped against.
                    foreground = foregroundSource.asBackground
                } else {
                    foreground = foregroundSource.onSurface
                }
            } else if style.reversed, let background {
                // Reversed with no explicit foreground: surface-colored text
                // on the fill.
                foreground = DynamicColor(
                    light: Contrast.legible(
                        ANSISnapshotRenderer.resolvedSurface.light, on: background.light),
                    dark: Contrast.legible(
                        ANSISnapshotRenderer.resolvedSurface.dark, on: background.dark))
            } else {
                foreground = nil
            }

            if let foreground {
                run.foregroundColor = style.dim
                    ? foreground.color.opacity(0.5) : foreground.color
            } else if style.dim {
                run.foregroundColor = Color.primary.opacity(0.5)
            }
            if let background {
                run.backgroundColor = background.color
            }

            var emphasis: InlinePresentationIntent = []
            if style.bold {
                emphasis.insert(.stronglyEmphasized)
            }
            if style.italic {
                emphasis.insert(.emphasized)
            }
            if !emphasis.isEmpty {
                run.inlinePresentationIntent = emphasis
            }
            if style.underline {
                run.underlineStyle = .single
            }

            output.append(run)
        }

        private mutating func consumeEscape() {
            let escapeIndex = index
            let nextIndex = scalars.index(after: escapeIndex)
            guard nextIndex < scalars.endIndex else {
                index = scalars.endIndex
                return
            }

            switch scalars[nextIndex].value {
            case 0x5B:
                consumeCSI(after: scalars.index(after: nextIndex))
            case 0x5D:
                consumeControlString(
                    after: scalars.index(after: nextIndex), bellTerminates: true)
            case 0x50, 0x58, 0x5E, 0x5F:
                consumeControlString(
                    after: scalars.index(after: nextIndex), bellTerminates: false)
            case 0x20...0x2F:
                consumeEscapeWithIntermediates(from: nextIndex)
            case 0x30...0x7E:
                index = scalars.index(after: nextIndex)
            default:
                // Preserve a printable non-ASCII scalar following a malformed ESC.
                index = nextIndex
            }
        }

        private mutating func consumeEscapeWithIntermediates(
            from firstIntermediate: String.UnicodeScalarView.Index
        ) {
            var cursor = firstIntermediate
            while cursor < scalars.endIndex {
                let value = scalars[cursor].value
                if (0x30...0x7E).contains(value) {
                    index = scalars.index(after: cursor)
                    return
                }
                guard (0x20...0x2F).contains(value) else {
                    index = cursor
                    return
                }
                cursor = scalars.index(after: cursor)
            }
            index = scalars.endIndex
        }

        private mutating func consumeCSI(after parameterStart: String.UnicodeScalarView.Index) {
            var cursor = parameterStart
            while cursor < scalars.endIndex {
                let value = scalars[cursor].value
                guard (0x40...0x7E).contains(value) else {
                    cursor = scalars.index(after: cursor)
                    continue
                }

                let final = scalars[cursor]
                if final.value == 0x6D,
                    let parameters = parseSGRParameters(scalars[parameterStart..<cursor])
                {
                    applySGR(parameters)
                }
                index = scalars.index(after: cursor)
                return
            }

            // A truncated CSI owns the remainder of the snapshot.
            index = scalars.endIndex
        }

        private func parseSGRParameters(
            _ parameterScalars: String.UnicodeScalarView.SubSequence
        ) -> [Int]? {
            guard parameterScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || $0.value == 0x3B
            }) else {
                return nil
            }

            let source = String(parameterScalars)
            guard !source.isEmpty else { return [0] }
            var parameters: [Int] = []
            for field in source.split(separator: ";", omittingEmptySubsequences: false) {
                if field.isEmpty {
                    parameters.append(0)
                } else if let value = Int(field) {
                    parameters.append(value)
                } else {
                    return nil
                }
            }
            return parameters
        }

        private mutating func consumeControlString(
            after contentStart: String.UnicodeScalarView.Index,
            bellTerminates: Bool
        ) {
            var cursor = contentStart
            while cursor < scalars.endIndex {
                let value = scalars[cursor].value
                if bellTerminates, value == 0x07 {
                    index = scalars.index(after: cursor)
                    return
                }
                if value == 0x9C {
                    index = scalars.index(after: cursor)
                    return
                }
                if value == 0x1B {
                    let next = scalars.index(after: cursor)
                    if next < scalars.endIndex, scalars[next].value == 0x5C {
                        index = scalars.index(after: next)
                        return
                    }
                }
                cursor = scalars.index(after: cursor)
            }

            // A truncated control string owns the remainder of the snapshot.
            index = scalars.endIndex
        }

        private mutating func applySGR(_ parameters: [Int]) {
            var parameterIndex = 0
            while parameterIndex < parameters.count {
                let parameter = parameters[parameterIndex]
                switch parameter {
                case 0:
                    style = SGRState()
                case 1:
                    style.bold = true
                case 2:
                    style.dim = true
                case 3:
                    style.italic = true
                case 4:
                    style.underline = true
                case 7:
                    style.reversed = true
                case 22:
                    style.bold = false
                    style.dim = false
                case 23:
                    style.italic = false
                case 24:
                    style.underline = false
                case 27:
                    style.reversed = false
                case 30...37:
                    style.foreground = Self.ansiColors[parameter - 30]
                case 38:
                    parameterIndex = applyExtendedColor(
                        parameters, at: parameterIndex, to: \SGRState.foreground)
                case 39:
                    style.foreground = nil
                case 40...47:
                    style.background = Self.ansiColors[parameter - 40]
                case 48:
                    parameterIndex = applyExtendedColor(
                        parameters, at: parameterIndex, to: \SGRState.background)
                case 49:
                    style.background = nil
                case 90...97:
                    style.foreground = Self.ansiColors[parameter - 90 + 8]
                case 100...107:
                    style.background = Self.ansiColors[parameter - 100 + 8]
                default:
                    break
                }
                parameterIndex += 1
            }
        }

        private mutating func applyExtendedColor(
            _ parameters: [Int],
            at introducerIndex: Int,
            to keyPath: WritableKeyPath<SGRState, ANSIColor?>
        ) -> Int {
            let modeIndex = introducerIndex + 1
            guard modeIndex < parameters.count else { return parameters.count }

            switch parameters[modeIndex] {
            case 5:
                let colorIndex = modeIndex + 1
                guard colorIndex < parameters.count else { return parameters.count }
                if let color = Self.color256(parameters[colorIndex]) {
                    style[keyPath: keyPath] = color
                }
                return colorIndex
            case 2:
                let blueIndex = modeIndex + 3
                guard blueIndex < parameters.count else { return parameters.count }
                let components = parameters[(modeIndex + 1)...blueIndex]
                if components.allSatisfy({ (0...255).contains($0) }) {
                    let rgb = RGB(
                        red: components[components.startIndex],
                        green: components[components.index(after: components.startIndex)],
                        blue: components[blueIndex])
                    style[keyPath: keyPath] = ANSIColor(
                        source: DynamicColor(light: rgb, dark: rgb))
                }
                return blueIndex
            default:
                return modeIndex
            }
        }

        private static func color256(_ index: Int) -> ANSIColor? {
            guard (0...255).contains(index) else { return nil }
            return ansiColors[index]
        }

        private static func cubeComponent(_ index: Int) -> Int {
            index == 0 ? 0 : 55 + index * 40
        }

        private static func sourceColor(for index: Int) -> DynamicColor {
            if index < basePalette.count {
                return basePalette[index]
            }
            let rgb: RGB
            if index < 232 {
                let cubeIndex = index - 16
                rgb = RGB(
                    red: cubeComponent(cubeIndex / 36),
                    green: cubeComponent((cubeIndex / 6) % 6),
                    blue: cubeComponent(cubeIndex % 6))
            } else {
                let gray = 8 + (index - 232) * 10
                rgb = RGB(red: gray, green: gray, blue: gray)
            }
            return DynamicColor(light: rgb, dark: rgb)
        }

        // All 256 xterm entries with their precomputed clamp results, built
        // once: the base 16 carry hand-picked per-appearance sources, the
        // cube/grayscale entries share one source across appearances.
        private static let ansiColors: [ANSIColor] = (0...255).map { index in
            ANSIColor(source: sourceColor(for: index))
        }

        // Per-appearance sources chosen for legibility of the foreground role
        // on `secondarySystemGroupedBackground`; the background role is
        // derived by the `ANSIColor` clamp, so the WCAG floor holds even if a
        // value is edited later.
        private static let basePalette: [DynamicColor] = [
            DynamicColor(
                light: RGB(red: 0x1C, green: 0x1C, blue: 0x1E),
                dark: RGB(red: 0x8C, green: 0x8C, blue: 0x8C)),
            DynamicColor(
                light: RGB(red: 0xA3, green: 0x15, blue: 0x15),
                dark: RGB(red: 0xF9, green: 0x75, blue: 0x83)),
            DynamicColor(
                light: RGB(red: 0x0A, green: 0x6E, blue: 0x0A),
                dark: RGB(red: 0x56, green: 0xD3, blue: 0x64)),
            DynamicColor(
                light: RGB(red: 0x6D, green: 0x6D, blue: 0x00),
                dark: RGB(red: 0xE5, green: 0xE5, blue: 0x10)),
            DynamicColor(
                light: RGB(red: 0x04, green: 0x51, blue: 0xA5),
                dark: RGB(red: 0x57, green: 0x9B, blue: 0xD5)),
            DynamicColor(
                light: RGB(red: 0x8A, green: 0x0A, blue: 0x8A),
                dark: RGB(red: 0xD6, green: 0x70, blue: 0xD6)),
            DynamicColor(
                light: RGB(red: 0x00, green: 0x76, blue: 0x76),
                dark: RGB(red: 0x39, green: 0xC5, blue: 0xCF)),
            DynamicColor(
                light: RGB(red: 0x59, green: 0x59, blue: 0x59),
                dark: RGB(red: 0xC0, green: 0xC0, blue: 0xC0)),
            DynamicColor(
                light: RGB(red: 0x6E, green: 0x6E, blue: 0x6E),
                dark: RGB(red: 0xA0, green: 0xA0, blue: 0xA0)),
            DynamicColor(
                light: RGB(red: 0xD7, green: 0x00, blue: 0x00),
                dark: RGB(red: 0xFF, green: 0x7B, blue: 0x72)),
            DynamicColor(
                light: RGB(red: 0x00, green: 0x7A, blue: 0x00),
                dark: RGB(red: 0x7C, green: 0xE3, blue: 0x8B)),
            DynamicColor(
                light: RGB(red: 0x71, green: 0x71, blue: 0x00),
                dark: RGB(red: 0xF2, green: 0xF9, blue: 0x7C)),
            DynamicColor(
                light: RGB(red: 0x10, green: 0x59, blue: 0xD0),
                dark: RGB(red: 0x6C, green: 0xB6, blue: 0xFF)),
            DynamicColor(
                light: RGB(red: 0xBC, green: 0x05, blue: 0xBC),
                dark: RGB(red: 0xF9, green: 0x82, blue: 0xF9)),
            DynamicColor(
                light: RGB(red: 0x00, green: 0x7A, blue: 0x7A),
                dark: RGB(red: 0x66, green: 0xE0, blue: 0xE0)),
            DynamicColor(
                light: RGB(red: 0x00, green: 0x00, blue: 0x00),
                dark: RGB(red: 0xFF, green: 0xFF, blue: 0xFF)),
        ]
    }

    private struct SGRState {
        var foreground: ANSIColor?
        var background: ANSIColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var reversed = false
    }
}
