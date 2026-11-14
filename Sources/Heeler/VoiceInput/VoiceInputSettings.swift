import Foundation
import Observation

/// Where Voice Input turns speech into text: this device, a built-in
/// service, or the user's own.
enum VoiceInputService: Hashable, Sendable, Identifiable {
    /// Apple's dictation model on this device, from iOS 26 (ADR 0043).
    case onDevice
    case preset(VoiceInputPreset)
    case custom

    static var allCases: [VoiceInputService] {
        var cases = VoiceInputPreset.allCases.map(VoiceInputService.preset) + [.custom]
        if #available(iOS 26.0, *) { cases.insert(.onDevice, at: 0) }
        return cases
    }

    var id: String { storageValue }

    var displayName: String {
        switch self {
        case .onDevice: String(localized: "On Device", comment: "Voice Input service: speech recognition on this device")
        case .preset(let preset): preset.displayName
        case .custom: String(localized: "Custom", comment: "Voice Input service: a service the user configures")
        }
    }

    var storageValue: String {
        switch self {
        case .onDevice: "on-device"
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
    }

    /// Where recordings are uploaded; nil on this device, or while Custom
    /// is incomplete.
    func endpoint(custom: VoiceInputCustomService) -> VoiceInputEndpoint? {
        switch self {
        case .onDevice: return nil
        case .preset(let preset): return .preset(preset)
        case .custom:
            if case .success(let url) = VoiceInputCustomURL.normalize(custom.baseURL) {
                let model = custom.model.trimmingCharacters(in: .whitespacesAndNewlines)
                return model.isEmpty ? nil : .custom(baseURL: url, model: model)
            }
            return nil
        }
    }

    /// Whether the service reads Keywords on their own. The others hear
    /// them only through the Prompt.
    var takesKeywords: Bool {
        switch self {
        case .onDevice: true
        case .preset(let preset): preset.takesKeywords
        case .custom: false
        }
    }

    /// `prompt` as it should read with `keywords`. Where the service reads
    /// Keywords itself it is unchanged; elsewhere its `Vocabulary:` line,
    /// the form Qwen3-ASR's model card gives, is rewritten in place, added
    /// at the end, or removed when there are no terms.
    func prompt(_ prompt: String, keywords: [String]) -> String {
        guard !takesKeywords else { return prompt }
        let isVocabulary = { (line: String) in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(Self.vocabularyLabel)
        }
        var lines = prompt.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        let place = lines.firstIndex(where: isVocabulary)
        lines.removeAll(where: isVocabulary)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        if !keywords.isEmpty {
            let line = Self.vocabularyLabel + " " + keywords.joined(separator: ", ")
            lines.insert(line, at: min(place ?? lines.count, lines.count))
        }
        return lines.joined(separator: "\n")
    }

    private static let vocabularyLabel = "Vocabulary:"

    init?(storageValue: String) {
        if storageValue == "on-device" {
            self = .onDevice
        } else if storageValue == "custom" {
            self = .custom
        } else if let preset = VoiceInputPreset(rawValue: storageValue) {
            self = .preset(preset)
        } else {
            return nil
        }
    }
}

/// Custom's fields as the user typed them.
struct VoiceInputCustomService: Equatable, Sendable {
    var baseURL = ""
    var model = ""
}

/// Unsaved connection fields. A typed key belongs only to the destination
/// being edited, including while a Custom URL is incomplete.
struct VoiceInputServiceDraft {
    var service: VoiceInputService? {
        didSet {
            if service != oldValue { apiKey = "" }
        }
    }
    var custom: VoiceInputCustomService {
        didSet {
            if custom.baseURL != oldValue.baseURL { apiKey = "" }
        }
    }
    var apiKey = ""
    var requestOptions: [String: VoiceInputRequestOptions] = [:]

    var endpoint: VoiceInputEndpoint? { service?.endpoint(custom: custom) }

    var options: VoiceInputRequestOptions {
        get { endpoint.flatMap { requestOptions[$0.consentID] } ?? .init() }
        set {
            guard let endpoint else { return }
            requestOptions[endpoint.consentID] = newValue
        }
    }
}

/// Voice Input's service, its keys, and what the user agreed to (ADR 0036).
/// Keys live in the Keychain, one per preset and one per Custom URL; the
/// rest is in user defaults. Voice Input stays off until a service is saved
/// with a key and the user has agreed to send recordings to it.
@MainActor
@Observable
final class VoiceInputSettings {
    static let keychainService = "dev.bybee.heeler.voice"

    enum SaveError: Error, Equatable {
        case invalidURL(VoiceInputCustomURL.Problem)
        case missingModel
        case missingKey
        case invalidKey
        case notConsented
        case keychain
        case keyRemoval
        case options(VoiceInputRequestOptions.Problem)
        case optionsStorage

        var message: String {
            switch self {
            case .options(let problem): problem.message
            case .optionsStorage: String(localized: "The request settings could not be saved.")
            case .invalidURL(let problem): problem.message
            case .missingModel: String(localized: "Enter the model name the service expects.")
            case .missingKey: String(localized: "Enter the service's API key.")
            case .invalidKey: String(localized: "Remove the spaces or line breaks from the key.")
            case .notConsented: String(localized: "Voice Input needs your agreement to send recordings.")
            case .keychain: String(localized: "The key could not be saved in the Keychain.")
            case .keyRemoval: String(localized: "The key could not be removed from the Keychain. Try again.")
            }
        }
    }

    private enum Key {
        static let service = "voice-input-service"
        static let customURL = "voice-input-custom-url"
        static let customModel = "voice-input-custom-model"
        static let customLanguage = "voice-input-custom-language"
        static let requestOptions = "voice-input-request-options-v1"
        static let consents = "voice-input-consents"
        static let builtInMicrophone = "voice-input-built-in-microphone"
        static let keywords = "voice-input-keywords"
        static let prompt = "voice-input-prompt"
        static let onDeviceLanguage = "voice-input-on-device-language"
    }

    /// Nil while Voice Input is off.
    private(set) var service: VoiceInputService?
    private(set) var custom: VoiceInputCustomService
    private(set) var consents: Set<String>
    private(set) var requestOptions: [String: VoiceInputRequestOptions]
    /// Bumped by every key write, so views re-read `hasKey(for:)`.
    private(set) var keyRevision = 0
    /// Records from this device's own microphone even while AirPods that
    /// record in full bandwidth are connected. Off by default, and applied
    /// at once rather than on Save.
    private(set) var alwaysUsesBuiltInMicrophone: Bool
    /// Names and terms the user says, sent with each recording so the
    /// service spells them. One list for every service.
    private(set) var keywords: [String]
    /// What recordings are about, sent with each one. One for every
    /// service; empty when unset.
    private(set) var prompt: String
    /// The language On Device listens for, as a BCP 47 identifier: one per
    /// recording, with English words inside it. The device's first
    /// preferred language until the user picks one.
    private(set) var onDeviceLanguage: String

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: VoiceInputSettings.keychainService),
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults
        self.secrets = secrets
        service = defaults.string(forKey: Key.service).flatMap(VoiceInputService.init(storageValue:))
        custom = VoiceInputCustomService(
            baseURL: defaults.string(forKey: Key.customURL) ?? "",
            model: defaults.string(forKey: Key.customModel) ?? "")
        requestOptions = defaults.data(forKey: Key.requestOptions)
            .flatMap { try? JSONDecoder().decode([String: VoiceInputRequestOptions].self, from: $0) } ?? [:]
        consents = Set(defaults.stringArray(forKey: Key.consents) ?? [])
        alwaysUsesBuiltInMicrophone = defaults.bool(forKey: Key.builtInMicrophone)
        keywords = defaults.stringArray(forKey: Key.keywords) ?? []
        prompt = defaults.string(forKey: Key.prompt) ?? ""
        onDeviceLanguage = defaults.string(forKey: Key.onDeviceLanguage)
            ?? preferredLanguages.first ?? "en-US"
        // Migrate the legacy toggle once, even while the Custom service is off.
        if defaults.object(forKey: Key.requestOptions) == nil {
            if defaults.bool(forKey: Key.customLanguage), let endpoint = VoiceInputService.custom.endpoint(custom: custom) {
                requestOptions[endpoint.consentID] = .init(fields: [
                    .init(name: "language", values: [VoiceInputLanguage.legacyPrimary(preferredLanguages: preferredLanguages)])
                ])
            }
            if let data = try? JSONEncoder().encode(requestOptions) {
                defaults.set(data, forKey: Key.requestOptions)
                defaults.removeObject(forKey: Key.customLanguage)
            }
        }
    }

    /// The saved destination; nil while Voice Input is off.
    var endpoint: VoiceInputEndpoint? {
        service?.endpoint(custom: custom)
    }

    /// Whether a recording can be transcribed now. On Device needs no key
    /// or agreement; whether its model is installed is checked as a
    /// recording starts.
    var isReady: Bool {
        if service == .onDevice { return true }
        guard let endpoint else { return false }
        return hasKey(for: endpoint) && hasConsent(for: endpoint)
    }

    func options(for endpoint: VoiceInputEndpoint) -> VoiceInputRequestOptions {
        requestOptions[endpoint.consentID] ?? .init()
    }

    func hasKey(for endpoint: VoiceInputEndpoint) -> Bool {
        _ = keyRevision
        return apiKey(for: endpoint) != nil
    }

    func apiKey(for endpoint: VoiceInputEndpoint) -> String? {
        guard let data = try? secrets.read(account: endpoint.keyAccount),
            let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    func hasConsent(for endpoint: VoiceInputEndpoint) -> Bool {
        consents.contains(endpoint.consentID)
    }

    /// Checks the form without saving it. A blank key keeps the stored one.
    func validate(
        service: VoiceInputService, custom: VoiceInputCustomService, apiKey: String,
        options: VoiceInputRequestOptions? = nil
    ) -> Result<VoiceInputEndpoint, SaveError> {
        if case .custom = service {
            if case .failure(let problem) = VoiceInputCustomURL.normalize(custom.baseURL) {
                return .failure(.invalidURL(problem))
            }
            if custom.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.missingModel)
            }
        }
        guard let endpoint = service.endpoint(custom: custom) else {
            return .failure(.invalidURL(.invalid))
        }
        do {
            try (options ?? self.options(for: endpoint)).validate(for: endpoint)
        } catch {
            return .failure(.options(error))
        }
        let key = Self.trimmedKey(apiKey)
        if key.isEmpty {
            return hasKey(for: endpoint) ? .success(endpoint) : .failure(.missingKey)
        }
        guard Self.isWellFormedKey(key) else { return .failure(.invalidKey) }
        return .success(endpoint)
    }

    /// Saves the form and turns Voice Input on. `consented` records the
    /// user's agreement for this endpoint; without it, one given earlier
    /// must already exist. A Custom URL that changed drops the old URL's key.
    func save(
        service: VoiceInputService,
        custom: VoiceInputCustomService,
        apiKey: String,
        consented: Bool,
        options: VoiceInputRequestOptions? = nil
    ) throws(SaveError) {
        let endpoint: VoiceInputEndpoint
        switch validate(service: service, custom: custom, apiKey: apiKey, options: options) {
        case .success(let validated): endpoint = validated
        case .failure(let error): throw error
        }
        guard consented || hasConsent(for: endpoint) else { throw .notConsented }
        var updatedOptions = requestOptions
        updatedOptions[endpoint.consentID] = options ?? self.options(for: endpoint)
        let optionsData: Data
        do { optionsData = try JSONEncoder().encode(updatedOptions) } catch { throw .optionsStorage }
        let key = Self.trimmedKey(apiKey)
        if !key.isEmpty {
            do {
                try secrets.write(Data(key.utf8), account: endpoint.keyAccount)
            } catch {
                throw .keychain
            }
        }
        if case .custom = service, let previous = VoiceInputService.custom.endpoint(custom: self.custom),
            previous.keyAccount != endpoint.keyAccount
        {
            do {
                try secrets.removeSecret(account: previous.keyAccount)
            } catch {
                // Keep the saved destination and its agreement unchanged.
                // The new key remains available in the form for a retry.
                throw .keyRemoval
            }
        }
        if consented { consents.insert(endpoint.consentID) }
        self.service = service
        if case .custom = service {
            self.custom = VoiceInputCustomService(
                baseURL: endpoint.baseURL.absoluteString, model: endpoint.model)
        }
        requestOptions = updatedOptions
        defaults.set(optionsData, forKey: Key.requestOptions)
        keyRevision += 1
        persist()
    }

    /// Turns On Device on, listening for `language`. Nothing leaves the
    /// device, so there is no key or agreement.
    func saveOnDevice(language: String) {
        service = .onDevice
        onDeviceLanguage = language
        defaults.set(language, forKey: Key.onDeviceLanguage)
        persist()
    }

    func setAlwaysUsesBuiltInMicrophone(_ isOn: Bool) {
        alwaysUsesBuiltInMicrophone = isOn
        defaults.set(isOn, forKey: Key.builtInMicrophone)
    }

    /// Keeps the terms in `text`, as the Keywords field holds them.
    func setKeywords(from text: String) {
        keywords = Self.keywords(in: text)
        defaults.set(keywords, forKey: Key.keywords)
    }

    func setPrompt(_ text: String) {
        prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(prompt, forKey: Key.prompt)
    }

    /// Terms split at commas, semicolons, and line breaks, in either width.
    /// `<` and `>` are dropped: OpenAI refuses a whole request over them.
    static func keywords(in text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\u{3001}\u{FF0C}\u{FF1B}").union(.newlines)
        var seen = Set<String>()
        return text.components(separatedBy: separators).compactMap { part in
            let term = part.filter { $0 != "<" && $0 != ">" }
                .trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
        }
    }

    /// Voice Input off. Keys stay until removed.
    func turnOff() {
        service = nil
        persist()
    }

    /// Deletes the key and the agreement for `endpoint`.
    func removeKey(for endpoint: VoiceInputEndpoint) throws(SaveError) {
        do {
            try secrets.removeSecret(account: endpoint.keyAccount)
        } catch {
            throw .keyRemoval
        }
        consents.remove(endpoint.consentID)
        keyRevision += 1
        persist()
    }

    private func persist() {
        defaults.set(service?.storageValue, forKey: Key.service)
        defaults.set(custom.baseURL, forKey: Key.customURL)
        defaults.set(custom.model, forKey: Key.customModel)
        defaults.set(consents.sorted(), forKey: Key.consents)
    }

    private static func trimmedKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A key goes into an HTTP header, so nothing that could end or bend it.
    private static func isWellFormedKey(_ key: String) -> Bool {
        key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }
    }
}
