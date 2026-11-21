import AVFoundation
import Foundation
import ImageIO
import UIKit

/// One image or video attached to the Composer's draft, displayed as a compact
/// pill above the text input while it prepares, uploads, awaits retry, or
/// stands ready with its staged Host path.
struct ComposerImageAttachment: Identifiable, Equatable, Sendable {
    enum MediaKind: String, Equatable, Sendable {
        case image
        case video
    }

    /// Local device metadata and thumbnail retained from `ImagePreparer` or
    /// `FilePreparer`, so the Composer pill and its preview sheet never read
    /// back over SSH.
    struct Preview: Equatable, Sendable {
        let fileURL: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int64
        let thumbnail: UIImage?
        let durationSeconds: Double?

        init(
            fileURL: URL,
            pixelWidth: Int,
            pixelHeight: Int,
            byteCount: Int64,
            thumbnail: UIImage?,
            durationSeconds: Double? = nil
        ) {
            self.fileURL = fileURL
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.byteCount = byteCount
            self.thumbnail = thumbnail
            self.durationSeconds = durationSeconds
        }

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
    let kind: MediaKind
    var preview: Preview?
    var phase: Phase

    init(
        id: UUID = UUID(),
        kind: MediaKind = .image,
        preview: Preview? = nil,
        phase: Phase
    ) {
        self.id = id
        self.kind = kind
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

    /// Extracts a first-frame thumbnail, duration, and natural pixel dimensions
    /// from a local prepared video file so the pill and its player never read
    /// back over SSH.
    nonisolated static func makeVideoPreview(
        from prepared: PreparedFile,
        maximumThumbnailPixelSize: Int = 120
    ) async -> Preview {
        let asset = AVURLAsset(url: prepared.fileURL)
        var durationSeconds: Double?
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                durationSeconds = seconds
            }
        }
        var pixelWidth = 0
        var pixelHeight = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
            let naturalSize = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        {
            let oriented = naturalSize.applying(transform)
            pixelWidth = Int(abs(oriented.width).rounded())
            pixelHeight = Int(abs(oriented.height).rounded())
        }
        let thumbnail: UIImage?
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: maximumThumbnailPixelSize,
            height: maximumThumbnailPixelSize)
        if let cgImage = try? await generator.image(at: .zero).image {
            thumbnail = UIImage(cgImage: cgImage)
        } else {
            thumbnail = nil
        }
        return Preview(
            fileURL: prepared.fileURL,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteCount: prepared.byteCount,
            thumbnail: thumbnail,
            durationSeconds: durationSeconds)
    }

    static func title(at index: Int) -> String {
        title(for: .image, number: index + 1)
    }

    static func title(for kind: MediaKind, number: Int) -> String {
        let formatted = number.formatted()
        switch kind {
        case .image:
            return String(
                localized: "Image \(formatted)",
                comment: "Title of an attached image pill in the Composer, numbered in order (e.g. Image 1).")
        case .video:
            return String(
                localized: "Video \(formatted)",
                comment: "Title of an attached video pill in the Composer, numbered in order (e.g. Video 1).")
        }
    }

    /// 1-based ordinal of `attachment` among pills of the same ``MediaKind``.
    static func displayNumber(
        for attachment: ComposerImageAttachment,
        in attachments: [ComposerImageAttachment]
    ) -> Int {
        var count = 0
        for item in attachments {
            if item.kind == attachment.kind {
                count += 1
            }
            if item.id == attachment.id {
                return count
            }
        }
        return 1
    }

    static func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    func previewTitle(at index: Int) -> String {
        previewTitle(number: index + 1)
    }

    func previewTitle(number: Int) -> String {
        let base = Self.title(for: kind, number: number)
        if kind == .video, let duration = preview?.durationSeconds {
            return "\(base) · \(Self.formattedDuration(duration))"
        }
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
            if kind == .video, let preview {
                let size = preview.byteCount.formatted(.byteCount(style: .file))
                if let duration = preview.durationSeconds {
                    return "\(Self.formattedDuration(duration)) · \(size)"
                }
                if preview.pixelWidth > 0, preview.pixelHeight > 0 {
                    return "\(preview.pixelWidth)×\(preview.pixelHeight) · \(size)"
                }
                return size
            }
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
