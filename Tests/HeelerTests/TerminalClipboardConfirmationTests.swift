import Testing

@testable import Heeler

@Suite("Terminal clipboard confirmation")
struct TerminalClipboardConfirmationTests {
    @Test func osc52WritePromptsUntilAllowed() {
        #expect(
            TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .osc52Write, osc52WriteApproved: false))
        #expect(
            !TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .osc52Write, osc52WriteApproved: true))
    }

    @Test func osc52ReadAlwaysPrompts() {
        #expect(
            TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .osc52Read, osc52WriteApproved: false))
        #expect(
            TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .osc52Read, osc52WriteApproved: true))
    }

    @Test func unsafePasteAlwaysPrompts() {
        #expect(
            TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .paste, osc52WriteApproved: false))
        #expect(
            TerminalClipboardConfirmationPolicy.requiresPrompt(
                for: .paste, osc52WriteApproved: true))
    }

    @Test func namesControlCharactersInFirstSeenOrder() {
        #expect(
            TerminalClipboardControlCharacters.distinctControlNames(in: "ls\r\n\u{1B}[A")
                == ["CR", "LF", "ESC"])
        #expect(
            TerminalClipboardControlCharacters.distinctControlNames(in: "plain text").isEmpty)
        #expect(
            TerminalClipboardControlCharacters.distinctControlNames(in: "a\u{07}b\u{07}c")
                == ["BEL"])
        #expect(
            TerminalClipboardControlCharacters.distinctControlNames(in: "x\u{7F}y") == ["DEL"])
    }

    @Test func summaryCapsLongControlLists() {
        #expect(TerminalClipboardControlCharacters.summary(in: "plain") == "none")
        #expect(TerminalClipboardControlCharacters.summary(in: "a\u{07}b") == "BEL")
        let many = "\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}"
        #expect(
            TerminalClipboardControlCharacters.summary(in: many)
                == "NUL, SOH, STX, ETX, EOT, +3 more")
    }

    @Test func previewTruncatesWithRemainderCount() {
        #expect(TerminalClipboardControlCharacters.preview(of: "short") == "short")
        let long = String(repeating: "a", count: 250)
        let previewed = TerminalClipboardControlCharacters.preview(of: long)
        #expect(previewed.hasPrefix(String(repeating: "a", count: 200)))
        #expect(previewed.contains("…"))
        #expect(previewed.contains("+50 more characters"))
    }
}
