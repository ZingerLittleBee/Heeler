import Foundation
import Observation

/// Where Voice Input sends recordings: a built-in service or the user's own.
enum VoiceInputService: Hashable, Sendable, Identifiable {
    case preset(VoiceInputPreset)
    case custom

    static var allCases: [VoiceInputService] {
        VoiceInputPreset.allCases.map(VoiceInputService.preset) + [.custom]
    }

    var id: String { storageValue }

    var displayName: String {
        switch self {
        case .preset(let preset): preset.displayName
        case .custom: "Custom"
        }
    }

    var storageValue: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .custom: "custom"
        }
    }

    init?(storageValue: String) {
        if storageValue == "custom" {
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
    /// Off by default: servers that reject an unknown `language` are more
    /// common than ones that need it.
    var sendsLanguage = false
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

        var message: String {
            switch self {
            case .invalidURL(let problem): problem.message
            case .missingModel: "Enter the model name the service expects."
            case .missingKey: "Enter the service's API key."
            case .invalidKey: "Remove the spaces or line breaks from the key."
            case .notConsented: "Voice Input needs your agreement to send recordings."
            case .keychain: "The key could not be saved in the Keychain."
            }
        }
    }

    private enum Key {
        static let service = "voice-input-service"
        static let customURL = "voice-input-custom-url"
        static let customModel = "voice-input-custom-model"
        static let customLanguage = "voice-input-custom-language"
        static let consents = "voice-input-consents"
        static let builtInMicrophone = "voice-input-built-in-microphone"
    }

    /// Nil while Voice Input is off.
    private(set) var service: VoiceInputService?
    private(set) var custom: VoiceInputCustomService
    private(set) var consents: Set<String>
    /// Bumped by every key write, so views re-read `hasKey(for:)`.
    private(set) var keyRevision = 0
    /// Records from this device's own microphone even while AirPods that
    /// record in full bandwidth are connected. Off by default, and applied
    /// at once rather than on Save.
    private(set) var alwaysUsesBuiltInMicrophone: Bool

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainSecretStore(service: VoiceInputSettings.keychainService)
    ) {
        self.defaults = defaults
        self.secrets = secrets
        service = defaults.string(forKey: Key.service).flatMap(VoiceInputService.init(storageValue:))
        custom = VoiceInputCustomService(
            baseURL: defaults.string(forKey: Key.customURL) ?? "",
            model: defaults.string(forKey: Key.customModel) ?? "",
            sendsLanguage: defaults.bool(forKey: Key.customLanguage))
        consents = Set(defaults.stringArray(forKey: Key.consents) ?? [])
        alwaysUsesBuiltInMicrophone = defaults.bool(forKey: Key.builtInMicrophone)
    }

    /// The saved destination; nil while Voice Input is off.
    var endpoint: VoiceInputEndpoint? {
        service.flatMap { endpoint(for: $0, custom: custom) }
    }

    /// Whether a recording can go out now.
    var isReady: Bool {
        guard let endpoint else { return false }
        return hasKey(for: endpoint) && hasConsent(for: endpoint)
    }

    func endpoint(
        for service: VoiceInputService, custom: VoiceInputCustomService
    ) -> VoiceInputEndpoint? {
        switch service {
        case .preset(let preset):
            return .preset(preset)
        case .custom:
            let model = custom.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard case .success(let url) = VoiceInputCustomURL.normalize(custom.baseURL),
                !model.isEmpty
            else { return nil }
            return .custom(baseURL: url, model: model, sendsLanguage: custom.sendsLanguage)
        }
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
        service: VoiceInputService, custom: VoiceInputCustomService, apiKey: String
    ) -> Result<VoiceInputEndpoint, SaveError> {
        if case .custom = service {
            if case .failure(let problem) = VoiceInputCustomURL.normalize(custom.baseURL) {
                return .failure(.invalidURL(problem))
            }
            if custom.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure(.missingModel)
            }
        }
        guard let endpoint = endpoint(for: service, custom: custom) else {
            return .failure(.invalidURL(.invalid))
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
        consented: Bool
    ) throws(SaveError) {
        let endpoint: VoiceInputEndpoint
        switch validate(service: service, custom: custom, apiKey: apiKey) {
        case .success(let validated): endpoint = validated
        case .failure(let error): throw error
        }
        guard consented || hasConsent(for: endpoint) else { throw .notConsented }
        let key = Self.trimmedKey(apiKey)
        if !key.isEmpty {
            do {
                try secrets.write(Data(key.utf8), account: endpoint.keyAccount)
            } catch {
                throw .keychain
            }
        }
        if case .custom = service, let previous = self.endpoint(for: .custom, custom: self.custom),
            previous.keyAccount != endpoint.keyAccount
        {
            try? secrets.removeSecret(account: previous.keyAccount)
        }
        if consented { consents.insert(endpoint.consentID) }
        self.service = service
        if case .custom = service {
            self.custom = VoiceInputCustomService(
                baseURL: endpoint.baseURL.absoluteString, model: endpoint.model,
                sendsLanguage: custom.sendsLanguage)
        }
        keyRevision += 1
        persist()
    }

    func setAlwaysUsesBuiltInMicrophone(_ isOn: Bool) {
        alwaysUsesBuiltInMicrophone = isOn
        defaults.set(isOn, forKey: Key.builtInMicrophone)
    }

    /// Voice Input off. Keys stay until removed.
    func turnOff() {
        service = nil
        persist()
    }

    /// Deletes the key and the agreement for `endpoint`.
    func removeKey(for endpoint: VoiceInputEndpoint) {
        try? secrets.removeSecret(account: endpoint.keyAccount)
        consents.remove(endpoint.consentID)
        keyRevision += 1
        persist()
    }

    private func persist() {
        defaults.set(service?.storageValue, forKey: Key.service)
        defaults.set(custom.baseURL, forKey: Key.customURL)
        defaults.set(custom.model, forKey: Key.customModel)
        defaults.set(custom.sendsLanguage, forKey: Key.customLanguage)
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
