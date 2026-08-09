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
/// appearance, so emitted colors adapt: every foreground is guaranteed to
/// reach WCAG 4.5:1 against `UIColor.secondarySystemGroupedBackground`
/// resolved in the matching appearance.
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
        return removingDecorationOnlyLines(from: cleaned)
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

    private static func removingDecorationOnlyLines(
        from source: AttributedString
    ) -> AttributedString {
        var keptLines: [AttributedString] = []
        var lineStart = source.startIndex
        var cursor = lineStart

        while cursor < source.endIndex {
            if source.characters[cursor] == "\n" {
                appendLine(source[lineStart..<cursor], to: &keptLines)
                cursor = source.characters.index(after: cursor)
                lineStart = cursor
            } else {
                cursor = source.characters.index(after: cursor)
            }
        }
        appendLine(source[lineStart..<source.endIndex], to: &keptLines)

        var result = AttributedString()
        for (index, line) in keptLines.enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            result.append(line)
        }
        return result
    }

    private static func appendLine(
        _ line: AttributedSubstring,
        to lines: inout [AttributedString]
    ) {
        let visibleCharacters = line.characters.filter { !$0.isWhitespace }
        let isDecorationOnly = visibleCharacters.count >= 3
            && visibleCharacters.allSatisfy(isBoxDrawing)
        guard !isDecorationOnly else { return }
        lines.append(trimmingDecorativeEdges(from: line))
    }

    private static func trimmingDecorativeEdges(
        from line: AttributedSubstring
    ) -> AttributedString {
        var start = line.startIndex
        var end = line.endIndex

        var cursor = end
        var trailingDecorationCount = 0
        while cursor > start {
            let previous = line.characters.index(before: cursor)
            let character = line.characters[previous]
            guard character.isWhitespace || isBoxDrawing(character) else { break }
            if isBoxDrawing(character) {
                trailingDecorationCount += 1
            }
            cursor = previous
        }
        if trailingDecorationCount >= 3,
            containsContent(in: line.characters[start..<cursor])
        {
            end = cursor
        }

        cursor = start
        var leadingDecorationCount = 0
        while cursor < end {
            let character = line.characters[cursor]
            guard character.isWhitespace || isBoxDrawing(character) else { break }
            if isBoxDrawing(character) {
                leadingDecorationCount += 1
            }
            cursor = line.characters.index(after: cursor)
        }
        if leadingDecorationCount >= 3,
            containsContent(in: line.characters[cursor..<end])
        {
            start = cursor
        }

        return AttributedString(line[start..<end])
    }

    private static func containsContent(
        in characters: AttributedString.CharacterView.SubSequence
    ) -> Bool {
        characters.contains { !$0.isWhitespace && !isBoxDrawing($0) }
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

        init(_ uiColor: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.init(
                red: Int((red * 255).rounded()),
                green: Int((green * 255).rounded()),
                blue: Int((blue * 255).rounded()))
        }

        var color: Color {
            Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255)
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
        /// The WCAG AA ratio every emitted foreground must reach against the
        /// snapshot surface.
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

        /// Returns `color` unchanged when it already contrasts with `surface`;
        /// otherwise adjusts its lightness — hue and saturation preserved —
        /// until it does. Light surfaces push colors darker, dark surfaces
        /// push them lighter.
        static func legible(_ color: RGB, on surface: RGB, appearance: Appearance) -> RGB {
            guard ratio(of: color, to: surface) < minimumForegroundRatio else { return color }

            let hsl = HSL(color)
            // Contrast against a fixed surface is monotonic in lightness, so a
            // binary search finds the value closest to the original that passes.
            var passing = appearance == .light ? 0.0 : 1.0
            var failing = hsl.lightness
            for _ in 0..<32 {
                let middle = (passing + failing) / 2
                if ratio(of: hsl.withLightness(middle).rgb, to: surface) >= clampTargetRatio {
                    passing = middle
                } else {
                    failing = middle
                }
            }

            var result = hsl.withLightness(passing).rgb
            var attempts = 0
            while ratio(of: result, to: surface) < minimumForegroundRatio, attempts < 8 {
                passing += appearance == .light ? -0.004 : 0.004
                result = hsl.withLightness(min(1, max(0, passing))).rgb
                attempts += 1
            }
            return result
        }

        private struct HSL {
            var hue: Double
            var saturation: Double
            var lightness: Double

            init(_ rgb: RGB) {
                let red = Double(rgb.red) / 255
                let green = Double(rgb.green) / 255
                let blue = Double(rgb.blue) / 255
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let delta = maximum - minimum

                lightness = (maximum + minimum) / 2
                guard delta > 0 else {
                    hue = 0
                    saturation = 0
                    return
                }

                saturation = delta / (1 - abs(2 * lightness - 1))
                switch maximum {
                case red:
                    hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
                case green:
                    hue = 60 * ((blue - red) / delta + 2)
                default:
                    hue = 60 * ((red - green) / delta + 4)
                }
                if hue < 0 {
                    hue += 360
                }
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

    /// The surface Monitor renders snapshots on, resolved per appearance. It
    /// is the reference every emitted foreground is clamped against.
    static func surfaceColor(for appearance: Appearance) -> RGB {
        let style: UIUserInterfaceStyle = appearance == .dark ? .dark : .light
        let resolved = UIColor.secondarySystemGroupedBackground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: style))
        return RGB(resolved)
    }

    /// A color with one value per appearance, each pre-clamped for legibility
    /// on the matching surface, bridged into a single dynamic `Color`.
    private struct AdaptiveColor {
        let light: RGB
        let dark: RGB

        init(light: RGB, dark: RGB) {
            self.light = Contrast.legible(
                light,
                on: ANSISnapshotRenderer.surfaceColor(for: .light),
                appearance: .light)
            self.dark = Contrast.legible(
                dark,
                on: ANSISnapshotRenderer.surfaceColor(for: .dark),
                appearance: .dark)
        }

        /// A single source color (256-color cube, grayscale ramp, truecolor),
        /// clamped per appearance.
        init(source color: RGB) {
            self.init(light: color, dark: color)
        }

        var color: Color {
            Color(uiColor: UIColor { traits in
                (traits.userInterfaceStyle == .dark ? dark : light).uiColor
            })
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

            var foreground = style.foreground?.color
            var background = style.background?.color
            if style.reversed {
                // Reverse video swaps the effective colors. An unset side falls
                // back to the default label-on-surface pair, so a bare SGR 7
                // still reads as a visible highlight in both appearances.
                let swappedForeground = background
                    ?? Color(uiColor: .secondarySystemGroupedBackground)
                let swappedBackground = foreground ?? Color(uiColor: .label)
                foreground = swappedForeground
                background = swappedBackground
            }

            if let foreground {
                run.foregroundColor = style.dim
                    ? foreground.opacity(0.5) : foreground
            } else if style.dim {
                run.foregroundColor = Color.primary.opacity(0.5)
            }
            if let background {
                run.backgroundColor = background
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
            to keyPath: WritableKeyPath<SGRState, AdaptiveColor?>
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
                    style[keyPath: keyPath] = AdaptiveColor(
                        source: RGB(
                            red: components[components.startIndex],
                            green: components[components.index(after: components.startIndex)],
                            blue: components[blueIndex]))
                }
                return blueIndex
            default:
                return modeIndex
            }
        }

        private static func color256(_ index: Int) -> AdaptiveColor? {
            guard (0...255).contains(index) else { return nil }
            if index < ansiColors.count {
                return ansiColors[index]
            }
            if index < 232 {
                let cubeIndex = index - 16
                return AdaptiveColor(
                    source: RGB(
                        red: cubeComponent(cubeIndex / 36),
                        green: cubeComponent((cubeIndex / 6) % 6),
                        blue: cubeComponent(cubeIndex % 6)))
            }
            let gray = 8 + (index - 232) * 10
            return AdaptiveColor(source: RGB(red: gray, green: gray, blue: gray))
        }

        private static func cubeComponent(_ index: Int) -> Int {
            index == 0 ? 0 : 55 + index * 40
        }

        // Per-appearance values chosen for legibility on
        // `secondarySystemGroupedBackground`; `AdaptiveColor` still clamps
        // them, so the WCAG floor holds even if a value is edited later.
        private static let ansiColors: [AdaptiveColor] = [
            AdaptiveColor(
                light: RGB(red: 0x1C, green: 0x1C, blue: 0x1E),
                dark: RGB(red: 0x8C, green: 0x8C, blue: 0x8C)),
            AdaptiveColor(
                light: RGB(red: 0xA3, green: 0x15, blue: 0x15),
                dark: RGB(red: 0xF9, green: 0x75, blue: 0x83)),
            AdaptiveColor(
                light: RGB(red: 0x0A, green: 0x6E, blue: 0x0A),
                dark: RGB(red: 0x56, green: 0xD3, blue: 0x64)),
            AdaptiveColor(
                light: RGB(red: 0x6D, green: 0x6D, blue: 0x00),
                dark: RGB(red: 0xE5, green: 0xE5, blue: 0x10)),
            AdaptiveColor(
                light: RGB(red: 0x04, green: 0x51, blue: 0xA5),
                dark: RGB(red: 0x57, green: 0x9B, blue: 0xD5)),
            AdaptiveColor(
                light: RGB(red: 0x8A, green: 0x0A, blue: 0x8A),
                dark: RGB(red: 0xD6, green: 0x70, blue: 0xD6)),
            AdaptiveColor(
                light: RGB(red: 0x00, green: 0x76, blue: 0x76),
                dark: RGB(red: 0x39, green: 0xC5, blue: 0xCF)),
            AdaptiveColor(
                light: RGB(red: 0x59, green: 0x59, blue: 0x59),
                dark: RGB(red: 0xC0, green: 0xC0, blue: 0xC0)),
            AdaptiveColor(
                light: RGB(red: 0x6E, green: 0x6E, blue: 0x6E),
                dark: RGB(red: 0xA0, green: 0xA0, blue: 0xA0)),
            AdaptiveColor(
                light: RGB(red: 0xD7, green: 0x00, blue: 0x00),
                dark: RGB(red: 0xFF, green: 0x7B, blue: 0x72)),
            AdaptiveColor(
                light: RGB(red: 0x00, green: 0x7A, blue: 0x00),
                dark: RGB(red: 0x7C, green: 0xE3, blue: 0x8B)),
            AdaptiveColor(
                light: RGB(red: 0x71, green: 0x71, blue: 0x00),
                dark: RGB(red: 0xF2, green: 0xF9, blue: 0x7C)),
            AdaptiveColor(
                light: RGB(red: 0x10, green: 0x59, blue: 0xD0),
                dark: RGB(red: 0x6C, green: 0xB6, blue: 0xFF)),
            AdaptiveColor(
                light: RGB(red: 0xBC, green: 0x05, blue: 0xBC),
                dark: RGB(red: 0xF9, green: 0x82, blue: 0xF9)),
            AdaptiveColor(
                light: RGB(red: 0x00, green: 0x7A, blue: 0x7A),
                dark: RGB(red: 0x66, green: 0xE0, blue: 0xE0)),
            AdaptiveColor(
                light: RGB(red: 0x00, green: 0x00, blue: 0x00),
                dark: RGB(red: 0xFF, green: 0xFF, blue: 0xFF)),
        ]
    }

    private struct SGRState {
        var foreground: AdaptiveColor?
        var background: AdaptiveColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var reversed = false
    }
}
