import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit

typealias ImageStageProgressHandler = @Sendable (ImageStageProgress) async -> Void
typealias ImageStager =
    @Sendable (PreparedImage, ImageStageProgressReporter) async throws -> StagedImage

struct ImageStageProgressReporter: Sendable {
    private let handler: ImageStageProgressHandler

    init(_ handler: @escaping ImageStageProgressHandler) {
        self.handler = handler
    }

    func report(_ progress: ImageStageProgress) async {
        await handler(progress)
    }
}

@MainActor
protocol ImageClipboard {
    func copy(_ path: String) throws
}

@MainActor
struct SystemImageClipboard: ImageClipboard {
    static let lifetime: TimeInterval = 24 * 60 * 60

    func copy(_ path: String) throws {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: path]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Self.lifetime),
            ])
    }
}

struct ImageAttachFailure: Sendable, Equatable {
    let message: String
    let isRetryable: Bool
}

struct ImageAttachResult: Sendable, Equatable {
    let stagedImage: StagedImage
    var copied: Bool
    var inserted: Bool

    var message: String {
        switch (copied, inserted) {
        case (true, true):
            "Image path inserted and copied."
        case (true, false):
            "Image path copied, but couldn't be inserted."
        case (false, true):
            "Image path inserted, but couldn't be copied."
        case (false, false):
            "Image uploaded, but its path couldn't be copied or inserted."
        }
    }
}

enum ImageAttachState: Sendable, Equatable {
    case idle
    case preparing
    case uploading(ImageStageProgress)
    case failed(ImageAttachFailure)
    case backgroundInterrupted(ImageAttachFailure)
    case completed(ImageAttachResult)

    var isBusy: Bool {
        switch self {
        case .preparing, .uploading:
            true
        case .idle, .failed, .backgroundInterrupted, .completed:
            false
        }
    }

    var isCompleted: Bool {
        if case .completed = self { true } else { false }
    }

    var completedResult: ImageAttachResult? {
        if case .completed(let result) = self { result } else { nil }
    }

    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }

    var failedValue: ImageAttachFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    var isBackgroundInterrupted: Bool {
        if case .backgroundInterrupted = self { true } else { false }
    }
}

/// Coordinates one selected image from Photos decoding through Host staging
/// and insertion into either the Composer draft or a legacy Attach input. It
/// owns only the app-local prepared file; completed Host files intentionally
/// outlive this screen (ADR 0005).
@MainActor
@Observable
final class ImageAttachStore {
    private enum InsertionDestination {
        case composer
        case terminal(TerminalInputController.SessionGeneration)
    }

    private enum CancellationDisposition {
        case user
        case background
        case leaving
    }

    private(set) var state: ImageAttachState = .idle

    private let preparer: any ImagePreparing
    private let stageImage: ImageStager
    private let clipboard: any ImageClipboard
    private let input: TerminalInputController
    private weak var composer: (any ComposerDraftOperations)?

    private var preparedImage: PreparedImage?
    private var operationTask: Task<Void, Never>?
    private var operationID: UInt64 = 0
    private var cancellationDisposition: CancellationDisposition?

    init(
        preparer: any ImagePreparing = ImagePreparer(),
        stageImage: @escaping ImageStager,
        clipboard: any ImageClipboard = SystemImageClipboard(),
        input: TerminalInputController,
        composer: (any ComposerDraftOperations)? = nil
    ) {
        self.preparer = preparer
        self.stageImage = stageImage
        self.clipboard = clipboard
        self.input = input
        self.composer = composer
    }

    var canSelectImage: Bool {
        !state.isBusy && insertionDestination != nil
    }

    func select(_ selection: any ImageSelection) {
        guard operationTask == nil, let destination = insertionDestination else { return }
        discardRetainedPreparedImage()
        cancellationDisposition = nil
        operationID &+= 1
        let currentID = operationID
        state = .preparing
        pauseInput(for: destination)
        operationTask = Task {
            await runSelection(
                selection,
                destination: destination,
                operationID: currentID)
        }
    }

    func retry() {
        guard operationTask == nil, let preparedImage,
            let destination = insertionDestination
        else { return }
        cancellationDisposition = nil
        operationID &+= 1
        let currentID = operationID
        state = .uploading(
            ImageStageProgress(transferredBytes: 0, totalBytes: preparedImage.byteCount))
        pauseInput(for: destination)
        operationTask = Task {
            await runUpload(
                preparedImage,
                destination: destination,
                operationID: currentID)
        }
    }

    func cancel() {
        guard let operationTask else {
            state = .idle
            discardRetainedPreparedImage()
            return
        }
        cancellationDisposition = .user
        operationTask.cancel()
    }

    func didEnterBackground() {
        guard let operationTask else { return }
        cancellationDisposition = .background
        operationTask.cancel()
    }

    /// Foregrounding never retries implicitly. The retained local file and
    /// explicit retry action make the interruption visible and deterministic.
    func didBecomeActive() {}

    func copyPath() {
        guard case .completed(var result) = state, !result.copied else { return }
        do {
            try clipboard.copy(result.stagedImage.path)
            result.copied = true
            state = .completed(result)
        } catch {
            // The completed result remains available for another explicit try.
        }
    }

    func insertPath() {
        guard case .completed(var result) = state, !result.inserted else { return }
        if let composer {
            composer.insertIntoDraft("\(result.stagedImage.path) ")
            result.inserted = true
        } else {
            result.inserted = input.insertPathIntoCurrentSession(result.stagedImage.path)
        }
        state = .completed(result)
    }

    func dismissResult() {
        guard !state.isBusy else { return }
        discardRetainedPreparedImage()
        state = .idle
    }

    func leaveAttach() async {
        if let task = operationTask {
            cancellationDisposition = .leaving
            task.cancel()
            await task.value
        }
        discardRetainedPreparedImage()
        input.resume()
        state = .idle
    }

    private func runSelection(
        _ selection: any ImageSelection,
        destination: InsertionDestination,
        operationID: UInt64
    ) async {
        var unclaimedImage: PreparedImage?
        do {
            let image = try await preparer.prepare(selection)
            unclaimedImage = image
            try Task.checkCancellation()
            guard operationID == self.operationID else {
                try? image.remove()
                return
            }
            preparedImage = image
            unclaimedImage = nil
            state = .uploading(
                ImageStageProgress(transferredBytes: 0, totalBytes: image.byteCount))
            await runUploadBody(
                image,
                destination: destination,
                operationID: operationID)
        } catch {
            try? unclaimedImage?.remove()
            finish(error: error, operationID: operationID)
        }
    }

    private func runUpload(
        _ image: PreparedImage,
        destination: InsertionDestination,
        operationID: UInt64
    ) async {
        await runUploadBody(
            image,
            destination: destination,
            operationID: operationID)
    }

    private func runUploadBody(
        _ image: PreparedImage,
        destination: InsertionDestination,
        operationID: UInt64
    ) async {
        do {
            let staged = try await stageImage(
                image,
                ImageStageProgressReporter { [weak self] progress in
                    await self?.receive(progress: progress, operationID: operationID)
                })
            try Task.checkCancellation()
            finishSuccess(
                staged,
                destination: destination,
                operationID: operationID)
        } catch {
            finish(error: error, operationID: operationID)
        }
    }

    private func receive(progress: ImageStageProgress, operationID: UInt64) {
        guard operationID == self.operationID, operationTask != nil else { return }
        state = .uploading(progress)
    }

    private func finishSuccess(
        _ stagedImage: StagedImage,
        destination: InsertionDestination,
        operationID: UInt64
    ) {
        guard operationID == self.operationID else { return }
        operationTask = nil
        cancellationDisposition = nil
        discardRetainedPreparedImage()
        resumeInput(for: destination)

        var copied = false
        do {
            try clipboard.copy(stagedImage.path)
            copied = true
        } catch {}
        let inserted: Bool
        switch destination {
        case .composer:
            if let composer {
                composer.insertIntoDraft("\(stagedImage.path) ")
                inserted = true
            } else {
                inserted = false
            }
        case .terminal(let generation):
            inserted = input.insertPath(stagedImage.path, matching: generation)
        }
        state = .completed(
            ImageAttachResult(
                stagedImage: stagedImage,
                copied: copied,
                inserted: inserted))
    }

    private func finish(error: any Error, operationID: UInt64) {
        guard operationID == self.operationID else { return }
        operationTask = nil
        input.resume()

        if Self.isCancellation(error) || cancellationDisposition != nil {
            switch cancellationDisposition {
            case .background:
                state = .backgroundInterrupted(
                    ImageAttachFailure(
                        message: "Image upload paused when herdr moved to the background.",
                        isRetryable: preparedImage != nil))
            case .user, .leaving, .none:
                discardRetainedPreparedImage()
                state = .idle
            }
            cancellationDisposition = nil
            return
        }

        let failure = Self.failure(for: error)
        if !failure.isRetryable {
            discardRetainedPreparedImage()
        }
        state = .failed(failure)
    }

    private func discardRetainedPreparedImage() {
        try? preparedImage?.remove()
        preparedImage = nil
    }

    private var insertionDestination: InsertionDestination? {
        if composer != nil {
            return .composer
        }
        guard let generation = input.liveGeneration else { return nil }
        return .terminal(generation)
    }

    private func pauseInput(for destination: InsertionDestination) {
        guard case .terminal = destination else { return }
        input.pause()
    }

    private func resumeInput(for destination: InsertionDestination) {
        guard case .terminal = destination else { return }
        input.resume()
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ImageStagingError) == .cancelled
    }

    private static func failure(for error: any Error) -> ImageAttachFailure {
        switch error {
        case TransportError.sshUnreachable:
            ImageAttachFailure(
                message: "The Host is not connected. Reconnect, then retry the upload.",
                isRetryable: true)
        case ImageStagingError.sftpUnavailable:
            ImageAttachFailure(
                message: "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem.",
                isRetryable: false)
        case let staging as ImageStagingError:
            ImageAttachFailure(
                message: "Image upload failed.",
                isRetryable: staging.isRetryable)
        case ImagePreparationError.selectionUnavailable:
            ImageAttachFailure(
                message: "The selected photo is no longer available.",
                isRetryable: false)
        case ImagePreparationError.sourceTooLarge:
            ImageAttachFailure(
                message: "The selected image is too large to decode safely.",
                isRetryable: false)
        case ImagePreparationError.invalidImage:
            ImageAttachFailure(
                message: "The selected item is not a readable image.",
                isRetryable: false)
        case ImagePreparationError.unableToProduceBoundedOutput:
            ImageAttachFailure(
                message: "The image could not be reduced below the 16 MiB upload limit.",
                isRetryable: false)
        case ImagePreparationError.localStorageFailed:
            ImageAttachFailure(
                message: "herdr could not prepare the image in protected local storage.",
                isRetryable: false)
        default:
            ImageAttachFailure(
                message: "Image preparation failed.",
                isRetryable: false)
        }
    }
}
