import Foundation
import Testing

@testable import Heeler

@Suite(
    "Image staging e2e",
    .enabled(
        if: HeelerSSHTransportBehaviorEnvironment.current != nil,
        "requires the disposable direct and Jump Host fixtures"),
    .serialized,
    .timeLimit(.minutes(2)))
struct ImageStagingE2ETests {
    @Test func directStagingStreamsPrivateFileAndAtomicallyRenamesThePart() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exercisePrivateAtomicStage(settings: environment.directSettings())
    }

    @Test func jumpStagingStreamsPrivateFileAndAtomicallyRenamesThePart() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exercisePrivateAtomicStage(settings: environment.jumpSettings())
    }

    @Test func cancellationRemovesOnlyTheCurrentIncompletePart() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let identifier = UUID().uuidString.lowercased()
        let remotePrefix = "heeler-cancel-\(identifier)"
        var settings = environment.directSettings()
        let stagingRoot = "\(environment.homePath)/.heeler-ci"
        let quotedStagingRoot = try #require(RemoteShellPath.quotedAbsolute(stagingRoot))
        settings.stageDirectoryCommand =
            "/bin/sh -c 'umask 077; "
            + "directory=$(mktemp -d \"$1/\(remotePrefix).XXXXXXXX\") || exit 1; "
            + "printf keep > \"$directory/sentinel\"; "
            + "printf \"__HEELER_STAGE_DIR__=%s\\n\" \"$directory\"' stage "
            + quotedStagingRoot
        let prepared = try makePreparedImage(
            named: "image-stage-cancel-\(identifier).jpg",
            byteCount: ImagePreparer.maximumEncodedByteCount,
            format: .jpeg)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let holdProgress = ScriptedTransportCallGate()
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        let task = Task {
            try await transport.stageImage(prepared.image) { value in
                if value.transferredBytes > 0 {
                    await holdProgress.waitUntilOpen()
                }
            }
        }
        try await waitUntil("upload should report a transferred chunk") {
            await holdProgress.entryCount > 0
        }

        task.cancel()
        await holdProgress.open()

        await #expect(throws: ImageStagingError.cancelled) {
            _ = try await task.value
        }
        let parent = try #require(
            try stagedDirectories(in: stagingRoot, prefix: remotePrefix).first)
        defer { try? FileManager.default.removeItem(at: parent) }
        let contents = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil)
        #expect(contents.contains { $0.lastPathComponent == "sentinel" })
        let stageDirectory = try #require(
            contents.first { $0.lastPathComponent.hasPrefix("stage-") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: stageDirectory.path).isEmpty)
        #expect(try await transport.ping().protocolVersion == 17)
        try await transport.close()
    }

    @Test func disconnectedTransportSurfacesRetryableTransferFailure() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let prepared = try makePreparedImage(
            named: "image-stage-disconnected-\(UUID().uuidString).png",
            byteCount: 1_024,
            format: .png)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let transport = try await HeelerSSHTransport.connect(settings: environment.directSettings())
        try await transport.close()

        do {
            _ = try await transport.stageImage(prepared.image) { _ in }
            Issue.record("A disconnected transport unexpectedly staged an image.")
        } catch let error as ImageStagingError {
            #expect(error == .transferFailed)
            #expect(error.isRetryable)
        }
    }

    @Test func sftpStatusFailureIsRetryableAndDoesNotExposeTheRemotePath() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        let privatePath = "/root/heeler-private-\(UUID().uuidString)"
        var settings = environment.directSettings()
        settings.stageDirectoryCommand =
            "printf '__HEELER_STAGE_DIR__=%s\\n' '\(privatePath)'"
        let prepared = try makePreparedImage(
            named: "image-stage-status-\(UUID().uuidString).png",
            byteCount: 1_024,
            format: .png)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        do {
            _ = try await transport.stageImage(prepared.image) { _ in }
            Issue.record("An inaccessible staging parent unexpectedly succeeded.")
        } catch let error as ImageStagingError {
            #expect(error == .transferFailed)
            #expect(error.isRetryable)
            #expect(!String(describing: error).contains(privatePath))
        }
    }

    @Test func directEventsAndAttachStayLiveDuringStagingAndEightRPCs() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseConcurrentChannels(settings: environment.directSettings())
    }

    @Test func jumpEventsAndAttachStayLiveDuringStagingAndEightRPCs() async throws {
        let environment = try #require(HeelerSSHTransportBehaviorEnvironment.current)
        try await exerciseConcurrentChannels(settings: environment.jumpSettings())
    }

    private func exercisePrivateAtomicStage(settings: SSHTransportSettings) async throws {
        let prepared = try makePreparedImage(
            named: "image-stage-\(UUID().uuidString).png",
            byteCount: 200_000,
            format: .png)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let progress = ProgressRecorder()
        let transport = try await HeelerSSHTransport.connect(settings: settings)

        let staged = try await transport.stageImage(prepared.image) { value in
            await progress.record(value)
        }
        let stageDirectory = staged.fileURL.deletingLastPathComponent()
        let parentDirectory = stageDirectory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }

        #expect(staged.path.hasPrefix("/"))
        #expect(staged.path.hasSuffix(".png"))
        #expect(!staged.path.contains(prepared.image.fileURL.lastPathComponent))
        #expect(try Data(contentsOf: staged.fileURL) == prepared.bytes)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        let stageAttributes = try FileManager.default.attributesOfItem(atPath: stageDirectory.path)
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parentDirectory.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((stageAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: stageDirectory.path)
                == [staged.fileURL.lastPathComponent])
        let values = await progress.values
        #expect(values.first == ImageStageProgress(
            transferredBytes: 0,
            totalBytes: prepared.bytes.count))
        #expect(values.last == ImageStageProgress(
            transferredBytes: prepared.bytes.count,
            totalBytes: prepared.bytes.count))
        #expect(values.map(\.transferredBytes) == values.map(\.transferredBytes).sorted())

        try await transport.close()
    }

    private func exerciseConcurrentChannels(settings: SSHTransportSettings) async throws {
        let prepared = try makePreparedImage(
            named: "image-stage-concurrent-\(UUID().uuidString).png",
            byteCount: 2 * 1_024 * 1_024,
            format: .png)
        defer { try? FileManager.default.removeItem(at: prepared.image.fileURL) }
        let holdProgress = ScriptedTransportCallGate()
        let transport = try await HeelerSSHTransport.connect(settings: settings)
        let events = try await transport.subscribeToEvents([.global(.paneCreated)])
        var eventIterator = events.events.makeAsyncIterator()
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:staging", cols: 80, rows: 24))
        var attachIterator = attach.output.makeAsyncIterator()
        let staging = Task {
            try await transport.stageImage(prepared.image) { value in
                if value.transferredBytes > 0 {
                    await holdProgress.waitUntilOpen()
                }
            }
        }
        try await waitUntil("SFTP should hold one ordinary session slot") {
            await holdProgress.entryCount > 0
        }

        try await AsyncDeadline.run(for: .seconds(10)) {
            try await withThrowingTaskGroup(of: ServerInfo.self) { group in
                for _ in 0..<HeelerSSHTransport.maxConcurrentForwardingChannels {
                    group.addTask { try await transport.ping() }
                }
                for try await server in group {
                    #expect(server.protocolVersion == 17)
                }
            }
        }

        await holdProgress.open()
        let staged = try await staging.value
        let parentDirectory = staged.fileURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parentDirectory) }
        #expect(try Data(contentsOf: staged.fileURL) == prepared.bytes)
        #expect(try await transport.ping().protocolVersion == 17)

        let event = try await eventIterator.next()
        #expect(event?.kind == HerdrEventKind(name: "future_herdr_event"))
        attach.send(Data("probe-after-stage\n".utf8))
        var attachOutput = ""
        while !attachOutput.contains("GOT:probe-after-stage") {
            let chunk = try #require(try await attachIterator.next())
            attachOutput += String(decoding: chunk, as: UTF8.self)
        }

        await attach.end()
        await events.end()
        try await transport.close()
    }

    private func makePreparedImage(
        named name: String,
        byteCount: Int,
        format: PreparedImageFormat
    ) throws -> (image: PreparedImage, bytes: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: url)
        return (
            PreparedImage(
                fileURL: url,
                format: format,
                pixelWidth: 4_096,
                pixelHeight: 2_048,
                byteCount: Int64(bytes.count)),
            bytes)
    }

    private func stagedDirectories(in parent: String, prefix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: parent),
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), comment)
    }

    private actor ProgressRecorder {
        private(set) var values: [ImageStageProgress] = []

        func record(_ progress: ImageStageProgress) {
            values.append(progress)
        }
    }
}
