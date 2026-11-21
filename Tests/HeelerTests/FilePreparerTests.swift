import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import Heeler

@Suite("File preparer")
struct FilePreparerTests {
    @Test func preparedFileNormalizesUnsafeExtensions() {
        let file = PreparedFile(
            fileURL: URL(fileURLWithPath: "/tmp/source"),
            fileExtension: "../SH",
            byteCount: 1)

        #expect(file.fileExtension.isEmpty)
        #expect(file.remoteFilename == "file")
    }

    /// The Host copy keeps the picked name, cleaned as herdr-core's `terminal.put`
    /// cleans one, so both routes land the same name. The second Windows run's
    /// files went as `file.bin` instead.
    @Test(arguments: [
        ("My Report (final).PDF", "My_Report__final_.pdf"),
        ("keep 15.bin", "keep_15.bin"),
        ("报告.pdf", "file.pdf"),
        ("..hidden.txt", "hidden.txt"),
        ("archive.tar.gz", "archive.tar.gz"),
        ("notes..md", "notes.md"),
        ("con.txt", "con_.txt"),
        ("AUX.backup.txt", "AUX_.backup.txt"),
        ("console.txt", "console.txt"),
        (String(repeating: "a", count: 80) + ".txt", String(repeating: "a", count: 64) + ".txt"),
    ])
    func aPickedNameNamesTheHostCopyCleaned(picked: String, expected: String) {
        let file = PreparedFile(
            fileURL: URL(fileURLWithPath: "/tmp/source"),
            fileExtension: URL(fileURLWithPath: picked).pathExtension,
            byteCount: 1,
            pickedName: picked)

        #expect(file.remoteFilename == expected)
    }

    @Test func createsProtectedPrivateCopyWithSafeExtension() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-preparer-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = sourceDirectory.appendingPathComponent("Report.TXT")
        let data = Data("attachment contents".utf8)
        try data.write(to: sourceURL)

        let prepared = try await FilePreparer(
            maximumByteCount: 1_024,
            directory: outputDirectory
        )
        .prepare(sourceURL)

        #expect(prepared.fileExtension == "txt")
        #expect(prepared.remoteFilename == "Report.txt")
        #expect(!prepared.fileURL.lastPathComponent.contains("Report"))
        #expect(prepared.byteCount == Int64(data.count))
        #expect(try Data(contentsOf: prepared.fileURL) == data)
        #expect(prepared.fileURL.deletingLastPathComponent() == outputDirectory)
    }

    @Test func rejectsFilesAboveTheConfiguredLimitWithoutLeavingACopy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-preparer-limit-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("large.bin")
        try Data(repeating: 0x41, count: 9).write(to: sourceURL)

        await #expect(throws: FilePreparationError.sourceTooLarge) {
            try await FilePreparer(maximumByteCount: 8, directory: outputDirectory)
                .prepare(sourceURL)
        }
        let remnants = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil)
        #expect(remnants?.isEmpty != false)
    }

    @Test func fileInboxResolvesExtensionsAndCopiesIntoProtectedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-inbox-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = sourceDir.appendingPathComponent("RPReplay_Final123")
        let videoBytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        try videoBytes.write(to: sourceURL)

        let materialized = try FileInbox.copyToInbox(
            from: sourceURL,
            suggestedName: nil,
            fallbackType: .mpeg4Movie,
            maximumByteCount: 1_024,
            inboxRoot: inboxRoot)

        #expect(materialized.url.lastPathComponent == "RPReplay_Final123.mp4")
        #expect(try Data(contentsOf: materialized.url) == videoBytes)
        #expect(materialized.cleanupURL != nil)

        materialized.cleanup()
        #expect(!FileManager.default.fileExists(atPath: materialized.url.path))
    }

    @Test func fileInboxRejectsOversizedFileWithoutCopying() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-inbox-limit-\(UUID().uuidString)", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("clip.mov")
        try Data(repeating: 0x01, count: 16).write(to: sourceURL)

        #expect(throws: FilePreparationError.sourceTooLarge) {
            try FileInbox.copyToInbox(
                from: sourceURL,
                fallbackType: .quickTimeMovie,
                maximumByteCount: 8,
                inboxRoot: inboxRoot)
        }
        #expect(!FileManager.default.fileExists(atPath: inboxRoot.path))
    }

    @Test func clipboardAttachmentPrefersVideoOverAccompanyingThumbnailImage() {
        // Photos copies videos with both a movie UTI and a poster JPEG/HEIC.
        let photosOrder = [UTType.jpeg.identifier, UTType.quickTimeMovie.identifier, UTType.movie.identifier]
        #expect(ClipboardAttachment.preferredVideoType(in: photosOrder) == .quickTimeMovie)

        let mp4First = [UTType.movie.identifier, UTType.mpeg4Movie.identifier, UTType.png.identifier]
        #expect(ClipboardAttachment.preferredVideoType(in: mp4First) == .mpeg4Movie)

        // Images, Live Photos, GIFs, and plain text must never classify as video.
        let imageOnly = [UTType.heic.identifier, UTType.jpeg.identifier, UTType.livePhoto.identifier]
        #expect(ClipboardAttachment.preferredVideoType(in: imageOnly) == nil)
        #expect(ClipboardAttachment.preferredVideoType(in: [UTType.gif.identifier]) == nil)
        #expect(ClipboardAttachment.preferredVideoType(in: [UTType.utf8PlainText.identifier]) == nil)

        // Text-view paste interception checks metadata only.
        #expect(ClipboardAttachment.canPasteInTextView(types: photosOrder, hasImages: true, hasStrings: false))
        #expect(
            ClipboardAttachment.canPasteInTextView(
                types: [UTType.mpeg4Movie.identifier], hasImages: false, hasStrings: false))
        #expect(
            ClipboardAttachment.canPasteInTextView(
                types: [UTType.mpeg4Movie.identifier, UTType.utf8PlainText.identifier],
                hasImages: false,
                hasStrings: true))
        #expect(ClipboardAttachment.canPasteInTextView(types: [UTType.png.identifier], hasImages: true, hasStrings: false))
        #expect(!ClipboardAttachment.canPasteInTextView(types: [UTType.png.identifier], hasImages: true, hasStrings: true))
        #expect(!ClipboardAttachment.canPasteInTextView(types: [UTType.utf8PlainText.identifier], hasImages: false, hasStrings: true))
    }

    @Test @MainActor func clipboardAttachmentReadsVideoFileFromPasteboardHoldingBothVideoAndThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }

        let mp4Bytes = Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        pasteboard.setItems([
            [
                UTType.jpeg.identifier: jpegBytes,
                UTType.mpeg4Movie.identifier: mp4Bytes,
            ]
        ])

        let attachment = ClipboardAttachment.current(pasteboard: pasteboard)
        guard case .file(let selection) = attachment else {
            Issue.record("Expected clipboard video with JPEG thumbnail to route to file staging, got image")
            return
        }

        let materialized = try await selection.materialize()
        defer { materialized.cleanup() }

        #expect(materialized.url.pathExtension.lowercased() == "mp4")
        #expect(try Data(contentsOf: materialized.url) == mp4Bytes)
    }

    @Test @MainActor func clipboardVideoSelectionReadsFileBackedItemProviderOverPosterImage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-video-provider-\(UUID().uuidString)", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movURL = root.appendingPathComponent("IMG_0042.MOV")
        let movBytes = Data([0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        try movBytes.write(to: movURL)

        let provider = NSItemProvider()
        provider.suggestedName = "IMG_0042"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(Data([0xFF, 0xD8, 0xFF, 0xD9]), nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.quickTimeMovie.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(movURL, false, nil)
            return nil
        }

        let selection = ClipboardVideoSelection.fromItemProvider(
            provider,
            preferredType: .movie,
            inboxRoot: inboxRoot)
        let materialized = try await selection.materialize()
        defer { materialized.cleanup() }

        #expect(materialized.url.lastPathComponent == "IMG_0042.mov")
        #expect(try Data(contentsOf: materialized.url) == movBytes)
    }

    @Test func photosPickerMediaClassifiesVideosWhileKeepingLivePhotosAndImagesAsImages() {
        #expect(PhotosPickerMedia.videoType(in: [.mpeg4Movie]) == .mpeg4Movie)
        #expect(PhotosPickerMedia.videoType(in: [.quickTimeMovie, .movie]) == .quickTimeMovie)
        #expect(PhotosPickerMedia.videoType(in: [.movie]) == .movie)
        #expect(PhotosPickerMedia.videoType(in: [.heic, .jpeg]) == nil)
        #expect(PhotosPickerMedia.videoType(in: [.gif]) == nil)
        #expect(PhotosPickerMedia.videoType(in: [.livePhoto, .heic]) == nil)
        #expect(PhotosPickerMedia.videoType(in: [.livePhoto, .quickTimeMovie]) == nil)
    }

    @Test func photosPickerVideoTransferImportsCopiesAndRejectsOversizedOrEmptyFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-video-transfer-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let inboxRoot = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clipURL = sourceDir.appendingPathComponent("screen_capture.mp4")
        let bytes = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70])
        try bytes.write(to: clipURL)

        let imported = PhotosPickerVideoTransfer.importReceivedFile(
            clipURL,
            fallbackType: .movie,
            maximumByteCount: 64,
            inboxRoot: inboxRoot)
        guard case .materialized(let materialized) = imported else {
            Issue.record("Expected materialized video file, got \(imported)")
            return
        }
        #expect(materialized.url.lastPathComponent == "screen_capture.mp4")
        #expect(try Data(contentsOf: materialized.url) == bytes)
        materialized.cleanup()
        #expect(!FileManager.default.fileExists(atPath: materialized.url.path))

        let oversized = PhotosPickerVideoTransfer.importReceivedFile(
            clipURL,
            fallbackType: .movie,
            maximumByteCount: 4,
            inboxRoot: inboxRoot)
        #expect(oversized == .oversized)

        let emptyURL = sourceDir.appendingPathComponent("empty.mov")
        try Data().write(to: emptyURL)
        let empty = PhotosPickerVideoTransfer.importReceivedFile(
            emptyURL,
            fallbackType: .movie,
            maximumByteCount: 64,
            inboxRoot: inboxRoot)
        #expect(empty == .unavailable)
    }
}
