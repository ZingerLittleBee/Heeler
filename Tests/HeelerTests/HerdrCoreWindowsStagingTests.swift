import Foundation
import Testing
import UIKit

@testable import Heeler

/// Staged Images and Files on a native Windows core Host from the Composer down:
/// the real Console, Host session, transport, link and Composer session, with the
/// exec and the core's `terminal.put` scripted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreWindowsStagingTests {
    private static let filesFolder = #"C:\Users\me\AppData\Local\herdr-core\work\files\t1\"#
    private static let mebibyte = 1024 * 1024

    private static let agentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string(#"C:\work\app"#), "state": .string("live"),
        "argv": .array([.string("powershell.exe"), .string("-Command"), .string("& 'claude'; exit $LASTEXITCODE")]),
        "keep": .bool(true), "title": .string(""), "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(7), "name": .string("powershell.exe"),
            "argv": .array([
                .string(#"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe"#), .string("-Command"),
                .string("& 'claude'; exit $LASTEXITCODE"),
            ]),
            "cwd": .string(#"C:\work\app"#),
        ]),
    ])

    @MainActor
    private struct Fixture {
        let scripted = ScriptedCoreHost(
            windowsLocator: ScriptedCoreHost.windowsLocatorLines(),
            channel: .core(.init(id: "c1", terminals: [HerdrCoreWindowsStagingTests.agentRecord])))
        let host = Host(address: "win.example", username: "me", serverKind: .herdrCore)
        let console: ConsoleStore

        init() async throws {
            let scripted = scripted
            await scripted.helper.configure { $0.platform = .nativeWindows }
            console = ConsoleStore(
                makeSession: { _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                        keepalive: nil)
                },
                makeCoreSession: { _ in
                    HerdrCoreHostSession(
                        connect: {
                            await scripted.setConnected(true)
                            return scripted.transport()
                        },
                        keepalive: nil)
                },
                coreHostMemory: HerdrCoreHostMemory(
                    defaults: UserDefaults(suiteName: "core-windows-staging-\(UUID().uuidString)") ?? .standard))
            console.setHosts([host])
            await console.resume()
            try await HerdrCoreWindowsStagingTests.until("the Agent") { [console] in !console.agents.isEmpty }
        }

        var session: AgentComposerSession {
            get throws { console.composerSession(for: try #require(console.agents.first)) }
        }

        func finish() async {
            console.setHosts([])
            await console.suspend()
        }
    }

    private static func until(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private static func temporaryFile(contents: Data, extension fileExtension: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-windows-staging-\(UUID().uuidString).\(fileExtension)")
        try contents.write(to: url)
        return url
    }

    private static func pickedPhoto() throws -> ComposerStagingStore.Source {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return .photo(DataImageSelection(data: try #require(image.pngData())))
    }

    private static func completedPath(_ session: AgentComposerSession) -> String? {
        if case .completed(let outcome) = session.staging.state { return outcome.path }
        return nil
    }

    private static func failure(_ store: ComposerStagingStore) -> ComposerStagingStore.Failure? {
        if case .failed(let failure) = store.state { return failure }
        return nil
    }

    private func putCount(_ fixture: Fixture) async -> Int {
        await fixture.scripted.methods.filter { $0 == "terminal.put" }.count
    }

    // MARK: Staged through the core

    @Test func aSmallFileGoesAsOnePutForItsTerminalAndTheCoresPathLandsInTheDraft() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        let contents = Data("notes 修复".utf8)
        let url = try Self.temporaryFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the file") { Self.completedPath(session) != nil }

        let puts = await fixture.scripted.puts
        #expect(puts.map(\.terminal) == ["t1"])
        #expect(puts.map(\.name) == ["file.txt"])
        #expect(puts.first?.contents == contents)
        #expect(await putCount(fixture) == 1)
        #expect(Self.completedPath(session) == Self.filesFolder + "file.txt")
        #expect(session.composer.draft == Self.filesFolder + "file.txt ")

        // No SFTP, and the path waits in the draft with Send hidden.
        #expect(await fixture.scripted.stagedFiles.isEmpty)
        #expect(!fixture.console.capabilities(for: fixture.host.id).composerSend)
        await fixture.finish()
    }

    @Test func anImageGoesTheSameWay() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session

        try #require(session.staging.begin(try Self.pickedPhoto()) != nil)
        try await Self.until("the image") { Self.completedPath(session) != nil }

        let puts = await fixture.scripted.puts
        #expect(puts.map(\.name) == ["image.jpg"])
        #expect(puts.first?.contents.isEmpty == false)
        #expect(session.composer.draft == Self.filesFolder + "image.jpg ")
        await fixture.finish()
    }

    /// The core takes exactly 8 MiB (herdr compatibility).
    @Test func aFileOfExactlyTheLimitGoesWithEveryByte() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        let contents = Data(repeating: 0xA5, count: 8 * Self.mebibyte)
        let url = try Self.temporaryFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the file") { Self.completedPath(session) != nil }

        #expect(await fixture.scripted.puts.first?.contents == contents)
        await fixture.finish()
    }

    // MARK: Over the limit

    @Test func aFileOverTheLimitIsRefusedBeforeAnyBytesGoAndTheDraftStays() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        session.composer.replaceDraft(with: "keep this")
        let url = try Self.temporaryFile(contents: Data(count: 9 * Self.mebibyte))
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the refusal") { Self.failure(session.staging) != nil }

        let failure = try #require(Self.failure(session.staging))
        #expect(failure.message == "This file is over the 8 MiB limit on a native Windows Host. Nothing was sent.")
        #expect(!failure.isRetryable)
        #expect(session.staging.presentation?.title == failure.message)
        #expect(session.staging.presentation?.commands == [.dismiss])
        #expect(session.composer.draft == "keep this")
        #expect(await putCount(fixture) == 0)
        await fixture.finish()
    }

    /// An ordinary photo comes out of `ImagePreparer` well under the limit, so this
    /// one comes from a preparer that hands over 9 MiB. The rest is the Composer's own.
    @Test func anImageOverTheLimitIsRefusedTheSameWay() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        session.composer.replaceDraft(with: "keep this")
        let url = try Self.temporaryFile(contents: Data(count: 9 * Self.mebibyte), extension: "jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let prepared = PreparedImage(
            fileURL: url, format: .jpeg, pixelWidth: 4096, pixelHeight: 4096, byteCount: Int64(9 * Self.mebibyte))
        let staging = ComposerStagingStore(
            imagePreparer: PreparedAlready(prepared: prepared),
            stageImage: fixture.console.imageStager(for: fixture.host.id, beside: "t1", keepingTo: session.corePin),
            stageFile: fixture.console.fileStager(for: fixture.host.id, beside: "t1", keepingTo: session.corePin),
            clipboard: IgnoringClipboard(),
            composer: session.composer)

        try #require(staging.begin(try Self.pickedPhoto()) != nil)
        try await Self.until("the refusal") { Self.failure(staging) != nil }

        let failure = try #require(Self.failure(staging))
        #expect(failure.message == "This image is over the 8 MiB limit on a native Windows Host. Nothing was sent.")
        #expect(!failure.isRetryable)
        #expect(session.composer.draft == "keep this")
        #expect(await putCount(fixture) == 0)
        await fixture.finish()
    }

    // MARK: Keeping to its core

    /// `terminal.put` writes beside the Terminal at an address, which means another
    /// Terminal on any other core (ADR 0031).
    @Test func aDetailOnAnotherCoreSendsNothing() async throws {
        let fixture = try await Fixture()
        let url = try Self.temporaryFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let stager = fixture.console.fileStager(
            for: fixture.host.id, beside: "t1", keepingTo: TerminalCorePin(joined: "the-core-before"))
        let file = PreparedFile(fileURL: url, fileExtension: "txt", byteCount: 5)

        await #expect(throws: TransportError.herdrCoreTerminalGone) {
            _ = try await stager(file, AttachmentStageProgressReporter { _ in })
        }

        #expect(await putCount(fixture) == 0)
        await fixture.finish()
    }

    // MARK: What the core says

    @Test(arguments: ["finished", "not_found"])
    func aTerminalThatEndedSaysSoAndOffersNoRetry(kind: String) async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        await fixture.scripted.refuseNextPut(kind: kind)
        let url = try Self.temporaryFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the refusal") { Self.failure(session.staging) != nil }

        let failure = try #require(Self.failure(session.staging))
        #expect(failure.message == "This Terminal has ended, so the file was not sent.")
        #expect(!failure.isRetryable)
        #expect(session.composer.draft.isEmpty)
        await fixture.finish()
    }

    @Test func anyOtherRefusalCarriesTheCoresWords() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        await fixture.scripted.refuseNextPut(kind: "machine_unknown")
        let url = try Self.temporaryFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the refusal") { Self.failure(session.staging) != nil }

        #expect(Self.failure(session.staging)?.message == "The Host refused the file: machine_unknown")
        await fixture.finish()
    }

    @Test func aReplyCountingOtherBytesIsNoSuccess() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        await fixture.scripted.setNextPutByteCount(4)
        let url = try Self.temporaryFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the failure") { Self.failure(session.staging) != nil }

        #expect(session.composer.draft.isEmpty)
        await fixture.finish()
    }

    /// The bytes may have landed. Retry sends another copy, which the core names
    /// apart, and the draft gets the one that was confirmed.
    @Test func aLinkLostMidPutReadsAsUnconfirmedAndRetrySendsAgain() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session
        await fixture.scripted.holdNextPutReply()
        let url = try Self.temporaryFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        try #require(session.staging.begin(.file(url)) != nil)
        try await Self.until("the put") { await fixture.scripted.puts.count == 1 }
        await fixture.scripted.socket?.deliverEndOfFile()
        try await Self.until("the failure") { Self.failure(session.staging) != nil }

        let failure = try #require(Self.failure(session.staging))
        #expect(failure.message == "The Host did not confirm the file. Retry sends another copy.")
        #expect(failure.isRetryable)
        #expect(session.composer.draft.isEmpty)

        try await Self.until("the link back") {
            fixture.console.hostStatuses[fixture.host.id] == .connected
        }
        session.staging.perform(.retry)
        try await Self.until("the second copy") { Self.completedPath(session) != nil }

        #expect(await fixture.scripted.puts.count == 2)
        #expect(session.composer.draft == Self.filesFolder + "file-2.txt ")
        await fixture.finish()
    }

    // MARK: The path

    @Test func aWindowsPathIsAStagedPathAndARelativeOneIsNot() throws {
        #expect(try StagedFile(path: Self.filesFolder + "file.txt").path == Self.filesFolder + "file.txt")
        #expect(try StagedImage(path: Self.filesFolder + "image.jpg").path == Self.filesFolder + "image.jpg")
        #expect(throws: AttachmentStagingError.invalidRemotePath) { try StagedFile(path: "file.txt") }
        #expect(throws: AttachmentStagingError.invalidRemotePath) { try StagedFile(path: #"C:file.txt"#) }
        #expect(throws: AttachmentStagingError.invalidRemotePath) { try StagedFile(path: "C:\\a\u{7}.txt") }
    }

    // MARK: Who gets uploads

    /// A Herdr TUI Host's offer never read its platform: its refusal is the
    /// connection's, in the two tests below.
    @Test func aCoreHostOffersThemOnWindowsAndATUIOfferIgnoresThePlatform() {
        #expect(HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows).uploads)
        #expect(
            HostCapabilities(serverKind: .herdrTUI, platform: .nativeWindows).uploads
                == HostCapabilities(serverKind: .herdrTUI, platform: .posix).uploads)
        #expect(!HostCapabilities(serverKind: .unconfirmed, platform: .nativeWindows).uploads)
    }

    /// The transport a Herdr TUI Host stages through, on the banner OpenSSH sends
    /// from Windows. The connection never shook hands, so an upload that got past
    /// the refusal would read `transferFailed`, as the next test shows.
    @Test func aWindowsHerdrTUIConnectionRefusesImagesAndFilesBeforeLookingAtTheLink() async throws {
        let refusal = TransportError.hostFeatureUnavailable(
            feature: "File and image uploads is not yet supported on native Windows")
        let upload = try UploadThroughSSH(banner: "SSH-2.0-OpenSSH_for_Windows_9.5")
        defer { upload.cleanup() }

        await #expect(throws: refusal) { try await upload.stageImage() }
        await #expect(throws: refusal) { try await upload.stageFile() }

        #expect(await upload.progress.reports == 0)
    }

    @Test func thatConnectionWithAUnixBannerIsNotRefused() async throws {
        let upload = try UploadThroughSSH(banner: "SSH-2.0-OpenSSH_9.9")
        defer { upload.cleanup() }

        await #expect(throws: AttachmentStagingError.transferFailed) { try await upload.stageImage() }
        await #expect(throws: AttachmentStagingError.transferFailed) { try await upload.stageFile() }

        #expect(await upload.progress.reports == 0)
    }
}

private struct UploadThroughSSH {
    actor Progress {
        private(set) var reports = 0

        func report() {
            reports += 1
        }
    }

    let progress = Progress()
    private let transport: HeelerSSHTransport
    private let source: URL

    init(banner: String) throws {
        transport = HeelerSSHTransport(
            connection: .neverConnectedForTesting(serverIdentification: banner),
            socketPath: "/never/opened")
        source = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-through-ssh-\(UUID().uuidString)")
        try Data("bytes".utf8).write(to: source)
    }

    func stageImage() async throws {
        let progress = progress
        _ = try await transport.stageImage(
            PreparedImage(fileURL: source, format: .jpeg, pixelWidth: 1, pixelHeight: 1, byteCount: 5)
        ) { _ in await progress.report() }
    }

    func stageFile() async throws {
        let progress = progress
        _ = try await transport.stageFile(
            PreparedFile(fileURL: source, fileExtension: "txt", byteCount: 5)
        ) { _ in await progress.report() }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: source)
    }
}

private actor PreparedAlready: ImagePreparing {
    let prepared: PreparedImage

    init(prepared: PreparedImage) {
        self.prepared = prepared
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        prepared
    }
}

private struct IgnoringClipboard: AttachmentClipboard {
    func copy(_ text: String) throws {}
}
