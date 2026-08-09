import Foundation
import SwiftUI

/// Renders the ANSI-formatted text returned by herdr reads for Monitor.
///
/// The renderer preserves printable text and line structure, applies the SGR
/// subset Monitor understands, and removes every other terminal control
/// sequence. It has no I/O or terminal state beyond the supplied snapshot.
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
        return removingDecorationOnlyLines(
            from: removingTrailingInputRegion(from: cleaned))
    }

    /// Monitor owns the only visible Composer. Agent TUIs place their own
    /// prompt at the bottom of the visible screen, commonly with model/path
    /// chrome below it. Remove that trailing region without parsing message
    /// boundaries or changing the raw snapshot used by history stitching.
    private static func removingTrailingInputRegion(
        from source: AttributedString
    ) -> AttributedString {
        let lines = attributedLines(in: source)
        let searchStart = max(0, lines.count - 8)
        guard let inputLineIndex = (searchStart..<lines.count).reversed().first(where: { index in
            guard isInputPromptLine(lines[index].text) else { return false }
            let hasTrailingChrome = lines[(index + 1)...].contains {
                !$0.text.allSatisfy(\.isWhitespace)
            }
            let leadingStart = max(0, index - 2)
            let hasLeadingDivider = lines[leadingStart..<index].contains {
                isDecorationOnlyLine($0.text)
            }
            let isBorderedPrompt = lines[index].text.trimmingCharacters(in: .whitespaces)
                .first.map { "│┃║".contains($0) } ?? false
            return hasTrailingChrome || hasLeadingDivider || isBorderedPrompt
        }) else {
            return source
        }

        var lastContentLine = inputLineIndex - 1
        while lastContentLine >= 0,
            lines[lastContentLine].text.allSatisfy(\.isWhitespace)
        {
            lastContentLine -= 1
        }
        guard lastContentLine >= 0 else { return AttributedString() }
        return AttributedString(source[source.startIndex..<lines[lastContentLine].end])
    }

    private struct AttributedLine {
        let text: String
        let end: AttributedString.Index
    }

    private static func attributedLines(in source: AttributedString) -> [AttributedLine] {
        var lines: [AttributedLine] = []
        var start = source.startIndex
        var cursor = start

        while cursor < source.endIndex {
            if source.characters[cursor] == "\n" {
                lines.append(
                    AttributedLine(
                        text: String(source.characters[start..<cursor]),
                        end: cursor))
                cursor = source.characters.index(after: cursor)
                start = cursor
            } else {
                cursor = source.characters.index(after: cursor)
            }
        }
        lines.append(
            AttributedLine(
                text: String(source.characters[start..<source.endIndex]),
                end: source.endIndex))
        return lines
    }

    private static func isInputPromptLine(_ line: String) -> Bool {
        var visible = line.trimmingCharacters(in: .whitespaces)
        while let first = visible.first, "│┃║".contains(first) {
            visible.removeFirst()
            visible = visible.trimmingCharacters(in: .whitespaces)
        }
        guard let marker = visible.first else { return false }
        return marker == "›" || marker == "❯"
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
        guard !isDecorationOnlyLine(String(line.characters)) else { return }
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

    private static func isDecorationOnlyLine(_ line: String) -> Bool {
        let visibleCharacters = line.filter { !$0.isWhitespace }
        return visibleCharacters.count >= 3
            && visibleCharacters.allSatisfy(isBoxDrawing)
    }
}

extension ANSISnapshotRenderer {
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

            if let foreground = style.foreground {
                run.foregroundColor = style.dim
                    ? foreground.color.opacity(0.5) : foreground.color
            } else if style.dim {
                run.foregroundColor = Color.primary.opacity(0.5)
            }
            if let background = style.background {
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
                case 22:
                    style.bold = false
                    style.dim = false
                case 23:
                    style.italic = false
                case 24:
                    style.underline = false
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
            to keyPath: WritableKeyPath<SGRState, RGB?>
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
                    style[keyPath: keyPath] = RGB(
                        red: components[components.startIndex],
                        green: components[components.index(after: components.startIndex)],
                        blue: components[blueIndex])
                }
                return blueIndex
            default:
                return modeIndex
            }
        }

        private static func color256(_ index: Int) -> RGB? {
            guard (0...255).contains(index) else { return nil }
            if index < ansiColors.count {
                return ansiColors[index]
            }
            if index < 232 {
                let cubeIndex = index - 16
                return RGB(
                    red: cubeComponent(cubeIndex / 36),
                    green: cubeComponent((cubeIndex / 6) % 6),
                    blue: cubeComponent(cubeIndex % 6))
            }
            let gray = 8 + (index - 232) * 10
            return RGB(red: gray, green: gray, blue: gray)
        }

        private static func cubeComponent(_ index: Int) -> Int {
            index == 0 ? 0 : 55 + index * 40
        }

        private static let ansiColors: [RGB] = [
            RGB(red: 0x00, green: 0x00, blue: 0x00),
            RGB(red: 0x80, green: 0x00, blue: 0x00),
            RGB(red: 0x00, green: 0x80, blue: 0x00),
            RGB(red: 0x80, green: 0x80, blue: 0x00),
            RGB(red: 0x00, green: 0x00, blue: 0x80),
            RGB(red: 0x80, green: 0x00, blue: 0x80),
            RGB(red: 0x00, green: 0x80, blue: 0x80),
            RGB(red: 0xC0, green: 0xC0, blue: 0xC0),
            RGB(red: 0x80, green: 0x80, blue: 0x80),
            RGB(red: 0xFF, green: 0x00, blue: 0x00),
            RGB(red: 0x00, green: 0xFF, blue: 0x00),
            RGB(red: 0xFF, green: 0xFF, blue: 0x00),
            RGB(red: 0x00, green: 0x00, blue: 0xFF),
            RGB(red: 0xFF, green: 0x00, blue: 0xFF),
            RGB(red: 0x00, green: 0xFF, blue: 0xFF),
            RGB(red: 0xFF, green: 0xFF, blue: 0xFF),
        ]
    }

    private struct SGRState {
        var foreground: RGB?
        var background: RGB?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        var color: Color {
            Color(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255)
        }
    }
}
