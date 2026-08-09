import Foundation
import Observation

typealias FileStager =
  @Sendable (PreparedFile, ImageStageProgressReporter) async throws -> StagedFile

struct FileAttachFailure: Sendable, Equatable {
  let message: String
  let isRetryable: Bool
}

struct FileAttachResult: Sendable, Equatable {
  let stagedFile: StagedFile
  var copied: Bool
  var inserted: Bool

  var message: String {
    switch (copied, inserted) {
    case (true, true):
      "File path inserted and copied."
    case (true, false):
      "File path copied, but couldn't be inserted."
    case (false, true):
      "File path inserted, but couldn't be copied."
    case (false, false):
      "File uploaded, but its path couldn't be copied or inserted."
    }
  }
}

enum FileAttachState: Sendable, Equatable {
  case idle
  case preparing
  case uploading(ImageStageProgress)
  case failed(FileAttachFailure)
  case backgroundInterrupted(FileAttachFailure)
  case completed(FileAttachResult)

  var isBusy: Bool {
    switch self {
    case .preparing, .uploading:
      true
    case .idle, .failed, .backgroundInterrupted, .completed:
      false
    }
  }
}

/// Coordinates one Files selection through a protected local copy, Host
/// staging, and insertion into the local Composer draft.
@MainActor
@Observable
final class FileAttachStore {
  private enum CancellationDisposition {
    case user
    case background
    case leaving
  }

  private(set) var state: FileAttachState = .idle

  private let preparer: any FilePreparing
  private let stageFile: FileStager
  private let clipboard: any ImageClipboard
  private weak var composer: (any ComposerDraftOperations)?

  private var preparedFile: PreparedFile?
  private var operationTask: Task<Void, Never>?
  private var operationID: UInt64 = 0
  private var cancellationDisposition: CancellationDisposition?

  init(
    preparer: any FilePreparing = FilePreparer(),
    stageFile: @escaping FileStager,
    clipboard: any ImageClipboard = SystemImageClipboard(),
    composer: any ComposerDraftOperations
  ) {
    self.preparer = preparer
    self.stageFile = stageFile
    self.clipboard = clipboard
    self.composer = composer
  }

  var canSelectFile: Bool {
    !state.isBusy && composer != nil
  }

  func select(_ sourceURL: URL) {
    guard operationTask == nil, composer != nil else { return }
    discardRetainedPreparedFile()
    cancellationDisposition = nil
    operationID &+= 1
    let currentID = operationID
    state = .preparing
    operationTask = Task {
      await runSelection(sourceURL, operationID: currentID)
    }
  }

  func retry() {
    guard operationTask == nil, let preparedFile, composer != nil else { return }
    cancellationDisposition = nil
    operationID &+= 1
    let currentID = operationID
    state = .uploading(
      ImageStageProgress(transferredBytes: 0, totalBytes: preparedFile.byteCount))
    operationTask = Task {
      await runUpload(preparedFile, operationID: currentID)
    }
  }

  func cancel() {
    guard let operationTask else {
      state = .idle
      discardRetainedPreparedFile()
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

  func copyPath() {
    guard case .completed(var result) = state, !result.copied else { return }
    do {
      try clipboard.copy(result.stagedFile.path)
      result.copied = true
      state = .completed(result)
    } catch {}
  }

  func insertPath() {
    guard case .completed(var result) = state, !result.inserted,
      let composer
    else { return }
    composer.insertIntoDraft("\(result.stagedFile.path) ")
    result.inserted = true
    state = .completed(result)
  }

  func dismissResult() {
    guard !state.isBusy else { return }
    discardRetainedPreparedFile()
    state = .idle
  }

  func leave() async {
    if let task = operationTask {
      cancellationDisposition = .leaving
      task.cancel()
      await task.value
    }
    discardRetainedPreparedFile()
    state = .idle
  }

  private func runSelection(_ sourceURL: URL, operationID: UInt64) async {
    var unclaimedFile: PreparedFile?
    do {
      let file = try await preparer.prepare(sourceURL)
      unclaimedFile = file
      try Task.checkCancellation()
      guard operationID == self.operationID else {
        try? file.remove()
        return
      }
      preparedFile = file
      unclaimedFile = nil
      state = .uploading(
        ImageStageProgress(transferredBytes: 0, totalBytes: file.byteCount))
      await runUploadBody(file, operationID: operationID)
    } catch {
      try? unclaimedFile?.remove()
      finish(error: error, operationID: operationID)
    }
  }

  private func runUpload(_ file: PreparedFile, operationID: UInt64) async {
    await runUploadBody(file, operationID: operationID)
  }

  private func runUploadBody(_ file: PreparedFile, operationID: UInt64) async {
    do {
      let staged = try await stageFile(
        file,
        ImageStageProgressReporter { [weak self] progress in
          await self?.receive(progress: progress, operationID: operationID)
        })
      try Task.checkCancellation()
      finishSuccess(staged, operationID: operationID)
    } catch {
      finish(error: error, operationID: operationID)
    }
  }

  private func receive(progress: ImageStageProgress, operationID: UInt64) {
    guard operationID == self.operationID, operationTask != nil else { return }
    state = .uploading(progress)
  }

  private func finishSuccess(_ stagedFile: StagedFile, operationID: UInt64) {
    guard operationID == self.operationID else { return }
    operationTask = nil
    cancellationDisposition = nil
    discardRetainedPreparedFile()

    var copied = false
    do {
      try clipboard.copy(stagedFile.path)
      copied = true
    } catch {}
    var inserted = false
    if let composer {
      composer.insertIntoDraft("\(stagedFile.path) ")
      inserted = true
    }
    state = .completed(
      FileAttachResult(stagedFile: stagedFile, copied: copied, inserted: inserted))
  }

  private func finish(error: any Error, operationID: UInt64) {
    guard operationID == self.operationID else { return }
    operationTask = nil

    if error is CancellationError || (error as? ImageStagingError) == .cancelled
      || cancellationDisposition != nil
    {
      switch cancellationDisposition {
      case .background:
        state = .backgroundInterrupted(
          FileAttachFailure(
            message: "File upload paused when Heeler moved to the background.",
            isRetryable: preparedFile != nil))
      case .user, .leaving, .none:
        discardRetainedPreparedFile()
        state = .idle
      }
      cancellationDisposition = nil
      return
    }

    let failure = Self.failure(for: error)
    if !failure.isRetryable {
      discardRetainedPreparedFile()
    }
    state = .failed(failure)
  }

  private func discardRetainedPreparedFile() {
    try? preparedFile?.remove()
    preparedFile = nil
  }

  private static func failure(for error: any Error) -> FileAttachFailure {
    switch error {
    case TransportError.sshUnreachable:
      FileAttachFailure(
        message: "The Host is not connected. Reconnect, then retry the upload.",
        isRetryable: true)
    case ImageStagingError.sftpUnavailable:
      FileAttachFailure(
        message: "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem.",
        isRetryable: false)
    case let staging as ImageStagingError:
      FileAttachFailure(
        message: "File upload failed.",
        isRetryable: staging.isRetryable)
    case FilePreparationError.selectionUnavailable:
      FileAttachFailure(
        message: "The selected file is no longer available.",
        isRetryable: false)
    case FilePreparationError.sourceTooLarge:
      FileAttachFailure(
        message: "The selected file exceeds the 64 MiB upload limit.",
        isRetryable: false)
    case FilePreparationError.localStorageFailed:
      FileAttachFailure(
        message: "Heeler couldn't prepare the file in protected local storage.",
        isRetryable: false)
    default:
      FileAttachFailure(
        message: "File preparation failed.",
        isRetryable: false)
    }
  }
}
