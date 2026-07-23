import Foundation
import PhotosUI
import SwiftUI

struct PhotosPickerImageSelection: ImageSelection {
    let item: PhotosPickerItem

    func loadData() async throws -> Data {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImagePreparationError.selectionUnavailable
        }
        return data
    }
}
