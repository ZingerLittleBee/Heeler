import Foundation

/// One multipart name with one or more values. Array values repeat the exact
/// name; brackets are never inferred from the number of values.
struct VoiceInputCustomField: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var values = [""]
}

/// Saved per preset/model or normalized Custom URL/model. Empty languages
/// mean automatic detection, independent of the device's preferred language.
struct VoiceInputRequestOptions: Codable, Equatable, Sendable {
    var languages: [String] = []
    var fields: [VoiceInputCustomField] = []
    /// Whether Keywords go to a service that bills them
    /// (`VoiceInputUploadFormat.optionalKeywords`). Off until the user turns
    /// it on; other services ignore it.
    var sendsKeywords = false

    enum Problem: Error, Equatable {
        case languagesUnavailable
        case singleLanguage
        case invalidLanguage
        case customOnly
        case invalidName
        case reservedName
        case duplicateName
        case missingValues
        case singleValue
        case conflictingLanguages

        var message: String {
            switch self {
            case .languagesUnavailable: String(localized: "Set language fields in Custom, or use automatic detection for this service.")
            case .singleLanguage: String(localized: "Choose one language, or use automatic detection for mixed speech.")
            case .invalidLanguage: String(localized: "Use language codes such as en, zh, or zh-tw, without duplicates.")
            case .customOnly: String(localized: "Additional request fields are only available for Custom services.")
            case .invalidName: String(localized: "Field names may contain ASCII letters, numbers, underscores, hyphens, dots, and a final [].")
            case .reservedName: String(localized: "File and model are supplied by Voice Input and cannot be overridden.")
            case .duplicateName: String(localized: "Use one entry per field name. Add values to that entry to repeat it.")
            case .missingValues: String(localized: "Each field needs at least one value. A value may be empty.")
            case .singleValue: String(localized: "Use one value for language, prompt, response_format, or stream, without brackets.")
            case .conflictingLanguages: String(localized: "Use language or languages, not both.")
            }
        }
    }

    func validate(for endpoint: VoiceInputEndpoint) throws(Problem) {
        switch endpoint.languageField {
        case .none:
            guard languages.isEmpty else { throw .languagesUnavailable }
        case .primary:
            guard languages.count <= 1 else { throw .singleLanguage }
        case .candidates:
            break
        }
        guard Set(languages).count == languages.count,
            languages.allSatisfy({ $0.range(of: #"^[a-z]{2,3}(-[a-z]{2})?\z"#, options: .regularExpression) != nil })
        else { throw .invalidLanguage }
        guard endpoint.source == .custom || fields.isEmpty else { throw .customOnly }
        var names = Set<String>()
        var languageFields = 0
        for field in fields {
            guard field.name.range(of: #"^[A-Za-z0-9_.-]+(\[\])?\z"#, options: .regularExpression) != nil else {
                throw .invalidName
            }
            let base = field.name.hasSuffix("[]") ? String(field.name.dropLast(2)) : field.name
            let folded = base.lowercased()
            guard !["file", "model"].contains(folded) else { throw .reservedName }
            guard names.insert(folded).inserted else { throw .duplicateName }
            guard !field.values.isEmpty else { throw .missingValues }
            if ["language", "prompt", "response_format", "stream"].contains(folded) {
                guard field.values.count == 1, !field.name.hasSuffix("[]") else { throw .singleValue }
            }
            if ["language", "languages"].contains(folded) { languageFields += 1 }
        }
        guard languageFields <= 1 else { throw .conflictingLanguages }
    }
}

extension VoiceInputRequestOptions {
    /// Options saved before `sendsKeywords` existed have no value for it, and
    /// one entry that fails to decode would drop every saved option.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languages = try container.decode([String].self, forKey: .languages)
        fields = try container.decode([VoiceInputCustomField].self, forKey: .fields)
        sendsKeywords = try container.decodeIfPresent(Bool.self, forKey: .sendsKeywords) ?? false
    }
}

enum VoiceInputLanguage {
    // Languages shared with Qwen3-ASR, using provider API codes (tl, not fil).
    // Hosted parameter behavior still needs vendor smoke tests.
    static let commonCodes = [
        "en", "zh", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi",
        "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "tl", "fa", "el", "hu", "mk", "ro",
    ]

    // ISO 639-3 codes in ElevenLabs' published Scribe language list.
    private static let scribeCodes = [
        "afr", "amh", "ara", "hye", "asm", "ast", "aze", "bel", "ben", "bos", "bul", "mya", "yue", "cat",
        "ceb", "nya", "hrv", "ces", "dan", "nld", "eng", "est", "fil", "fin", "fra", "ful", "glg", "lug",
        "kat", "deu", "ell", "guj", "hau", "heb", "hin", "hun", "isl", "ibo", "ind", "gle", "ita", "jpn",
        "jav", "kea", "kan", "kaz", "khm", "kor", "kur", "kir", "lao", "lav", "lin", "lit", "luo", "ltz",
        "mkd", "msa", "mal", "mlt", "zho", "mri", "mar", "mon", "nep", "nso", "nor", "oci", "ori", "pus",
        "fas", "pol", "por", "pan", "ron", "rus", "srp", "sna", "snd", "sin", "slk", "slv", "som", "spa",
        "swa", "swe", "tam", "tgk", "tel", "tha", "tur", "ukr", "umb", "urd", "uzb", "vie", "cym", "wol",
        "xho", "zul",
    ]

    static func choices(for preset: VoiceInputPreset) -> [String] {
        switch preset {
        case .openAI: commonCodes + ["zh-cn", "zh-tw", "zh-hk"]
        case .deepInfra: commonCodes
        case .elevenLabs: scribeCodes
        case .siliconFlowCN: []
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "zh-cn": String(localized: "Chinese (Mainland China)")
        case "zh-tw": String(localized: "Chinese (Taiwan)")
        case "zh-hk": String(localized: "Chinese (Hong Kong)")
        default: Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }

    /// Used only to freeze the old Custom Send Language setting on upgrade.
    static func legacyPrimary(preferredLanguages: [String]) -> String {
        for identifier in preferredLanguages {
            if let code = Locale.Language(identifier: identifier).languageCode?.identifier(.alpha2) {
                return code.lowercased()
            }
        }
        return "en"
    }
}
