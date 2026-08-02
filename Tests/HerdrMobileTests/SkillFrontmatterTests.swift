import Foundation
import Testing

@testable import HerdrMobile

@Suite("skill frontmatter parsing")
struct SkillFrontmatterTests {
    @Test func parsesPlainScalars() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name: code-review
            description: Review the changes since a fixed point.
            ---
            # Body
            """)
        #expect(parsed.name == "code-review")
        #expect(parsed.description == "Review the changes since a fixed point.")
    }

    @Test func unquotesQuotedScalars() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name: "tdd"
            description: 'Red, green, refactor.'
            ---
            """)
        #expect(parsed.name == "tdd")
        #expect(parsed.description == "Red, green, refactor.")
    }

    @Test func foldsBlockScalarDescriptions() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name: research
            description: >-
              Investigate a question against primary sources
              and capture the findings.
            ---
            """)
        #expect(
            parsed.description
                == "Investigate a question against primary sources and capture the findings.")
    }

    @Test func keepsLiteralBlockNewlines() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            description: |
              First line.
              Second line.
            ---
            """)
        #expect(parsed.description == "First line.\nSecond line.")
    }

    @Test func foldsWrappedPlainScalars() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            description: A description that wraps
              onto a second line.
            ---
            """)
        #expect(parsed.description == "A description that wraps onto a second line.")
    }

    @Test func fileWithoutFrontmatterParsesEmpty() {
        let parsed = SkillFrontmatter.parse("# Just a heading\n\nSome prose.")
        #expect(parsed == SkillFrontmatter())
    }

    @Test func survivesCRLFAndBOM() {
        let parsed = SkillFrontmatter.parse(
            "\u{FEFF}---\r\nname: crlf-skill\r\ndescription: Written on Windows.\r\n---\r\n")
        #expect(parsed.name == "crlf-skill")
        #expect(parsed.description == "Written on Windows.")
    }

    @Test func skipsNestedMappingsAndUnknownKeys() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name: complex
            metadata:
              type: project
            allowed-tools: Bash, Read
            description: Still found below the noise.
            ---
            """)
        #expect(parsed.name == "complex")
        #expect(parsed.description == "Still found below the noise.")
    }

    @Test func endsAtDotDotDotFence() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name: fenced
            ...
            description: This is body text, not frontmatter.
            """)
        #expect(parsed.name == "fenced")
        #expect(parsed.description == nil)
    }

    @Test func emptyValuesReadAsMissing() {
        let parsed = SkillFrontmatter.parse(
            """
            ---
            name:
            description:
            ---
            """)
        #expect(parsed.name == nil)
        #expect(parsed.description == nil)
    }
}
