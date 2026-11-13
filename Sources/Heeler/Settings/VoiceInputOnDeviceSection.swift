import SwiftUI

/// On Device's language and its speech model. The language applies on Save;
/// the model downloads at once, since a recording cannot wait for it.
@available(iOS 26.0, *)
struct VoiceInputOnDeviceSection: View {
    @Binding var language: String
    @State private var languages: [String] = []
    @State private var status: VoiceInputModelStatus?
    /// The model being fetched. The Language picker stays open meanwhile,
    /// so the download shows, and reports back, only for its own language.
    @State private var download: ModelDownload?
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
            Text("One language per recording, with English words inside it. Keywords help it spell your terms. Text appears as you speak, and nothing leaves this device.")
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
            if let download, download.language == language {
                ProgressView(value: download.progress) { Text("Downloading Speech Model…") }
            } else {
                Button("Download Speech Model", action: startDownload)
            }
        }
    }

    private func startDownload() {
        let language = language
        download = ModelDownload(language: language, progress: 0)
        downloadError = nil
        Task {
            var failed = false
            do {
                try await DeviceVoiceTranscriber.downloadModel(for: language) { progress in
                    if download?.language == language { download?.progress = progress }
                }
            } catch {
                failed = true
            }
            if download?.language == language { download = nil }
            let finished = await DeviceVoiceTranscriber.modelStatus(for: language)
            guard self.language == language else { return }
            status = finished
            if failed { downloadError = String(localized: "The speech model could not be downloaded.") }
        }
    }

    private static func name(of identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// A speech model download in progress, from 0 to 1.
private struct ModelDownload {
    let language: String
    var progress: Double
}
