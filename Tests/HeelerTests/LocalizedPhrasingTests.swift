import Testing

@testable import Heeler

/// Closing and joining localized text without naming any language's marks.
@Suite("Localized phrasing")
struct LocalizedPhrasingTests {
    @Test(arguments: ["Done.", "完了。", "已完成。", "Why?", "¿Listo?", "Stop!", "समाप्त।", "متى؟", "Cut short…"])
    func aClosingMarkOfAnyScriptEndsTheSentence(text: String) {
        #expect(text.endsSentence)
        #expect(text.asSentence == text)
    }

    @Test(arguments: ["", "Not running", "Quoted 「完了」", "(aside)", "v1.2"])
    func textWithoutAClosingMarkDoesNot(text: String) {
        #expect(!text.endsSentence)
    }

    /// The tests run in English.
    @Test func englishClosesWithAPeriodAndJoinsWithCommas() {
        #expect("Not running".asSentence == "Not running.")
        #expect(["2 Working", "1 Blocked"].joinedAsPhrases() == "2 Working, 1 Blocked")
        #expect([String]().joinedAsPhrases().isEmpty)
    }
}
