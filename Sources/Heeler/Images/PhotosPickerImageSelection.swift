import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhotosPickerImageSelection: ImageSelection {
    let item: PhotosPickerItem

    func loadData() async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImagePreparationError.selectionUnavailable
        }
        return data
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
    static func current() -> ClipboardImageSelection {
        let board = UIPasteboard.general
        guard board.hasImages else { return ClipboardImageSelection(content: .noImage) }
        let listed = Set(board.types)
        let data: Data? =
            if let type = encodedTypes.first(where: { listed.contains($0.identifier) }) {
                board.data(forPasteboardType: type.identifier)
            } else {
                board.image?.pngData()
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
