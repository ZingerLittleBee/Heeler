import Foundation
import ImageIO

/// Reads only the recorded Host file, on demand. Image bytes never join the
/// transcript cache and a long press never runs a command on the Host.
enum ChatImagePreviewReader {
    static let maximumBytes = 20 * 1_024 * 1_024

    static func read(path: String, files: ChatHostFiles) async throws -> Data {
        guard RemoteFilePath.isAcceptable(path) else { throw ChatImagePreviewError.invalidPath }
        try Task.checkCancellation()
        guard let status = try await files.status(path) else { throw ChatImagePreviewError.missing }
        guard status.kind == .regular, let length = status.size, length > 0 else {
            throw ChatImagePreviewError.invalidImage
        }
        guard length <= maximumBytes else { throw ChatImagePreviewError.tooLarge }
        var data = Data()
        while data.count < length {
            try Task.checkCancellation()
            let count = min(256 * 1_024, Int(length) - data.count)
            let slice = try await files.read(.init(path: path, offset: UInt64(data.count), maxBytes: count))
            guard let currentLength = slice.length else { throw ChatImagePreviewError.missing }
            guard currentLength == length, !slice.data.isEmpty, slice.data.count <= count else {
                throw ChatImagePreviewError.changed
            }
            data.append(slice.data)
        }
        try Task.checkCancellation()
        return data
    }
}

enum ChatImagePreviewError: Error, LocalizedError {
    case unavailable, invalidPath, missing, tooLarge, invalidImage, changed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Connect to the Host to preview this image."
        case .invalidPath: "This image has no supported absolute path on the Host."
        case .missing: "This image is no longer on the Host."
        case .tooLarge: "This image is too large to preview (20 MB maximum)."
        case .invalidImage: "This file cannot be displayed as an image."
        case .changed: "The image changed while loading. Try again."
        }
    }
}

/// Decode off the main actor, with bounded pixel memory even for compressed
/// images whose dimensions are far larger than their file size suggests.
actor ChatImagePreviewDecoder {
    static let shared = ChatImagePreviewDecoder()

    func decode(_ data: Data) throws -> CGImage {
        try Task.checkCancellation()
        guard data.count <= ChatImagePreviewReader.maximumBytes,
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue > 0, height.doubleValue > 0,
            width.doubleValue * height.doubleValue <= 200_000_000
        else { throw ChatImagePreviewError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ChatImagePreviewError.invalidImage
        }
        try Task.checkCancellation()
        return image
    }
}
