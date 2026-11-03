import Foundation
import ImageIO

/// The Host file an image row shows, as transcripts record it.
enum ChatImagePath {
    /// Resolves only recorded filesystem paths: an absolute path or a
    /// `file:` URL, a relative path joined to the recorded working
    /// directory, or a `~/` path joined to the Host's home directory when
    /// it is known. Joining preserves remote symlink semantics; local URL
    /// standardization must not rewrite a Host's path.
    static func resolve(_ value: String?, cwd: String?, home: String? = nil) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL,
                url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                url.query == nil, url.fragment == nil
            else { return nil }
            let path = url.path(percentEncoded: false)
            return RemoteHostPath.isAbsolute(path) ? path : nil
        }
        if RemoteHostPath.isAbsolute(value) { return value }
        if value.hasPrefix("~/") {
            guard let home, RemoteHostPath.isAbsolute(home) else { return nil }
            let path = RemoteHostPath.childPath(home, name: String(value.dropFirst(2)))
            return RemoteHostPath.isAbsolute(path) ? path : nil
        }
        // Schemes, drive-relative paths and other home-relative paths need
        // context the transcript does not provide. They must not become cwd
        // children.
        guard URLComponents(string: value)?.scheme == nil,
            !value.hasPrefix("~"), !value.hasPrefix("\\"),
            let cwd, RemoteHostPath.isAbsolute(cwd)
        else { return nil }
        let path = RemoteHostPath.childPath(cwd, name: value)
        return RemoteHostPath.isAbsolute(path) ? path : nil
    }

    /// Whether the path names a file of an image type, for a record that
    /// says nothing else about what was read.
    static func hasImageExtension(_ path: String) -> Bool {
        guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return false }
        return imageExtensions.contains(path[path.index(after: dot)...].lowercased())
    }

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
}

/// A Host file as its status reported it: a file written again at the same
/// path reads again.
struct ChatImageStamp: Hashable, Sendable {
    let size: UInt64
    let modificationTime: UInt32?
}

/// Reads only the recorded Host file, on demand. Image bytes never join the
/// transcript cache and reading an image never runs a command on the Host.
enum ChatImagePreviewReader {
    static let maximumBytes = 20 * 1_024 * 1_024

    static func read(path: String, files: ChatHostFiles) async throws -> Data {
        try await read(path: path, stamp: stamp(path: path, files: files), files: files)
    }

    /// The file's status, checked before any of it is read.
    static func stamp(path: String, files: ChatHostFiles) async throws -> ChatImageStamp {
        guard RemoteFilePath.isAcceptable(path) else { throw ChatImagePreviewError.invalidPath }
        try Task.checkCancellation()
        guard let status = try await files.status(path) else { throw ChatImagePreviewError.missing }
        guard status.kind == .regular, let length = status.size, length > 0 else {
            throw ChatImagePreviewError.invalidImage
        }
        guard length <= maximumBytes else { throw ChatImagePreviewError.tooLarge }
        return ChatImageStamp(size: length, modificationTime: status.modificationTime)
    }

    /// The file `stamp` describes, which fails if its length changes.
    static func read(path: String, stamp: ChatImageStamp, files: ChatHostFiles) async throws -> Data {
        guard RemoteFilePath.isAcceptable(path) else { throw ChatImagePreviewError.invalidPath }
        let length = stamp.size
        guard length > 0, length <= maximumBytes else { throw ChatImagePreviewError.tooLarge }
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

    /// The same, in the room a row's thumbnail has.
    var thumbnailMessage: String {
        switch self {
        case .unavailable: "Connect to the Host to show this image"
        case .missing: "No longer on the Host"
        case .tooLarge: "Too large to show (20 MB maximum)"
        case .invalidPath, .invalidImage: "Can't show this file as an image"
        case .changed: "Changed while loading"
        }
    }
}

/// Decode off the main actor, with bounded pixel memory even for compressed
/// images whose dimensions are far larger than their file size suggests.
actor ChatImagePreviewDecoder {
    static let shared = ChatImagePreviewDecoder()

    /// `maximumPixelSize` bounds the long edge: the preview's sheet zooms,
    /// a row's thumbnail does not.
    func decode(_ data: Data, maximumPixelSize: Int = 4_096) throws -> CGImage {
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
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ChatImagePreviewError.invalidImage
        }
        try Task.checkCancellation()
        return image
    }
}
