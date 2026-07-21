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

    @Test func midRecordingFailureKeepsPartialText() async throws {
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
        // Half a spoken reply is never silently thrown away (User Story 16).
        #expect(input.draft == "half a reply")
    }

    @Test func startFailureLeavesTheDraftUntouched() async throws {
        let engine = ScriptedDictationEngine()
        await engine.setStartError(DictationEngineError.microphonePermissionDenied)
        let input = makeInput()
        input.draft = "typed already"
        let store = DictationStore(engine: engine, draft: input)

        store.startDictation()
        try await waitUntil("a start failure should surface") {
            if case .failed = store.state { return true }
            return false
        }
        // Nothing was captured, so the pre-existing draft is left alone.
        #expect(input.draft == "typed already")
        #expect(!store.isRecording)
    }

    @Test func composeInsertsOneSpaceOnlyWhenNeeded() {
        // The append seam: no leading space into an empty base, exactly one
        // space after a non-space, none after existing whitespace.
        #expect(DictationStore.compose(base: "", dictated: "hi") == "hi")
        #expect(DictationStore.compose(base: "a", dictated: "b") == "a b")
        #expect(DictationStore.compose(base: "a ", dictated: "b") == "a b")
        #expect(DictationStore.compose(base: "a", dictated: "") == "a")
    }
}

/// A stand-in error for a mid-recording engine failure.
private enum TranscriptionFailure: Error {
    case engineDied
}
