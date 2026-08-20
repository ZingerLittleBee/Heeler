import Foundation
import Testing

@testable import Heeler

@Suite("Code syntax highlighter")
struct CodeSyntaxHighlighterTests {
    @Test func swiftTokensCoverCommentsStringsKeywordsAndNumbers() {
        let source = "// note\nlet answer = \"forty-two\" + 42\n"
        let tokens = CodeSyntaxHighlighter.tokens(in: source, language: .swift)

        #expect(hasToken(.comment, text: "// note", in: source, tokens: tokens))
        #expect(hasToken(.keyword, text: "let", in: source, tokens: tokens))
        #expect(hasToken(.string, text: "\"forty-two\"", in: source, tokens: tokens))
        #expect(hasToken(.number, text: "42", in: source, tokens: tokens))
    }

    @Test func unterminatedStringsEndAtTheSourceWithoutRunningAway() {
        let source = "let message = \"unfinished"
        let tokens = CodeSyntaxHighlighter.tokens(in: source, language: .swift)
        let stringToken = tokens.first { $0.kind == .string }

        #expect(stringToken?.range.location == (source as NSString).range(of: "\"").location)
        #expect(NSMaxRange(stringToken?.range ?? NSRange(location: 0, length: 0)) == source.utf16.count)
    }

    @Test func jsonAndYAMLRecognizeTheirBasicTokens() {
        let json = "{\"enabled\": true, \"retries\": 3}"
        let yaml = "enabled: false\n# deployment\nretries: 3\n"

        let jsonTokens = CodeSyntaxHighlighter.tokens(in: json, language: .json)
        let yamlTokens = CodeSyntaxHighlighter.tokens(in: yaml, language: .yaml)

        #expect(hasToken(.string, text: "\"enabled\"", in: json, tokens: jsonTokens))
        #expect(hasToken(.keyword, text: "true", in: json, tokens: jsonTokens))
        #expect(hasToken(.number, text: "3", in: json, tokens: jsonTokens))
        #expect(hasToken(.keyword, text: "false", in: yaml, tokens: yamlTokens))
        #expect(hasToken(.comment, text: "# deployment", in: yaml, tokens: yamlTokens))
    }

    @Test func unknownExtensionsYieldNoTokens() {
        let source = "opaque format 12"
        #expect(CodeSyntaxHighlighter.language(forPath: "/workspace/file.custom") == .plain)
        #expect(CodeSyntaxHighlighter.tokens(in: source, language: .plain).isEmpty)
    }

    @Test func utf16RangesStayOnCharacterBoundariesForHostileText() {
        let source = "let text = \"😀 \\\"nested\\\" quote\" // 😈\r\nlet value = 0x2A"
        let tokens = CodeSyntaxHighlighter.tokens(in: source, language: .swift)

        #expect(tokens.allSatisfy { token in
            token.range.location >= 0
                && NSMaxRange(token.range) <= source.utf16.count
                && Range(token.range, in: source) != nil
        })
        #expect(hasToken(.string, text: "\"😀 \\\"nested\\\" quote\"", in: source, tokens: tokens))
        #expect(hasToken(.comment, text: "// 😈", in: source, tokens: tokens))
    }

    private func hasToken(
        _ kind: CodeSyntaxHighlighter.Kind,
        text: String,
        in source: String,
        tokens: [CodeSyntaxHighlighter.Token]
    ) -> Bool {
        let range = (source as NSString).range(of: text)
        return tokens.contains { $0.kind == kind && $0.range == range }
    }
}
