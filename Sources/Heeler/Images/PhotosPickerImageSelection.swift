import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

struct PhotosPickerImageSelection: ImageSelection {
    let item: PhotosPickerItem

    func loadData() async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImagePreparationError.selectionUnavailable
        }
        return data
    }
}

/// Classifies `PhotosPickerItem` content types so videos route through file
/// staging while photos and Live Photos stay on the image pipeline.
enum PhotosPickerMedia {
    /// Returns the video `UTType` if `supportedContentTypes` represents a video
    /// asset. Live Photos stay images even if a companion movie type is listed.
    static func videoType(in supportedContentTypes: [UTType]) -> UTType? {
        if supportedContentTypes.contains(where: { $0.conforms(to: .livePhoto) }) {
            return nil
        }
        return ClipboardAttachment.preferredVideoType(
            in: supportedContentTypes.map(\.identifier))
    }
}

/// File-backed `Transferable` for `PhotosPickerItem` videos so Photos exports
/// directly to disk rather than loading the entire video into memory.
struct PhotosPickerVideoTransfer: Transferable, Sendable {
    enum Result: Sendable, Equatable {
        case materialized(MaterializedFile)
        case oversized
        case unavailable
    }

    let result: Result

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PhotosPickerVideoTransfer(
                result: Self.importReceivedFile(received.file, fallbackType: .movie))
        }
        FileRepresentation(importedContentType: .video) { received in
            PhotosPickerVideoTransfer(
                result: Self.importReceivedFile(received.file, fallbackType: .video))
        }
    }

    static func importReceivedFile(
        _ sourceURL: URL,
        fallbackType: UTType,
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        inboxRoot: URL = FilePreparer.defaultDirectory
    ) -> Result {
        do {
            let materialized = try FileInbox.copyToInbox(
                from: sourceURL,
                fallbackType: fallbackType,
                defaultStem: "video",
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
            return .materialized(materialized)
        } catch FilePreparationError.sourceTooLarge {
            return .oversized
        } catch {
            return .unavailable
        }
    }
}

/// Loads a video chosen in `PhotosPicker` via a file-backed `Transferable`
/// copy into a temporary inbox that `ComposerStagingStore` cleans up once
/// `FilePreparer` finishes.
struct PhotosPickerVideoSelection: FileSelection {
    let item: PhotosPickerItem
    var isVideo: Bool { true }

    func materialize() async throws -> MaterializedFile {
        try Task.checkCancellation()
        guard let transfer = try await item.loadTransferable(type: PhotosPickerVideoTransfer.self) else {
            throw FilePreparationError.selectionUnavailable
        }
        if Task.isCancelled {
            if case .materialized(let file) = transfer.result {
                file.cleanup()
            }
            throw CancellationError()
        }
        switch transfer.result {
        case .materialized(let file):
            return file
        case .oversized:
            throw FilePreparationError.sourceTooLarge
        case .unavailable:
            throw FilePreparationError.selectionUnavailable
        }
    }
}

/// One item chosen in `PhotosPicker`, split between image pills and video file
/// uploads.
enum PickedMedia: Sendable {
    case image(any ImageSelection)
    case file(any FileSelection)

    static func from(_ item: PhotosPickerItem) -> PickedMedia {
        if PhotosPickerMedia.videoType(in: item.supportedContentTypes) != nil {
            return .file(PhotosPickerVideoSelection(item: item))
        }
        return .image(PhotosPickerImageSelection(item: item))
    }
}

/// Routes clipboard media to the right staging pipeline: videos go through file
/// staging so a video copied from iOS Photos (which also places a poster
/// thumbnail on the pasteboard) is uploaded as the original video file instead
/// of a still `image.jpg`.
enum ClipboardAttachment: Sendable {
    case image(ClipboardImageSelection)
    case file(any FileSelection)

    /// Concrete movie types preferred when only abstract types appear first.
    private static let preferredVideoTypes: [UTType] = [
        .mpeg4Movie,
        .quickTimeMovie,
        .appleProtectedMPEG4Video,
        .avi,
        .mpeg,
    ]

    /// Whether a text-field Paste action should bypass `UITextView.paste(_:)`
    /// and route through ``ClipboardAttachment``. Reads metadata only (`types`,
    /// `hasImages`, `hasStrings`) so it never triggers the iOS paste prompt.
    static func canPasteInTextView(
        types: [String],
        hasImages: Bool,
        hasStrings: Bool
    ) -> Bool {
        if preferredVideoType(in: types) != nil { return true }
        return hasImages && !hasStrings
    }

    /// Returns the video `UTType` advertised in `types`, if any. Prefers the
    /// first concrete type with a safe filename extension (matching the source's
    /// native format order) over abstract `public.movie` / `public.video`.
    static func preferredVideoType(in types: [String]) -> UTType? {
        var matched: [UTType] = []
        for identifier in types {
            guard let type = UTType(identifier),
                type.conforms(to: .movie) || type.conforms(to: .video)
            else { continue }
            matched.append(type)
        }
        guard !matched.isEmpty else { return nil }
        if let firstConcrete = matched.first(where: {
            $0 != .movie && $0 != .video
                && ($0.preferredFilenameExtension.map { !PreparedFile.safeExtension($0).isEmpty } ?? false)
        }) {
            return firstConcrete
        }
        if let known = preferredVideoTypes.first(where: { candidate in
            matched.contains { $0 == candidate }
        }) {
            return known
        }
        return matched.first
    }

    /// Reads the current pasteboard on the main actor when Paste or Paste Image
    /// is invoked. Checks video types before images so a copied video carrying
    /// a preview thumbnail is staged as a video file.
    @MainActor
    static func current(pasteboard: UIPasteboard = .general) -> ClipboardAttachment {
        if let videoType = preferredVideoType(in: pasteboard.types) {
            return .file(ClipboardVideoSelection.current(from: pasteboard, preferredType: videoType))
        }
        return .image(ClipboardImageSelection.current(pasteboard: pasteboard))
    }
}

/// Transfers an `NSItemProvider` captured on the main actor into its own
/// thread-safe `loadFileRepresentation` callback.
final class ItemProviderBox: @unchecked Sendable {
    let provider: NSItemProvider

    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
}

/// The video on the clipboard when Paste or Paste Image was tapped. Captures
/// the pasteboard's `NSItemProvider` immediately on the main actor so a later
/// copy cannot replace it, then copies the file representation into a temporary
/// inbox off the main actor while `ComposerStagingStore` shows preparing state.
struct ClipboardVideoSelection: FileSelection {
    struct PasteboardFallback: Sendable {
        let pasteboardNameRawValue: String
        let changeCount: Int
    }

    enum Content: Sendable {
        case provider(
            ItemProviderBox,
            typeIdentifier: String,
            preferredType: UTType,
            suggestedName: String?,
            fallback: PasteboardFallback?)
        case data(Data, preferredType: UTType, suggestedName: String?)
        /// The clipboard advertised a video whose bytes did not arrive, as when
        /// Allow Paste is declined.
        case unreadable
    }

    let content: Content
    let maximumByteCount: Int64
    let inboxRoot: URL
    var isVideo: Bool { true }

    init(
        content: Content,
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        inboxRoot: URL = FilePreparer.defaultDirectory
    ) {
        self.content = content
        self.maximumByteCount = maximumByteCount
        self.inboxRoot = inboxRoot
    }

    @MainActor
    static func current(
        from pasteboard: UIPasteboard = .general,
        preferredType: UTType,
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        inboxRoot: URL = FilePreparer.defaultDirectory
    ) -> ClipboardVideoSelection {
        let changeCount = pasteboard.changeCount
        let providers = pasteboard.itemProviders
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(preferredType.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.video.identifier)
        }) {
            let loadType = Self.bestTypeIdentifier(on: provider, fallback: preferredType)
            let resolvedType = UTType(loadType) ?? preferredType
            return ClipboardVideoSelection(
                content: .provider(
                    ItemProviderBox(provider),
                    typeIdentifier: loadType,
                    preferredType: resolvedType,
                    suggestedName: provider.suggestedName,
                    fallback: PasteboardFallback(
                        pasteboardNameRawValue: pasteboard.name.rawValue,
                        changeCount: changeCount)),
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
        }
        return ClipboardVideoSelection(
            content: .unreadable,
            maximumByteCount: maximumByteCount,
            inboxRoot: inboxRoot)
    }

    @MainActor
    static func fromItemProvider(
        _ provider: NSItemProvider,
        preferredType: UTType,
        maximumByteCount: Int64 = Int64(FilePreparer.maximumByteCount),
        inboxRoot: URL = FilePreparer.defaultDirectory
    ) -> ClipboardVideoSelection {
        let loadType = Self.bestTypeIdentifier(on: provider, fallback: preferredType)
        let resolvedType = UTType(loadType) ?? preferredType
        return ClipboardVideoSelection(
            content: .provider(
                ItemProviderBox(provider),
                typeIdentifier: loadType,
                preferredType: resolvedType,
                suggestedName: provider.suggestedName,
                fallback: nil),
            maximumByteCount: maximumByteCount,
            inboxRoot: inboxRoot)
    }

    private static func bestTypeIdentifier(on provider: NSItemProvider, fallback: UTType) -> String {
        if let registered = ClipboardAttachment.preferredVideoType(in: provider.registeredTypeIdentifiers) {
            return registered.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(fallback.identifier) {
            return fallback.identifier
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            return UTType.movie.identifier
        }
        return UTType.video.identifier
    }

    func materialize() async throws -> MaterializedFile {
        try Task.checkCancellation()
        switch content {
        case .unreadable:
            throw FilePreparationError.clipboardUnreadable
        case let .data(data, preferredType, suggestedName):
            return try FileInbox.writeToInbox(
                data,
                suggestedName: suggestedName,
                fallbackType: preferredType,
                defaultStem: "video",
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
        case let .provider(box, typeIdentifier, preferredType, suggestedName, fallback):
            return try await Self.loadFromProvider(
                box,
                typeIdentifier: typeIdentifier,
                preferredType: preferredType,
                suggestedName: suggestedName,
                fallback: fallback,
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
        }
    }

    private static func loadFromProvider(
        _ box: ItemProviderBox,
        typeIdentifier: String,
        preferredType: UTType,
        suggestedName: String?,
        fallback: PasteboardFallback?,
        maximumByteCount: Int64,
        inboxRoot: URL
    ) async throws -> MaterializedFile {
        do {
            return try await loadFileRepresentation(
                box,
                typeIdentifier: typeIdentifier,
                preferredType: preferredType,
                suggestedName: suggestedName,
                maximumByteCount: maximumByteCount,
                inboxRoot: inboxRoot)
        } catch let error as FilePreparationError where error == .sourceTooLarge || error == .localStorageFailed {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall back to `loadDataRepresentation` on the same provider, then
            // to direct `UIPasteboard.data(forPasteboardType:)` guarded by
            // `changeCount` for raw-data pasteboard items (`setData`/`setItems`).
            do {
                return try await loadDataRepresentation(
                    box,
                    typeIdentifier: typeIdentifier,
                    preferredType: preferredType,
                    suggestedName: suggestedName,
                    maximumByteCount: maximumByteCount,
                    inboxRoot: inboxRoot)
            } catch let error as FilePreparationError where error == .sourceTooLarge || error == .localStorageFailed {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard let fallback,
                    let data = await Self.readPasteboardData(
                        fallback: fallback,
                        typeIdentifiers: [typeIdentifier, preferredType.identifier])
                else {
                    throw FilePreparationError.clipboardUnreadable
                }
                try Task.checkCancellation()
                return try FileInbox.writeToInbox(
                    data,
                    suggestedName: suggestedName,
                    fallbackType: preferredType,
                    defaultStem: "video",
                    maximumByteCount: maximumByteCount,
                    inboxRoot: inboxRoot)
            }
        }
    }

    @MainActor
    private static func readPasteboardData(
        fallback: PasteboardFallback,
        typeIdentifiers: [String]
    ) -> Data? {
        guard
            let pasteboard = UIPasteboard(
                name: UIPasteboard.Name(rawValue: fallback.pasteboardNameRawValue),
                create: false),
            pasteboard.changeCount == fallback.changeCount
        else { return nil }
        for identifier in typeIdentifiers {
            if let data = pasteboard.data(forPasteboardType: identifier), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private static func loadFileRepresentation(
        _ box: ItemProviderBox,
        typeIdentifier: String,
        preferredType: UTType,
        suggestedName: String?,
        maximumByteCount: Int64,
        inboxRoot: URL
    ) async throws -> MaterializedFile {
        let state = OSAllocatedUnfairLock(initialState: (progress: Progress?.none, cancelled: false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = box.provider.loadFileRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { url, error in
                    let isCancelled = state.withLock { $0.cancelled }
                    if isCancelled || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let url, error == nil else {
                        continuation.resume(throwing: FilePreparationError.clipboardUnreadable)
                        return
                    }
                    do {
                        let materialized = try FileInbox.copyToInbox(
                            from: url,
                            suggestedName: suggestedName,
                            fallbackType: preferredType,
                            defaultStem: "video",
                            maximumByteCount: maximumByteCount,
                            inboxRoot: inboxRoot)
                        if state.withLock({ $0.cancelled }) {
                            materialized.cleanup()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        continuation.resume(returning: materialized)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let shouldCancel = state.withLock { current -> Bool in
                    current.progress = progress
                    return current.cancelled
                }
                if shouldCancel {
                    progress.cancel()
                }
            }
        } onCancel: {
            let progress = state.withLock { current -> Progress? in
                current.cancelled = true
                return current.progress
            }
            progress?.cancel()
        }
    }

    private static func loadDataRepresentation(
        _ box: ItemProviderBox,
        typeIdentifier: String,
        preferredType: UTType,
        suggestedName: String?,
        maximumByteCount: Int64,
        inboxRoot: URL
    ) async throws -> MaterializedFile {
        let state = OSAllocatedUnfairLock(initialState: (progress: Progress?.none, cancelled: false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let progress = box.provider.loadDataRepresentation(
                    forTypeIdentifier: typeIdentifier
                ) { data, error in
                    let isCancelled = state.withLock { $0.cancelled }
                    if isCancelled || Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard let data, !data.isEmpty, error == nil else {
                        continuation.resume(throwing: FilePreparationError.clipboardUnreadable)
                        return
                    }
                    do {
                        let materialized = try FileInbox.writeToInbox(
                            data,
                            suggestedName: suggestedName,
                            fallbackType: preferredType,
                            defaultStem: "video",
                            maximumByteCount: maximumByteCount,
                            inboxRoot: inboxRoot)
                        if state.withLock({ $0.cancelled }) {
                            materialized.cleanup()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        continuation.resume(returning: materialized)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let shouldCancel = state.withLock { current -> Bool in
                    current.progress = progress
                    return current.cancelled
                }
                if shouldCancel {
                    progress.cancel()
                }
            }
        } onCancel: {
            let progress = state.withLock { current -> Progress? in
                current.cancelled = true
                return current.progress
            }
            progress?.cancel()
        }
    }
}

/// The image on the clipboard when Paste Image was tapped. The bytes are read
/// then, on the main actor, so a later copy cannot change what is staged; an
/// encoded image is kept as copied, and only a bare bitmap is encoded as PNG.
struct ClipboardImageSelection: ImageSelection {
    enum Content: Sendable {
        case image(Data)
        case noImage
        /// The clipboard lists an image whose bytes did not arrive, as when
        /// Allow Paste is declined.
        case unreadable
    }

    private static let encodedTypes: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .webP, .tiff]

    let content: Content

    /// `hasImages` and `types` read no content, so they never ask to paste.
    /// Only the one chosen representation is read.
    @MainActor
    static func current(pasteboard: UIPasteboard = .general) -> ClipboardImageSelection {
        guard pasteboard.hasImages else { return ClipboardImageSelection(content: .noImage) }
        let listed = Set(pasteboard.types)
        let data: Data? =
            if let type = encodedTypes.first(where: { listed.contains($0.identifier) }) {
                pasteboard.data(forPasteboardType: type.identifier)
            } else {
                pasteboard.image?.pngData()
            }
        guard let data, !data.isEmpty else { return ClipboardImageSelection(content: .unreadable) }
        return ClipboardImageSelection(content: .image(data))
    }

    func loadData() async throws -> Data {
        switch content {
        case let .image(data):
            return data
        case .noImage:
            throw ImagePreparationError.clipboardHasNoImage
        case .unreadable:
            throw ImagePreparationError.clipboardUnreadable
        }
    }
}
