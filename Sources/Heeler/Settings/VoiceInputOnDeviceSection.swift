import SwiftUI

/// On Device's language and its speech model. The language applies on Save;
/// the model downloads at once, since a recording cannot wait for it.
@available(iOS 26.0, *)
struct VoiceInputOnDeviceSection: View {
    @Binding var language: String
    @State private var languages: [String] = []
    @State private var status: VoiceInputModelStatus?
    @State private var progress: Double?
    @State private var downloadError: String?

    var body: some View {
        Section {
            Picker("Language", selection: $language) {
                ForEach(options, id: \.self) { identifier in
                    Text(Self.name(of: identifier)).tag(identifier)
                }
            }
            modelRow
            if let downloadError {
                Text(downloadError).foregroundStyle(.red)
            }
        } footer: {
            Text("One language per recording, with English words inside it. Keywords help it spell your terms. Text appears in the draft as you speak, and nothing leaves this device.")
        }
        .task {
            let supported = await DeviceVoiceTranscriber.supportedLanguages()
            languages = supported.sorted { Self.name(of: $0) < Self.name(of: $1) }
            if !supported.contains(language),
                let nearest = await DeviceVoiceTranscriber.supportedLanguage(equivalentTo: language)
            {
                language = nearest
            }
        }
        .task(id: language) {
            status = nil
            downloadError = nil
            status = await DeviceVoiceTranscriber.modelStatus(for: language)
        }
    }

    /// The supported languages, and the chosen one even where it is not.
    private var options: [String] {
        languages.contains(language) ? languages : [language] + languages
    }

    @ViewBuilder
    private var modelRow: some View {
        switch status {
        case nil:
            LabeledContent("Speech Model") { ProgressView() }
        case .installed:
            LabeledContent("Speech Model", value: String(localized: "Installed"))
        case .unsupported:
            LabeledContent("Speech Model", value: String(localized: "Not available on this device"))
        case .notInstalled:
            if let progress {
                ProgressView(value: progress) { Text("Downloading Speech Model…") }
            } else {
                Button("Download Speech Model", action: download)
            }
        }
    }

    private func download() {
        let language = language
        progress = 0
        downloadError = nil
        Task {
            do {
                try await DeviceVoiceTranscriber.downloadModel(for: language) { progress = $0 }
            } catch {
                downloadError = String(localized: "The speech model could not be downloaded.")
            }
            progress = nil
            status = await DeviceVoiceTranscriber.modelStatus(for: language)
        }
    }

    private static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
