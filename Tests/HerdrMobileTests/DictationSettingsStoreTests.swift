import Foundation
import Testing

@testable import HerdrMobile

/// The Dictation settings store (#38) against a scripted engine: the language
/// selection round-trips through UserDefaults (default Simplified Chinese, a
/// persisted choice survives a fresh store), and per-language model readiness
/// maps the engine's status onto the store's user-facing state — including the
/// model-not-ready path and a live download's progress. Protocol level, no
/// Speech framework (ADR 0003).
@MainActor
@Suite("Dictation settings store")
struct DictationSettingsStoreTests {
    /// A private, empty UserDefaults suite per test so persistence is real but
    /// isolated (mirrors the repo's InMemory doubles for other stores).
    private func makeDefaults() -> UserDefaults {
        let suite = "dictation.settings.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        _ comment: Comment, timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    @Test func defaultsToSimplifiedChineseWhenNothingPersisted() {
        let store = DictationSettingsStore(
            engine: ScriptedDictationEngine(), defaults: makeDefaults())
        #expect(store.selectedLanguage == .simplifiedChinese)
    }

    @Test func persistsSelectionAcrossStoreInstances() {
        let defaults = makeDefaults()
        let engine = ScriptedDictationEngine()

        let first = DictationSettingsStore(engine: engine, defaults: defaults)
        first.select(.english)
        #expect(first.selectedLanguage == .english)

        // A fresh store on the same defaults reads the persisted choice back,
        // as a relaunch would.
        let second = DictationSettingsStore(engine: engine, defaults: defaults)
        #expect(second.selectedLanguage == .english)
    }

    @Test func ignoresAnUnknownPersistedLanguageAndFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("xx-YY", forKey: "dictation.selectedLanguage")
        let store = DictationSettingsStore(engine: ScriptedDictationEngine(), defaults: defaults)
        #expect(store.selectedLanguage == .default)
    }

    @Test func refreshMapsEngineStatusesOntoModelState() async {
        let engine = ScriptedDictationEngine()
        await engine.setModelStatus(.installed, for: .simplifiedChinese)
        await engine.setModelStatus(.notInstalled, for: .english)
        let store = DictationSettingsStore(engine: engine, defaults: makeDefaults())

        await store.refreshStatuses()

        #expect(store.modelState(for: .simplifiedChinese) == .ready)
        // The model-not-ready path: a supported-but-missing model reads as
        // notDownloaded, which the UI turns into a Download action.
        #expect(store.modelState(for: .english) == .notDownloaded)
    }

    @Test func unsupportedLocaleReadsAsUnsupported() async {
        // What the Simulator and CI report for every locale (ADR 0003).
        let engine = ScriptedDictationEngine()
        await engine.setModelStatus(.unsupported, for: .simplifiedChinese)
        let store = DictationSettingsStore(engine: engine, defaults: makeDefaults())

        await store.refreshStatus(for: .simplifiedChinese)
        #expect(store.modelState(for: .simplifiedChinese) == .unsupported)
    }

    @Test func downloadStreamsProgressThenReady() async throws {
        let engine = ScriptedDictationEngine()
        await engine.setModelStatus(.notInstalled, for: .english)
        let store = DictationSettingsStore(engine: engine, defaults: makeDefaults())

        store.download(.english)
        try await waitUntil("the engine should open a download stream") {
            await engine.hasLiveDownload
        }
        #expect(store.modelState(for: .english) == .downloading(progress: 0))

        await engine.emitDownloadProgress(0.5)
        try await waitUntil("progress should stream into the model state") {
            store.modelState(for: .english) == .downloading(progress: 0.5)
        }

        await engine.finishDownload()
        try await waitUntil("a finished download should land on ready") {
            store.modelState(for: .english) == .ready
        }
    }

    @Test func refreshLeavesAnInFlightDownloadUntouched() async throws {
        // A stale status query must not stomp a live download's progress.
        let engine = ScriptedDictationEngine()
        await engine.setModelStatus(.notInstalled, for: .english)
        let store = DictationSettingsStore(engine: engine, defaults: makeDefaults())

        store.download(.english)
        try await waitUntil("the download should be live") { await engine.hasLiveDownload }
        await engine.emitDownloadProgress(0.3)
        try await waitUntil("progress should land") {
            store.modelState(for: .english) == .downloading(progress: 0.3)
        }

        await store.refreshStatus(for: .english)
        #expect(store.modelState(for: .english) == .downloading(progress: 0.3))

        await engine.finishDownload()
        try await waitUntil("the download should still complete") {
            store.modelState(for: .english) == .ready
        }
    }

    @Test func downloadFailureSurfacesFailedState() async throws {
        let engine = ScriptedDictationEngine()
        await engine.setModelStatus(.notInstalled, for: .english)
        let store = DictationSettingsStore(engine: engine, defaults: makeDefaults())

        store.download(.english)
        try await waitUntil("the download should be live") { await engine.hasLiveDownload }
        await engine.failDownload(DictationEngineError.modelUnavailable)

        try await waitUntil("a failed download should surface a failed state") {
            if case .failed = store.modelState(for: .english) { return true }
            return false
        }
    }
}
