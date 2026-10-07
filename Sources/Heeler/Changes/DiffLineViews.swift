import SwiftUI
import UIKit

/// One line beside its gutter: the line numbers on the gutter's wash, the
/// sign, and the code on the line's wash. A unified row shows both numbers;
/// a side-by-side cell shows its own side's.
struct DiffLineRow: View {
    let line: DiffLine
    let numbers: [Int?]
    let numberDigits: Int
    /// Space before the first line number, inside the gutter.
    let gutterLeading: CGFloat
    let wordChanges: [Range<Int>]
    /// A side-by-side cell stretches to its taller neighbour.
    var fillsHeight = false
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @ScaledMetric(relativeTo: .caption2) private var digitWidth: CGFloat =
        DiffLayoutPolicy.defaultDigitWidth
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat =
        DiffLayoutPolicy.defaultGlyphWidth

    var body: some View {
        let palette = DiffPalette.current(differentiatingWithoutColor: differentiateWithoutColor)
        let ink = Color(uiColor: palette.ink(for: line.kind))
        let numberWidth = digitWidth * CGFloat(max(numberDigits, 1))
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DiffLayoutPolicy.numberSpacing) {
                ForEach(Array(numbers.enumerated()), id: \.offset) { _, number in
                    // The digit width is an estimate the font can exceed by
                    // a hair, which must not wrap a number onto two lines.
                    Text(verbatim: number.map(String.init) ?? "")
                        .font(.caption2.monospaced())
                        .fixedSize()
                        .frame(width: numberWidth, alignment: .trailing)
                }
            }
            .padding(.leading, gutterLeading)
            .padding(.trailing, DiffLayoutPolicy.numberSpacing)
            .foregroundStyle(ink)
            Text(verbatim: line.glyph)
                .font(.footnote.monospaced().weight(.semibold))
                .foregroundStyle(ink)
                .frame(width: glyphWidth)
            DiffCodeText(line: line, wordChanges: wordChanges, palette: palette)
                .padding(.trailing, DiffLayoutPolicy.trailingPadding)
        }
        .padding(.vertical, 0.5)
        .frame(
            maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Color(uiColor: palette.gutter(for: line.kind))
                    .frame(
                        width: DiffLayoutPolicy.gutterWidth(
                            leading: gutterLeading, numberWidth: numberWidth,
                            numbers: numbers.count))
                Color(uiColor: palette.background(for: line.kind))
            }
        }
    }
}

/// A line's code in the label colour. Leading indentation is a fixed prefix,
/// so a long line wraps under its own first character rather than the
/// margin. Changed words carry a fill and a 1 pt outline.
struct DiffCodeText: View {
    let line: DiffLine
    let wordChanges: [Range<Int>]
    let palette: DiffPalette
    /// Deeper indentation wraps with the text instead of starving it.
    static let maximumHangingIndent = 32

    var body: some View {
        let parts = Self.split(line.text)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if !parts.indent.isEmpty {
                    Text(verbatim: parts.indent)
                        .fixedSize()
                }
                code(parts)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if line.missingNewline {
                Text("No newline at end of file")
                    .font(.caption2)
                    .foregroundStyle(Color(uiColor: DiffPalette.contextNumber))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .font(.footnote.monospaced())
        .foregroundStyle(Color(uiColor: DiffPalette.code))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func code(_ parts: (indent: String, code: String)) -> some View {
        let offset = parts.indent.count
        let changes = wordChanges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound - offset, 0)
            let upper = range.upperBound - offset
            return upper > lower ? lower..<upper : nil
        }
        if let change = palette.change(line.kind), !changes.isEmpty {
            Self.text(parts.code, changes: changes)
                .textRenderer(DiffWordRenderer(
                    fill: Color(uiColor: change.word),
                    outline: Color(uiColor: change.ink).opacity(0.7)))
        } else {
            Text(verbatim: parts.code.isEmpty && parts.indent.isEmpty ? " " : parts.code)
        }
    }

    /// The leading run of spaces and tabs, capped, and the rest of the line.
    static func split(_ text: String) -> (indent: String, code: String) {
        let indent = text.prefix { $0 == " " || $0 == "\t" }.prefix(maximumHangingIndent)
        // A blank line keeps its whitespace as code so the row keeps its height.
        guard indent.count < text.count else { return ("", text) }
        return (String(indent), String(text.dropFirst(indent.count)))
    }

    /// The code with each changed range marked for `DiffWordRenderer`.
    static func text(_ code: String, changes: [Range<Int>]) -> Text {
        let characters = Array(code)
        var result = Text(verbatim: "")
        var cursor = 0
        for range in changes where range.lowerBound >= cursor {
            let upper = min(range.upperBound, characters.count)
            guard range.lowerBound < upper else { continue }
            if range.lowerBound > cursor {
                let plain = Text(verbatim: String(characters[cursor..<range.lowerBound]))
                result = Text("\(result)\(plain)")
            }
            let word = Text(verbatim: String(characters[range.lowerBound..<upper]))
                .customAttribute(DiffWordAttribute())
            result = Text("\(result)\(word)")
            cursor = upper
        }
        if cursor < characters.count {
            let plain = Text(verbatim: String(characters[cursor...]))
            result = Text("\(result)\(plain)")
        }
        return result
    }
}

/// Marks a changed word for `DiffWordRenderer`.
struct DiffWordAttribute: TextAttribute {}

/// Draws a rounded fill and outline behind each changed word, then the text.
/// The outline is the second channel beside colour.
struct DiffWordRenderer: TextRenderer {
    let fill: Color
    let outline: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[DiffWordAttribute.self] != nil {
                let shape = Path(
                    roundedRect: run.typographicBounds.rect.insetBy(dx: -1, dy: 0),
                    cornerRadius: 2)
                context.fill(shape, with: .color(fill))
                context.stroke(shape, with: .color(outline), lineWidth: 1)
            }
        }
        for line in layout {
            context.draw(line)
        }
    }
}

/// A side-by-side cell with no line: diagonals phased to the scroll content,
/// so a run of blank cells reads as one hatched block with no seams.
struct DiffHatch: View {
    /// The diff's scrolling content, which every blank cell measures against.
    static let coordinateSpace = "file-diff-content"
    private static let period: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .named(Self.coordinateSpace)).origin
            Canvas { context, size in
                // Lines where x + y is a multiple of the period in content
                // coordinates, from the top-right towards the bottom-left.
                var start = (-(origin.x + origin.y)).truncatingRemainder(dividingBy: Self.period)
                if start < 0 { start += Self.period }
                var path = Path()
                var constant = start
                while constant <= size.width + size.height {
                    path.move(to: CGPoint(x: constant, y: 0))
                    path.addLine(to: CGPoint(x: constant - size.height, y: size.height))
                    constant += Self.period
                }
                context.stroke(path, with: .color(Color(uiColor: DiffPalette.hatch)), lineWidth: 1)
            }
        }
        .background(Color(uiColor: DiffPalette.background))
        .accessibilityHidden(true)
    }
}

/// A hunk's band: its range and section context, and how many unchanged
/// lines precede it. When the row is narrow the count wraps under them; at
/// accessibility sizes the range hides. VoiceOver reads the full header.
struct FileDiffHunkBand: View {
    let hunk: DiffHunk
    let unchangedLinesBefore: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                heading
                if hunk.section.isEmpty {
                    Spacer(minLength: 0)
                }
                count
            }
            VStack(alignment: .leading, spacing: 2) {
                heading
                count
            }
        }
        .foregroundStyle(Color(uiColor: DiffPalette.hunkText))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: DiffPalette.hunkBand))
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hunk.title)
        .accessibilityValue(unchangedLinesBefore.map(Self.unchangedSummary) ?? "")
    }

    static func unchangedSummary(_ count: Int) -> String {
        "\(count.formatted()) unchanged \(count == 1 ? "line" : "lines")"
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text(verbatim: hunk.range)
                    .font(.caption2.monospaced())
                    .fixedSize()
            }
            if !hunk.section.isEmpty {
                Text(verbatim: hunk.section)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Measured narrow, so a long section truncates beside
                    // the count before the count wraps.
                    .frame(minWidth: 44, idealWidth: 44, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var count: some View {
        if let unchangedLinesBefore {
            Text(Self.unchangedSummary(unchangedLinesBefore))
                .font(.caption2)
                .monospacedDigit()
                .fixedSize()
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / displayScale)
    }
}

/// One file of a patch: its change letter, its kind and staging, the
/// patch's own notes (a rename, a mode change, a binary file), and its
/// totals. The label is the path, as the Files rotor names it.
struct FileDiffFileBar: View {
    let path: String
    let kind: ChangedFile.Kind
    let detail: String
    let summary: String?
    let lineCounts: LineCounts?
    /// Shown when a patch holds more than one file, so each is named.
    let showsPath: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ChangeKindBadge(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                if showsPath {
                    Text(verbatim: path)
                        .font(.footnote.monospaced().weight(.semibold))
                }
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let lineCounts {
                ChangesLineCounts(counts: lineCounts)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(path)
        .accessibilityValue(
            [detail, summary, lineCounts?.accessibilityLabel].compactMap(\.self)
                .joined(separator: ", "))
    }
}

/// A file's change letter in a rounded outline, in its kind's colour.
struct ChangeKindBadge: View {
    let kind: ChangedFile.Kind
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 18

    var body: some View {
        let color = Color(uiColor: ChangeKindPalette.color(for: kind))
        Text(verbatim: kind.symbol)
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.5)
            }
            .accessibilityHidden(true)
    }
}

/// Change letters in VS Code's and GitHub's colours. Each letter is its own
/// glyph, so colour is never the only channel.
enum ChangeKindPalette {
    static func color(for kind: ChangedFile.Kind) -> UIColor {
        switch kind {
        case .modified: DiffPalette.adaptive(light: 0x8A5C00, dark: 0xE2C08D)
        case .added: DiffPalette.github.added.ink
        case .deleted: DiffPalette.github.removed.ink
        case .renamed: DiffPalette.adaptive(light: 0x0969DA, dark: 0x79C0FF)
        case .untracked: DiffPalette.adaptive(light: 0x1A7F37, dark: 0x56D364)
        case .conflicted: DiffPalette.adaptive(light: 0x8250DF, dark: 0xD2A8FF)
        }
    }
}
