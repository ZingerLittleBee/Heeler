import SwiftUI

/// An assistant message's Markdown, one block at a time: paragraphs and
/// headings as text, list items after their markers, quotes with a bar,
/// code and tables in a monospaced box that wraps rather than scrolls
/// sideways (a horizontal scroll would fight the edge back gesture).
struct ChatMarkdownView: View {
    let blocks: [ChatMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                ChatMarkdownBlockView(block: blocks[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Links that pass `ChatLinkPolicy` open in the browser; nothing else
        // the model wrote acts on the phone.
        .environment(\.openURL, OpenURLAction { url in
            ChatLinkPolicy.allows(url) ? .systemAction : .discarded
        })
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
            Text(block.content)
                .font(.body)
        case .heading(let level):
            Text(block.content)
                .font(Self.headingFont(level))
                .padding(.top, level <= 2 ? 4 : 0)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: indent - 6, alignment: .trailing)
                Text(block.content)
                    .font(.body)
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
            Divider()
                .padding(.vertical, 4)
        case .html:
            Text(verbatim: block.text)
                .font(.body)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}
