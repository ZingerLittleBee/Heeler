import Foundation
import Observation

/// Owns the app-level Dictation settings (#38): the selected recognition
/// language, persisted in UserDefaults, and each language's on-device model
/// state with download triggering. The recording path reads the selected
/// language through a closure; this store is the single writer.
///
/// Model lifecycle goes through the `DictationEngine` seam (AssetInventory
/// under the hood), so this store — like the reply-box store — never touches
/// Speech framework types and is exercised against a scripted engine. Real
/// download progress is device-only (the Simulator reports every locale
/// unsupported, ADR 0003).
@MainActor
@Observable
final class DictationSettingsStore {
    /// A language's model state as Settings presents it. Distinct from the
    /// engine's `DictationModelStatus`: it folds in the transient download
    /// progress and failure this store tracks while a download runs.
    enum ModelState: Equatable, Sendable {
        /// Not queried yet.
        case unknown
        /// No on-device support for the language (also the Simulator/CI).
        case unsupported
        /// Supported, model not downloaded — offer a Download action.
        case notDownloaded
        /// A download is in flight; `progress` is a fraction in `0...1`.
        case downloading(progress: Double)
        /// The last download attempt failed; the message is user-facing.
        case failed(String)
        /// The model is installed and ready.
        case ready
    }

    private let engine: any DictationEngine
    private let defaults: UserDefaults
    private static let languageKey = "dictation.selectedLanguage"

    /// The selected recognition language. Written only through `select(_:)` so
    /// persistence stays in one place.
    private(set) var selectedLanguage: DictationLanguage
    /// Per-language model state, keyed by `DictationLanguage.id`.
    private(set) var modelStates: [DictationLanguage.ID: ModelState] = [:]

    /// In-flight download tasks, so a second tap on Download is a no-op.
    private var downloadTasks: [DictationLanguage.ID: Task<Void, Never>] = [:]

    /// The languages offered in Settings, in display order.
    var languages: [DictationLanguage] { DictationLanguage.all }

    init(engine: any DictationEngine = SpeechDictationEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        self.selectedLanguage =
            DictationLanguage.language(forID: defaults.string(forKey: Self.languageKey))
            ?? .default
    }

    /// The current model state for a language, `.unknown` until first queried.
    func modelState(for language: DictationLanguage) -> ModelState {
        modelStates[language.id] ?? .unknown
    }

    /// Selects and persists `language`; takes effect on the next recording.
    func select(_ language: DictationLanguage) {
        selectedLanguage = language
        defaults.set(language.id, forKey: Self.languageKey)
    }

    /// Refreshes every offered language's model readiness from the engine.
    func refreshStatuses() async {
        for language in languages {
            await refreshStatus(for: language)
        }
    }

    /// Refreshes one language's readiness. A live download owns the state, so
    /// this leaves a `.downloading` entry alone rather than stomping its
    /// progress with a stale query.
    func refreshStatus(for language: DictationLanguage) async {
        if case .downloading = modelState(for: language) { return }
        let status = await engine.modelStatus(for: language)
        modelStates[language.id] = Self.state(from: status)
    }

    /// Triggers a model download for `language`, streaming progress into its
    /// model state and ending at `.ready` or `.failed`. A no-op while a
    /// download for the same language is already in flight.
    func download(_ language: DictationLanguage) {
        guard downloadTasks[language.id] == nil else { return }
        modelStates[language.id] = .downloading(progress: 0)
        let engine = self.engine
        downloadTasks[language.id] = Task { [weak self] in
            do {
                for try await fraction in await engine.downloadModel(for: language) {
                    self?.modelStates[language.id] = .downloading(
                        progress: min(max(fraction, 0), 1))
                }
                self?.modelStates[language.id] = .ready
            } catch {
                self?.modelStates[language.id] = .failed(Self.downloadFailureMessage(for: language))
            }
            self?.downloadTasks[language.id] = nil
        }
    }

    private static func state(from status: DictationModelStatus) -> ModelState {
        switch status {
        case .unsupported: .unsupported
        case .notInstalled: .notDownloaded
        case .installed: .ready
        }
    }

    private static func downloadFailureMessage(for language: DictationLanguage) -> String {
        "Couldn't download the \(language.displayName) model. Check your connection and try again."
    }
}
