import Foundation
import Testing

@testable import HerdrMobile

@Suite("Snippet")
struct SnippetTests {
    @Test func carriageReturnsBecomeLineFeedsOnSave() throws {
        // The whole point: CR is what the Enter key sends, so text pasted into
        // the editor from a Windows-flavoured source must not smuggle submits
        // into a Snippet that promises never to submit.
        let snippet = try Snippet.make(title: "", body: "first\r\nsecond\rthird")

        #expect(snippet.body == "first\nsecond\nthird")
        #expect(!snippet.body.contains("\r"))
    }

    @Test func tabsAndLineFeedsSurvive() throws {
        let snippet = try Snippet.make(title: "", body: "run:\n\tmake test")

        #expect(snippet.body == "run:\n\tmake test")
    }

    @Test func otherControlCharactersAreRefused() {
        for scalar in [0x00, 0x07, 0x08, 0x0B, 0x1B, 0x1F, 0x7F] {
            let body = "safe\(Character(UnicodeScalar(UInt8(scalar))))text"
            #expect(throws: SnippetValidationError.unsupportedControlCharacters) {
                try Snippet.make(title: "", body: body)
            }
        }
    }

    @Test func blankBodyIsRefused() {
        #expect(throws: SnippetValidationError.emptyBody) {
            try Snippet.make(title: "Named", body: "   \n  ")
        }
    }

    @Test func bodyOverTheLimitIsRefused() {
        let limit = Snippet.bodyCharacterLimit
        #expect(throws: SnippetValidationError.bodyTooLong(limit: limit)) {
            try Snippet.make(title: "", body: String(repeating: "x", count: limit + 1))
        }
        #expect(throws: Never.self) {
            try Snippet.make(title: "", body: String(repeating: "x", count: limit))
        }
    }

    @Test func titleIsTrimmedAndOptional() throws {
        let named = try Snippet.make(title: "  Review  ", body: "please review this")
        let unnamed = try Snippet.make(title: "   ", body: "继续")

        #expect(named.title == "Review")
        #expect(named.displayTitle == "Review")
        #expect(named.displaySubtitle == "please review this")

        #expect(unnamed.title.isEmpty)
        // Without a Title there is nothing to put on the first line, so the
        // body takes it rather than the row showing a blank and a repeat.
        #expect(unnamed.displayTitle == "继续")
        #expect(unnamed.displaySubtitle == nil)
    }

    @Test func decodedSnippetsSurviveARoundTrip() throws {
        let snippet = try Snippet.make(title: "Tests", body: "make test")
        let decoded = try JSONDecoder().decode(
            Snippet.self, from: JSONEncoder().encode(snippet))

        #expect(decoded == snippet)
    }
}
