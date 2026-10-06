import Foundation
import Testing

@testable import Heeler

// The expected blocks follow Foundation's Markdown parser as observed on
// macOS 27.0.1. iOS 18's parser is assumed to agree; the parser-dependent
// details are the ordinals of ordered lists, autolink detection, and which
// runs carry source positions.
@Suite("Chat Markdown")
struct ChatMarkdownTests {
    /// A block without its attributed content, for comparing structure.
    struct Shape: Sendable, Equatable, CustomStringConvertible {
        let kind: ChatMarkdownBlock.Kind
        let text: String
        let listDepth: Int
        let quoteDepth: Int

        init(_ kind: ChatMarkdownBlock.Kind, _ text: String, list: Int = 0, quote: Int = 0) {
            self.kind = kind
            self.text = text
            listDepth = list
            quoteDepth = quote
        }

        init(_ block: ChatMarkdownBlock) {
            self.init(block.kind, block.text, list: block.listDepth, quote: block.quoteDepth)
        }

        var description: String { "\(kind) \(text.debugDescription) list \(listDepth) quote \(quoteDepth)" }
    }

    struct Vector: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let expected: [Shape]
        var testDescription: String { name }
    }

    static let vectors: [Vector] = [
        Vector(
            name: "ATX headings", source: "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six",
            expected: [
                Shape(.heading(level: 1), "One"), Shape(.heading(level: 2), "Two"),
                Shape(.heading(level: 3), "Three"), Shape(.heading(level: 4), "Four"),
                Shape(.heading(level: 5), "Five"), Shape(.heading(level: 6), "Six"),
            ]),
        Vector(
            name: "Setext headings", source: "Title\n=====\n\nSub\n---",
            expected: [Shape(.heading(level: 1), "Title"), Shape(.heading(level: 2), "Sub")]),
        Vector(
            name: "Paragraphs", source: "First paragraph.\n\nSecond paragraph.",
            expected: [Shape(.paragraph, "First paragraph."), Shape(.paragraph, "Second paragraph.")]),
        Vector(
            name: "Nested bullets change marker with depth", source: "- a\n  - b\n    - c\n- d",
            expected: [
                Shape(.listItem(marker: "•"), "• a", list: 1),
                Shape(.listItem(marker: "◦"), "◦ b", list: 2),
                Shape(.listItem(marker: "▪"), "▪ c", list: 3),
                Shape(.listItem(marker: "•"), "• d", list: 1),
            ]),
        Vector(
            name: "Ordered lists keep their start number", source: "3. three\n4. four\n5. five",
            expected: [
                Shape(.listItem(marker: "3."), "3. three", list: 1),
                Shape(.listItem(marker: "4."), "4. four", list: 1),
                Shape(.listItem(marker: "5."), "5. five", list: 1),
            ]),
        Vector(
            name: "Ordered lists count up from the first number", source: "1. a\n1. b\n1) c",
            expected: [
                Shape(.listItem(marker: "1."), "1. a", list: 1),
                Shape(.listItem(marker: "2."), "2. b", list: 1),
                // A different delimiter starts a new list.
                Shape(.listItem(marker: "1."), "1. c", list: 1),
            ]),
        Vector(
            name: "Mixed nesting", source: "1. one\n   - sub\n     1. deep\n2. two",
            expected: [
                Shape(.listItem(marker: "1."), "1. one", list: 1),
                Shape(.listItem(marker: "◦"), "◦ sub", list: 2),
                Shape(.listItem(marker: "1."), "1. deep", list: 3),
                Shape(.listItem(marker: "2."), "2. two", list: 1),
            ]),
        Vector(
            name: "A list item's later paragraphs have no marker", source: "- first\n\n  second\n- next",
            expected: [
                Shape(.listItem(marker: "•"), "• first", list: 1),
                Shape(.paragraph, "second", list: 1),
                Shape(.listItem(marker: "•"), "• next", list: 1),
            ]),
        Vector(
            name: "An item that starts with code keeps its number", source: "1. ```sh\n   ls\n   ```\n2. after",
            expected: [
                Shape(.listItem(marker: "1."), "1.", list: 1),
                Shape(.code(language: "sh"), "ls", list: 1),
                Shape(.listItem(marker: "2."), "2. after", list: 1),
            ]),
        Vector(
            name: "An item that starts with a nested list keeps both markers", source: "- - nested",
            expected: [
                Shape(.listItem(marker: "•"), "•", list: 1),
                Shape(.listItem(marker: "◦"), "◦ nested", list: 2),
            ]),
        Vector(
            name: "An item that starts with a heading or quote", source: "- # Title\n- > quoted",
            expected: [
                Shape(.listItem(marker: "•"), "•", list: 1),
                Shape(.heading(level: 1), "Title", list: 1),
                Shape(.listItem(marker: "•"), "•", list: 1),
                Shape(.paragraph, "quoted", list: 1, quote: 1),
            ]),
        Vector(
            name: "Task items stay literal", source: "- [ ] open\n- [x] done",
            expected: [
                Shape(.listItem(marker: "•"), "• [ ] open", list: 1),
                Shape(.listItem(marker: "•"), "• [x] done", list: 1),
            ]),
        Vector(
            name: "Nested quotes", source: "> outer\n>\n> > inner\n\nafter",
            expected: [
                Shape(.paragraph, "outer", quote: 1), Shape(.paragraph, "inner", quote: 2),
                Shape(.paragraph, "after"),
            ]),
        Vector(
            name: "A list inside a quote", source: "> - a\n> - b\n>\n> text",
            expected: [
                Shape(.listItem(marker: "•"), "• a", list: 1, quote: 1),
                Shape(.listItem(marker: "•"), "• b", list: 1, quote: 1),
                Shape(.paragraph, "text", quote: 1),
            ]),
        Vector(
            name: "A list item inside a quote that starts with code", source: "> 1. ```\n>    x\n>    ```",
            expected: [
                Shape(.listItem(marker: "1."), "1.", list: 1, quote: 1),
                Shape(.code(language: nil), "x", list: 1, quote: 1),
            ]),
        Vector(
            name: "Fenced code with a language", source: "```swift\nlet x = 1\nprint(x)\n```",
            expected: [Shape(.code(language: "swift"), "let x = 1\nprint(x)")]),
        Vector(
            name: "Fenced code without a language", source: "```\nplain\n```",
            expected: [Shape(.code(language: nil), "plain")]),
        Vector(
            name: "The language is the info string's first word", source: "```swift title=x\nlet a = 1\n```",
            expected: [Shape(.code(language: "swift"), "let a = 1")]),
        Vector(
            name: "Code drops only its final newline", source: "```py\nx = 1\n\n```",
            expected: [Shape(.code(language: "py"), "x = 1\n")]),
        Vector(
            name: "Tilde fences and indented code", source: "~~~\nraw\n~~~\n\n    indented\n    more\n",
            expected: [Shape(.code(language: nil), "raw"), Shape(.code(language: nil), "indented\nmore")]),
        Vector(
            name: "Code in a quote", source: "> ```js\n> x()\n> ```",
            expected: [Shape(.code(language: "js"), "x()", quote: 1)]),
        Vector(
            name: "An unclosed fence runs to the end", source: "intro\n\n```python\nprint(1)\n",
            expected: [Shape(.paragraph, "intro"), Shape(.code(language: "python"), "print(1)")]),
        Vector(
            name: "Thematic breaks", source: "above\n\n---\n\n***\n\nbelow",
            expected: [
                Shape(.paragraph, "above"), Shape(.thematicBreak, ""), Shape(.thematicBreak, ""),
                Shape(.paragraph, "below"),
            ]),
        Vector(
            name: "A raw HTML block stays verbatim", source: "<div>\nblock <b>html</b>\n</div>\n\nafter",
            expected: [Shape(.html, "<div>\nblock <b>html</b>\n</div>"), Shape(.paragraph, "after")]),
        Vector(
            name: "Adjacent HTML blocks stay separate", source: "<div>a</div>\n\n<p>b</p>",
            expected: [Shape(.html, "<div>a</div>"), Shape(.html, "<p>b</p>")]),
        Vector(
            name: "HTML at the start of a list item", source: "- <div>x</div>\n- y",
            expected: [
                Shape(.listItem(marker: "•"), "•", list: 1), Shape(.html, "<div>x</div>", list: 1),
                Shape(.listItem(marker: "•"), "• y", list: 1),
            ]),
        Vector(
            name: "Inline HTML stays text", source: "before <b>bold</b> after",
            expected: [Shape(.paragraph, "before <b>bold</b> after")]),
        Vector(
            name: "A table stays as its source lines",
            source: "| Col A | Col B |\n| ----- | ----: |\n| a1 | **b1** |\n| a2 | `b2` |\n\nafter",
            expected: [
                Shape(.table, "| Col A | Col B |\n| ----- | ----: |\n| a1 | **b1** |\n| a2 | `b2` |"),
                Shape(.paragraph, "after"),
            ]),
        Vector(
            name: "A header-only table keeps its delimiter row", source: "| a | b |\n| - | - |\n\nafter",
            expected: [Shape(.table, "| a | b |\n| - | - |"), Shape(.paragraph, "after")]),
        Vector(
            name: "A table keeps rows of empty cells",
            source: "| a | b |\n| - | - |\n| 1 | 2 |\n|   |   |\n\nafter",
            expected: [Shape(.table, "| a | b |\n| - | - |\n| 1 | 2 |\n|   |   |"), Shape(.paragraph, "after")]),
        Vector(
            name: "A table with an empty header row", source: "intro\n\n|   |   |\n| - | - |\n| 1 | 2 |\n\n---\n\nend",
            expected: [
                Shape(.paragraph, "intro"), Shape(.table, "|   |   |\n| - | - |\n| 1 | 2 |"),
                Shape(.thematicBreak, ""), Shape(.paragraph, "end"),
            ]),
        Vector(
            name: "A table between other blocks", source: "# Title\n| a |\n| - |\n| 1 |\n\n---\n\nend",
            expected: [
                Shape(.heading(level: 1), "Title"), Shape(.table, "| a |\n| - |\n| 1 |"),
                Shape(.thematicBreak, ""), Shape(.paragraph, "end"),
            ]),
        Vector(
            name: "A table ends where the next block starts", source: "| a |\n| - |\n| 1 |\n# Heading",
            expected: [Shape(.table, "| a |\n| - |\n| 1 |"), Shape(.heading(level: 1), "Heading")]),
        Vector(
            name: "A table can follow a paragraph line directly", source: "intro\n| a |\n| - |\n| 1 |",
            expected: [Shape(.paragraph, "intro"), Shape(.table, "| a |\n| - |\n| 1 |")]),
        Vector(
            name: "A table after several paragraph lines",
            source: "one\ntwo\nthree\n| a | b |\n| - | - |\n| 1 | 2 |\n\nafter",
            expected: [
                Shape(.paragraph, "one two three"), Shape(.table, "| a | b |\n| - | - |\n| 1 | 2 |"),
                Shape(.paragraph, "after"),
            ]),
        Vector(
            name: "A header-only aligned table after a paragraph line", source: "# H\n\npara\n| x | y |\n|:--|--:|",
            expected: [
                Shape(.heading(level: 1), "H"), Shape(.paragraph, "para"), Shape(.table, "| x | y |\n|:--|--:|"),
            ]),
        Vector(
            name: "A table after a list item's first line", source: "- item\n  | a |\n  | - |\n  | 1 |",
            expected: [
                Shape(.listItem(marker: "•"), "• item", list: 1), Shape(.table, "| a |\n| - |\n| 1 |", list: 1),
            ]),
        Vector(
            name: "A table after a quoted line", source: "> intro\n> | a |\n> | - |",
            expected: [Shape(.paragraph, "intro", quote: 1), Shape(.table, "| a |\n| - |", quote: 1)]),
        Vector(
            name: "A table before a misreported one keeps its rows",
            source: "| a |\n| - |\n| 1 |\n|   |\n\nintro\n| b |\n| - |\n| 2 |",
            expected: [
                Shape(.table, "| a |\n| - |\n| 1 |\n|   |"), Shape(.paragraph, "intro"),
                Shape(.table, "| b |\n| - |\n| 2 |"),
            ]),
        Vector(
            name: "An aligned table without outer pipes", source: "l | c | r\n:-- | :-: | --:\n1 | 2 | 3",
            expected: [Shape(.table, "l | c | r\n:-- | :-: | --:\n1 | 2 | 3")]),
        Vector(
            name: "A table in a quote loses its quote markers",
            source: "> | a | b |\n> | - | - |\n> | 1 | 2 |\n>\n> text",
            expected: [
                Shape(.table, "| a | b |\n| - | - |\n| 1 | 2 |", quote: 1), Shape(.paragraph, "text", quote: 1),
            ]),
        Vector(
            name: "A table in a list item loses its indent", source: "- item\n\n  | a | b |\n  | - | - |\n  | 1 | 2 |",
            expected: [
                Shape(.listItem(marker: "•"), "• item", list: 1),
                Shape(.table, "| a | b |\n| - | - |\n| 1 | 2 |", list: 1),
            ]),
        Vector(
            name: "Images show their alt text", source: "see ![alt text](https://example.com/a.png) here",
            expected: [Shape(.paragraph, "see alt text here")]),
        Vector(
            name: "A soft break is a space", source: "line one\nline two",
            expected: [Shape(.paragraph, "line one line two")]),
        Vector(
            name: "Hard breaks are newlines", source: "line one  \nline two\\\nline three",
            expected: [Shape(.paragraph, "line one\nline two\nline three")]),
        Vector(
            name: "CJK and emoji", source: "# 标题 🎉\n\n中文段落，含**粗体**与`代码`。👍🏽 家族👨‍👩‍👧",
            expected: [Shape(.heading(level: 1), "标题 🎉"), Shape(.paragraph, "中文段落，含粗体与代码。👍🏽 家族👨‍👩‍👧")]),
        Vector(
            name: "CJK in a table", source: "| 名称 | 状态 |\n| --- | --- |\n| 构建 | ✅ |",
            expected: [Shape(.table, "| 名称 | 状态 |\n| --- | --- |\n| 构建 | ✅ |")]),
        Vector(
            name: "CRLF and CR line endings", source: "first\r\nsecond\r\n\r\n```c\r\nint x;\r\n```\r| a |\r| - |",
            expected: [
                Shape(.paragraph, "first second"), Shape(.code(language: "c"), "int x;"),
                Shape(.table, "| a |\n| - |"),
            ]),
        Vector(
            name: "Entities decode", source: "a &amp; b &lt; c",
            expected: [Shape(.paragraph, "a & b < c")]),
        Vector(name: "Empty input", source: "", expected: []),
        Vector(name: "Whitespace only", source: "  \n\n\t\n", expected: []),
    ]

    @Test("Blocks follow the document's structure", arguments: vectors)
    func structure(_ vector: Vector) {
        let shapes = ChatMarkdown.blocks(from: vector.source).map(Shape.init)
        #expect(shapes == vector.expected)
    }

    @Test("Blocks carry no block attributes or source positions", arguments: vectors)
    func noBlockAttributes(_ vector: Vector) {
        for block in ChatMarkdown.blocks(from: vector.source) {
            for run in block.content.runs {
                #expect(run.presentationIntent == nil)
                #expect(run.markdownSourcePosition == nil)
                #expect(run.imageURL == nil)
            }
            if case .listItem = block.kind {
                continue
            }
            #expect(String(block.content.characters) == block.text)
        }
    }

    @Test("Inline styles survive as inline presentation intents")
    func inlineStyles() throws {
        let block = try #require(
            ChatMarkdown.blocks(from: "**strong** *em* `code` ~~strike~~ ***both*** plain").first)
        #expect(block.text == "strong em code strike both plain")
        #expect(intents(in: block.content) == [
            Styled("strong", .stronglyEmphasized), Styled(" "), Styled("em", .emphasized), Styled(" "),
            Styled("code", .code), Styled(" "), Styled("strike", .strikethrough), Styled(" "),
            Styled("both", [.emphasized, .stronglyEmphasized]), Styled(" plain"),
        ])
    }

    @Test("A soft break inside emphasis keeps the emphasis and loses the break intent")
    func softBreakInEmphasis() throws {
        let block = try #require(ChatMarkdown.blocks(from: "*a\nb*").first)
        let runs = Array(block.content.runs)
        #expect(runs.count == 1)
        #expect(runs.first?.inlinePresentationIntent == .emphasized)
        #expect(String(block.content.characters) == "a b")
    }

    @Test("A hard break leaves no break intent behind")
    func hardBreakIntent() throws {
        let block = try #require(ChatMarkdown.blocks(from: "one  \ntwo").first)
        #expect(block.content.runs.count == 1)
        #expect(block.content.runs.first?.inlinePresentationIntent == nil)
    }

    @Test("A heading keeps its inline styles")
    func headingInlineStyles() throws {
        let block = try #require(ChatMarkdown.blocks(from: "## Use `foo()` now").first)
        #expect(block.kind == .heading(level: 2))
        #expect(intents(in: block.content) == [Styled("Use "), Styled("foo()", .code), Styled(" now")])
    }

    @Test("Web links stay links; every other link keeps only its text")
    func linkPolicy() throws {
        let source = """
            [ok](https://example.com) [bad](javascript:alert(1)) [rel](docs/a.md) \
            [abs](/etc/x) [mail](mailto:a@b.c) [file](file:///etc/passwd) [own](heeler://pair) \
            [data](data:text/html,hi) [ftp](ftp://x.test/f)
            """
        let block = try #require(ChatMarkdown.blocks(from: source).first)
        #expect(block.text == "ok bad rel abs mail file own data ftp")
        #expect(links(in: block.content) == ["ok": "https://example.com"])
    }

    @Test("Autolinks to the web are links; an e-mail address is text")
    func autolinks() throws {
        let source = "see https://example.org/x?y=1 and www.example.com and <https://angle.test> and a@b.co"
        let block = try #require(ChatMarkdown.blocks(from: source).first)
        #expect(block.text == "see https://example.org/x?y=1 and www.example.com and https://angle.test and a@b.co")
        #expect(links(in: block.content) == [
            "https://example.org/x?y=1": "https://example.org/x?y=1",
            "www.example.com": "http://www.example.com",
            "https://angle.test": "https://angle.test",
        ])
    }

    @Test("An image is its alt text and is never fetched, even inside a link")
    func images() throws {
        let image = try #require(ChatMarkdown.blocks(from: "![diagram](https://example.com/a.png)").first)
        #expect(image.text == "diagram")
        #expect(image.content.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })

        let linked = try #require(
            ChatMarkdown.blocks(from: "[![logo](https://x.test/l.png)](https://example.com)").first)
        #expect(linked.text == "logo")
        #expect(links(in: linked.content) == ["logo": "https://example.com"])
    }

    @Test("A footnote reference keeps its text and loses its relative link")
    func footnote() throws {
        let blocks = ChatMarkdown.blocks(from: "text[^1]\n\n[^1]: note")
        #expect(blocks.map(\.text) == ["text^1"])
        let block = try #require(blocks.first)
        #expect(links(in: block.content).isEmpty)
    }

    @Test("A list item's content holds the text without its marker")
    func listItemContent() throws {
        let block = try #require(ChatMarkdown.blocks(from: "7. **seven**").first)
        #expect(block.kind == .listItem(marker: "7."))
        #expect(block.text == "7. seven")
        #expect(intents(in: block.content) == [Styled("seven", .stronglyEmphasized)])
    }

    @Test("Code, tables and HTML are plain text without styles")
    func verbatimBlocksArePlain() {
        let blocks = ChatMarkdown.blocks(from: "```\n**x**\n```\n\n| **a** |\n| - |\n\n<div>*y*</div>")
        #expect(blocks.map(\.text) == ["**x**", "| **a** |\n| - |", "<div>*y*</div>"])
        for block in blocks {
            #expect(block.content == AttributedString(block.text))
        }
    }

    @Test("A source over 48 KB is one plain paragraph, as written")
    func oversizedSource() throws {
        let unit = "## Heading\n\n**bold** and `code` with a [link](https://example.com).\r\n\n"
        let source = String(repeating: unit, count: 60 * 1_024 / unit.utf8.count + 1)
        #expect(source.utf8.count >= 60 * 1_024)
        let blocks = ChatMarkdown.blocks(from: source)
        #expect(blocks == [ChatMarkdownBlock(kind: .paragraph, content: AttributedString(source), text: source)])
    }

    @Test("A source of exactly 48 KB still parses; one byte more does not")
    func sizeBoundary() throws {
        let head = "# Head\n\n"
        let filler = String(repeating: "x", count: ChatMarkdown.maximumSourceBytes - head.utf8.count)
        let atLimit = head + filler
        #expect(atLimit.utf8.count == ChatMarkdown.maximumSourceBytes)
        #expect(ChatMarkdown.blocks(from: atLimit).first?.kind == .heading(level: 1))

        let overLimit = atLimit + "x"
        let blocks = ChatMarkdown.blocks(from: overLimit)
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .paragraph)
        #expect(blocks.first?.text == overLimit)
    }

    /// A run's text and inline intent.
    struct Styled: Equatable, CustomStringConvertible {
        let text: String
        let intent: InlinePresentationIntent?

        init(_ text: String, _ intent: InlinePresentationIntent? = nil) {
            self.text = text
            self.intent = intent
        }

        var description: String { "\(text.debugDescription) \(intent.map { String($0.rawValue) } ?? "-")" }
    }

    private func intents(in content: AttributedString) -> [Styled] {
        content.runs.map { Styled(String(content[$0.range].characters), $0.inlinePresentationIntent) }
    }

    /// The text of every linked run and its URL.
    private func links(in content: AttributedString) -> [String: String] {
        var result: [String: String] = [:]
        for run in content.runs {
            if let link = run.link {
                result[String(content[run.range].characters)] = link.absoluteString
            }
        }
        return result
    }
}
