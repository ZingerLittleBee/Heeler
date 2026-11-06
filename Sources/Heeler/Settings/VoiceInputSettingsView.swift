import SwiftUI

/// Settings › Voice Input, and the sheet the Composer's mic opens before
/// setup. The service, its key, the Keywords, and the Prompt change only on
/// Save, which asks once per destination before recordings may go to it
/// (ADR 0036); the microphone choice applies at once. Keywords and the Prompt
/// stay the same whichever service is chosen, except that a service which
/// doesn't read Keywords keeps them on the Prompt's Vocabulary line, updated
/// as Keywords change or the service becomes one of those.
struct VoiceInputSettingsView: View {
    let settings: VoiceInputSettings
    /// The mic's sheet has Cancel; pushed from Settings, Back does it.
    var isSheet = false
    @State private var connection: VoiceInputServiceDraft
    @State private var keywords: String
    @State private var prompt: String
    @State private var consentRequest: VoiceInputEndpoint?
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(settings: VoiceInputSettings, isSheet: Bool = false) {
        self.settings = settings
        self.isSheet = isSheet
        _connection = State(initialValue: VoiceInputServiceDraft(service: settings.service, custom: settings.custom))
        _keywords = State(initialValue: settings.keywords.joined(separator: ", "))
        _prompt = State(initialValue: settings.prompt)
    }

    var body: some View {
        Form {
            Section {
                Picker("Service", selection: $connection.service) {
                    Text("Off").tag(VoiceInputService?.none)
                    ForEach(VoiceInputService.allCases) { @Sendable service in
                        Text(service.displayName).tag(VoiceInputService?.some(service))
                    }
                }
            } footer: {
                Text(serviceFooter)
            }
            switch connection.service {
            case .preset(let preset):
                Section {
                    LabeledContent("Model", value: preset.model)
                }
                keySection
            case .custom:
                customSection
                keySection
            case nil:
                EmptyView()
            }
            if connection.service != nil {
                keywordsSection
                promptSection
                if #available(iOS 26.0, *) {
                    microphoneSection
                }
            }
        }
        .onChange(of: keywords) { syncVocabulary() }
        .onChange(of: connection.service) { syncVocabulary() }
        .navigationTitle("Voice Input")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: requestSave)
                    .disabled(!canSave)
            }
        }
        .alert(
            consentRequest.map(Self.consentTitle) ?? "",
            isPresented: Binding(
                get: { consentRequest != nil },
                set: { if !$0 { consentRequest = nil } }),
            presenting: consentRequest
        ) { _ in
            Button("Send Recordings") { save(consented: true) }
            Button("Cancel", role: .cancel) {}
        } message: { endpoint in
            Text(Self.consentMessage(endpoint))
        }
        .alert(
            "Could not update Voice Input",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var customSection: some View {
        Section {
            VoiceInputFormField(
                title: "Base URL", prompt: "https://api.example.com/v1", text: $connection.custom.baseURL,
                keyboard: .URL)
            VoiceInputFormField(title: "Model", prompt: "Required", text: $connection.custom.model)
            Toggle("Send Language", isOn: $connection.custom.sendsLanguage)
        } footer: {
            Text(
                "For services that take OpenAI's audio/transcriptions request. Send Language adds "
                    + "your first preferred language; leave it off if the service rejects it.")
        }
    }

    private var keySection: some View {
        Section {
            SecureField(hasStoredKey ? "Saved; enter a new key to replace it" : "Required", text: $connection.apiKey)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("API Key")
            if let endpoint = draftEndpoint, hasStoredKey {
                Button("Remove Key", role: .destructive) {
                    removeKey(for: endpoint)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Kept in this device's Keychain and sent only with recordings to \(draftHost).")
        }
    }

    private var keywordsSection: some View {
        Section {
            TextField(
                "Keywords", text: $keywords,
                prompt: Text(verbatim: "herdr, Claude Code, Codex, pnpm, SwiftUI"), axis: .vertical)
                .lineLimit(2...6)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Keywords")
        } footer: {
            Text("Names and terms you say, separated by commas, so the service spells them right.")
        }
    }

    private var promptSection: some View {
        Section {
            TextField(
                "Prompt", text: $prompt,
                prompt: Text("Instructions dictated to a coding agent"), axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text("Prompt")
        } footer: {
            if connection.service?.takesKeywords == false {
                Text(
                    "What you talk about, sent as written. This service doesn't read Keywords, "
                        + "so they're added here.")
            } else {
                Text("What you talk about, sent as written.")
            }
        }
    }

    private func syncVocabulary() {
        guard let service = connection.service else { return }
        prompt = service.prompt(prompt, keywords: VoiceInputSettings.keywords(in: keywords))
    }

    /// Only AirPods with high-quality recording, from iOS 26, are ever
    /// chosen over this device's microphone, so earlier systems have no
    /// choice to make.
    private var microphoneSection: some View {
        Section {
            Toggle(
                "Always Use \(UIDevice.current.model) Microphone",
                isOn: Binding(
                    get: { settings.alwaysUsesBuiltInMicrophone },
                    set: { settings.setAlwaysUsesBuiltInMicrophone($0) }))
        } footer: {
            Text("Otherwise, connected AirPods record when they support high-quality recording.")
        }
    }

    private var serviceFooter: String {
        switch connection.service {
        case .preset(let preset):
            "Recordings go to \(preset.operatorName) under its terms, billed to your key. "
                + "Heeler's developer receives none of them."
        case .custom:
            "Recordings go to the URL you enter, under the terms of whoever runs it."
        case nil:
            "Voice Input turns speech into Composer text through a speech service you choose, "
                + "with your own API key."
        }
    }

    private var draftEndpoint: VoiceInputEndpoint? {
        connection.service.flatMap { settings.endpoint(for: $0, custom: connection.custom) }
    }

    private var draftHost: String {
        draftEndpoint?.host ?? "the service"
    }

    private var hasStoredKey: Bool {
        draftEndpoint.map(settings.hasKey(for:)) ?? false
    }

    private func removeKey(for endpoint: VoiceInputEndpoint) {
        do {
            try settings.removeKey(for: endpoint)
            if settings.service == connection.service, !settings.hasKey(for: endpoint) {
                settings.turnOff()
            }
        } catch {
            saveError = error.message
        }
    }

    private var canSave: Bool {
        guard let service = connection.service else { return settings.service != nil }
        if case .success = settings.validate(service: service, custom: connection.custom, apiKey: connection.apiKey) {
            return true
        }
        return false
    }

    private func requestSave() {
        guard let service = connection.service else {
            settings.turnOff()
            dismiss()
            return
        }
        switch settings.validate(service: service, custom: connection.custom, apiKey: connection.apiKey) {
        case .failure(let error):
            saveError = error.message
        case .success(let endpoint):
            if settings.hasConsent(for: endpoint) {
                save(consented: false)
            } else {
                consentRequest = endpoint
            }
        }
    }

    private func save(consented: Bool) {
        guard let service = connection.service else { return }
        do {
            try settings.save(service: service, custom: connection.custom, apiKey: connection.apiKey, consented: consented)
            settings.setKeywords(from: keywords)
            settings.setPrompt(prompt)
            connection.apiKey = ""
            dismiss()
        } catch {
            saveError = error.message
        }
    }

    static func consentTitle(_ endpoint: VoiceInputEndpoint) -> String {
        "Send Recordings to \(endpoint.operatorName ?? endpoint.host)?"
    }

    static func consentMessage(_ endpoint: VoiceInputEndpoint) -> String {
        let terms = endpoint.operatorName.map { "\($0)'s terms" } ?? "the terms of whoever runs it"
        return "Each Voice Input recording is uploaded to \(endpoint.host) and turned into text "
            + "under \(terms). Heeler keeps no copy once the text arrives."
    }
}

private struct VoiceInputFormField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
        } label: {
            Text(title)
        }
    }
}
