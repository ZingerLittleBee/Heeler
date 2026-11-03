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
    let data: Data?

    @MainActor
    static func current() -> ClipboardImageSelection {
        let board = UIPasteboard.general
        guard board.hasImages else { return ClipboardImageSelection(data: nil) }
        let types: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .webP, .tiff]
        for type in types {
            if let data = board.data(forPasteboardType: type.identifier), !data.isEmpty {
                return ClipboardImageSelection(data: data)
            }
        }
        return ClipboardImageSelection(data: board.image?.pngData())
    }

    func loadData() async throws -> Data {
        guard let data, !data.isEmpty else { throw ImagePreparationError.clipboardHasNoImage }
        return data
    }
}
