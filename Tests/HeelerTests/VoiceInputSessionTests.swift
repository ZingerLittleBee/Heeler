import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Voice Input session")
struct VoiceInputSessionTests {
    @MainActor
    private struct Fixture {
        let session: VoiceInputSession
        let recorder: FakeVoiceRecorder
        let transcriber: ScriptedTranscriber
        let live: FakeLiveTranscriber
        let settings: VoiceInputSettings
        let defaults: UserDefaults
        let suite: String

        func makeStore(holdGate: ScriptedTransportCallGate? = nil) -> AgentComposerStore {
            let voice = ComposerVoiceInput(sleep: { _ in await holdGate?.waitUntilOpen() })
            return AgentComposerStore(target: "w1:p1", voice: voice) { _ in
                throw TransportError.cancelled
            }
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeFixture(
        ready: Bool = true,
        results: [Result<String, VoiceTranscriptionError>] = []
    ) throws -> Fixture {
        let suite = "hm-voice-session-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = VoiceInputSettings(defaults: defaults, secrets: InMemorySecretStore())
        if ready {
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "sk-test", consented: true)
        }
        if let endpoint = settings.endpoint {
            try settings.save(service: .preset(.openAI), custom: .init(), apiKey: "", consented: false,
                              options: .init(languages: ["zh", "en"]))
            #expect(settings.options(for: endpoint).languages == ["zh", "en"])
        }
        let recorder = FakeVoiceRecorder()
        let transcriber = ScriptedTranscriber(results: results)
        let live = FakeLiveTranscriber()
        let session = VoiceInputSession(
            settings: settings, recorder: recorder,
            transcribe: { try await transcriber.transcribe($0) },
            makeLiveTranscriber: { live },
            sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        return Fixture(
            session: session, recorder: recorder, transcriber: transcriber, live: live,
            settings: settings, defaults: defaults, suite: suite)
    }

    private func makeOnDeviceFixture() throws -> Fixture {
        let fixture = try makeFixture(ready: false)
        fixture.settings.saveOnDevice(language: "zh-CN")
        fixture.settings.setKeywords(from: "useEffect, README")
        return fixture
    }

    @Test func onDeviceTextShowsInTheRecorderAndLandsOnceOnStop() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        let hold = ScriptedTransportCallGate()
        let store = fixture.makeStore(holdGate: hold)
        store.applyEditorDraft("fix. Then commit", selection: NSRange(location: 4, length: 0))

        fixture.session.toggle(store.voice)
        #expect(store.voice.showsRecorder)
        #expect(store.voice.isInRecordingMode)
        try await waitUntil("recording") { store.voice.isRecording }
        #expect(fixture.live.started.map(\.locale) == ["zh-CN"])
        #expect(fixture.live.started.first?.keywords == ["useEffect", "README"])
        #expect(fixture.recorder.hasAudioSink)

        fixture.live.hear(VoiceHeard(settled: "the ", revising: "use"))
        fixture.live.hear(VoiceHeard(settled: "the useEffect ", revising: "hook"))
        #expect(store.voice.heard.text == "the useEffect hook")
        #expect(store.draft == "fix. Then commit", "the draft waits for the text to settle")
        #expect(!store.canSend)

        fixture.live.finalText = "Look at the useEffect hook."
        fixture.session.stop(store.voice)
        try await waitUntil("settled") { store.voice.phase == .idle }
        #expect(store.draft == "fix. Then commit Look at the useEffect hook.", "the text joins the draft's end, as the recorder showed")
        #expect(
            store.draftSelection == NSRange(location: (store.draft as NSString).length, length: 0),
            "the caret goes after all the text")
        #expect(store.voiceFocusRequests == 1)
        #expect(!store.voice.showsRecorder)
        #expect(store.voiceSendRequests == 0)
        #expect(await fixture.transcriber.requests.isEmpty, "nothing is uploaded")
        await hold.open()
        try await waitUntil("hold over") { store.canSend }
    }

    @Test func sendLandsTheTextThenAsksForTheDraftToBeSent() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        fixture.live.hear(VoiceHeard(settled: "run the tests", revising: ""))
        fixture.live.finalText = "run the tests"
        fixture.session.stop(store.voice, sending: true)
        #expect(store.voice.sendsWhenSettled)
        try await waitUntil("sent") { store.voiceSendRequests == 1 }
        #expect(store.voiceFocusRequests == 0, "Send leaves the keyboard down")
        #expect(store.draft == "run the tests")
        #expect(store.voice.phase == .idle)
        #expect(store.canSend, "no hold: the user asked to send")
    }

    @Test func stopBeforeRecordingBeginsDropsTheStart() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        let gate = ScriptedTransportCallGate()
        fixture.recorder.permissionGate = gate
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        #expect(store.voice.phase == .starting)
        fixture.session.stop(store.voice)
        #expect(store.voice.phase == .idle)
        #expect(!store.voice.showsRecorder)
        await gate.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.recorder.starts == 0)
    }

    @Test func aMissingModelDownloadsInPlaceThenRecords() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        fixture.live.startError = .modelNotInstalled
        let download = ScriptedTransportCallGate()
        fixture.live.downloadGate = download
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("failed") { store.voice.failure != nil }
        #expect(store.voice.failure == LiveVoiceTranscriberError.modelNotInstalled.failure)
        #expect(store.voice.failure?.downloadsModel == true)
        #expect(store.voice.showsRecorder, "the failure shows in the recorder")
        #expect(!store.voice.isInRecordingMode)
        #expect(fixture.recorder.starts == 0)

        fixture.live.startError = nil
        fixture.session.downloadModel(store.voice)
        try await waitUntil("downloading") { store.voice.phase == .downloadingModel(progress: 0.5) }
        await download.open()
        try await waitUntil("recording") { store.voice.isRecording }
        #expect(fixture.live.downloads == ["zh-CN"])
    }

    @Test func hearingNothingOffersToTryAgain() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        fixture.session.stop(store.voice)
        try await waitUntil("failed") { store.voice.failure != nil }
        #expect(store.voice.failure == .noSpeech)
        #expect(store.voice.failure?.restarts == true)

        fixture.session.start(store.voice)
        try await waitUntil("recording again") { store.voice.isRecording }
    }

    @Test func settlingThatFailsKeepsWhatWasHeard() async throws {
        let fixture = try makeOnDeviceFixture()
        defer { fixture.tearDown() }
        fixture.live.finishError = LiveVoiceTranscriberError.failed
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        fixture.live.hear(VoiceHeard(settled: "run the ", revising: "tests"))
        fixture.session.stop(store.voice)
        try await waitUntil("settled") { store.voice.phase == .idle }
        #expect(store.draft == "run the tests")
    }

    @Test func theMicOpensSetupBeforeAServiceIsSavedAndRecordsNothing() throws {
        let fixture = try makeFixture(ready: false)
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        #expect(fixture.session.toggle(store.voice) == .needsSetup)
        #expect(store.voice.phase == .idle)
        #expect(fixture.recorder.starts == 0)
    }

    @Test func aRecordingLandsOnceAtTheCaretWhileSendWaitsForIt() async throws {
        let fixture = try makeFixture(results: [.success("and add a test")])
        defer { fixture.tearDown() }
        let upload = ScriptedTransportCallGate()
        await fixture.transcriber.gate(using: upload)
        let hold = ScriptedTransportCallGate()
        let store = fixture.makeStore(holdGate: hold)
        store.replaceDraft(with: "fix the bug")

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        #expect(!store.canSend)
        #expect(store.sendAccessibilityHint == "Waiting for Voice Input…")

        fixture.session.toggle(store.voice)
        #expect(store.voice.phase == .transcribing)
        await upload.waitForEntry()
        #expect(await store.send() == .ignored, "Send waits for the text")
        #expect(store.draft == "fix the bug")

        await upload.open()
        try await waitUntil("inserted") { store.draft == "fix the bug and add a test" }
        #expect(store.voice.phase == .idle)
        #expect(store.draftSelection == NSRange(location: 26, length: 0))
        #expect(!store.canSend, "Send waits a moment after the text lands")
        await hold.open()
        try await waitUntil("hold over") { store.canSend }

        let requests = await fixture.transcriber.requests
        #expect(requests.count == 1)
        #expect(requests.first?.endpoint == VoiceInputEndpoint.preset(.openAI))
        #expect(requests.first?.apiKey == "sk-test")
        #expect(requests.first?.audio == fixture.recorder.nextRecording.audio)
        #expect(requests.first?.options.languages == ["zh", "en"])
    }

    @Test func textWaitsUntilTheInputMethodFinishesComposing() async throws {
        let fixture = try makeFixture(results: [.success("把测试跑一下")])
        defer { fixture.tearDown() }
        let store = fixture.makeStore()
        store.applyEditorDraft("请ce", selection: NSRange(location: 3, length: 0))
        store.setEditorComposing(true)

        try await record(store, with: fixture)
        try await waitUntil("text arrived") { await fixture.transcriber.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.draft == "请ce", "marked text is left alone")
        #expect(store.voice.phase == .transcribing)
        #expect(!store.canSend)

        store.applyEditorDraft("请测", selection: NSRange(location: 2, length: 0))
        store.setEditorComposing(false)
        #expect(store.draft == "请测把测试跑一下")
        #expect(store.voice.phase == .idle)
    }

    @Test func aFailedUploadKeepsTheRecordingForRetry() async throws {
        let fixture = try makeFixture(results: [.failure(.network("offline")), .success("retry worked")])
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        try await waitUntil("failed") { store.voice.failure != nil }
        let failure = try #require(store.voice.failure)
        #expect(failure.canRetry)
        #expect(failure.message == "Couldn't reach the speech service. offline")
        #expect(store.draft.isEmpty)
        #expect(store.canSend == false, "an empty draft still cannot send")

        fixture.session.retry(store.voice)
        try await waitUntil("inserted") { store.draft == "retry worked" }
        let requests = await fixture.transcriber.requests
        #expect(requests.map(\.audio) == [fixture.recorder.nextRecording.audio, fixture.recorder.nextRecording.audio])
    }

    @Test func aRejectedKeyPointsToVoiceInputSettings() async throws {
        let fixture = try makeFixture(results: [.failure(.unauthorized("Incorrect API key provided."))])
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        try await waitUntil("failed") { store.voice.failure != nil }
        #expect(store.voice.failure?.opensVoiceInputSettings == true)
        store.replaceDraft(with: "typed instead")
        #expect(store.canSend, "a failure does not hold Send")
        store.voice.dismissFailure()
        #expect(store.voice.phase == .idle)
    }

    @Test func aDeniedMicrophoneSaysWhereToTurnItOn() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.recorder.permission = false
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("failed") { store.voice.failure != nil }
        #expect(store.voice.failure == .microphoneDenied)
        #expect(fixture.recorder.starts == 0)
    }

    @Test func aTooShortRecordingIsNotSent() async throws {
        let fixture = try makeFixture(results: [.success("never")])
        defer { fixture.tearDown() }
        fixture.recorder.nextRecording = VoiceRecording(audio: Data("tap".utf8), duration: 0.2)
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        #expect(store.voice.failure == .tooShort)
        #expect(await fixture.transcriber.requests.isEmpty)
    }

    @Test func theLastDetailLeavingDropsTextStillOnItsWay() async throws {
        let fixture = try makeFixture(results: [.success("too late")])
        defer { fixture.tearDown() }
        let upload = ScriptedTransportCallGate()
        await fixture.transcriber.gate(using: upload)
        let store = fixture.makeStore()
        let composerSession = AgentComposerSession(composer: store)
        let detail = UUID()
        composerSession.detailDidAppear(detail)

        try await record(store, with: fixture)
        await upload.waitForEntry()
        await composerSession.detailDidDisappear(detail)?.value
        #expect(store.voice.phase == .idle)
        await upload.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.draft.isEmpty)
        #expect(store.voice.phase == .idle)
    }

    @Test func aCancelDuringTheMicrophoneRequestNeverStartsRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let permission = ScriptedTransportCallGate()
        fixture.recorder.permissionGate = permission
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        await permission.waitForEntry()
        #expect(store.voice.phase == .starting)
        fixture.session.toggle(store.voice)
        #expect(store.voice.phase == .starting, "the mic waits; only the bar's Cancel ends it")
        store.voice.cancel()
        #expect(store.voice.phase == .idle)
        await permission.open()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.recorder.starts == 0)
        #expect(store.voice.phase == .idle)
    }

    @Test func aSecondTapWhileTheTextIsOnItsWayKeepsIt() async throws {
        let fixture = try makeFixture(results: [.success("keep this")])
        defer { fixture.tearDown() }
        let upload = ScriptedTransportCallGate()
        await fixture.transcriber.gate(using: upload)
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        await upload.waitForEntry()
        fixture.session.toggle(store.voice)
        #expect(store.voice.phase == .transcribing)
        await upload.open()
        try await waitUntil("inserted") { store.draft == "keep this" }
    }

    @Test func theBarFollowsTheMicrophoneOnlyWhileRecording() async throws {
        let fixture = try makeFixture(results: [.success("done")])
        defer { fixture.tearDown() }
        let upload = ScriptedTransportCallGate()
        await fixture.transcriber.gate(using: upload)
        let store = fixture.makeStore()
        fixture.recorder.currentLevel = 0.6

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        try await waitUntil("sampled") { store.voice.levels.count >= 3 }
        #expect(store.voice.levels.allSatisfy { $0 == 0.6 })

        fixture.session.toggle(store.voice)
        let heard = store.voice.levels
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.voice.levels == heard, "transcribing keeps what was heard and samples no more")
        #expect(store.voice.recordedDuration == fixture.recorder.nextRecording.duration)
        await upload.open()
        try await waitUntil("inserted") { store.draft == "done" }

        fixture.session.toggle(store.voice)
        #expect(store.voice.levels.isEmpty, "the next recording starts with a flat bar")
    }

    @Test func theLevelScaleRunsFromAQuietRoomToNearbySpeech() {
        #expect(SystemVoiceRecorder.level(decibels: -160) == 0)
        #expect(SystemVoiceRecorder.level(decibels: -50) == 0)
        #expect(SystemVoiceRecorder.level(decibels: -30) == 0.5)
        #expect(SystemVoiceRecorder.level(decibels: -10) == 1)
        #expect(SystemVoiceRecorder.level(decibels: 0) == 1)
    }

    @Test func anotherComposersMicStopsTheFirstIntoItsOwnDraft() async throws {
        let fixture = try makeFixture(results: [.success("for the first Agent")])
        defer { fixture.tearDown() }
        let first = fixture.makeStore()
        let second = fixture.makeStore()

        fixture.session.toggle(first.voice)
        try await waitUntil("first recording") { first.voice.isRecording }
        fixture.session.toggle(second.voice)
        #expect(first.voice.phase == .transcribing)
        try await waitUntil("second recording") { second.voice.isRecording }
        try await waitUntil("first inserted") { first.draft == "for the first Agent" }
        #expect(second.draft.isEmpty)
        #expect(fixture.recorder.stops == 1)
    }

    @Test func leavingTheScreenOrTheSystemEndingARecordingSendsWhatWasHeard() async throws {
        let fixture = try makeFixture(results: [.success("left"), .success("ended")])
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        store.voice.composerDidLeaveScreen()
        try await waitUntil("inserted") { store.draft == "left" }

        fixture.session.toggle(store.voice)
        try await waitUntil("recording again") { store.voice.isRecording }
        fixture.recorder.onEnded?()
        try await waitUntil("inserted again") { store.draft == "left ended" }
    }

    @Test func savedKeywordsAndPromptGoWithTheRecording() async throws {
        let fixture = try makeFixture(results: [.success("done")])
        defer { fixture.tearDown() }
        fixture.settings.setKeywords(from: "herdr, Heeler")
        fixture.settings.setPrompt("Instructions to a coding agent")
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        try await waitUntil("inserted") { store.draft == "done" }
        let requests = await fixture.transcriber.requests
        #expect(requests.map(\.keywords) == [["herdr", "Heeler"]])
        #expect(requests.map(\.prompt) == ["Instructions to a coding agent"])
    }

    @Test func eachRecordingTakesTheMicrophoneChoiceAtItsStart() async throws {
        let fixture = try makeFixture(results: [.success("one"), .success("two")])
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        try await record(store, with: fixture)
        try await waitUntil("first text") { store.draft == "one" }
        fixture.settings.setAlwaysUsesBuiltInMicrophone(true)
        try await record(store, with: fixture)
        try await waitUntil("second text") { store.draft.hasSuffix("two") }
        #expect(fixture.recorder.builtInMicrophoneStarts == [false, true])
    }

    @Test func directInputCancelsTheRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let store = fixture.makeStore()

        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        store.voice.cancel()
        #expect(store.voice.phase == .idle)
        #expect(fixture.recorder.cancels == 1)
        #expect(fixture.recorder.stops == 0)
    }

    private func record(_ store: AgentComposerStore, with fixture: Fixture) async throws {
        fixture.session.toggle(store.voice)
        try await waitUntil("recording") { store.voice.isRecording }
        fixture.session.toggle(store.voice)
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(2),
        condition: () async -> Bool
    ) async throws {
        var budget = PollBudget(timeout)
        while budget.hasTimeLeft {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
            budget.charge()
        }
        #expect(await condition(), comment)
    }
}

@Suite("Voice Input spacing")
struct VoiceInputSpacingTests {
    struct SpacingCase: CustomTestStringConvertible, Sendable {
        let before: Character?
        let text: String
        let after: Character?
        let expected: String
        var testDescription: String { "\(before.map(String.init) ?? "∅")|\(text)|\(after.map(String.init) ?? "∅")" }
    }

    @Test(
        "Dictated text gets spaces only between words",
        arguments: [
            SpacingCase(before: "g", text: "and more", after: nil, expected: " and more"),
            SpacingCase(before: " ", text: "and more", after: nil, expected: "and more"),
            SpacingCase(before: ".", text: "Next", after: "x", expected: " Next "),
            SpacingCase(before: "a", text: ", then", after: nil, expected: ", then"),
            SpacingCase(before: "请", text: "run tests", after: nil, expected: "run tests"),
            SpacingCase(before: "x", text: "跑一下", after: "y", expected: "跑一下"),
            SpacingCase(before: nil, text: "start", after: "e", expected: "start "),
            SpacingCase(before: nil, text: "start", after: nil, expected: "start"),
        ])
    func spacing(_ spacingCase: SpacingCase) {
        #expect(
            VoiceInputSpacing.fitted(spacingCase.text, after: spacingCase.before, before: spacingCase.after)
                == spacingCase.expected)
    }
}

@MainActor
private final class FakeVoiceRecorder: VoiceRecorder {
    var onEnded: (@MainActor () -> Void)?
    var permission = true
    var permissionGate: ScriptedTransportCallGate?
    var nextRecording = VoiceRecording(audio: Data("RIFF-voice".utf8), duration: 3)
    var currentLevel = 0.0
    private(set) var starts = 0
    private(set) var builtInMicrophoneStarts: [Bool] = []
    private(set) var stops = 0
    private(set) var cancels = 0
    private(set) var hasAudioSink = false
    private var isRecording = false

    func requestPermission() async -> Bool {
        await permissionGate?.waitUntilOpen()
        return permission
    }

    func start(maxDuration _: TimeInterval, builtInMicrophone: Bool, onAudio: VoiceAudioSink?) throws {
        starts += 1
        builtInMicrophoneStarts.append(builtInMicrophone)
        hasAudioSink = onAudio != nil
        isRecording = true
    }

    func stop() throws -> VoiceRecording {
        stops += 1
        isRecording = false
        return nextRecording
    }

    func cancel() {
        if isRecording { cancels += 1 }
        isRecording = false
    }

    func level() -> Double {
        isRecording ? currentLevel : 0
    }
}

@MainActor
private final class FakeLiveTranscriber: LiveVoiceTranscriber {
    var startError: LiveVoiceTranscriberError?
    var finalText = ""
    var finishError: (any Error)?
    var downloadGate: ScriptedTransportCallGate?
    private(set) var started: [(locale: String, keywords: [String])] = []
    private(set) var downloads: [String] = []
    private(set) var cancels = 0
    private var onText: (@MainActor (VoiceHeard) -> Void)?

    func start(
        locale: String, keywords: [String], onText: @escaping @MainActor (VoiceHeard) -> Void
    ) async throws -> VoiceAudioSink {
        started.append((locale, keywords))
        if let startError { throw startError }
        self.onText = onText
        return { _ in }
    }

    /// What the device has heard so far.
    func hear(_ heard: VoiceHeard) {
        onText?(heard)
    }

    func finish() async throws -> String {
        if let finishError { throw finishError }
        return finalText
    }

    func cancel() {
        cancels += 1
    }

    func downloadModel(locale: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        downloads.append(locale)
        progress(0.5)
        await downloadGate?.waitUntilOpen()
    }
}

private actor ScriptedTranscriber {
    private(set) var requests: [VoiceTranscriptionRequest] = []
    private var results: [Result<String, VoiceTranscriptionError>]
    private var gate: ScriptedTransportCallGate?

    init(results: [Result<String, VoiceTranscriptionError>]) {
        self.results = results
    }

    func gate(using gate: ScriptedTransportCallGate) {
        self.gate = gate
    }

    func transcribe(_ request: VoiceTranscriptionRequest) async throws -> String {
        requests.append(request)
        let gate = gate
        self.gate = nil
        await gate?.waitUntilOpen()
        guard !results.isEmpty else { throw VoiceTranscriptionError.unreadableResponse }
        return try results.removeFirst().get()
    }
}

