import SwiftUI

/// Settings › Voice Input, and the sheet the Composer's mic opens before
/// setup. The service, its key, the Keywords, and the Prompt change only on
/// Save, which asks once per destination before recordings may go to it
/// (ADR 0036); the microphone choice applies at once. Keywords and the Prompt
/// stay the same whichever service is chosen, except that a service which
/// doesn't read Keywords keeps them on the Prompt's Vocabulary line, updated
/// as Keywords change or the service becomes one of those. A service that
/// bills Keywords shows them behind Send Keywords, saved with its options,
/// and one that takes no Prompt shows none.
struct VoiceInputSettingsView: View {
    let settings: VoiceInputSettings
    /// The mic's sheet has Cancel; pushed from Settings, Back does it.
    var isSheet = false
    @State private var connection: VoiceInputServiceDraft
    @State private var keywords: String
    @State private var prompt: String
    @State private var onDeviceLanguage: String
    @State private var consentRequest: VoiceInputEndpoint?
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(settings: VoiceInputSettings, isSheet: Bool = false) {
        self.settings = settings
        self.isSheet = isSheet
        _connection = State(initialValue: VoiceInputServiceDraft(
            service: settings.service, custom: settings.custom, requestOptions: settings.requestOptions))
        _keywords = State(initialValue: settings.keywords.joined(separator: ", "))
        _prompt = State(initialValue: settings.prompt)
        _onDeviceLanguage = State(initialValue: settings.onDeviceLanguage)
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
            case .onDevice:
                if #available(iOS 26.0, *) {
                    VoiceInputOnDeviceSection(language: $onDeviceLanguage)
                }
            case .preset(let preset):
                Section {
                    LabeledContent("Model", value: preset.model)
                }
                VoiceInputLanguagesSection(preset: preset, languages: $connection.options.languages)
                if preset.recognitionModes.count > 1 {
                    recognitionSection(preset.recognitionModes)
                }
                keySection
            case .custom:
                customSection
                keySection
            case nil:
                EmptyView()
            }
            if let service = connection.service {
                if service.takesKeywords || service.acceptsPrompt || service.keywordsAreOptional {
                    keywordsSection
                }
                if service.acceptsPrompt {
                    promptSection
                }
                if connection.service == .custom, connection.endpoint != nil {
                    VoiceInputCustomFieldsSection(fields: $connection.options.fields)
                    if let problem = optionsProblem {
                        Section { Text(problem.message).foregroundStyle(.errorInk) }
                    }
                }
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
                title: String(localized: "Base URL"), prompt: "https://api.example.com/v1", text: $connection.custom.baseURL,
                keyboard: .URL)
            VoiceInputFormField(
                title: String(localized: "Model"), prompt: String(localized: "Required"), text: $connection.custom.model)
        } footer: {
            Text(
                String(localized: "For services that take OpenAI's audio/transcriptions request. Language and other options can be set in Advanced Request Fields after entering the URL and model."))
        }
    }

    /// Only a service that offers more than one way shows this; the choice
    /// is saved with its options.
    private func recognitionSection(_ modes: [VoiceRecognitionMode]) -> some View {
        Section {
            Picker(
                "Recognition",
                selection: Binding(
                    get: { connection.service?.recognitionMode(chosen: connection.options.mode) ?? .batch },
                    set: { connection.options.mode = $0 })
            ) {
                ForEach(modes, id: \.self) { mode in
                    Text(Self.name(of: mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Recognition")
        } footer: {
            Text("As You Speak shows the text while you talk. After Recording sends the whole recording once you stop, and if As You Speak loses its connection, the recording is sent that way instead.")
        }
    }

    private static func name(of mode: VoiceRecognitionMode) -> String {
        switch mode {
        case .stream: String(localized: "As You Speak", comment: "Voice Input recognition: text appears while the user talks")
        case .batch: String(localized: "After Recording", comment: "Voice Input recognition: the whole recording is sent once the user stops")
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
            if let host = draftEndpoint?.host {
                Text("Kept in this device's Keychain and sent only with recordings to \(host).")
            } else {
                Text("Kept in this device's Keychain and sent only with recordings to the service.")
            }
        }
    }

    private var keywordsSection: some View {
        Section {
            if billedKeywordsOperator != nil {
                Toggle("Send Keywords", isOn: $connection.options.sendsKeywords)
            }
            if billedKeywordsOperator == nil || connection.options.sendsKeywords {
                TextField(
                    "Keywords", text: $keywords,
                    prompt: Text(verbatim: "herdr, Claude Code, Codex, pnpm, SwiftUI"), axis: .vertical)
                    .lineLimit(2...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("Keywords")
        } footer: {
            let purpose = String(localized: "Names and terms you say, separated by commas, so the service spells them right.")
            if let billedKeywordsOperator {
                Text([purpose, String(localized: "\(billedKeywordsOperator) charges extra for recordings sent with Keywords.")].joinedAsSentences())
            } else {
                Text(purpose)
            }
        }
    }

    /// Who bills Keywords, for a service that takes them only behind Send
    /// Keywords; nil for every other service.
    private var billedKeywordsOperator: String? {
        guard case .preset(let preset) = connection.service, connection.service?.keywordsAreOptional == true else {
            return nil
        }
        return preset.operatorName
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
            if connection.service == .custom, connection.options.fields.contains(where: { $0.name == "prompt" }) {
                Text("The prompt in Advanced Request Fields replaces this Prompt for this Custom model.")
            } else if connection.service?.takesKeywords == false {
                Text(
                    String(localized: "What you talk about, sent as written. This service doesn't read Keywords, so they're added here."))
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
        case .onDevice:
            String(localized: "Speech is turned into text on this device by Apple's dictation model.")
        case .preset(let preset):
            String(localized: "Recordings go to \(preset.operatorName) under its terms, billed to your key. Heeler's developer receives none of them.")
        case .custom:
            String(localized: "Recordings go to the URL you enter, under the terms of whoever runs it.")
        case nil:
            String(localized: "Voice Input turns speech into Composer text through a speech service you choose, with your own API key.")
        }
    }

    private var draftEndpoint: VoiceInputEndpoint? {
        connection.endpoint
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

    private var optionsProblem: VoiceInputRequestOptions.Problem? {
        guard let endpoint = connection.endpoint else { return nil }
        do { try connection.options.validate(for: endpoint) } catch { return error }
        return nil
    }

    private var canSave: Bool {
        guard let service = connection.service else { return settings.service != nil }
        if service == .onDevice { return true }
        if case .success = settings.validate(service: service, custom: connection.custom, apiKey: connection.apiKey, options: connection.options) {
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
        if service == .onDevice {
            settings.saveOnDevice(language: onDeviceLanguage)
            settings.setKeywords(from: keywords)
            dismiss()
            return
        }
        switch settings.validate(service: service, custom: connection.custom, apiKey: connection.apiKey, options: connection.options) {
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
            try settings.save(service: service, custom: connection.custom, apiKey: connection.apiKey, consented: consented, options: connection.options)
            settings.setKeywords(from: keywords)
            settings.setPrompt(prompt)
            connection.apiKey = ""
            dismiss()
        } catch {
            saveError = error.message
        }
    }

    static func consentTitle(_ endpoint: VoiceInputEndpoint) -> String {
        String(localized: "Send Recordings to \(endpoint.operatorName ?? endpoint.host)?")
    }

    static func consentMessage(_ endpoint: VoiceInputEndpoint) -> String {
        guard let operatorName = endpoint.operatorName else {
            return String(localized: "Each Voice Input recording is uploaded to \(endpoint.host) and turned into text under the terms of whoever runs it. Heeler keeps no copy once the text arrives.")
        }
        if case .volcengine = endpoint.wire {
            return String(
                localized: "Voice Input sends what you say to \(endpoint.host) as you speak, or the whole recording once you stop, to be turned into text under \(operatorName)'s terms. Heeler keeps no copy once the text arrives.",
                comment: "Voice Input consent for a service that can stream. %1$@ is the service host name, %2$@ the company that runs it.")
        }
        return String(localized: "Each Voice Input recording is uploaded to \(endpoint.host) and turned into text under \(operatorName)'s terms. Heeler keeps no copy once the text arrives.")
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
