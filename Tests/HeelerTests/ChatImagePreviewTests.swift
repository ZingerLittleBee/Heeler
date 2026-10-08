import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Chat image file reads")
struct ChatImagePreviewReaderTests {
    @Test func readsInBoundedChunksFromTheRecordedPath() async throws {
        let bytes = Data(repeating: 42, count: 600_000)
        let fixture = ImageFileFixture(data: bytes)
        #expect(try await ChatImagePreviewReader.read(path: "/tmp/picture.png", files: fixture.files) == bytes)
        let reads = await fixture.reads
        #expect(reads.map(\.path) == Array(repeating: "/tmp/picture.png", count: 3))
        #expect(reads.map(\.offset) == [0, 262_144, 524_288])
        #expect(reads.allSatisfy { $0.maxBytes <= 262_144 })
    }

    @Test func missingOversizedAndInvalidPathsDoNotReadBytes() async {
        for issue in [ImageFileFixture.Issue.missing, .tooLarge] {
            let fixture = ImageFileFixture(data: Data([1]), issue: issue)
            await #expect(throws: (any Error).self) {
                try await ChatImagePreviewReader.read(path: "/tmp/picture.png", files: fixture.files)
            }
            #expect(await fixture.reads.isEmpty)
        }
        let fixture = ImageFileFixture(data: Data([1]))
        await #expect(throws: (any Error).self) {
            try await ChatImagePreviewReader.read(path: "https://example.com/image.png", files: fixture.files)
        }
        #expect(await fixture.reads.isEmpty)
    }

    @Test func changedAndTruncatedFilesFailInsteadOfDecodingPartialBytes() async {
        for issue in [ImageFileFixture.Issue.changed, .truncated] {
            let fixture = ImageFileFixture(data: Data([1, 2]), issue: issue)
            await #expect(throws: (any Error).self) {
                try await ChatImagePreviewReader.read(path: "/tmp/picture.png", files: fixture.files)
            }
        }
    }

    @Test func cancelledPreviewDoesNotRead() async {
        let fixture = ImageFileFixture(data: Data([1]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChatImagePreviewReader.read(path: "/tmp/picture.png", files: fixture.files)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.reads.isEmpty)
    }
}

private actor ImageFileFixture {
    enum Issue: Sendable { case missing, tooLarge, changed, truncated }
    let data: Data
    let issue: Issue?
    private(set) var reads: [RemoteFileRange] = []

    init(data: Data, issue: Issue? = nil) { self.data = data; self.issue = issue }

    nonisolated var files: ChatHostFiles {
        ChatHostFiles(
            status: { _ in await self.status() }, list: { _ in nil },
            read: { await self.read($0) }, home: { "/home/test" })
    }

    func status() -> RemoteFileStatus? {
        if issue == .missing { return nil }
        return .init(kind: .regular, size: issue == .tooLarge ? 30_000_000 : UInt64(data.count))
    }

    func read(_ range: RemoteFileRange) -> RemoteFileSlice {
        reads.append(range)
        if issue == .truncated { return .init(data: Data(), length: UInt64(data.count)) }
        let end = min(data.count, Int(range.offset) + range.maxBytes)
        return .init(data: data[Int(range.offset)..<end], length: UInt64(data.count + (issue == .changed ? 1 : 0)))
    }
}

@MainActor
@Suite("Chat image preview", .serialized)
struct ChatImagePreviewTests {
    @Test func decoderAcceptsImagesAndRejectsText() async throws {
        let image = try await ChatImagePreviewDecoder.shared.decode(Self.png())
        #expect(image.width == 240)
        #expect(image.height == 160)
        await #expect(throws: (any Error).self) {
            try await ChatImagePreviewDecoder.shared.decode(Data("not an image".utf8))
        }
    }

    @Test func previewLoadsLazilyAndSupportsZoom() async throws {
        var requests: [String] = []
        let preview = ChatImagePreviewController(path: "/tmp/picture.png") { path in
            requests.append(path)
            return Self.png()
        }
        #expect(requests.isEmpty)
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640), rootViewController: preview) { _ in
            let deadline = ContinuousClock.now + .seconds(3)
            while !preview.isLoaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(preview.isLoaded)
            #expect(requests == ["/tmp/picture.png"])
            let scroll = try #require(preview.view.subviews.compactMap { $0 as? UIScrollView }.first)
            scroll.setZoomScale(2, animated: false)
            #expect(scroll.zoomScale == 2)
            let renderer = UIGraphicsImageRenderer(bounds: preview.view.bounds)
            let image = renderer.image { _ in preview.view.drawHierarchy(in: preview.view.bounds, afterScreenUpdates: true) }
            Attachment.record(image, named: "chat-image-preview-zoomed", as: .png)
        }
    }

    @Test func unavailableImageOffersRetry() async throws {
        let preview = ChatImagePreviewController(path: "/tmp/deleted.png") { _ in throw ChatImagePreviewError.missing }
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640), rootViewController: preview) { _ in
            let deadline = ContinuousClock.now + .seconds(3)
            let message = try #require(preview.view.subviews.compactMap { $0 as? UILabel }.first)
            while message.text == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(message.text == "This image is no longer on the Host.")
            #expect(preview.view.subviews.compactMap { $0 as? UIButton }.first?.isHidden == false)
        }
    }

    private static func png() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 40, width: 120, height: 80))
        }
    }
}

@MainActor
@Suite("Chat tool title layout")
struct ChatToolTitleLayoutTests {
    @Test func searchIconSharesTheTitleRowAboveTheSubtitle() throws {
        let tool = ChatToolActivity(
            kind: .search, name: "search", title: "cat Sources/Heeler/Images/ImagePreparer.swift | head -160; search files",
            subtitle: "ChatHostFiles", status: .succeeded)
        let row = ChatRow(id: .entry(ChatEntryID("search")), content: .tool(tool), revision: 1, topSpacing: 0)
        let renderer = ImageRenderer(content: ChatRowView(row: row, isExpanded: false, actions: .init(
            toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: ""))
            .padding(.vertical, 16).frame(width: 390).background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        Attachment.record(try #require(renderer.uiImage), named: "chat-search-title-alignment", as: .png)
    }
}
