import CryptoKit
import Foundation

/// A built-in speech service. Each speaks the OpenAI `/audio/transcriptions`
/// shape, so one client serves all of them and Custom (ADR 0036).
enum VoiceInputPreset: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case deepInfra = "deepinfra"
    case siliconFlowCN = "siliconflow-cn"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepInfra: "DeepInfra"
        case .siliconFlowCN: "SiliconFlow (China)"
        }
    }

    /// Who receives the recording, named in the consent.
    var operatorName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepInfra: "DeepInfra"
        case .siliconFlowCN: "SiliconFlow"
        }
    }

    var model: String {
        switch self {
        case .openAI: "gpt-transcribe"
        case .deepInfra, .siliconFlowCN: "Qwen/Qwen3-ASR-1.7B"
        }
    }

    fileprivate var baseURLString: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepInfra: "https://api.deepinfra.com/v1/openai"
        case .siliconFlowCN: "https://api.siliconflow.cn/v1"
        }
    }

    /// `gpt-transcribe` takes the possible languages and rejects `language`
    /// beside them. Qwen3-ASR on DeepInfra takes one forced language, which
    /// matches how the owner's Mac setup runs it. SiliconFlow documents
    /// neither field, so nothing is sent.
    fileprivate var languageField: VoiceInputLanguageField {
        switch self {
        case .openAI: .candidates
        case .deepInfra: .primary
        case .siliconFlowCN: .none
        }
    }

    /// Only `gpt-transcribe` reads `keywords`; it spelled listed terms from
    /// them but barely from `prompt` in testing.
    fileprivate var takesKeywords: Bool {
        self == .openAI
    }
}

/// How a service hears which languages to expect.
enum VoiceInputLanguageField: Equatable, Sendable {
    case none
    /// `language`: the primary language only.
    case primary
    /// `languages[]`: the primary language, then English.
    case candidates
}

/// Where one recording goes and how the request is shaped.
struct VoiceInputEndpoint: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case preset(VoiceInputPreset)
        case custom
    }

    let source: Source
    /// Normalized: https, no trailing slash, no `/audio/transcriptions`.
    let baseURL: URL
    let model: String
    let languageField: VoiceInputLanguageField
    /// Whether Keywords go in `keywords[]`; elsewhere they join the prompt.
    let takesKeywords: Bool
    /// Custom servers get an explicit `response_format=json`; some require it.
    let sendsResponseFormat: Bool

    static func preset(_ preset: VoiceInputPreset) -> VoiceInputEndpoint? {
        guard case .success(let url) = VoiceInputCustomURL.normalize(preset.baseURLString) else {
            return nil
        }
        return VoiceInputEndpoint(
            source: .preset(preset), baseURL: url, model: preset.model,
            languageField: preset.languageField, takesKeywords: preset.takesKeywords,
            sendsResponseFormat: false)
    }

    static func custom(baseURL: URL, model: String, sendsLanguage: Bool) -> VoiceInputEndpoint {
        VoiceInputEndpoint(
            source: .custom, baseURL: baseURL, model: model,
            languageField: sendsLanguage ? .primary : .none, takesKeywords: false,
            sendsResponseFormat: true)
    }

    var transcriptionURL: URL {
        baseURL.appending(path: "audio/transcriptions")
    }

    var host: String {
        baseURL.host() ?? baseURL.absoluteString
    }

    /// The named operator for a preset; nil for Custom, whose operator
    /// Heeler cannot know.
    var operatorName: String? {
        switch source {
        case .preset(let preset): preset.operatorName
        case .custom: nil
        }
    }

    /// The Keychain account holding this endpoint's key. Custom derives it
    /// from the URL, so a key never follows an edited URL to another host.
    var keyAccount: String {
        switch source {
        case .preset(let preset): "voice-preset-\(preset.rawValue)"
        case .custom: "voice-custom-\(Self.digest(baseURL.absoluteString))"
        }
    }

    /// What one consent covers. A different URL or model on Custom is a
    /// different destination, so it asks again.
    var consentID: String {
        switch source {
        case .preset(let preset): "preset|\(preset.rawValue)|\(model)"
        case .custom: "custom|\(baseURL.absoluteString)|\(model)"
        }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Validates and normalizes a Custom base URL.
enum VoiceInputCustomURL {
    enum Problem: Error, Equatable {
        case empty
        case invalid
        case notHTTPS
        case containsCredentials
        case containsQueryOrFragment

        var message: String {
            switch self {
            case .empty: "Enter the service's base URL."
            case .invalid: "Enter an https URL, such as https://api.example.com/v1."
            case .notHTTPS: "Voice Input only sends recordings and keys over https."
            case .containsCredentials: "Remove the user name or password from the URL."
            case .containsQueryOrFragment: "Remove the part after ? or # from the URL."
            }
        }
    }

    private static let endpointSuffix = "/audio/transcriptions"

    /// Keeps the user's path, since `/v1` is not universal, and strips what
    /// people paste by accident: trailing slashes and the endpoint itself. A
    /// trailing slash matters: DeepInfra answers one with a redirect to
    /// plain http.
    static func normalize(_ raw: String) -> Result<URL, Problem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty
        else { return .failure(.invalid) }
        guard scheme == "https" else { return .failure(.notHTTPS) }
        guard components.user == nil, components.password == nil else {
            return .failure(.containsCredentials)
        }
        guard components.query == nil, components.fragment == nil else {
            return .failure(.containsQueryOrFragment)
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix(endpointSuffix) {
            path.removeLast(endpointSuffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = path
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }
}

/// The languages a recording is expected to hold. Until Voice Input has its
/// own language list, the primary comes from the system's first preferred
/// language, and English is the second.
enum VoiceInputLanguage {
    static func primary(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferredLanguages {
            if let code = Locale.Language(identifier: identifier).languageCode?.identifier(.alpha2) {
                return code.lowercased()
            }
        }
        return "en"
    }

    static func candidates(primary: String) -> [String] {
        primary == "en" ? ["en"] : [primary, "en"]
    }
}
