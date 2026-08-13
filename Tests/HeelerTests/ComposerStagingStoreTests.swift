import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Composer staging store")
struct ComposerStagingStoreTests {
    @Test(arguments: StagingTestMedium.allCases)
    func successfulUploadCopiesThenInsertsIntoComposer(_ medium: StagingTestMedium) async throws {
        let fixture = try await makeFixture(medium)
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("staging should complete") { fixture.store.state.isCompleted }

        let path = remotePath(for: medium)
        #expect(
            fixture.store.state
                == .completed(
                    ComposerStagingStore.Outcome(
                        medium: medium.storeMedium,
                        path: path,
                        copied: true)))
        #expect(fixture.sideEffects.events == [.copied(path), .inserted("\(path) ")])
        #expect(fixture.composer.draft == "\(path) ")
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(await fixture.stageRequestCount(for: medium) == 1)
        #expect(
            fixture.store.presentation
                == ComposerStagingStore.Presentation(
                    icon: "checkmark.circle",
                    title: "\(medium.displayName) path inserted and copied.",
                    accessibilityLabel: "\(medium.displayName) path inserted and copied.",
                    commands: [.dismiss]))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func transientFailureRetainsPreparationAndRetryCompletes(
        _ medium: StagingTestMedium
    ) async throws {
        let retriedPath = remotePath(for: medium, stem: "retried")
        let fixture = try await makeFixture(
            medium,
            stagePlans: [
                .failure(.transferFailed),
                .success(retriedPath),
            ])
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }

        let failure = try #require(fixture.store.state.failure)
        #expect(failure.medium == medium.storeMedium)
        #expect(failure.isRetryable)
        #expect(fixture.preparedFileExists(for: medium))
        #expect(fixture.store.presentation?.commands == [.retry, .dismiss])

        fixture.store.perform(.retry)
        try await waitUntil("retry should complete") { fixture.store.state.isCompleted }

        #expect(await fixture.stageRequestCount(for: medium) == 2)
        #expect(fixture.composer.draft == "\(retriedPath) ")
        #expect(!fixture.preparedFileExists(for: medium))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func dismissingRetryableFailureDiscardsPreparation(
        _ medium: StagingTestMedium
    ) async throws {
        let fixture = try await makeFixture(
            medium,
            stagePlans: [.failure(.transferFailed)])
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }
        #expect(fixture.preparedFileExists(for: medium))

        fixture.store.perform(.dismiss)

        #expect(fixture.store.state == .idle)
        #expect(fixture.store.presentation == nil)
        #expect(!fixture.preparedFileExists(for: medium))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func backgroundInterruptionRequiresExplicitRetry(_ medium: StagingTestMedium) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        #expect(fixture.store.presentation?.commands == [.cancel])
        fixture.store.didEnterBackground()
        await stageGate.open()
        try await waitUntil("background interruption should surface") {
            fixture.store.state.isBackgroundInterrupted
        }

        let requestCount = await fixture.stageRequestCount(for: medium)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await fixture.stageRequestCount(for: medium) == requestCount)
        #expect(fixture.preparedFileExists(for: medium))
        #expect(fixture.store.presentation?.commands == [.retry, .dismiss])

        fixture.store.perform(.retry)
        try await waitUntil("explicit retry should complete") {
            fixture.store.state.isCompleted
        }
        #expect(await fixture.stageRequestCount(for: medium) == 2)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func userCancellationIsSilentAndDiscardsPreparation(
        _ medium: StagingTestMedium
    ) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        fixture.store.perform(.cancel)
        await stageGate.open()
        try await waitUntil("cancellation should return to idle") {
            fixture.store.state == .idle
        }

        #expect(fixture.store.presentation == nil)
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.composer.draft.isEmpty)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func cancellationAtPreparationHandoffDiscardsUnclaimedFile(
        _ medium: StagingTestMedium
    ) async throws {
        let preparationGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            gates: preparationGates(preparationGate, for: medium))
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("preparation should reach the gate") {
            await preparationGate.entryCount == 1
        }
        fixture.store.perform(.cancel)
        await preparationGate.open()
        try await waitUntil("cancellation should return to idle") {
            fixture.store.state == .idle
        }

        #expect(!fixture.preparedFileExists(for: medium))
        #expect(await fixture.stageRequestCount(for: medium) == 0)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func unavailableSFTPSurfacesNonRetryableFailure(_ medium: StagingTestMedium) async throws {
        let fixture = try await makeFixture(
            medium,
            stagePlans: [.failure(.sftpUnavailable)])
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }

        let failure = try #require(fixture.store.state.failure)
        #expect(failure.medium == medium.storeMedium)
        #expect(!failure.isRetryable)
        #expect(failure.message.contains("SFTP"))
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.store.presentation?.commands == [.dismiss])

        fixture.store.perform(.retry)
        #expect(await fixture.stageRequestCount(for: medium) == 1)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func clipboardRecoveryRetriesOnlyCopy(_ medium: StagingTestMedium) async throws {
        let fixture = try await makeFixture(medium)
        defer { fixture.cleanup() }
        fixture.clipboard.error = StagingClipboardTestError.failed

        fixture.begin(medium)
        try await waitUntil("staging should complete") { fixture.store.state.isCompleted }

        let path = remotePath(for: medium)
        let outcome = try #require(fixture.store.state.outcome)
        #expect(outcome.medium == medium.storeMedium)
        #expect(outcome.path == path)
        #expect(!outcome.copied)
        #expect(fixture.composer.draft == "\(path) ")
        #expect(fixture.store.presentation?.commands == [.copyPath, .dismiss])

        fixture.clipboard.error = nil
        fixture.store.perform(.copyPath)

        #expect(fixture.store.state.outcome?.copied == true)
        #expect(fixture.clipboard.copiedPaths == [path])
        #expect(fixture.composer.draft == "\(path) ")
        #expect(await fixture.stageRequestCount(for: medium) == 1)
        #expect(fixture.store.presentation?.commands == [.dismiss])
    }

    @Test(arguments: StagingTestMedium.allCases)
    func secondSelectionIsIgnoredWhileOperationIsActive(
        _ medium: StagingTestMedium
    ) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("upload should reach the gate") {
            await stageGate.entryCount == 1
        }
        #expect(!fixture.store.canBegin)

        fixture.begin(medium)
        #expect(await fixture.stageRequestCount(for: medium) == 1)

        await stageGate.open()
        try await waitUntil("staging should complete") { fixture.store.state.isCompleted }
        #expect(await fixture.stageRequestCount(for: medium) == 1)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func leaveIsIdempotentAndDiscardsOnlyLocalPreparation(
        _ medium: StagingTestMedium
    ) async throws {
        let stager = NonCooperativeStager(path: remotePath(for: medium))
        let fixture = try await makeFixture(
            medium,
            nonCooperativeStager: stager)
        defer { fixture.cleanup() }

        fixture.begin(medium)
        try await waitUntil("upload should reach the non-cooperative stager") {
            await stager.entryCount == 1
        }
        let leave = Task { await fixture.store.leave() }
        try await waitUntil("leave should cancel the in-flight operation") {
            await stager.hasObservedCancellation()
        }

        await stager.releaseLateProgress()
        try await waitUntil("the stale operation should report late progress") {
            await stager.lateProgressCount == 1
        }
        #expect(
            fixture.store.state
                == .uploading(
                    medium.storeMedium,
                    AttachmentStageProgress(
                        transferredBytes: 0,
                        totalBytes: fixture.preparedByteCount(for: medium))))
        #expect(fixture.composer.draft.isEmpty)
        #expect(fixture.clipboard.copiedPaths.isEmpty)

        await stager.releaseLateSuccess()
        await leave.value

        #expect(await stager.successCount == 1)
        #expect(fixture.store.state == .idle)
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.composer.draft.isEmpty)
        #expect(fixture.clipboard.copiedPaths.isEmpty)

        await fixture.store.leave()
        #expect(fixture.store.state == .idle)
    }

    @Test func fileBeginIsIgnoredWhileImageIsActive() async throws {
        let imageStageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            .image,
            gates: StagingGates(imageStage: imageStageGate))
        defer { fixture.cleanup() }

        fixture.begin(.image)
        try await waitUntil("image upload should reach the gate") {
            await imageStageGate.entryCount == 1
        }
        fixture.begin(.file)

        #expect(await fixture.transport.stageRequests.count == 1)
        #expect(await fixture.transport.fileStageRequests.isEmpty)
        #expect(fixture.store.state.medium == .image)

        await imageStageGate.open()
        try await waitUntil("image staging should complete") {
            fixture.store.state.isCompleted
        }
    }

    @Test func newBeginReplacesCompletedAndRetryableFailureStates() async throws {
        let completedFilePreparationGate = ScriptedTransportCallGate()
        let completedFixture = try await makeFixture(
            .image,
            gates: StagingGates(filePreparation: completedFilePreparationGate))
        defer { completedFixture.cleanup() }

        completedFixture.begin(.image)
        try await waitUntil("image staging should complete") {
            completedFixture.store.state.isCompleted
        }
        #expect(completedFixture.store.state.outcome?.medium == .image)
        #expect(completedFixture.store.presentation?.commands == [.dismiss])

        completedFixture.begin(.file)

        #expect(completedFixture.store.state == .preparing(.file))
        #expect(completedFixture.store.state.outcome == nil)
        #expect(
            completedFixture.store.presentation
                == ComposerStagingStore.Presentation(
                    icon: "doc",
                    title: "Preparing File…",
                    accessibilityLabel: "Preparing File",
                    commands: [.cancel]))

        completedFixture.store.perform(.cancel)
        await completedFilePreparationGate.open()
        try await waitUntil("file cancellation should clear the completed fixture") {
            completedFixture.store.state == .idle
        }

        let failedFilePreparationGate = ScriptedTransportCallGate()
        let failedFixture = try await makeFixture(
            .image,
            stagePlans: [.failure(.transferFailed)],
            gates: StagingGates(filePreparation: failedFilePreparationGate))
        defer { failedFixture.cleanup() }

        failedFixture.begin(.image)
        try await waitUntil("image staging should fail retryably") {
            failedFixture.store.state.isFailed
        }
        #expect(failedFixture.store.state.failure?.isRetryable == true)
        #expect(failedFixture.preparedFileExists(for: .image))
        #expect(failedFixture.store.presentation?.commands == [.retry, .dismiss])

        failedFixture.begin(.file)

        #expect(failedFixture.store.state == .preparing(.file))
        #expect(failedFixture.store.state.failure == nil)
        #expect(!failedFixture.preparedFileExists(for: .image))
        #expect(
            failedFixture.store.presentation
                == ComposerStagingStore.Presentation(
                    icon: "doc",
                    title: "Preparing File…",
                    accessibilityLabel: "Preparing File",
                    commands: [.cancel]))

        failedFixture.store.perform(.cancel)
        await failedFilePreparationGate.open()
        try await waitUntil("file cancellation should clear the failed fixture") {
            failedFixture.store.state == .idle
        }
    }

    private func makeFixture(
        _ selectedMedium: StagingTestMedium,
        stagePlans: [StagingPlan]? = nil,
        gates: StagingGates = StagingGates(),
        nonCooperativeStager: NonCooperativeStager? = nil
    ) async throws -> StagingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("prepared.jpg")
        let fileURL = directory.appendingPathComponent("prepared.txt")
        try Data(repeating: 0x41, count: 128).write(to: imageURL)
        try Data(repeating: 0x42, count: 256).write(to: fileURL)
        let image = PreparedImage(
            fileURL: imageURL,
            format: .jpeg,
            pixelWidth: 16,
            pixelHeight: 16,
            byteCount: 128)
        let file = PreparedFile(fileURL: fileURL, fileExtension: "txt", byteCount: 256)
        let transport = ScriptedTransport()
        let plans = stagePlans ?? [.success(remotePath(for: selectedMedium))]
        let imagePlans =
            selectedMedium == .image
            ? plans : [.success(remotePath(for: .image))]
        let filePlans =
            selectedMedium == .file
            ? plans : [.success(remotePath(for: .file))]
        try await transport.configureImageStaging(
            outcomes: imagePlans.map(Self.imageOutcome),
            gate: gates.imageStage)
        try await transport.configureFileStaging(
            outcomes: filePlans.map(Self.fileOutcome),
            gate: gates.fileStage)
        let sideEffects = StagingSideEffectRecorder()
        let clipboard = RecordingStagingClipboard(sideEffects: sideEffects)
        let composer = RecordingStagingComposer(sideEffects: sideEffects)
        let store = ComposerStagingStore(
            imagePreparer: ScriptedStagingImagePreparer(
                prepared: image,
                gate: gates.imagePreparation),
            filePreparer: ScriptedStagingFilePreparer(
                prepared: file,
                gate: gates.filePreparation),
            stageImage: { image, reporter in
                if selectedMedium == .image, let nonCooperativeStager {
                    return try await nonCooperativeStager.stageImage(
                        image,
                        reporter: reporter)
                }
                return try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            stageFile: { file, reporter in
                if selectedMedium == .file, let nonCooperativeStager {
                    return try await nonCooperativeStager.stageFile(
                        file,
                        reporter: reporter)
                }
                return try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            },
            clipboard: clipboard,
            composer: composer)
        return StagingFixture(
            store: store,
            transport: transport,
            clipboard: clipboard,
            composer: composer,
            sideEffects: sideEffects,
            directory: directory,
            preparedImage: image,
            preparedFile: file)
    }

    private static func imageOutcome(
        _ plan: StagingPlan
    ) throws -> Result<StagedImage, AttachmentStagingError> {
        switch plan {
        case .success(let path): .success(try StagedImage(path: path))
        case .failure(let error): .failure(error)
        }
    }

    private static func fileOutcome(
        _ plan: StagingPlan
    ) throws -> Result<StagedFile, AttachmentStagingError> {
        switch plan {
        case .success(let path): .success(try StagedFile(path: path))
        case .failure(let error): .failure(error)
        }
    }

    private func remotePath(
        for medium: StagingTestMedium,
        stem: String = "source"
    ) -> String {
        switch medium {
        case .image: "/tmp/staged/\(stem).jpg"
        case .file: "/tmp/staged/\(stem).txt"
        }
    }

    private func stageGates(
        _ gate: ScriptedTransportCallGate,
        for medium: StagingTestMedium
    ) -> StagingGates {
        switch medium {
        case .image: StagingGates(imageStage: gate)
        case .file: StagingGates(fileStage: gate)
        }
    }

    private func preparationGates(
        _ gate: ScriptedTransportCallGate,
        for medium: StagingTestMedium
    ) -> StagingGates {
        switch medium {
        case .image: StagingGates(imagePreparation: gate)
        case .file: StagingGates(filePreparation: gate)
        }
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

enum StagingTestMedium: CaseIterable, Sendable {
    case image
    case file

    var storeMedium: ComposerStagingStore.Medium {
        switch self {
        case .image: .image
        case .file: .file
        }
    }

    var displayName: String {
        switch self {
        case .image: "Image"
        case .file: "File"
        }
    }
}

private enum StagingPlan: Sendable {
    case success(String)
    case failure(AttachmentStagingError)
}

private struct StagingGates {
    var imagePreparation: ScriptedTransportCallGate?
    var filePreparation: ScriptedTransportCallGate?
    var imageStage: ScriptedTransportCallGate?
    var fileStage: ScriptedTransportCallGate?

    init(
        imagePreparation: ScriptedTransportCallGate? = nil,
        filePreparation: ScriptedTransportCallGate? = nil,
        imageStage: ScriptedTransportCallGate? = nil,
        fileStage: ScriptedTransportCallGate? = nil
    ) {
        self.imagePreparation = imagePreparation
        self.filePreparation = filePreparation
        self.imageStage = imageStage
        self.fileStage = fileStage
    }
}

@MainActor
private struct StagingFixture {
    let store: ComposerStagingStore
    let transport: ScriptedTransport
    let clipboard: RecordingStagingClipboard
    let composer: RecordingStagingComposer
    let sideEffects: StagingSideEffectRecorder
    let directory: URL
    let preparedImage: PreparedImage
    let preparedFile: PreparedFile

    func begin(_ medium: StagingTestMedium) {
        switch medium {
        case .image:
            store.begin(.photo(DataImageSelection(data: Data([0x01]))))
        case .file:
            store.begin(.file(URL(fileURLWithPath: "/provider/report.txt")))
        }
    }

    func preparedFileExists(for medium: StagingTestMedium) -> Bool {
        let url = medium == .image ? preparedImage.fileURL : preparedFile.fileURL
        return FileManager.default.fileExists(atPath: url.path)
    }

    func preparedByteCount(for medium: StagingTestMedium) -> Int64 {
        medium == .image ? preparedImage.byteCount : preparedFile.byteCount
    }

    func stageRequestCount(for medium: StagingTestMedium) async -> Int {
        switch medium {
        case .image: await transport.stageRequests.count
        case .file: await transport.fileStageRequests.count
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ScriptedStagingImagePreparer: ImagePreparing {
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

private actor ScriptedStagingFilePreparer: FilePreparing {
    let prepared: PreparedFile
    let gate: ScriptedTransportCallGate?

    init(prepared: PreparedFile, gate: ScriptedTransportCallGate?) {
        self.prepared = prepared
        self.gate = gate
    }

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        await gate?.waitUntilOpen()
        return prepared
    }
}

private actor NonCooperativeStager {
    private let path: String
    private let cancellation = StagingCancellationRecorder()
    private let lateProgressGate = ScriptedTransportCallGate()
    private let lateSuccessGate = ScriptedTransportCallGate()
    private(set) var entryCount = 0
    private(set) var lateProgressCount = 0
    private(set) var successCount = 0

    init(path: String) {
        self.path = path
    }

    func stageImage(
        _ image: PreparedImage,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedImage {
        try await stage(
            byteCount: image.byteCount,
            reporter: reporter,
            makeResult: { try StagedImage(path: $0) })
    }

    func stageFile(
        _ file: PreparedFile,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedFile {
        try await stage(
            byteCount: file.byteCount,
            reporter: reporter,
            makeResult: { try StagedFile(path: $0) })
    }

    func hasObservedCancellation() async -> Bool {
        await cancellation.observed
    }

    func releaseLateProgress() async {
        await lateProgressGate.open()
    }

    func releaseLateSuccess() async {
        await lateSuccessGate.open()
    }

    private func stage<Result: Sendable>(
        byteCount: Int64,
        reporter: AttachmentStageProgressReporter,
        makeResult: (String) throws -> Result
    ) async throws -> Result {
        entryCount += 1
        await withTaskCancellationHandler {
            await lateProgressGate.waitUntilOpen()
        } onCancel: { [cancellation] in
            Task { await cancellation.record() }
        }
        await reporter.report(
            AttachmentStageProgress(
                transferredBytes: byteCount,
                totalBytes: byteCount))
        lateProgressCount += 1
        await lateSuccessGate.waitUntilOpen()
        successCount += 1
        return try makeResult(path)
    }
}

private actor StagingCancellationRecorder {
    private(set) var observed = false

    func record() {
        observed = true
    }
}

@MainActor
private final class RecordingStagingClipboard: AttachmentClipboard {
    private let sideEffects: StagingSideEffectRecorder
    private(set) var copiedPaths: [String] = []
    var error: (any Error)?

    init(sideEffects: StagingSideEffectRecorder) {
        self.sideEffects = sideEffects
    }

    func copy(_ path: String) throws {
        if let error { throw error }
        copiedPaths.append(path)
        sideEffects.record(.copied(path))
    }
}

@MainActor
private final class RecordingStagingComposer: ComposerDraftOperations {
    private let sideEffects: StagingSideEffectRecorder
    private(set) var draft = ""

    init(sideEffects: StagingSideEffectRecorder) {
        self.sideEffects = sideEffects
    }

    func replaceDraft(with text: String) {
        draft = text
    }

    func insertIntoDraft(_ text: String) {
        draft.append(text)
        sideEffects.record(.inserted(text))
    }
}

@MainActor
private final class StagingSideEffectRecorder {
    enum Event: Equatable {
        case copied(String)
        case inserted(String)
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

private enum StagingClipboardTestError: Error {
    case failed
}

extension ComposerStagingStore.State {
    fileprivate var isCompleted: Bool {
        if case .completed = self { true } else { false }
    }

    fileprivate var isFailed: Bool {
        if case .failed = self { true } else { false }
    }

    fileprivate var isBackgroundInterrupted: Bool {
        if case .backgroundInterrupted = self { true } else { false }
    }

    fileprivate var failure: ComposerStagingStore.Failure? {
        switch self {
        case .failed(let failure), .backgroundInterrupted(let failure): failure
        case .idle, .preparing, .uploading, .completed: nil
        }
    }

    fileprivate var outcome: ComposerStagingStore.Outcome? {
        if case .completed(let outcome) = self { outcome } else { nil }
    }

    fileprivate var medium: ComposerStagingStore.Medium? {
        switch self {
        case .preparing(let medium), .uploading(let medium, _): medium
        case .failed(let failure), .backgroundInterrupted(let failure): failure.medium
        case .completed(let outcome): outcome.medium
        case .idle: nil
        }
    }
}
