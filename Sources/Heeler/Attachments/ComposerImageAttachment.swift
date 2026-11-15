import Foundation
import ImageIO
import UIKit

/// One image attached to the Composer's draft, displayed as a compact pill
/// above the text input while it prepares, uploads, awaits retry, or stands
/// ready with its staged Host path.
struct ComposerImageAttachment: Identifiable, Equatable, Sendable {
    /// Local device metadata and thumbnail retained from `ImagePreparer`, so
    /// the Composer pill and its zoomable preview sheet never read back over SSH.
    struct Preview: Equatable, Sendable {
        let fileURL: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int64
        let thumbnail: UIImage?

        func removeLocalFile(fileManager: FileManager = .default) {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    enum Phase: Equatable, Sendable {
        case queued
        case preparing
        case uploading(AttachmentStageProgress)
        case ready(path: String)
        case failed(message: String, isRetryable: Bool)

        var isPending: Bool {
            switch self {
            case .queued, .preparing, .uploading, .failed:
                true
            case .ready:
                false
            }
        }

        var readyPath: String? {
            if case .ready(let path) = self { return path }
            return nil
        }
    }

    let id: UUID
    var preview: Preview?
    var phase: Phase

    init(id: UUID = UUID(), preview: Preview? = nil, phase: Phase) {
        self.id = id
        self.preview = preview
        self.phase = phase
    }

    nonisolated static func makePreview(
        from prepared: PreparedImage,
        maximumThumbnailPixelSize: Int = 120
    ) -> Preview {
        let thumbnail: UIImage?
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(prepared.fileURL as CFURL, sourceOptions),
            CGImageSourceGetCount(source) > 0
        {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailPixelSize,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                thumbnail = UIImage(cgImage: cgImage)
            } else {
                thumbnail = nil
            }
        } else {
            thumbnail = nil
        }
        return Preview(
            fileURL: prepared.fileURL,
            pixelWidth: prepared.pixelWidth,
            pixelHeight: prepared.pixelHeight,
            byteCount: prepared.byteCount,
            thumbnail: thumbnail)
    }

    static func title(at index: Int) -> String {
        let number = (index + 1).formatted()
        return String(
            localized: "Image \(number)",
            comment: "Title of an attached image pill in the Composer, numbered in order (e.g. Image 1).")
    }

    func previewTitle(at index: Int) -> String {
        let base = Self.title(at: index)
        guard let preview, preview.pixelWidth > 0, preview.pixelHeight > 0 else {
            return base
        }
        return "\(base) · \(preview.pixelWidth)×\(preview.pixelHeight)"
    }

    var subtitle: String {
        switch phase {
        case .queued:
            return String(
                localized: "Waiting…",
                comment: "Subtitle on a queued Composer image pill waiting for an earlier upload to finish.")
        case .preparing:
            return String(
                localized: "Preparing…",
                comment: "Subtitle on a Composer image pill while decoding and resizing locally.")
        case .uploading(let progress):
            let percentage = Int(progress.fractionCompleted * 100)
            let percent = (Double(percentage) / 100)
                .formatted(.percent.precision(.fractionLength(0)))
            return String(
                localized: "Uploading \(percent)…",
                comment: "Subtitle on a Composer image pill while uploading; placeholder is a formatted percentage such as 64%.")
        case .ready(let path):
            if let preview, preview.pixelWidth > 0, preview.pixelHeight > 0 {
                let size = preview.byteCount.formatted(.byteCount(style: .file))
                return "\(preview.pixelWidth)×\(preview.pixelHeight) · \(size)"
            }
            return RemoteHostPath.lastComponent(of: path)
        case .failed:
            return String(
                localized: "Upload failed · Tap to retry",
                comment: "Subtitle on a retryable failed Composer image pill.")
        }
    }
}
