import CryptoKit
import Foundation

/// A built-in speech service, including how recordings reach it and its
/// language hints.
enum VoiceInputPreset: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case deepInfra = "deepinfra"
    case elevenLabs = "elevenlabs"
    case siliconFlowCN = "siliconflow-cn"
    case volcengine = "volcengine"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepInfra: "DeepInfra"
        case .elevenLabs: "ElevenLabs"
        case .siliconFlowCN: String(localized: "SiliconFlow (China)")
        case .volcengine: String(localized: "Volcengine (China)")
        }
    }

    /// Who receives the recording, named in the consent.
    var operatorName: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepInfra: "DeepInfra"
        case .elevenLabs: "ElevenLabs"
        case .siliconFlowCN: "SiliconFlow"
        case .volcengine: "Volcengine"
        }
    }

    /// Volcengine names its model by the resource it bills, sent as
    /// `X-Api-Resource-Id`: Doubao streaming speech recognition 2.0.
    var model: String {
        switch self {
        case .openAI: "gpt-transcribe"
        case .elevenLabs: "scribe_v3"
        case .deepInfra, .siliconFlowCN: "Qwen/Qwen3-ASR-1.7B"
        case .volcengine: "volc.seedasr.sauc.duration"
        }
    }

    fileprivate var baseURLString: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .elevenLabs: "https://api.elevenlabs.io/v1"
        case .deepInfra: "https://api.deepinfra.com/v1/openai"
        case .siliconFlowCN: "https://api.siliconflow.cn/v1"
        case .volcengine: "https://openspeech.bytedance.com/api/v3/sauc"
        }
    }

    /// OpenAI and ElevenLabs accept several hints. DeepInfra accepts one language,
    /// whose effect on hosted Qwen3-ASR still needs a real-key smoke test.
    /// SiliconFlow documents neither field, so nothing is sent. Volcengine
    /// hears Mandarin, Chinese dialects and English, mixed, without a hint.
    var languageField: VoiceInputLanguageField {
        switch self {
        case .openAI: .candidates(first: "languages[]", additional: "languages[]")
        case .deepInfra: .primary
        case .elevenLabs: .candidates(first: "language_code", additional: "secondary_language_codes")
        case .siliconFlowCN, .volcengine: .none
        }
    }

    var wire: VoiceInputWire {
        switch self {
        case .openAI, .deepInfra, .siliconFlowCN: .upload(.openAI)
        case .elevenLabs: .upload(.scribe)
        case .volcengine: .volcengine
        }
    }

    /// `gpt-transcribe` reads `keywords`; it spelled listed terms from them
    /// but barely from `prompt` in testing. Volcengine takes them as
    /// hotwords, at no charge.
    var takesKeywords: Bool {
        self == .openAI || self == .volcengine
    }

    var acceptsPrompt: Bool {
        if case .upload(let format) = wire { format.acceptsPrompt } else { false }
    }

    /// Where Keywords go once the user turns them on, for a service that
    /// bills them.
    var optionalKeywords: VoiceInputOptionalKeywords? {
        if case .upload(let format) = wire { format.optionalKeywords } else { nil }
    }

    /// Volcengine streams by default and takes a finished recording too.
    var recognitionModes: [VoiceRecognitionMode] {
        self == .volcengine ? [.stream, .batch] : [.batch]
    }
}

/// How a recording reaches a service.
enum VoiceInputWire: Sendable {
    /// One multipart upload of the finished recording, in this shape.
    case upload(VoiceInputUploadFormat)
    /// Volcengine's binary WebSocket protocol (`VolcengineConnection`).
    case volcengine
}

/// How a service hears which languages to expect.
enum VoiceInputLanguageField: Equatable, Sendable {
    case none
    /// `language`: one explicitly selected language.
    case primary
    /// Field names for the first selected language and each additional hint.
    case candidates(first: String, additional: String)
}

/// The service owns these upload names. Custom always uses the OpenAI format.
struct VoiceInputUploadFormat: Sendable {
    let path: String
    let keyHeader: String
    let keyPrefix: String
    let modelField: String
    let acceptsPrompt: Bool
    let fixedFields: [(name: String, value: String)]
    /// Where Keywords go once the user turns them on, for a service that
    /// bills them; nil where there is no such field.
    let optionalKeywords: VoiceInputOptionalKeywords?

    static let openAI = Self(
        path: "audio/transcriptions", keyHeader: "Authorization", keyPrefix: "Bearer ",
        modelField: "model", acceptsPrompt: true, fixedFields: [], optionalKeywords: nil)
    static let scribe = Self(
        path: "speech-to-text", keyHeader: "xi-api-key", keyPrefix: "",
        modelField: "model_id", acceptsPrompt: false, fixedFields: [("tag_audio_events", "false")],
        optionalKeywords: .init(
            field: "keyterms", refusedCharacters: "<>{}[]\\", maxLength: 50, maxSpaces: 4, maxTerms: 1000))
}

/// A repeated form field for Keywords, with the limits the service puts on a
/// term. Scribe answers 400 to the whole request over one term outside them,
/// so `terms` leaves those out.
struct VoiceInputOptionalKeywords: Sendable {
    let field: String
    let refusedCharacters: String
    /// In Unicode scalars, the way the service counts.
    let maxLength: Int
    let maxSpaces: Int
    let maxTerms: Int

    func terms(from keywords: [String]) -> [String] {
        let terms = keywords.compactMap { keyword -> String? in
            let term = keyword.filter { !refusedCharacters.contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, term.unicodeScalars.count <= maxLength,
                term.count(where: { $0 == " " }) <= maxSpaces
            else { return nil }
            return term
        }
        return Array(terms.prefix(maxTerms))
    }
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
    /// Whether the service reads Keywords: `keywords[]` in an upload,
    /// hotwords on Volcengine.
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

    static func custom(baseURL: URL, model: String) -> VoiceInputEndpoint {
        VoiceInputEndpoint(
            source: .custom, baseURL: baseURL, model: model,
            languageField: .none, takesKeywords: false,
            sendsResponseFormat: true)
    }

    var wire: VoiceInputWire {
        switch source {
        case .preset(let preset): preset.wire
        case .custom: .upload(.openAI)
        }
    }

    /// The upload's shape and where it goes; nil for a service that takes
    /// no upload.
    var upload: (format: VoiceInputUploadFormat, url: URL)? {
        guard case .upload(let format) = wire else { return nil }
        return (format, baseURL.appending(path: format.path))
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
            case .empty: String(localized: "Enter the service's base URL.")
            case .invalid: String(localized: "Enter an https URL, such as https://api.example.com/v1.")
            case .notHTTPS: String(localized: "Voice Input only sends recordings and keys over https.")
            case .containsCredentials: String(localized: "Remove the user name or password from the URL.")
            case .containsQueryOrFragment: String(localized: "Remove the part after ? or # from the URL.")
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
