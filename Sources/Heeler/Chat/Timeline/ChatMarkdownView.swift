import SwiftUI

/// An assistant message's Markdown, one block at a time: paragraphs and
/// headings as text, list items after their markers, quotes with a bar,
/// code in a monospaced box and tables in aligned, wrapping columns.
/// Only tables too wide for the available space scroll horizontally.
///
/// Blocks sit on the next line or a blank line apart wherever Claude Code's
/// terminal puts them. A blank line before a heading is wider and one after
/// it narrower, so a heading stays with the text it introduces.
struct ChatMarkdownView: View {
    let blocks: [ChatMarkdownBlock]
    /// Text that reads as the process rather than the answer, in the
    /// secondary color as quotes are.
    var isMuted = false
    @ScaledMetric(relativeTo: .body) private var nextLineGap: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var blankLineGap: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var aboveHeadingGap: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var belowHeadingGap: CGFloat = 12
    @Environment(\.chatImageOpener) private var imageOpener

    var body: some View {
        let _ = PerfTrace.count("ChatMarkdownView.body")
        let _ = PerfTrace.count("ChatMarkdownView.blocks", blocks.count)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { @Sendable index in
                MainActorContent {
                    ChatMarkdownBlockView(block: blocks[index], isMuted: isMuted)
                        .padding(.top, gap(before: index))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatMessageLinks(opener: imageOpener)
    }

    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let block = blocks[index]
        guard block.blankLineBefore else { return nextLineGap }
        if case .heading = blocks[index - 1].kind {
            return belowHeadingGap
        }
        if case .heading = block.kind {
            return aboveHeadingGap
        }
        return blankLineGap
    }

    /// The content with its strong emphasis bold in `font`.
    ///
    /// `Text` draws the strong intent with `Font.bold()`, which gives a text
    /// style only semibold: Chinese strokes gain about a third of a point,
    /// and with Bold Text on, strong text looks the same as the rest. A run
    /// font of an explicit bold weight draws real bold, which the intent
    /// would override, so the intent goes. Emphasis, code and strikethrough
    /// stay intents.
    nonisolated static func boldingStrongEmphasis(_ content: AttributedString, in font: Font) -> AttributedString {
        guard content.runs.contains(where: { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }) else {
            return content
        }
        var result = AttributedString()
        for run in content.runs {
            var piece = AttributedString(content[run.range])
            if var intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                intent.remove(.stronglyEmphasized)
                piece.inlinePresentationIntent = intent.isEmpty ? nil : intent
                piece.font = font.weight(.bold)
            }
            result.append(piece)
        }
        return result
    }

    /// The content with its inline code on a tinted background.
    ///
    /// The monospaced design has no CJK glyphs, so code in Chinese would
    /// read as body text. The tint marks it in every script. Code that
    /// opens an image is a link instead (see `styled`).
    nonisolated static func tintingCode(_ content: AttributedString, opensImages: Bool = false) -> AttributedString {
        var result = content
        for run in content.runs where run.inlinePresentationIntent?.contains(.code) == true {
            if opensImages, run[ChatImageLink.PathAttribute.self] != nil { continue }
            result[run.range].backgroundColor = Color(uiColor: .tertiarySystemFill)
        }
        return result
    }

    /// The content as a text block draws it in `font`.
    ///
    /// Chat's font sets a design on the whole conversation, which outranks
    /// the code intent's monospaced one; a run font outranks the design, so
    /// code keeps its face in every Chat font. Where Chat can open images,
    /// a path to one is a link in the tint color (`ChatImageLink`).
    nonisolated static func styled(_ content: AttributedString, in font: Font, opensImages: Bool = false)
        -> AttributedString
    {
        var result = tintingCode(boldingStrongEmphasis(content, in: font), opensImages: opensImages)
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let runFont = run[AttributeScopes.SwiftUIAttributes.FontAttribute.self] ?? font
                result[run.range].font = runFont.monospaced()
            }
            if opensImages, let path = run[ChatImageLink.PathAttribute.self] {
                result[run.range].link = ChatImageLink.url(for: path)
            }
        }
        return result
    }

    /// The content as a text block draws it in `font`: `styled`, with a
    /// photo symbol before each path that opens an image, so the link reads
    /// as a picture rather than as code or a web page.
    static func text(_ content: AttributedString, in font: Font, opensImages: Bool) -> Text {
        let styled = styled(content, in: font, opensImages: opensImages)
        guard opensImages, styled.runs.contains(where: { $0[ChatImageLink.PathAttribute.self] != nil }) else {
            return Text(styled)
        }
        var pieces: [Text] = []
        var chunk = AttributedString()
        var previousPath: String?
        for run in styled.runs {
            let path = run[ChatImageLink.PathAttribute.self]
            if let path, path != previousPath {
                if !chunk.characters.isEmpty { pieces.append(Text(chunk)) }
                chunk = AttributedString()
                // A no-break space keeps the symbol on its path's line.
                pieces.append(Text("\(Image(systemName: "photo"))\u{00A0}").foregroundStyle(.tint))
            }
            previousPath = path
            chunk.append(styled[run.range])
        }
        if !chunk.characters.isEmpty { pieces.append(Text(chunk)) }
        return pieces.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
    }
}

/// Opens an image file a message names, by its path as written
/// (`ChatImageLink`). Rows that can open images put one in the environment.
struct ChatImageOpener {
    let open: @MainActor (String) -> Void
}

extension EnvironmentValues {
    @Entry var chatImageOpener: ChatImageOpener? = nil
}

extension View {
    /// What links in message text do: web links that pass `ChatLinkPolicy`
    /// open in the browser and image paths in Chat's preview; nothing else
    /// the model wrote acts on the phone.
    func chatMessageLinks(opener: ChatImageOpener?) -> some View {
        environment(\.openURL, OpenURLAction { url in
            if let path = ChatImageLink.path(opening: url) {
                opener?.open(path)
                return opener == nil ? .discarded : .handled
            }
            return ChatLinkPolicy.allows(url) ? .systemAction : .discarded
        })
    }
}

private struct ChatMarkdownBlockView: View {
    @Environment(\.themeColors) private var themeColors
    let block: ChatMarkdownBlock
    let isMuted: Bool
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18
    @Environment(\.chatImageOpener) private var imageOpener

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<block.quoteDepth, id: \.self) { @Sendable _ in
                MainActorContent {
                    Capsule()
                        .fill(Color(uiColor: .tertiaryLabel))
                        .frame(width: 3)
                }
            }
            content
                .foregroundStyle(block.quoteDepth > 0 || isMuted ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, leadingIndent)
    }

    /// A list item's marker sits one level out from its text; a paragraph
    /// continuing an item lines up with that text.
    private var leadingIndent: CGFloat {
        guard block.listDepth > 0 else { return 0 }
        if case .listItem = block.kind {
            return CGFloat(block.listDepth - 1) * indent
        }
        return CGFloat(block.listDepth) * indent
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .paragraph:
            styledText(in: .body)
        case .heading(let level):
            styledText(in: Self.headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: indent - 6, alignment: .trailing)
                styledText(in: .body)
            }
        case .code(let language):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: block.text)
                    .font(.system(.footnote, design: .monospaced))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeColors.raised, in: .rect(cornerRadius: 10))
        case .table:
            if let table = block.table {
                ChatMarkdownTableView(table: table)
            } else {
                Text(verbatim: block.text).font(.body)
            }
        case .thematicBreak:
            // A `Divider` would follow the axis of the `HStack` in `body`
            // and stand upright.
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1 / 3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        case .html:
            Text(verbatim: block.text)
                .font(.body)
        }
    }

    private func styledText(in font: Font) -> some View {
        ChatMarkdownView.text(block.content, in: font, opensImages: imageOpener != nil)
            .font(font)
    }

    /// Every level is bold, as Claude Code's terminal draws them, and the
    /// top two are larger than the text.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.bold)
        default: .body.weight(.bold)
        }
    }
}

/// A native table with stable column widths across every row. Wide tables
/// scroll within their own bounds; ordinary two-column tables fit the phone.
struct ChatMarkdownTableView: View {
    @Environment(\.themeColors) private var themeColors
    let table: ChatMarkdownBlock.Table
    @ScaledMetric(relativeTo: .subheadline) private var minimumColumnWidth: CGFloat = 112
    @Environment(\.chatImageOpener) private var imageOpener

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
    }

    private var grid: some View {
        ChatMarkdownTableLayout(columns: table.columns.count, minimumColumnWidth: minimumColumnWidth) {
            ForEach(table.rows.indices, id: \.self) { @Sendable row in
                MainActorContent {
                    ForEach(table.columns.indices, id: \.self) { @Sendable column in
                        MainActorContent {
                            let alignment = alignment(for: table.columns[column])
                            ChatMarkdownView.text(
                                table.rows[row][column], in: .subheadline, opensImages: imageOpener != nil)
                                .font(row == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                .multilineTextAlignment(textAlignment(for: table.columns[column]))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                                .padding(8)
                                .background(row == 0 ? themeColors.raised : themeColors.background)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
                                }
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(Color(uiColor: .separator)).frame(width: 0.5)
                                }
                                .accessibilityAddTraits(row == 0 ? .isHeader : [])
                        }
                    }
                }
            }
        }
    }

    private func alignment(for column: ChatMarkdownBlock.Table.Alignment) -> Alignment {
        switch column {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        }
    }

    private func textAlignment(for column: ChatMarkdownBlock.Table.Alignment) -> TextAlignment {
        switch column {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// Measures each cell with its column width before choosing a row height.
/// A long cell therefore wraps without changing the widths in other rows.
struct ChatMarkdownTableLayout: Layout {
    let columns: Int
    let minimumColumnWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(proposal.width ?? 0, CGFloat(columns) * minimumColumnWidth)
        return CGSize(width: width, height: rowHeights(width: width, subviews: subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard columns > 0 else { return }
        let width = bounds.width / CGFloat(columns)
        let heights = rowHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard subviews.indices.contains(index) else { continue }
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * width, y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: width, height: height))
            }
            y += height
        }
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        guard columns > 0 else { return [] }
        let cellProposal = ProposedViewSize(width: width / CGFloat(columns), height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(cellProposal).height }.max() ?? 0
        }
    }
}
