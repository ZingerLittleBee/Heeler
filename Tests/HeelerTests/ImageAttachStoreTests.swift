import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Image attach store")
struct ImageAttachStoreTests {
    @Test func successfulUploadCopiesThenInsertsIntoCapturedSession() async throws {
        let fixture = try await makeFixture()
        let events = ImageAttachEventRecorder()
        fixture.clipboard.onCopy = { path in events.record(.copied(path)) }
        fixture.input.endSession(fixture.generation)
        let generation = fixture.input.beginSession { data in
            events.record(.sent(String(decoding: data, as: UTF8.self)))
        }

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }

        #expect(
            events.events == [
                .copied("/tmp/staged/image.jpg"),
                .sent("/tmp/staged/image.jpg"),
                .sent(" "),
            ])
        #expect(
            fixture.store.state
                == .completed(
                    ImageAttachResult(
                        stagedImage: try StagedImage(path: "/tmp/staged/image.jpg"),
                        copied: true,
                        inserted: true)))
        #expect(fixture.input.liveGeneration == generation)
        #expect(!fixture.input.isPaused)
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
    }

    @Test func sessionGenerationChangeSuppressesAutomaticInsertion() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)
        var sent = Data()

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.input.endSession(fixture.generation)
        _ = fixture.input.beginSession { sent.append($0) }
        await stageGate.open()
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }

        #expect(sent.isEmpty)
        #expect(fixture.clipboard.copiedPaths == ["/tmp/staged/image.jpg"])
        #expect(fixture.store.state.completedResult?.inserted == false)
        #expect(
            fixture.store.state.completedResult?.message
                == "Image path copied, but couldn't be inserted.")
    }

    @Test func terminalInputIsPausedOnlyWhileTheOperationIsRunning() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        #expect(fixture.input.isPaused)
        fixture.input.send(Data("blocked".utf8))
        #expect(fixture.sent.value.isEmpty)

        await stageGate.open()
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }
        #expect(!fixture.input.isPaused)
    }

    @Test func transientFailureRetainsPreparedImageAndRetryUsesCurrentSession() async throws {
        let fixture = try await makeFixture(stageOutcomes: [
            .failure(ImageStagingError.transferFailed),
            .success(try StagedImage(path: "/tmp/staged/retried.jpg")),
        ])

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should fail") { fixture.store.state.isFailed }

        #expect(fixture.store.state.failedValue?.isRetryable == true)
        #expect(FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))

        fixture.store.retry()
        try await waitUntil("retry should complete") {
            fixture.store.state.isCompleted
        }

        #expect(await fixture.transport.stageRequests.count == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
    }

    @Test func dismissingARetryableFailureAbandonsItsPreparedImage() async throws {
        let fixture = try await makeFixture(stageOutcomes: [
            .failure(ImageStagingError.transferFailed)
        ])

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should fail") { fixture.store.state.isFailed }
        #expect(FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))

        fixture.store.dismissResult()

        #expect(fixture.store.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
    }

    @Test func backgroundCancelsWithoutAutomaticForegroundRetry() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.store.didEnterBackground()
        await stageGate.open()
        try await waitUntil("background interruption should surface") {
            fixture.store.state.isBackgroundInterrupted
        }

        let stageCount = await fixture.transport.stageRequests.count
        fixture.store.didBecomeActive()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.transport.stageRequests.count == stageCount)
        #expect(FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))

        fixture.store.retry()
        try await waitUntil("explicit retry should complete") {
            fixture.store.state.isCompleted
        }
    }

    @Test func userCancellationIsSilentAndCleansLocalFile() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.store.cancel()
        await stageGate.open()
        try await waitUntil("cancellation should return to idle") {
            fixture.store.state == .idle
        }

        #expect(!fixture.input.isPaused)
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
    }

    @Test func cancellationAtPreparationHandoffCleansTheUnclaimedFile() async throws {
        let preparationGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(preparationGate: preparationGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("preparation should reach the gate") {
            await preparationGate.entryCount == 1
        }
        fixture.store.cancel()
        await preparationGate.open()
        try await waitUntil("cancellation should return to idle") {
            fixture.store.state == .idle
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
        #expect(await fixture.transport.stageRequests.isEmpty)
    }

    @Test func unavailableSFTPSurfacesActionableNonRetryableFailure() async throws {
        let fixture = try await makeFixture(stageOutcomes: [
            .failure(ImageStagingError.sftpUnavailable)
        ])

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should fail") { fixture.store.state.isFailed }

        let failure = try #require(fixture.store.state.failedValue)
        #expect(!failure.isRetryable)
        #expect(failure.message.contains("SFTP"))
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
    }

    @Test func recoveryActionsRetryOnlyTheirMissingSideEffect() async throws {
        let fixture = try await makeFixture()
        fixture.clipboard.error = ImageClipboardTestError.failed

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }
        let result = try #require(fixture.store.state.completedResult)
        #expect(result.inserted)
        #expect(!result.copied)
        #expect(result.message == "Image path inserted, but couldn't be copied.")

        fixture.clipboard.error = nil
        fixture.store.copyPath()
        #expect(fixture.store.state.completedResult?.copied == true)
        #expect(fixture.clipboard.copiedPaths == ["/tmp/staged/image.jpg"])
        #expect(await fixture.transport.stageRequests.count == 1)
    }

    @Test func explicitInsertPathTargetsTheCurrentLiveSession() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)
        let currentSessionBytes = DataBox()

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.input.endSession(fixture.generation)
        let currentGeneration = fixture.input.beginSession {
            currentSessionBytes.value.append($0)
        }
        await stageGate.open()
        try await waitUntil("image attach should complete without automatic insertion") {
            fixture.store.state.isCompleted
        }
        #expect(fixture.store.state.completedResult?.inserted == false)
        #expect(currentSessionBytes.value.isEmpty)

        fixture.store.insertPath()

        #expect(fixture.input.liveGeneration == currentGeneration)
        #expect(
            currentSessionBytes.value
                == Data("/tmp/staged/image.jpg ".utf8))
        #expect(!currentSessionBytes.value.contains(0x0A))
        #expect(!currentSessionBytes.value.contains(0x0D))
        #expect(fixture.store.state.completedResult?.inserted == true)
        #expect(await fixture.transport.stageRequests.count == 1)
    }

    @Test func failureOfBothPostStageActionsKeepsRecoverableResult() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)
        fixture.clipboard.error = ImageClipboardTestError.failed

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.input.endSession(fixture.generation)
        await stageGate.open()
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }

        let result = try #require(fixture.store.state.completedResult)
        #expect(!result.copied)
        #expect(!result.inserted)
        #expect(
            result.message
                == "Image uploaded, but its path couldn't be copied or inserted.")

        fixture.store.dismissResult()
        #expect(fixture.store.state == .idle)
    }

    @Test func aSecondSelectionIsIgnoredWhileAnOperationIsActive() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.store.select(DataImageSelection(data: Data([0x02])))
        #expect(await fixture.transport.stageRequests.count == 1)

        await stageGate.open()
        try await waitUntil("image attach should complete") {
            fixture.store.state.isCompleted
        }
        #expect(await fixture.transport.stageRequests.count == 1)
    }

    @Test func leavingAttachCancelsAndRemovesOnlyLocalPreparedData() async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(stageGate: stageGate)

        fixture.store.select(DataImageSelection(data: Data([0x01])))
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        let leave = Task { await fixture.store.leaveAttach() }
        await stageGate.open()
        await leave.value

        #expect(fixture.store.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: fixture.prepared.fileURL.path))
        #expect(await fixture.transport.stageRequests.count == 1)
    }

    private struct Fixture {
        let store: ImageAttachStore
        let transport: ScriptedTransport
        let clipboard: RecordingImageClipboard
        let input: TerminalInputController
        let generation: TerminalInputController.SessionGeneration
        let prepared: PreparedImage
        let sent: DataBox
    }

    private func makeFixture(
        stageOutcomes: [Result<StagedImage, ImageStagingError>] = [
            .success(try! StagedImage(path: "/tmp/staged/image.jpg"))
        ],
        stageGate: ScriptedTransportCallGate? = nil,
        preparationGate: ScriptedTransportCallGate? = nil
    ) async throws -> Fixture {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-attach-\(UUID().uuidString).jpg")
        try Data(repeating: 0x41, count: 128).write(to: fileURL)
        let prepared = PreparedImage(
            fileURL: fileURL,
            format: .jpeg,
            pixelWidth: 16,
            pixelHeight: 16,
            byteCount: 128)
        let preparer = ScriptedImagePreparer(
            prepared: prepared,
            gate: preparationGate)
        let transport = ScriptedTransport()
        await transport.configureImageStaging(outcomes: stageOutcomes, gate: stageGate)
        let clipboard = RecordingImageClipboard()
        let input = TerminalInputController()
        let sent = DataBox()
        let generation = input.beginSession { sent.value.append($0) }
        let store = ImageAttachStore(
            preparer: preparer,
            stageImage: { image, reporter in
                try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            clipboard: clipboard,
            input: input)
        return Fixture(
            store: store,
            transport: transport,
            clipboard: clipboard,
            input: input,
            generation: generation,
            prepared: prepared,
            sent: sent)
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }
}

private actor ScriptedImagePreparer: ImagePreparing {
    let prepared: PreparedImage
    let gate: ScriptedTransportCallGate?

    init(prepared: PreparedImage, gate: ScriptedTransportCallGate?) {
        self.prepared = prepared
        self.gate = gate
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        await gate?.waitUntilOpen()
        return prepared
    }
}

@MainActor
private final class RecordingImageClipboard: ImageClipboard {
    var copiedPaths: [String] = []
    var error: (any Error)?
    var onCopy: ((String) -> Void)?

    func copy(_ path: String) throws {
        if let error { throw error }
        copiedPaths.append(path)
        onCopy?(path)
    }
}

private enum ImageClipboardTestError: Error {
    case failed
}

@MainActor
private final class DataBox {
    var value = Data()
}

@MainActor
private final class ImageAttachEventRecorder {
    enum Event: Equatable {
        case copied(String)
        case sent(String)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}
