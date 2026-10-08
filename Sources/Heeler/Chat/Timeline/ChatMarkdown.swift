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
    /// Whether Claude Code's terminal shows a blank line between this block
    /// and the one before (see `ChatMarkdown`); otherwise it starts on the
    /// next line. Always false for the first block.
    let blankLineBefore: Bool

    init(
        kind: Kind, content: AttributedString, text: String, listDepth: Int = 0, quoteDepth: Int = 0,
        blankLineBefore: Bool = false
    ) {
        self.kind = kind
        self.content = content
        self.text = text
        self.listDepth = listDepth
        self.quoteDepth = quoteDepth
        self.blankLineBefore = blankLineBefore
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
/// Lines follow Claude Code's terminal, which keeps the source's: a single
/// line break stays a line break, and blocks are a blank line apart only
/// where the source has one or more blank lines between them. On top of
/// that, a heading is followed by a blank line (in a top-level list, only
/// before the rest of its item and the items after it), and a table or
/// quote at the top level has one around it. A table inside a quote has
/// one below it before the rest of the quote; one in a list item has one
/// below it before the next item and none before the rest of its item.
/// List items stay together unless at least two blank lines part them.
/// Codex's terminal spaces blocks differently in several ways, among them a
/// blank line between every two top-level blocks; Chat follows Claude
/// Code's for every Agent.
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
/// the source lines, and the list items whose marker has been placed with
/// the lists they belong to.
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
    private var markedLists: Set<Int> = []

    init(parsed: AttributedString, lines: [Substring]) {
        self.parsed = parsed
        self.lines = lines
    }

    mutating func build() -> [ChatMarkdownBlock] {
        let groups = groups()
        var blocks: [ChatMarkdownBlock] = []
        for (index, group) in groups.enumerated() {
            // The first block the group adds takes the blank line: a marker
            // placed before it, or its own block.
            var blankLine = index > 0 && startsAfterBlankLine(group, after: groups[index - 1])
            let marker = placeMarkers(for: group, into: &blocks, blankLineBefore: &blankLine)
            blocks.append(block(for: group, at: index, in: groups, marker: marker, blankLineBefore: blankLine))
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
            let covered = run.markdownSourcePosition.map(Self.lines(of:))
            if let last = groups.last, last.role == role, last.key == key {
                groups[groups.count - 1].range = last.range.lowerBound..<run.range.upperBound
                if let covered {
                    groups[groups.count - 1].firstLine = min(last.firstLine ?? covered.lowerBound, covered.lowerBound)
                    groups[groups.count - 1].lastLine = max(last.lastLine ?? covered.upperBound, covered.upperBound)
                }
            } else {
                groups.append(
                    Group(
                        role: role, key: key, chain: chain, range: run.range,
                        firstLine: covered?.lowerBound, lastLine: covered?.upperBound))
            }
        }
        correctLines(in: &groups)
        return groups
    }

    /// The lines a run covers. One that ends at the start of a line, as an
    /// indented code block does on the blank line after it, ends on the
    /// line before.
    private static func lines(of position: AttributedString.MarkdownSourcePosition) -> ClosedRange<Int> {
        let last = position.endColumn == 0 ? position.endLine - 1 : position.endLine
        return position.startLine...max(last, position.startLine)
    }

    /// Corrects the lines the parser reports wrongly or not at all, in
    /// reading order:
    /// - A table that interrupts a paragraph has its header row reported on
    ///   the paragraph's first line, and the paragraph from line 0. The
    ///   table starts above its delimiter row instead, and the paragraph
    ///   runs from there up to the nearest blank line or earlier block.
    /// - A fence left open in a list item runs on to the next block's line.
    ///   The code ends at its last line with text.
    /// - A setext heading's runs leave out its underline.
    /// - Thematic breaks have no position. Each is on the first line before
    ///   the next block that reads as one.
    private func correctLines(in groups: inout [Group]) {
        // The first line reported after each group, which bounds the
        // searches below.
        var nextStart = Array(repeating: lines.count + 1, count: groups.count)
        for index in groups.indices.dropLast().reversed() {
            let next = groups[index + 1].firstLine.flatMap { $0 >= 1 ? $0 : nil } ?? nextStart[index + 1]
            nextStart[index] = min(nextStart[index + 1], next)
        }
        var reached = 0
        var scanned = 0
        var interrupted: Int?
        for index in groups.indices {
            if let first = groups[index].firstLine, first < 1 {
                groups[index].firstLine = nil
                groups[index].lastLine = nil
                interrupted = index
            }
            let depth = groups[index].chain.filter(Self.isQuote).count
            switch (groups[index].role, groups[index].chain.first?.kind) {
            case (.table, _):
                guard let firstCell = groups[index].firstLine,
                    let delimiter = delimiterRow(near: firstCell, quoteDepth: depth)
                else { break }
                let header = max(delimiter - 1, 1)
                groups[index].firstLine = header
                groups[index].lastLine = max(groups[index].lastLine ?? delimiter, delimiter)
                if interrupted == index - 1, header - 1 > reached {
                    var first = header - 1
                    while first - 1 > reached, !isBlankLine(first - 1, quoteDepth: depth) {
                        first -= 1
                    }
                    groups[index - 1].firstLine = first
                    groups[index - 1].lastLine = header - 1
                }
            case (.leaf, .codeBlock?):
                guard let first = groups[index].firstLine, var last = groups[index].lastLine else { break }
                last = min(last, nextStart[index] - 1)
                while last > first, isBlankLine(last, quoteDepth: depth) {
                    last -= 1
                }
                groups[index].lastLine = max(last, first)
            case (.leaf, .header?):
                if let last = groups[index].lastLine, last < lines.count, isUnderlinedHeading(groups[index]) {
                    groups[index].lastLine = last + 1
                }
            case (.leaf, .thematicBreak?) where groups[index].firstLine == nil:
                // Lines already searched are skipped, so the searches
                // together stay linear.
                let start = max(reached, scanned)
                let end = min(nextStart[index] - 1, lines.count)
                if start < end, let found = (start..<end).first(where: { Self.readsAsThematicBreak(lines[$0]) }) {
                    groups[index].firstLine = found + 1
                    groups[index].lastLine = found + 1
                    scanned = found + 1
                } else {
                    scanned = max(scanned, end)
                }
            default:
                break
            }
            reached = max(reached, groups[index].lastLine ?? reached)
        }
    }

    /// The delimiter row of a table whose first reported cell is on `line`.
    ///
    /// Only cells carry source positions, and the header row's are wrong
    /// when the table interrupts a paragraph (body rows stay right). The
    /// delimiter row is searched for over the unbroken lines from there,
    /// downward and then upward, since a table holds no blank line.
    private func delimiterRow(near line: Int, quoteDepth: Int) -> Int? {
        guard !lines.isEmpty else { return nil }
        func search(from line: Int, step: Int) -> Int? {
            var line = line
            while (1...lines.count).contains(line), !isBlankLine(line, quoteDepth: quoteDepth) {
                if Self.isDelimiterRow(Self.droppingQuoteMarkers(lines[line - 1], depth: quoteDepth)) {
                    return line
                }
                line += step
            }
            return nil
        }
        let first = min(max(line, 1), lines.count)
        return search(from: first, step: 1) ?? search(from: first - 1, step: -1)
    }

    /// Whether a heading is set with an underline (`Title` over `---`)
    /// rather than `#` marks: no `#` comes before its text on its line.
    private func isUnderlinedHeading(_ group: Group) -> Bool {
        guard let start = parsed[group.range].runs.lazy.compactMap({ $0.markdownSourcePosition }).first,
            lines.indices.contains(start.startLine - 1)
        else { return false }
        let before = lines[start.startLine - 1].utf8.prefix(max(start.startColumn - 1, 0))
        return !before.contains(UInt8(ascii: "#"))
    }

    /// Whether the terminal shows a blank line between the group and the
    /// one before it. See `ChatMarkdown` for the rules.
    private func startsAfterBlankLine(_ group: Group, after previous: Group) -> Bool {
        let laterItem = startsLaterItem(group)
        if previous.role == .leaf, case .header? = previous.chain.first?.kind,
            Self.keepsBlankLineAfterHeading(previous, before: group, laterItem: laterItem)
        {
            return true
        }
        if Self.isTopLevelTable(group) || Self.isTopLevelTable(previous)
            || Self.isInTopLevelQuote(group) != Self.isInTopLevelQuote(previous)
        {
            return true
        }
        if previous.role == .table, let decided = Self.blankLineAfterTable(previous, before: group, laterItem: laterItem) {
            return decided
        }
        guard let last = previous.lastLine, let first = group.firstLine else { return !laterItem }
        let depth = max(group.chain.filter(Self.isQuote).count, previous.chain.filter(Self.isQuote).count)
        let blankLines = first > last + 1 ? ((last + 1)..<first).filter { isBlankLine($0, quoteDepth: depth) }.count : 0
        return blankLines >= (laterItem ? 2 : 1)
    }

    /// Whether the terminal keeps the blank line after a heading before the
    /// group. Its text keeps it everywhere but in a top-level list, which it
    /// lays out item by item: there the blank line reaches only the rest of
    /// the heading's item (or of its quote, for a heading in a quote in the
    /// item) and the items after it.
    private static func keepsBlankLineAfterHeading(_ heading: Group, before group: Group, laterItem: Bool) -> Bool {
        guard let outermost = heading.chain.last, isList(outermost),
            let item = heading.chain.firstIndex(where: isListItem)
        else { return true }
        if let quote = heading.chain[..<item].last(where: isQuote) {
            return group.chain.contains { $0.identity == quote.identity }
        }
        return laterItem || group.chain.contains { $0.identity == heading.chain[item].identity }
    }

    private static func isTopLevelTable(_ group: Group) -> Bool {
        group.role == .table && group.chain.last.map(isTable) == true
    }

    /// Whether the group is in a quote outside every list.
    private static func isInTopLevelQuote(_ group: Group) -> Bool {
        group.chain.last.map(isQuote) ?? false
    }

    /// Whether the terminal shows a blank line between a table inside a
    /// list or quote and the group, where the source does not decide: one
    /// before the rest of the table's quote, one before the next item after
    /// an item the table ends, and none before the rest of that item (the
    /// terminal's parser takes any blank lines there into the table).
    private static func blankLineAfterTable(_ table: Group, before group: Group, laterItem: Bool) -> Bool? {
        guard let position = table.chain.firstIndex(where: isTable) else { return nil }
        let containers = table.chain[(position + 1)...]
        if let quote = containers.first(where: isQuote) {
            return group.chain.contains { $0.identity == quote.identity } ? true : nil
        }
        guard let item = containers.first, isListItem(item) else { return nil }
        if laterItem {
            return true
        }
        return group.chain.contains { $0.identity == item.identity } ? false : nil
    }

    /// Whether the group starts an item that follows another item of its
    /// list, rather than a list's first item or more of an item. The
    /// outermost item it starts decides; any inside that one start nested
    /// lists.
    private func startsLaterItem(_ group: Group) -> Bool {
        let chain = group.chain
        guard
            let position = chain.indices.last(where: { index in
                Self.isListItem(chain[index]) && !markedItems.contains(chain[index].identity)
            }),
            chain.indices.contains(position + 1)
        else { return false }
        return markedLists.contains(chain[position + 1].identity)
    }

    /// Whether a source line, numbered from 1, is blank once `quoteDepth`
    /// quote markers are removed.
    private func isBlankLine(_ number: Int, quoteDepth: Int) -> Bool {
        guard lines.indices.contains(number - 1) else { return false }
        return Self.droppingQuoteMarkers(lines[number - 1], depth: quoteDepth).allSatisfy(\.isWhitespace)
    }

    /// Places the marker of every list item the group starts. A paragraph
    /// directly inside its item carries the marker itself, which it returns.
    /// Anything else (a code block, a table, a nested list's first item)
    /// gets an empty block with the marker before it, so no item loses its
    /// bullet or number. The first marker block placed takes the group's
    /// blank line.
    private mutating func placeMarkers(
        for group: Group, into blocks: inout [ChatMarkdownBlock], blankLineBefore: inout Bool
    ) -> String? {
        let chain = group.chain
        let itemPositions = chain.indices.filter { Self.isListItem(chain[$0]) }.reversed()
        var ownMarker: String?
        for (depthIndex, position) in itemPositions.enumerated() {
            let item = chain[position]
            guard markedItems.insert(item.identity).inserted else { continue }
            let depth = depthIndex + 1
            let list = chain.indices.contains(position + 1) ? chain[position + 1] : nil
            if let list {
                markedLists.insert(list.identity)
            }
            let marker = Self.marker(for: item, in: list, depth: depth)
            if group.role == .leaf, position == 1, Self.isParagraph(chain[0]) {
                ownMarker = marker
            } else {
                let outerQuotes = chain[(position + 1)...].filter(Self.isQuote).count
                blocks.append(
                    ChatMarkdownBlock(
                        kind: .listItem(marker: marker), content: AttributedString(), text: marker,
                        listDepth: depth, quoteDepth: outerQuotes, blankLineBefore: blankLineBefore))
                blankLineBefore = false
            }
        }
        return ownMarker
    }

    private func block(
        for group: Group, at index: Int, in groups: [Group], marker: String?, blankLineBefore: Bool
    ) -> ChatMarkdownBlock {
        let chain = group.chain
        let listDepth = chain.filter(Self.isListItem).count
        let quoteDepth = chain.filter(Self.isQuote).count
        func make(_ kind: ChatMarkdownBlock.Kind, _ text: String) -> ChatMarkdownBlock {
            ChatMarkdownBlock(
                kind: kind, content: AttributedString(text), text: text,
                listDepth: listDepth, quoteDepth: quoteDepth, blankLineBefore: blankLineBefore)
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
                kind: kind, content: content, text: text, listDepth: listDepth, quoteDepth: quoteDepth,
                blankLineBefore: blankLineBefore)
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
                // so the characters must be the break. A soft break breaks
                // the line too, as in both programs' terminals; a space would
                // also wrongly part two Chinese sentences.
                if !intent.isDisjoint(with: [.softBreak, .lineBreak]) {
                    text = "\n"
                    intent.subtract([.softBreak, .lineBreak])
                }
                attributes.inlinePresentationIntent = intent.isEmpty ? nil : intent
            }
            content.append(AttributedString(text, attributes: attributes))
        }
        return content
    }

    /// A table's source lines, with quote markers and the common indent
    /// removed so the table reads as if written on its own. It starts at
    /// its header row (see `correctLines`), and its end grows from the last
    /// reported row over unbroken lines (rows of empty cells report nothing)
    /// until the next block's start.
    private func tableText(for group: Group, at index: Int, in groups: [Group], quoteDepth: Int) -> String {
        guard let firstLine = group.firstLine, let lastLine = group.lastLine, !lines.isEmpty else {
            return cellText(group.range)
        }
        func content(_ number: Int) -> Substring {
            Self.droppingQuoteMarkers(lines[number - 1], depth: quoteDepth)
        }

        let start = min(max(firstLine, 1), lines.count)
        var end = min(max(lastLine, start), lines.count)
        let nextBlock = groups[(index + 1)...].compactMap(\.firstLine).filter { $0 > end }.min()
        let limit = min(nextBlock.map { $0 - 1 } ?? lines.count, lines.count)
        while end + 1 <= limit, !isBlankLine(end + 1, quoteDepth: quoteDepth) { end += 1 }

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

    /// A thematic break's line: three or more of one of `-`, `*` and `_`,
    /// with nothing else but spaces and tabs.
    private static func isThematicBreak(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == mark }
    }

    /// Whether a line is a thematic break once any quote and list markers
    /// before it are removed, as in `> ***` or `- ***`.
    private static func readsAsThematicBreak(_ line: Substring) -> Bool {
        var rest = line
        while !isThematicBreak(rest) {
            let marked = rest.drop { $0 == " " || $0 == "\t" }
            if marked.first == ">" {
                rest = marked.dropFirst()
            } else if let marker = listMarkerLength(marked) {
                rest = marked.dropFirst(marker)
            } else {
                return false
            }
        }
        return true
    }

    /// The length of the list item marker the text starts with: `-`, `*`
    /// or `+`, or up to nine digits and `.` or `)`, then a space, a tab or
    /// the end of the line.
    private static func listMarkerLength(_ text: Substring) -> Int? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }.count
        let length: Int
        if digits > 0 {
            guard digits <= 9, let delimiter = text.dropFirst(digits).first, delimiter == "." || delimiter == ")"
            else { return nil }
            length = digits + 1
        } else {
            guard let bullet = text.first, "-*+".contains(bullet) else { return nil }
            length = 1
        }
        let after = text.dropFirst(length).first
        return after == nil || after == " " || after == "\t" ? length : nil
    }

    /// Removes up to `depth` block quote markers: any indent (in a list item,
    /// the item's content is indented), `>`, and one optional space each.
    private static func droppingQuoteMarkers(_ line: Substring, depth: Int) -> Substring {
        var rest = line
        for _ in 0..<depth {
            let marked = rest.drop { $0 == " " || $0 == "\t" }
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

    private static func isList(_ component: PresentationIntent.IntentType) -> Bool {
        switch component.kind {
        case .orderedList, .unorderedList: return true
        default: return false
        }
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
