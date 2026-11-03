import Foundation
import Testing
import UIKit

@testable import Heeler

/// Staged Images and Files on a core Host from the Composer down: the real
/// Console, Host session, link and Composer session, with the SSH connection
/// and the core scripted.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreStagingTests {
    private static let agentRecord: JSONValue = .object([
        "address": .string("t1"), "cwd": .string("/work/app"), "state": .string("live"),
        "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
        "cols": .number(80), "rows": .number(24), "pid": .number(7),
        "foreground": .object([
            "pid": .number(40), "name": .string("claude"), "argv": .array([.string("claude")]),
            "cwd": .string("/work/app"),
        ]),
    ])

    @MainActor
    private struct Fixture {
        let scripted = ScriptedCoreHost(
            channel: .core(.init(id: "c1", terminals: [HerdrCoreStagingTests.agentRecord])))
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let console: ConsoleStore

        init(platform: HostPlatform = .posix) async throws {
            let scripted = scripted
            await scripted.helper.configure { $0.platform = platform }
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
                    defaults: UserDefaults(suiteName: "core-staging-\(UUID().uuidString)") ?? .standard))
            console.setHosts([host])
            await console.resume()
            try await HerdrCoreStagingTests.until("the Agent") { [console] in !console.agents.isEmpty }
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
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
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

    /// A file picked by this name, alone in a folder of its own: remove `folder`.
    private static func pickedFile(
        named name: String = "notes.txt", contents: Data
    ) throws -> (source: ComposerStagingStore.Source, folder: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url)
        return (.file(url), folder)
    }

    private static func hasCompleted(
        _ medium: ComposerStagingStore.Medium, _ session: AgentComposerSession
    ) -> Bool {
        if case .completed(let outcome) = session.staging.state { return outcome.medium == medium }
        return false
    }

    /// What a Console reads on its own. Anything else reached the core because
    /// of the upload.
    private static let consoleReads: Set<String> = ["events.subscribe", "doc.get", "server.status"]

    @Test func aCoreAgentsComposerStagesAnImageAndAFileThroughHostServices() async throws {
        let fixture = try await Fixture()
        let session = try fixture.session

        try #require(session.staging.begin(try Self.pickedPhoto()) != nil)
        try await Self.until("the image") { Self.hasCompleted(.image, session) }
        let contents = Data("notes".utf8)
        // The Host copy takes the picked name, cleaned as on native Windows (ADR 0006).
        let file = try Self.pickedFile(named: "meeting notes.txt", contents: contents)
        defer { try? FileManager.default.removeItem(at: file.folder) }
        try #require(session.staging.begin(file.source) != nil)
        try await Self.until("the file") { Self.hasCompleted(.file, session) }

        let staged = await fixture.scripted.stagedFiles
        #expect(staged.map(\.path) == [
            "/tmp/heeler-stage/stage-0/image.jpg", "/tmp/heeler-stage/stage-1/meeting_notes.txt",
        ])
        #expect(staged.last?.contents == contents)
        #expect(
            session.composer.draft
                == "/tmp/heeler-stage/stage-0/image.jpg /tmp/heeler-stage/stage-1/meeting_notes.txt ")

        // The path waits in the draft; delivering it is Send's job.
        #expect(Set(await fixture.scripted.methods).isSubset(of: Self.consoleReads))
        #expect(await fixture.scripted.attaches.isEmpty)
        await fixture.finish()
    }

    /// macOS and Linux both answer POSIX, and native Windows stages through the
    /// core's `terminal.put` (ADR 0032).
    @Test(arguments: [HostPlatform.posix, .nativeWindows])
    func aCoreHostOffersUploadsOnceItsConnectionReportsItsPlatform(platform: HostPlatform) async throws {
        let fixture = try await Fixture(platform: platform)
        let console = fixture.console
        let hostID = fixture.host.id
        #expect(!console.capabilities(for: hostID).uploads)

        _ = try fixture.session
        try await Self.until("the platform") { console.hostPlatforms[hostID] == platform }

        #expect(console.capabilities(for: hostID).uploads)
        await fixture.finish()
    }

    @Test func aPlatformChangesNothingForAHerdrTUIHostOrAnUnconfirmedOne() {
        for platform in [nil, HostPlatform.posix, .nativeWindows] {
            #expect(HostCapabilities(serverKind: .herdrTUI, platform: platform) == HostCapabilities(serverKind: .herdrTUI))
            #expect(HostCapabilities(serverKind: .herdrTUI, platform: platform).uploads)
            #expect(HostCapabilities(serverKind: .herdrTUI, platform: platform).composerSend)
            #expect(!HostCapabilities(serverKind: .unconfirmed, platform: platform).uploads)
            #expect(!HostCapabilities(serverKind: .unconfirmed, platform: platform).composerSend)
        }
    }

    /// The foreground Send checks takes its form from the platform, so a core Host
    /// offers it only once that is known.
    @Test func aCoreHostOffersSendOnceItsPlatformIsKnown() {
        #expect(!HostCapabilities(serverKind: .herdrCore).composerSend)
        #expect(HostCapabilities(serverKind: .herdrCore, platform: .posix).composerSend)
        #expect(HostCapabilities(serverKind: .herdrCore, platform: .nativeWindows).composerSend)
    }

    @Test func aPlatformLeftUnknownIsAskedAgainOnTheNextConnection() async throws {
        let fixture = try await Fixture()
        let console = fixture.console
        let hostID = fixture.host.id
        await fixture.scripted.setPlatformFailure(.timedOut)

        _ = try fixture.session
        try await Self.until("the first ask") { await fixture.scripted.platformAsks == 1 }
        #expect(!console.capabilities(for: hostID).uploads)

        await fixture.scripted.setPlatformFailure(nil)
        await console.suspend()
        await console.resume()
        try await Self.until("Add") { console.capabilities(for: hostID).uploads }
        await fixture.finish()
    }

    // MARK: Failures

    /// The same refusal under both Server Kinds, for what each one's Composer shows.
    private static func herdrTUIState(
        failingWith failure: AttachmentStagingError, source: ComposerStagingStore.Source
    ) async throws -> ComposerStagingStore.State {
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.configureFileStaging(outcomes: [.failure(failure)])
        let console = ConsoleStore { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([Host.fixture()])
        await console.resume()
        try await until("the Agent") { !console.agents.isEmpty }
        let session = console.composerSession(for: try #require(console.agents.first))
        try #require(session.staging.begin(source) != nil)
        try await until("the failure") { hasFailed(session) }
        let state = session.staging.state
        console.setHosts([])
        await console.suspend()
        return state
    }

    private static func hasFailed(_ session: AgentComposerSession) -> Bool {
        if case .failed = session.staging.state { return true }
        return false
    }

    @Test(arguments: [
        (AttachmentStagingError.sftpUnavailable, "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem."),
        (AttachmentStagingError.transferFailed, "File upload failed."),
        (AttachmentStagingError.remoteTemporaryDirectoryFailed, "File upload failed."),
    ])
    func aStagingFailureOnACoreHostReadsAsItDoesOnHerdrTUI(
        failure: AttachmentStagingError, message: String
    ) async throws {
        let picked = try Self.pickedFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: picked.folder) }
        let fixture = try await Fixture()
        await fixture.scripted.failStages(with: [failure])
        let session = try fixture.session

        try #require(session.staging.begin(picked.source) != nil)
        try await Self.until("the failure") { Self.hasFailed(session) }

        #expect(session.staging.presentation?.title == message)
        #expect(session.staging.state == (try await Self.herdrTUIState(failingWith: failure, source: picked.source)))
        #expect(session.composer.draft.isEmpty)
        await fixture.finish()
    }

    @Test func aHostThatIsNotConnectedSaysSoAndKeepsTheRetry() async throws {
        let picked = try Self.pickedFile(contents: Data("notes".utf8))
        defer { try? FileManager.default.removeItem(at: picked.folder) }
        let fixture = try await Fixture()
        let session = try fixture.session
        await fixture.console.suspend()

        try #require(session.staging.begin(picked.source) != nil)
        try await Self.until("the failure") { Self.hasFailed(session) }

        #expect(
            session.staging.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: .file,
                        message: "The Host is not connected. Reconnect, then retry the upload.",
                        isRetryable: true)))
        await fixture.finish()
    }

    @Test func retryAfterAFailedUploadInsertsThePathOfTheOneThatLanded() async throws {
        let contents = Data("notes".utf8)
        let picked = try Self.pickedFile(contents: contents)
        defer { try? FileManager.default.removeItem(at: picked.folder) }
        let fixture = try await Fixture()
        await fixture.scripted.failStages(with: [.transferFailed])
        let session = try fixture.session

        try #require(session.staging.begin(picked.source) != nil)
        try await Self.until("the failure") { Self.hasFailed(session) }
        #expect(session.staging.presentation?.commands == [.retry, .dismiss])

        session.staging.perform(.retry)
        try await Self.until("the file") { Self.hasCompleted(.file, session) }

        let staged = await fixture.scripted.stagedFiles
        #expect(staged.map(\.path) == ["/tmp/heeler-stage/stage-0/notes.txt"])
        #expect(staged.first?.contents == contents)
        #expect(session.composer.draft == "/tmp/heeler-stage/stage-0/notes.txt ")
        await fixture.finish()
    }
}
