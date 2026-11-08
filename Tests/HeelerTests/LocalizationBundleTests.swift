import Foundation
import Testing

@testable import Heeler

/// The `.lproj` tables the String Catalogs compile into the app bundle.
enum LocalizationTables {
    /// Every language Heeler ships besides English, as its `.lproj` names it.
    /// A language added to the catalogs joins every test that iterates it.
    static let translations = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }.sorted()

    static func table(_ name: String, localization: String) -> [String: String]? {
        guard let path = Bundle.main.path(
            forResource: name, ofType: "strings", inDirectory: nil, forLocalization: localization)
        else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }
}

/// The compiled String Catalogs inside the app bundle.
///
/// These read the built `.lproj` tables directly, so they hold whichever
/// language the test host runs in.
@Suite("Localization bundle")
struct LocalizationBundleTests {
    private static let usageDescriptionKeys = [
        "NSCameraUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSLocalNetworkUsageDescription",
    ]

    @Test func theAppShipsTranslations() {
        #expect(!LocalizationTables.translations.isEmpty)
    }

    /// An InfoPlist catalog entry without an English value compiles to an
    /// English table that maps the key to its own name, which iOS then shows
    /// in the permission prompt instead of the purpose string. Unlike other
    /// text, a permission prompt is translated in every language Heeler ships.
    @Test func permissionPromptsShowTheirPurposeInEveryLanguage() throws {
        let english = LocalizationTables.table("InfoPlist", localization: "en") ?? [:]
        for key in Self.usageDescriptionKeys {
            let purpose = try #require(Bundle.main.infoDictionary?[key] as? String)
            #expect(purpose.hasPrefix("Heeler "), "\(key) in Info.plist")
            if let shown = english[key] {
                #expect(shown != key, "\(key) in en.lproj")
            }
            if let shown = Bundle.main.localizedInfoDictionary?[key] as? String {
                #expect(shown != key, "\(key) in the running localization")
            }
            for language in LocalizationTables.translations {
                let translated = LocalizationTables.table("InfoPlist", localization: language)?[key]
                #expect(
                    translated.map { $0 != key && $0 != purpose } == true,
                    "\(key) in \(language).lproj: \(translated ?? "missing")")
            }
        }
    }

    /// Format specifiers are checked in the catalog by
    /// `scripts/check-localizations.py`: the English of a
    /// `String(localized:defaultValue:)` key lives in code, never in a table.
    @Test(arguments: LocalizationTables.translations)
    func everyLanguageShipsItsTable(language: String) {
        #expect(LocalizationTables.table("Localizable", localization: language)?.isEmpty == false)
    }
}
