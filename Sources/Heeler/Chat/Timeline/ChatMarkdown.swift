import Foundation

/// One block of an assistant message's Markdown, in reading order: a
/// paragraph, a heading, a list item, a code block and so on.
///
/// SwiftUI's `Text` draws inline styles and links but ignores block
/// structure, and Foundation's parser puts no newlines between blocks, so a
/// whole message in one `Text` runs its headings, paragraphs and list items
/// together. Chat draws one of these at a time instead and lays out lists,
/// quotes and code itself.
struct ChatMarkdownBlock: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case paragraph
        /// Levels 1 through 6.
        case heading(level: Int)
        /// The first block of a list item, drawn after its marker: a bullet
        /// that changes with depth, or the item's number, counting up from
        /// the list's first number as Markdown renderers do (`1.` `1.` `1.`
        /// shows as 1, 2, 3).
        case listItem(marker: String)
        /// A fenced or indented code block. The language is the first word
        /// of the fence's info string.
        case code(language: String?)
        /// A table as its source lines, for a monospaced font. Tables are
        /// rare in messages; laying them out as grids can come later.
        case table
        case thematicBreak
        /// A raw HTML block, shown as written. Chat never interprets HTML.
        case html
    }

    let kind: Kind
    /// What to draw: the text with its inline styles (emphasis, strong,
    /// inline code, strikethrough) and permitted links, and without block
    /// attributes. Empty for a thematic break, and for a list item whose
    /// first block is not a paragraph; that block follows as its own.
    let content: AttributedString
    /// The block as plain text, for Select Text and VoiceOver. A list item
    /// starts with its marker and a space, so a numbered list keeps its
    /// numbers when it is selected or read aloud. Empty for a thematic break.
    let text: String
    /// How many list items contain the block: 0 outside any list, 1 in a
    /// top-level item.
    let listDepth: Int
    /// How many block quotes contain the block.
    let quoteDepth: Int

    init(kind: Kind, content: AttributedString, text: String, listDepth: Int = 0, quoteDepth: Int = 0) {
        self.kind = kind
        self.content = content
        self.text = text
        self.listDepth = listDepth
        self.quoteDepth = quoteDepth
    }
}

/// Splits an assistant message's Markdown into blocks.
///
/// Foundation's parser (`AttributedString(markdown:)` with the full GFM
/// syntax) reports structure only through each run's `presentationIntent`.
/// Runs are grouped by their innermost block; list and quote depths come
/// from the intents that enclose it. Nothing is fetched or interpreted:
/// images keep only their alt text, HTML stays text, and links that fail
/// `ChatLinkPolicy` keep their text but stop being links.
///
/// Parsing is pure and safe off the main actor; callers memoize the result
/// per entry revision.
enum ChatMarkdown {
    /// Larger sources show as one plain paragraph, as written. Parse time
    /// grows with inline markup (a dense 48 KB paragraph took about 0.1 s on
    /// an M-series Mac, and phones are slower).
    static let maximumSourceBytes = 48 * 1_024

    static func blocks(from source: String) -> [ChatMarkdownBlock] {
        if source.allSatisfy(\.isWhitespace) { return [] }
        guard source.utf8.count <= maximumSourceBytes else { return [plainParagraph(source)] }
        let normalized = normalizingLineEndings(source)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible, languageCode: nil,
            appliesSourcePositionAttributes: true)
        guard let parsed = try? AttributedString(markdown: normalized, options: options) else {
            return [plainParagraph(source)]
        }
        var builder = BlockBuilder(
            parsed: parsed, lines: normalized.split(separator: "\n", omittingEmptySubsequences: false))
        return builder.build()
    }

    private static func plainParagraph(_ source: String) -> ChatMarkdownBlock {
        ChatMarkdownBlock(kind: .paragraph, content: AttributedString(source), text: source)
    }

    /// Source positions count lines; splitting on `\n` alone matches them
    /// only once `\r\n` and lone `\r` endings are gone.
    private static func normalizingLineEndings(_ source: String) -> String {
        guard source.utf8.contains(UInt8(ascii: "\r")) else { return source }
        return source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

/// Which links in an assistant message Chat lets the user open.
///
/// Only web links: http or https with a host. Anything else the model wrote
/// would act on the phone rather than take the user to a page: a relative
/// path or `file:` URL means a file on the Host, which the phone cannot
/// open, `heeler:` would drive Heeler itself, and `javascript:`, `mailto:`
/// and `data:` run, compose or render something nobody asked for. Such
/// links keep their text and lose their link.
enum ChatLinkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host(percentEncoded: true), !host.isEmpty else { return false }
        return true
    }
}

/// Turns one parsed message into blocks. A value made per call: the parse,
/// the source lines and the list items whose marker has been placed.
private struct BlockBuilder {
    /// A run of consecutive runs that form one block.
    private struct Group {
        enum Role: Equatable {
            /// A leaf block: paragraph, heading, code block, thematic break.
            case leaf
            case table
            /// A raw HTML block. Each is its own run, since each carries its
            /// own source position.
            case html
        }

        let role: Role
        /// The leaf's or table's identity, or the run's ordinal for HTML.
        let key: Int
        /// The first run's intents, innermost first.
        let chain: [PresentationIntent.IntentType]
        var range: Range<AttributedString.Index>
        /// The source lines the group's positioned runs cover, 1-based.
        var firstLine: Int?
        var lastLine: Int?
    }

    let parsed: AttributedString
    let lines: [Substring]
    private var markedItems: Set<Int> = []

    init(parsed: AttributedString, lines: [Substring]) {
        self.parsed = parsed
        self.lines = lines
    }

    mutating func build() -> [ChatMarkdownBlock] {
        let groups = groups()
        var blocks: [ChatMarkdownBlock] = []
        for (index, group) in groups.enumerated() {
            let marker = placeMarkers(for: group, into: &blocks)
            blocks.append(block(for: group, at: index, in: groups, marker: marker))
        }
        return blocks
    }

    private func groups() -> [Group] {
        var groups: [Group] = []
        for (ordinal, run) in parsed.runs.enumerated() {
            let chain = run.presentationIntent?.components ?? []
            let role: Group.Role
            let key: Int
            if let leaf = chain.first, run.inlinePresentationIntent?.contains(.blockHTML) != true {
                if let table = chain.first(where: Self.isTable) {
                    role = .table
                    key = table.identity
                } else {
                    role = .leaf
                    key = leaf.identity
                }
            } else {
                role = .html
                key = ordinal
            }
            let position = run.markdownSourcePosition
            if let last = groups.last, last.role == role, last.key == key {
                groups[groups.count - 1].range = last.range.lowerBound..<run.range.upperBound
                if let position {
                    groups[groups.count - 1].firstLine = min(last.firstLine ?? position.startLine, position.startLine)
                    groups[groups.count - 1].lastLine = max(last.lastLine ?? position.endLine, position.endLine)
                }
            } else {
                groups.append(
                    Group(
                        role: role, key: key, chain: chain, range: run.range,
                        firstLine: position?.startLine, lastLine: position?.endLine))
            }
        }
        return groups
    }

    /// Places the marker of every list item the group starts. A paragraph
    /// directly inside its item carries the marker itself, which it returns.
    /// Anything else (a code block, a table, a nested list's first item)
    /// gets an empty block with the marker before it, so no item loses its
    /// bullet or number.
    private mutating func placeMarkers(for group: Group, into blocks: inout [ChatMarkdownBlock]) -> String? {
        let chain = group.chain
        let itemPositions = chain.indices.filter { Self.isListItem(chain[$0]) }.reversed()
        var ownMarker: String?
        for (depthIndex, position) in itemPositions.enumerated() {
            let item = chain[position]
            guard markedItems.insert(item.identity).inserted else { continue }
            let depth = depthIndex + 1
            let list = chain.indices.contains(position + 1) ? chain[position + 1] : nil
            let marker = Self.marker(for: item, in: list, depth: depth)
            if group.role == .leaf, position == 1, Self.isParagraph(chain[0]) {
                ownMarker = marker
            } else {
                let outerQuotes = chain[(position + 1)...].filter(Self.isQuote).count
                blocks.append(
                    ChatMarkdownBlock(
                        kind: .listItem(marker: marker), content: AttributedString(), text: marker,
                        listDepth: depth, quoteDepth: outerQuotes))
            }
        }
        return ownMarker
    }

    private func block(for group: Group, at index: Int, in groups: [Group], marker: String?) -> ChatMarkdownBlock {
        let chain = group.chain
        let listDepth = chain.filter(Self.isListItem).count
        let quoteDepth = chain.filter(Self.isQuote).count
        func make(_ kind: ChatMarkdownBlock.Kind, _ text: String) -> ChatMarkdownBlock {
            ChatMarkdownBlock(
                kind: kind, content: AttributedString(text), text: text,
                listDepth: listDepth, quoteDepth: quoteDepth)
        }

        switch group.role {
        case .html:
            return make(.html, Self.droppingFinalNewline(String(parsed[group.range].characters)))
        case .table:
            return make(.table, tableText(for: group, at: index, in: groups, quoteDepth: quoteDepth))
        case .leaf:
            break
        }
        switch chain.first?.kind {
        case .codeBlock(let hint)?:
            let language = hint?.split(whereSeparator: \.isWhitespace).first.map(String.init)
            return make(.code(language: language), Self.droppingFinalNewline(String(parsed[group.range].characters)))
        case .thematicBreak?:
            return make(.thematicBreak, "")
        default:
            let content = inlineContent(group.range)
            let plain = String(content.characters)
            let kind: ChatMarkdownBlock.Kind
            let text: String
            if case .header(let level)? = chain.first?.kind {
                kind = .heading(level: level)
                text = plain
            } else if let marker {
                kind = .listItem(marker: marker)
                text = "\(marker) \(plain)"
            } else {
                kind = .paragraph
                text = plain
            }
            return ChatMarkdownBlock(
                kind: kind, content: content, text: text, listDepth: listDepth, quoteDepth: quoteDepth)
        }
    }

    /// The runs as inline content: block attributes and source positions
    /// removed, images reduced to their alt text, unsafe links reduced to
    /// their text, and breaks spelled as the characters they render as.
    private func inlineContent(_ range: Range<AttributedString.Index>) -> AttributedString {
        var content = AttributedString()
        let slice = parsed[range]
        for run in slice.runs {
            var attributes = run.attributes
            attributes.presentationIntent = nil
            attributes.markdownSourcePosition = nil
            attributes.imageURL = nil
            if let link = attributes.link, !ChatLinkPolicy.allows(link) {
                attributes.link = nil
            }
            var text = String(slice[run.range].characters)
            if var intent = attributes.inlinePresentationIntent {
                // `Text` ignores both break intents and draws the characters,
                // so the characters must be the break.
                if intent.contains(.softBreak) {
                    text = " "
                    intent.remove(.softBreak)
                }
                if intent.contains(.lineBreak) {
                    text = "\n"
                    intent.remove(.lineBreak)
                }
                attributes.inlinePresentationIntent = intent.isEmpty ? nil : intent
            }
            content.append(AttributedString(text, attributes: attributes))
        }
        return content
    }

    /// A table's source lines, with quote markers and the common indent
    /// removed so the table reads as if written on its own.
    ///
    /// Only cells carry source positions, and not all of them reliably: when
    /// a table interrupts a paragraph, the parser reports the paragraph and
    /// the header row on lines that are too low (body rows stay right). The
    /// delimiter row anchors the table instead. It is searched for over the
    /// unbroken lines from the first reported cell, downward and then upward
    /// (a table holds no blank line), and the header row is the line above
    /// it. The end grows from the last reported cell over unbroken lines
    /// (rows of empty cells report nothing) until the next block's start.
    private func tableText(for group: Group, at index: Int, in groups: [Group], quoteDepth: Int) -> String {
        guard let firstCell = group.firstLine, let lastCell = group.lastLine, !lines.isEmpty else {
            return cellText(group.range)
        }
        func content(_ number: Int) -> Substring {
            Self.droppingQuoteMarkers(lines[number - 1], depth: quoteDepth)
        }
        func isBlank(_ number: Int) -> Bool { content(number).allSatisfy(\.isWhitespace) }
        func delimiterRow(from line: Int, step: Int) -> Int? {
            var line = line
            while (1...lines.count).contains(line), !isBlank(line) {
                if Self.isDelimiterRow(content(line)) { return line }
                line += step
            }
            return nil
        }

        let first = min(max(firstCell, 1), lines.count)
        let delimiter = delimiterRow(from: first, step: 1) ?? delimiterRow(from: first - 1, step: -1)
        let start = delimiter.map { max($0 - 1, 1) } ?? first
        var end = min(max(lastCell, delimiter ?? start), lines.count)
        // Positions that go backward are the misreported ones above.
        let nextBlock = groups[(index + 1)...].compactMap(\.firstLine).filter { $0 > end }.min()
        let limit = min(nextBlock.map { $0 - 1 } ?? lines.count, lines.count)
        while end + 1 <= limit, !isBlank(end + 1) { end += 1 }

        var rows = (start...end).map(content)
        while let row = rows.last, row.allSatisfy(\.isWhitespace) { rows.removeLast() }
        while let row = rows.first, row.allSatisfy(\.isWhitespace) { rows.removeFirst() }
        let indent = rows.filter { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return rows.map { $0.dropFirst(indent) }.joined(separator: "\n")
    }

    /// A table without source positions: its cells as text, one row per
    /// line, separated by pipes.
    private func cellText(_ range: Range<AttributedString.Index>) -> String {
        var rows: [[String]] = []
        var rowIdentity: Int?
        var cellIdentity: Int?
        let slice = parsed[range]
        for run in slice.runs {
            let chain = run.presentationIntent?.components ?? []
            let row = chain.first(where: Self.isTableRow)?.identity
            let cell = chain.first(where: Self.isTableCell)?.identity
            let text = String(slice[run.range].characters)
            if rows.isEmpty || row != rowIdentity {
                rows.append([text])
            } else if cell != cellIdentity {
                rows[rows.count - 1].append(text)
            } else {
                rows[rows.count - 1][rows[rows.count - 1].count - 1] += text
            }
            rowIdentity = row
            cellIdentity = cell
        }
        return rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
    }

    private static func marker(
        for item: PresentationIntent.IntentType, in list: PresentationIntent.IntentType?, depth: Int
    ) -> String {
        if case .orderedList? = list?.kind, case .listItem(let ordinal) = item.kind {
            return "\(ordinal)."
        }
        switch depth {
        case 1: return "•"
        case 2: return "◦"
        default: return "▪"
        }
    }

    /// A GFM delimiter row: cells of dashes, optionally colon-aligned,
    /// separated by pipes, such as `| --- | :-: |`.
    private static func isDelimiterRow(_ line: Substring) -> Bool {
        var row = line.trimmingCharacters(in: .whitespaces)[...]
        if row.first == "|" {
            row = row.dropFirst()
        }
        if row.last == "|" {
            row = row.dropLast()
        }
        let cells = row.split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty && cells.allSatisfy { cell in
            var dashes = cell.trimmingCharacters(in: .whitespaces)[...]
            if dashes.first == ":" {
                dashes = dashes.dropFirst()
            }
            if dashes.last == ":" {
                dashes = dashes.dropLast()
            }
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }

    /// Removes up to `depth` block quote markers: up to three spaces, `>`,
    /// and one optional space each.
    private static func droppingQuoteMarkers(_ line: Substring, depth: Int) -> Substring {
        var rest = line
        for _ in 0..<depth {
            let indent = rest.prefix { $0 == " " }.prefix(3).count
            let marked = rest.dropFirst(indent)
            guard marked.first == ">" else { break }
            rest = marked.dropFirst()
            if rest.first == " " {
                rest = rest.dropFirst()
            }
        }
        return rest
    }

    /// Code and HTML blocks end with the newline of their last line, which
    /// would draw as an empty line.
    private static func droppingFinalNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    private static func isListItem(_ component: PresentationIntent.IntentType) -> Bool {
        if case .listItem = component.kind { return true }
        return false
    }

    private static func isQuote(_ component: PresentationIntent.IntentType) -> Bool {
        if case .blockQuote = component.kind { return true }
        return false
    }

    private static func isParagraph(_ component: PresentationIntent.IntentType) -> Bool {
        if case .paragraph = component.kind { return true }
        return false
    }

    private static func isTable(_ component: PresentationIntent.IntentType) -> Bool {
        if case .table = component.kind { return true }
        return false
    }

    private static func isTableRow(_ component: PresentationIntent.IntentType) -> Bool {
        switch component.kind {
        case .tableHeaderRow, .tableRow: return true
        default: return false
        }
    }

    private static func isTableCell(_ component: PresentationIntent.IntentType) -> Bool {
        if case .tableCell = component.kind { return true }
        return false
    }
}
