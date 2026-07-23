import Foundation
import Testing

@testable import HerdrMobile

@Suite(
    "Image staging e2e",
    .enabled(
        if: LocalSSHTestEnvironment.isAvailable,
        "requires localhost sshd, SFTP, and an authorized Ed25519 test key"),
    .serialized,
    .timeLimit(.minutes(1)))
struct ImageStagingE2ETests {
    @Test func streamsPrivateFileAndAtomicallyRenamesThePart() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-stage-\(UUID().uuidString).png")
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let image = PreparedImage(
            fileURL: localURL,
            format: .png,
            pixelWidth: 320,
            pixelHeight: 200,
            byteCount: Int64(bytes.count))
        let progress = ProgressRecorder()
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath("/tmp/herdr-image-stage-unused.sock")))

        let staged: StagedImage
        do {
            staged = try await transport.stageImage(image) { value in
                await progress.record(value)
            }
        } catch {
            try? await transport.close()
            throw error
        }
        defer { try? FileManager.default.removeItem(at: staged.fileURL.deletingLastPathComponent()) }

        #expect(staged.path.hasPrefix("/"))
        #expect(staged.path.hasSuffix(".png"))
        #expect(!staged.path.contains(localURL.lastPathComponent))
        #expect(try Data(contentsOf: staged.fileURL) == bytes)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: staged.fileURL.deletingLastPathComponent().path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: staged.fileURL.deletingLastPathComponent().path)
                == [staged.fileURL.lastPathComponent])
        let values = await progress.values
        #expect(values.first == ImageStageProgress(transferredBytes: 0, totalBytes: bytes.count))
        #expect(
            values.last
                == ImageStageProgress(
                    transferredBytes: bytes.count,
                    totalBytes: bytes.count))
        #expect(values.map(\.transferredBytes) == values.map(\.transferredBytes).sorted())

        try await transport.close()
    }

    @Test func cancellationRemovesOnlyTheCurrentIncompletePart() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let identifier = UUID().uuidString.lowercased()
        let remotePrefix = "herdr-mobile-cancel-\(identifier)"
        let stageDirectoryCommand =
            "/bin/sh -c 'umask 077; "
            + "directory=$(mktemp -d \"/tmp/\(remotePrefix).XXXXXXXX\") || exit 1; "
            + "printf \"__HERDR_MOBILE_STAGE_DIR__=%s\\n\" \"$directory\"'"
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-stage-cancel-\(identifier).jpg")
        let bytes = Data(repeating: 0xA5, count: 8 * 1_024 * 1_024)
        try bytes.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let image = PreparedImage(
            fileURL: localURL,
            format: .jpeg,
            pixelWidth: 4_096,
            pixelHeight: 2_048,
            byteCount: Int64(bytes.count))
        let holdProgress = ScriptedTransportCallGate()
        let transport = try await SSHTransport.connect(
            settings: environment.makeSettings(
                socket: .absolutePath("/tmp/herdr-image-stage-unused.sock"),
                stageDirectoryCommand: stageDirectoryCommand))
        let task = Task {
            try await transport.stageImage(image) { value in
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
        let stagedDirectories = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/tmp"),
            includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(remotePrefix) }
        #expect(stagedDirectories.count == 1)
        let directory = try #require(stagedDirectories.first)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try await transport.close()
    }

    @Test func stagingSharesCapacityWithRPCsWhileEventsAndAttachAreLive() async throws {
        let environment = try #require(LocalSSHTestEnvironment.current)
        let server = try FakeHerdrServer { request in
            if request.method == "events.subscribe" {
                return .streamThenHold([
                    .write(
                        #"{"id":"\#(request.id)","result":{"type":"subscription_started"}}"#)
                ])
            }
            return nil
        }
        defer { server.stop() }

        let identifier = UUID().uuidString.lowercased()
        let attachScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-stage-attach-\(identifier).sh")
        try """
        printf 'READY\\n'
        exec sleep 30
        """.write(to: attachScript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: attachScript) }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-stage-capacity-\(identifier).png")
        let bytes = Data(repeating: 0x4B, count: 200_000)
        try bytes.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let image = PreparedImage(
            fileURL: localURL,
            format: .png,
            pixelWidth: 320,
            pixelHeight: 200,
            byteCount: Int64(bytes.count))

        var settings = environment.makeSettings(
            socket: .absolutePath(server.socketPath),
            wakeCommand: "false",
            requestTimeout: .seconds(20))
        settings.attachCommand = "/bin/sh \(attachScript.path)"
        let transport = try await SSHTransport.connect(settings: settings)
        let events = try await transport.subscribeToEvents([.global(.paneCreated)])
        let attach = try await transport.attachTerminal(
            TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24))
        var attachOutput = attach.output.makeAsyncIterator()
        var attachText = ""
        while !attachText.contains("READY") {
            guard let bytes = try await attachOutput.next() else {
                Issue.record("Attach ended before the capacity test was ready.")
                break
            }
            attachText += String(decoding: bytes, as: UTF8.self)
        }

        let requests = (0..<SSHTransport.maxConcurrentExecChannels).map { _ in
            Task { try await transport.listAgents() }
        }
        #expect(
            await server.wait(for: {
                $0.receivedRequests.filter { $0.method == "agent.list" }.count
                    == SSHTransport.maxConcurrentExecChannels
            }))

        let staging = Task {
            try await transport.stageImage(image) { _ in }
        }
        try await Task.sleep(for: .milliseconds(150))

        requests[0].cancel()
        await #expect(throws: TransportError.cancelled) {
            _ = try await requests[0].value
        }
        let staged = try await staging.value
        defer {
            try? FileManager.default.removeItem(
                at: staged.fileURL.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: staged.fileURL) == bytes)

        for request in requests.dropFirst() {
            request.cancel()
            await #expect(throws: TransportError.cancelled) {
                _ = try await request.value
            }
        }
        await attach.end()
        await events.end()
        try await transport.close()
    }

    private func waitUntil(
        _ comment: Comment,
        timeout: Duration = .seconds(5),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { break }
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
