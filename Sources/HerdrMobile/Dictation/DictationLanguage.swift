import Foundation

/// A user-selectable Dictation language. v1 ships Simplified Chinese (the
/// default) and English; extending the offer is a one-line change to `all`.
///
/// `id` is a stable BCP-47 tag used for UserDefaults persistence and as the
/// requested locale. It is deliberately never compared against a raw `Locale`
/// to decide on-device support: the Speech framework canonicalizes locales in
/// ways that make identity comparison unreliable, so support is resolved
/// through the engine's supported-locale equivalence lookup instead (ADR 0003).
struct DictationLanguage: Identifiable, Sendable, Hashable {
    /// BCP-47 tag, e.g. `zh-CN` / `en-US`. Persisted, and used to build the
    /// requested `Locale` the engine resolves against on-device support.
    let id: String
    /// The language shown in its own script (endonym), matching how iOS lists
    /// languages in system Settings.
    let displayName: String

    /// The requested locale handed to the engine, which resolves it to an
    /// on-device-supported locale via equivalence lookup — never compared for
    /// identity (ADR 0003).
    var locale: Locale { Locale(identifier: id) }

    static let simplifiedChinese = DictationLanguage(id: "zh-CN", displayName: "简体中文")
    static let english = DictationLanguage(id: "en-US", displayName: "English")

    /// The languages offered in Settings, in display order. The first entry is
    /// the default. Extending Dictation to another language is a one-line
    /// addition here (plus its on-device model).
    static let all: [DictationLanguage] = [.simplifiedChinese, .english]

    /// The selection used when nothing is persisted yet (Simplified Chinese).
    static var `default`: DictationLanguage { all[0] }

    /// The offered language for a persisted id, or `nil` if the id is unknown
    /// (e.g. a language dropped from a later build).
    static func language(forID id: String?) -> DictationLanguage? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

/// On-device availability of a language's speech model, resolved by the engine
/// through the Speech framework's equivalence lookup. The Settings store maps
/// this to its user-facing model state; stores and UI never touch Speech types.
enum DictationModelStatus: Sendable, Equatable {
    /// No on-device support for the language. Also what the Simulator and CI
    /// report for every locale (ADR 0003).
    case unsupported
    /// Supported, but the language model is not downloaded yet.
    case notInstalled
    /// The model is installed and ready to transcribe.
    case installed
}
