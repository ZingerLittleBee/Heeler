import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PreparedImageFormat: String, Sendable, Equatable {
    case jpeg
    case png

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    fileprivate var typeIdentifier: CFString {
        switch self {
        case .jpeg: UTType.jpeg.identifier as CFString
        case .png: UTType.png.identifier as CFString
        }
    }
}

/// App-owned normalized image file ready for transport. The random local name
/// carries no Photos filename or metadata.
struct PreparedImage: Sendable, Equatable {
    let fileURL: URL
    let format: PreparedImageFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64

    func remove(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

protocol ImageSelection: Sendable {
    func loadData() async throws -> Data
}

struct DataImageSelection: ImageSelection {
    let data: Data

    func loadData() async throws -> Data {
        data
    }
}

/// Image pick from the system document browser (Files). Holds a security-scoped
/// URL long enough to read bytes, then the existing preparer owns the copy.
struct FileURLImageSelection: ImageSelection {
    let url: URL

    func loadData() async throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImagePreparationError.selectionUnavailable
        }
    }
}

protocol ImagePreparing: Sendable {
    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage
}

enum ImagePreparationError: Error, Sendable, Equatable {
    case selectionUnavailable
    case invalidImage
    case sourceTooLarge
    case unableToProduceBoundedOutput
    case localStorageFailed
}

/// Safely decodes into a bounded thumbnail, applies source orientation, strips
/// metadata by re-encoding from pixels, and writes one protected app-owned file.
actor ImagePreparer: ImagePreparing {
    struct Configuration: Sendable, Equatable {
        let maximumLongEdge: Int
        let maximumEncodedByteCount: Int
        let maximumSourcePixelCount: Int

        init(
            maximumLongEdge: Int,
            maximumEncodedByteCount: Int,
            maximumSourcePixelCount: Int
        ) {
            self.maximumLongEdge = maximumLongEdge
            self.maximumEncodedByteCount = maximumEncodedByteCount
            self.maximumSourcePixelCount = maximumSourcePixelCount
        }
    }

    static let maximumEncodedByteCount = 16 * 1_024 * 1_024
    static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeelerPreparedImages", isDirectory: true)

    private static let defaultConfiguration = Configuration(
        maximumLongEdge: 4_096,
        maximumEncodedByteCount: maximumEncodedByteCount,
        maximumSourcePixelCount: 200_000_000)
    private static let jpegQualities: [CGFloat] = [
        0.90, 0.82, 0.74, 0.66, 0.58, 0.50, 0.42, 0.35,
    ]
    private static let minimumDimension = 16

    private let configuration: Configuration
    private let directory: URL
    private let fileManager: FileManager

    init(
        configuration: Configuration = ImagePreparer.defaultConfiguration,
        directory: URL = ImagePreparer.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.directory = directory
        self.fileManager = fileManager
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        try Task.checkCancellation()
        let sourceData = try await selection.loadData()
        guard !sourceData.isEmpty else { throw ImagePreparationError.selectionUnavailable }
        try Task.checkCancellation()

        do {
            try Self.ensureDirectory(directory, fileManager: fileManager)
        } catch {
            throw ImagePreparationError.localStorageFailed
        }
        let sourceURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).source")
        do {
            try Self.writeProtected(sourceData, to: sourceURL, fileManager: fileManager)
        } catch {
            throw ImagePreparationError.localStorageFailed
        }
        defer { try? fileManager.removeItem(at: sourceURL) }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions),
            CGImageSourceGetCount(source) > 0
        else {
            throw ImagePreparationError.invalidImage
        }
        let dimensions = try Self.sourceDimensions(source)
        guard Self.isSafelyBounded(dimensions, configuration: configuration) else {
            throw ImagePreparationError.sourceTooLarge
        }
        try Task.checkCancellation()

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: configuration.maximumLongEdge,
        ]
        guard
            let orientedImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary)
        else {
            throw ImagePreparationError.invalidImage
        }
        let format: PreparedImageFormat =
            Self.hasAlpha(orientedImage) ? .png : .jpeg
        let encoded = try Self.encodeBounded(
            orientedImage,
            format: format,
            maximumByteCount: configuration.maximumEncodedByteCount)
        try Task.checkCancellation()

        let outputURL = directory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).\(format.fileExtension)")
        do {
            try Self.writeProtected(encoded.data, to: outputURL, fileManager: fileManager)
        } catch {
            throw ImagePreparationError.localStorageFailed
        }
        return PreparedImage(
            fileURL: outputURL,
            format: format,
            pixelWidth: encoded.image.width,
            pixelHeight: encoded.image.height,
            byteCount: Int64(encoded.data.count))
    }

    static func cleanupRemnants(
        in directory: URL = defaultDirectory,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        {
            try fileManager.removeItem(at: url)
        }
    }

    private static func ensureDirectory(_ directory: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private static func writeProtected(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    private static func sourceDimensions(_ source: CGImageSource) throws -> (Int, Int) {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0
        else {
            throw ImagePreparationError.invalidImage
        }
        return (width, height)
    }

    private static func isSafelyBounded(
        _ dimensions: (Int, Int),
        configuration: Configuration
    ) -> Bool {
        let (pixelCount, overflow) = dimensions.0.multipliedReportingOverflow(
            by: dimensions.1)
        return !overflow
            && pixelCount <= configuration.maximumSourcePixelCount
            && dimensions.0 <= 65_535
            && dimensions.1 <= 65_535
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            true
        }
    }

    private struct EncodedImage {
        let image: CGImage
        let data: Data
    }

    private static func encodeBounded(
        _ image: CGImage,
        format: PreparedImageFormat,
        maximumByteCount: Int
    ) throws -> EncodedImage {
        guard maximumByteCount > 0 else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }
        var candidate = image
        while candidate.width >= minimumDimension, candidate.height >= minimumDimension {
            try Task.checkCancellation()
            switch format {
            case .jpeg:
                var smallestData: Data?
                for quality in jpegQualities {
                    try Task.checkCancellation()
                    let data = try encode(candidate, format: format, quality: quality)
                    if data.count <= maximumByteCount {
                        return EncodedImage(image: candidate, data: data)
                    }
                    smallestData = data
                }
                guard let smallestData else {
                    throw ImagePreparationError.unableToProduceBoundedOutput
                }
                candidate = try scaledDown(
                    candidate,
                    currentByteCount: smallestData.count,
                    maximumByteCount: maximumByteCount,
                    preservesAlpha: false)
            case .png:
                let data = try encode(candidate, format: format, quality: nil)
                if data.count <= maximumByteCount {
                    return EncodedImage(image: candidate, data: data)
                }
                candidate = try scaledDown(
                    candidate,
                    currentByteCount: data.count,
                    maximumByteCount: maximumByteCount,
                    preservesAlpha: true)
            }
        }
        throw ImagePreparationError.unableToProduceBoundedOutput
    }

    private static func encode(
        _ image: CGImage,
        format: PreparedImageFormat,
        quality: CGFloat?
    ) throws -> Data {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                format.typeIdentifier,
                1,
                nil)
        else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }
        let properties: CFDictionary?
        if let quality {
            properties = [
                kCGImageDestinationLossyCompressionQuality: quality
            ] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }
        return data as Data
    }

    private static func scaledDown(
        _ image: CGImage,
        currentByteCount: Int,
        maximumByteCount: Int,
        preservesAlpha: Bool
    ) throws -> CGImage {
        let estimated = sqrt(Double(maximumByteCount) / Double(currentByteCount)) * 0.9
        let scale = min(0.8, max(0.25, estimated))
        let width = max(minimumDimension, Int((Double(image.width) * scale).rounded(.down)))
        let height = max(minimumDimension, Int((Double(image.height) * scale).rounded(.down)))
        guard width < image.width || height < image.height else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }

        let alphaInfo: CGImageAlphaInfo = preservesAlpha ? .premultipliedLast : .noneSkipLast
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue).rawValue)
        else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw ImagePreparationError.unableToProduceBoundedOutput
        }
        return scaled
    }
}
