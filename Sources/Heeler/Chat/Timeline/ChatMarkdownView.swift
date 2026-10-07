import SwiftUI

/// An assistant message's Markdown, one block at a time: paragraphs and
/// headings as text, list items after their markers, quotes with a bar,
/// code and tables in a monospaced box that wraps rather than scrolls
/// sideways (a horizontal scroll would fight the edge back gesture).
///
/// Blocks sit on the next line or a blank line apart wherever Claude Code's
/// terminal puts them. A blank line before a heading is wider and one after
/// it narrower, so a heading stays with the text it introduces.
struct ChatMarkdownView: View {
    let blocks: [ChatMarkdownBlock]
    @ScaledMetric(relativeTo: .body) private var nextLineGap: CGFloat = 4
    @ScaledMetric(relativeTo: .body) private var blankLineGap: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var aboveHeadingGap: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var belowHeadingGap: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                ChatMarkdownBlockView(block: blocks[index])
                    .padding(.top, gap(before: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Links that pass `ChatLinkPolicy` open in the browser; nothing else
        // the model wrote acts on the phone.
        .environment(\.openURL, OpenURLAction { url in
            ChatLinkPolicy.allows(url) ? .systemAction : .discarded
        })
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
}

private struct ChatMarkdownBlockView: View {
    let block: ChatMarkdownBlock
    @ScaledMetric(relativeTo: .body) private var indent: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                Capsule()
                    .fill(Color(uiColor: .tertiaryLabel))
                    .frame(width: 3)
            }
            content
                .foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
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
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
        case .table:
            Text(verbatim: block.text)
                .font(.system(.footnote, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
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
        Text(ChatMarkdownView.boldingStrongEmphasis(block.content, in: font))
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
