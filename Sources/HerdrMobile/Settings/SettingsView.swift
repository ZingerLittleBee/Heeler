import SwiftUI

/// The app-level Settings screen (#38), deliberately small: v1 holds only the
/// Dictation section — a language picker and per-language on-device model
/// management. It reads and writes the shared `DictationSettingsStore`; the
/// model state and download progress it shows come from the `DictationEngine`
/// seam, never from Speech framework types.
struct SettingsView: View {
    @Bindable var store: DictationSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: languageSelection) {
                        ForEach(store.languages) { language in
                            Text(language.displayName).tag(language.id)
                        }
                    }
                } header: {
                    Text("Dictation Language")
                } footer: {
                    Text(
                        "Replies are transcribed on device in this language. "
                            + "It takes effect on your next recording.")
                }

                Section("On-Device Models") {
                    ForEach(store.languages) { language in
                        ModelStatusRow(
                            language: language,
                            state: store.modelState(for: language),
                            onDownload: { store.download(language) })
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refreshStatuses() }
        }
    }

    /// Binds the picker to the store's persisted selection, going through
    /// `select(_:)` so the choice is written to UserDefaults on change.
    private var languageSelection: Binding<DictationLanguage.ID> {
        Binding(
            get: { store.selectedLanguage.id },
            set: { id in
                guard let language = store.languages.first(where: { $0.id == id }) else { return }
                store.select(language)
            })
    }
}

/// One language's on-device model row: its name plus a trailing control that
/// reflects readiness — a checkmark when ready, a Download button when missing,
/// live progress while downloading, a retry on failure, and an "unavailable"
/// note where the device has no on-device support.
private struct ModelStatusRow: View {
    let language: DictationLanguage
    let state: DictationSettingsStore.ModelState
    let onDownload: () -> Void

    var body: some View {
        let presentation = presentation
        HStack {
            Text(language.displayName)
            Spacer()
            trailing(presentation.control)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(language.displayName) model")
        .accessibilityValue(presentation.accessibilityValue)
    }

    /// The one derivation from `ModelState`: the trailing control and its
    /// accessibility value come from a single switch so they can never describe
    /// different states (adding a `ModelState` forces both here).
    private var presentation: Presentation {
        switch state {
        case .unknown:
            Presentation(control: .checking, accessibilityValue: "Checking")
        case .unsupported:
            Presentation(
                control: .note("Not available on this device"),
                accessibilityValue: "Not available on this device")
        case .notDownloaded:
            Presentation(
                control: .button(title: "Download", tint: nil),
                accessibilityValue: "Not downloaded")
        case .downloading(let progress):
            Presentation(
                control: .progress(progress),
                accessibilityValue: "Downloading, \(Int(progress * 100)) percent")
        case .failed(let message):
            Presentation(
                control: .button(title: "Retry", tint: .red), accessibilityValue: message)
        case .ready:
            Presentation(control: .ready, accessibilityValue: "Ready")
        }
    }

    @ViewBuilder
    private func trailing(_ control: Presentation.Control) -> some View {
        switch control {
        case .checking:
            ProgressView().controlSize(.small)
        case .note(let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .button(let title, let tint):
            Button(title, action: onDownload)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(tint)
        case .progress(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
    }

    /// The trailing control and accessibility value for one `ModelState`,
    /// produced together so the two can't drift.
    private struct Presentation {
        let control: Control
        let accessibilityValue: String

        enum Control {
            case checking
            case note(String)
            case button(title: String, tint: Color?)
            case progress(Double)
            case ready
        }
    }
}
