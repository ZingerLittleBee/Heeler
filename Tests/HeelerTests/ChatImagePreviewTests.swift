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
        #expect(ChatImageLink.path(opening: try #require(URL(string: "https://x.test/?path=/a.png"))) == nil)
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

    /// A row is as tall whatever its thumbnail shows, and at any width: a
    /// picture arriving never moves the rows around it.
    @Test func anImageRowIsAsTallWhateverItsThumbnailShows() async throws {
        let path = "/tmp/shot.png"
        var tool = ChatToolActivity(kind: .fileRead, name: "Read", title: path, status: .succeeded)
        tool.imagePath = path
        let row = ChatRow(id: .entry(ChatEntryID("read")), content: .tool(tool), revision: 1, topSpacing: 0)
        func height(_ thumbnails: ChatImageThumbnails?, width: CGFloat) -> CGFloat {
            var actions = ChatRowActions(
                toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: "")
            actions.thumbnails = thumbnails
            let host = UIHostingController(rootView: ChatRowView(row: row, isExpanded: false, actions: actions))
            host.safeAreaRegions = []
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        func loaded(_ files: [String: Data], sizes: [String: UInt64] = [:]) async -> ChatImageThumbnails {
            let thumbnails = Self.thumbnails(ThumbnailHost(files: files, sizes: sizes))
            thumbnails.appear(path)
            await thumbnails.settled()
            return thumbnails
        }
        // A Host that answers only once the row leaves.
        let loading = ChatImageThumbnails(
            source: .init(
                stamp: { _ in
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                }, read: { _, _ in Data() }),
            cache: ChatImageThumbnailCache())
        loading.appear(path)
        let shown: [(String, ChatImageThumbnails?)] = [
            ("none", nil),
            ("loading", loading),
            ("wide", await loaded([path: Self.png(width: 3_000, height: 600)])),
            ("tall", await loaded([path: Self.png(width: 600, height: 1_300)])),
            ("large", await loaded([path: Self.png(width: 4, height: 4)], sizes: [path: 30 << 20])),
            ("missing", await loaded([:])),
        ]
        #expect(loading.phase(of: path) == .loading)
        for width: CGFloat in [320, 390, 744] {
            let heights = shown.map { ($0.0, height($0.1, width: width)) }
            #expect(Set(heights.map(\.1)).count == 1, "at width \(width): \(heights)")
        }
        loading.disappear(path)
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

    @Test func aThumbnailStandsInUntilTheFileIsRead() async throws {
        let thumbnail = try #require(UIImage(data: Self.png()))
        let preview = ChatImagePreviewController(path: "/tmp/picture.png", placeholder: thumbnail) { _ in
            try await Task.sleep(for: .seconds(30))
            return Data()
        }
        try await withTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640), rootViewController: preview) { _ in
            let scroll = try #require(preview.view.subviews.compactMap { $0 as? UIScrollView }.first)
            let image = try #require(scroll.subviews.compactMap { $0 as? UIImageView }.first)
            #expect(image.image === thumbnail)
            #expect(!preview.isLoaded)
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
        let rendered = try RenderedBitmap(
            ChatRowView(row: row, isExpanded: false, actions: .init(
                toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: ""))
                .padding(.vertical, 16).frame(width: 390).background(Color(uiColor: .systemBackground))
                .environment(\.colorScheme, .dark),
            proposedSize: .unspecified, scale: 2)
        Attachment.record(try rendered.image(), named: "chat-search-title-alignment", as: .png)
    }

    /// Image rows in each state their thumbnail can show, for review.
    @Test(arguments: [ColorScheme.light, .dark])
    func imageRowsShowTheirThumbnailUnderTheTitle(scheme: ColorScheme) async throws {
        func row(_ name: String, files: [String: Data], sizes: [String: UInt64] = [:], connected: Bool = true) async
            -> (ChatRow, ChatRowActions)
        {
            let path = "/private/tmp/claude-501/scratchpad/e2e/\(name)"
            var tool = ChatToolActivity(kind: .fileRead, name: "Read", title: path, status: .succeeded)
            tool.imagePath = path
            let thumbnails = ChatImageThumbnails(
                source: .init(
                    stamp: { _ in
                        guard let data = files[name] else { throw ChatImagePreviewError.missing }
                        return ChatImageStamp(size: sizes[name] ?? UInt64(data.count), modificationTime: 1)
                    }, read: { _, _ in files[name] ?? Data() }),
                cache: ChatImageThumbnailCache())
            thumbnails.hostConnectionChanged(connected)
            thumbnails.appear(path)
            await thumbnails.settled()
            var actions = ChatRowActions(
                toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: "")
            actions.thumbnails = thumbnails
            return (ChatRow(id: .entry(ChatEntryID(name)), content: .tool(tool), revision: 1, topSpacing: 8), actions)
        }
        let wide = ChatImageThumbnailsTests.png(width: 1_600, height: 900, color: .systemIndigo)
        let rows = [
            await row("report-top.png", files: ["report-top.png": wide]),
            await row("phone.png", files: ["phone.png": ChatImageThumbnailsTests.png(width: 1_206, height: 2_622)]),
            await row("huge.png", files: ["huge.png": wide], sizes: ["huge.png": 12_400_000]),
            await row("deleted.png", files: [:]),
            await row("offline.png", files: [:], connected: false),
        ]
        let rendered = try RenderedBitmap(
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    ChatRowView(row: rows[index].0, isExpanded: false, actions: rows[index].1)
                }
            }
            .padding(.vertical, 16).frame(width: 390).background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme),
            proposedSize: .unspecified, scale: 3)
        Attachment.record(try rendered.image(), named: "chat-image-rows-\(scheme)", as: .png)
    }
}
