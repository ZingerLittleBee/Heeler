import Foundation
import Testing

@testable import Heeler

@Suite("Terminal unsafe paste text")
struct TerminalUnsafePasteTextTests {
    @Test func escapesControlCharactersByName() {
        #expect(TerminalUnsafePasteText.escaped("ls\r\n") == "ls<CR><LF>")
        #expect(
            TerminalUnsafePasteText.escaped("cat -v\n\ndictated") == "cat -v<LF><LF>dictated")
        #expect(TerminalUnsafePasteText.escaped("plain text") == "plain text")
        #expect(TerminalUnsafePasteText.escaped("a\u{07}b") == "a<BEL>b")
    }

    @Test func namesEveryControlScalar() {
        #expect(TerminalUnsafePasteText.shortName(for: "\u{1B}") == "ESC")
        #expect(TerminalUnsafePasteText.shortName(for: "\u{7F}") == "DEL")
        // C1 controls are rare but still control-shaped: the alert must not
        // carry one raw either.
        #expect(TerminalUnsafePasteText.shortName(for: "\u{85}") == "U+0085")
        #expect(TerminalUnsafePasteText.shortName(for: "a") == nil)
        #expect(TerminalUnsafePasteText.shortName(for: "é") == nil)
    }

    @Test func previewNeverCarriesAControlCharacter() {
        let preview = TerminalUnsafePasteText.preview(of: "cat -v\r\nfirst line\u{1B}[Adictated\n")

        #expect(!preview.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(preview.hasPrefix("cat -v<CR><LF>"))
        #expect(preview.contains("<ESC>"))
    }

    @Test func distinctControlNamesKeepFirstSeenOrder() {
        #expect(
            TerminalUnsafePasteText.distinctControlNames(in: "ls\r\n\u{1B}[A") == ["CR", "LF", "ESC"])
        #expect(TerminalUnsafePasteText.distinctControlNames(in: "plain text").isEmpty)
        #expect(TerminalUnsafePasteText.distinctControlNames(in: "a\u{07}b\u{07}c") == ["BEL"])
    }

    @Test func summaryCapsLongControlLists() {
        #expect(TerminalUnsafePasteText.summary(in: "plain") == "none")
        #expect(TerminalUnsafePasteText.summary(in: "a\u{07}b") == "BEL")
        let many = "\u{00}\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{07}"
        #expect(TerminalUnsafePasteText.summary(in: many) == "NUL, SOH, STX, ETX, EOT, +3 more")
    }

    @Test func previewTruncatesWithRemainderCount() {
        #expect(TerminalUnsafePasteText.preview(of: "short") == "short")
        let previewed = TerminalUnsafePasteText.preview(of: String(repeating: "a", count: 250))
        #expect(previewed.hasPrefix(String(repeating: "a", count: 200)))
        #expect(previewed.contains("…"))
        #expect(previewed.contains("+50 more characters"))
    }

    @Test func messageCarriesTheSummaryAndThePreview() {
        let message = TerminalUnsafePasteText.message(for: "cat -v\r\ndictated")

        #expect(message.contains("(CR, LF)"))
        #expect(message.contains("cat -v<CR><LF>dictated"))
    }

    /// The three answers are herdr's reachability, so they must not drift: the
    /// only request that can reach an attach client is reviewed, and the two
    /// that cannot are answered without UI.
    @Test func everyRequestKindMapsToItsDocumentedAnswer() {
        #expect(TerminalClipboardRequestDecision.decision(for: .paste) == .askUser)
        #expect(TerminalClipboardRequestDecision.decision(for: .osc52Write) == .allow)
        #expect(TerminalClipboardRequestDecision.decision(for: .osc52Read) == .deny)
    }
}
