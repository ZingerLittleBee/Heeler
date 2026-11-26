import Foundation

/// A description as the detail lays it out (ADR 0065): Chat's Markdown
/// blocks, each picture and video GitHub shows where the Markdown puts it,
/// and the HTML GitHub renders as its text rather than its tags.
///
/// Each picture and video the Markdown writes (`![alt](address)`, `<img>`,
/// `<video>`, or an uploaded video's address on a line of its own) becomes a
/// placeholder before Chat's parser runs, so it stays where it was written
/// whatever block holds it. Each placeholder GitHub would show is then
/// matched to a picture or video of the rendered HTML by its upload id or
/// address, and the rest in order when as many are left on each side. One
/// in code goes back to what was written; one with no match shows its alt
/// text, as before.
enum GitHubBody {
    /// A picture or video where the description has one.
    struct Item: Sendable, Equatable, Identifiable {
        /// Its place among what the description writes.
        let id: Int
        let media: GitHubMedia
        /// What the author wrote for it; empty when nothing.
        let alt: String
        /// The web link it sits in.
        let link: URL?

        /// What it is called: its alt text, or what it is.
        var name: String {
            if !alt.isEmpty { return alt }
            switch media.kind {
            case .image: return String(localized: "Image")
            case .video: return String(localized: "Video")
            }
        }
    }

    /// Pictures and videos on lines of their own: side by side while they
    /// fit, as GitHub lays out images.
    struct MediaGroup: Sendable, Equatable {
        let items: [Item]
        let listDepth: Int
        let quoteDepth: Int
    }

    /// A table some of whose cells hold pictures or videos.
    struct MediaTable: Sendable, Equatable {
        struct Cell: Sendable, Equatable {
            let text: AttributedString
            let items: [Item]
        }

        let columns: [ChatMarkdownBlock.Table.Alignment]
        /// The header row first.
        let rows: [[Cell]]
        let listDepth: Int
        let quoteDepth: Int
    }

    enum Element: Sendable, Equatable {
        case block(ChatMarkdownBlock)
        case media(MediaGroup, blankLineBefore: Bool)
        case table(MediaTable, blankLineBefore: Bool)
    }

    struct Layout: Sendable, Equatable {
        let elements: [Element]
        /// The pictures and videos text links to, by the path its link
        /// carries (`ChatImageLink.PathAttribute`).
        let linkedItems: [String: Item]
    }

    static func layout(markdown: String, media: [GitHubMedia]) -> Layout {
        let visible = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let videoKeys = Set(media.filter { $0.kind == .video }.flatMap(\.keys))
        let (source, references) = Placeholders.replacing(in: visible, videoKeys: videoKeys)
        let blocks = Self.blocks(of: source)
        var builder = Builder(references: references)
        builder.matches = Builder.match(builder.shownPlaceholders(in: blocks), references: references, media: media)
        for block in blocks {
            builder.add(block)
        }
        return Layout(elements: builder.elements, linkedItems: builder.linkedItems)
    }

    /// Chat's blocks for the Markdown. Chat shows a source larger than its
    /// parser takes as one plain paragraph, and a description can be 64 KB
    /// (Renovate's release notes often are), so a larger one parses in
    /// sections, each ending at a blank line outside a code fence.
    static func blocks(of source: String) -> [ChatMarkdownBlock] {
        let limit = ChatMarkdown.maximumSourceBytes
        guard source.utf8.count > limit else { return ChatMarkdown.blocks(from: source) }
        var blocks: [ChatMarkdownBlock] = []
        for section in sections(of: source, limit: limit) {
            var parsed = ChatMarkdown.blocks(from: section)
            if !blocks.isEmpty, let first = parsed.first {
                parsed[0] = ChatMarkdownBlock(
                    kind: first.kind, content: first.content, text: first.text, listDepth: first.listDepth,
                    quoteDepth: first.quoteDepth, blankLineBefore: true, table: first.table)
            }
            blocks += parsed
        }
        return blocks
    }

    /// The source in parts of at most `limit` bytes where it can be: each
    /// ends at the last blank line before the limit outside a code fence,
    /// preferably one a line at the left margin follows, so a list or
    /// quote stays whole.
    static func sections(of source: String, limit: Int) -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var sections: [String] = []
        var start = 0
        var bytes = 0
        var fence: Substring?
        var anyBreak: Int?
        var marginBreak: Int?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let size = line.utf8.count + 1
            if bytes + size > limit, index > start {
                let end = marginBreak ?? anyBreak ?? index
                sections.append(lines[start..<end].joined(separator: "\n"))
                start = end
                index = end
                bytes = 0
                fence = nil
                anyBreak = nil
                marginBreak = nil
                continue
            }
            bytes += size
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.dropFirst(open.count).allSatisfy({ $0 == open.first || $0.isWhitespace }) {
                    fence = nil
                }
            } else if let marker = trimmed.prefixMatch(of: /```+|~~~+/) {
                fence = marker.output
            } else if trimmed.isEmpty, index > start {
                anyBreak = index
                if index + 1 < lines.count, let next = lines[index + 1].first, next != " ", next != "\t" {
                    marginBreak = index
                }
            }
            index += 1
        }
        if start < lines.count { sections.append(lines[start...].joined(separator: "\n")) }
        return sections
    }

    /// The path a link to an item carries. Its extension says which symbol
    /// the link shows (`ChatImageLink.mediaKind(for:)`).
    static func linkPath(for item: Item) -> String {
        "github-media/\(item.id).\(item.media.kind == .video ? "mp4" : "png")"
    }

    /// The text of an HTML block as a browser shows it: tags gone, a line
    /// for each block element and break, white space collapsed.
    static func htmlText(_ html: String) -> String {
        let blockTags =
            /<\/?(?:p|div|h[1-6]|li|ul|ol|dl|dt|dd|tr|table|thead|tbody|tfoot|caption|details|summary|blockquote|pre|section|figure|figcaption|center|hr)\b[^>]*>/
            .ignoresCase()
        let text = html.replacingOccurrences(of: "\n", with: " ")
            .replacing(/<br\s*\/?>/.ignoresCase(), with: "\n")
            .replacing(blockTags, with: "\n")
            .replacing(/<\/?t[dh]\b[^>]*>/.ignoresCase(), with: " ")
            .replacing(/<[^>]*>/, with: "")
        return GitHubMedia.htmlUnescaped(text)
            .split(separator: "\n")
            .map { $0.replacing(/[ \t]+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Placeholders

extension GitHubBody {
    /// What the Markdown wrote for one picture or video.
    struct Reference: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case image
            case video
        }

        let kind: Kind
        /// The text it replaced.
        let original: String
        let alt: String
        let keys: [String]
    }

    /// Placeholders: a private-use character pair around the reference's
    /// number, which Chat's parser leaves as text.
    enum Placeholders {
        static func text(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

        /// Each placeholder in `text`, in order.
        static func find(in text: Substring) -> [(range: Range<String.Index>, index: Int)] {
            guard text.contains("\u{E000}") else { return [] }
            return text.matches(of: /\u{E000}([0-9]+)\u{E001}/).compactMap { match in
                Int(match.output.1).map { (match.range, $0) }
            }
        }

        /// The Markdown with each picture and video it writes replaced by a
        /// placeholder, and what each replaced. A line that is only an
        /// address is a video's when the HTML shows a video there.
        /// Whether a backslash escapes the character at `index`, which
        /// Markdown then shows as written.
        static func isEscaped(_ index: String.Index, in text: String) -> Bool {
            text[..<index].reversed().prefix { $0 == "\\" }.count % 2 == 1
        }

        static func replacing(in markdown: String, videoKeys: Set<String>) -> (String, [Reference]) {
            var found: [(range: Range<String.Index>, reference: Reference)] = []
            // A tag can wrap onto the quote's next lines, whose `>` markers
            // the parser takes off before it reads the tag.
            let tag = /<img\b(?:[^>\n]|\n[ \t]*(?:(?:>[ \t]?)+(?=[^\n>]))?)*>/.ignoresCase()
            for match in markdown.matches(of: tag) where !isEscaped(match.range.lowerBound, in: markdown) {
                let unquoted = String(match.output).replacing(/\n[ \t]*(?:>[ \t]?)*/, with: "\n")
                let attributes = GitHubMedia.attributes(in: unquoted)
                let alt = (attributes["alt"] ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                found.append((match.range, Reference(
                    kind: .image, original: String(match.output), alt: alt,
                    keys: attributes["src"].map(GitHubMedia.keys(written:)) ?? [])))
            }
            for match in markdown.matches(of: /<video\b[^>]*?(?:\/>|>(?:[\s\S]*?<\/video>)?)/.ignoresCase())
            where !isEscaped(match.range.lowerBound, in: markdown) {
                let attributes = GitHubMedia.attributes(in: String(match.output))
                found.append((match.range, Reference(
                    kind: .video, original: String(match.output), alt: "",
                    keys: attributes["src"].map(GitHubMedia.keys(written:)) ?? [])))
            }
            let image =
                /!\[((?:\\.|[^\\\[\]]|\[(?:\\.|[^\\\[\]])*\])*)\]\(\s*(<[^<>\n]*>|(?:[^\s()\\]|\\.|\((?:[^\s()\\]|\\.)*\))+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^()\n]*\)))?\s*\)/
            for match in markdown.matches(of: image) where !isEscaped(match.range.lowerBound, in: markdown) {
                let alt = String(match.output.1).replacing(/\\(.)/) { String($0.output.1) }
                found.append((match.range, Reference(
                    kind: .image, original: String(match.output.0), alt: alt,
                    keys: GitHubMedia.keys(written: String(match.output.2)))))
            }
            if !videoKeys.isEmpty {
                // Bare or in angle brackets, as an autolink.
                let line = /^[ \t]*(?:>[ \t]*)*(?:(?:[-*+]|[0-9]{1,9}[.)])[ \t]+)?(<https?:\/\/[^\s<>]+>|https?:\/\/[^\s<>]+)[ \t]*$/
                for match in markdown.matches(of: line.anchorsMatchLineEndings()) {
                    let address = match.output.1
                    let written = address.hasPrefix("<") ? address.dropFirst().dropLast() : address
                    let keys = GitHubMedia.keys(written: String(written))
                    guard keys.contains(where: videoKeys.contains) else { continue }
                    found.append((address.startIndex..<address.endIndex, Reference(
                        kind: .video, original: String(address), alt: "", keys: keys)))
                }
            }
            found.sort { lhs, rhs in
                lhs.range.lowerBound != rhs.range.lowerBound
                    ? lhs.range.lowerBound < rhs.range.lowerBound
                    : lhs.range.upperBound > rhs.range.upperBound
            }
            var result = ""
            var references: [Reference] = []
            var cursor = markdown.startIndex
            for entry in found where entry.range.lowerBound >= cursor {
                result += markdown[cursor..<entry.range.lowerBound]
                result += text(references.count)
                references.append(entry.reference)
                cursor = entry.range.upperBound
            }
            result += markdown[cursor...]
            return (result, references)
        }
    }
}

// MARK: - Building

extension GitHubBody {
    fileprivate struct Builder {
        let references: [Reference]
        var matches: [Int: GitHubMedia] = [:]
        private(set) var elements: [Element] = []
        private(set) var linkedItems: [String: Item] = [:]

        init(references: [Reference]) {
            self.references = references
        }

        /// The placeholders GitHub shows as pictures or videos, in reading
        /// order: none in code.
        func shownPlaceholders(in blocks: [ChatMarkdownBlock]) -> [Int] {
            var shown: [Int] = []
            for block in blocks {
                switch block.kind {
                case .code, .thematicBreak:
                    continue
                case .html:
                    shown += Placeholders.find(in: block.text[...]).map(\.index)
                case .table:
                    for cell in (block.table?.rows ?? []).joined() {
                        shown += Self.prosePlaceholders(in: cell)
                    }
                case .paragraph, .heading, .listItem:
                    shown += Self.prosePlaceholders(in: block.content)
                }
            }
            return shown
        }

        private static func prosePlaceholders(in content: AttributedString) -> [Int] {
            content.runs.flatMap { run -> [Int] in
                guard !isCode(run), !isHTML(run) else { return [] }
                return Placeholders.find(in: String(content[run.range].characters)[...]).map(\.index)
            }
        }

        /// The picture or video GitHub shows for each placeholder: the first
        /// unused one with a key in common, then, when as many images are
        /// left on each side, the rest in order (an address GitHub rewrote,
        /// such as a path in the repository).
        static func match(_ shown: [Int], references: [Reference], media: [GitHubMedia]) -> [Int: GitHubMedia] {
            var matches: [Int: GitHubMedia] = [:]
            var used: Set<Int> = []
            for index in shown where references.indices.contains(index) {
                let keys = Set(references[index].keys)
                guard !keys.isEmpty,
                    let found = media.indices.first(where: { !used.contains($0) && !keys.isDisjoint(with: media[$0].keys) })
                else { continue }
                used.insert(found)
                matches[index] = media[found]
            }
            let referencesLeft = shown.filter {
                references.indices.contains($0) && matches[$0] == nil && references[$0].kind == .image
            }
            let mediaLeft = media.indices.filter { !used.contains($0) && media[$0].kind == .image }
            if referencesLeft.count == mediaLeft.count {
                for (reference, found) in zip(referencesLeft, mediaLeft) {
                    matches[reference] = media[found]
                }
            }
            return matches
        }

        mutating func add(_ block: ChatMarkdownBlock) {
            switch block.kind {
            case .code(let language):
                let text = restoring(block.text)
                elements.append(.block(ChatMarkdownBlock(
                    kind: .code(language: language), content: AttributedString(text), text: text,
                    listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: block.blankLineBefore)))
            case .thematicBreak:
                elements.append(.block(block))
            case .table:
                addTable(block)
            case .html:
                addHTML(block)
            case .paragraph, .heading, .listItem:
                addProse(block)
            }
        }

        // MARK: Prose

        /// A paragraph, heading or list item: its lines that hold only
        /// pictures and videos become a group, the rest stays text.
        private mutating func addProse(_ block: ChatMarkdownBlock) {
            let lines = Self.lines(of: prose(block.content))
            var groups: [(isMedia: Bool, lines: [AttributedString])] = []
            for line in lines {
                let isMedia = isMediaLine(line)
                if let last = groups.last, last.isMedia == isMedia {
                    groups[groups.count - 1].lines.append(line)
                } else {
                    groups.append((isMedia, [line]))
                }
            }
            let emittedBefore = elements.count
            var blankLineBefore = block.blankLineBefore
            var markerPlaced = false
            for group in groups {
                if group.isMedia {
                    if case .listItem(let marker) = block.kind, !markerPlaced {
                        // The item's marker, before its first line's media.
                        elements.append(.block(ChatMarkdownBlock(
                            kind: .listItem(marker: marker), content: AttributedString(), text: marker,
                            listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: blankLineBefore)))
                        markerPlaced = true
                        blankLineBefore = false
                    }
                    let shown = group.lines.flatMap { items(in: $0) }
                    elements.append(.media(
                        MediaGroup(items: shown, listDepth: block.listDepth, quoteDepth: block.quoteDepth),
                        blankLineBefore: blankLineBefore))
                } else {
                    let trimmed = Self.trimmingBlankLines(group.lines)
                    guard !trimmed.isEmpty else { continue }
                    var content = AttributedString()
                    for (index, line) in trimmed.enumerated() {
                        if index > 0 { content.append(AttributedString("\n")) }
                        content.append(inline(line))
                    }
                    let plain = String(content.characters)
                    let kind: ChatMarkdownBlock.Kind
                    let text: String
                    if case .listItem(let marker) = block.kind, !markerPlaced {
                        kind = .listItem(marker: marker)
                        text = "\(marker) \(plain)"
                        markerPlaced = true
                    } else if case .listItem = block.kind {
                        kind = .paragraph
                        text = plain
                    } else {
                        kind = block.kind
                        text = plain
                    }
                    elements.append(.block(ChatMarkdownBlock(
                        kind: kind, content: content, text: text,
                        listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: blankLineBefore)))
                }
                blankLineBefore = false
            }
            // An item with nothing left to show keeps its marker.
            if elements.count == emittedBefore, case .listItem(let marker) = block.kind {
                elements.append(.block(ChatMarkdownBlock(
                    kind: .listItem(marker: marker), content: AttributedString(), text: marker,
                    listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: block.blankLineBefore)))
            }
        }

        /// Inline content as GitHub shows it: code as written, inline HTML
        /// as the break it is or nothing, and no Host image paths, which
        /// name files on the author's machine.
        private func prose(_ content: AttributedString) -> AttributedString {
            var result = AttributedString()
            for run in content.runs {
                var attributes = run.attributes
                attributes[ChatImageLink.PathAttribute.self] = nil
                attributes[ChatImageLink.TitleAttribute.self] = nil
                let text = String(content[run.range].characters)
                if Self.isHTML(run) {
                    guard text.wholeMatch(of: /<br\s*\/?>/.ignoresCase()) != nil else { continue }
                    var intent = attributes.inlinePresentationIntent ?? []
                    intent.remove(.inlineHTML)
                    attributes.inlinePresentationIntent = intent.isEmpty ? nil : intent
                    result.append(AttributedString("\n", attributes: attributes))
                } else if Self.isCode(run) {
                    result.append(AttributedString(restoring(text), attributes: attributes))
                } else {
                    result.append(AttributedString(text, attributes: attributes))
                }
            }
            return result
        }

        /// Whether a line holds pictures or videos GitHub shows, and
        /// nothing else but space.
        private func isMediaLine(_ line: AttributedString) -> Bool {
            let text = String(line.characters)
            let found = Placeholders.find(in: text[...])
            guard !found.isEmpty, found.allSatisfy({ matches[$0.index] != nil }) else { return false }
            var rest = text
            for placeholder in found.reversed() {
                rest.removeSubrange(placeholder.range)
            }
            return rest.allSatisfy(\.isWhitespace)
        }

        /// The items a line or cell shows, each with the web link it sits in.
        private func items(in content: AttributedString) -> [Item] {
            content.runs.flatMap { run -> [Item] in
                Placeholders.find(in: String(content[run.range].characters)[...]).compactMap { found in
                    item(found.index, link: run.link)
                }
            }
        }

        private func item(_ index: Int, link: URL?) -> Item? {
            guard let media = matches[index], references.indices.contains(index) else { return nil }
            return Item(id: index, media: media, alt: references[index].alt, link: link.flatMap { ChatLinkPolicy.allows($0) ? $0 : nil })
        }

        /// Text with each placeholder as what it shows: a link that opens
        /// the picture or video, or its alt text when GitHub shows none.
        private mutating func inline(_ content: AttributedString) -> AttributedString {
            guard String(content.characters).contains("\u{E000}") else { return content }
            var result = AttributedString()
            for run in content.runs {
                let text = String(content[run.range].characters)
                var cursor = text.startIndex
                for found in Placeholders.find(in: text[...]) {
                    result.append(AttributedString(String(text[cursor..<found.range.lowerBound]), attributes: run.attributes))
                    cursor = found.range.upperBound
                    if let item = item(found.index, link: run.link) {
                        var attributes = run.attributes
                        attributes.link = nil
                        var piece = AttributedString(item.name, attributes: attributes)
                        let path = GitHubBody.linkPath(for: item)
                        piece[ChatImageLink.PathAttribute.self] = path
                        piece[ChatImageLink.TitleAttribute.self] = item.name
                        linkedItems[path] = item
                        result.append(piece)
                    } else {
                        result.append(AttributedString(altText(found.index), attributes: run.attributes))
                    }
                }
                result.append(AttributedString(String(text[cursor...]), attributes: run.attributes))
            }
            return result
        }

        // MARK: Tables

        private mutating func addTable(_ block: ChatMarkdownBlock) {
            let source = restoring(block.text)
            guard let table = block.table else {
                elements.append(.block(ChatMarkdownBlock(
                    kind: .table, content: AttributedString(source), text: source,
                    listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: block.blankLineBefore)))
                return
            }
            let cells = table.rows.map { $0.map(prose) }
            let hasMedia = cells.joined().contains { !items(in: $0).isEmpty }
            guard hasMedia else {
                var rows: [[AttributedString]] = []
                for row in cells {
                    var resolved: [AttributedString] = []
                    for cell in row { resolved.append(inline(cell)) }
                    rows.append(resolved)
                }
                elements.append(.block(ChatMarkdownBlock(
                    kind: .table, content: AttributedString(source), text: source,
                    listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: block.blankLineBefore,
                    table: ChatMarkdownBlock.Table(columns: table.columns, rows: rows))))
                return
            }
            var rows: [[MediaTable.Cell]] = []
            for row in cells {
                var resolved: [MediaTable.Cell] = []
                for cell in row {
                    let items = items(in: cell)
                    var text = inline(removingShown(cell))
                    Self.trimWhitespace(&text)
                    resolved.append(MediaTable.Cell(text: text, items: items))
                }
                rows.append(resolved)
            }
            elements.append(.table(
                MediaTable(columns: table.columns, rows: rows, listDepth: block.listDepth, quoteDepth: block.quoteDepth),
                blankLineBefore: block.blankLineBefore))
        }

        /// The content without the placeholders GitHub shows as pictures or
        /// videos, which the cell shows under its text.
        private func removingShown(_ content: AttributedString) -> AttributedString {
            var result = AttributedString()
            for run in content.runs {
                var text = String(content[run.range].characters)
                for found in Placeholders.find(in: text[...]).reversed() where matches[found.index] != nil {
                    text.removeSubrange(found.range)
                }
                result.append(AttributedString(text, attributes: run.attributes))
            }
            return result
        }

        // MARK: HTML

        /// An HTML block: its pictures and videos as groups, its text
        /// between them as a browser shows it.
        private mutating func addHTML(_ block: ChatMarkdownBlock) {
            let text = block.text
            var blankLineBefore = block.blankLineBefore
            var pending = ""
            var group: [Item] = []
            func flushGroup(_ elements: inout [Element]) {
                guard !group.isEmpty else { return }
                elements.append(.media(
                    MediaGroup(items: group, listDepth: block.listDepth, quoteDepth: block.quoteDepth),
                    blankLineBefore: blankLineBefore))
                group = []
                blankLineBefore = false
            }
            func flushText(_ elements: inout [Element]) {
                let shown = GitHubBody.htmlText(pending)
                pending = ""
                guard !shown.isEmpty else { return }
                elements.append(.block(ChatMarkdownBlock(
                    kind: .paragraph, content: AttributedString(shown), text: shown,
                    listDepth: block.listDepth, quoteDepth: block.quoteDepth, blankLineBefore: blankLineBefore)))
                blankLineBefore = false
            }
            var cursor = text.startIndex
            for found in Placeholders.find(in: text[...]) {
                pending += text[cursor..<found.range.lowerBound]
                cursor = found.range.upperBound
                guard let item = item(found.index, link: nil) else {
                    pending += altText(found.index)
                    continue
                }
                if !GitHubBody.htmlText(pending).isEmpty {
                    flushGroup(&elements)
                    flushText(&elements)
                }
                pending = ""
                group.append(item)
            }
            pending += text[cursor...]
            flushGroup(&elements)
            flushText(&elements)
        }

        // MARK: Text

        /// The text with each placeholder back as what was written.
        private func restoring(_ text: String) -> String {
            var result = text
            for found in Placeholders.find(in: text[...]).reversed() where references.indices.contains(found.index) {
                result.replaceSubrange(found.range, with: references[found.index].original)
            }
            return result
        }

        /// What a picture or video GitHub does not show reads as.
        private func altText(_ index: Int) -> String {
            guard references.indices.contains(index) else { return "" }
            let reference = references[index]
            switch reference.kind {
            case .image: return reference.alt.isEmpty ? String(localized: "Image") : reference.alt
            case .video: return reference.original
            }
        }

        private static func lines(of content: AttributedString) -> [AttributedString] {
            var lines: [AttributedString] = []
            var start = content.startIndex
            var index = content.startIndex
            while index < content.endIndex {
                let next = content.characters.index(after: index)
                if content.characters[index] == "\n" {
                    lines.append(AttributedString(content[start..<index]))
                    start = next
                }
                index = next
            }
            lines.append(AttributedString(content[start..<content.endIndex]))
            return lines
        }

        private static func trimmingBlankLines(_ lines: [AttributedString]) -> [AttributedString] {
            func isBlank(_ line: AttributedString) -> Bool { line.characters.allSatisfy(\.isWhitespace) }
            guard let first = lines.firstIndex(where: { !isBlank($0) }),
                let last = lines.lastIndex(where: { !isBlank($0) })
            else { return [] }
            return Array(lines[first...last])
        }

        private static func trimWhitespace(_ content: inout AttributedString) {
            while let first = content.characters.first, first.isWhitespace {
                content.removeSubrange(content.startIndex..<content.characters.index(after: content.startIndex))
            }
            while let last = content.characters.last, last.isWhitespace {
                content.removeSubrange(content.characters.index(before: content.endIndex)..<content.endIndex)
            }
        }

        private static func isCode(_ run: AttributedString.Runs.Run) -> Bool {
            run.inlinePresentationIntent?.contains(.code) == true
        }

        private static func isHTML(_ run: AttributedString.Runs.Run) -> Bool {
            run.inlinePresentationIntent?.contains(.inlineHTML) == true
        }
    }
}
