import Foundation
import Observation

/// Owns one cross-media Composer staging workflow. Prepared local files belong
/// to this store; completed Host files intentionally outlive it (ADR 0005).
@MainActor
@Observable
final class ComposerStagingStore {
    enum Source: Sendable {
        case photo(any ImageSelection)
        case file(URL)

        fileprivate var medium: Medium {
            switch self {
            case .photo: .image
            case .file: .file
            }
        }
    }

    enum Command: Sendable, Hashable {
        case cancel
        case retry
        case copyPath
        case dismiss
    }

    enum State: Sendable, Equatable {
        case idle
        case preparing(Medium)
        case uploading(Medium, AttachmentStageProgress)
        case failed(Failure)
        case backgroundInterrupted(Failure)
        case completed(Outcome)

        var isBusy: Bool {
            switch self {
            case .preparing, .uploading:
                true
            case .idle, .failed, .backgroundInterrupted, .completed:
                false
            }
        }
    }

    enum Medium: Sendable, Equatable {
        case image
        case file

        fileprivate var displayName: String {
            switch self {
            case .image: "Image"
            case .file: "File"
            }
        }

        fileprivate var preparationIcon: String {
            switch self {
            case .image: "photo"
            case .file: "doc"
            }
        }
    }

    struct Failure: Sendable, Equatable {
        let medium: Medium
        let message: String
        let isRetryable: Bool
    }

    struct Outcome: Sendable, Equatable {
        let medium: Medium
        let path: String
        var copied: Bool
    }

    struct Presentation: Sendable, Equatable {
        let icon: String
        let title: String
        let accessibilityLabel: String
        let commands: [Command]
    }

    private enum CancellationDisposition {
        case user
        case background
    }

    private struct ImageAdapter: Sendable {
        let preparer: any ImagePreparing
        let stage: ImageStager

        func prepare(_ selection: any ImageSelection) async throws -> PreparedSource {
            .image(try await preparer.prepare(selection))
        }

        func upload(
            _ image: PreparedImage,
            reporter: AttachmentStageProgressReporter
        ) async throws -> StagedSource {
            .image(try await stage(image, reporter))
        }
    }

    private struct FileAdapter: Sendable {
        let preparer: any FilePreparing
        let stage: FileStager

        func prepare(_ sourceURL: URL) async throws -> PreparedSource {
            .file(try await preparer.prepare(sourceURL))
        }

        func upload(
            _ file: PreparedFile,
            reporter: AttachmentStageProgressReporter
        ) async throws -> StagedSource {
            .file(try await stage(file, reporter))
        }
    }

    private enum PreparedSource: Sendable {
        case image(PreparedImage)
        case file(PreparedFile)

        var medium: Medium {
            switch self {
            case .image: .image
            case .file: .file
            }
        }

        var byteCount: Int64 {
            switch self {
            case .image(let image): image.byteCount
            case .file(let file): file.byteCount
            }
        }

        func remove() throws {
            switch self {
            case .image(let image): try image.remove()
            case .file(let file): try file.remove()
            }
        }
    }

    private enum StagedSource: Sendable {
        case image(StagedImage)
        case file(StagedFile)

        var medium: Medium {
            switch self {
            case .image: .image
            case .file: .file
            }
        }

        var path: String {
            switch self {
            case .image(let image): image.path
            case .file(let file): file.path
            }
        }
    }

    private(set) var state: State = .idle

    var canBegin: Bool { !state.isBusy }

    var presentation: Presentation? {
        Self.presentation(for: state)
    }

    private let imageAdapter: ImageAdapter
    private let fileAdapter: FileAdapter
    private let clipboard: any AttachmentClipboard
    private let composer: any ComposerDraftOperations

    private var preparedSource: PreparedSource?
    private var operationTask: Task<Void, Never>?
    private var operationID: UInt64 = 0
    private var cancellationDisposition: CancellationDisposition?

    init(
        imagePreparer: any ImagePreparing = ImagePreparer(),
        filePreparer: any FilePreparing = FilePreparer(),
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager,
        clipboard: any AttachmentClipboard = SystemAttachmentClipboard(),
        composer: any ComposerDraftOperations
    ) {
        imageAdapter = ImageAdapter(preparer: imagePreparer, stage: stageImage)
        fileAdapter = FileAdapter(preparer: filePreparer, stage: stageFile)
        self.clipboard = clipboard
        self.composer = composer
    }

    func begin(_ source: Source) {
        guard !state.isBusy, operationTask == nil else { return }
        discardRetainedPreparedSource()
        cancellationDisposition = nil
        operationID &+= 1
        let currentID = operationID
        state = .preparing(source.medium)
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.runSelection(source, operationID: currentID)
        }
    }

    func perform(_ command: Command) {
        switch command {
        case .cancel:
            cancel()
        case .retry:
            retry()
        case .copyPath:
            copyPath()
        case .dismiss:
            dismiss()
        }
    }

    func didEnterBackground() {
        guard state.isBusy, let operationTask else { return }
        cancellationDisposition = .background
        operationTask.cancel()
    }

    func leave() async {
        operationID &+= 1
        let task = operationTask
        operationTask = nil
        cancellationDisposition = nil
        task?.cancel()
        await task?.value
        discardRetainedPreparedSource()
        state = .idle
    }

    private func cancel() {
        guard state.isBusy, let operationTask else { return }
        cancellationDisposition = .user
        operationTask.cancel()
    }

    private func retry() {
        let failure: Failure
        switch state {
        case .failed(let value), .backgroundInterrupted(let value):
            failure = value
        case .idle, .preparing, .uploading, .completed:
            return
        }
        guard failure.isRetryable, operationTask == nil, let preparedSource,
            preparedSource.medium == failure.medium
        else { return }

        cancellationDisposition = nil
        operationID &+= 1
        let currentID = operationID
        state = .uploading(
            preparedSource.medium,
            AttachmentStageProgress(
                transferredBytes: 0,
                totalBytes: preparedSource.byteCount))
        operationTask = Task { [weak self] in
            guard let self else { return }
            await self.runUpload(preparedSource, operationID: currentID)
        }
    }

    private func copyPath() {
        guard case .completed(var outcome) = state, !outcome.copied else { return }
        do {
            try clipboard.copy(outcome.path)
            outcome.copied = true
            state = .completed(outcome)
        } catch {
            // Keep the completed outcome available for another explicit try.
        }
    }

    private func dismiss() {
        guard !state.isBusy else { return }
        discardRetainedPreparedSource()
        state = .idle
    }

    private func runSelection(_ source: Source, operationID: UInt64) async {
        var unclaimedSource: PreparedSource?
        do {
            let prepared = try await prepare(source)
            unclaimedSource = prepared
            try Task.checkCancellation()
            guard operationID == self.operationID else {
                try? prepared.remove()
                return
            }
            preparedSource = prepared
            unclaimedSource = nil
            state = .uploading(
                prepared.medium,
                AttachmentStageProgress(
                    transferredBytes: 0,
                    totalBytes: prepared.byteCount))
            await runUploadBody(prepared, operationID: operationID)
        } catch {
            try? unclaimedSource?.remove()
            finish(error: error, medium: source.medium, operationID: operationID)
        }
    }

    private func prepare(_ source: Source) async throws -> PreparedSource {
        switch source {
        case .photo(let selection):
            try await imageAdapter.prepare(selection)
        case .file(let sourceURL):
            try await fileAdapter.prepare(sourceURL)
        }
    }

    private func runUpload(_ source: PreparedSource, operationID: UInt64) async {
        await runUploadBody(source, operationID: operationID)
    }

    private func runUploadBody(_ source: PreparedSource, operationID: UInt64) async {
        do {
            let reporter = AttachmentStageProgressReporter { [weak self] progress in
                await self?.receive(progress: progress, operationID: operationID)
            }
            let staged: StagedSource
            switch source {
            case .image(let image):
                staged = try await imageAdapter.upload(image, reporter: reporter)
            case .file(let file):
                staged = try await fileAdapter.upload(file, reporter: reporter)
            }
            try Task.checkCancellation()
            finishSuccess(staged, operationID: operationID)
        } catch {
            finish(error: error, medium: source.medium, operationID: operationID)
        }
    }

    private func receive(progress: AttachmentStageProgress, operationID: UInt64) {
        guard operationID == self.operationID, operationTask != nil,
            case .uploading(let medium, _) = state
        else { return }
        state = .uploading(medium, progress)
    }

    private func finishSuccess(_ staged: StagedSource, operationID: UInt64) {
        guard operationID == self.operationID else { return }
        operationTask = nil
        cancellationDisposition = nil
        discardRetainedPreparedSource()

        var copied = false
        do {
            try clipboard.copy(staged.path)
            copied = true
        } catch {}
        composer.insertIntoDraft("\(staged.path) ")
        state = .completed(
            Outcome(medium: staged.medium, path: staged.path, copied: copied))
    }

    private func finish(error: any Error, medium: Medium, operationID: UInt64) {
        guard operationID == self.operationID else { return }
        operationTask = nil

        if Self.isCancellation(error) || cancellationDisposition != nil {
            switch cancellationDisposition {
            case .background:
                state = .backgroundInterrupted(
                    Failure(
                        medium: medium,
                        message:
                            "\(medium.displayName) upload paused when Heeler moved to the background.",
                        isRetryable: preparedSource != nil))
            case .user, .none:
                discardRetainedPreparedSource()
                state = .idle
            }
            cancellationDisposition = nil
            return
        }

        let failure = Self.failure(for: error, medium: medium)
        if !failure.isRetryable {
            discardRetainedPreparedSource()
        }
        state = .failed(failure)
    }

    private func discardRetainedPreparedSource() {
        try? preparedSource?.remove()
        preparedSource = nil
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AttachmentStagingError) == .cancelled
    }

    private static func failure(for error: any Error, medium: Medium) -> Failure {
        switch error {
        case TransportError.sshUnreachable:
            Failure(
                medium: medium,
                message: "The Host is not connected. Reconnect, then retry the upload.",
                isRetryable: true)
        case AttachmentStagingError.sftpUnavailable:
            Failure(
                medium: medium,
                message: "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem.",
                isRetryable: false)
        case let staging as AttachmentStagingError:
            Failure(
                medium: medium,
                message: "\(medium.displayName) upload failed.",
                isRetryable: staging.isRetryable)
        case ImagePreparationError.selectionUnavailable:
            Failure(
                medium: medium,
                message: "The selected photo is no longer available.",
                isRetryable: false)
        case ImagePreparationError.sourceTooLarge:
            Failure(
                medium: medium,
                message: "The selected image is too large to decode safely.",
                isRetryable: false)
        case ImagePreparationError.invalidImage:
            Failure(
                medium: medium,
                message: "The selected item is not a readable image.",
                isRetryable: false)
        case ImagePreparationError.unableToProduceBoundedOutput:
            Failure(
                medium: medium,
                message: "The image could not be reduced below the 16 MiB upload limit.",
                isRetryable: false)
        case ImagePreparationError.localStorageFailed:
            Failure(
                medium: medium,
                message: "Heeler couldn't prepare the image in protected local storage.",
                isRetryable: false)
        case FilePreparationError.selectionUnavailable:
            Failure(
                medium: medium,
                message: "The selected file is no longer available.",
                isRetryable: false)
        case FilePreparationError.sourceTooLarge:
            Failure(
                medium: medium,
                message: "The selected file exceeds the 64 MiB upload limit.",
                isRetryable: false)
        case FilePreparationError.localStorageFailed:
            Failure(
                medium: medium,
                message: "Heeler couldn't prepare the file in protected local storage.",
                isRetryable: false)
        default:
            Failure(
                medium: medium,
                message: "\(medium.displayName) preparation failed.",
                isRetryable: false)
        }
    }

    private static func presentation(for state: State) -> Presentation? {
        switch state {
        case .idle:
            return nil
        case .preparing(let medium):
            return Presentation(
                icon: medium.preparationIcon,
                title: "Preparing \(medium.displayName)…",
                accessibilityLabel: "Preparing \(medium.displayName)",
                commands: [.cancel])
        case .uploading(let medium, let progress):
            let percentage = Int(progress.fractionCompleted * 100)
            return Presentation(
                icon: "arrow.up.circle",
                title: "Uploading \(medium.displayName)… \(percentage)%",
                accessibilityLabel: "Uploading \(medium.displayName), \(percentage) percent",
                commands: [.cancel])
        case .failed(let failure), .backgroundInterrupted(let failure):
            return Presentation(
                icon: "exclamationmark.triangle",
                title: failure.message,
                accessibilityLabel: failure.message,
                commands: failure.isRetryable ? [.retry, .dismiss] : [.dismiss])
        case .completed(let outcome):
            let title =
                outcome.copied
                ? "\(outcome.medium.displayName) path inserted and copied."
                : "\(outcome.medium.displayName) path inserted, but couldn't be copied."
            return Presentation(
                icon: outcome.copied ? "checkmark.circle" : "info.circle",
                title: title,
                accessibilityLabel: title,
                commands: outcome.copied ? [.dismiss] : [.copyPath, .dismiss])
        }
    }
}
