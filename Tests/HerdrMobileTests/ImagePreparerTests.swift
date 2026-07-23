import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import HerdrMobile

@Suite("Image preparer", .serialized)
struct ImagePreparerTests {
    @Test func opaqueInputBecomesMetadataFreeJPEG() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try encodedImage(
            width: 320,
            height: 180,
            alpha: false,
            type: .jpeg,
            properties: [
                kCGImagePropertyExifDictionary: ["UserComment": "private"],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 25.03,
                    kCGImagePropertyGPSLongitude: 121.56,
                ],
            ])
        let preparer = ImagePreparer(directory: directory)

        let prepared = try await preparer.prepare(DataImageSelection(data: source))
        defer { try? prepared.remove() }

        #expect(prepared.format == .jpeg)
        #expect(prepared.pixelWidth == 320)
        #expect(prepared.pixelHeight == 180)
        #expect(prepared.byteCount <= ImagePreparer.maximumEncodedByteCount)
        #expect(prepared.fileURL.pathExtension == "jpg")
        let output = try #require(CGImageSourceCreateWithURL(prepared.fileURL as CFURL, nil))
        #expect(CGImageSourceGetType(output) as String? == UTType.jpeg.identifier)
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test func transparentInputPreservesAlphaAsPNG() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = ImagePreparer(directory: directory)

        let prepared = try await preparer.prepare(
            DataImageSelection(
                data: try encodedImage(width: 64, height: 48, alpha: true, type: .png)))
        defer { try? prepared.remove() }

        #expect(prepared.format == .png)
        let output = try #require(CGImageSourceCreateWithURL(prepared.fileURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
        #expect(image.alphaInfo != .none)
        #expect(image.alphaInfo != .noneSkipFirst)
        #expect(image.alphaInfo != .noneSkipLast)
    }

    @Test func orientationIsAppliedBeforeEncoding() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try encodedImage(
            width: 120,
            height: 80,
            alpha: false,
            type: .jpeg,
            properties: [kCGImagePropertyOrientation: 6])
        let preparer = ImagePreparer(directory: directory)

        let prepared = try await preparer.prepare(DataImageSelection(data: source))
        defer { try? prepared.remove() }

        #expect(prepared.pixelWidth == 80)
        #expect(prepared.pixelHeight == 120)
        let output = try #require(CGImageSourceCreateWithURL(prepared.fileURL as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        let orientation = properties[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == 1)
    }

    @Test func longEdgeIsDownscaledTo4096Pixels() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try encodedImage(
            width: 5_000, height: 1_000, alpha: false, type: .jpeg)
        let preparer = ImagePreparer(directory: directory)

        let prepared = try await preparer.prepare(DataImageSelection(data: source))
        defer { try? prepared.remove() }

        #expect(prepared.pixelWidth == 4_096)
        #expect(prepared.pixelHeight == 819)
    }

    @Test func encodedByteLimitReducesDimensionsWhenQualityIsInsufficient() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try noisyPNG(width: 512, height: 512, alpha: true)
        let configuration = ImagePreparer.Configuration(
            maximumLongEdge: 4_096,
            maximumEncodedByteCount: 40_000,
            maximumSourcePixelCount: 200_000_000)
        let preparer = ImagePreparer(configuration: configuration, directory: directory)

        let prepared = try await preparer.prepare(DataImageSelection(data: source))
        defer { try? prepared.remove() }

        #expect(prepared.format == .png)
        #expect(prepared.byteCount <= 40_000)
        #expect(prepared.pixelWidth < 512)
        #expect(prepared.pixelHeight < 512)
    }

    @Test func impossibleEncodedByteLimitFailsWithoutLeavingOutput() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try encodedImage(
            width: 64, height: 64, alpha: false, type: .jpeg)
        let preparer = ImagePreparer(
            configuration: .init(
                maximumLongEdge: 4_096,
                maximumEncodedByteCount: 1,
                maximumSourcePixelCount: 200_000_000),
            directory: directory)

        await #expect(throws: ImagePreparationError.unableToProduceBoundedOutput) {
            _ = try await preparer.prepare(DataImageSelection(data: source))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func oversizedDecodedInputsAreRejectedBeforeFullResolutionRendering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = ImagePreparer(
            configuration: .init(
                maximumLongEdge: 4_096,
                maximumEncodedByteCount: 16 * 1_024 * 1_024,
                maximumSourcePixelCount: 9_999),
            directory: directory)
        let source = try encodedImage(width: 100, height: 100, alpha: false, type: .jpeg)

        await #expect(throws: ImagePreparationError.sourceTooLarge) {
            _ = try await preparer.prepare(DataImageSelection(data: source))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func malformedInputLeavesNoTemporaryFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = ImagePreparer(directory: directory)

        await #expect(throws: ImagePreparationError.invalidImage) {
            _ = try await preparer.prepare(DataImageSelection(data: Data("not an image".utf8)))
        }

        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func preparedFilesAreProtectedAndExcludedFromBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let preparer = ImagePreparer(directory: directory)
        let prepared = try await preparer.prepare(
            DataImageSelection(
                data: try encodedImage(width: 32, height: 32, alpha: false, type: .jpeg)))
        defer { try? prepared.remove() }

        let attributes = try FileManager.default.attributesOfItem(atPath: prepared.fileURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
#if targetEnvironment(simulator)
        // The simulator accepts the protection attribute but does not expose it
        // through stat. A physical-device acceptance run verifies enforcement.
        #expect(protection == nil || protection == .complete)
#else
        #expect(protection == .complete)
#endif
        let values = try prepared.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func launchCleanupRemovesOnlyPreparedImageRemnants() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let remnant = directory.appendingPathComponent("old.png")
        try Data([1, 2, 3]).write(to: remnant)
        let neighbor = directory.deletingLastPathComponent()
            .appendingPathComponent("keep-\(UUID().uuidString)")
        try Data([4]).write(to: neighbor)
        defer { try? FileManager.default.removeItem(at: neighbor) }

        try ImagePreparer.cleanupRemnants(in: directory)

        #expect(!FileManager.default.fileExists(atPath: remnant.path))
        #expect(FileManager.default.fileExists(atPath: neighbor.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("image-preparer-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func encodedImage(
        width: Int,
        height: Int,
        alpha: Bool,
        type: UTType,
        properties: [CFString: Any] = [:]
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo =
            alpha
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue))
        context.setFillColor(
            alpha
                ? CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.5)
                : CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func noisyPNG(width: Int, height: Int, alpha: Bool) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x1234_5678_9ABC_DEF0
        for index in bytes.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        if !alpha {
            for index in stride(from: 3, to: bytes.count, by: 4) {
                bytes[index] = 255
            }
        }
        let provider = try #require(
            CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
