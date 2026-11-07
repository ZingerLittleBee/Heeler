import Foundation
import Synchronization
import Testing

@testable import Heeler

@MainActor
@Suite("Voice Input settings")
struct VoiceInputSettingsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "hm-voice-input-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func voiceInputStaysOffUntilAServiceIsSavedWithKeyAndAgreement() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(settings.service == nil)
            #expect(!settings.isReady)

            #expect(throws: VoiceInputSettings.SaveError.notConsented) {
                try settings.save(
                    service: .preset(.openAI), custom: .init(), apiKey: "sk-live", consented: false)
            }
            #expect(!settings.isReady)
            #expect(try secrets.read(account: "voice-preset-openai") == nil, "no key without agreement")

            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: " sk-live\n", consented: true)
            #expect(settings.isReady)
            let endpoint = try #require(settings.endpoint)
            #expect(settings.apiKey(for: endpoint) == "sk-live")

            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(reopened.service == .preset(.openAI))
            #expect(reopened.isReady)
        }
    }

    @Test func aBlankKeyKeepsTheSavedOneAndAMissingKeyIsRefused() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            #expect(throws: VoiceInputSettings.SaveError.missingKey) {
                try settings.save(service: .preset(.deepInfra), custom: .init(), apiKey: "", consented: true)
            }
            try settings.save(service: .preset(.deepInfra), custom: .init(), apiKey: "di-key", consented: true)
            try settings.save(service: .preset(.deepInfra), custom: .init(), apiKey: "  ", consented: false)
            let endpoint = try #require(settings.endpoint)
            #expect(settings.apiKey(for: endpoint) == "di-key")
        }
    }

    @Test func aKeyThatCouldBendTheHeaderIsRefused() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            #expect(throws: VoiceInputSettings.SaveError.invalidKey) {
                try settings.save(
                    service: .preset(.openAI), custom: .init(), apiKey: "sk-a\r\nX-Other: b", consented: true)
            }
            #expect(settings.service == nil)
        }
    }

    @Test func customNeedsAnHTTPSURLAndAModel() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            let insecure = VoiceInputCustomService(baseURL: "http://asr.example.com/v1", model: "whisper-1")
            #expect(throws: VoiceInputSettings.SaveError.invalidURL(.notHTTPS)) {
                try settings.save(service: .custom, custom: insecure, apiKey: "k", consented: true)
            }
            let modelless = VoiceInputCustomService(baseURL: "https://asr.example.com/v1", model: " ")
            #expect(throws: VoiceInputSettings.SaveError.missingModel) {
                try settings.save(service: .custom, custom: modelless, apiKey: "k", consented: true)
            }
        }
    }

    @Test func aNewCustomURLAsksAgainAndDropsTheOldURLsKey() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            let first = VoiceInputCustomService(
                baseURL: "https://a.example.com/v1/audio/transcriptions", model: "whisper-1")
            try settings.save(service: .custom, custom: first, apiKey: "key-a", consented: true)
            let firstEndpoint = try #require(settings.endpoint)
            #expect(settings.custom.baseURL == "https://a.example.com/v1", "saved normalized")

            let moved = VoiceInputCustomService(baseURL: "https://b.example.com/v1", model: "whisper-1")
            #expect(throws: VoiceInputSettings.SaveError.notConsented) {
                try settings.save(service: .custom, custom: moved, apiKey: "key-b", consented: false)
            }
            #expect(settings.apiKey(for: firstEndpoint) == "key-a", "a refused save changes nothing")

            try settings.save(service: .custom, custom: moved, apiKey: "key-b", consented: true)
            #expect(settings.apiKey(for: firstEndpoint) == nil)
            let movedEndpoint = try #require(settings.endpoint)
            #expect(settings.apiKey(for: movedEndpoint) == "key-b")
            #expect(settings.isReady)
        }
    }

    @Test func removingAKeyAlsoWithdrawsTheAgreement() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk", consented: true)
            let endpoint = try #require(settings.endpoint)
            try settings.removeKey(for: endpoint)
            #expect(!settings.hasKey(for: endpoint))
            #expect(!settings.hasConsent(for: endpoint))
            #expect(!settings.isReady)
        }
    }

    @Test func keywordsSplitAtSeparatorsAndLoseWhatOpenAIRefuses() {
        #expect(
            VoiceInputSettings.keywords(in: " herdr, Heeler，SwiftUI\n<PR>;git\r\n\nherdr、worktree ")
                == ["herdr", "Heeler", "SwiftUI", "PR", "git", "worktree"])
        #expect(VoiceInputSettings.keywords(in: " ,\n ").isEmpty)
    }

    @Test func aTypedKeyCannotFollowAServiceChangeIntoSave() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            var draft = VoiceInputServiceDraft(service: .preset(.openAI), custom: .init())
            draft.apiKey = "openai-key"
            draft.service = .preset(.deepInfra)
            #expect(draft.apiKey.isEmpty)
            #expect(throws: VoiceInputSettings.SaveError.missingKey) {
                try settings.save(
                    service: .preset(.deepInfra), custom: draft.custom, apiKey: draft.apiKey, consented: true)
            }
            draft.apiKey = "deepinfra-key"
            draft.service = nil
            draft.service = .preset(.deepInfra)
            #expect(draft.apiKey.isEmpty, "Off cannot carry a typed key back to a service")
        }
    }

    @Test func customURLEditsClearTheTypedKeyEvenBeforeTheURLIsValid() {
        var draft = VoiceInputServiceDraft(
            service: .custom,
            custom: .init(baseURL: "https://a.example.com/v1", model: "first"))
        draft.apiKey = "key-a"
        draft.custom.model = "second"
        #expect(draft.apiKey == "key-a", "models share the destination's key")
        draft.custom.baseURL = "https://"
        #expect(draft.apiKey.isEmpty)
        draft.custom.baseURL = "https://b.example.com/v1"
        #expect(draft.apiKey.isEmpty)
    }

    @Test func switchingServicesKeepsEachSavedKeyAtItsOwnDestination() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            try settings.save(service: .preset(.deepInfra), custom: .init(), apiKey: "di-key", consented: true)
            var draft = VoiceInputServiceDraft(service: .preset(.openAI), custom: .init())
            draft.apiKey = "openai-key"
            draft.service = .preset(.deepInfra)
            try settings.save(
                service: .preset(.deepInfra), custom: draft.custom, apiKey: draft.apiKey, consented: false)
            #expect(settings.apiKey(for: try #require(settings.endpoint)) == "di-key")
        }
    }

    @Test func aFailedKeyRemovalPreservesTheKeyAndAgreementUntilRetry() throws {
        try withDefaults { defaults in
            let secrets = RemovalFailingVoiceSecrets()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk", consented: true)
            let endpoint = try #require(settings.endpoint)
            let revision = settings.keyRevision
            #expect(throws: VoiceInputSettings.SaveError.keyRemoval) {
                try settings.removeKey(for: endpoint)
            }
            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(reopened.apiKey(for: endpoint) == "sk")
            #expect(reopened.hasConsent(for: endpoint))
            #expect(reopened.isReady)
            #expect(settings.keyRevision == revision)

            secrets.allowRemoval()
            try settings.removeKey(for: endpoint)
            #expect(!settings.hasKey(for: endpoint))
            #expect(!settings.hasConsent(for: endpoint))
        }
    }

    @Test func aCustomMoveWithFailedCleanupKeepsTheSavedDestinationUntilRetry() throws {
        try withDefaults { defaults in
            let secrets = RemovalFailingVoiceSecrets()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            let first = VoiceInputCustomService(baseURL: "https://a.example.com/v1", model: "asr")
            let moved = VoiceInputCustomService(baseURL: "https://b.example.com/v1", model: "asr")
            try settings.save(service: .custom, custom: first, apiKey: "key-a", consented: true)
            let firstEndpoint = try #require(settings.endpoint)
            let movedEndpoint = try #require(VoiceInputService.custom.endpoint(custom: moved))
            #expect(throws: VoiceInputSettings.SaveError.keyRemoval) {
                try settings.save(service: .custom, custom: moved, apiKey: "key-b", consented: true)
            }
            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(reopened.endpoint == firstEndpoint)
            #expect(reopened.apiKey(for: firstEndpoint) == "key-a")
            #expect(reopened.hasConsent(for: firstEndpoint))
            #expect(!reopened.hasConsent(for: movedEndpoint))

            secrets.allowRemoval()
            try settings.save(service: .custom, custom: moved, apiKey: "", consented: true)
            #expect(settings.endpoint == movedEndpoint)
            #expect(settings.apiKey(for: firstEndpoint) == nil)
            #expect(settings.apiKey(for: movedEndpoint) == "key-b")
            #expect(settings.isReady)
        }
    }

    @Test func onlyServicesThatDoNotReadKeywordsKeepThemInThePrompt() {
        let about = "Instructions to a coding agent"
        let terms = ["herdr", "Heeler"]
        let stale = "\(about)\nVocabulary: herdr"
        #expect(VoiceInputService.preset(.openAI).prompt(stale, keywords: terms) == stale)
        for service in [VoiceInputService.preset(.deepInfra), .preset(.siliconFlowCN), .custom] {
            #expect(service.prompt("", keywords: terms) == "Vocabulary: herdr, Heeler")
            #expect(service.prompt("\(about)\n\n", keywords: terms) == "\(about)\nVocabulary: herdr, Heeler")
            #expect(
                service.prompt("Vocabulary: git\n\(about)\n  Vocabulary: pnpm", keywords: terms)
                    == "Vocabulary: herdr, Heeler\n\(about)")
            #expect(service.prompt(stale, keywords: []) == about)
            #expect(service.prompt(about, keywords: []) == about)
        }
    }

    @Test func keywordsAndThePromptOutliveServiceChanges() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(settings.keywords.isEmpty)
            #expect(settings.prompt.isEmpty)
            settings.setKeywords(from: "herdr, Heeler")
            settings.setPrompt("  Instructions to a coding agent\n")
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk", consented: true)
            try settings.save(service: .preset(.siliconFlowCN), custom: .init(), apiKey: "sk", consented: true)
            settings.turnOff()

            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(reopened.keywords == ["herdr", "Heeler"])
            #expect(reopened.prompt == "Instructions to a coding agent")
        }
    }

    @Test func theDeviceMicrophoneChoiceStartsOffAndOutlivesTheService() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            #expect(!settings.alwaysUsesBuiltInMicrophone)

            settings.setAlwaysUsesBuiltInMicrophone(true)
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk", consented: true)
            settings.turnOff()
            #expect(VoiceInputSettings(defaults: defaults, secrets: secrets).alwaysUsesBuiltInMicrophone)
        }
    }

    @Test func languagesAreSavedPerServiceAndDraftEditsDoNotPersistUntilSave() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets, preferredLanguages: ["en-US"])
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk", consented: true,
                              options: .init(languages: ["zh", "en"]))
            var draft = VoiceInputServiceDraft(
                service: settings.service, custom: settings.custom, requestOptions: settings.requestOptions)
            draft.options.languages = ["ja"]
            let openAI = try #require(settings.endpoint)
            #expect(settings.options(for: openAI).languages == ["zh", "en"], "Cancel leaves the saved languages alone")
            draft.service = .preset(.deepInfra)
            #expect(draft.options.languages.isEmpty)
            draft.options.languages = ["fr"]
            draft.service = .preset(.openAI)
            #expect(draft.options.languages == ["ja"])
            try settings.save(service: .preset(.deepInfra), custom: .init(), apiKey: "di", consented: true,
                              options: .init(languages: ["fr"]))
            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets, preferredLanguages: ["de"])
            #expect(reopened.options(for: openAI).languages == ["zh", "en"])
            #expect(reopened.options(for: try #require(reopened.endpoint)).languages == ["fr"])
        }
    }

    @Test func customFieldsFollowOnlyTheirNormalizedURLAndModel() throws {
        try withDefaults { defaults in
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets)
            let custom = VoiceInputCustomService(baseURL: "https://a.example.com/v1", model: "asr")
            let options = VoiceInputRequestOptions(fields: [.init(name: "languages[]", values: ["zh", "en"])])
            try settings.save(service: .custom, custom: custom, apiKey: "key-a", consented: true, options: options)
            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets)
            var draft = VoiceInputServiceDraft(service: .custom, custom: custom, requestOptions: reopened.requestOptions)
            #expect(draft.options == options)
            draft.custom.baseURL = "https://A.example.com/v1/audio/transcriptions/"
            #expect(draft.options == options)
            draft.custom.model = "other"
            #expect(draft.options.fields.isEmpty)
            draft.custom.model = "asr"
            draft.custom.baseURL = "https://b.example.com/v1"
            #expect(draft.options.fields.isEmpty)
            draft.custom.baseURL = custom.baseURL
            #expect(draft.options == options)
        }
    }

    @Test func theLegacyCustomLanguageMigratesOnceEvenWhileOff() throws {
        try withDefaults { defaults in
            defaults.set("https://a.example.com/v1", forKey: "voice-input-custom-url")
            defaults.set("asr", forKey: "voice-input-custom-model")
            defaults.set(true, forKey: "voice-input-custom-language")
            let secrets = InMemorySecretStore()
            let settings = VoiceInputSettings(defaults: defaults, secrets: secrets, preferredLanguages: ["zh-Hans-CN"])
            let endpoint = try #require(VoiceInputService.custom.endpoint(custom: settings.custom))
            #expect(settings.service == nil)
            #expect(settings.options(for: endpoint).fields.map(\.name) == ["language"])
            #expect(settings.options(for: endpoint).fields.map(\.values) == [["zh"]])
            #expect(defaults.object(forKey: "voice-input-custom-language") == nil)
            let reopened = VoiceInputSettings(defaults: defaults, secrets: secrets, preferredLanguages: ["en-US"])
            #expect(reopened.options(for: endpoint).fields.map(\.values) == [["zh"]])
            try reopened.save(service: .custom, custom: reopened.custom, apiKey: "key", consented: true, options: .init())
            let cleared = VoiceInputSettings(defaults: defaults, secrets: secrets, preferredLanguages: ["fr"])
            #expect(cleared.options(for: endpoint).fields.isEmpty, "clearing the migration is permanent")
        }
    }

    @Test func invalidFieldsCannotSaveAKeyOrAgreement() throws {
        try withDefaults { defaults in
            let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
            let custom = VoiceInputCustomService(baseURL: "https://a.example.com", model: "asr")
            let endpoint = try #require(VoiceInputService.custom.endpoint(custom: custom))
            #expect(throws: VoiceInputSettings.SaveError.options(.reservedName)) {
                try settings.save(service: .custom, custom: custom, apiKey: "key", consented: true,
                                  options: .init(fields: [.init(name: "file", values: ["override"])]))
            }
            #expect(!settings.hasKey(for: endpoint))
            #expect(!settings.hasConsent(for: endpoint))
            #expect(settings.service == nil)
        }
    }

    @Test func requestValidationRejectsAmbiguousAndUnsafeFieldShapes() throws {
        let endpoint = VoiceInputEndpoint.custom(baseURL: try #require(URL(string: "https://a.example.com")), model: "asr")
        let cases: [([VoiceInputCustomField], VoiceInputRequestOptions.Problem)] = [
            ([.init(name: "model[]", values: ["other"])], .reservedName),
            ([.init(name: "file", values: ["other"])], .reservedName),
            ([.init(name: "name\n", values: ["x"])], .invalidName),
            ([.init(name: "name\"", values: ["x"])], .invalidName),
            ([.init(name: "", values: ["x"])], .invalidName),
            ([.init(name: "language", values: ["zh", "en"])], .singleValue),
            ([.init(name: "prompt[]", values: ["x"])], .singleValue),
            ([.init(name: "x", values: [])], .missingValues),
            ([.init(name: "x", values: ["a"]), .init(name: "x[]", values: ["b"])], .duplicateName),
            ([.init(name: "language", values: ["zh"]), .init(name: "languages[]", values: ["en"])], .conflictingLanguages),
        ]
        for (fields, problem) in cases {
            #expect(throws: problem) { try VoiceInputRequestOptions(fields: fields).validate(for: endpoint) }
        }
        try VoiceInputRequestOptions(fields: [.init(name: "prompt", values: [""])]).validate(for: endpoint)
        let openAI = try #require(VoiceInputEndpoint.preset(.openAI))
        #expect(throws: VoiceInputRequestOptions.Problem.invalidLanguage) {
            try VoiceInputRequestOptions(languages: ["en\n"]).validate(for: openAI)
        }
        #expect(throws: VoiceInputRequestOptions.Problem.customOnly) {
            try VoiceInputRequestOptions(fields: [.init(name: "x", values: ["y"])]).validate(for: openAI)
        }
        let siliconFlow = try #require(VoiceInputEndpoint.preset(.siliconFlowCN))
        #expect(throws: VoiceInputRequestOptions.Problem.languagesUnavailable) {
            try VoiceInputRequestOptions(languages: ["zh"]).validate(for: siliconFlow)
        }
    }
}

private final class RemovalFailingVoiceSecrets: SecretStore {
    private let stored = InMemorySecretStore()
    private let rejectsRemoval = Mutex(true)

    func allowRemoval() { rejectsRemoval.withLock { $0 = false } }
    func read(account: String) throws -> Data? { try stored.read(account: account) }
    func readAll() throws -> [String: Data] { try stored.readAll() }
    func write(_ secret: Data, account: String) throws { try stored.write(secret, account: account) }
    func removeSecret(account: String) throws {
        if rejectsRemoval.withLock({ $0 }) { throw KeychainError.unexpectedStatus(-1) }
        try stored.removeSecret(account: account)
    }
}
