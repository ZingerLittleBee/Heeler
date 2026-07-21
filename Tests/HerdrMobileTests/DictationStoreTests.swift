import Foundation
import Testing

@testable import HerdrMobile

/// The dictation store (#36) against a scripted engine: partials stream into
/// the reply draft, release finalizes and keeps the text, dictation composes
/// with an existing draft instead of overwriting it, a mid-recording failure
/// preserves what already landed, and the existing send / quick-key path is
/// untouched — protocol level, no Speech framework, no SSH, no UI.
@MainActor
@Suite("Dictation store")
struct DictationStoreTests {
    /// A reply draft with the send path a real AgentInputStore carries, so the
    /// "send unchanged" test drives a genuine send. `transport` nil means the
    /// send path is not exercised.
    private func makeInput(transport: ScriptedTransport? = nil) -> AgentInputStore {
        AgentInputStore(target: "w1:p1") { transport }
    }

    /// Polls until `condition` holds, yielding so the store's session task
    /// progresses (mirrors the input-store suite).
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

    /// Starts dictation and waits until the engine's stream is live, so the
    /// test can emit into it deterministically.
    private func startAndAwaitLiveStream(
        _ store: DictationStore, _ engine: ScriptedDictationEngine
    ) async throws {
        store.startDictation()
        try await waitUntil("the engine should open its stream after start") {
            await engine.hasLiveStream
        }
    }

    @Test func partialsStreamIntoTheDraft() async throws {
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        #expect(store.state == .recording)

        await engine.emitPartial("打开")
        try await waitUntil("the first partial should reach the draft") {
            input.draft == "打开"
        }
        // Each partial is the whole span so far and replaces the previous one.
        await engine.emitPartial("打开日志")
        try await waitUntil("a later partial should replace the earlier one") {
            input.draft == "打开日志"
        }
        #expect(store.isRecording)
    }

    @Test func releaseFinalizesAndKeepsTheText() async throws {
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.emitPartial("restart the")
        try await waitUntil("the partial should land") { input.draft == "restart the" }

        // Releasing asks the engine to flush its final transcript and end.
        await engine.setFinalOnStop(DictationTranscript(text: "restart the server", isFinal: true))
        store.stopDictation()

        try await waitUntil("the session should return to idle after finalizing") {
            store.state == .idle
        }
        #expect(input.draft == "restart the server")
        #expect(await engine.stopCount == 1)
        #expect(!store.isRecording)
    }

    @Test func dictationAppendsOntoExistingDraftWithoutOverwriting() async throws {
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        input.draft = "please"
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.emitPartial("restart")
        try await waitUntil("dictation should append after the typed text") {
            input.draft == "please restart"
        }

        await engine.setFinalOnStop(DictationTranscript(text: "restart it", isFinal: true))
        store.stopDictation()
        try await waitUntil("the final should keep composing onto the base") {
            store.state == .idle
        }
        #expect(input.draft == "please restart it")
    }

    @Test func existingSendAndQuickKeyBehaviorIsUnchanged() async throws {
        // Dictate into the draft, then drive the real send path: dictation is
        // purely additive to the reply surface (#17).
        let transport = ScriptedTransport()
        let engine = ScriptedDictationEngine()
        let input = makeInput(transport: transport)
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.setFinalOnStop(DictationTranscript(text: "yes proceed", isFinal: true))
        store.stopDictation()
        try await waitUntil("dictation should finish") { store.state == .idle }
        #expect(input.draft == "yes proceed")

        await input.sendDraft()
        #expect(input.state == .idle)
        #expect(input.draft.isEmpty)
        #expect(
            await transport.sentInputs == [
                PaneSendInputParams(paneID: "w1:p1", keys: ["enter"], text: "yes proceed")
            ])

        // The quick-key path still sends its herdr spelling.
        await input.send(.enter)
        #expect(
            await transport.sentKeys == [PaneSendKeysParams(keys: ["enter"], paneID: "w1:p1")])
    }

    @Test func slideOffCancelDiscardsInFlightTranscription() async throws {
        // Sliding the finger off the button cancels: everything streamed this
        // session is thrown away and the prior draft is restored (User Story 5).
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        input.draft = "keep this"
        input.cursorOffset = input.draft.count
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.emitPartial("garbage take")
        try await waitUntil("the partial should stream into the draft") {
            input.draft == "keep this garbage take"
        }

        // A final flushed by stop() after a cancel must not leak into the draft.
        await engine.setFinalOnStop(DictationTranscript(text: "garbage take two", isFinal: true))
        store.cancelDictation()

        try await waitUntil("cancel should wind the session back to idle") {
            store.state == .idle
        }
        #expect(input.draft == "keep this")
        #expect(input.cursorOffset == "keep this".count)
        #expect(await engine.stopCount == 1)
        #expect(!store.isRecording)
    }

    @Test func dictationInsertsAtTheCursorWithinExistingDraft() async throws {
        // With the caret in the middle of a typed draft, dictation inserts
        // there; text on both sides of the caret is preserved (User Story 6).
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        input.draft = "please it"
        input.cursorOffset = "please ".count  // caret between "please " and "it"
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.emitPartial("restart")
        try await waitUntil("dictation should insert at the caret, not the end") {
            input.draft == "please restart it"
        }
        // The caret follows the dictated span, landing after the separating
        // space so further typing goes right before "it".
        #expect(input.cursorOffset == "please restart ".count)

        await engine.setFinalOnStop(DictationTranscript(text: "restart", isFinal: true))
        store.stopDictation()
        try await waitUntil("the final keeps the same insertion") { store.state == .idle }
        #expect(input.draft == "please restart it")
    }

    @Test func midRecordingFailureKeepsPartialsAndSurfacesInTheErrorRow() async throws {
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        let store = DictationStore(engine: engine, draft: input)

        try await startAndAwaitLiveStream(store, engine)
        await engine.emitPartial("half a reply")
        try await waitUntil("the partial should land") { input.draft == "half a reply" }

        await engine.failStream(TranscriptionFailure.engineDied)
        try await waitUntil("the store should surface the failure") {
            if case .failed = store.state { return true }
            return false
        }
        // Half a spoken reply is never silently thrown away (User Story 16)…
        #expect(input.draft == "half a reply")
        // …and the failure goes to the existing error row, not the alert.
        #expect(store.errorRowMessage != nil)
        #expect(!store.showsPermissionAlert)
        // An untyped engine failure never leaks its description to the user and
        // offers no remedy — it is not a missing-model, download-in-Settings case.
        #expect(store.errorRowMessage == "Dictation stopped unexpectedly. Try again.")
        #expect(store.errorRowRemedy == nil)
    }

    @Test func permissionDeniedShowsAlertNotErrorRowAndDraftUntouched() async throws {
        let engine = ScriptedDictationEngine()
        await engine.setStartError(DictationEngineError.microphonePermissionDenied)
        let input = makeInput()
        input.draft = "typed already"
        let store = DictationStore(engine: engine, draft: input)

        store.startDictation()
        try await waitUntil("a denied mic should surface the permission alert") {
            store.showsPermissionAlert
        }
        // The alert carries the remedy; the error row stays empty for it.
        #expect(store.errorRowMessage == nil)
        // Nothing was captured, so the pre-existing draft is left alone.
        #expect(input.draft == "typed already")
        #expect(!store.isRecording)

        // Dismissing the alert returns to idle; the button never went away.
        store.dismissPermissionAlert()
        #expect(store.state == .idle)
        #expect(!store.showsPermissionAlert)
    }

    @Test func modelUnavailableRoutesToTheErrorRowNotTheAlert() async throws {
        let engine = ScriptedDictationEngine()
        await engine.setStartError(DictationEngineError.modelUnavailable)
        let input = makeInput()
        input.draft = "typed already"
        let store = DictationStore(engine: engine, draft: input)

        store.startDictation()
        try await waitUntil("a missing model should surface in the error row") {
            store.errorRowMessage != nil
        }
        #expect(!store.showsPermissionAlert)
        #expect(input.draft == "typed already")
        #expect(!store.isRecording)
        // The hint is actionable: the reply box can route the user to Settings
        // to download the model (User Story 15).
        #expect(store.errorRowRemedy == .openSettings)
    }

    @Test func recordsInTheSelectedLanguageNotAHardcodedDefault() async throws {
        // The store forwards the persisted selection to the engine, replacing
        // the tracer bullet's hardcoded zh_CN (#38).
        let engine = ScriptedDictationEngine()
        let input = makeInput()
        let store = DictationStore(engine: engine, draft: input) { .english }

        try await startAndAwaitLiveStream(store, engine)
        #expect(await engine.lastStartLanguage == .english)
    }

    @Test func clearErrorRowClearsAStaleMessageButNotThePermissionAlert() async throws {
        // A send attempt clears a lingering model-not-ready hint so it can't
        // mask a later send failure (#38)…
        let engine = ScriptedDictationEngine()
        await engine.setStartError(DictationEngineError.modelUnavailable)
        let input = makeInput()
        let store = DictationStore(engine: engine, draft: input)

        store.startDictation()
        try await waitUntil("the missing model should surface in the error row") {
            store.errorRowMessage != nil
        }
        store.clearErrorRow()
        #expect(store.errorRowMessage == nil)
        #expect(store.state == .idle)

        // …but a denied-mic alert is a different remedy and must not be cleared.
        await engine.setStartError(DictationEngineError.microphonePermissionDenied)
        store.startDictation()
        try await waitUntil("a denied mic should surface the alert") {
            store.showsPermissionAlert
        }
        store.clearErrorRow()
        #expect(store.showsPermissionAlert)
    }

    @Test func composeInsertsOneSpaceOnlyWhenNeeded() {
        // The insertion seam: no leading space into an empty prefix, exactly one
        // space where the dictated span abuts a non-space on either side, and
        // none next to existing whitespace or an empty side.
        #expect(DictationStore.compose(prefix: "", dictated: "hi", suffix: "") == "hi")
        #expect(DictationStore.compose(prefix: "a", dictated: "b", suffix: "") == "a b")
        #expect(DictationStore.compose(prefix: "a ", dictated: "b", suffix: "") == "a b")
        #expect(DictationStore.compose(prefix: "a", dictated: "", suffix: "c") == "ac")
        // Caret in the middle: a space is added on each abutting non-space side.
        #expect(DictationStore.compose(prefix: "a", dictated: "b", suffix: "c") == "a b c")
        #expect(DictationStore.compose(prefix: "a ", dictated: "b", suffix: " c") == "a b c")
    }
}

/// A stand-in error for a mid-recording engine failure.
private enum TranscriptionFailure: Error {
    case engineDied
}
