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
            case .languagesUnavailable: "Set language fields in Custom, or use automatic detection for this service."
            case .singleLanguage: "Choose one language, or use automatic detection for mixed speech."
            case .invalidLanguage: "Use language codes such as en, zh, or zh-tw, without duplicates."
            case .customOnly: "Additional request fields are only available for Custom services."
            case .invalidName: "Field names may contain ASCII letters, numbers, underscores, hyphens, dots, and a final []."
            case .reservedName: "File and model are supplied by Voice Input and cannot be overridden."
            case .duplicateName: "Use one entry per field name. Add values to that entry to repeat it."
            case .missingValues: "Each field needs at least one value. A value may be empty."
            case .singleValue: "Use one value for language, prompt, response_format, or stream, without brackets."
            case .conflictingLanguages: "Use language or languages, not both."
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

enum VoiceInputLanguage {
    // Qwen3-ASR's model card lists these languages. Hosted parameter behavior
    // still needs vendor smoke tests; it is not established by that card.
    static let commonCodes = [
        "en", "zh", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi",
        "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
    ]

    static func choices(for preset: VoiceInputPreset) -> [String] {
        switch preset {
        case .openAI: commonCodes.map { $0 == "fil" ? "tl" : $0 } + ["zh-cn", "zh-tw", "zh-hk"]
        case .deepInfra: commonCodes
        case .siliconFlowCN: []
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "zh-cn": "Chinese (Mainland China)"
        case "zh-tw": "Chinese (Taiwan)"
        case "zh-hk": "Chinese (Hong Kong)"
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
