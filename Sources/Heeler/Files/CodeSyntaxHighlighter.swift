import Foundation

/// A small lexical highlighter for the editor. It deliberately recognizes only
/// tokens that are safe to colour without parsing: a malformed remote file
/// remains editable instead of making the editor wait on a compiler.
enum CodeSyntaxHighlighter {
    enum Language: Sendable, Equatable {
        case swift
        case kotlin
        case rust
        case go
        case python
        case javaScript
        case json
        case yaml
        case toml
        case shell
        case markdown
        case c
        case zig
        case plain
    }

    enum Kind: Sendable, Equatable {
        case comment
        case string
        case number
        case keyword
        case heading
        case codeFence
    }

    struct Token: Sendable, Equatable {
        let range: NSRange
        let kind: Kind
    }

    static func language(forPath path: String) -> Language {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "kt", "kts": .kotlin
        case "rs": .rust
        case "go": .go
        case "py", "pyw": .python
        case "js", "mjs", "cjs", "jsx", "ts", "tsx": .javaScript
        case "json": .json
        case "yaml", "yml": .yaml
        case "toml": .toml
        case "sh", "bash", "zsh", "fish": .shell
        case "md", "markdown", "mdown": .markdown
        case "c", "cc", "cp", "cpp", "cxx", "h", "hh", "hpp", "hxx": .c
        case "zig": .zig
        default: .plain
        }
    }

    /// Returns UTF-16 ranges because `NSTextStorage` consumes UTF-16 offsets.
    /// The scanner only creates boundaries at ASCII syntax characters or at the
    /// source ends, so an emoji in a comment or string is always kept whole.
    static func tokens(in text: String, language: Language) -> [Token] {
        switch language {
        case .plain:
            []
        case .markdown:
            markdownTokens(in: text as NSString)
        default:
            genericTokens(in: text as NSString, configuration: configuration(for: language))
        }
    }

    private struct BlockComment: Sendable {
        let opening: String
        let closing: String
    }

    private struct Configuration: Sendable {
        let lineComment: String?
        let blockComment: BlockComment?
        let keywords: Set<String>
        let stringDelimiters: Set<UInt16>
    }

    private static func configuration(for language: Language) -> Configuration {
        switch language {
        case .swift:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: swiftKeywords, stringDelimiters: [quote])
        case .kotlin:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: kotlinKeywords, stringDelimiters: [quote])
        case .rust:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: rustKeywords, stringDelimiters: [quote, apostrophe])
        case .go:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: goKeywords, stringDelimiters: [quote, backtick])
        case .python:
            Configuration(
                lineComment: "#", blockComment: nil,
                keywords: pythonKeywords, stringDelimiters: [quote, apostrophe])
        case .javaScript:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: javaScriptKeywords, stringDelimiters: [quote, apostrophe, backtick])
        case .json:
            Configuration(
                lineComment: nil, blockComment: nil,
                keywords: jsonKeywords, stringDelimiters: [quote])
        case .yaml:
            Configuration(
                lineComment: "#", blockComment: nil,
                keywords: yamlKeywords, stringDelimiters: [quote, apostrophe])
        case .toml:
            Configuration(
                lineComment: "#", blockComment: nil,
                keywords: tomlKeywords, stringDelimiters: [quote, apostrophe])
        case .shell:
            Configuration(
                lineComment: "#", blockComment: nil,
                keywords: shellKeywords, stringDelimiters: [quote, apostrophe, backtick])
        case .c:
            Configuration(
                lineComment: "//", blockComment: BlockComment(opening: "/*", closing: "*/"),
                keywords: cKeywords, stringDelimiters: [quote, apostrophe])
        case .zig:
            Configuration(
                lineComment: "//", blockComment: nullBlockComment,
                keywords: zigKeywords, stringDelimiters: [quote])
        case .markdown, .plain:
            Configuration(lineComment: nil, blockComment: nil, keywords: [], stringDelimiters: [])
        }
    }

    private static func genericTokens(in source: NSString, configuration: Configuration) -> [Token] {
        let length = source.length
        var tokens: [Token] = []
        var offset = 0

        while offset < length {
            if let marker = configuration.lineComment, matches(source, at: offset, marker: marker) {
                let start = offset
                offset += marker.utf16.count
                while offset < length, !isLineBreak(source.character(at: offset)) {
                    offset += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: offset - start), kind: .comment))
                continue
            }

            if let block = configuration.blockComment,
                matches(source, at: offset, marker: block.opening)
            {
                let start = offset
                offset += block.opening.utf16.count
                while offset < length, !matches(source, at: offset, marker: block.closing) {
                    offset += 1
                }
                if matches(source, at: offset, marker: block.closing) {
                    offset += block.closing.utf16.count
                }
                tokens.append(Token(range: NSRange(location: start, length: offset - start), kind: .comment))
                continue
            }

            let unit = source.character(at: offset)
            if configuration.stringDelimiters.contains(unit) {
                let start = offset
                offset += 1
                while offset < length {
                    let current = source.character(at: offset)
                    if current == backslash {
                        offset += 1
                        if offset < length { offset += 1 }
                    } else {
                        offset += 1
                        if current == unit { break }
                    }
                }
                tokens.append(Token(range: NSRange(location: start, length: offset - start), kind: .string))
                continue
            }

            if isDigit(unit) {
                let start = offset
                offset = numberEnd(in: source, from: offset)
                tokens.append(Token(range: NSRange(location: start, length: offset - start), kind: .number))
                continue
            }

            if isIdentifierStart(unit) {
                let start = offset
                offset += 1
                while offset < length, isIdentifierContinue(source.character(at: offset)) {
                    offset += 1
                }
                let word = source.substring(with: NSRange(location: start, length: offset - start))
                if configuration.keywords.contains(word) {
                    tokens.append(Token(range: NSRange(location: start, length: offset - start), kind: .keyword))
                }
                continue
            }

            offset += 1
        }
        return tokens
    }

    private static func markdownTokens(in source: NSString) -> [Token] {
        let length = source.length
        var tokens: [Token] = []
        var lineStart = 0

        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length, !isLineBreak(source.character(at: lineEnd)) {
                lineEnd += 1
            }
            var contentStart = lineStart
            while contentStart < lineEnd, isMarkdownIndent(source.character(at: contentStart)) {
                contentStart += 1
            }

            if contentStart < lineEnd, source.character(at: contentStart) == hash {
                tokens.append(
                    Token(
                        range: NSRange(location: contentStart, length: lineEnd - contentStart),
                        kind: .heading))
            } else if matches(source, at: contentStart, marker: "```")
                || matches(source, at: contentStart, marker: "~~~")
            {
                tokens.append(
                    Token(
                        range: NSRange(location: contentStart, length: lineEnd - contentStart),
                        kind: .codeFence))
            }

            lineStart = lineEnd
            if lineStart < length, source.character(at: lineStart) == carriageReturn {
                lineStart += 1
            }
            if lineStart < length, source.character(at: lineStart) == lineFeed {
                lineStart += 1
            }
        }
        return tokens
    }

    private static func numberEnd(in source: NSString, from start: Int) -> Int {
        let length = source.length
        var offset = start
        if source.character(at: offset) == zero,
            offset + 1 < length,
            source.character(at: offset + 1) == x || source.character(at: offset + 1) == uppercaseX
        {
            offset += 2
            while offset < length, isHexDigit(source.character(at: offset)) || source.character(at: offset) == underscore {
                offset += 1
            }
            return offset
        }

        while offset < length, isDigit(source.character(at: offset)) || source.character(at: offset) == underscore {
            offset += 1
        }
        if offset < length, source.character(at: offset) == period {
            offset += 1
            while offset < length, isDigit(source.character(at: offset)) || source.character(at: offset) == underscore {
                offset += 1
            }
        }
        if offset < length, source.character(at: offset) == e || source.character(at: offset) == uppercaseE {
            let exponentStart = offset
            offset += 1
            if offset < length, source.character(at: offset) == plus || source.character(at: offset) == minus {
                offset += 1
            }
            let digitsStart = offset
            while offset < length, isDigit(source.character(at: offset)) || source.character(at: offset) == underscore {
                offset += 1
            }
            if digitsStart == offset { offset = exponentStart }
        }
        return offset
    }

    private static func matches(_ source: NSString, at offset: Int, marker: String) -> Bool {
        let markerLength = marker.utf16.count
        guard offset + markerLength <= source.length else { return false }
        for (index, unit) in marker.utf16.enumerated() {
            guard source.character(at: offset + index) == unit else { return false }
        }
        return true
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == carriageReturn || unit == lineFeed
    }

    private static func isMarkdownIndent(_ unit: UInt16) -> Bool {
        unit == space || unit == tab
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= zero && unit <= nine
    }

    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= a && unit <= f) || (unit >= uppercaseA && unit <= uppercaseF)
    }

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= a && unit <= z) || (unit >= uppercaseA && unit <= uppercaseZ) || unit == underscore
    }

    private static func isIdentifierContinue(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    private static let nullBlockComment: BlockComment? = nil
    private static let quote: UInt16 = 0x22
    private static let apostrophe: UInt16 = 0x27
    private static let backtick: UInt16 = 0x60
    private static let backslash: UInt16 = 0x5C
    private static let hash: UInt16 = 0x23
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let carriageReturn: UInt16 = 0x0D
    private static let lineFeed: UInt16 = 0x0A
    private static let zero: UInt16 = 0x30
    private static let nine: UInt16 = 0x39
    private static let a: UInt16 = 0x61
    private static let f: UInt16 = 0x66
    private static let z: UInt16 = 0x7A
    private static let uppercaseA: UInt16 = 0x41
    private static let uppercaseZ: UInt16 = 0x5A
    private static let uppercaseE: UInt16 = 0x45
    private static let uppercaseF: UInt16 = 0x46
    private static let uppercaseX: UInt16 = 0x58
    private static let x: UInt16 = 0x78
    private static let e: UInt16 = 0x65
    private static let underscore: UInt16 = 0x5F
    private static let period: UInt16 = 0x2E
    private static let plus: UInt16 = 0x2B
    private static let minus: UInt16 = 0x2D

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "async", "await", "break", "case", "class", "continue", "default",
        "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import",
        "in", "init", "let", "nil", "protocol", "public", "private", "return", "self", "static",
        "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while",
    ]
    private static let kotlinKeywords: Set<String> = [
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface",
        "is", "null", "object", "package", "return", "super", "this", "throw", "true", "try", "typealias",
        "val", "var", "when", "while",
    ]
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
        "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
        "where", "while",
    ]
    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
        "struct", "switch", "type", "var",
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
        "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield",
    ]
    private static let javaScriptKeywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import",
        "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "return",
        "static", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void",
        "while", "yield",
    ]
    private static let jsonKeywords: Set<String> = ["true", "false", "null"]
    private static let yamlKeywords: Set<String> = ["true", "false", "null", "yes", "no", "on", "off"]
    private static let tomlKeywords: Set<String> = ["true", "false"]
    private static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "then", "until",
        "while",
    ]
    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
    ]
    private static let zigKeywords: Set<String> = [
        "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "catch",
        "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "false",
        "fn", "for", "if", "inline", "noalias", "nosuspend", "null", "opaque", "or", "orelse", "packed", "pub",
        "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "true", "try", "union", "unreachable",
        "var", "volatile", "while",
    ]
}
