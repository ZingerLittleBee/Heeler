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
        #expect(!LocalizationTables.translations.isEmpty)
        for language in LocalizationTables.translations {
            let table = try #require(LocalizationTables.table("Localizable", localization: language))
            let translated = table[key]
            #expect(translated == nil || translated == key, "\(language): \(key) => \(translated ?? "")")
        }
    }

    /// The status words of each language whose glossary fixes them.
    @Test(arguments: [
        ("ja", ["Blocked": "対応待ち", "Working": "作業中", "Agent status Done": "完了", "Idle": "待機中"]),
        ("zh-Hans", ["Blocked": "待处理", "Working": "工作中", "Agent status Done": "已完成", "Idle": "空闲"]),
        ("zh-Hant", ["Blocked": "待處理", "Working": "工作中", "Agent status Done": "已完成", "Idle": "閒置"]),
    ])
    func statusWordsFollowTheGlossary(language: String, words: [String: String]) throws {
        let table = try #require(LocalizationTables.table("Localizable", localization: language))
        for (status, word) in words {
            #expect(table[status] == word, "\(language): \(status)")
        }
    }
}
