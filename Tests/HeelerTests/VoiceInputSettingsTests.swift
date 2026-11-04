import Foundation
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
            settings.removeKey(for: endpoint)
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
}
