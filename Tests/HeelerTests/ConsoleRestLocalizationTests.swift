import Foundation
import Testing

@testable import Heeler

/// Console text matched against other programs' output stays in their
/// language, and the status words the Console shows are translated.
///
/// These read the built `.lproj` tables directly, as `LocalizationBundleTests`
/// does, so they hold whichever language the test host runs in.
@Suite("Console localization")
struct ConsoleRestLocalizationTests {
    private static func japaneseTable() -> [String: String]? {
        guard let path = Bundle.main.path(
            forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ja")
        else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// Claude Code, Oh My Pi and git print these in English whatever the
    /// app's language, so a translation would never match their output: a
    /// rename that worked would read as unconfirmed, and a submodule refusal
    /// would lose its force command.
    @Test(arguments: [
        "Session renamed to: %@",
        "Session renamed to \"%@\".",
        "working trees containing submodules cannot be moved or removed",
    ])
    func screenMatchTokensHaveNoTranslation(key: String) throws {
        let japanese = try #require(Self.japaneseTable())
        let translated = japanese[key]
        #expect(translated == nil || translated == key, "\(key) => \(translated ?? "")")
    }

    @Test func statusWordsFollowTheGlossaryInJapanese() throws {
        let japanese = try #require(Self.japaneseTable())
        let expected = [
            "Blocked": "対応待ち",
            "Working": "作業中",
            "Done": "完了",
            "Idle": "待機中",
        ]
        for (status, word) in expected {
            #expect(japanese[status] == word, "\(status)")
        }
    }
}
