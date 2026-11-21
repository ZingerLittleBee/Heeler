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

@Suite("Chat image links")
struct ChatImageLinkTests {
    @Test(arguments: [
        "/tmp/shot.png", "/Users/dev/Desktop/Screenshot 2026-11-03 at 10.00.00.png", "~/shots/a.JPG",
        "docs/images/logo@2x.png", "logo.webp", "file:///tmp/y%20z.heic", " /tmp/padded.gif ",
    ])
    func aWrittenPathToAnImageNamesIt(_ value: String) {
        #expect(ChatImageLink.path(written: value) == value.trimmingCharacters(in: .whitespaces))
    }

    @Test(arguments: [
        "*.png", ".png", "/tmp/.png", "image/png", #"UIImage(named: "a.png")"#, "https://x.test/a.png",
        "/tmp/a.pdf", "a b.png", "-o.png", "/tmp/dir.png/", #"C:\shots\a.png"#, "~user/a.png", "a:b.png",
        "/tmp/$NAME.png", "/tmp/a.png\n/tmp/b.png",
    ])
    func codeAndOtherFilesNameNoImage(_ value: String) {
        #expect(ChatImageLink.path(written: value) == nil)
    }

    @Test func linksToHostImagesNameThemAndWebLinksDoNot() throws {
        #expect(ChatImageLink.path(linkedBy: try #require(URL(string: "/tmp/a%20b.png"))) == "/tmp/a b.png")
        #expect(ChatImageLink.path(linkedBy: try #require(URL(string: "shots/c.png"))) == "shots/c.png")
        #expect(ChatImageLink.path(linkedBy: try #require(URL(string: "file:///tmp/d.png"))) == "file:///tmp/d.png")
        #expect(ChatImageLink.path(linkedBy: try #require(URL(string: "https://x.test/e.png"))) == nil)
        #expect(ChatImageLink.path(linkedBy: try #require(URL(string: "docs/a.md"))) == nil)
    }

    @Test("Absolute and home paths in prose end where the image's name does", arguments: [
        ("截图在 /tmp/a.png。", ["/tmp/a.png"]),
        ("保存到/tmp/截图.png，然后打开", ["/tmp/截图.png"]),
        ("See /tmp/a.png.", ["/tmp/a.png"]),
        ("(/tmp/a.png) and ~/x/y.webp", ["/tmp/a.png", "~/x/y.webp"]),
        ("/tmp/a.png,/tmp/b.png", ["/tmp/a.png", "/tmp/b.png"]),
        ("/usr/bin/x and --out=/tmp/b.gif", ["/tmp/b.gif"]),
        ("and/or.png https://x.test/a.png ftp://h/b.png", []),
        ("/tmp/a.png.bak /tmp/a.png/thumb.txt /tmp/a.pngx /tmp/.png", []),
    ])
    func prosePaths(_ text: String, _ expected: [String]) {
        #expect(ChatImageLink.pathRanges(in: text).map { String(text[$0]) } == expected)
    }

    @Test func theLinkOpensThePathAsWritten() throws {
        let path = "/tmp/截图 1.png?#&"
        let url = try #require(ChatImageLink.url(for: path))
        #expect(!ChatLinkPolicy.allows(url))
        #expect(ChatImageLink.path(opening: url) == path)
        #expect(ChatImageLink.opening(url) == ChatImageLink.Reference(path: path, title: nil))
        let titledURL = try #require(ChatImageLink.url(for: path, title: "图片 #1"))
        #expect(ChatImageLink.opening(titledURL) == ChatImageLink.Reference(path: path, title: "图片 #1"))
        #expect(ChatImageLink.path(opening: try #require(URL(string: "https://x.test/?path=/a.png"))) == nil)
    }

    @Test func stagedImagePathsShortenToNumberedLabelsWhileKeepingTheirHostPaths() {
        let first =
            "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.Ud2jiH1T/stage-8ecc3e99-15a3-4637-8778-0f6a3f67fb31/image.jpg"
        let second =
            "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.xMNHghek/stage-2b71c120-91df-42da-a910-12ab34cd56ef/image.png"
        let label1 = ChatImageLink.stagedImageLabel(number: 1)
        let label2 = ChatImageLink.stagedImageLabel(number: 2)

        let text = "这个状态显示不对吧 \(first) \(second) "
        let marked = ChatImageLink.marking(text)
        #expect(String(marked.characters) == "这个状态显示不对吧 \(label1) \(label2)")
        #expect(
            ChatImageLink.references(in: marked) == [
                ChatImageLink.Reference(path: first, title: label1),
                ChatImageLink.Reference(path: second, title: label2),
            ])

        // Non-staged paths stay as written while staged paths shorten.
        let mixed = ChatImageLink.marking("Compare /tmp/c.png with \(first) and \(first)")
        #expect(String(mixed.characters) == "Compare /tmp/c.png with \(label1) and \(label1)")
        #expect(
            ChatImageLink.references(in: mixed) == [
                ChatImageLink.Reference(path: "/tmp/c.png", title: nil),
                ChatImageLink.Reference(path: first, title: label1),
            ])

        // Native Windows herdr-core staged image paths shorten as well.
        let windowsPath = #"C:\Users\me\AppData\Local\herdr-core\work\files\t1\image.jpg"#
        let windowsMarked = ChatImageLink.marking("Check \(windowsPath) ")
        #expect(String(windowsMarked.characters) == "Check \(label1)")
        #expect(
            ChatImageLink.references(in: windowsMarked) == [
                ChatImageLink.Reference(path: windowsPath, title: label1)
            ])
    }

    @Test func stagedUserMessageAndPendingEchoExposeNumberedImagesAndCompactExtent() async {
        let first = "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.Ud2jiH1T/stage-11111111/image.jpg"
        let second = "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.Ud2jiH1T/stage-22222222/image.jpg"
        let label1 = ChatImageLink.stagedImageLabel(number: 1)
        let label2 = ChatImageLink.stagedImageLabel(number: 2)
        let rawPrompt = "看看 \(first) \(second) "

        let userEntry = ChatEntry(
            id: ChatEntryID("user"), sourceOffset: 0,
            content: .user(ChatUserMessage(text: rawPrompt)))
        let echo = ChatPendingEcho(
            id: UUID(), text: rawPrompt, state: .sending, stagedImagePaths: [first, second])
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [userEntry], pending: [echo]))

        #expect(rows.count == 2)
        let expectedRefs = [
            ChatImageLink.Reference(path: first, title: label1),
            ChatImageLink.Reference(path: second, title: label2),
        ]
        #expect(rows[0].messageImages == expectedRefs)
        #expect(rows[1].messageImages == expectedRefs)
        #expect(rows[0].copyText == rawPrompt)
        #expect(rows[1].copyText == rawPrompt)
        #expect((rows[0].extent?.textBytes ?? .max) < 40)
    }

    @Test func stagedImageLabelShipsTranslationsInEveryLanguage() {
        #expect(LocalizationTables.table("Localizable", localization: "zh-Hans")?["Image #%@"] == "图片#%@")
        #expect(LocalizationTables.table("Localizable", localization: "zh-Hant")?["Image #%@"] == "圖片#%@")
        #expect(LocalizationTables.table("Localizable", localization: "ja")?["Image #%@"] == "画像#%@")
        #expect(LocalizationTables.table("Localizable", localization: "zh-Hans")?["Video #%@"] == "视频#%@")
        #expect(LocalizationTables.table("Localizable", localization: "zh-Hant")?["Video #%@"] == "影片#%@")
        #expect(LocalizationTables.table("Localizable", localization: "ja")?["Video #%@"] == "動画#%@")
    }

    @Test func stagedVideoPathsShortenToNumberedVideoLabelsAlongsideImages() async {
        let imagePath =
            "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.Ud2jiH1T/stage-11111111/image.jpg"
        let videoPath =
            "/var/folders/rm/2k0dww5x7w145cb1qctpswr80000gn/T//heeler.YhDlgO2n/stage-019cf591/ScreenRecording_11-21-2026_19-14-51_1.mp4"
        let windowsVideo = #"C:\Users\me\AppData\Local\herdr-core\work\files\t1\clip.mov"#
        let imageLabel = ChatImageLink.stagedImageLabel(number: 1)
        let videoLabel = ChatImageLink.stagedVideoLabel(number: 1)

        let rawPrompt = "看录屏 \(imagePath) \(videoPath) "
        let marked = ChatImageLink.marking(rawPrompt)
        #expect(String(marked.characters) == "看录屏 \(imageLabel) \(videoLabel)")
        let refs = ChatImageLink.references(in: marked)
        #expect(
            refs == [
                ChatImageLink.Reference(path: imagePath, title: imageLabel),
                ChatImageLink.Reference(path: videoPath, title: videoLabel),
            ])
        #expect(refs.map(\.mediaKind) == [.image, .video])

        let winMarked = ChatImageLink.marking("Check \(windowsVideo) ")
        #expect(String(winMarked.characters) == "Check \(videoLabel)")
        #expect(ChatImageLink.references(in: winMarked).first?.mediaKind == .video)

        // Non-staged video paths stay as written while still linking as videos.
        let direct = ChatImageLink.marking("Recorded /tmp/demo.mov.")
        #expect(String(direct.characters) == "Recorded /tmp/demo.mov.")
        #expect(ChatImageLink.references(in: direct) == [ChatImageLink.Reference(path: "/tmp/demo.mov", title: nil)])
        #expect(ChatImageLink.references(in: direct).first?.mediaKind == .video)

        let entry = ChatEntry(id: ChatEntryID("user"), sourceOffset: 0, content: .user(ChatUserMessage(text: rawPrompt)))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        #expect(rows.first?.messageImages == refs)
        #expect(rows.first?.copyText == rawPrompt)
    }

    @Test func composerVideoAttachmentFormatsDurationAndNumbersIndependentlyFromImages() {
        #expect(ComposerImageAttachment.formattedDuration(4.2) == "0:04")
        #expect(ComposerImageAttachment.formattedDuration(75) == "1:15")
        #expect(ComposerImageAttachment.formattedDuration(3661) == "1:01:01")

        let image = ComposerImageAttachment(kind: .image, phase: .ready(path: "/tmp/stage/image.jpg"))
        let video = ComposerImageAttachment(
            kind: .video,
            preview: ComposerImageAttachment.Preview(
                fileURL: URL(fileURLWithPath: "/tmp/local.mp4"),
                pixelWidth: 1170,
                pixelHeight: 2532,
                byteCount: 1_000_000,
                thumbnail: nil,
                durationSeconds: 4),
            phase: .ready(path: "/tmp/stage/clip.mp4"))
        let list = [image, video]
        #expect(ComposerImageAttachment.displayNumber(for: image, in: list) == 1)
        #expect(ComposerImageAttachment.displayNumber(for: video, in: list) == 1)
        #expect(video.previewTitle(number: 1).contains("0:04"))
        #expect(video.subtitle.contains("0:04"))
    }

    @Test func aSentImagesPlaceholdersOpenTheFilesItCameFrom() {
        let text = "[Image #2]compare with [Image #3] and /tmp/c.png"
        let marked = ChatImageLink.marking(text, imagePaths: ["/tmp/a.png", "/tmp/b.png"])
        let linked = marked.runs.filter { $0[ChatImageLink.PathAttribute.self] != nil }
        #expect(linked.map { String(marked[$0.range].characters) } == ["[Image #2]", "[Image #3]", "/tmp/c.png"])
        #expect(ChatImageLink.paths(in: marked) == ["/tmp/a.png", "/tmp/b.png", "/tmp/c.png"])
        // Without one file for every placeholder, no placeholder links.
        #expect(ChatImageLink.paths(in: ChatImageLink.marking(text, imagePaths: ["/tmp/a.png"])) == ["/tmp/c.png"])
    }

    @Test func aSentImageIsPreviewedFromItsRowWithoutAPlaceholder() async {
        let message = ChatUserMessage(text: "look", imageCount: 1, imagePaths: ["/tmp/a.png"])
        let entry = ChatEntry(id: ChatEntryID("user"), sourceOffset: 0, content: .user(message))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        #expect(rows.first?.messageImagePaths == ["/tmp/a.png"])
        #expect(rows.first?.hasInnerControls == false)
    }

    @Test("A code block's line names an image only when it is one image's path", arguments: [
        ("/tmp/a.png", ["/tmp/a.png"]),
        ("\t/tmp/b c.png  ", ["/tmp/b c.png"]),
        ("shots/d.png", ["shots/d.png"]),
        ("cp a.png b.png", []),
        (#"UIImage(named: "a.png")"#, []),
        ("/tmp/report.pdf", []),
        ("open /tmp/e.png", []),
    ])
    func codeBlockLines(_ line: String, _ expected: [String]) {
        let marked = ChatImageLink.markingLines("before\n\(line)\nafter")
        #expect(String(marked.characters) == "before\n\(line)\nafter")
        #expect(ChatImageLink.paths(in: marked) == expected)
    }

    @Test func aMessagesCodeBlockPathsArePreviewedFromItsMenu() async {
        let text = """
            The screenshots:

            ```
            /tmp/shots/a.png
            /tmp/shots/b 2.png
            ```

            ```swift
            let image = UIImage(named: "c.png")
            ```

            ```sh
            cp c.png d.png
            shots/e.png
            /tmp/notes.txt
            /tmp/shots/a.png
            ```
            """
        let entry = ChatEntry(
            id: ChatEntryID("reply"), sourceOffset: 0, content: .assistant(ChatAssistantMessage(text: text)))
        let rows = await ChatRowBuilder().rows(for: ChatTimelineInput(entries: [entry]))
        #expect(rows.first?.messageImagePaths == ["/tmp/shots/a.png", "/tmp/shots/b 2.png", "shots/e.png"])
    }

    @Test func aHomePathResolvesOnlyWithTheHome() {
        #expect(ChatImagePath.resolve("~/a/b.png", cwd: "/w", home: "/home/dev") == "/home/dev/a/b.png")
        #expect(ChatImagePath.resolve("~/a/b.png", cwd: "/w") == nil)
        #expect(ChatImagePath.resolve("~other/b.png", cwd: "/w", home: "/home/dev") == nil)
        #expect(ChatImagePath.resolve("shots/b.png", cwd: "/w", home: "/home/dev") == "/w/shots/b.png")
    }
}

@MainActor
@Suite("Chat image thumbnails", .timeLimit(.minutes(1)))
struct ChatImageThumbnailsTests {
    static func png(width: Int, height: Int, color: UIColor = .systemTeal) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func thumbnails(_ host: ThumbnailHost) -> ChatImageThumbnails {
        ChatImageThumbnails(source: host.source, cache: ChatImageThumbnailCache())
    }

    @Test func readsShownRowsOneFileAtATimeAndDecodesThemSmall() async throws {
        let host = ThumbnailHost(files: [
            "/tmp/a.png": Self.png(width: 3_000, height: 1_500), "/tmp/b.png": Self.png(width: 40, height: 80),
        ])
        let thumbnails = Self.thumbnails(host)

        thumbnails.appear("/tmp/a.png")
        thumbnails.appear("/tmp/b.png")
        // A second row showing the same file reads nothing more.
        thumbnails.appear("/tmp/a.png")
        #expect(thumbnails.phase(of: "/tmp/b.png") == .loading)
        await thumbnails.settled()

        #expect(try #require(thumbnails.image(of: "/tmp/a.png")).size == CGSize(width: 1_024, height: 512))
        #expect(try #require(thumbnails.image(of: "/tmp/b.png")).size == CGSize(width: 40, height: 80))
        #expect(await host.calls == ["stamp /tmp/a.png", "read /tmp/a.png", "stamp /tmp/b.png", "read /tmp/b.png"])
        #expect(await host.mostAtOnce == 1)
    }

    @Test func aRowThatLeavesBeforeItsTurnIsNeverRead() async {
        let host = ThumbnailHost(files: [
            "/tmp/a.png": Self.png(width: 4, height: 4), "/tmp/b.png": Self.png(width: 4, height: 4),
        ])
        let thumbnails = Self.thumbnails(host)

        thumbnails.appear("/tmp/a.png")
        thumbnails.appear("/tmp/b.png")
        thumbnails.disappear("/tmp/b.png")
        await thumbnails.settled()

        #expect(await host.calls == ["stamp /tmp/a.png", "read /tmp/a.png"])
        #expect(thumbnails.image(of: "/tmp/b.png") == nil)
    }

    @Test func aLargeFileWaitsForATap() async {
        let bytes = ChatImageThumbnails.automaticBytes + 1
        let host = ThumbnailHost(files: ["/tmp/big.png": Self.png(width: 4, height: 4)], sizes: ["/tmp/big.png": bytes])
        let thumbnails = Self.thumbnails(host)

        thumbnails.appear("/tmp/big.png")
        await thumbnails.settled()
        #expect(thumbnails.phase(of: "/tmp/big.png") == .large(bytes: bytes))
        #expect(await host.calls == ["stamp /tmp/big.png"])

        thumbnails.load("/tmp/big.png")
        #expect(thumbnails.phase(of: "/tmp/big.png") == .loading)
        await thumbnails.settled()
        #expect(thumbnails.image(of: "/tmp/big.png") != nil)
    }

    @Test func aMissingFileSaysSoAndATapTriesAgain() async {
        let host = ThumbnailHost(files: [:])
        let thumbnails = Self.thumbnails(host)

        thumbnails.appear("/tmp/gone.png")
        await thumbnails.settled()
        #expect(thumbnails.phase(of: "/tmp/gone.png") == .failed("No longer on the Host"))

        await host.write("/tmp/gone.png", Self.png(width: 4, height: 4))
        thumbnails.load("/tmp/gone.png")
        await thumbnails.settled()
        #expect(thumbnails.image(of: "/tmp/gone.png") != nil)
    }

    @Test func anOfflineHostLoadsOnceItConnects() async {
        let host = ThumbnailHost(files: ["/tmp/a.png": Self.png(width: 4, height: 4)])
        let thumbnails = Self.thumbnails(host)
        thumbnails.hostConnectionChanged(false)

        thumbnails.appear("/tmp/a.png")
        await thumbnails.settled()
        #expect(thumbnails.phase(of: "/tmp/a.png") == .offline)
        #expect(await host.calls.isEmpty)

        thumbnails.hostConnectionChanged(true)
        await thumbnails.settled()
        #expect(thumbnails.image(of: "/tmp/a.png") != nil)
    }

    @Test func aKeptCopyShowsAtOnceAndAFileWrittenAgainReadsAgain() async throws {
        let path = "/tmp/shot.png"
        let host = ThumbnailHost(files: [path: Self.png(width: 20, height: 10)])
        let thumbnails = Self.thumbnails(host)
        thumbnails.appear(path)
        await thumbnails.settled()
        let first = try #require(thumbnails.image(of: path))
        thumbnails.disappear(path)
        #expect(thumbnails.image(of: path) == nil)

        // Back on screen: the copy shows while the file is checked, and an
        // unchanged file is not read again.
        thumbnails.appear(path)
        #expect(thumbnails.image(of: path) === first)
        await thumbnails.settled()
        #expect(await host.calls == ["stamp \(path)", "read \(path)", "stamp \(path)"])
        thumbnails.disappear(path)

        // The Agent took its screenshot again at the same path.
        await host.write(path, Self.png(width: 10, height: 20))
        thumbnails.appear(path)
        await thumbnails.settled()
        #expect(try #require(thumbnails.image(of: path)).size == CGSize(width: 10, height: 20))
        thumbnails.disappear(path)

        // Offline, the copy still shows, without asking the Host.
        let asked = await host.calls.count
        thumbnails.hostConnectionChanged(false)
        thumbnails.appear(path)
        await thumbnails.settled()
        #expect(try #require(thumbnails.image(of: path)).size == CGSize(width: 10, height: 20))
        #expect(await host.calls.count == asked)
    }
}

/// Image files on a test Host, as thumbnails reach them.
private actor ThumbnailHost {
    private var files: [String: (data: Data, time: UInt32)]
    private let sizes: [String: UInt64]
    private(set) var calls: [String] = []
    private(set) var mostAtOnce = 0
    private var active = 0

    init(files: [String: Data], sizes: [String: UInt64] = [:]) {
        self.files = files.mapValues { ($0, 1) }
        self.sizes = sizes
    }

    nonisolated var source: ChatImageThumbnails.Source {
        ChatImageThumbnails.Source(
            stamp: { try await self.stamp($0) }, read: { try await self.read($0, $1) })
    }

    /// Writes the file again, as a newer file.
    func write(_ path: String, _ data: Data) {
        files[path] = (data, (files[path]?.time ?? 0) + 1)
    }

    private func stamp(_ path: String) async throws -> ChatImageStamp {
        calls.append("stamp \(path)")
        await enter()
        defer { active -= 1 }
        guard let file = files[path] else { throw ChatImagePreviewError.missing }
        return ChatImageStamp(size: sizes[path] ?? UInt64(file.data.count), modificationTime: file.time)
    }

    private func read(_ path: String, _ stamp: ChatImageStamp) async throws -> Data {
        calls.append("read \(path)")
        await enter()
        defer { active -= 1 }
        guard let file = files[path] else { throw ChatImagePreviewError.missing }
        return file.data
    }

    /// Counts reads at once, giving others a chance to start alongside.
    private func enter() async {
        active += 1
        mostAtOnce = max(mostAtOnce, active)
        await Task.yield()
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

    @Test func composerImageStripAutoScrollsOnAppendAndFinalCompletionWithoutJumpingOnDelete() {
        let a = UUID(), b = UUID(), c = UUID()
        let entry = { (id: UUID, phase: ComposerImageAttachment.Phase) in
            ComposerImageStrip.ScrollEntry(ComposerImageAttachment(id: id, phase: phase))
        }
        let progress = AttachmentStageProgress(transferredBytes: 50, totalBytes: 100)

        // Single image stays at leading margin without auto-scrolling.
        #expect(!ComposerImageStrip.shouldScrollToEnd(from: [], to: [entry(a, .preparing)]))
        // Appending a second or third image scrolls to the trailing end.
        let twoUploading = [entry(a, .ready(path: "/a")), entry(b, .uploading(progress))]
        #expect(ComposerImageStrip.shouldScrollToEnd(from: [entry(a, .ready(path: "/a"))], to: twoUploading))
        // Completing the trailing upload scrolls again once its metadata widens the pill.
        let twoReady = [entry(a, .ready(path: "/a")), entry(b, .ready(path: "/b"))]
        #expect(ComposerImageStrip.shouldScrollToEnd(from: twoUploading, to: twoReady))
        // Batch of 3 keeps trailing pinned as earlier items widen, then settles on #3 ready.
        let threeQueued = [entry(a, .uploading(progress)), entry(b, .queued), entry(c, .queued)]
        let threeAfterA = [entry(a, .ready(path: "/a")), entry(b, .uploading(progress)), entry(c, .queued)]
        #expect(ComposerImageStrip.shouldScrollToEnd(from: [], to: threeQueued))
        #expect(ComposerImageStrip.shouldScrollToEnd(from: threeQueued, to: threeAfterA))
        // Deleting an attachment never jumps to the end.
        #expect(!ComposerImageStrip.shouldScrollToEnd(
            from: [entry(a, .ready(path: "/a")), entry(b, .ready(path: "/b")), entry(c, .ready(path: "/c"))],
            to: [entry(a, .ready(path: "/a")), entry(c, .ready(path: "/c"))]))
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
