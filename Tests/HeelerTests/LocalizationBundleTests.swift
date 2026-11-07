import Foundation
import Testing

@testable import Heeler

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

    private static func table(_ name: String, localization: String) -> [String: String]? {
        guard let path = Bundle.main.path(
            forResource: name, ofType: "strings", inDirectory: nil, forLocalization: localization)
        else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    /// An InfoPlist catalog entry without an English value compiles to an
    /// English table that maps the key to its own name, which iOS then shows
    /// in the permission prompt instead of the purpose string.
    @Test func permissionPromptsShowTheirPurposeInEveryLanguage() throws {
        let english = Self.table("InfoPlist", localization: "en") ?? [:]
        let japanese = try #require(Self.table("InfoPlist", localization: "ja"))
        for key in Self.usageDescriptionKeys {
            let purpose = try #require(Bundle.main.infoDictionary?[key] as? String)
            #expect(purpose.hasPrefix("Heeler "), "\(key) in Info.plist")
            if let shown = english[key] {
                #expect(shown != key, "\(key) in en.lproj")
            }
            if let shown = Bundle.main.localizedInfoDictionary?[key] as? String {
                #expect(shown != key, "\(key) in the running localization")
            }
            let translated = try #require(japanese[key], "\(key) in ja.lproj")
            #expect(translated != key && translated != purpose)
        }
    }

    /// A translation that drops, adds or retypes a format specifier garbles
    /// the text or crashes when the value is formatted.
    @Test func japaneseTranslationsKeepTheFormatSpecifiersOfTheirKey() throws {
        let japanese = try #require(Self.table("Localizable", localization: "ja"))
        #expect(!japanese.isEmpty)
        let mismatches = japanese.compactMap { key, value -> String? in
            Self.specifiersMatch(key: key, value: value) ? nil : "\(key) => \(value)"
        }
        #expect(mismatches.isEmpty, "\(mismatches.sorted().joined(separator: "\n"))")
    }

    private static let specifier = try? NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+0#']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])"#)

    /// Specifiers in order as (position, type); a literal `%%` is ignored.
    private static func specifiers(in text: String) -> [(position: Int?, type: String)] {
        let text = text.replacingOccurrences(of: "%%", with: "")
        let range = NSRange(text.startIndex..., in: text)
        return (specifier?.matches(in: text, range: range) ?? []).map { match in
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return (Int(group(1)), group(2) + group(3))
        }
    }

    private static func specifiersMatch(key: String, value: String) -> Bool {
        let expected = specifiers(in: key).map(\.type)
        let found = specifiers(in: value)
        guard found.contains(where: { $0.position != nil }) else {
            return found.map(\.type) == expected
        }
        // Positional forms let the translation reorder arguments; each
        // argument must still appear exactly once with its key's type.
        let positions = found.compactMap(\.position)
        guard !expected.isEmpty, positions.count == found.count,
              positions.sorted() == Array(1...expected.count)
        else { return false }
        return found.allSatisfy { item in
            guard let position = item.position, expected.indices.contains(position - 1) else { return false }
            return expected[position - 1] == item.type
        }
    }
}
